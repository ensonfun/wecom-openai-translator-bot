import SwiftUI

@main
struct MacTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
        .defaultSize(width: 900, height: 760)

        Settings {
            SettingsView()
        }
    }
}
