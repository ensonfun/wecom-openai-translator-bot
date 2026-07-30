import Foundation

public enum AppSettings {
    public static let modelKey = "openaiModel"
    public static let composerHeightKey = "composerHeight"
    public static let mainSidebarExpandedKey = "mainSidebarExpanded"
    public static let defaultModel = "gpt-5.4-mini"

    public static func resolvedModel(_ configuredModel: String?) -> String {
        let model = configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if model.isEmpty {
            return defaultModel
        }
        return model
    }
}
