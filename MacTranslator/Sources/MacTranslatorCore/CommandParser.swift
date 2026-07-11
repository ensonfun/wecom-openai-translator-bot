import Foundation

public enum CommandMode: String, Codable, CaseIterable, Sendable {
    case translate
    case correct
    case slack

    public var title: String {
        switch self {
        case .translate: "Translation"
        case .correct: "Correction"
        case .slack: "Slack"
        }
    }

    public var commandHint: String {
        switch self {
        case .translate: "No prefix"
        case .correct: "t + space"
        case .slack: "s + space"
        }
    }
}

public struct ParsedCommand: Equatable, Sendable {
    public let mode: CommandMode
    public let userText: String
    public let instructions: String?
    public let cleanedText: String

    public init(mode: CommandMode, userText: String, instructions: String?, cleanedText: String) {
        self.mode = mode
        self.userText = userText
        self.instructions = instructions
        self.cleanedText = cleanedText
    }
}

public enum CommandParser {
    public static func parse(
        _ text: String,
        prompts: PromptConfiguration = .defaults
    ) -> ParsedCommand {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let characters = Array(cleaned)
        if characters.count > 2, characters[1] == " " {
            let prefix = String(characters[0]).lowercased()
            let userText = String(characters.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)

            if prefix == "t" {
                return ParsedCommand(
                    mode: .correct,
                    userText: userText,
                    instructions: prompts.correct,
                    cleanedText: cleaned
                )
            }

            if prefix == "s" {
                return ParsedCommand(
                    mode: .slack,
                    userText: userText,
                    instructions: prompts.slack,
                    cleanedText: cleaned
                )
            }
        }

        return ParsedCommand(
            mode: .translate,
            userText: cleaned,
            instructions: prompts.translate,
            cleanedText: cleaned
        )
    }
}
