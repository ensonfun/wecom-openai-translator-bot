import Foundation

public final class DiagnosticLogger: @unchecked Sendable {
    public static let shared = DiagnosticLogger()

    public let logFileURL: URL

    private let maxFileSize: UInt64
    private let retainedFileCount: Int
    private let queue = DispatchQueue(label: "com.mario.MacTranslator.diagnostics")
    private let encoder: JSONEncoder

    public init(
        directoryURL: URL? = nil,
        maxFileSize: UInt64 = 1_048_576,
        retainedFileCount: Int = 5
    ) {
        let directory = directoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacTranslator", isDirectory: true)
        self.logFileURL = directory.appendingPathComponent("MacTranslator.log")
        self.maxFileSize = max(1, maxFileSize)
        self.retainedFileCount = max(0, retainedFileCount)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func requestStarted(requestID: UUID, attempt: Int) {
        write(.init(event: "request_started", requestID: requestID, attempt: attempt))
    }

    public func responseReceived(
        requestID: UUID,
        attempt: Int,
        statusCode: Int,
        openAIRequestID: String?
    ) {
        write(.init(
            event: "response_received",
            requestID: requestID,
            attempt: attempt,
            statusCode: statusCode,
            openAIRequestID: openAIRequestID
        ))
    }

    public func retryScheduled(
        requestID: UUID,
        attempt: Int,
        delayMilliseconds: Int,
        failure: DiagnosticFailure
    ) {
        write(.init(
            event: "retry_scheduled",
            requestID: requestID,
            attempt: attempt,
            statusCode: failure.statusCode,
            errorDomain: failure.errorDomain,
            errorCode: failure.errorCode,
            receivedText: false,
            retryDelayMilliseconds: delayMilliseconds
        ))
    }

    public func requestCompleted(
        requestID: UUID,
        attempt: Int,
        receivedText: Bool,
        durationMilliseconds: Int
    ) {
        write(.init(
            event: "request_completed",
            requestID: requestID,
            attempt: attempt,
            receivedText: receivedText,
            durationMilliseconds: durationMilliseconds
        ))
    }

    public func requestFailed(
        requestID: UUID,
        attempt: Int,
        receivedText: Bool,
        durationMilliseconds: Int,
        failure: DiagnosticFailure
    ) {
        write(.init(
            event: "request_failed",
            requestID: requestID,
            attempt: attempt,
            statusCode: failure.statusCode,
            errorDomain: failure.errorDomain,
            errorCode: failure.errorCode,
            receivedText: receivedText,
            durationMilliseconds: durationMilliseconds
        ))
    }

    public func flush() {
        queue.sync {}
    }

    public func archivedLogFileURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(logFileURL.path).\(index)")
    }

    private func write(_ record: DiagnosticLogRecord) {
        queue.async { [self] in
            do {
                var data = try encoder.encode(record)
                data.append(0x0A)
                try FileManager.default.createDirectory(
                    at: logFileURL.deletingLastPathComponent(),
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
            } catch {
                // Diagnostic logging must never interfere with sending a message.
            }
        }
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
}

public struct DiagnosticFailure: Sendable {
    public let statusCode: Int?
    public let errorDomain: String?
    public let errorCode: Int?

    public init(statusCode: Int?, errorDomain: String?, errorCode: Int?) {
        self.statusCode = statusCode
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

private struct DiagnosticLogRecord: Encodable {
    let timestamp: Date
    let event: String
    let requestID: String
    let attempt: Int?
    let statusCode: Int?
    let openAIRequestID: String?
    let errorDomain: String?
    let errorCode: Int?
    let receivedText: Bool?
    let retryDelayMilliseconds: Int?
    let durationMilliseconds: Int?

    init(
        event: String,
        requestID: UUID,
        attempt: Int? = nil,
        statusCode: Int? = nil,
        openAIRequestID: String? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        receivedText: Bool? = nil,
        retryDelayMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.timestamp = Date()
        self.event = event
        self.requestID = requestID.uuidString
        self.attempt = attempt
        self.statusCode = statusCode
        self.openAIRequestID = openAIRequestID
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.receivedText = receivedText
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.durationMilliseconds = durationMilliseconds
    }
}
