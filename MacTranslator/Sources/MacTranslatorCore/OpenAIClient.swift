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

    public init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func streamResponse(
        apiKey: String,
        model: String,
        instructions: String,
        input: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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
                            stream: true
                        )
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIClientError.invalidResponse
                    }

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
                        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }

                        switch try OpenAIStreamEventParser.parse(data) {
                        case .textDelta(let delta):
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                        case .failure(let message):
                            throw OpenAIClientError.stream(message)
                        case .ignored:
                            continue
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
    let stream: Bool
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
