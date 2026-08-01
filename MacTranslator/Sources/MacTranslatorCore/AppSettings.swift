import Foundation

public enum OpenAIReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

public struct OpenAIModelProfile: Equatable, Sendable {
    public let model: String
    public let reasoningEffort: OpenAIReasoningEffort

    public init(model: String, reasoningEffort: OpenAIReasoningEffort) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum AppSettings {
    public static let modelKey = "openaiModel"
    public static let learningAnalysisModelKey = "learningAnalysisModel"
    public static let learningAnalysisReasoningEffortKey = "learningAnalysisReasoningEffort"
    public static let learningInteractiveModelKey = "learningInteractiveModel"
    public static let learningInteractiveReasoningEffortKey = "learningInteractiveReasoningEffort"
    public static let composerHeightKey = "composerHeight"
    public static let mainSidebarExpandedKey = "mainSidebarExpanded"
    public static let defaultModel = "gpt-5.4-mini"
    public static let defaultLearningAnalysisModel = "gpt-5.6-terra"
    public static let defaultLearningAnalysisReasoningEffort = OpenAIReasoningEffort.high
    public static let defaultLearningInteractiveModel = "gpt-5.6-luna"
    public static let defaultLearningInteractiveReasoningEffort = OpenAIReasoningEffort.medium

    public static func resolvedModel(
        _ configuredModel: String?,
        fallback: String = defaultModel
    ) -> String {
        let model = configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? fallback : model
    }

    public static func resolvedReasoningEffort(
        _ configuredEffort: String?,
        fallback: OpenAIReasoningEffort
    ) -> OpenAIReasoningEffort {
        guard let configuredEffort else { return fallback }
        return OpenAIReasoningEffort(rawValue: configuredEffort) ?? fallback
    }
}
