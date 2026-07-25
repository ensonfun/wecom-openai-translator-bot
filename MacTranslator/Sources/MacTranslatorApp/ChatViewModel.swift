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
    private let historyQueue = DispatchQueue(label: "com.mario.MacTranslator.history", qos: .utility)
    private var pendingTextUpdates: [UUID: DispatchWorkItem] = [:]
    private var requestTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        keychain: KeychainStore = KeychainStore(),
        client: OpenAIClient = OpenAIClient(),
        historyStore: ChatHistoryStore = ChatHistoryStore()
    ) {
        self.keychain = keychain
        self.client = client
        self.historyStore = historyStore
        migrateUnavailablePreviewModel()

        do {
            messages = try historyStore.load()
        } catch {
            messages = []
            errorMessage = error.localizedDescription
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
    }

    func send() {
        let command = CommandParser.parse(
            input,
            prompts: PromptConfiguration.stored()
        )
        guard !command.cleanedText.isEmpty else { return }
        guard !command.userText.isEmpty, let instructions = command.instructions else { return }
        guard let apiKey = resolvedAPIKey(), !apiKey.isEmpty else {
            errorMessage = "Save your OpenAI API key in Settings before sending a message."
            hasAPIKey = false
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
                    input: command.userText
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
            } catch {
                finalStatus = .failed
                removeMessageIfEmpty(id: responseID)
                errorMessage = error.localizedDescription
            }
            persistMessageImmediately(id: responseID)
            var completedTurn = turn
            completedTurn.completedAt = Date()
            completedTurn.status = finalStatus
            persistTurnImmediately(completedTurn)
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
        requestTask?.cancel()
    }

    func clearConversation() {
        requestTask?.cancel()
        requestTask = nil
        cancelPendingUpdates()
        messages.removeAll()
        errorMessage = nil
        isSending = false
        historyQueue.sync {
            try? historyStore.clear()
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedAPIKey() -> String? {
        SharedOpenAIConfiguration.apiKey(from: keychain)
    }

    private func migrateUnavailablePreviewModel() {
        let defaults = UserDefaults.standard
        let configuredModel = defaults.string(forKey: AppSettings.modelKey)
        let resolvedModel = AppSettings.resolvedModel(configuredModel)
        if configuredModel != nil, configuredModel != resolvedModel {
            defaults.set(resolvedModel, forKey: AppSettings.modelKey)
        }
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
        historyQueue.async { [historyStore] in
            try? historyStore.delete(id: id)
        }
    }

    private func persistNewMessage(_ message: ChatMessage, position: Int) {
        historyQueue.async { [historyStore] in
            try? historyStore.upsert(message, position: position)
        }
    }

    private func persistTurn(_ turn: ChatTurn) {
        historyQueue.async { [historyStore] in
            try? historyStore.upsertTurn(turn)
        }
    }

    private func persistTurnImmediately(_ turn: ChatTurn) {
        historyQueue.sync {
            try? historyStore.upsertTurn(turn)
        }
    }

    private func persistTextDebounced(id: UUID, text: String) {
        pendingTextUpdates[id]?.cancel()
        let workItem = DispatchWorkItem { [historyStore] in
            try? historyStore.updateText(id: id, text: text)
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
                try? historyStore.upsert(message, position: index)
            }
        } else {
            historyQueue.sync {
                try? historyStore.delete(id: id)
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
            try? historyStore.replaceAll(snapshot)
        }
    }
}
