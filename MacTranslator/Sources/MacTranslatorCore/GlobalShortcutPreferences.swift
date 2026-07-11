import Foundation

public struct ShortcutModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
}

public struct GlobalShortcut: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public var keyName: String

    public init(keyCode: UInt32, modifiers: ShortcutModifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    public static let `default` = GlobalShortcut(
        keyCode: 46,
        modifiers: [.control, .option],
        keyName: "M"
    )
}

public enum GlobalShortcutPreferences {
    public static let enabledKey = "globalShortcut.enabled"
    public static let keyCodeKey = "globalShortcut.keyCode"
    public static let modifiersKey = "globalShortcut.modifiers"
    public static let keyNameKey = "globalShortcut.keyName"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func load(in defaults: UserDefaults = .standard) -> GlobalShortcut {
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return .default
        }
        return GlobalShortcut(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: ShortcutModifiers(rawValue: defaults.integer(forKey: modifiersKey)),
            keyName: defaults.string(forKey: keyNameKey) ?? "Key"
        )
    }

    public static func save(
        enabled: Bool,
        shortcut: GlobalShortcut,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(shortcut.modifiers.rawValue, forKey: modifiersKey)
        defaults.set(shortcut.keyName, forKey: keyNameKey)
    }
}
