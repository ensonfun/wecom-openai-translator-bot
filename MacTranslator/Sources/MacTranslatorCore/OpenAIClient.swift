import Foundation

public enum OpenAIClientError: LocalizedError {
    case invalidResponse
    case api(statusCode: Int, message: String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI returned an unrecognized response."
        case .api(let statusCode, let message):
            return "OpenAI API request failed (HTTP \(statusCode)): \(message)"
        case .stream(let message):
            return message
        }
    }
}

public struct OpenAIClient: Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let diagnosticLogger: DiagnosticLogger
    private let retryDelayNanoseconds: [UInt64]

    public init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared,
        diagnosticLogger: DiagnosticLogger = .shared,
        retryDelayNanoseconds: [UInt64] = [500_000_000, 1_000_000_000]
    ) {
        self.endpoint = endpoint
        self.session = session
        self.diagnosticLogger = diagnosticLogger
        self.retryDelayNanoseconds = Array(retryDelayNanoseconds.prefix(2))
    }

    public func streamResponse(
        apiKey: String,
        model: String,
        instructions: String,
        input: String,
        diagnosticContext: DiagnosticRequestContext = DiagnosticRequestContext(flow: "chat")
    ) -> AsyncThrowingStream<String, Error> {
        diagnosticLogger.registerSecret(apiKey)
        let requestContext = DiagnosticRequestContext(
            flow: diagnosticContext.flow,
            operationID: diagnosticContext.operationID,
            details: diagnosticContext.details.merging([
                "endpoint": .string(endpoint.absoluteString),
                "store": .boolean(false),
                "stream": .boolean(true)
            ]) { _, new in new }
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                let requestID = UUID()
                let startedAt = Date()
                var receivedText = false
                var outputText = ""
                var attempt = 0

                while true {
                    attempt += 1
                    diagnosticLogger.requestStarted(
                        requestID: requestID,
                        attempt: attempt,
                        context: requestContext,
                        model: model,
                        instructions: attempt == 1 ? instructions : nil,
                        input: attempt == 1 ? input : nil
                    )

                    do {
                        var request = URLRequest(url: endpoint)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONEncoder().encode(
                            ResponseRequest(
                                model: model,
                                instructions: instructions,
                                input: input,
                                store: false,
                                stream: true
                            )
                        )

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw OpenAIClientError.invalidResponse
                        }
                        diagnosticLogger.responseReceived(
                            requestID: requestID,
                            attempt: attempt,
                            statusCode: httpResponse.statusCode,
                            openAIRequestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
                            headers: Self.responseHeaders(httpResponse),
                            context: requestContext
                        )

                        guard (200..<300).contains(httpResponse.statusCode) else {
                            var body = Data()
                            for try await byte in bytes {
                                body.append(byte)
                            }
                            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body)
                            let fallback = String(data: body, encoding: .utf8) ?? "Unknown error"
                            throw OpenAIClientError.api(
                                statusCode: httpResponse.statusCode,
                                message: envelope?.error.message ?? fallback
                            )
                        }

                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" {
                                diagnosticLogger.event(
                                    "stream_done_received",
                                    component: "openai",
                                    operationID: requestContext.operationID,
                                    details: [
                                        "flow": .string(requestContext.flow),
                                        "request_id": .string(requestID.uuidString),
                                        "attempt": .integer(attempt)
                                    ]
                                )
                                continue
                            }
                            guard let data = payload.data(using: .utf8) else { continue }

                            let parsedEvent: OpenAIStreamEventOutcome
                            do {
                                parsedEvent = try OpenAIStreamEventParser.parse(data)
                            } catch {
                                diagnosticLogger.event(
                                    "stream_event_parse_failed",
                                    level: .error,
                                    component: "openai",
                                    operationID: requestContext.operationID,
                                    failure: DiagnosticFailure.from(error),
                                    details: [
                                        "flow": .string(requestContext.flow),
                                        "request_id": .string(requestID.uuidString),
                                        "attempt": .integer(attempt),
                                        "raw_event": .string(payload)
                                    ]
                                )
                                throw error
                            }

                            switch parsedEvent {
                            case .textDelta(let delta):
                                if !delta.isEmpty {
                                    receivedText = true
                                    outputText += delta
                                    continuation.yield(delta)
                                }
                            case .failure(let message):
                                diagnosticLogger.event(
                                    "stream_failure_event_received",
                                    level: .error,
                                    component: "openai",
                                    operationID: requestContext.operationID,
                                    failure: DiagnosticFailure(
                                        statusCode: nil,
                                        errorDomain: "OpenAI.StreamEvent",
                                        errorCode: nil,
                                        message: message
                                    ),
                                    details: [
                                        "flow": .string(requestContext.flow),
                                        "request_id": .string(requestID.uuidString),
                                        "attempt": .integer(attempt),
                                        "raw_event": .string(payload)
                                    ]
                                )
                                throw OpenAIClientError.stream(message)
                            case .ignored:
                                diagnosticLogger.event(
                                    "stream_lifecycle_event_received",
                                    level: .debug,
                                    component: "openai",
                                    operationID: requestContext.operationID,
                                    details: [
                                        "flow": .string(requestContext.flow),
                                        "request_id": .string(requestID.uuidString),
                                        "attempt": .integer(attempt),
                                        "raw_event": .string(payload)
                                    ]
                                )
                                continue
                            }
                        }

                        diagnosticLogger.requestCompleted(
                            requestID: requestID,
                            attempt: attempt,
                            receivedText: receivedText,
                            durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                            outputText: outputText,
                            context: requestContext
                        )
                        continuation.finish()
                        return
                    } catch {
                        let failure = Self.diagnosticFailure(for: error)
                        let retryIndex = attempt - 1
                        if !receivedText,
                           Self.isRetryable(error),
                           retryIndex < retryDelayNanoseconds.count,
                           !Task.isCancelled {
                            let delay = retryDelayNanoseconds[retryIndex]
                            diagnosticLogger.retryScheduled(
                                requestID: requestID,
                                attempt: attempt,
                                delayMilliseconds: Int(delay / 1_000_000),
                                failure: failure,
                                context: requestContext
                            )
                            do {
                                try await Task.sleep(nanoseconds: delay)
                                continue
                            } catch {
                                diagnosticLogger.requestFailed(
                                    requestID: requestID,
                                    attempt: attempt,
                                    receivedText: receivedText,
                                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                                    failure: Self.diagnosticFailure(for: error),
                                    outputText: outputText.isEmpty ? nil : outputText,
                                    context: requestContext
                                )
                                continuation.finish(throwing: error)
                                return
                            }
                        }

                        diagnosticLogger.requestFailed(
                            requestID: requestID,
                            attempt: attempt,
                            receivedText: receivedText,
                            durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                            failure: failure,
                            outputText: outputText.isEmpty ? nil : outputText,
                            context: requestContext
                        )
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func structuredResponse<Output: Decodable & Sendable>(
        apiKey: String,
        model: String,
        instructions: String,
        input: String,
        schemaName: String,
        schema: JSONValue,
        maxOutputTokens: Int = 2_000,
        diagnosticContext: DiagnosticRequestContext = DiagnosticRequestContext(
            flow: "structured"
        ),
        outputType: Output.Type = Output.self
    ) async throws -> Output {
        diagnosticLogger.registerSecret(apiKey)
        let requestContext = DiagnosticRequestContext(
            flow: diagnosticContext.flow,
            operationID: diagnosticContext.operationID,
            details: diagnosticContext.details.merging([
                "endpoint": .string(endpoint.absoluteString),
                "store": .boolean(false),
                "stream": .boolean(false),
                "max_output_tokens": .integer(maxOutputTokens)
            ]) { _, new in new }
        )
        let data = try await structuredResponseData(
            apiKey: apiKey,
            model: model,
            instructions: instructions,
            input: input,
            schemaName: schemaName,
            schema: schema,
            maxOutputTokens: maxOutputTokens,
            diagnosticContext: requestContext
        )
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            diagnosticLogger.event(
                "structured_output_decode_failed",
                level: .error,
                component: "openai",
                operationID: requestContext.operationID,
                failure: DiagnosticFailure.from(error),
                details: [
                    "flow": .string(requestContext.flow),
                    "schema_name": .string(schemaName),
                    "output": .string(String(data: data, encoding: .utf8) ?? "")
                ]
            )
            throw OpenAIClientError.stream("The structured response did not match the app's data model.")
        }
    }

    private func structuredResponseData(
        apiKey: String,
        model: String,
        instructions: String,
        input: String,
        schemaName: String,
        schema: JSONValue,
        maxOutputTokens: Int,
        diagnosticContext: DiagnosticRequestContext
    ) async throws -> Data {
        let requestID = UUID()
        let startedAt = Date()
        var attempt = 0
        var responseText: String?
        let schemaText = (try? JSONEncoder().encode(schema))
            .flatMap { String(data: $0, encoding: .utf8) }

        while true {
            attempt += 1
            responseText = nil
            diagnosticLogger.requestStarted(
                requestID: requestID,
                attempt: attempt,
                context: diagnosticContext,
                model: model,
                instructions: attempt == 1 ? instructions : nil,
                input: attempt == 1 ? input : nil,
                schemaName: attempt == 1 ? schemaName : nil,
                schema: attempt == 1 ? schemaText : nil
            )
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(
                    StructuredResponseRequest(
                        model: model,
                        instructions: instructions,
                        input: input,
                        store: false,
                        maxOutputTokens: maxOutputTokens,
                        text: StructuredTextConfiguration(
                            format: StructuredTextFormat(
                                type: "json_schema",
                                name: schemaName,
                                strict: true,
                                schema: schema
                            )
                        )
                    )
                )

                let (data, response) = try await session.data(for: request)
                responseText = String(data: data, encoding: .utf8)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIClientError.invalidResponse
                }
                diagnosticLogger.responseReceived(
                    requestID: requestID,
                    attempt: attempt,
                    statusCode: httpResponse.statusCode,
                    openAIRequestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
                    headers: Self.responseHeaders(httpResponse),
                    context: diagnosticContext
                )
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
                    let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw OpenAIClientError.api(
                        statusCode: httpResponse.statusCode,
                        message: envelope?.error.message ?? fallback
                    )
                }

                let envelope = try JSONDecoder().decode(StructuredResponseEnvelope.self, from: data)
                if let error = envelope.error {
                    throw OpenAIClientError.stream(error.message)
                }
                for output in envelope.output {
                    guard output.type == "message" else { continue }
                    for content in output.content {
                        if content.type == "refusal", let refusal = content.refusal {
                            throw OpenAIClientError.stream(refusal)
                        }
                        if content.type == "output_text", let text = content.text,
                           let outputData = text.data(using: .utf8) {
                            diagnosticLogger.requestCompleted(
                                requestID: requestID,
                                attempt: attempt,
                                receivedText: true,
                                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                                outputText: text,
                                context: diagnosticContext
                            )
                            return outputData
                        }
                    }
                }
                if envelope.status == "incomplete" {
                    throw OpenAIClientError.stream(
                        envelope.incompleteDetails?.reason
                            ?? "The structured response was incomplete."
                    )
                }
                throw OpenAIClientError.invalidResponse
            } catch {
                let failure = Self.diagnosticFailure(for: error)
                let retryIndex = attempt - 1
                if Self.isRetryable(error),
                   retryIndex < retryDelayNanoseconds.count,
                   !Task.isCancelled {
                    let delay = retryDelayNanoseconds[retryIndex]
                    diagnosticLogger.retryScheduled(
                        requestID: requestID,
                        attempt: attempt,
                        delayMilliseconds: Int(delay / 1_000_000),
                        failure: failure,
                        context: diagnosticContext
                    )
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                diagnosticLogger.requestFailed(
                    requestID: requestID,
                    attempt: attempt,
                    receivedText: false,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    failure: failure,
                    outputText: responseText,
                    context: diagnosticContext
                )
                throw error
            }
        }
    }

    public static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable
            ].contains(urlError.code)
        }

        if case .api(let statusCode, _) = error as? OpenAIClientError {
            return statusCode == 408
                || statusCode == 409
                || statusCode == 429
                || (500...599).contains(statusCode)
        }
        return false
    }

    private static func diagnosticFailure(for error: Error) -> DiagnosticFailure {
        if case .api(let statusCode, _) = error as? OpenAIClientError {
            return DiagnosticFailure(
                statusCode: statusCode,
                errorDomain: "OpenAIClientError",
                errorCode: statusCode,
                message: error.localizedDescription
            )
        }
        let nsError = error as NSError
        return DiagnosticFailure(
            statusCode: nil,
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            message: error.localizedDescription
        )
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func responseHeaders(
        _ response: HTTPURLResponse
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: response.allHeaderFields.map {
            (String(describing: $0.key), String(describing: $0.value))
        })
    }
}

public enum OpenAIStreamEventOutcome: Equatable, Sendable {
    case textDelta(String)
    case failure(String)
    case ignored
}

public enum OpenAIStreamEventParser {
    public static func parse(_ data: Data) throws -> OpenAIStreamEventOutcome {
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        switch event.type {
        case "response.output_text.delta":
            return .textDelta(event.delta ?? "")
        case "response.failed":
            return .failure(event.response?.error?.message ?? "OpenAI could not generate a response.")
        case "error":
            return .failure(
                event.error?.message
                    ?? event.message
                    ?? "The OpenAI response stream failed."
            )
        default:
            return .ignored
        }
    }
}

private struct ResponseRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
    let stream: Bool
}

private struct StructuredResponseRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
    let maxOutputTokens: Int
    let text: StructuredTextConfiguration

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case store
        case maxOutputTokens = "max_output_tokens"
        case text
    }
}

private struct StructuredTextConfiguration: Encodable {
    let format: StructuredTextFormat
}

private struct StructuredTextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: JSONValue
}

private struct StructuredResponseEnvelope: Decodable {
    let status: String?
    let error: APIErrorDetail?
    let incompleteDetails: StructuredIncompleteDetails?
    let output: [StructuredOutputItem]

    enum CodingKeys: String, CodingKey {
        case status
        case error
        case incompleteDetails = "incomplete_details"
        case output
    }
}

private struct StructuredIncompleteDetails: Decodable {
    let reason: String?
}

private struct StructuredOutputItem: Decodable {
    let type: String
    let content: [StructuredOutputContent]
}

private struct StructuredOutputContent: Decodable {
    let type: String
    let text: String?
    let refusal: String?
}

private struct StreamEvent: Decodable {
    let type: String
    let delta: String?
    let message: String?
    let error: APIErrorDetail?
    let response: StreamResponse?
}

private struct StreamResponse: Decodable {
    let error: APIErrorDetail?
}

private struct APIErrorEnvelope: Decodable {
    let error: APIErrorDetail
}

private struct APIErrorDetail: Decodable {
    let message: String
}
