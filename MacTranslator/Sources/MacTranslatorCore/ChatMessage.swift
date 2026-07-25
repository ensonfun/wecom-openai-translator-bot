import Foundation

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public let mode: CommandMode
    public let turnID: UUID?
    public let createdAt: Date
    public let origin: Origin

    public enum Origin: String, Codable, Sendable {
        case native
        case legacy
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        mode: CommandMode,
        turnID: UUID? = nil,
        createdAt: Date = Date(),
        origin: Origin = .native
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.mode = mode
        self.turnID = turnID
        self.createdAt = createdAt
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case mode
        case turnID
        case createdAt
        case origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        mode = try container.decode(CommandMode.self, forKey: .mode)
        turnID = try container.decodeIfPresent(UUID.self, forKey: .turnID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .legacy
    }
}

public struct ChatTurn: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case streaming
        case completed
        case failed
        case cancelled
    }

    public let id: UUID
    public let mode: CommandMode
    public let userMessageID: UUID
    public var assistantMessageID: UUID?
    public let createdAt: Date
    public var completedAt: Date?
    public var status: Status
    public let model: String
    public let promptFingerprint: String
    public let origin: ChatMessage.Origin

    public init(
        id: UUID,
        mode: CommandMode,
        userMessageID: UUID,
        assistantMessageID: UUID? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        status: Status,
        model: String,
        promptFingerprint: String,
        origin: ChatMessage.Origin = .native
    ) {
        self.id = id
        self.mode = mode
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.model = model
        self.promptFingerprint = promptFingerprint
        self.origin = origin
    }
}

public struct LearningSourceTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let mode: CommandMode
    public let userText: String
    public let assistantText: String?
    public let createdAt: Date
    public let origin: ChatMessage.Origin

    public init(
        id: UUID,
        mode: CommandMode,
        userText: String,
        assistantText: String?,
        createdAt: Date,
        origin: ChatMessage.Origin
    ) {
        self.id = id
        self.mode = mode
        self.userText = userText
        self.assistantText = assistantText
        self.createdAt = createdAt
        self.origin = origin
    }
}
