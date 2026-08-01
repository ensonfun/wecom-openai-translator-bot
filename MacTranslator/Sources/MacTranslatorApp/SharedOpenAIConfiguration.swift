import Foundation
import MacTranslatorCore

enum SharedOpenAIConfiguration {
    static func apiKey(from keychain: KeychainStore) -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            DiagnosticLogger.shared.registerSecret(environmentKey)
            return environmentKey
        }

        let keychainKey: String?
        do {
            keychainKey = try keychain.read()
        } catch {
            DiagnosticLogger.shared.event(
                "keychain_read_failed",
                level: .error,
                component: "keychain",
                failure: DiagnosticFailure.from(error)
            )
            return nil
        }
        guard let keychainKey else { return nil }
        let trimmedKey = keychainKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            DiagnosticLogger.shared.registerSecret(trimmedKey)
        }
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    static var model: String {
        AppSettings.resolvedModel(
            UserDefaults.standard.string(forKey: AppSettings.modelKey)
        )
    }

    static var learningAnalysisProfile: OpenAIModelProfile {
        let defaults = UserDefaults.standard
        return OpenAIModelProfile(
            model: AppSettings.resolvedModel(
                defaults.string(forKey: AppSettings.learningAnalysisModelKey),
                fallback: AppSettings.defaultLearningAnalysisModel
            ),
            reasoningEffort: AppSettings.resolvedReasoningEffort(
                defaults.string(forKey: AppSettings.learningAnalysisReasoningEffortKey),
                fallback: AppSettings.defaultLearningAnalysisReasoningEffort
            )
        )
    }

    static var learningInteractiveProfile: OpenAIModelProfile {
        let defaults = UserDefaults.standard
        return OpenAIModelProfile(
            model: AppSettings.resolvedModel(
                defaults.string(forKey: AppSettings.learningInteractiveModelKey),
                fallback: AppSettings.defaultLearningInteractiveModel
            ),
            reasoningEffort: AppSettings.resolvedReasoningEffort(
                defaults.string(forKey: AppSettings.learningInteractiveReasoningEffortKey),
                fallback: AppSettings.defaultLearningInteractiveReasoningEffort
            )
        )
    }
}
