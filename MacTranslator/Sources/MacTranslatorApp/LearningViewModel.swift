import AppKit
import Combine
import Foundation
import MacTranslatorCore
import UniformTypeIdentifiers

@MainActor
final class LearningViewModel: ObservableObject {
    @Published private(set) var dashboard: LearningDashboard?
    @Published private(set) var isLoading = true
    @Published private(set) var isSyncing = false
    @Published private(set) var isWorking = false
    @Published private(set) var hasAPIKey = false
    @Published var answer = ""
    @Published var errorMessage: String?
    @Published var syncMessage = "Loading your learning profile…"

    private let engine: LearningEngine
    private let keychain: KeychainStore
    private var didStart = false
    private var syncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        engine: LearningEngine = LearningEngine(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.engine = engine
        self.keychain = keychain

        NotificationCenter.default.publisher(for: .translatorCredentialsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshCredentials()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .translatorChatHistoryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleSync()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .translatorLearningDataDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.reload() }
            }
            .store(in: &cancellables)
    }

    deinit {
        syncTask?.cancel()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshCredentials()
        Task {
            await reload()
            await syncHistory()
            await recoverPendingSessionIfNeeded()
        }
    }

    func reload() async {
        do {
            dashboard = try await engine.loadDashboard()
            isLoading = false
            if !isSyncing {
                syncMessage = statusText
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func syncHistory() async {
        guard !isSyncing else { return }
        refreshCredentials()
        guard let apiKey = resolvedAPIKey() else {
            isLoading = false
            syncMessage = "Add the shared OpenAI API key in Settings."
            return
        }
        isSyncing = true
        syncMessage = "Checking recent t/s chats…"
        do {
            let result = try await engine.syncHistory(
                apiKey: apiKey,
                model: resolvedModel
            )
            dashboard = try await engine.loadDashboard()
            if result.analyzedTurnCount > 0 {
                syncMessage = "Learned from \(result.analyzedTurnCount) new chat"
                    + (result.analyzedTurnCount == 1 ? "." : "s.")
            } else {
                syncMessage = "Up to date"
            }
        } catch is CancellationError {
            syncMessage = statusText
        } catch {
            errorMessage = error.localizedDescription
            syncMessage = "Could not analyze new chats."
        }
        isSyncing = false
        isLoading = false
    }

    func startOrResumeSession() {
        performAPIWork { [engine] apiKey, model in
            try await engine.startOrResumeSession(apiKey: apiKey, model: model)
        }
    }

    func submitAnswer() {
        let submitted = answer
        performAPIWork(clearAnswer: true) { [engine] apiKey, model in
            try await engine.submitAnswer(submitted, apiKey: apiKey, model: model)
        }
    }

    func continueSession() {
        performAPIWork { [engine] apiKey, model in
            try await engine.continueSession(apiKey: apiKey, model: model)
        }
    }

    func requestHint() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                dashboard = try await engine.requestHint()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func skipQuestion() {
        performAPIWork { [engine] apiKey, model in
            try await engine.skipQuestion(apiKey: apiKey, model: model)
        }
    }

    func endSession() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                dashboard = try await engine.endSession()
                answer = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func exportProgress() {
        let panel = NSSavePanel()
        panel.title = "Export Learning Event Archive"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "MacTranslator-Learning-\(formatter.string(from: Date())).json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        Task {
            do {
                try await engine.exportEvents(to: destinationURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var statusText: String {
        guard let dashboard else { return "Loading…" }
        if dashboard.analyzedTurnCount == 0 {
            return "No t/s chats analyzed yet"
        }
        return "\(dashboard.analyzedTurnCount) chats analyzed"
    }

    private func performAPIWork(
        clearAnswer: Bool = false,
        _ work: @escaping @Sendable (String, String) async throws -> LearningDashboard
    ) {
        guard !isWorking else { return }
        refreshCredentials()
        guard let apiKey = resolvedAPIKey() else {
            errorMessage = "Chat and Learn share one OpenAI API key. Add it in Settings."
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                dashboard = try await work(apiKey, resolvedModel)
                if clearAnswer {
                    answer = ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func scheduleSync() {
        guard didStart else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncHistory()
        }
    }

    private func recoverPendingSessionIfNeeded() async {
        guard let session = dashboard?.activeSession else { return }
        let last = session.attempts.last
        let needsRecovery = last == nil
            || last?.skipped == true
            || (last?.answer != nil && last?.grade == nil)
        guard needsRecovery,
              let apiKey = resolvedAPIKey(),
              !isWorking else {
            return
        }
        isWorking = true
        do {
            dashboard = try await engine.startOrResumeSession(
                apiKey: apiKey,
                model: resolvedModel
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func refreshCredentials() {
        hasAPIKey = resolvedAPIKey() != nil
    }

    private func resolvedAPIKey() -> String? {
        SharedOpenAIConfiguration.apiKey(from: keychain)
    }

    private var resolvedModel: String {
        SharedOpenAIConfiguration.model
    }
}
