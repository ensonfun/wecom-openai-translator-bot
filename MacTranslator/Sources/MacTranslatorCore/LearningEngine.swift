import Foundation

public actor LearningEngine {
    private let historyStore: ChatHistoryStore
    private let learningStore: LearningStore
    private let client: OpenAIClient

    public init(
        historyStore: ChatHistoryStore = ChatHistoryStore(),
        learningStore: LearningStore = LearningStore(),
        client: OpenAIClient = OpenAIClient()
    ) {
        self.historyStore = historyStore
        self.learningStore = learningStore
        self.client = client
    }

    public func loadDashboard() throws -> LearningDashboard {
        try learningStore.dashboard()
    }

    public func syncHistory(
        apiKey: String,
        model: String
    ) async throws -> LearningSyncResult {
        let sourceTurns = try historyStore.learningSourceTurns()
        let analyzedIDs = try learningStore.analyzedTurnIDs(
            analyzerVersion: LearningPromptContracts.analyzerVersion
        )
        let pending = sourceTurns.filter { !analyzedIDs.contains($0.id) }
        guard !pending.isEmpty else {
            return LearningSyncResult(analyzedTurnCount: 0, evidenceCount: 0)
        }

        var analyzedCount = 0
        var evidenceCount = 0
        for batch in pending.chunked(into: 8) {
            try Task.checkCancellation()
            let result = try await analyze(
                batch,
                apiKey: apiKey,
                model: model
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
                var acceptedEvidence = 0

                for (index, evidence) in analyzed.evidence.enumerated() {
                    guard let definition = LearningTaxonomy.definition(
                        for: evidence.knowledgePointID
                    ) else {
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
        }
        return LearningSyncResult(
            analyzedTurnCount: analyzedCount,
            evidenceCount: evidenceCount
        )
    }

    public func startOrResumeSession(
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        if let session = dashboard.activeSession {
            return try await recover(
                session: session,
                apiKey: apiKey,
                model: model
            )
        }

        let focus = dashboard.recommendedFocus ?? Self.diagnosticFocus
        let sessionID = UUID()
        let startedAt = Date()
        let reason = Self.focusReason(focus)
        let startPayload = LearningSessionStartedPayload(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let focusPayload = SessionFocusSelectedPayload(
            sessionID: sessionID,
            knowledgePointID: focus.id,
            title: focus.title,
            reason: reason
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
        return try await generateNextQuestion(
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
        }
        return try learningStore.dashboard()
    }

    public func submitAnswer(
        _ answer: String,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LearningStoreError.invalidModelOutput("Enter an answer first.")
        }
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession,
              let attempt = session.attempts.last,
              !attempt.skipped,
              attempt.grade == nil else {
            throw LearningStoreError.missingQuestion
        }

        if attempt.answer == nil {
            let answerID = UUID()
            let payload = AnswerSubmittedPayload(
                answerID: answerID,
                sessionID: session.id,
                questionID: attempt.question.id,
                answer: trimmed,
                submittedAt: Date()
            )
            try learningStore.append(
                PendingLearningEvent(
                    type: .answerSubmitted,
                    sessionID: session.id,
                    knowledgePointID: attempt.question.knowledgePointID,
                    correlationID: session.id,
                    idempotencyKey: "answer:\(answerID.uuidString)",
                    producer: "learner",
                    payload: payload
                )
            )
        }
        return try await gradePendingAnswer(
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
        guard let last = session.attempts.last else {
            return try await generateNextQuestion(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if last.answer != nil, last.grade == nil {
            return try await gradePendingAnswer(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if last.grade == nil, !last.skipped {
            return dashboard
        }

        if session.successfulAttemptCount >= 2,
           session.completedQuestionTypes.count >= 2 {
            return try complete(
                session: session,
                outcome: .goodForToday,
                summary: "你已经用两种不同题型正确展示了这个知识点。本轮学习完成，系统会安排之后的间隔复习。"
            )
        }
        if session.consecutiveFailureCount >= 2 {
            return try complete(
                session: session,
                outcome: .needsReview,
                summary: "这个知识点今天仍不稳定。先暂停重复练习，明天会用更基础的题型重新复习。"
            )
        }
        if session.attempts.count >= 7 {
            return try complete(
                session: session,
                outcome: .needsReview,
                summary: "本次练习已经足够。进度已保存，下一次会从最需要巩固的部分继续。"
            )
        }
        return try await generateNextQuestion(
            sessionID: session.id,
            apiKey: apiKey,
            model: model
        )
    }

    public func skipQuestion(
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession,
              let attempt = session.attempts.last,
              attempt.grade == nil,
              !attempt.skipped else {
            throw LearningStoreError.missingQuestion
        }
        let payload = QuestionSkippedPayload(
            sessionID: session.id,
            questionID: attempt.question.id
        )
        try learningStore.append(
            PendingLearningEvent(
                type: .questionSkipped,
                sessionID: session.id,
                knowledgePointID: attempt.question.knowledgePointID,
                correlationID: session.id,
                idempotencyKey: "skip:\(attempt.question.id.uuidString)",
                producer: "learner",
                payload: payload
            )
        )
        if session.attempts.count >= 7 {
            let refreshed = try learningStore.dashboard()
            guard let active = refreshed.activeSession else { return refreshed }
            return try complete(
                session: active,
                outcome: .userEnded,
                summary: "本次学习已结束，已跳过的题目不会影响掌握度。"
            )
        }
        return try await generateNextQuestion(
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
        return try learningStore.dashboard()
    }

    public func deleteAllLearningData() throws -> LearningDashboard {
        try learningStore.deleteAllLearningData()
        return try learningStore.dashboard()
    }

    public func rebuildProfile() throws -> LearningDashboard {
        try learningStore.rebuildProjections()
        return try learningStore.dashboard()
    }

    public func exportEvents(to destinationURL: URL) throws {
        try learningStore.exportEvents(to: destinationURL)
    }

    private func recover(
        session: LearningSessionSnapshot,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        guard let last = session.attempts.last else {
            return try await generateNextQuestion(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if last.answer != nil, last.grade == nil {
            return try await gradePendingAnswer(
                sessionID: session.id,
                apiKey: apiKey,
                model: model
            )
        }
        if last.skipped {
            return try await generateNextQuestion(
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
        model: String
    ) async throws -> HistoryAnalysisResult {
        let input = HistoryAnalysisInput(
            taxonomyVersion: LearningTaxonomy.version,
            turns: turns.map {
                HistoryAnalysisTurnInput(
                    turnID: $0.id.uuidString,
                    mode: $0.mode.rawValue,
                    userText: String($0.userText.prefix(4_000)),
                    assistantText: $0.assistantText.map { String($0.prefix(5_000)) }
                )
            }
        )
        return try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.historyAnalyzer,
            input: try encodeInput(input),
            schemaName: "english_history_analysis",
            schema: LearningPromptContracts.historyAnalysisSchema,
            maxOutputTokens: 4_000,
            outputType: HistoryAnalysisResult.self
        )
    }

    private func generateNextQuestion(
        sessionID: UUID,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession, session.id == sessionID else {
            throw LearningStoreError.missingSession
        }
        if let last = session.attempts.last, last.grade == nil, !last.skipped {
            return dashboard
        }
        let focusID = session.focusKnowledgePointID ?? LearningTaxonomy.fallback.id
        let focus = dashboard.knowledgePoints.first(where: { $0.id == focusID })
            ?? Self.diagnosticFocus
        let requestedType = Self.nextQuestionType(for: session)
        let request = QuestionGenerationInput(
            knowledgePointID: focus.id,
            knowledgePointTitle: focus.title,
            dimension: focus.dimension.rawValue,
            mastery: focus.mastery,
            lifecycle: focus.lifecycle.rawValue,
            requestedType: requestedType.rawValue,
            sanitizedEvidence: focus.sourceExcerpt,
            previousCorrection: focus.correctedForm,
            explanationZH: focus.explanationZH,
            recentQuestionTypes: session.attempts.suffix(4).map { $0.question.type.rawValue }
        )
        let generated: GeneratedLearningQuestion = try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.questionGenerator,
            input: try encodeInput(request),
            schemaName: "english_learning_question",
            schema: LearningPromptContracts.questionSchema,
            maxOutputTokens: 1_200,
            outputType: GeneratedLearningQuestion.self
        )
        guard generated.type == requestedType,
              !generated.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !generated.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LearningStoreError.invalidModelOutput(
                "The generated question did not match the requested exercise."
            )
        }
        let question = QuestionPresentedPayload(
            id: UUID(),
            sessionID: session.id,
            ordinal: session.attempts.count + 1,
            knowledgePointID: focus.id,
            generated: generated
        )
        try learningStore.append(
            PendingLearningEvent(
                type: .questionPresented,
                sessionID: session.id,
                knowledgePointID: focus.id,
                correlationID: session.id,
                idempotencyKey: [
                    "question",
                    session.id.uuidString,
                    String(question.ordinal),
                    LearningPromptContracts.questionVersion
                ].joined(separator: ":"),
                producer: "question_generator",
                model: model,
                promptVersion: LearningPromptContracts.questionVersion,
                payload: question
            )
        )
        return try learningStore.dashboard()
    }

    private func gradePendingAnswer(
        sessionID: UUID,
        apiKey: String,
        model: String
    ) async throws -> LearningDashboard {
        let dashboard = try learningStore.dashboard()
        guard let session = dashboard.activeSession, session.id == sessionID,
              let attempt = session.attempts.last,
              let answerID = attempt.answerID,
              let answer = attempt.answer,
              attempt.grade == nil else {
            throw LearningStoreError.missingQuestion
        }
        let input = AnswerGradingInput(
            knowledgePointID: attempt.question.knowledgePointID,
            questionType: attempt.question.type.rawValue,
            prompt: attempt.question.prompt,
            context: attempt.question.context,
            rubric: attempt.question.rubric,
            referenceAnswer: attempt.question.referenceAnswer,
            learnerAnswer: answer,
            hintUsed: attempt.hintUsed
        )
        let generated: GeneratedLearningGrade = try await client.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: LearningPromptContracts.answerGrader,
            input: try encodeInput(input),
            schemaName: "english_answer_grade",
            schema: LearningPromptContracts.gradeSchema,
            maxOutputTokens: 1_500,
            outputType: GeneratedLearningGrade.self
        )
        let normalizedConfidence = min(1, max(0, generated.confidence))
        let verdict = normalizedConfidence < 0.35 ? LearningVerdict.ungradable : generated.verdict
        let gradeID = UUID()
        let grade = AnswerGradedPayload(
            gradeID: gradeID,
            sessionID: session.id,
            questionID: attempt.question.id,
            answerID: answerID,
            knowledgePointID: attempt.question.knowledgePointID,
            questionType: attempt.question.type,
            usedHint: attempt.hintUsed,
            isRetry: session.attempts.count > 1,
            verdict: verdict,
            confidence: normalizedConfidence,
            targetDemonstrated: verdict == .ungradable ? false : generated.targetDemonstrated,
            correctedAnswer: String(generated.correctedAnswer.prefix(600)),
            explanationZH: String(generated.explanationZH.prefix(1_200)),
            issues: generated.issues.prefix(8).map { String($0.prefix(300)) },
            followUp: verdict == .ungradable ? .variation : generated.followUp,
            gradedAt: Date()
        )
        let explanation = ExplanationPresentedPayload(
            sessionID: session.id,
            questionID: attempt.question.id,
            gradeID: gradeID,
            presentedAt: Date()
        )
        try learningStore.append([
            try PendingLearningEvent(
                type: .answerGraded,
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
            ),
            try PendingLearningEvent(
                type: .explanationPresented,
                sessionID: session.id,
                knowledgePointID: attempt.question.knowledgePointID,
                correlationID: session.id,
                causationID: gradeID,
                idempotencyKey: "explanation:\(gradeID.uuidString)",
                producer: "tutor",
                payload: explanation
            )
        ])
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
        return try learningStore.dashboard()
    }

    private func encodeInput<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw LearningStoreError.invalidPayload
        }
        return text
    }

    private static func nextQuestionType(
        for session: LearningSessionSnapshot
    ) -> LearningQuestionType {
        if let followUp = session.attempts.last?.grade?.followUp {
            switch followUp {
            case .scaffold:
                return .fillBlank
            case .harder:
                return .freeProduction
            case .variation:
                break
            case .reviewLater, .none:
                break
            }
        }
        let progression: [LearningQuestionType] = [
            .sentenceRepair,
            .guidedRewrite,
            .chineseToEnglish,
            .freeProduction,
            .fillBlank,
            .recognition
        ]
        let recent = Set(session.attempts.suffix(3).map { $0.question.type })
        return progression.first(where: { !recent.contains($0) }) ?? .freeProduction
    }

    private static func focusReason(_ focus: KnowledgePointSnapshot) -> String {
        if focus.realChatErrorCount > 0 {
            return "This appeared in \(focus.realChatErrorCount) recent t/s message"
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

private struct QuestionGenerationInput: Encodable {
    let knowledgePointID: String
    let knowledgePointTitle: String
    let dimension: String
    let mastery: Double
    let lifecycle: String
    let requestedType: String
    let sanitizedEvidence: String
    let previousCorrection: String
    let explanationZH: String
    let recentQuestionTypes: [String]

    enum CodingKeys: String, CodingKey {
        case knowledgePointID = "knowledge_point_id"
        case knowledgePointTitle = "knowledge_point_title"
        case dimension
        case mastery
        case lifecycle
        case requestedType = "requested_type"
        case sanitizedEvidence = "sanitized_evidence"
        case previousCorrection = "previous_correction"
        case explanationZH = "explanation_zh"
        case recentQuestionTypes = "recent_question_types"
    }
}

private struct AnswerGradingInput: Encodable {
    let knowledgePointID: String
    let questionType: String
    let prompt: String
    let context: String
    let rubric: String
    let referenceAnswer: String
    let learnerAnswer: String
    let hintUsed: Bool

    enum CodingKeys: String, CodingKey {
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
