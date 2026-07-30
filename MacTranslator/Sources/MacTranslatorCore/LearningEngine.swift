import Foundation

public actor LearningEngine {
    public static let expressionBatchSize = 5
    public static let automaticHistorySyncThreshold = 50
    public static let passingBatchScore = 4
    public static let maximumReinforcementRounds = 3

    private let historyStore: ChatHistoryStore
    private let learningStore: LearningStore
    private let client: OpenAIClient
    private let diagnosticLogger: DiagnosticLogger

    public init(
        historyStore: ChatHistoryStore = ChatHistoryStore(),
        learningStore: LearningStore = LearningStore(),
        client: OpenAIClient = OpenAIClient(),
        diagnosticLogger: DiagnosticLogger = .shared
    ) {
        self.historyStore = historyStore
        self.learningStore = learningStore
        self.client = client
        self.diagnosticLogger = diagnosticLogger
    }

    public func loadDashboard() throws -> LearningDashboard {
        try learningStore.dashboard()
    }

    public func pendingHistoryTurnCount() throws -> Int {
        try pendingHistoryTurns().count
    }

    public static func shouldAutomaticallySync(
        pendingTurnCount: Int
    ) -> Bool {
        pendingTurnCount >= automaticHistorySyncThreshold
    }

    public func syncHistory(
        apiKey: String,
        model: String
    ) async throws -> LearningSyncResult {
        let syncID = UUID()
        let sourceTurns = try historyStore.learningSourceTurns()
        let pending = try pendingHistoryTurns(sourceTurns: sourceTurns)
        let alreadyAnalyzedCount = sourceTurns.count - pending.count
        diagnosticLogger.event(
            "learning_sync_started",
            component: "learn",
            operationID: syncID,
            details: [
                "source_turn_count": .integer(sourceTurns.count),
                "already_analyzed_count": .integer(alreadyAnalyzedCount),
                "pending_turn_count": .integer(pending.count),
                "model": .string(model)
            ]
        )
        guard !pending.isEmpty else {
            diagnosticLogger.event(
                "learning_sync_finished",
                component: "learn",
                operationID: syncID,
                details: [
                    "analyzed_turn_count": .integer(0),
                    "evidence_count": .integer(0)
                ]
            )
            return LearningSyncResult(analyzedTurnCount: 0, evidenceCount: 0)
        }

        var analyzedCount = 0
        var evidenceCount = 0
        for batch in pending.chunked(into: 8) {
            try Task.checkCancellation()
            let result = try await analyze(
                batch,
                apiKey: apiKey,
                model: model,
                operationID: syncID
            )
            let byID = Dictionary(uniqueKeysWithValues: result.turns.map { ($0.turnID, $0) })
            let expected = Set(batch.map(\.id))
            guard Set(byID.keys) == expected else {
                throw LearningStoreError.invalidModelOutput(
                    "The analyzer did not return every source turn exactly once."
                )
            }

            var events: [PendingLearningEvent] = []
            for source in batch {
                guard let analyzed = byID[source.id] else { continue }
                let isEligible = analyzed.isProficiencyEvidence
                    && (analyzed.inputLanguage == .english || analyzed.inputLanguage == .mixed)
                    && (source.mode == .correct || source.mode == .slack)
                var acceptedEvidence = 0

                for (index, evidence) in analyzed.evidence.enumerated() {
                    guard let definition = LearningTaxonomy.definition(
                        for: evidence.knowledgePointID
                    ), definition.dimension.isTrainable else {
                        continue
                    }
                    if [.error, .correctUsage].contains(evidence.kind), !isEligible {
                        continue
                    }

                    let eventType: LearningEventType
                    switch evidence.kind {
                    case .error:
                        eventType = .errorEvidenceObserved
                    case .correctUsage:
                        eventType = .correctUsageObserved
                    case .learningInterest:
                        eventType = .learningInterestObserved
                    case .level:
                        eventType = .levelEvidenceObserved
                    }
                    let payload = EvidenceObservedPayload(
                        evidenceID: UUID(),
                        sourceTurnID: source.id,
                        sourceMode: source.mode,
                        sourceOrigin: source.origin,
                        inputLanguage: analyzed.inputLanguage,
                        isProficiencyEvidence: isEligible,
                        knowledgePointID: definition.id,
                        title: definition.title,
                        dimension: definition.dimension,
                        severity: evidence.severity,
                        confidence: min(1, max(0, evidence.confidence)),
                        communicationImpact: min(
                            1,
                            max(0, evidence.communicationImpact)
                        ),
                        sourceExcerpt: Self.sanitizeExcerpt(evidence.sourceExcerpt),
                        correctedForm: String(evidence.correctedForm.prefix(300)),
                        explanationZH: String(evidence.explanationZH.prefix(600))
                    )
                    events.append(
                        try PendingLearningEvent(
                            type: eventType,
                            knowledgePointID: definition.id,
                            sourceTurnID: source.id,
                            correlationID: source.id,
                            idempotencyKey: [
                                "evidence",
                                source.id.uuidString,
                                LearningPromptContracts.analyzerVersion,
                                String(index),
                                eventType.rawValue
                            ].joined(separator: ":"),
                            producer: "history_analyzer",
                            model: model,
                            promptVersion: LearningPromptContracts.analyzerVersion,
                            payload: payload
                        )
                    )
                    acceptedEvidence += 1
                }

                let completion = SourceTurnAnalysisCompletedPayload(
                    sourceTurnID: source.id,
                    inputLanguage: analyzed.inputLanguage,
                    isProficiencyEvidence: isEligible,
                    analyzerVersion: LearningPromptContracts.analyzerVersion,
                    evidenceCount: acceptedEvidence
                )
                events.append(
                    try PendingLearningEvent(
                        type: .sourceTurnAnalysisCompleted,
                        sourceTurnID: source.id,
                        correlationID: source.id,
                        idempotencyKey: [
                            "analysis",
                            source.id.uuidString,
                            LearningPromptContracts.analyzerVersion
                        ].joined(separator: ":"),
                        producer: "history_analyzer",
                        model: model,
                        promptVersion: LearningPromptContracts.analyzerVersion,
                        payload: completion
                    )
                )
                analyzedCount += 1
                evidenceCount += acceptedEvidence
            }
            try learningStore.append(events)
            diagnosticLogger.event(
                "learning_analysis_batch_persisted",
                component: "learn",
                operationID: syncID,
                details: [
                    "turn_ids": .strings(batch.map { $0.id.uuidString }),
                    "event_count": .integer(events.count),
                    "batch_evidence_count": .integer(
                        events.filter {
                            $0.type != .sourceTurnAnalysisCompleted
                        }.count
                    )
                ]
            )
        }
        diagnosticLogger.event(
            "learning_sync_finished",
            component: "learn",
            operationID: syncID,
            details: [
                "analyzed_turn_count": .integer(analyzedCount),
                "evidence_count": .integer(evidenceCount)
            ]
        )
        return LearningSyncResult(
            analyzedTurnCount: analyzedCount,
            evidenceCount: evidenceCount
        )
    }

    private func pendingHistoryTurns(
        sourceTurns: [LearningSourceTurn]? = nil
    ) throws -> [LearningSourceTurn] {
        let sourceTurns = try sourceTurns ?? historyStore.learningSourceTurns()
        let analyzedIDs = try learningStore.analyzedTurnIDs(
            analyzerVersion: LearningPromptContracts.analyzerVersion
        )
        return sourceTurns.filter { !analyzedIDs.contains($0.id) }
    }

    public func startOrResumeSession(
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        if let session = dashboard.activeSession {
            let hasLegacyQuestion = session.attempts.contains {
                $0.question.type.isLegacy || $0.question.batchID == nil
            }
            let hasLegacyFocus = session.focusKnowledgePointID.map {
                !LearningTaxonomy.isTrainable($0)
            } ?? false
            let hasLegacyPerQuestionScoring = session.attempts.contains {
                $0.grade?.countsTowardMastery == true
            }
            if hasLegacyQuestion || hasLegacyFocus || hasLegacyPerQuestionScoring {
                _ = try complete(
                    session: session,
                    outcome: .userEnded,
                    summary: "The previous exercise was saved and closed when Learn upgraded its review schedule."
                )
                return try await startOrResumeSession(apiKey: apiKey, model: model)
            }
            diagnosticLogger.event(
                "learning_session_resumed",
                component: "learn",
                operationID: session.id,
                details: [
                    "attempt_count": .integer(session.attempts.count),
                    "focus_knowledge_point_id": .string(
                        session.focusKnowledgePointID ?? ""
                    )
                ]
            )
            return try await recover(
                session: session,
                apiKey: apiKey,
                model: model
            )
        }

        let planned = try plannedFocus(in: dashboard)
        let focus = planned.focus
        let sessionID = UUID()
        let startedAt = Date()
        let reason = Self.focusReason(focus, planKind: planned.kind)
        let startPayload = LearningSessionStartedPayload(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let focusPayload = SessionFocusSelectedPayload(
            sessionID: sessionID,
            knowledgePointID: focus.id,
            title: focus.title,
            reason: reason,
            planKind: planned.kind
        )
        try learningStore.append([
            try PendingLearningEvent(
                type: .learningSessionStarted,
                sessionID: sessionID,
                correlationID: sessionID,
                idempotencyKey: "session:\(sessionID.uuidString):started",
                producer: "tutor",
                payload: startPayload
            ),
            try PendingLearningEvent(
                type: .sessionFocusSelected,
                sessionID: sessionID,
                knowledgePointID: focus.id,
                correlationID: sessionID,
                idempotencyKey: "session:\(sessionID.uuidString):focus",
                producer: "planner",
                payload: focusPayload
            )
        ])
        diagnosticLogger.event(
            "learning_session_started",
            component: "learn",
            operationID: sessionID,
            details: [
                "focus_knowledge_point_id": .string(focus.id),
                "focus_title": .string(focus.title),
                "focus_reason": .string(reason),
                "plan_kind": .string(planned.kind.rawValue),
                "mastery": .double(focus.mastery),
                "lifecycle": .string(focus.lifecycle.rawValue)
            ]
        )
        return try await generateQuestionBatch(
            sessionID: sessionID,
            apiKey: apiKey,
            model: model
        )
    }

    public func requestHint() throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession,
              let attempt = session.attempts.last,
              !attempt.skipped,
              attempt.grade == nil else {
            throw LearningStoreError.missingQuestion
        }
        if !attempt.hintUsed {
            let payload = HintRequestedPayload(
                sessionID: session.id,
                questionID: attempt.question.id
            )
            try learningStore.append(
                PendingLearningEvent(
                    type: .hintRequested,
                    sessionID: session.id,
                    knowledgePointID: session.focusKnowledgePointID,
                    correlationID: session.id,
                    idempotencyKey: "hint:\(attempt.question.id.uuidString)",
                    producer: "learner",
                    payload: payload
                )
            )
            diagnosticLogger.event(
                "learning_hint_requested",
                component: "learn",
                operationID: session.id,
                details: [
                    "question_id": .string(attempt.question.id.uuidString),
                    "hint": .string(attempt.question.hint)
                ]
            )
        }
        return try learningStore.dashboard()
    }

    public func submitAnswers(
        _ answers: [UUID: String],
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession else {
            throw LearningStoreError.missingQuestion
        }
        let attempts = Self.currentBatchAttempts(in: session).filter { !$0.skipped }
        guard attempts.count == Self.expressionBatchSize,
              attempts.contains(where: { $0.grade == nil }) else {
            throw LearningStoreError.missingQuestion
        }

        var submittedEvents: [PendingLearningEvent] = []
        var submittedQuestionIDs: [String] = []
        for attempt in attempts where attempt.answer == nil {
            let trimmed = (answers[attempt.question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw LearningStoreError.invalidModelOutput(
                    "Complete all \(Self.expressionBatchSize) expressions before checking them."
                )
            }
            let answerID = UUID()
            let payload = AnswerSubmittedPayload(
                answerID: answerID,
                sessionID: session.id,
                questionID: attempt.question.id,
                answer: trimmed,
                submittedAt: Date()
            )
            submittedEvents.append(
                try PendingLearningEvent(
                    type: .answerSubmitted,
                    sessionID: session.id,
                    knowledgePointID: attempt.question.knowledgePointID,
                    correlationID: session.id,
                    idempotencyKey: "answer:\(answerID.uuidString)",
                    producer: "learner",
                    payload: payload
                )
            )
            submittedQuestionIDs.append(attempt.question.id.uuidString)
        }
        if !submittedEvents.isEmpty {
            try learningStore.append(submittedEvents)
            diagnosticLogger.event(
                "learning_answer_batch_submitted",
                component: "learn",
                operationID: session.id,
                details: [
                    "question_ids": .strings(submittedQuestionIDs),
                    "answer_count": .integer(submittedEvents.count)
                ]
            )
        }
        return try await gradePendingBatch(
            sessionID: session.id,
            apiKey: apiKey,
            model: model
        )
    }

    public func continueSession(
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession else {
            throw LearningStoreError.missingSession
        }
        let batch = Self.currentBatchAttempts(in: session).filter { !$0.skipped }
        guard !batch.isEmpty else {
            return try await generateQuestionBatch(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if batch.allSatisfy({ $0.answer != nil }),
           batch.contains(where: { $0.grade == nil }) {
            return try await gradePendingBatch(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        guard batch.allSatisfy({ $0.grade != nil }) else {
            return dashboard
        }
        let successfulCount = batch.filter {
            guard let grade = $0.grade else { return false }
            return grade.targetDemonstrated
                && (grade.verdict == .correct || grade.verdict == .acceptable)
        }.count
        let completedBatchCount = Self.completedBatchCount(in: session)
        switch Self.batchOutcome(
            successfulCount: successfulCount,
            completedBatchCount: completedBatchCount
        ) {
        case .reinforce:
            diagnosticLogger.event(
                "learning_reinforcement_started",
                component: "learn",
                operationID: session.id,
                details: [
                    "successful_count": .integer(successfulCount),
                    "completed_batch_count": .integer(completedBatchCount),
                    "knowledge_point_id": .string(
                        session.focusKnowledgePointID ?? ""
                    )
                ]
            )
            return try await generateQuestionBatch(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )

        case .passed:
            _ = try complete(
                session: session,
                outcome: .goodForToday,
                summary: "本轮 \(successfulCount)/\(batch.count) 通过；这只代表今天掌握，系统会按间隔再次复习。"
            )
            return try await startOrResumeSession(apiKey: apiKey, model: model)

        case .paused:
            _ = try complete(
                session: session,
                outcome: .needsReview,
                summary: "已完成 \(completedBatchCount) 轮强化，本知识点会在明天优先复习，避免疲劳式重复。"
            )
            return try await startOrResumeSession(apiKey: apiKey, model: model)
        }
    }

    public func replaceBatch(
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession else {
            throw LearningStoreError.missingQuestion
        }
        let attempts = Self.currentBatchAttempts(in: session).filter {
            !$0.skipped && $0.grade == nil
        }
        guard !attempts.isEmpty else {
            throw LearningStoreError.missingQuestion
        }
        let events = try attempts.map { attempt in
            try PendingLearningEvent(
                type: .questionSkipped,
                sessionID: session.id,
                knowledgePointID: attempt.question.knowledgePointID,
                correlationID: session.id,
                idempotencyKey: "skip:\(attempt.question.id.uuidString)",
                producer: "learner",
                payload: QuestionSkippedPayload(
                    sessionID: session.id,
                    questionID: attempt.question.id
                )
            )
        }
        try learningStore.append(events)
        diagnosticLogger.event(
            "learning_question_batch_replaced",
            component: "learn",
            operationID: session.id,
            details: [
                "question_ids": .strings(attempts.map { $0.question.id.uuidString }),
                "question_count": .integer(attempts.count)
            ]
        )
        return try await generateQuestionBatch(
            sessionID: session.id,
            apiKey: apiKey,
            model: model
        )
    }

    public func endSession() throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession else {
            return dashboard
        }
        return try complete(
            session: session,
            outcome: .userEnded,
            summary: "本次学习已结束，所有已完成的练习都已保存。"
        )
    }

    public func resetProgress() throws -> LearningDashboard {
        try learningStore.startNewEpoch(keepExtractedEvidence: true)
        diagnosticLogger.event(
            "learning_progress_reset",
            level: .warning,
            component: "learn"
        )
        return try learningStore.dashboard()
    }

    public func deleteAllLearningData() throws -> LearningDashboard {
        try learningStore.deleteAllLearningData()
        diagnosticLogger.event(
            "learning_data_deleted",
            level: .warning,
            component: "learn"
        )
        return try learningStore.dashboard()
    }

    public func rebuildProfile() throws -> LearningDashboard {
        try learningStore.rebuildProjections()
        diagnosticLogger.event(
            "learning_profile_rebuilt",
            component: "learn"
        )
        return try learningStore.dashboard()
    }

    public func exportEvents(to destinationURL: URL) throws {
        try learningStore.exportEvents(to: destinationURL)
        diagnosticLogger.event(
            "learning_events_exported",
            component: "learn",
            details: ["destination": .string(destinationURL.path)]
        )
    }

    private func recover(
        session: LearningSessionSnapshot,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let batch = Self.currentBatchAttempts(in: session).filter { !$0.skipped }
        guard !batch.isEmpty else {
            return try await generateQuestionBatch(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if batch.allSatisfy({ $0.answer != nil }),
           batch.contains(where: { $0.grade == nil }) {
            return try await gradePendingBatch(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        return try learningStore.dashboard()
    }

    private func analyze(
        _ turns: [LearningSourceTurn],
        apiKey: String,
        model: String,
        operationID: UUID
    ) async throws -> HistoryAnalysisResult {
        let references = turns.enumerated().map { index, turn in
            ("t\(index + 1)", turn)
        }
        let turnIDsByReference = Dictionary(
            uniqueKeysWithValues: references.map { ($0.0, $0.1.id) }
        )
        let input = HistoryAnalysisInput(
            taxonomyVersion: LearningTaxonomy.version,
            turns: references.map { reference, turn in
                HistoryAnalysisTurnInput(
                    turnID: reference,
                    mode: turn.mode.rawValue,
                    userText: String(turn.userText.prefix(4_000)),
                    assistantText: turn.assistantText.map { String($0.prefix(5_000)) }
                )
            }
        )
        let generated: HistoryAnalysisWireResult = try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.historyAnalyzer,
            input: try encodeInput(input),
            schemaName: "english_history_analysis",
            schema: LearningPromptContracts.historyAnalysisSchema(
                turnIDs: references.map(\.0)
            ),
            maxOutputTokens: 4_000,
            diagnosticContext: DiagnosticRequestContext(
                flow: "learning_history_analysis",
                operationID: operationID,
                details: [
                    "turn_ids": .strings(turns.map { $0.id.uuidString }),
                    "turn_references": .strings(references.map(\.0)),
                    "turn_count": .integer(turns.count)
                ]
            ),
            outputType: HistoryAnalysisWireResult.self
        )

        var resolved: [AnalyzedTurn] = []
        var seenReferences: Set<String> = []
        for item in generated.turns {
            guard let turnID = turnIDsByReference[item.turnID] else {
                throw LearningStoreError.invalidModelOutput(
                    "The analyzer returned an unknown turn ID: \(item.turnID)."
                )
            }
            guard seenReferences.insert(item.turnID).inserted else {
                throw LearningStoreError.invalidModelOutput(
                    "The analyzer returned a duplicate turn ID: \(item.turnID)."
                )
            }
            resolved.append(
                AnalyzedTurn(
                    turnID: turnID,
                    inputLanguage: item.inputLanguage,
                    isProficiencyEvidence: item.isProficiencyEvidence,
                    evidence: item.evidence
                )
            )
        }
        guard seenReferences == Set(turnIDsByReference.keys) else {
            throw LearningStoreError.invalidModelOutput(
                "The analyzer did not return every source turn exactly once."
            )
        }
        return HistoryAnalysisResult(turns: resolved)
    }

    private func generateQuestionBatch(
        sessionID: UUID,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession, session.id == sessionID else {
            throw LearningStoreError.missingSession
        }
        let currentBatch = Self.currentBatchAttempts(in: session)
        if currentBatch.contains(where: { !$0.skipped && $0.grade == nil }) {
            return dashboard
        }
        let focusID = session.focusKnowledgePointID ?? LearningTaxonomy.fallback.id
        let focus = dashboard.knowledgePoints.first(where: { $0.id == focusID })
            ?? Self.diagnosticFocus
        let requestedType = LearningQuestionType.chineseToEnglish
        let completedBatchCount = Self.completedBatchCount(in: session)
        let isReinforcement = completedBatchCount > 0
        let practiceMode = isReinforcement
            ? "reinforcement"
            : session.focusPlanKind.rawValue
        let recentBatchFeedback = currentBatch.compactMap { attempt -> String? in
            guard let grade = attempt.grade else { return nil }
            let issueText = grade.issues.joined(separator: "; ")
            return [
                issueText.isEmpty ? grade.explanationZH : issueText,
                grade.correctedAnswer.isEmpty
                    ? nil
                    : "Recommended: \(grade.correctedAnswer)"
            ]
            .compactMap { $0 }
            .joined(separator: " | ")
        }
        let recentScenarios = try historyStore.learningSourceTurns()
            .filter { $0.assistantText?.isEmpty == false }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(12)
            .map {
                QuestionScenarioInput(
                    turnID: $0.id.uuidString,
                    mode: $0.mode.rawValue,
                    userText: Self.sanitizeScenarioText($0.userText),
                    assistantText: $0.assistantText.map(Self.sanitizeScenarioText)
                )
            }
        let request = QuestionGenerationInput(
            batchSize: Self.expressionBatchSize,
            knowledgePointID: focus.id,
            knowledgePointTitle: focus.title,
            dimension: focus.dimension.rawValue,
            mastery: focus.mastery,
            lifecycle: focus.lifecycle.rawValue,
            requestedType: requestedType.rawValue,
            sanitizedEvidence: focus.sourceExcerpt,
            previousCorrection: focus.correctedForm,
            explanationZH: focus.explanationZH,
            practiceMode: practiceMode,
            reinforcementRound: isReinforcement ? completedBatchCount + 1 : 1,
            recentBatchFeedback: recentBatchFeedback,
            recentScenarios: recentScenarios,
            recentPrompts: session.attempts.suffix(10).map { $0.question.prompt }
        )
        let generated: GeneratedLearningQuestionBatch = try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.questionGenerator,
            input: try encodeInput(request),
            schemaName: "english_learning_question_batch",
            schema: LearningPromptContracts.questionBatchSchema,
            maxOutputTokens: 4_000,
            diagnosticContext: DiagnosticRequestContext(
                flow: "learning_question_batch_generation",
                operationID: session.id,
                details: [
                    "knowledge_point_id": .string(focus.id),
                    "question_type": .string(requestedType.rawValue),
                    "batch_size": .integer(Self.expressionBatchSize),
                    "practice_mode": .string(practiceMode),
                    "reinforcement_round": .integer(
                        isReinforcement ? completedBatchCount + 1 : 1
                    )
                ]
            ),
            outputType: GeneratedLearningQuestionBatch.self
        )
        let normalizedPrompts = generated.questions.map {
            $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard generated.questions.count == Self.expressionBatchSize,
              Set(normalizedPrompts).count == Self.expressionBatchSize,
              generated.questions.allSatisfy({
                  $0.type == requestedType
                      && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw LearningStoreError.invalidModelOutput(
                "The generated batch did not contain \(Self.expressionBatchSize) distinct expression exercises."
            )
        }
        let batchID = UUID()
        let questions = generated.questions.enumerated().map { index, generatedQuestion in
            QuestionPresentedPayload(
                id: UUID(),
                sessionID: session.id,
                ordinal: session.attempts.count + index + 1,
                knowledgePointID: focus.id,
                generated: generatedQuestion,
                batchID: batchID,
                batchIndex: index
            )
        }
        let events = try questions.map { question in
            try PendingLearningEvent(
                type: .questionPresented,
                sessionID: session.id,
                knowledgePointID: focus.id,
                correlationID: session.id,
                idempotencyKey: [
                    "question",
                    session.id.uuidString,
                    batchID.uuidString,
                    String(question.batchIndex ?? 0),
                    LearningPromptContracts.questionVersion
                ].joined(separator: ":"),
                producer: "question_generator",
                model: model,
                promptVersion: LearningPromptContracts.questionVersion,
                payload: question
            )
        }
        try learningStore.append(events)
        diagnosticLogger.event(
            "learning_question_batch_presented",
            component: "learn",
            operationID: session.id,
            details: [
                "batch_id": .string(batchID.uuidString),
                "question_ids": .strings(questions.map { $0.id.uuidString }),
                "question_count": .integer(questions.count),
                "knowledge_point_id": .string(focus.id),
                "prompts": .strings(questions.map(\.prompt))
            ]
        )
        return try learningStore.dashboard()
    }

    private func gradePendingBatch(
        sessionID: UUID,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession, session.id == sessionID else {
            throw LearningStoreError.missingSession
        }
        let attempts = Self.currentBatchAttempts(in: session).filter { !$0.skipped }
        let pending = attempts.filter { $0.grade == nil }
        let completedBatchCount = Self.completedBatchCount(in: session)
        let reinforcementRound = completedBatchCount + 1
        guard attempts.count == Self.expressionBatchSize,
              !pending.isEmpty,
              let batchID = attempts.first?.question.batchID,
              let knowledgePointID = session.focusKnowledgePointID,
              pending.allSatisfy({ $0.answerID != nil && $0.answer != nil }) else {
            throw LearningStoreError.invalidModelOutput(
                "All expressions in the batch must be saved before grading."
            )
        }

        let references = pending.enumerated().map { index, attempt in
            ("q\(index + 1)", attempt)
        }
        let questionIDsByReference = Dictionary(
            uniqueKeysWithValues: references.map { ($0.0, $0.1.question.id) }
        )
        let input = AnswerGradingBatchInput(
            answers: references.compactMap { reference, attempt in
                guard let answer = attempt.answer else { return nil }
                return AnswerGradingInput(
                    questionID: reference,
                    knowledgePointID: attempt.question.knowledgePointID,
                    questionType: attempt.question.type.rawValue,
                    prompt: attempt.question.prompt,
                    context: attempt.question.context,
                    rubric: attempt.question.rubric,
                    referenceAnswer: attempt.question.referenceAnswer,
                    learnerAnswer: answer,
                    hintUsed: attempt.hintUsed
                )
            }
        )
        let generated: GeneratedLearningGradeWireBatch = try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.answerGrader,
            input: try encodeInput(input),
            schemaName: "english_answer_grade_batch",
            schema: LearningPromptContracts.gradeBatchSchema(
                questionIDs: references.map(\.0)
            ),
            maxOutputTokens: 7_000,
            diagnosticContext: DiagnosticRequestContext(
                flow: "learning_answer_batch_grading",
                operationID: session.id,
                details: [
                    "question_ids": .strings(pending.map { $0.question.id.uuidString }),
                    "question_references": .strings(references.map(\.0)),
                    "answer_count": .integer(pending.count)
                ]
            ),
            outputType: GeneratedLearningGradeWireBatch.self
        )
        var generatedByQuestionID: [UUID: GeneratedLearningGrade] = [:]
        for item in generated.grades {
            guard let questionID = questionIDsByReference[item.questionID] else {
                throw LearningStoreError.invalidModelOutput(
                    "The grader returned an unknown question ID: \(item.questionID)."
                )
            }
            guard generatedByQuestionID[questionID] == nil else {
                throw LearningStoreError.invalidModelOutput(
                    "The grader returned a duplicate question ID."
                )
            }
            generatedByQuestionID[questionID] = item.grade
        }
        let expectedQuestionIDs = Set(pending.map { $0.question.id })
        guard Set(generatedByQuestionID.keys) == expectedQuestionIDs else {
            throw LearningStoreError.invalidModelOutput(
                "The grader did not return exactly one result for every expression."
            )
        }

        var events: [PendingLearningEvent] = []
        var verdicts: [String] = []
        var successfulCount = 0
        let completedAt = Date()
        for attempt in pending {
            guard let answerID = attempt.answerID,
                  let generatedGrade = generatedByQuestionID[attempt.question.id] else {
                continue
            }
            let normalizedConfidence = min(1, max(0, generatedGrade.confidence))
            let verdict = normalizedConfidence < 0.35
                ? LearningVerdict.ungradable
                : generatedGrade.verdict
            let targetDemonstrated = verdict == .ungradable
                ? false
                : generatedGrade.targetDemonstrated
            if targetDemonstrated
                && (verdict == .correct || verdict == .acceptable) {
                successfulCount += 1
            }
            let gradeID = UUID()
            let grade = AnswerGradedPayload(
                gradeID: gradeID,
                sessionID: session.id,
                questionID: attempt.question.id,
                answerID: answerID,
                knowledgePointID: attempt.question.knowledgePointID,
                questionType: attempt.question.type,
                usedHint: attempt.hintUsed,
                isRetry: reinforcementRound > 1,
                verdict: verdict,
                confidence: normalizedConfidence,
                targetDemonstrated: targetDemonstrated,
                correctedAnswer: String(generatedGrade.correctedAnswer.prefix(600)),
                explanationZH: String(generatedGrade.explanationZH.prefix(1_200)),
                issues: generatedGrade.issues.prefix(8).map { String($0.prefix(300)) },
                followUp: verdict == .ungradable ? .variation : generatedGrade.followUp,
                gradedAt: completedAt,
                alternativeAnswers: generatedGrade.alternativeAnswers.prefix(2).map {
                    String($0.prefix(600))
                },
                patterns: generatedGrade.patterns.prefix(4).map {
                    LearningSentencePattern(
                        pattern: String($0.pattern.prefix(200)),
                        meaningZH: String($0.meaningZH.prefix(300)),
                        example: String($0.example.prefix(500))
                    )
                },
                keyExplanationsZH: generatedGrade.keyExplanationsZH.prefix(3).map {
                    String($0.prefix(600))
                },
                countsTowardMastery: false
            )
            events.append(
                try PendingLearningEvent(
                    type: .answerGraded,
                    occurredAt: completedAt,
                    sessionID: session.id,
                    knowledgePointID: attempt.question.knowledgePointID,
                    correlationID: session.id,
                    causationID: answerID,
                    idempotencyKey: [
                        "grade",
                        answerID.uuidString,
                        LearningPromptContracts.graderVersion
                    ].joined(separator: ":"),
                    producer: "answer_grader",
                    model: model,
                    promptVersion: LearningPromptContracts.graderVersion,
                    payload: grade
                )
            )
            events.append(
                try PendingLearningEvent(
                    type: .explanationPresented,
                    sessionID: session.id,
                    knowledgePointID: attempt.question.knowledgePointID,
                    correlationID: session.id,
                    causationID: gradeID,
                    idempotencyKey: "explanation:\(gradeID.uuidString)",
                    producer: "tutor",
                    payload: ExplanationPresentedPayload(
                        sessionID: session.id,
                        questionID: attempt.question.id,
                        gradeID: gradeID,
                        presentedAt: Date()
                    )
                )
            )
            verdicts.append(verdict.rawValue)
        }
        let batchOutcome = Self.batchOutcome(
            successfulCount: successfulCount,
            completedBatchCount: reinforcementRound
        )
        events.append(
            try PendingLearningEvent(
                type: .batchReviewCompleted,
                occurredAt: completedAt,
                sessionID: session.id,
                knowledgePointID: knowledgePointID,
                correlationID: session.id,
                idempotencyKey: "batch-review:\(session.id.uuidString):\(batchID.uuidString)",
                producer: "learning_scheduler",
                payload: BatchReviewCompletedPayload(
                    sessionID: session.id,
                    batchID: batchID,
                    knowledgePointID: knowledgePointID,
                    successfulCount: successfulCount,
                    questionCount: attempts.count,
                    reinforcementRound: reinforcementRound,
                    outcome: batchOutcome,
                    completedAt: completedAt
                )
            )
        )
        try learningStore.append(events)
        diagnosticLogger.event(
            "learning_answer_batch_graded",
            component: "learn",
            operationID: session.id,
            details: [
                "question_ids": .strings(pending.map { $0.question.id.uuidString }),
                "grade_count": .integer(pending.count),
                "verdicts": .strings(verdicts),
                "successful_count": .integer(successfulCount),
                "reinforcement_round": .integer(reinforcementRound),
                "batch_outcome": .string(batchOutcome.rawValue)
            ]
        )
        return try learningStore.dashboard()
    }

    private func complete(
        session: LearningSessionSnapshot,
        outcome: LearningSessionCompletedPayload.Outcome,
        summary: String
    ) throws -> LearningDashboard {
        let payload = LearningSessionCompletedPayload(
            sessionID: session.id,
            outcome: outcome,
            summary: summary,
            completedAt: Date()
        )
        try learningStore.append(
            PendingLearningEvent(
                type: .learningSessionCompleted,
                sessionID: session.id,
                knowledgePointID: session.focusKnowledgePointID,
                correlationID: session.id,
                idempotencyKey: "session:\(session.id.uuidString):completed",
                producer: "tutor",
                payload: payload
            )
        )
        diagnosticLogger.event(
            "learning_session_completed",
            component: "learn",
            operationID: session.id,
            details: [
                "outcome": .string(outcome.rawValue),
                "summary": .string(summary),
                "attempt_count": .integer(session.attempts.count),
                "successful_attempt_count": .integer(
                    session.successfulAttemptCount
                ),
                "consecutive_failure_count": .integer(
                    session.consecutiveFailureCount
                )
            ]
        )
        return try learningStore.dashboard()
    }

    private func plannedFocus(
        in dashboard: LearningDashboard
    ) throws -> (focus: KnowledgePointSnapshot, kind: LearningSessionPlanKind) {
        let now = Date()
        let trainable = dashboard.knowledgePoints.filter {
            $0.dimension.isTrainable
        }
        guard !trainable.isEmpty else {
            return (Self.diagnosticFocus, .newMaterial)
        }

        let dueReviews = trainable.filter {
            $0.hasBeenPractised
                && ($0.lifecycle == .lapsed || ($0.dueAt.map { $0 <= now } ?? false))
        }.sorted(by: Self.reviewPriority)
        let newMaterial = trainable.filter {
            !$0.hasBeenPractised
        }.sorted(by: Self.newMaterialPriority)
        let counts = try todayPlanCounts()

        if let due = dueReviews.first {
            let shouldIntroduceNew = Self.shouldIntroduceNewMaterial(
                reviewSessionsToday: counts.review,
                newMaterialSessionsToday: counts.newMaterial,
                hasNewMaterial: !newMaterial.isEmpty
            )
            if shouldIntroduceNew, let newFocus = newMaterial.first {
                return (newFocus, .newMaterial)
            }
            return (due, .dueReview)
        }
        if let newFocus = newMaterial.first {
            return (newFocus, .newMaterial)
        }

        return (
            dashboard.recommendedFocus ?? trainable[0],
            .dueReview
        )
    }

    private func todayPlanCounts() throws -> (review: Int, newMaterial: Int) {
        let events = try learningStore.loadEvents()
        guard let currentEpoch = events.last?.learnerEpoch else {
            return (0, 0)
        }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var review = 0
        var newMaterial = 0
        for event in events where event.learnerEpoch == currentEpoch
            && event.type == .sessionFocusSelected
            && event.occurredAt >= startOfDay {
            guard let data = event.payloadJSON.data(using: .utf8),
                  let payload = try? decoder.decode(
                      SessionFocusSelectedPayload.self,
                      from: data
                  ) else {
                continue
            }
            switch payload.planKind {
            case .dueReview:
                review += 1
            case .newMaterial:
                newMaterial += 1
            }
        }
        return (review, newMaterial)
    }

    private func encodeInput<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw LearningStoreError.invalidPayload
        }
        return text
    }

    private static func currentBatchAttempts(
        in session: LearningSessionSnapshot
    ) -> [LearningAttemptSnapshot] {
        guard let batchID = session.attempts.last?.question.batchID else {
            return []
        }
        return session.attempts.filter {
            $0.question.batchID == batchID
        }.sorted {
            ($0.question.batchIndex ?? 0) < ($1.question.batchIndex ?? 0)
        }
    }

    public static func batchOutcome(
        successfulCount: Int,
        completedBatchCount: Int
    ) -> LearningBatchOutcome {
        if successfulCount >= passingBatchScore {
            return .passed
        }
        return completedBatchCount < maximumReinforcementRounds
            ? .reinforce
            : .paused
    }

    public static func shouldIntroduceNewMaterial(
        reviewSessionsToday: Int,
        newMaterialSessionsToday: Int,
        hasNewMaterial: Bool
    ) -> Bool {
        hasNewMaterial
            && max(0, reviewSessionsToday)
                >= 2 * (max(0, newMaterialSessionsToday) + 1)
    }

    public static func completedBatchCount(
        in session: LearningSessionSnapshot
    ) -> Int {
        let grouped = Dictionary(grouping: session.attempts.compactMap {
            attempt -> (UUID, LearningAttemptSnapshot)? in
            guard let batchID = attempt.question.batchID, !attempt.skipped else {
                return nil
            }
            return (batchID, attempt)
        }, by: \.0)
        return grouped.values.filter { entries in
            let attempts = entries.map(\.1)
            return attempts.count == expressionBatchSize
                && attempts.allSatisfy { $0.grade != nil }
        }.count
    }

    private static func reviewPriority(
        _ lhs: KnowledgePointSnapshot,
        _ rhs: KnowledgePointSnapshot
    ) -> Bool {
        if lhs.lifecycle == .lapsed, rhs.lifecycle != .lapsed {
            return true
        }
        if rhs.lifecycle == .lapsed, lhs.lifecycle != .lapsed {
            return false
        }
        if lhs.dueAt != rhs.dueAt {
            return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
        }
        return lhs.mastery < rhs.mastery
    }

    private static func newMaterialPriority(
        _ lhs: KnowledgePointSnapshot,
        _ rhs: KnowledgePointSnapshot
    ) -> Bool {
        if lhs.realChatErrorCount != rhs.realChatErrorCount {
            return lhs.realChatErrorCount > rhs.realChatErrorCount
        }
        return lhs.mastery < rhs.mastery
    }

    private static func focusReason(
        _ focus: KnowledgePointSnapshot,
        planKind: LearningSessionPlanKind
    ) -> String {
        if planKind == .dueReview {
            if focus.lifecycle == .lapsed {
                return "This knowledge point needs retrieval practice after a recent lapse."
            }
            if let dueAt = focus.dueAt, dueAt <= Date() {
                return "This knowledge point is due for spaced review."
            }
            return "Optional maintenance practice before the next scheduled review."
        }
        if focus.realChatErrorCount > 0 {
            return "This appeared in \(focus.realChatErrorCount) recent chat"
                + (focus.realChatErrorCount == 1 ? "." : "s.")
        }
        if let dueAt = focus.dueAt, dueAt <= Date() {
            return "This knowledge point is due for review."
        }
        return "Start with a short diagnostic so the teacher can calibrate your level."
    }

    private static func sanitizeExcerpt(_ input: String) -> String {
        var result = String(input.prefix(400))
        let patterns = [
            #"https?://\S+"#,
            #"\b[A-Z]{2,10}-\d+\b"#,
            #"\b(?:sk|pk)-[A-Za-z0-9_-]{8,}\b"#
        ]
        for pattern in patterns {
            if let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) {
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: "[redacted]"
                )
            }
        }
        return String(result.prefix(200))
    }

    private static func sanitizeScenarioText(_ input: String) -> String {
        var result = String(input.prefix(1_200))
        let patterns = [
            #"https?://\S+"#,
            #"\b[A-Z]{2,10}-\d+\b"#,
            #"\b(?:sk|pk)-[A-Za-z0-9_-]{8,}\b"#,
            #"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#
        ]
        for pattern in patterns {
            if let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) {
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: "[redacted]"
                )
            }
        }
        return String(result.prefix(700))
    }

    private static let diagnosticFocus = KnowledgePointSnapshot(
        id: LearningTaxonomy.fallback.id,
        title: LearningTaxonomy.fallback.title,
        dimension: LearningTaxonomy.fallback.dimension,
        mastery: 0.50,
        confidence: 0,
        lifecycle: .unobserved,
        weightedEvidenceCount: 0,
        realChatErrorCount: 0,
        realChatCorrectCount: 0,
        successfulAttempts: 0,
        lapseCount: 0,
        dueAt: Date(),
        lastEvidenceAt: nil,
        sourceExcerpt: "",
        correctedForm: "",
        explanationZH: ""
    )
}

private struct HistoryAnalysisInput: Encodable {
    let taxonomyVersion: Int
    let turns: [HistoryAnalysisTurnInput]

    enum CodingKeys: String, CodingKey {
        case taxonomyVersion = "taxonomy_version"
        case turns
    }
}

private struct HistoryAnalysisTurnInput: Encodable {
    let turnID: String
    let mode: String
    let userText: String
    let assistantText: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case mode
        case userText = "user_text"
        case assistantText = "assistant_text"
    }
}

private struct HistoryAnalysisWireResult: Decodable, Sendable {
    let turns: [HistoryAnalysisWireTurn]
}

private struct HistoryAnalysisWireTurn: Decodable, Sendable {
    let turnID: String
    let inputLanguage: LearningInputLanguage
    let isProficiencyEvidence: Bool
    let evidence: [AnalyzedEvidence]

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case inputLanguage = "input_language"
        case isProficiencyEvidence = "is_proficiency_evidence"
        case evidence
    }
}

private struct QuestionGenerationInput: Encodable {
    let batchSize: Int
    let knowledgePointID: String
    let knowledgePointTitle: String
    let dimension: String
    let mastery: Double
    let lifecycle: String
    let requestedType: String
    let sanitizedEvidence: String
    let previousCorrection: String
    let explanationZH: String
    let practiceMode: String
    let reinforcementRound: Int
    let recentBatchFeedback: [String]
    let recentScenarios: [QuestionScenarioInput]
    let recentPrompts: [String]

    enum CodingKeys: String, CodingKey {
        case batchSize = "batch_size"
        case knowledgePointID = "knowledge_point_id"
        case knowledgePointTitle = "knowledge_point_title"
        case dimension
        case mastery
        case lifecycle
        case requestedType = "requested_type"
        case sanitizedEvidence = "sanitized_evidence"
        case previousCorrection = "previous_correction"
        case explanationZH = "explanation_zh"
        case practiceMode = "practice_mode"
        case reinforcementRound = "reinforcement_round"
        case recentBatchFeedback = "recent_batch_feedback"
        case recentScenarios = "recent_scenarios"
        case recentPrompts = "recent_prompts"
    }
}

private struct QuestionScenarioInput: Encodable {
    let turnID: String
    let mode: String
    let userText: String
    let assistantText: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case mode
        case userText = "user_text"
        case assistantText = "assistant_text"
    }
}

private struct AnswerGradingInput: Encodable {
    let questionID: String
    let knowledgePointID: String
    let questionType: String
    let prompt: String
    let context: String
    let rubric: String
    let referenceAnswer: String
    let learnerAnswer: String
    let hintUsed: Bool

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case knowledgePointID = "knowledge_point_id"
        case questionType = "question_type"
        case prompt
        case context
        case rubric
        case referenceAnswer = "reference_answer"
        case learnerAnswer = "learner_answer"
        case hintUsed = "hint_used"
    }
}

private struct AnswerGradingBatchInput: Encodable {
    let answers: [AnswerGradingInput]
}

private struct GeneratedLearningGradeWireBatch: Decodable, Sendable {
    let grades: [GeneratedLearningGradeWireItem]
}

private struct GeneratedLearningGradeWireItem: Decodable, Sendable {
    let questionID: String
    let grade: GeneratedLearningGrade

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case grade
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
