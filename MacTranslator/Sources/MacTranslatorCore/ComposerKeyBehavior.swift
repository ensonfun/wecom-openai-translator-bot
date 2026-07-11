public enum ComposerKeyAction: Equatable, Sendable {
    case send
    case insertNewline
    case passThrough
}

public enum ComposerKeyBehavior {
    public static func action(
        isReturnKey: Bool,
        hasMarkedText: Bool,
        shiftPressed: Bool,
        commandPressed: Bool
    ) -> ComposerKeyAction {
        guard isReturnKey else { return .passThrough }
        guard !hasMarkedText else { return .passThrough }
        if shiftPressed || commandPressed {
            return .insertNewline
        }
        return .send
    }
}
