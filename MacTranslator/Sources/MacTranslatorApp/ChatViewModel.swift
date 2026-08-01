import AppKit
import Combine
import Foundation
import MacTranslatorCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let translatorCredentialsDidChange = Notification.Name("translatorCredentialsDidChange")
    static let translatorChatHistoryDidChange = Notification.Name("translatorChatHistoryDidChange")
    static let translatorLearningDataDidChange = Notification.Name("translatorLearningDataDidChange")
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var hasAPIKey = false
    @Published var errorMessage: String?

    private let keychain: KeychainStore
    private let client: OpenAIClient
    private let historyStore: ChatHistoryStore
    private let diagnosticLogger: DiagnosticLogger
    private let historyQueue = DispatchQueue(label: "com.mario.MacTranslator.history", qos: .utility)
    private var pendingTextUpdates: [UUID: DispatchWorkItem] = [:]
    private var requestTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        keychain: KeychainStore = KeychainStore(),
        client: OpenAIClient = OpenAIClient(),
        historyStore: ChatHistoryStore = ChatHistoryStore(),
        diagnosticLogger: DiagnosticLogger = .shared
    ) {
        self.keychain = keychain
        self.client = client
        self.historyStore = historyStore
        self.diagnosticLogger = diagnosticLogger

        do {
            messages = try historyStore.load()
            diagnosticLogger.event(
                "chat_history_loaded",
                component: "chat",
                details: [
                    "message_count": .integer(messages.count),
                    "database_path": .string(historyStore.databaseURL.path)
                ]
            )
        } catch {
            messages = []
            errorMessage = error.localizedDescription
            diagnosticLogger.event(
                "chat_history_load_failed",
                level: .error,
                component: "chat",
                failure: DiagnosticFailure.from(error),
                details: [
                    "database_path": .string(historyStore.databaseURL.path)
                ]
            )
        }

        refreshCredentials()
        NotificationCenter.default.publisher(for: .translatorCredentialsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshCredentials()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushHistory()
            }
            .store(in: &cancellables)
    }

    var currentMode: CommandMode {
        CommandParser.parse(input).mode
    }

    func refreshCredentials() {
        hasAPIKey = resolvedAPIKey() != nil
        diagnosticLogger.event(
            "credential_availability_checked",
            component: "chat",
            details: ["api_key_available": .boolean(hasAPIKey)]
        )
    }

    func send() {
        let command = CommandParser.parse(
            input,
            prompts: PromptConfiguration.stored()
        )
        guard !command.cleanedText.isEmpty else {
            diagnosticLogger.event(
                "chat_send_ignored",
                level: .debug,
                component: "chat",
                details: ["reason": .string("empty_input")]
            )
            return
        }
        guard !command.userText.isEmpty, let instructions = command.instructions else {
            diagnosticLogger.event(
                "chat_send_ignored",
                level: .warning,
                component: "chat",
                details: [
                    "reason": .string("command_without_body"),
                    "input": .string(input)
                ]
            )
            return
        }
        guard let apiKey = resolvedAPIKey(), !apiKey.isEmpty else {
            errorMessage = "Save your OpenAI API key in Settings before sending a message."
            hasAPIKey = false
            diagnosticLogger.event(
                "chat_send_blocked",
                level: .warning,
                component: "chat",
                details: [
                    "reason": .string("missing_api_key"),
                    "mode": .string(command.mode.rawValue),
                    "input": .string(command.userText)
                ]
            )
            return
        }

        errorMessage = nil
        input = ""

        let model = SharedOpenAIConfiguration.model
        let turnID = UUID()
        let createdAt = Date()
        let userMessage = ChatMessage(
            role: .user,
            text: command.userText,
            mode: command.mode,
            turnID: turnID,
            createdAt: createdAt
        )
        messages.append(userMessage)
        persistNewMessage(userMessage, position: messages.count - 1)

        let responseID = UUID()
        let responseMessage = ChatMessage(
            id: responseID,
            role: .assistant,
            text: "",
            mode: command.mode,
            turnID: turnID,
            createdAt: createdAt
        )
        messages.append(responseMessage)
        persistNewMessage(responseMessage, position: messages.count - 1)
        let turn = ChatTurn(
            id: turnID,
            mode: command.mode,
            userMessageID: userMessage.id,
            assistantMessageID: responseID,
            createdAt: createdAt,
            status: .streaming,
            model: model,
            promptFingerprint: PromptFingerprint.make(instructions)
        )
        diagnosticLogger.event(
            "chat_turn_started",
            component: "chat",
            operationID: turnID,
            details: [
                "mode": .string(command.mode.rawValue),
                "model": .string(model),
                "input": .string(command.userText),
                "instructions": .string(instructions),
                "input_chars": .integer(command.userText.count),
                "prompt_fingerprint": .string(turn.promptFingerprint),
                "user_message_id": .string(userMessage.id.uuidString),
                "assistant_message_id": .string(responseID.uuidString)
            ]
        )
        persistTurn(turn)
        isSending = true

        requestTask = Task { [weak self] in
            guard let self else { return }
            var finalStatus = ChatTurn.Status.completed
            do {
                let stream = client.streamResponse(
                    apiKey: apiKey,
                    model: model,
                    instructions: instructions,
                    input: command.userText,
                    diagnosticContext: DiagnosticRequestContext(
                        flow: "chat",
                        operationID: turnID,
                        details: ["mode": .string(command.mode.rawValue)]
                    )
                )
                for try await delta in stream {
                    append(delta, to: responseID)
                }
                if messageText(for: responseID).isEmpty {
                    replaceMessage(id: responseID, with: "(The model returned no text output.)")
                }
            } catch is CancellationError {
                finalStatus = .cancelled
                removeMessageIfEmpty(id: responseID)
                diagnosticLogger.event(
                    "chat_turn_cancelled",
                    level: .warning,
                    component: "chat",
                    operationID: turnID
                )
            } catch {
                finalStatus = .failed
                removeMessageIfEmpty(id: responseID)
                errorMessage = error.localizedDescription
                diagnosticLogger.event(
                    "chat_turn_failed",
                    level: .error,
                    component: "chat",
                    operationID: turnID,
                    failure: DiagnosticFailure.from(error),
                    details: [
                        "mode": .string(command.mode.rawValue),
                        "partial_output": .string(messageText(for: responseID))
                    ]
                )
            }
            persistMessageImmediately(id: responseID)
            var completedTurn = turn
            completedTurn.completedAt = Date()
            completedTurn.status = finalStatus
            persistTurnImmediately(completedTurn)
            diagnosticLogger.event(
                "chat_turn_finished",
                component: "chat",
                operationID: turnID,
                details: [
                    "status": .string(finalStatus.rawValue),
                    "mode": .string(command.mode.rawValue),
                    "output": .string(messageText(for: responseID)),
                    "output_chars": .integer(messageText(for: responseID).count),
                    "duration_ms": .integer(
                        max(0, Int(Date().timeIntervalSince(createdAt) * 1_000))
                    )
                ]
            )
            if command.mode == .correct || command.mode == .slack {
                NotificationCenter.default.post(
                    name: .translatorChatHistoryDidChange,
                    object: turnID
                )
            }
            isSending = false
            requestTask = nil
        }
    }

    func cancel() {
        diagnosticLogger.event(
            "chat_cancel_requested",
            level: .warning,
            component: "chat"
        )
        requestTask?.cancel()
    }

    func clearConversation() {
        let removedCount = messages.count
        requestTask?.cancel()
        requestTask = nil
        cancelPendingUpdates()
        messages.removeAll()
        errorMessage = nil
        isSending = false
        historyQueue.sync {
            do {
                try historyStore.clear()
                diagnosticLogger.event(
                    "chat_history_cleared",
                    component: "chat",
                    details: ["removed_message_count": .integer(removedCount)]
                )
            } catch {
                diagnosticLogger.event(
                    "chat_history_clear_failed",
                    level: .error,
                    component: "chat",
                    failure: DiagnosticFailure.from(error),
                    details: ["removed_message_count": .integer(removedCount)]
                )
            }
        }
    }

    func exportHistory() {
        guard !messages.isEmpty else { return }

        flushHistory()
        let panel = NSSavePanel()
        panel.title = "Export Chat History"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "MacTranslator-History-\(formatter.string(from: Date())).json"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            try historyStore.exportJSON(to: destinationURL)
            diagnosticLogger.event(
                "chat_history_exported",
                component: "chat",
                details: [
                    "destination": .string(destinationURL.path),
                    "message_count": .integer(messages.count)
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
            diagnosticLogger.event(
                "chat_history_export_failed",
                level: .error,
                component: "chat",
                failure: DiagnosticFailure.from(error),
                details: ["destination": .string(destinationURL.path)]
            )
        }
    }

    private func resolvedAPIKey() -> String? {
        SharedOpenAIConfiguration.apiKey(from: keychain)
    }

    private func append(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
        persistTextDebounced(id: id, text: messages[index].text)
    }

    private func replaceMessage(id: UUID, with text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        persistTextDebounced(id: id, text: text)
    }

    private func messageText(for id: UUID) -> String {
        messages.first(where: { $0.id == id })?.text ?? ""
    }

    private func removeMessageIfEmpty(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].text.isEmpty else { return }
        pendingTextUpdates[id]?.cancel()
        pendingTextUpdates[id] = nil
        messages.remove(at: index)
        historyQueue.async { [historyStore, diagnosticLogger] in
            do {
                try historyStore.delete(id: id)
            } catch {
                diagnosticLogger.event(
                    "chat_message_delete_failed",
                    level: .error,
                    component: "storage",
                    operationID: id,
                    failure: DiagnosticFailure.from(error)
                )
            }
        }
    }

    private func persistNewMessage(_ message: ChatMessage, position: Int) {
        historyQueue.async { [historyStore, diagnosticLogger] in
            do {
                try historyStore.upsert(message, position: position)
            } catch {
                diagnosticLogger.event(
                    "chat_message_insert_failed",
                    level: .error,
                    component: "storage",
                    operationID: message.turnID ?? message.id,
                    failure: DiagnosticFailure.from(error),
                    details: [
                        "message_id": .string(message.id.uuidString),
                        "role": .string(message.role.rawValue),
                        "position": .integer(position),
                        "text": .string(message.text)
                    ]
                )
            }
        }
    }

    private func persistTurn(_ turn: ChatTurn) {
        historyQueue.async { [historyStore, diagnosticLogger] in
            do {
                try historyStore.upsertTurn(turn)
            } catch {
                diagnosticLogger.event(
                    "chat_turn_insert_failed",
                    level: .error,
                    component: "storage",
                    operationID: turn.id,
                    failure: DiagnosticFailure.from(error)
                )
            }
        }
    }

    private func persistTurnImmediately(_ turn: ChatTurn) {
        historyQueue.sync {
            do {
                try historyStore.upsertTurn(turn)
            } catch {
                diagnosticLogger.event(
                    "chat_turn_update_failed",
                    level: .error,
                    component: "storage",
                    operationID: turn.id,
                    failure: DiagnosticFailure.from(error),
                    details: ["status": .string(turn.status.rawValue)]
                )
            }
        }
    }

    private func persistTextDebounced(id: UUID, text: String) {
        pendingTextUpdates[id]?.cancel()
        let workItem = DispatchWorkItem { [historyStore, diagnosticLogger] in
            do {
                try historyStore.updateText(id: id, text: text)
            } catch {
                diagnosticLogger.event(
                    "chat_message_stream_persist_failed",
                    level: .error,
                    component: "storage",
                    operationID: id,
                    failure: DiagnosticFailure.from(error),
                    details: ["text": .string(text)]
                )
            }
        }
        pendingTextUpdates[id] = workItem
        historyQueue.asyncAfter(deadline: .now() + .milliseconds(450), execute: workItem)
    }

    private func persistMessageImmediately(id: UUID) {
        pendingTextUpdates[id]?.cancel()
        pendingTextUpdates[id] = nil

        if let index = messages.firstIndex(where: { $0.id == id }) {
            let message = messages[index]
            historyQueue.sync {
                do {
                    try historyStore.upsert(message, position: index)
                } catch {
                    diagnosticLogger.event(
                        "chat_message_final_persist_failed",
                        level: .error,
                        component: "storage",
                        operationID: message.turnID ?? message.id,
                        failure: DiagnosticFailure.from(error),
                        details: [
                            "message_id": .string(message.id.uuidString),
                            "text": .string(message.text)
                        ]
                    )
                }
            }
        } else {
            historyQueue.sync {
                do {
                    try historyStore.delete(id: id)
                } catch {
                    diagnosticLogger.event(
                        "chat_message_cleanup_failed",
                        level: .error,
                        component: "storage",
                        operationID: id,
                        failure: DiagnosticFailure.from(error)
                    )
                }
            }
        }
    }

    private func cancelPendingUpdates() {
        for workItem in pendingTextUpdates.values {
            workItem.cancel()
        }
        pendingTextUpdates.removeAll()
    }

    private func flushHistory() {
        cancelPendingUpdates()
        let snapshot = messages
        historyQueue.sync {
            do {
                try historyStore.replaceAll(snapshot)
                diagnosticLogger.event(
                    "chat_history_flushed",
                    component: "storage",
                    details: ["message_count": .integer(snapshot.count)]
                )
            } catch {
                diagnosticLogger.event(
                    "chat_history_flush_failed",
                    level: .error,
                    component: "storage",
                    failure: DiagnosticFailure.from(error),
                    details: ["message_count": .integer(snapshot.count)]
                )
            }
        }
    }
}
