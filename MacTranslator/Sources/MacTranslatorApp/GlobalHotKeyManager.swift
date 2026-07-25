import AppKit
import Carbon
import MacTranslatorCore

final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    @discardableResult
    func reloadFromPreferences() -> OSStatus {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }

        guard GlobalShortcutPreferences.isEnabled() else {
            DiagnosticLogger.shared.event(
                "global_shortcut_disabled",
                component: "shortcut"
            )
            return noErr
        }

        let shortcut = GlobalShortcutPreferences.load()
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4D54524E), // MTRN
            id: 1
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(for: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        DiagnosticLogger.shared.event(
            status == noErr ? "global_shortcut_registered" : "global_shortcut_registration_failed",
            level: status == noErr ? .info : .error,
            component: "shortcut",
            failure: status == noErr
                ? nil
                : DiagnosticFailure(
                    statusCode: nil,
                    errorDomain: "Carbon.HotKey",
                    errorCode: Int(status),
                    message: "RegisterEventHotKey returned \(status)"
                ),
            details: [
                "key_code": .integer(Int(shortcut.keyCode)),
                "key_name": .string(shortcut.keyName),
                "modifiers": .integer(shortcut.modifiers.rawValue)
            ]
        )
        return status
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DiagnosticLogger.shared.event(
                    "global_shortcut_pressed",
                    component: "shortcut"
                )
                manager.showApplication()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        DiagnosticLogger.shared.event(
            status == noErr
                ? "global_shortcut_handler_installed"
                : "global_shortcut_handler_install_failed",
            level: status == noErr ? .info : .error,
            component: "shortcut",
            failure: status == noErr
                ? nil
                : DiagnosticFailure(
                    statusCode: nil,
                    errorDomain: "Carbon.EventHandler",
                    errorCode: Int(status),
                    message: "InstallEventHandler returned \(status)"
                )
        )
    }

    private func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func showApplication() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title == "Mac Translator" }) {
                let wasMinimized = window.isMiniaturized
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                DiagnosticLogger.shared.event(
                    "application_window_shown",
                    component: "shortcut",
                    details: [
                        "was_minimized": .boolean(wasMinimized),
                        "window_count": .integer(NSApp.windows.count)
                    ]
                )
            } else {
                DiagnosticLogger.shared.event(
                    "application_window_not_found",
                    level: .warning,
                    component: "shortcut",
                    details: ["window_count": .integer(NSApp.windows.count)]
                )
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        DiagnosticLogger.shared.startApplicationSession(
            details: [
                "app_version": .string(
                    bundle.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown"
                ),
                "build": .string(
                    bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                        ?? "unknown"
                ),
                "bundle_id": .string(bundle.bundleIdentifier ?? "unknown"),
                "os_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "architecture": .string(Self.architecture),
                "locale": .string(Locale.current.identifier),
                "process_id": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
                "log_path": .string(DiagnosticLogger.shared.logFileURL.path)
            ]
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shortcutStatus = GlobalHotKeyManager.shared.reloadFromPreferences()
        DiagnosticLogger.shared.event(
            "application_ready",
            component: "app",
            details: [
                "shortcut_status": .integer(Int(shortcutStatus)),
                "window_count": .integer(NSApp.windows.count)
            ]
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLogger.shared.endApplicationSession(
            details: ["window_count": .integer(NSApp.windows.count)]
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DiagnosticLogger.shared.event(
            "application_reopen_requested",
            component: "app",
            details: [
                "had_visible_windows": .boolean(flag),
                "window_count": .integer(sender.windows.count)
            ]
        )
        if let window = sender.windows.first(where: { $0.title == "Mac Translator" }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
