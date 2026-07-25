import Foundation
import MacTranslatorCore

enum SharedOpenAIConfiguration {
    static func apiKey(from keychain: KeychainStore) -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return environmentKey
        }

        guard let keychainKey = try? keychain.read() else {
            return nil
        }
        let trimmedKey = keychainKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    static var model: String {
        AppSettings.resolvedModel(
            UserDefaults.standard.string(forKey: AppSettings.modelKey)
        )
    }
}
