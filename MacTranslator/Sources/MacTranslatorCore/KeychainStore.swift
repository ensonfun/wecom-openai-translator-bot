import Foundation
import Security

public enum KeychainError: LocalizedError {
    case authenticationFailed
    case unexpectedStatus(OSStatus)

    public static func from(status: OSStatus) -> KeychainError {
        status == errSecAuthFailed
            ? .authenticationFailed
            : .unexpectedStatus(status)
    }

    public var requiresLoginKeychainReconnect: Bool {
        if case .authenticationFailed = self {
            return true
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "macOS could not unlock your login keychain. Reconnect it and try again. (\(errSecAuthFailed))"
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain error: \(message) (\(status))"
        }
    }
}

public struct KeychainStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.mario.MacTranslator",
        account: String = "openai-api-key"
    ) {
        self.service = service
        self.account = account
    }

    public func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.from(status: status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete()
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = baseQuery
            newItem[kSecValueData as String] = Data(trimmed.utf8)
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.from(status: addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainError.from(status: updateStatus)
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status: status)
        }
    }

    /// Repairs the stale authentication state seen in the legacy login keychain
    /// on recent macOS releases. The unlock call presents a system-owned password
    /// prompt, so the app never receives the user's Mac login password.
    public func reconnectDefaultKeychain() throws {
        let lockStatus = SecKeychainLock(nil)
        guard lockStatus == errSecSuccess else {
            throw KeychainError.from(status: lockStatus)
        }

        let unlockStatus = SecKeychainUnlock(nil, 0, nil, false)
        guard unlockStatus == errSecSuccess else {
            throw KeychainError.from(status: unlockStatus)
        }
    }
}
