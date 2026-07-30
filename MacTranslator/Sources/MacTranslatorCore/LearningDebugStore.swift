import Foundation

public extension Notification.Name {
    static let translatorLearningDebugDidChange = Notification.Name(
        "translatorLearningDebugDidChange"
    )
}

public enum LearningDebugRequestStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
}

public struct LearningTokenUsage: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedInputTokens: Int?
    public let reasoningOutputTokens: Int?

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        cachedInputTokens: Int?,
        reasoningOutputTokens: Int?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

public struct LearningDebugEntry: Identifiable, Sendable {
    public let id: UUID
    public let flow: String
    public let model: String
    public let instructions: String
    public let input: String
    public let response: String?
    public let tokenUsage: LearningTokenUsage?
    public let status: LearningDebugRequestStatus
    public let attempt: Int
    public let startedAt: Date
    public let updatedAt: Date
    public let durationMilliseconds: Int?
    public let errorMessage: String?

    public init(
        id: UUID,
        flow: String,
        model: String,
        instructions: String,
        input: String,
        response: String?,
        tokenUsage: LearningTokenUsage?,
        status: LearningDebugRequestStatus,
        attempt: Int,
        startedAt: Date,
        updatedAt: Date,
        durationMilliseconds: Int?,
        errorMessage: String?
    ) {
        self.id = id
        self.flow = flow
        self.model = model
        self.instructions = instructions
        self.input = input
        self.response = response
        self.tokenUsage = tokenUsage
        self.status = status
        self.attempt = attempt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.durationMilliseconds = durationMilliseconds
        self.errorMessage = errorMessage
    }
}

public final class LearningDebugStore: @unchecked Sendable {
    public static let shared = LearningDebugStore()

    private let lock = NSLock()
    private let maxEntries: Int
    private var entriesByID: [UUID: LearningDebugEntry] = [:]

    public init(maxEntries: Int = 40) {
        self.maxEntries = max(1, maxEntries)
    }

    public func requestStarted(
        requestID: UUID,
        flow: String,
        model: String,
        instructions: String,
        input: String,
        attempt: Int
    ) {
        guard Self.isLearningFlow(flow) else { return }
        let now = Date()
        lock.lock()
        let existing = entriesByID[requestID]
        entriesByID[requestID] = LearningDebugEntry(
            id: requestID,
            flow: flow,
            model: model,
            instructions: instructions,
            input: input,
            response: existing?.response,
            tokenUsage: existing?.tokenUsage,
            status: .running,
            attempt: attempt,
            startedAt: existing?.startedAt ?? now,
            updatedAt: now,
            durationMilliseconds: existing?.durationMilliseconds,
            errorMessage: nil
        )
        trimIfNeeded()
        lock.unlock()
        notifyObservers()
    }

    public func requestCompleted(
        requestID: UUID,
        response: String,
        tokenUsage: LearningTokenUsage?,
        attempt: Int,
        durationMilliseconds: Int
    ) {
        update(
            requestID: requestID,
            response: response,
            tokenUsage: tokenUsage,
            status: .completed,
            attempt: attempt,
            durationMilliseconds: durationMilliseconds,
            errorMessage: nil
        )
    }

    public func requestFailed(
        requestID: UUID,
        response: String?,
        tokenUsage: LearningTokenUsage? = nil,
        attempt: Int,
        durationMilliseconds: Int,
        errorMessage: String
    ) {
        update(
            requestID: requestID,
            response: response,
            tokenUsage: tokenUsage,
            status: .failed,
            attempt: attempt,
            durationMilliseconds: durationMilliseconds,
            errorMessage: errorMessage
        )
    }

    public func entries() -> [LearningDebugEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByID.values.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.id.uuidString > $1.id.uuidString
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func clear() {
        lock.lock()
        entriesByID.removeAll()
        lock.unlock()
        notifyObservers()
    }

    private func update(
        requestID: UUID,
        response: String?,
        tokenUsage: LearningTokenUsage?,
        status: LearningDebugRequestStatus,
        attempt: Int,
        durationMilliseconds: Int,
        errorMessage: String?
    ) {
        let now = Date()
        lock.lock()
        guard let existing = entriesByID[requestID] else {
            lock.unlock()
            return
        }
        entriesByID[requestID] = LearningDebugEntry(
            id: existing.id,
            flow: existing.flow,
            model: existing.model,
            instructions: existing.instructions,
            input: existing.input,
            response: response ?? existing.response,
            tokenUsage: tokenUsage ?? existing.tokenUsage,
            status: status,
            attempt: attempt,
            startedAt: existing.startedAt,
            updatedAt: now,
            durationMilliseconds: durationMilliseconds,
            errorMessage: errorMessage
        )
        lock.unlock()
        notifyObservers()
    }

    private func trimIfNeeded() {
        guard entriesByID.count > maxEntries else { return }
        let entriesToRemove = entriesByID.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(entriesByID.count - maxEntries)
        for entry in entriesToRemove {
            entriesByID.removeValue(forKey: entry.id)
        }
    }

    private func notifyObservers() {
        NotificationCenter.default.post(
            name: .translatorLearningDebugDidChange,
            object: self
        )
    }

    private static func isLearningFlow(_ flow: String) -> Bool {
        flow.hasPrefix("learning_")
    }
}
