import Foundation

public enum PromptKind: String, CaseIterable, Identifiable, Sendable {
    case translate
    case correct
    case slack

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .translate: "Default"
        case .correct: "T / Correction"
        case .slack: "S / Slack"
        }
    }

    public var commandDescription: String {
        switch self {
        case .translate: "Used when the message has no command prefix."
        case .correct: "Used when the message starts with t followed by a space."
        case .slack: "Used when the message starts with s followed by a space."
        }
    }

    public var defaultsKey: String {
        "prompt.\(rawValue)"
    }

    public var defaultPrompt: String {
        switch self {
        case .translate: TranslationPrompts.translate
        case .correct: TranslationPrompts.correct
        case .slack: TranslationPrompts.slack
        }
    }
}

public struct PromptConfiguration: Sendable {
    public var translate: String
    public var correct: String
    public var slack: String

    public init(translate: String, correct: String, slack: String) {
        self.translate = translate
        self.correct = correct
        self.slack = slack
    }

    public static let defaults = PromptConfiguration(
        translate: TranslationPrompts.translate,
        correct: TranslationPrompts.correct,
        slack: TranslationPrompts.slack
    )

    public static func stored(in defaults: UserDefaults = .standard) -> PromptConfiguration {
        PromptConfiguration(
            translate: defaults.string(forKey: PromptKind.translate.defaultsKey)
                ?? TranslationPrompts.translate,
            correct: defaults.string(forKey: PromptKind.correct.defaultsKey)
                ?? TranslationPrompts.correct,
            slack: defaults.string(forKey: PromptKind.slack.defaultsKey)
                ?? TranslationPrompts.slack
        )
    }

    public func prompt(for mode: CommandMode) -> String {
        switch mode {
        case .translate: translate
        case .correct: correct
        case .slack: slack
        }
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(translate, forKey: PromptKind.translate.defaultsKey)
        defaults.set(correct, forKey: PromptKind.correct.defaultsKey)
        defaults.set(slack, forKey: PromptKind.slack.defaultsKey)
    }
}
