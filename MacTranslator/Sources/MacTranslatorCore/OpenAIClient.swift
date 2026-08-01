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
    private static let structuredContentRetryInstructions = """


    The previous structured response was incomplete or could not be decoded.
    Return the entire JSON object again from the beginning.
    Keep every string concise. Do not pad any field with spaces, tabs, or blank lines.
    Copy every short ID from the input exactly. Return JSON only.
    """

    private let endpoint: URL
    private let session: URLSession
    private let diagnosticLogger: DiagnosticLogger
    private let learningDebugStore: LearningDebugStore
    private let retryDelayNanoseconds: [UInt64]
    private let backgroundPollIntervalNanoseconds: UInt64

    public init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared,
        diagnosticLogger: DiagnosticLogger = .shared,
        learningDebugStore: LearningDebugStore = .shared,
        retryDelayNanoseconds: [UInt64] = [500_000_000, 1_000_000_000],
        backgroundPollIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.endpoint = endpoint
        self.session = session
        self.diagnosticLogger = diagnosticLogger
        self.learningDebugStore = learningDebugStore
        self.retryDelayNanoseconds = Array(retryDelayNanoseconds.prefix(2))
        self.backgroundPollIntervalNanoseconds = backgroundPollIntervalNanoseconds
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
                "background": .boolean(true),
                "max_output_tokens": .integer(maxOutputTokens)
            ]) { _, new in new }
        )
        for contentAttempt in 1...2 {
            let retryingContent = contentAttempt == 2
            let attemptInstructions = retryingContent
                ? instructions + Self.structuredContentRetryInstructions
                : instructions
            do {
                let payload = try await structuredResponseData(
                    apiKey: apiKey,
                    model: model,
                    instructions: attemptInstructions,
                    input: input,
                    schemaName: schemaName,
                    schema: schema,
                    maxOutputTokens: maxOutputTokens,
                    diagnosticContext: requestContext
                )
                do {
                    return try JSONDecoder().decode(Output.self, from: payload.data)
                } catch {
                    let decodingMessage = Self.structuredDecodingFailureDescription(error)
                    diagnosticLogger.event(
                        "structured_output_decode_failed",
                        level: .error,
                        component: "openai",
                        operationID: requestContext.operationID,
                        failure: DiagnosticFailure.from(error),
                        details: [
                            "flow": .string(requestContext.flow),
                            "schema_name": .string(schemaName),
                            "content_attempt": .integer(contentAttempt),
                            "output": .string(
                                String(data: payload.data, encoding: .utf8) ?? ""
                            )
                        ]
                    )
                    learningDebugStore.requestFailed(
                        requestID: payload.requestID,
                        response: String(data: payload.data, encoding: .utf8),
                        attempt: payload.transportAttempt,
                        durationMilliseconds: payload.durationMilliseconds,
                        errorMessage: decodingMessage
                    )
                    if !retryingContent {
                        logStructuredContentRetry(
                            context: requestContext,
                            schemaName: schemaName,
                            reason: decodingMessage
                        )
                        continue
                    }
                    throw OpenAIClientError.stream(
                        "\(decodingMessage) The app retried once, but the second response "
                            + "was also invalid. Open Learn Debug for the raw response."
                    )
                }
            } catch let failure as StructuredContentFailure {
                if !retryingContent {
                    logStructuredContentRetry(
                        context: requestContext,
                        schemaName: schemaName,
                        reason: failure.localizedDescription
                    )
                    continue
                }
                throw OpenAIClientError.stream(
                    "\(failure.localizedDescription) The app retried once, but the second "
                        + "response was also incomplete. Open Learn Debug for the raw response."
                )
            }
        }
        throw OpenAIClientError.invalidResponse
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
    ) async throws -> StructuredResponsePayload {
        let requestID = UUID()
        let startedAt = Date()
        let attempt = 1
        var responseText: String?
        var outputText: String?
        var tokenUsage: LearningTokenUsage?
        var openAIResponseID: String?
        var openAIStatus: String?
        var pollCount = 0
        let schemaText = (try? JSONEncoder().encode(schema))
            .flatMap { String(data: $0, encoding: .utf8) }

        diagnosticLogger.requestStarted(
            requestID: requestID,
            attempt: attempt,
            context: diagnosticContext,
            model: model,
            instructions: instructions,
            input: input,
            schemaName: schemaName,
            schema: schemaText
        )
        learningDebugStore.requestStarted(
            requestID: requestID,
            flow: diagnosticContext.flow,
            model: model,
            instructions: instructions,
            input: input,
            attempt: attempt
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
                    background: true,
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

            let initialResult = try await sendBackgroundRequest(request)
            responseText = String(data: initialResult.data, encoding: .utf8)
            diagnosticLogger.responseReceived(
                requestID: requestID,
                attempt: attempt,
                statusCode: initialResult.response.statusCode,
                openAIRequestID: initialResult.response.value(
                    forHTTPHeaderField: "x-request-id"
                ),
                headers: Self.responseHeaders(initialResult.response),
                context: diagnosticContext
            )

            var envelope = initialResult.envelope
            openAIResponseID = envelope.id
            openAIStatus = envelope.status
            updateBackgroundStatus(
                requestID: requestID,
                responseID: openAIResponseID,
                status: openAIStatus,
                pollCount: pollCount,
                startedAt: startedAt,
                context: diagnosticContext
            )

            while Self.isBackgroundResponsePending(envelope.status) {
                guard let responseID = envelope.id ?? openAIResponseID else {
                    throw OpenAIClientError.invalidResponse
                }
                openAIResponseID = responseID
                try Task.checkCancellation()
                if backgroundPollIntervalNanoseconds > 0 {
                    try await Task.sleep(
                        nanoseconds: backgroundPollIntervalNanoseconds
                    )
                }
                try Task.checkCancellation()
                pollCount += 1
                let pollResult = try await retrieveBackgroundResponse(
                    responseID: responseID,
                    apiKey: apiKey,
                    requestID: requestID,
                    pollCount: pollCount,
                    context: diagnosticContext
                )
                responseText = String(data: pollResult.data, encoding: .utf8)
                envelope = pollResult.envelope
                openAIStatus = envelope.status
                updateBackgroundStatus(
                    requestID: requestID,
                    responseID: responseID,
                    status: envelope.status,
                    pollCount: pollCount,
                    startedAt: startedAt,
                    context: diagnosticContext
                )
            }

            tokenUsage = Self.learningTokenUsage(from: envelope.usage)
            outputText = Self.structuredOutputText(from: envelope)
            if let error = envelope.error {
                throw OpenAIClientError.stream(error.message)
            }
            switch envelope.status {
            case "incomplete":
                let reason = envelope.incompleteDetails?.reason ?? "unknown reason"
                throw StructuredContentFailure.incomplete(reason: reason)
            case "failed":
                throw OpenAIClientError.stream(
                    "OpenAI could not complete the background response."
                )
            case "cancelled", "canceled":
                throw OpenAIClientError.stream(
                    "The OpenAI background response was cancelled."
                )
            case "queued", "in_progress":
                throw OpenAIClientError.invalidResponse
            default:
                break
            }

            for output in envelope.output {
                guard output.type == "message" else { continue }
                for content in output.content {
                    if content.type == "refusal", let refusal = content.refusal {
                        throw OpenAIClientError.stream(refusal)
                    }
                    if content.type == "output_text", let text = content.text,
                       let outputData = text.data(using: .utf8) {
                        let durationMilliseconds = Self.elapsedMilliseconds(
                            since: startedAt
                        )
                        diagnosticLogger.requestCompleted(
                            requestID: requestID,
                            attempt: attempt,
                            receivedText: true,
                            durationMilliseconds: durationMilliseconds,
                            outputText: text,
                            tokenUsage: tokenUsage,
                            context: diagnosticContext
                        )
                        learningDebugStore.requestCompleted(
                            requestID: requestID,
                            response: text,
                            tokenUsage: tokenUsage,
                            attempt: attempt,
                            durationMilliseconds: durationMilliseconds
                        )
                        return StructuredResponsePayload(
                            requestID: requestID,
                            data: outputData,
                            transportAttempt: attempt,
                            durationMilliseconds: durationMilliseconds
                        )
                    }
                }
            }
            throw OpenAIClientError.invalidResponse
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            if wasCancelled, let openAIResponseID {
                await cancelBackgroundResponse(
                    responseID: openAIResponseID,
                    apiKey: apiKey,
                    requestID: requestID,
                    context: diagnosticContext
                )
            }
            let reportedError: Error = wasCancelled ? CancellationError() : error
            let failure = Self.diagnosticFailure(for: reportedError)
            diagnosticLogger.requestFailed(
                requestID: requestID,
                attempt: attempt,
                receivedText: outputText?.isEmpty == false,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                failure: failure,
                outputText: outputText ?? responseText,
                context: diagnosticContext
            )
            learningDebugStore.requestFailed(
                requestID: requestID,
                response: outputText ?? responseText,
                tokenUsage: tokenUsage,
                attempt: attempt,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                errorMessage: wasCancelled
                    ? "The Learn background request was cancelled."
                    : error.localizedDescription
            )
            throw reportedError
        }
    }

    private func sendBackgroundRequest(
        _ request: URLRequest
    ) async throws -> BackgroundResponseResult {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        try Self.validateBackgroundHTTPResponse(httpResponse, data: data)
        return BackgroundResponseResult(
            data: data,
            response: httpResponse,
            envelope: try JSONDecoder().decode(
                StructuredResponseEnvelope.self,
                from: data
            )
        )
    }

    private func retrieveBackgroundResponse(
        responseID: String,
        apiKey: String,
        requestID: UUID,
        pollCount: Int,
        context: DiagnosticRequestContext
    ) async throws -> BackgroundResponseResult {
        let responseURL = endpoint.appendingPathComponent(responseID)
        var transportAttempt = 0

        while true {
            transportAttempt += 1
            do {
                var request = URLRequest(url: responseURL)
                request.httpMethod = "GET"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let result = try await sendBackgroundRequest(request)
                diagnosticLogger.event(
                    "background_response_poll_received",
                    level: .debug,
                    component: "openai",
                    operationID: context.operationID,
                    details: [
                        "flow": .string(context.flow),
                        "request_id": .string(requestID.uuidString),
                        "response_id": .string(responseID),
                        "status": .string(result.envelope.status ?? "unknown"),
                        "poll_count": .integer(pollCount),
                        "transport_attempt": .integer(transportAttempt),
                        "http_status": .integer(result.response.statusCode)
                    ]
                )
                return result
            } catch {
                let retryIndex = transportAttempt - 1
                guard Self.isRetryable(error),
                      retryIndex < retryDelayNanoseconds.count,
                      !Task.isCancelled else {
                    throw error
                }
                let delay = retryDelayNanoseconds[retryIndex]
                diagnosticLogger.event(
                    "background_response_poll_retry_scheduled",
                    level: .warning,
                    component: "openai",
                    operationID: context.operationID,
                    failure: Self.diagnosticFailure(for: error),
                    details: [
                        "flow": .string(context.flow),
                        "request_id": .string(requestID.uuidString),
                        "response_id": .string(responseID),
                        "poll_count": .integer(pollCount),
                        "transport_attempt": .integer(transportAttempt),
                        "delay_ms": .integer(Int(delay / 1_000_000))
                    ]
                )
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func updateBackgroundStatus(
        requestID: UUID,
        responseID: String?,
        status: String?,
        pollCount: Int,
        startedAt: Date,
        context: DiagnosticRequestContext
    ) {
        learningDebugStore.backgroundStatusUpdated(
            requestID: requestID,
            responseID: responseID,
            status: status,
            pollCount: pollCount,
            durationMilliseconds: Self.elapsedMilliseconds(since: startedAt)
        )
        diagnosticLogger.event(
            pollCount == 0
                ? "background_response_created"
                : "background_response_status_updated",
            component: "openai",
            operationID: context.operationID,
            details: [
                "flow": .string(context.flow),
                "request_id": .string(requestID.uuidString),
                "response_id": .string(responseID ?? "unknown"),
                "status": .string(status ?? "unknown"),
                "poll_count": .integer(pollCount)
            ]
        )
    }

    private func cancelBackgroundResponse(
        responseID: String,
        apiKey: String,
        requestID: UUID,
        context: DiagnosticRequestContext
    ) async {
        let cancelURL = endpoint
            .appendingPathComponent(responseID)
            .appendingPathComponent("cancel")
        let session = session
        let diagnosticLogger = diagnosticLogger
        let operationID = context.operationID
        let flow = context.flow
        await Task.detached(priority: .utility) {
            do {
                var request = URLRequest(url: cancelURL)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                diagnosticLogger.event(
                    "background_response_cancel_requested",
                    component: "openai",
                    operationID: operationID,
                    details: [
                        "flow": .string(flow),
                        "request_id": .string(requestID.uuidString),
                        "response_id": .string(responseID),
                        "http_status": .integer(statusCode ?? 0)
                    ]
                )
            } catch {
                diagnosticLogger.event(
                    "background_response_cancel_failed",
                    level: .warning,
                    component: "openai",
                    operationID: operationID,
                    failure: Self.diagnosticFailure(for: error),
                    details: [
                        "flow": .string(flow),
                        "request_id": .string(requestID.uuidString),
                        "response_id": .string(responseID)
                    ]
                )
            }
        }.value
    }

    private static func validateBackgroundHTTPResponse(
        _ response: HTTPURLResponse,
        data: Data
    ) throws {
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIClientError.api(
                statusCode: response.statusCode,
                message: envelope?.error.message ?? fallback
            )
        }
    }

    private static func isBackgroundResponsePending(_ status: String?) -> Bool {
        status == "queued" || status == "in_progress"
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

    private func logStructuredContentRetry(
        context: DiagnosticRequestContext,
        schemaName: String,
        reason: String
    ) {
        diagnosticLogger.event(
            "structured_content_retry_scheduled",
            level: .warning,
            component: "openai",
            operationID: context.operationID,
            details: [
                "flow": .string(context.flow),
                "schema_name": .string(schemaName),
                "reason": .string(reason),
                "next_content_attempt": .integer(2)
            ]
        )
    }

    private static func learningTokenUsage(
        from usage: StructuredResponseUsage?
    ) -> LearningTokenUsage? {
        usage.map {
            LearningTokenUsage(
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                totalTokens: $0.totalTokens,
                cachedInputTokens: $0.inputTokensDetails?.cachedTokens,
                reasoningOutputTokens: $0.outputTokensDetails?.reasoningTokens
            )
        }
    }

    private static func structuredOutputText(
        from envelope: StructuredResponseEnvelope
    ) -> String? {
        envelope.output.lazy
            .filter { $0.type == "message" }
            .flatMap(\.content)
            .first { $0.type == "output_text" }?
            .text
    }

    private static func structuredDecodingFailureDescription(_ error: Error) -> String {
        let prefix = "The structured response could not be decoded"
        guard let decodingError = error as? DecodingError else {
            return "\(prefix): \(error.localizedDescription)"
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "\(prefix): missing required field "
                + "'\(codingPath(context.codingPath + [key]))'."
        case .typeMismatch(let type, let context):
            return "\(prefix): field '\(codingPath(context.codingPath))' "
                + "was not a \(String(describing: type))."
        case .valueNotFound(let type, let context):
            return "\(prefix): field '\(codingPath(context.codingPath))' "
                + "was null instead of \(String(describing: type))."
        case .dataCorrupted(let context):
            return "\(prefix) at '\(codingPath(context.codingPath))': "
                + context.debugDescription
        @unknown default:
            return "\(prefix): \(error.localizedDescription)"
        }
    }

    private static func codingPath(_ keys: [any CodingKey]) -> String {
        guard !keys.isEmpty else { return "<root>" }
        var result = ""
        for key in keys {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty { result += "." }
                result += key.stringValue
            }
        }
        return result
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
    let background: Bool
    let maxOutputTokens: Int
    let text: StructuredTextConfiguration

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case store
        case background
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
    let id: String?
    let status: String?
    let error: APIErrorDetail?
    let incompleteDetails: StructuredIncompleteDetails?
    let output: [StructuredOutputItem]
    let usage: StructuredResponseUsage?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case error
        case incompleteDetails = "incomplete_details"
        case output
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        error = try container.decodeIfPresent(APIErrorDetail.self, forKey: .error)
        incompleteDetails = try container.decodeIfPresent(
            StructuredIncompleteDetails.self,
            forKey: .incompleteDetails
        )
        output = try container.decodeIfPresent(
            [StructuredOutputItem].self,
            forKey: .output
        ) ?? []
        usage = try container.decodeIfPresent(
            StructuredResponseUsage.self,
            forKey: .usage
        )
    }
}

private struct BackgroundResponseResult {
    let data: Data
    let response: HTTPURLResponse
    let envelope: StructuredResponseEnvelope
}

private struct StructuredResponsePayload {
    let requestID: UUID
    let data: Data
    let transportAttempt: Int
    let durationMilliseconds: Int
}

private enum StructuredContentFailure: LocalizedError {
    case incomplete(reason: String)

    var errorDescription: String? {
        switch self {
        case .incomplete(let reason):
            if reason == "max_output_tokens" {
                return "The structured response reached its output-token limit and was incomplete."
            }
            return "The structured response was incomplete (\(reason))."
        }
    }
}

private struct StructuredResponseUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let inputTokensDetails: StructuredInputTokenDetails?
    let outputTokensDetails: StructuredOutputTokenDetails?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokensDetails = "output_tokens_details"
    }
}

private struct StructuredInputTokenDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

private struct StructuredOutputTokenDetails: Decodable {
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
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
