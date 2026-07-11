import AppKit
import MacTranslatorCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.startRecording(_:))
        button.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event)
        }
        context.coordinator.button = button
        button.title = shortcut.displayName
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.parent = self
        if !button.isRecording {
            button.title = shortcut.displayName
        }
    }

    final class Coordinator: NSObject {
        var parent: ShortcutRecorder
        weak var button: RecorderButton?
        private var eventMonitor: Any?

        init(parent: ShortcutRecorder) {
            self.parent = parent
        }

        deinit {
            removeEventMonitor()
        }

        @objc func startRecording(_ sender: RecorderButton) {
            sender.isRecording = true
            sender.title = "Press shortcut…"
            sender.window?.makeFirstResponder(sender)
            removeEventMonitor()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.button?.isRecording == true else { return event }
                self.handle(event)
                return nil
            }
        }

        func handle(_ event: NSEvent) {
            guard let button else { return }
            if event.keyCode == 53 {
                finishRecording(button)
                return
            }

            let modifiers = ShortcutModifiers(event.modifierFlags)
            guard modifiers.contains(.command)
                    || modifiers.contains(.control)
                    || modifiers.contains(.option) else {
                NSSound.beep()
                return
            }

            guard let keyName = Self.keyName(for: event) else {
                NSSound.beep()
                return
            }

            parent.shortcut = GlobalShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                keyName: keyName
            )
            finishRecording(button)
        }

        private func finishRecording(_ button: RecorderButton) {
            button.isRecording = false
            button.title = parent.shortcut.displayName
            button.window?.makeFirstResponder(nil)
            removeEventMonitor()
        }

        private func removeEventMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private static func keyName(for event: NSEvent) -> String? {
            switch event.keyCode {
            case 36, 76: return "Return"
            case 48: return "Tab"
            case 49: return "Space"
            case 51: return "Delete"
            case 53: return "Escape"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default:
                let value = event.charactersIgnoringModifiers?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                return value?.isEmpty == false ? value : nil
            }
        }
    }
}

final class RecorderButton: NSButton {
    var isRecording = false
    var keyHandler: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            keyHandler?(event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            keyHandler?(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }
}

private extension GlobalShortcut {
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyName
    }
}
