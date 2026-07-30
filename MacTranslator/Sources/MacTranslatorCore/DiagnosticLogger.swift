import Foundation

public enum DiagnosticLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum DiagnosticValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case strings([String])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .strings(let value):
            try container.encode(value)
        }
    }

    fileprivate func redacted(using transform: (String) -> String) -> DiagnosticValue {
        switch self {
        case .string(let value):
            return .string(transform(value))
        case .strings(let values):
            return .strings(values.map(transform))
        case .integer, .double, .boolean:
            return self
        }
    }
}

public struct DiagnosticRequestContext: Sendable {
    public let flow: String
    public let operationID: UUID?
    public let details: [String: DiagnosticValue]

    public init(
        flow: String,
        operationID: UUID? = nil,
        details: [String: DiagnosticValue] = [:]
    ) {
        self.flow = flow
        self.operationID = operationID
        self.details = details
    }
}

public struct DiagnosticFailure: Codable, Sendable {
    public let statusCode: Int?
    public let errorDomain: String?
    public let errorCode: Int?
    public let message: String?

    public init(
        statusCode: Int?,
        errorDomain: String?,
        errorCode: Int?,
        message: String? = nil
    ) {
        self.statusCode = statusCode
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
    }

    public static func from(_ error: Error, statusCode: Int? = nil) -> DiagnosticFailure {
        let nsError = error as NSError
        return DiagnosticFailure(
            statusCode: statusCode,
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            message: error.localizedDescription
        )
    }

    fileprivate func redacted(using transform: (String) -> String) -> DiagnosticFailure {
        DiagnosticFailure(
            statusCode: statusCode,
            errorDomain: errorDomain.map(transform),
            errorCode: errorCode,
            message: message.map(transform)
        )
    }
}

public final class DiagnosticLogger: @unchecked Sendable {
    public static let shared = DiagnosticLogger()

    public let logFileURL: URL
    public let logsDirectoryURL: URL
    public let applicationSessionID: UUID

    private let maxFileSize: UInt64
    private let retainedFileCount: Int
    private let queue = DispatchQueue(label: "com.mario.MacTranslator.diagnostics")
    private let encoder: JSONEncoder
    private let secretLock = NSLock()
    private var registeredSecrets: [String] = []

    public init(
        directoryURL: URL? = nil,
        maxFileSize: UInt64 = 5_242_880,
        retainedFileCount: Int = 7
    ) {
        let directory = directoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacTranslator", isDirectory: true)
        self.logsDirectoryURL = directory
        self.logFileURL = directory.appendingPathComponent("MacTranslator.log")
        self.applicationSessionID = UUID()
        self.maxFileSize = max(1, maxFileSize)
        self.retainedFileCount = max(0, retainedFileCount)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// Registers a value that must never be persisted. OpenAIClient calls this
    /// before it records any request fields, including chat text and prompts.
    public func registerSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return }
        secretLock.lock()
        defer { secretLock.unlock() }
        guard !registeredSecrets.contains(trimmed) else { return }
        registeredSecrets.append(trimmed)
        if registeredSecrets.count > 16 {
            registeredSecrets.removeFirst(registeredSecrets.count - 16)
        }
    }

    public func startApplicationSession(
        details: [String: DiagnosticValue] = [:]
    ) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: logsDirectoryURL,
                    withIntermediateDirectories: true
                )
                if let marker = try? loadSessionMarker() {
                    try writeNow(
                        PendingDiagnosticRecord(
                            level: .warning,
                            component: "app",
                            event: "previous_session_unclosed",
                            operationID: nil,
                            failure: nil,
                            details: [
                                "previous_session_id": .string(marker.sessionID),
                                "previous_started_at": .string(marker.startedAt)
                            ],
                            sourceFile: nil,
                            sourceFunction: nil,
                            sourceLine: nil,
                            stackTrace: nil
                        )
                    )
                }

                try writeNow(
                    PendingDiagnosticRecord(
                        level: .info,
                        component: "app",
                        event: "application_started",
                        operationID: nil,
                        failure: nil,
                        details: details,
                        sourceFile: nil,
                        sourceFunction: nil,
                        sourceLine: nil,
                        stackTrace: nil
                    )
                )
                try saveSessionMarker()
            } catch {
                // Logging must never prevent the app from launching.
            }
        }
    }

    public func endApplicationSession(
        details: [String: DiagnosticValue] = [:]
    ) {
        queue.sync {
            do {
                try writeNow(
                    PendingDiagnosticRecord(
                        level: .info,
                        component: "app",
                        event: "application_terminated",
                        operationID: nil,
                        failure: nil,
                        details: details,
                        sourceFile: nil,
                        sourceFunction: nil,
                        sourceLine: nil,
                        stackTrace: nil
                    )
                )
                try? FileManager.default.removeItem(at: sessionMarkerURL)
            } catch {
                // App termination must continue even when logs cannot be written.
            }
        }
    }

    public func event(
        _ event: String,
        level: DiagnosticLogLevel = .info,
        component: String,
        operationID: UUID? = nil,
        failure: DiagnosticFailure? = nil,
        details: [String: DiagnosticValue] = [:],
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let stackTrace = level == .error
            ? Array(Thread.callStackSymbols.prefix(20))
            : nil
        let pending = PendingDiagnosticRecord(
            level: level,
            component: component,
            event: event,
            operationID: operationID,
            failure: failure,
            details: details,
            sourceFile: String(describing: file),
            sourceFunction: String(describing: function),
            sourceLine: line,
            stackTrace: stackTrace
        )
        if level == .error {
            queue.sync { [self] in
                try? writeNow(pending)
            }
        } else {
            queue.async { [self] in
                try? writeNow(pending)
            }
        }
    }

    public func requestStarted(
        requestID: UUID,
        attempt: Int,
        context: DiagnosticRequestContext = DiagnosticRequestContext(flow: "openai"),
        model: String? = nil,
        instructions: String? = nil,
        input: String? = nil,
        schemaName: String? = nil,
        schema: String? = nil
    ) {
        var details = context.details
        details["request_id"] = .string(requestID.uuidString)
        details["attempt"] = .integer(attempt)
        details["flow"] = .string(context.flow)
        if let model {
            details["model"] = .string(model)
        }
        if let instructions {
            details["instructions"] = .string(instructions)
        }
        if let input {
            details["input"] = .string(input)
        }
        if let schemaName {
            details["schema_name"] = .string(schemaName)
        }
        if let schema {
            details["schema"] = .string(schema)
        }
        event(
            "request_started",
            component: "openai",
            operationID: context.operationID,
            details: details
        )
    }

    public func responseReceived(
        requestID: UUID,
        attempt: Int,
        statusCode: Int,
        openAIRequestID: String?,
        headers: [String: String] = [:],
        context: DiagnosticRequestContext = DiagnosticRequestContext(flow: "openai")
    ) {
        var details = context.details
        details["request_id"] = .string(requestID.uuidString)
        details["attempt"] = .integer(attempt)
        details["flow"] = .string(context.flow)
        details["status_code"] = .integer(statusCode)
        if let openAIRequestID {
            details["openai_request_id"] = .string(openAIRequestID)
        }
        if !headers.isEmpty {
            details["response_headers"] = .strings(
                headers
                    .map { "\($0.key): \($0.value)" }
                    .sorted()
            )
        }
        event(
            "response_received",
            component: "openai",
            operationID: context.operationID,
            details: details
        )
    }

    public func retryScheduled(
        requestID: UUID,
        attempt: Int,
        delayMilliseconds: Int,
        failure: DiagnosticFailure,
        context: DiagnosticRequestContext = DiagnosticRequestContext(flow: "openai")
    ) {
        var details = context.details
        details["request_id"] = .string(requestID.uuidString)
        details["attempt"] = .integer(attempt)
        details["flow"] = .string(context.flow)
        details["retry_delay_ms"] = .integer(delayMilliseconds)
        event(
            "retry_scheduled",
            level: .warning,
            component: "openai",
            operationID: context.operationID,
            failure: failure,
            details: details
        )
    }

    public func requestCompleted(
        requestID: UUID,
        attempt: Int,
        receivedText: Bool,
        durationMilliseconds: Int,
        outputText: String? = nil,
        tokenUsage: LearningTokenUsage? = nil,
        context: DiagnosticRequestContext = DiagnosticRequestContext(flow: "openai")
    ) {
        var details = context.details
        details["request_id"] = .string(requestID.uuidString)
        details["attempt"] = .integer(attempt)
        details["flow"] = .string(context.flow)
        details["received_text"] = .boolean(receivedText)
        details["duration_ms"] = .integer(durationMilliseconds)
        if let outputText {
            details["output"] = .string(outputText)
            details["output_chars"] = .integer(outputText.count)
        }
        if let inputTokens = tokenUsage?.inputTokens {
            details["input_tokens"] = .integer(inputTokens)
        }
        if let outputTokens = tokenUsage?.outputTokens {
            details["output_tokens"] = .integer(outputTokens)
        }
        if let totalTokens = tokenUsage?.totalTokens {
            details["total_tokens"] = .integer(totalTokens)
        }
        if let cachedInputTokens = tokenUsage?.cachedInputTokens {
            details["cached_input_tokens"] = .integer(cachedInputTokens)
        }
        if let reasoningOutputTokens = tokenUsage?.reasoningOutputTokens {
            details["reasoning_output_tokens"] = .integer(reasoningOutputTokens)
        }
        event(
            "request_completed",
            component: "openai",
            operationID: context.operationID,
            details: details
        )
    }

    public func requestFailed(
        requestID: UUID,
        attempt: Int,
        receivedText: Bool,
        durationMilliseconds: Int,
        failure: DiagnosticFailure,
        outputText: String? = nil,
        context: DiagnosticRequestContext = DiagnosticRequestContext(flow: "openai")
    ) {
        var details = context.details
        details["request_id"] = .string(requestID.uuidString)
        details["attempt"] = .integer(attempt)
        details["flow"] = .string(context.flow)
        details["received_text"] = .boolean(receivedText)
        details["duration_ms"] = .integer(durationMilliseconds)
        if let outputText {
            details["partial_output"] = .string(outputText)
            details["output_chars"] = .integer(outputText.count)
        }
        event(
            "request_failed",
            level: .error,
            component: "openai",
            operationID: context.operationID,
            failure: failure,
            details: details
        )
    }

    public func flush() {
        queue.sync {}
    }

    public func exportArchive(to destinationURL: URL) throws {
        try queue.sync {
            var output = Data()
            let archiveURLs = retainedFileCount > 0
                ? stride(
                    from: retainedFileCount,
                    through: 1,
                    by: -1
                ).map(archivedLogFileURL)
                : []
            for url in archiveURLs + [logFileURL] {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try Data(contentsOf: url)
                output.append(data)
                if output.last != 0x0A {
                    output.append(0x0A)
                }
            }
            try output.write(to: destinationURL, options: .atomic)
        }
    }

    public func archivedLogFileURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(logFileURL.path).\(index)")
    }

    private var sessionMarkerURL: URL {
        logsDirectoryURL.appendingPathComponent("active-session.json")
    }

    private func loadSessionMarker() throws -> DiagnosticSessionMarker {
        let data = try Data(contentsOf: sessionMarkerURL)
        return try JSONDecoder().decode(DiagnosticSessionMarker.self, from: data)
    }

    private func saveSessionMarker() throws {
        let formatter = ISO8601DateFormatter()
        let marker = DiagnosticSessionMarker(
            sessionID: applicationSessionID.uuidString,
            startedAt: formatter.string(from: Date())
        )
        try JSONEncoder().encode(marker).write(to: sessionMarkerURL, options: .atomic)
    }

    private func writeNow(_ pending: PendingDiagnosticRecord) throws {
        var details: [String: DiagnosticValue] = [:]
        for (key, value) in pending.details {
            details[redact(key)] = value.redacted(using: redact)
        }
        let record = DiagnosticLogRecord(
            timestamp: Date(),
            level: pending.level,
            component: redact(pending.component),
            event: redact(pending.event),
            applicationSessionID: applicationSessionID.uuidString,
            operationID: pending.operationID?.uuidString,
            failure: pending.failure?.redacted(using: redact),
            details: details.isEmpty ? nil : details,
            sourceFile: pending.sourceFile.map(redact),
            sourceFunction: pending.sourceFunction.map(redact),
            sourceLine: pending.sourceLine,
            stackTrace: pending.stackTrace?.map(redact)
        )
        var data = try encoder.encode(record)
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true
        )
        try rotateIfNeeded(forAdditionalBytes: UInt64(data.count))

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func redact(_ value: String) -> String {
        var result = value

        secretLock.lock()
        let secrets = registeredSecrets.sorted { $0.count > $1.count }
        secretLock.unlock()
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(
                of: secret,
                with: "<redacted-api-key>"
            )
        }

        for rule in Self.redactionRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.template
            )
        }
        return result
    }

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: UInt64) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let existingSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard existingSize > 0, existingSize + additionalBytes > maxFileSize else { return }

        if retainedFileCount == 0 {
            try? FileManager.default.removeItem(at: logFileURL)
            return
        }

        try? FileManager.default.removeItem(at: archivedLogFileURL(index: retainedFileCount))
        if retainedFileCount > 1 {
            for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
                let source = archivedLogFileURL(index: index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.moveItem(
                    at: source,
                    to: archivedLogFileURL(index: index + 1)
                )
            }
        }
        try FileManager.default.moveItem(at: logFileURL, to: archivedLogFileURL(index: 1))
    }

    private static let redactionRules: [(expression: NSRegularExpression, template: String)] = {
        let patterns = [
            (#"sk-[A-Za-z0-9_-]{8,}"#, "<redacted-api-key>"),
            (#"(?i)(Bearer\s+)[^\s\"']+"#, "$1<redacted-api-key>"),
            (#"(?i)(OPENAI_API_KEY\s*[=:]\s*)[^\s\"']+"#, "$1<redacted-api-key>"),
            (
                #"(?i)(\"?(?:api[_-]?key)\"?\s*[:=]\s*\"?)[^\"\s,}]+"#,
                "$1<redacted-api-key>"
            )
        ]
        return patterns.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return (expression, template)
        }
    }()
}

private struct PendingDiagnosticRecord: Sendable {
    let level: DiagnosticLogLevel
    let component: String
    let event: String
    let operationID: UUID?
    let failure: DiagnosticFailure?
    let details: [String: DiagnosticValue]
    let sourceFile: String?
    let sourceFunction: String?
    let sourceLine: UInt?
    let stackTrace: [String]?
}

private struct DiagnosticLogRecord: Encodable {
    let timestamp: Date
    let level: DiagnosticLogLevel
    let component: String
    let event: String
    let applicationSessionID: String
    let operationID: String?
    let failure: DiagnosticFailure?
    let details: [String: DiagnosticValue]?
    let sourceFile: String?
    let sourceFunction: String?
    let sourceLine: UInt?
    let stackTrace: [String]?
}

private struct DiagnosticSessionMarker: Codable {
    let sessionID: String
    let startedAt: String
}
