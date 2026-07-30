import AppKit
import MacTranslatorCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingResetLearningConfirmation = false
    @State private var showingDeleteLearningConfirmation = false
    @State private var showingKeychainReconnect = false
    @State private var keychainReconnectShouldSave = false
    @State private var isManagingLearningData = false

    private let keychain = KeychainStore()
    private let learningEngine = LearningEngine()
    private let diagnosticLogger = DiagnosticLogger.shared

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

                learningSettings
                    .tabItem {
                        Label("Learning", systemImage: "graduationcap")
                    }

                diagnosticsSettings
                    .tabItem {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
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
            diagnosticLogger.event(
                "settings_opened",
                component: "settings"
            )
            loadSettings()
        }
        .confirmationDialog(
            "Reset learning progress?",
            isPresented: $showingResetLearningConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Progress", role: .destructive) {
                resetLearningProgress()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Extracted weaknesses stay available, but practice attempts and mastery progress start again.")
        }
        .confirmationDialog(
            "Delete all learning data?",
            isPresented: $showingDeleteLearningConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Learning Data", role: .destructive) {
                deleteLearningData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the learning event history, progress, and derived examples. Chat history is not deleted.")
        }
        .alert(
            "Reconnect macOS login keychain?",
            isPresented: $showingKeychainReconnect
        ) {
            Button(keychainReconnectShouldSave ? "Reconnect and Save" : "Reconnect") {
                reconnectKeychain()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "macOS rejected access to the login keychain. Reconnecting briefly locks and unlocks it, then macOS asks for your Mac login password. Mac Translator never receives that password."
            )
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

                Text(
                    "Chat and Learn share this API key and model. The key is stored only in macOS Keychain. The default model is \(AppSettings.defaultModel)."
                )
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
                "Chat requests send only the current message. Learn separately analyzes new completed chat records in small incremental batches.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var learningSettings: some View {
        Form {
            Section("Personal English Teacher") {
                Label(
                    "Learning events and progress are stored locally in the same SQLite database as chat history.",
                    systemImage: "externaldrive.fill"
                )
                Text(
                    "The Learn page sends only new chat turns and a small set of recent, sanitized scenarios to generate a five-expression batch. The completed batch is graded in one request. It never sends the complete event archive."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Button("Rebuild Learning Profile") {
                    rebuildLearningProfile()
                }
                .disabled(isManagingLearningData)

                Text("Recreates the current profile from the immutable learning event history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset Learning Progress…") {
                    showingResetLearningConfirmation = true
                }
                .disabled(isManagingLearningData)

                Button("Delete All Learning Data…", role: .destructive) {
                    showingDeleteLearningConfirmation = true
                }
                .disabled(isManagingLearningData)
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private var diagnosticsSettings: some View {
        Form {
            Section("Runtime Logs") {
                Label(
                    "Mac Translator continuously records app actions, chat and learning requests, model responses, storage operations, retries, and errors.",
                    systemImage: "doc.text.magnifyingglass"
                )

                Text(
                    "Conversation text and model output are included so a problem can be diagnosed without reproducing it. OpenAI API keys are always redacted."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("Location") {
                    Text(diagnosticLogger.logFileURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            Section("Support") {
                Button("Export Diagnostic Log…") {
                    exportDiagnostics()
                }

                Button("Reveal Logs in Finder") {
                    revealDiagnostics()
                }

                Text(
                    "Logs rotate automatically and retain recent history, including detection of a previous unclean app exit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
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
        do {
            apiKey = try keychain.read() ?? ""
            if !apiKey.isEmpty {
                diagnosticLogger.registerSecret(apiKey)
            }
            diagnosticLogger.event(
                "settings_loaded",
                component: "settings",
                details: ["api_key_available": .boolean(!apiKey.isEmpty)]
            )
        } catch let error as KeychainError where error.requiresLoginKeychainReconnect {
            apiKey = ""
            statusMessage = "The macOS login keychain needs to be reconnected."
            isError = true
            keychainReconnectShouldSave = false
            showingKeychainReconnect = true
            diagnosticLogger.event(
                "settings_keychain_reconnect_required",
                level: .warning,
                component: "settings",
                failure: DiagnosticFailure.from(error)
            )
        } catch {
            apiKey = ""
            statusMessage = error.localizedDescription
            isError = true
            diagnosticLogger.event(
                "settings_load_failed",
                level: .error,
                component: "settings",
                failure: DiagnosticFailure.from(error)
            )
        }
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
        diagnosticLogger.event(
            "prompt_default_restored",
            component: "settings",
            details: ["prompt_kind": .string(selectedPrompt.rawValue)]
        )
    }

    private func save(offerKeychainReconnect: Bool = true) {
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
            diagnosticLogger.event(
                "settings_save_blocked",
                level: .warning,
                component: "settings",
                details: [
                    "reason": .string("empty_prompt"),
                    "translate_prompt": .string(prompts.translate),
                    "correct_prompt": .string(prompts.correct),
                    "slack_prompt": .string(prompts.slack)
                ]
            )
            return
        }

        do {
            diagnosticLogger.registerSecret(apiKey)
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
            diagnosticLogger.event(
                "settings_saved",
                component: "settings",
                details: [
                    "api_key_available": .boolean(!apiKey.isEmpty),
                    "model": .string(model),
                    "translate_prompt": .string(prompts.translate),
                    "correct_prompt": .string(prompts.correct),
                    "slack_prompt": .string(prompts.slack),
                    "global_shortcut_enabled": .boolean(globalShortcutEnabled),
                    "global_shortcut_key": .string(globalShortcut.keyName),
                    "global_shortcut_key_code": .integer(
                        Int(globalShortcut.keyCode)
                    ),
                    "global_shortcut_modifiers": .integer(
                        globalShortcut.modifiers.rawValue
                    )
                ]
            )
            NotificationCenter.default.post(name: .translatorCredentialsDidChange, object: nil)
        } catch let error as KeychainError
            where error.requiresLoginKeychainReconnect && offerKeychainReconnect {
            statusMessage = "The macOS login keychain needs to be reconnected."
            isError = true
            keychainReconnectShouldSave = true
            showingKeychainReconnect = true
            diagnosticLogger.event(
                "settings_save_requires_keychain_reconnect",
                level: .warning,
                component: "settings",
                failure: DiagnosticFailure.from(error)
            )
        } catch {
            statusMessage = error.localizedDescription
            isError = true
            diagnosticLogger.event(
                "settings_save_failed",
                level: .error,
                component: "settings",
                failure: DiagnosticFailure.from(error)
            )
        }
    }

    private func reconnectKeychain() {
        diagnosticLogger.event(
            "keychain_reconnect_started",
            component: "settings",
            details: ["save_after_reconnect": .boolean(keychainReconnectShouldSave)]
        )
        do {
            try keychain.reconnectDefaultKeychain()
            if keychainReconnectShouldSave {
                save(offerKeychainReconnect: false)
            } else {
                apiKey = try keychain.read() ?? ""
                statusMessage = "Keychain reconnected"
                isError = false
                NotificationCenter.default.post(
                    name: .translatorCredentialsDidChange,
                    object: nil
                )
            }
            diagnosticLogger.event(
                "keychain_reconnect_completed",
                component: "settings",
                details: [
                    "save_after_reconnect": .boolean(
                        keychainReconnectShouldSave
                    )
                ]
            )
        } catch {
            statusMessage = error.localizedDescription
            isError = true
            diagnosticLogger.event(
                "keychain_reconnect_failed",
                level: .error,
                component: "settings",
                failure: DiagnosticFailure.from(error)
            )
        }
    }

    private func rebuildLearningProfile() {
        manageLearningData(
            actionName: "rebuild_learning_profile",
            successMessage: "Learning profile rebuilt"
        ) {
            _ = try await learningEngine.rebuildProfile()
        }
    }

    private func resetLearningProgress() {
        manageLearningData(
            actionName: "reset_learning_progress",
            successMessage: "Learning progress reset"
        ) {
            _ = try await learningEngine.resetProgress()
        }
    }

    private func deleteLearningData() {
        manageLearningData(
            actionName: "delete_learning_data",
            successMessage: "Learning data deleted"
        ) {
            _ = try await learningEngine.deleteAllLearningData()
        }
    }

    private func manageLearningData(
        actionName: String,
        successMessage: String,
        action: @escaping @Sendable () async throws -> Void
    ) {
        guard !isManagingLearningData else { return }
        isManagingLearningData = true
        diagnosticLogger.event(
            "settings_learning_action_started",
            component: "settings",
            details: ["action": .string(actionName)]
        )
        Task {
            do {
                try await action()
                statusMessage = successMessage
                isError = false
                NotificationCenter.default.post(
                    name: .translatorLearningDataDidChange,
                    object: nil
                )
                diagnosticLogger.event(
                    "settings_learning_action_completed",
                    component: "settings",
                    details: ["action": .string(actionName)]
                )
            } catch {
                statusMessage = error.localizedDescription
                isError = true
                diagnosticLogger.event(
                    "settings_learning_action_failed",
                    level: .error,
                    component: "settings",
                    failure: DiagnosticFailure.from(error),
                    details: ["action": .string(actionName)]
                )
            }
            isManagingLearningData = false
        }
    }

    private func revealDiagnostics() {
        diagnosticLogger.event(
            "diagnostics_reveal_requested",
            component: "settings"
        )
        diagnosticLogger.flush()
        if FileManager.default.fileExists(
            atPath: diagnosticLogger.logFileURL.path
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([
                diagnosticLogger.logFileURL
            ])
        } else {
            NSWorkspace.shared.open(diagnosticLogger.logsDirectoryURL)
        }
    }

    private func exportDiagnostics() {
        diagnosticLogger.event(
            "diagnostics_export_requested",
            component: "settings"
        )
        diagnosticLogger.flush()

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Log"
        panel.prompt = "Export"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "jsonl") ?? .plainText
        ]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue =
            "MacTranslator-Diagnostics-\(formatter.string(from: Date())).jsonl"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            diagnosticLogger.event(
                "diagnostics_export_cancelled",
                component: "settings"
            )
            return
        }

        do {
            try diagnosticLogger.exportArchive(to: destinationURL)
            statusMessage = "Diagnostic log exported"
            isError = false
            diagnosticLogger.event(
                "diagnostics_export_completed",
                component: "settings",
                details: ["destination": .string(destinationURL.path)]
            )
        } catch {
            statusMessage = error.localizedDescription
            isError = true
            diagnosticLogger.event(
                "diagnostics_export_failed",
                level: .error,
                component: "settings",
                failure: DiagnosticFailure.from(error),
                details: ["destination": .string(destinationURL.path)]
            )
        }
    }
}
