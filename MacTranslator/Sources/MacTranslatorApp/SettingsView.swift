import MacTranslatorCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @State private var apiKey = ""
    @State private var showAPIKey = false
    @State private var globalShortcutEnabled = false
    @State private var globalShortcut = GlobalShortcut.default
    @State private var selectedPrompt: PromptKind = .translate
    @State private var translatePrompt = TranslationPrompts.translate
    @State private var correctPrompt = TranslationPrompts.correct
    @State private var slackPrompt = TranslationPrompts.slack
    @State private var statusMessage: String?
    @State private var isError = false

    private let keychain = KeychainStore()

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalSettings
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }

                openAISettings
                    .tabItem {
                        Label("OpenAI", systemImage: "key")
                    }

                promptSettings
                    .tabItem {
                        Label("Prompts", systemImage: "text.quote")
                    }
            }

            Divider()

            HStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .green)
                }
                Spacer()
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 600)
        .onAppear {
            loadSettings()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Keyboard") {
                Toggle("Enable global shortcut", isOn: $globalShortcutEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show Mac Translator")
                        Text("Works from any app while Mac Translator is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: $globalShortcut)
                        .frame(width: 150, height: 28)
                        .disabled(!globalShortcutEnabled)
                }

                Text("Click the shortcut field, then press a combination containing Command, Control, or Option. Press Escape to cancel recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Composer") {
                LabeledContent("Send message", value: "Return")
                LabeledContent("Insert new line", value: "Shift+Return or Command+Return")
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private var openAISettings: some View {
        Form {
            Section("OpenAI") {
                HStack {
                    if showAPIKey {
                        TextField("sk-…", text: $apiKey)
                    } else {
                        SecureField("sk-…", text: $apiKey)
                    }
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(showAPIKey ? "Hide API Key" : "Show API Key")
                }

                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)

                Text("Your API key is stored only in macOS Keychain. The default model is \(AppSettings.defaultModel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private var promptSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Prompt", selection: $selectedPrompt) {
                ForEach(PromptKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedPrompt.title)
                        .font(.headline)
                    Text(selectedPrompt.commandDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Default") {
                    restoreSelectedPrompt()
                }
            }

            TextEditor(text: selectedPromptBinding)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.12))
                }

            Label(
                "Each request sends only the current message with the selected prompt. Chat history is never included.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var selectedPromptBinding: Binding<String> {
        Binding(
            get: {
                switch selectedPrompt {
                case .translate: translatePrompt
                case .correct: correctPrompt
                case .slack: slackPrompt
                }
            },
            set: { value in
                switch selectedPrompt {
                case .translate: translatePrompt = value
                case .correct: correctPrompt = value
                case .slack: slackPrompt = value
                }
            }
        )
    }

    private func loadSettings() {
        apiKey = (try? keychain.read()) ?? ""
        globalShortcutEnabled = GlobalShortcutPreferences.isEnabled()
        globalShortcut = GlobalShortcutPreferences.load()
        let prompts = PromptConfiguration.stored()
        translatePrompt = prompts.translate
        correctPrompt = prompts.correct
        slackPrompt = prompts.slack
    }

    private func restoreSelectedPrompt() {
        switch selectedPrompt {
        case .translate: translatePrompt = TranslationPrompts.translate
        case .correct: correctPrompt = TranslationPrompts.correct
        case .slack: slackPrompt = TranslationPrompts.slack
        }
        statusMessage = "Default restored. Save to apply."
        isError = false
    }

    private func save() {
        let prompts = PromptConfiguration(
            translate: translatePrompt,
            correct: correctPrompt,
            slack: slackPrompt
        )
        guard [prompts.translate, prompts.correct, prompts.slack].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            statusMessage = "Prompts cannot be empty."
            isError = true
            return
        }

        do {
            try keychain.save(apiKey)
            model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty {
                model = AppSettings.defaultModel
            }
            prompts.save()
            GlobalShortcutPreferences.save(
                enabled: globalShortcutEnabled,
                shortcut: globalShortcut
            )
            let shortcutStatus = GlobalHotKeyManager.shared.reloadFromPreferences()
            guard shortcutStatus == 0 else {
                statusMessage = "That global shortcut is unavailable. Choose another combination."
                isError = true
                return
            }
            statusMessage = "Saved"
            isError = false
            NotificationCenter.default.post(name: .translatorCredentialsDidChange, object: nil)
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }
}
