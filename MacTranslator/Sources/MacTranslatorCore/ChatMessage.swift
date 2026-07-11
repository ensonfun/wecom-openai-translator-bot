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

    public init(id: UUID = UUID(), role: Role, text: String, mode: CommandMode) {
        self.id = id
        self.role = role
        self.text = text
        self.mode = mode
    }
}
