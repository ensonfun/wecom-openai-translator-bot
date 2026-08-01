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
    @Published private(set) var debugEntries: [LearningDebugEntry] = []
    @Published var batchAnswers: [UUID: String] = [:]
    @Published var errorMessage: String?
    @Published var syncMessage = "Loading your learning profile…"

    private let engine: LearningEngine
    private let keychain: KeychainStore
    private let diagnosticLogger: DiagnosticLogger
    private let learningDebugStore: LearningDebugStore
    private var didStart = false
    private var startupTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        engine: LearningEngine = LearningEngine(),
        keychain: KeychainStore = KeychainStore(),
        diagnosticLogger: DiagnosticLogger = .shared,
        learningDebugStore: LearningDebugStore = .shared
    ) {
        self.engine = engine
        self.keychain = keychain
        self.diagnosticLogger = diagnosticLogger
        self.learningDebugStore = learningDebugStore
        self.debugEntries = learningDebugStore.entries()

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

        NotificationCenter.default.publisher(
            for: .translatorLearningDebugDidChange,
            object: learningDebugStore
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.reloadDebugEntries()
        }
        .store(in: &cancellables)
    }

    deinit {
        startupTask?.cancel()
        syncTask?.cancel()
        workTask?.cancel()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        diagnosticLogger.event(
            "learning_view_started",
            component: "learn"
        )
        refreshCredentials()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await reload()
            await syncHistoryIfThresholdReached(trigger: "learn_opened")
            await prepareExerciseIfNeeded()
            startupTask = nil
        }
    }

    func reload() async {
        do {
            dashboard = try await engine.loadDashboard()
            isLoading = false
            if let dashboard {
                diagnosticLogger.event(
                    "learning_dashboard_loaded",
                    component: "learn",
                    details: Self.dashboardDetails(dashboard)
                )
            }
            if !isSyncing {
                syncMessage = statusText
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            diagnosticLogger.event(
                "learning_dashboard_load_failed",
                level: .error,
                component: "learn",
                failure: DiagnosticFailure.from(error)
            )
        }
    }

    func syncHistory() async {
        guard !isSyncing else { return }
        refreshCredentials()
        guard let apiKey = resolvedAPIKey() else {
            isLoading = false
            syncMessage = "Add the shared OpenAI API key in Settings."
            diagnosticLogger.event(
                "learning_sync_blocked",
                level: .warning,
                component: "learn",
                details: ["reason": .string("missing_api_key")]
            )
            return
        }
        isSyncing = true
        syncMessage = "Checking recent chats…"
        diagnosticLogger.event(
            "learning_sync_requested",
            component: "learn",
            details: ["model": .string(resolvedModel)]
        )
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
            diagnosticLogger.event(
                "learning_sync_ui_completed",
                component: "learn",
                details: [
                    "analyzed_turn_count": .integer(result.analyzedTurnCount),
                    "evidence_count": .integer(result.evidenceCount)
                ]
            )
        } catch is CancellationError {
            syncMessage = statusText
            diagnosticLogger.event(
                "learning_sync_cancelled",
                level: .warning,
                component: "learn"
            )
        } catch {
            errorMessage = error.localizedDescription
            syncMessage = "Could not analyze new chats."
            diagnosticLogger.event(
                "learning_sync_failed",
                level: .error,
                component: "learn",
                failure: DiagnosticFailure.from(error)
            )
        }
        isSyncing = false
        isLoading = false
    }

    func startHistorySync() {
        guard !isSyncing else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncHistory()
        }
    }

    func startOrResumeSession() {
        performAPIWork(action: "start_or_resume_session") { [engine] apiKey, model in
            try await engine.startOrResumeSession(apiKey: apiKey, model: model)
        }
    }

    func submitBatch() {
        let submitted = batchAnswers
        performAPIWork(
            action: "submit_answer_batch",
            details: ["answer_count": .integer(submitted.count)]
        ) { [engine] apiKey, model in
            try await engine.submitAnswers(submitted, apiKey: apiKey, model: model)
        }
    }

    func continueSession() {
        performAPIWork(
            action: "continue_session",
            clearBatchAnswers: true
        ) { [engine] apiKey, model in
            try await engine.continueSession(apiKey: apiKey, model: model)
        }
    }

    func requestHint() {
        guard !isWorking else { return }
        isWorking = true
        diagnosticLogger.event(
            "learning_action_started",
            component: "learn",
            details: ["action": .string("request_hint")]
        )
        Task {
            do {
                dashboard = try await engine.requestHint()
                diagnosticLogger.event(
                    "learning_action_completed",
                    component: "learn",
                    details: ["action": .string("request_hint")]
                )
            } catch {
                errorMessage = error.localizedDescription
                diagnosticLogger.event(
                    "learning_action_failed",
                    level: .error,
                    component: "learn",
                    failure: DiagnosticFailure.from(error),
                    details: ["action": .string("request_hint")]
                )
            }
            isWorking = false
        }
    }

    func replaceBatch() {
        performAPIWork(
            action: "replace_batch",
            clearBatchAnswers: true
        ) { [engine] apiKey, model in
            try await engine.replaceBatch(apiKey: apiKey, model: model)
        }
    }

    func endSession() {
        guard !isWorking else { return }
        isWorking = true
        diagnosticLogger.event(
            "learning_action_started",
            component: "learn",
            details: ["action": .string("end_session")]
        )
        Task {
            do {
                dashboard = try await engine.endSession()
                batchAnswers = [:]
                diagnosticLogger.event(
                    "learning_action_completed",
                    component: "learn",
                    details: ["action": .string("end_session")]
                )
            } catch {
                errorMessage = error.localizedDescription
                diagnosticLogger.event(
                    "learning_action_failed",
                    level: .error,
                    component: "learn",
                    failure: DiagnosticFailure.from(error),
                    details: ["action": .string("end_session")]
                )
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
                diagnosticLogger.event(
                    "learning_export_ui_completed",
                    component: "learn",
                    details: ["destination": .string(destinationURL.path)]
                )
            } catch {
                errorMessage = error.localizedDescription
                diagnosticLogger.event(
                    "learning_export_ui_failed",
                    level: .error,
                    component: "learn",
                    failure: DiagnosticFailure.from(error),
                    details: ["destination": .string(destinationURL.path)]
                )
            }
        }
    }

    func reloadDebugEntries() {
        debugEntries = learningDebugStore.entries()
    }

    func clearDebugEntries() {
        learningDebugStore.clear()
        reloadDebugEntries()
    }

    func cancelCurrentRequest() {
        guard isWorking || isSyncing else { return }
        diagnosticLogger.event(
            "learning_action_cancel_requested",
            component: "learn"
        )
        startupTask?.cancel()
        syncTask?.cancel()
        workTask?.cancel()
    }

    var statusText: String {
        guard let dashboard else { return "Loading…" }
        if dashboard.analyzedTurnCount == 0 {
            return "No chats analyzed yet"
        }
        return "\(dashboard.analyzedTurnCount) chats analyzed"
    }

    private func performAPIWork(
        action: String,
        clearBatchAnswers: Bool = false,
        details: [String: DiagnosticValue] = [:],
        _ work: @escaping @Sendable (String, String) async throws -> LearningDashboard
    ) {
        guard !isWorking else { return }
        refreshCredentials()
        guard let apiKey = resolvedAPIKey() else {
            errorMessage = "Chat and Learn share one OpenAI API key. Add it in Settings."
            diagnosticLogger.event(
                "learning_action_blocked",
                level: .warning,
                component: "learn",
                details: [
                    "action": .string(action),
                    "reason": .string("missing_api_key")
                ]
            )
            return
        }
        isWorking = true
        errorMessage = nil
        var startedDetails = details
        startedDetails["action"] = .string(action)
        startedDetails["model"] = .string(resolvedModel)
        diagnosticLogger.event(
            "learning_action_started",
            component: "learn",
            details: startedDetails
        )
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                dashboard = try await work(apiKey, resolvedModel)
                if clearBatchAnswers {
                    batchAnswers = [:]
                }
                diagnosticLogger.event(
                    "learning_action_completed",
                    component: "learn",
                    details: Self.merging(
                        details,
                        with: ["action": .string(action)]
                    )
                )
            } catch is CancellationError {
                errorMessage = nil
                diagnosticLogger.event(
                    "learning_action_cancelled",
                    level: .warning,
                    component: "learn",
                    details: Self.merging(
                        details,
                        with: ["action": .string(action)]
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
                diagnosticLogger.event(
                    "learning_action_failed",
                    level: .error,
                    component: "learn",
                    failure: DiagnosticFailure.from(error),
                    details: Self.merging(
                        details,
                        with: ["action": .string(action)]
                    )
                )
            }
            isWorking = false
            workTask = nil
        }
    }

    private func scheduleSync() {
        guard didStart else { return }
        syncTask?.cancel()
        diagnosticLogger.event(
            "learning_sync_scheduled",
            component: "learn",
            details: ["delay_ms": .integer(2_000)]
        )
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncHistoryIfThresholdReached(trigger: "chat_completed")
        }
    }

    private func syncHistoryIfThresholdReached(trigger: String) async {
        guard !isSyncing else { return }
        do {
            let pendingCount = try await engine.pendingHistoryTurnCount()
            guard !isSyncing else { return }
            if LearningEngine.shouldAutomaticallySync(
                pendingTurnCount: pendingCount
            ) {
                diagnosticLogger.event(
                    "learning_automatic_sync_threshold_reached",
                    component: "learn",
                    details: [
                        "trigger": .string(trigger),
                        "pending_turn_count": .integer(pendingCount),
                        "threshold": .integer(
                            LearningEngine.automaticHistorySyncThreshold
                        )
                    ]
                )
                await syncHistory()
                return
            }

            if pendingCount == 0 {
                syncMessage = "Up to date"
            } else {
                syncMessage = [
                    "\(pendingCount)/",
                    "\(LearningEngine.automaticHistorySyncThreshold) new chats ",
                    "waiting for automatic analysis"
                ].joined()
            }
            diagnosticLogger.event(
                "learning_automatic_sync_deferred",
                component: "learn",
                details: [
                    "trigger": .string(trigger),
                    "pending_turn_count": .integer(pendingCount),
                    "threshold": .integer(
                        LearningEngine.automaticHistorySyncThreshold
                    )
                ]
            )
        } catch is CancellationError {
            errorMessage = nil
            diagnosticLogger.event(
                "learning_pending_history_count_cancelled",
                level: .warning,
                component: "learn",
                details: ["trigger": .string(trigger)]
            )
        } catch {
            errorMessage = error.localizedDescription
            diagnosticLogger.event(
                "learning_pending_history_count_failed",
                level: .error,
                component: "learn",
                failure: DiagnosticFailure.from(error),
                details: ["trigger": .string(trigger)]
            )
        }
    }

    private func prepareExerciseIfNeeded() async {
        let session = dashboard?.activeSession
        let batchID = session?.attempts.last?.question.batchID
        let batch = session?.attempts.filter {
            $0.question.batchID == batchID
        } ?? []
        let needsWork = session == nil
            || batchID == nil
            || batch.isEmpty
            || batch.allSatisfy({ $0.skipped })
            || (
                batch.allSatisfy({ $0.answer != nil || $0.skipped })
                    && batch.contains(where: { $0.grade == nil && !$0.skipped })
            )
        guard needsWork, let apiKey = resolvedAPIKey(), !isWorking else {
            return
        }
        isWorking = true
        diagnosticLogger.event(
            "learning_exercise_preparation_started",
            component: "learn",
            operationID: session?.id,
            details: ["attempt_count": .integer(session?.attempts.count ?? 0)]
        )
        do {
            dashboard = try await engine.startOrResumeSession(
                apiKey: apiKey,
                model: resolvedModel
            )
            diagnosticLogger.event(
                "learning_exercise_preparation_completed",
                component: "learn",
                operationID: dashboard?.activeSession?.id
            )
        } catch is CancellationError {
            errorMessage = nil
            diagnosticLogger.event(
                "learning_exercise_preparation_cancelled",
                level: .warning,
                component: "learn",
                operationID: session?.id
            )
        } catch {
            errorMessage = error.localizedDescription
            diagnosticLogger.event(
                "learning_exercise_preparation_failed",
                level: .error,
                component: "learn",
                operationID: session?.id,
                failure: DiagnosticFailure.from(error)
            )
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

    private static func dashboardDetails(
        _ dashboard: LearningDashboard
    ) -> [String: DiagnosticValue] {
        [
            "knowledge_point_count": .integer(dashboard.knowledgePoints.count),
            "analyzed_turn_count": .integer(dashboard.analyzedTurnCount),
            "eligible_english_turn_count": .integer(
                dashboard.eligibleEnglishTurnCount
            ),
            "active_session_id": .string(
                dashboard.activeSession?.id.uuidString ?? ""
            ),
            "recommended_focus_id": .string(
                dashboard.recommendedFocus?.id ?? ""
            )
        ]
    }

    private static func merging(
        _ left: [String: DiagnosticValue],
        with right: [String: DiagnosticValue]
    ) -> [String: DiagnosticValue] {
        left.merging(right) { _, new in new }
    }
}
