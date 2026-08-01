import Foundation

public enum LearningEventType: String, Codable, CaseIterable, Sendable {
    case sourceTurnAnalysisCompleted = "source_turn_analysis_completed"
    case sourceTurnAnalysisFailed = "source_turn_analysis_failed"
    case errorEvidenceObserved = "error_evidence_observed"
    case correctUsageObserved = "correct_usage_observed"
    case learningInterestObserved = "learning_interest_observed"
    case levelEvidenceObserved = "level_evidence_observed"
    case analysisEvidenceSuperseded = "analysis_evidence_superseded"
    case learningSessionStarted = "learning_session_started"
    case sessionFocusSelected = "session_focus_selected"
    case questionPresented = "question_presented"
    case hintRequested = "hint_requested"
    case answerSubmitted = "answer_submitted"
    case answerGraded = "answer_graded"
    case batchReviewCompleted = "batch_review_completed"
    case explanationPresented = "explanation_presented"
    case questionSkipped = "question_skipped"
    case learningSessionPaused = "learning_session_paused"
    case learningSessionResumed = "learning_session_resumed"
    case learningSessionCompleted = "learning_session_completed"
    case learningEpochStarted = "learning_epoch_started"
}

public struct LearningEventRecord: Identifiable, Codable, Equatable, Sendable {
    public let sequence: Int64
    public let id: UUID
    public let type: LearningEventType
    public let occurredAt: Date
    public let recordedAt: Date
    public let schemaVersion: Int
    public let learnerEpoch: UUID
    public let sessionID: UUID?
    public let knowledgePointID: String?
    public let sourceTurnID: UUID?
    public let correlationID: UUID?
    public let causationID: UUID?
    public let idempotencyKey: String
    public let producer: String
    public let model: String?
    public let reasoningEffort: OpenAIReasoningEffort?
    public let promptVersion: String?
    public let payloadJSON: String

    public init(
        sequence: Int64,
        id: UUID,
        type: LearningEventType,
        occurredAt: Date,
        recordedAt: Date,
        schemaVersion: Int,
        learnerEpoch: UUID,
        sessionID: UUID?,
        knowledgePointID: String?,
        sourceTurnID: UUID?,
        correlationID: UUID?,
        causationID: UUID?,
        idempotencyKey: String,
        producer: String,
        model: String?,
        reasoningEffort: OpenAIReasoningEffort?,
        promptVersion: String?,
        payloadJSON: String
    ) {
        self.sequence = sequence
        self.id = id
        self.type = type
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.schemaVersion = schemaVersion
        self.learnerEpoch = learnerEpoch
        self.sessionID = sessionID
        self.knowledgePointID = knowledgePointID
        self.sourceTurnID = sourceTurnID
        self.correlationID = correlationID
        self.causationID = causationID
        self.idempotencyKey = idempotencyKey
        self.producer = producer
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptVersion = promptVersion
        self.payloadJSON = payloadJSON
    }
}

public struct PendingLearningEvent: Sendable {
    public let id: UUID
    public let type: LearningEventType
    public let occurredAt: Date
    public let schemaVersion: Int
    public let learnerEpoch: UUID?
    public let sessionID: UUID?
    public let knowledgePointID: String?
    public let sourceTurnID: UUID?
    public let correlationID: UUID?
    public let causationID: UUID?
    public let idempotencyKey: String
    public let producer: String
    public let model: String?
    public let reasoningEffort: OpenAIReasoningEffort?
    public let promptVersion: String?
    public let payloadJSON: String

    public init<Payload: Encodable & Sendable>(
        id: UUID = UUID(),
        type: LearningEventType,
        occurredAt: Date = Date(),
        schemaVersion: Int = 1,
        learnerEpoch: UUID? = nil,
        sessionID: UUID? = nil,
        knowledgePointID: String? = nil,
        sourceTurnID: UUID? = nil,
        correlationID: UUID? = nil,
        causationID: UUID? = nil,
        idempotencyKey: String,
        producer: String,
        model: String? = nil,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        promptVersion: String? = nil,
        payload: Payload
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payloadJSON = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw LearningStoreError.invalidPayload
        }
        self.id = id
        self.type = type
        self.occurredAt = occurredAt
        self.schemaVersion = schemaVersion
        self.learnerEpoch = learnerEpoch
        self.sessionID = sessionID
        self.knowledgePointID = knowledgePointID
        self.sourceTurnID = sourceTurnID
        self.correlationID = correlationID
        self.causationID = causationID
        self.idempotencyKey = idempotencyKey
        self.producer = producer
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptVersion = promptVersion
        self.payloadJSON = payloadJSON
    }
}

public enum LearningInputLanguage: String, Codable, CaseIterable, Sendable {
    case english
    case chinese
    case mixed
    case other
}

public enum LearningEvidenceKind: String, Codable, CaseIterable, Sendable {
    case error
    case correctUsage = "correct_usage"
    case learningInterest = "learning_interest"
    case level
}

public enum LearningEvidenceSeverity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var weight: Double {
        switch self {
        case .low: 0.55
        case .medium: 0.78
        case .high: 1.0
        }
    }
}

public struct AnalyzedEvidence: Codable, Equatable, Sendable {
    public let kind: LearningEvidenceKind
    public let knowledgePointID: String
    public let title: String
    public let dimension: LearningDimension
    public let severity: LearningEvidenceSeverity
    public let confidence: Double
    public let communicationImpact: Double
    public let sourceExcerpt: String
    public let correctedForm: String
    public let explanationZH: String

    enum CodingKeys: String, CodingKey {
        case kind
        case knowledgePointID = "knowledge_point_id"
        case title
        case dimension
        case severity
        case confidence
        case communicationImpact = "communication_impact"
        case sourceExcerpt = "source_excerpt"
        case correctedForm = "corrected_form"
        case explanationZH = "explanation_zh"
    }

    public init(
        kind: LearningEvidenceKind,
        knowledgePointID: String,
        title: String,
        dimension: LearningDimension,
        severity: LearningEvidenceSeverity,
        confidence: Double,
        communicationImpact: Double,
        sourceExcerpt: String,
        correctedForm: String,
        explanationZH: String
    ) {
        self.kind = kind
        self.knowledgePointID = knowledgePointID
        self.title = title
        self.dimension = dimension
        self.severity = severity
        self.confidence = min(1, max(0, confidence))
        self.communicationImpact = min(1, max(0, communicationImpact))
        self.sourceExcerpt = String(sourceExcerpt.prefix(200))
        self.correctedForm = String(correctedForm.prefix(300))
        self.explanationZH = String(explanationZH.prefix(600))
    }
}

public struct AnalyzedTurn: Codable, Equatable, Sendable {
    public let turnID: UUID
    public let inputLanguage: LearningInputLanguage
    public let isProficiencyEvidence: Bool
    public let evidence: [AnalyzedEvidence]

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case inputLanguage = "input_language"
        case isProficiencyEvidence = "is_proficiency_evidence"
        case evidence
    }

    public init(
        turnID: UUID,
        inputLanguage: LearningInputLanguage,
        isProficiencyEvidence: Bool,
        evidence: [AnalyzedEvidence]
    ) {
        self.turnID = turnID
        self.inputLanguage = inputLanguage
        self.isProficiencyEvidence = isProficiencyEvidence
        self.evidence = evidence
    }
}

public struct HistoryAnalysisResult: Codable, Equatable, Sendable {
    public let turns: [AnalyzedTurn]

    public init(turns: [AnalyzedTurn]) {
        self.turns = turns
    }
}

public struct SourceTurnAnalysisCompletedPayload: Codable, Equatable, Sendable {
    public let sourceTurnID: UUID
    public let inputLanguage: LearningInputLanguage
    public let isProficiencyEvidence: Bool
    public let analyzerVersion: String
    public let evidenceCount: Int

    public init(
        sourceTurnID: UUID,
        inputLanguage: LearningInputLanguage,
        isProficiencyEvidence: Bool,
        analyzerVersion: String,
        evidenceCount: Int
    ) {
        self.sourceTurnID = sourceTurnID
        self.inputLanguage = inputLanguage
        self.isProficiencyEvidence = isProficiencyEvidence
        self.analyzerVersion = analyzerVersion
        self.evidenceCount = evidenceCount
    }
}

public struct EvidenceObservedPayload: Codable, Equatable, Sendable {
    public let evidenceID: UUID
    public let sourceTurnID: UUID
    public let sourceMode: CommandMode
    public let sourceOrigin: ChatMessage.Origin
    public let inputLanguage: LearningInputLanguage
    public let isProficiencyEvidence: Bool
    public let knowledgePointID: String
    public let title: String
    public let dimension: LearningDimension
    public let severity: LearningEvidenceSeverity
    public let confidence: Double
    public let communicationImpact: Double
    public let sourceExcerpt: String
    public let correctedForm: String
    public let explanationZH: String

    public init(
        evidenceID: UUID,
        sourceTurnID: UUID,
        sourceMode: CommandMode,
        sourceOrigin: ChatMessage.Origin,
        inputLanguage: LearningInputLanguage,
        isProficiencyEvidence: Bool,
        knowledgePointID: String,
        title: String,
        dimension: LearningDimension,
        severity: LearningEvidenceSeverity,
        confidence: Double,
        communicationImpact: Double,
        sourceExcerpt: String,
        correctedForm: String,
        explanationZH: String
    ) {
        self.evidenceID = evidenceID
        self.sourceTurnID = sourceTurnID
        self.sourceMode = sourceMode
        self.sourceOrigin = sourceOrigin
        self.inputLanguage = inputLanguage
        self.isProficiencyEvidence = isProficiencyEvidence
        self.knowledgePointID = knowledgePointID
        self.title = title
        self.dimension = dimension
        self.severity = severity
        self.confidence = confidence
        self.communicationImpact = communicationImpact
        self.sourceExcerpt = sourceExcerpt
        self.correctedForm = correctedForm
        self.explanationZH = explanationZH
    }
}

public enum LearningQuestionType: String, Codable, CaseIterable, Sendable {
    case recognition
    case fillBlank = "fill_blank"
    case sentenceRepair = "sentence_repair"
    case guidedRewrite = "guided_rewrite"
    case chineseToEnglish = "chinese_to_english"
    case freeProduction = "free_production"

    public var title: String {
        switch self {
        case .recognition: "Choose"
        case .fillBlank: "Fill in the blank"
        case .sentenceRepair: "Repair the sentence"
        case .guidedRewrite: "Rewrite"
        case .chineseToEnglish: "Translate"
        case .freeProduction: "Write freely"
        }
    }

    public var evidenceWeight: Double {
        switch self {
        case .recognition: 0.35
        case .fillBlank: 0.50
        case .sentenceRepair: 0.65
        case .guidedRewrite: 0.75
        case .chineseToEnglish: 1.0
        case .freeProduction: 1.0
        }
    }

    public var isLegacy: Bool {
        self != .chineseToEnglish
    }
}

public struct GeneratedLearningQuestion: Codable, Equatable, Sendable {
    public let type: LearningQuestionType
    public let prompt: String
    public let context: String
    public let hint: String
    public let rubric: String
    public let referenceAnswer: String

    enum CodingKeys: String, CodingKey {
        case type
        case prompt
        case context
        case hint
        case rubric
        case referenceAnswer = "reference_answer"
    }

    public init(
        type: LearningQuestionType,
        prompt: String,
        context: String,
        hint: String,
        rubric: String,
        referenceAnswer: String
    ) {
        self.type = type
        self.prompt = prompt
        self.context = context
        self.hint = hint
        self.rubric = rubric
        self.referenceAnswer = referenceAnswer
    }
}

public struct GeneratedLearningQuestionBatch: Codable, Equatable, Sendable {
    public let questions: [GeneratedLearningQuestion]

    public init(questions: [GeneratedLearningQuestion]) {
        self.questions = questions
    }
}

public struct QuestionPresentedPayload: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let ordinal: Int
    public let knowledgePointID: String
    public let batchID: UUID?
    public let batchIndex: Int?
    public let type: LearningQuestionType
    public let prompt: String
    public let context: String
    public let hint: String
    public let rubric: String
    public let referenceAnswer: String

    public init(
        id: UUID,
        sessionID: UUID,
        ordinal: Int,
        knowledgePointID: String,
        generated: GeneratedLearningQuestion,
        batchID: UUID? = nil,
        batchIndex: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.knowledgePointID = knowledgePointID
        self.batchID = batchID
        self.batchIndex = batchIndex
        type = generated.type
        prompt = generated.prompt
        context = generated.context
        hint = generated.hint
        rubric = generated.rubric
        referenceAnswer = generated.referenceAnswer
    }
}

public enum LearningVerdict: String, Codable, CaseIterable, Sendable {
    case correct
    case acceptable
    case needsImprovement = "needs_improvement"
    case incorrect
    case ungradable

    public var title: String {
        switch self {
        case .correct: "Natural expression"
        case .acceptable: "Mostly right"
        case .needsImprovement: "Needs adjustment"
        case .incorrect: "Needs adjustment"
        case .ungradable: "Try another prompt"
        }
    }

    public var baseScore: Double? {
        switch self {
        case .correct: 1.0
        case .acceptable: 0.78
        case .needsImprovement: 0.42
        case .incorrect: 0
        case .ungradable: nil
        }
    }
}

public enum LearningFollowUp: String, Codable, CaseIterable, Sendable {
    case harder
    case variation
    case scaffold
    case reviewLater = "review_later"
    case none
}

public struct LearningSentencePattern: Codable, Equatable, Sendable {
    public let pattern: String
    public let meaningZH: String
    public let example: String

    enum CodingKeys: String, CodingKey {
        case pattern
        case meaningZH = "meaning_zh"
        case example
    }

    public init(pattern: String, meaningZH: String, example: String) {
        self.pattern = pattern
        self.meaningZH = meaningZH
        self.example = example
    }
}

public struct GeneratedLearningGrade: Codable, Equatable, Sendable {
    public let verdict: LearningVerdict
    public let confidence: Double
    public let targetDemonstrated: Bool
    public let correctedAnswer: String
    public let alternativeAnswers: [String]
    public let explanationZH: String
    public let issues: [String]
    public let patterns: [LearningSentencePattern]
    public let keyExplanationsZH: [String]
    public let followUp: LearningFollowUp

    enum CodingKeys: String, CodingKey {
        case verdict
        case confidence
        case targetDemonstrated = "target_demonstrated"
        case correctedAnswer = "corrected_answer"
        case alternativeAnswers = "alternative_answers"
        case explanationZH = "explanation_zh"
        case issues
        case patterns
        case keyExplanationsZH = "key_explanations_zh"
        case followUp = "follow_up"
    }
}

public struct GeneratedLearningGradeItem: Codable, Equatable, Sendable {
    public let questionID: UUID
    public let grade: GeneratedLearningGrade

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case grade
    }

    public init(questionID: UUID, grade: GeneratedLearningGrade) {
        self.questionID = questionID
        self.grade = grade
    }
}

public struct GeneratedLearningGradeBatch: Codable, Equatable, Sendable {
    public let grades: [GeneratedLearningGradeItem]

    public init(grades: [GeneratedLearningGradeItem]) {
        self.grades = grades
    }
}

public struct LearningSessionStartedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let startedAt: Date

    public init(sessionID: UUID, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}

public struct SessionFocusSelectedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let knowledgePointID: String
    public let title: String
    public let reason: String
    public let planKind: LearningSessionPlanKind

    enum CodingKeys: String, CodingKey {
        case sessionID
        case knowledgePointID
        case title
        case reason
        case planKind
    }

    public init(
        sessionID: UUID,
        knowledgePointID: String,
        title: String,
        reason: String,
        planKind: LearningSessionPlanKind = .newMaterial
    ) {
        self.sessionID = sessionID
        self.knowledgePointID = knowledgePointID
        self.title = title
        self.reason = reason
        self.planKind = planKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        knowledgePointID = try container.decode(String.self, forKey: .knowledgePointID)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        planKind = try container.decodeIfPresent(
            LearningSessionPlanKind.self,
            forKey: .planKind
        ) ?? .newMaterial
    }
}

public enum LearningSessionPlanKind: String, Codable, CaseIterable, Sendable {
    case dueReview = "due_review"
    case newMaterial = "new_material"

    public var title: String {
        switch self {
        case .dueReview: "Due review"
        case .newMaterial: "New from your chats"
        }
    }
}

public struct HintRequestedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let questionID: UUID
}

public struct AnswerSubmittedPayload: Codable, Equatable, Sendable {
    public let answerID: UUID
    public let sessionID: UUID
    public let questionID: UUID
    public let answer: String
    public let submittedAt: Date

    public init(
        answerID: UUID,
        sessionID: UUID,
        questionID: UUID,
        answer: String,
        submittedAt: Date
    ) {
        self.answerID = answerID
        self.sessionID = sessionID
        self.questionID = questionID
        self.answer = answer
        self.submittedAt = submittedAt
    }
}

public struct AnswerGradedPayload: Codable, Equatable, Sendable {
    public let gradeID: UUID
    public let sessionID: UUID
    public let questionID: UUID
    public let answerID: UUID
    public let knowledgePointID: String
    public let questionType: LearningQuestionType
    public let usedHint: Bool
    public let isRetry: Bool
    public let verdict: LearningVerdict
    public let confidence: Double
    public let targetDemonstrated: Bool
    public let correctedAnswer: String
    public let explanationZH: String
    public let issues: [String]
    public let followUp: LearningFollowUp
    public let gradedAt: Date
    public let alternativeAnswers: [String]
    public let patterns: [LearningSentencePattern]
    public let keyExplanationsZH: [String]
    public let countsTowardMastery: Bool

    enum CodingKeys: String, CodingKey {
        case gradeID
        case sessionID
        case questionID
        case answerID
        case knowledgePointID
        case questionType
        case usedHint
        case isRetry
        case verdict
        case confidence
        case targetDemonstrated
        case correctedAnswer
        case explanationZH
        case issues
        case followUp
        case gradedAt
        case alternativeAnswers
        case patterns
        case keyExplanationsZH
        case countsTowardMastery
    }

    public init(
        gradeID: UUID,
        sessionID: UUID,
        questionID: UUID,
        answerID: UUID,
        knowledgePointID: String,
        questionType: LearningQuestionType,
        usedHint: Bool,
        isRetry: Bool,
        verdict: LearningVerdict,
        confidence: Double,
        targetDemonstrated: Bool,
        correctedAnswer: String,
        explanationZH: String,
        issues: [String],
        followUp: LearningFollowUp,
        gradedAt: Date,
        alternativeAnswers: [String] = [],
        patterns: [LearningSentencePattern] = [],
        keyExplanationsZH: [String] = [],
        countsTowardMastery: Bool = true
    ) {
        self.gradeID = gradeID
        self.sessionID = sessionID
        self.questionID = questionID
        self.answerID = answerID
        self.knowledgePointID = knowledgePointID
        self.questionType = questionType
        self.usedHint = usedHint
        self.isRetry = isRetry
        self.verdict = verdict
        self.confidence = confidence
        self.targetDemonstrated = targetDemonstrated
        self.correctedAnswer = correctedAnswer
        self.explanationZH = explanationZH
        self.issues = issues
        self.followUp = followUp
        self.gradedAt = gradedAt
        self.alternativeAnswers = alternativeAnswers
        self.patterns = patterns
        self.keyExplanationsZH = keyExplanationsZH
        self.countsTowardMastery = countsTowardMastery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gradeID = try container.decode(UUID.self, forKey: .gradeID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        questionID = try container.decode(UUID.self, forKey: .questionID)
        answerID = try container.decode(UUID.self, forKey: .answerID)
        knowledgePointID = try container.decode(String.self, forKey: .knowledgePointID)
        questionType = try container.decode(LearningQuestionType.self, forKey: .questionType)
        usedHint = try container.decode(Bool.self, forKey: .usedHint)
        isRetry = try container.decode(Bool.self, forKey: .isRetry)
        verdict = try container.decode(LearningVerdict.self, forKey: .verdict)
        confidence = try container.decode(Double.self, forKey: .confidence)
        targetDemonstrated = try container.decode(Bool.self, forKey: .targetDemonstrated)
        correctedAnswer = try container.decode(String.self, forKey: .correctedAnswer)
        explanationZH = try container.decode(String.self, forKey: .explanationZH)
        issues = try container.decode([String].self, forKey: .issues)
        followUp = try container.decode(LearningFollowUp.self, forKey: .followUp)
        gradedAt = try container.decode(Date.self, forKey: .gradedAt)
        alternativeAnswers = try container.decodeIfPresent(
            [String].self,
            forKey: .alternativeAnswers
        ) ?? []
        patterns = try container.decodeIfPresent(
            [LearningSentencePattern].self,
            forKey: .patterns
        ) ?? []
        keyExplanationsZH = try container.decodeIfPresent(
            [String].self,
            forKey: .keyExplanationsZH
        ) ?? []
        countsTowardMastery = try container.decodeIfPresent(
            Bool.self,
            forKey: .countsTowardMastery
        ) ?? true
    }
}

public enum LearningBatchOutcome: String, Codable, CaseIterable, Sendable {
    case passed
    case reinforce
    case paused
}

public struct BatchReviewCompletedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let batchID: UUID
    public let knowledgePointID: String
    public let successfulCount: Int
    public let questionCount: Int
    public let reinforcementRound: Int
    public let outcome: LearningBatchOutcome
    public let completedAt: Date

    public init(
        sessionID: UUID,
        batchID: UUID,
        knowledgePointID: String,
        successfulCount: Int,
        questionCount: Int,
        reinforcementRound: Int,
        outcome: LearningBatchOutcome,
        completedAt: Date
    ) {
        self.sessionID = sessionID
        self.batchID = batchID
        self.knowledgePointID = knowledgePointID
        self.successfulCount = successfulCount
        self.questionCount = questionCount
        self.reinforcementRound = reinforcementRound
        self.outcome = outcome
        self.completedAt = completedAt
    }
}

public struct ExplanationPresentedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let questionID: UUID
    public let gradeID: UUID
    public let presentedAt: Date
}

public struct QuestionSkippedPayload: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let questionID: UUID
}

public struct LearningSessionCompletedPayload: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case goodForToday = "good_for_today"
        case needsReview = "needs_review"
        case userEnded = "user_ended"
    }

    public let sessionID: UUID
    public let outcome: Outcome
    public let summary: String
    public let completedAt: Date
}

public struct LearningEpochStartedPayload: Codable, Equatable, Sendable {
    public let epochID: UUID
    public let keepExtractedEvidence: Bool
    public let startedAt: Date
}

public enum KnowledgeLifecycleState: String, Codable, CaseIterable, Sendable {
    case unobserved
    case weaknessDetected = "weakness_detected"
    case learning
    case consolidating
    case masteryCandidate = "mastery_candidate"
    case maintained
    case lapsed

    public var title: String {
        switch self {
        case .unobserved: "Not observed"
        case .weaknessDetected: "Needs attention"
        case .learning: "Learning"
        case .consolidating: "Consolidating"
        case .masteryCandidate: "Almost there"
        case .maintained: "Maintained"
        case .lapsed: "Review needed"
        }
    }
}

public struct KnowledgePointSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let dimension: LearningDimension
    public let mastery: Double
    public let confidence: Double
    public let lifecycle: KnowledgeLifecycleState
    public let weightedEvidenceCount: Double
    public let realChatErrorCount: Int
    public let realChatCorrectCount: Int
    public let successfulAttempts: Int
    public let lapseCount: Int
    public let dueAt: Date?
    public let lastEvidenceAt: Date?
    public let sourceExcerpt: String
    public let correctedForm: String
    public let explanationZH: String
    public let reviewStage: Int
    public let successfulReviewCount: Int
    public let lastReviewedAt: Date?
    public let lastReviewPassed: Bool

    public init(
        id: String,
        title: String,
        dimension: LearningDimension,
        mastery: Double,
        confidence: Double,
        lifecycle: KnowledgeLifecycleState,
        weightedEvidenceCount: Double,
        realChatErrorCount: Int,
        realChatCorrectCount: Int,
        successfulAttempts: Int,
        lapseCount: Int,
        dueAt: Date?,
        lastEvidenceAt: Date?,
        sourceExcerpt: String,
        correctedForm: String,
        explanationZH: String,
        reviewStage: Int = 0,
        successfulReviewCount: Int = 0,
        lastReviewedAt: Date? = nil,
        lastReviewPassed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.dimension = dimension
        self.mastery = mastery
        self.confidence = confidence
        self.lifecycle = lifecycle
        self.weightedEvidenceCount = weightedEvidenceCount
        self.realChatErrorCount = realChatErrorCount
        self.realChatCorrectCount = realChatCorrectCount
        self.successfulAttempts = successfulAttempts
        self.lapseCount = lapseCount
        self.dueAt = dueAt
        self.lastEvidenceAt = lastEvidenceAt
        self.sourceExcerpt = sourceExcerpt
        self.correctedForm = correctedForm
        self.explanationZH = explanationZH
        self.reviewStage = max(0, reviewStage)
        self.successfulReviewCount = max(0, successfulReviewCount)
        self.lastReviewedAt = lastReviewedAt
        self.lastReviewPassed = lastReviewPassed
    }

    public var hasBeenPractised: Bool {
        lastReviewedAt != nil || successfulReviewCount > 0
    }
}

public struct LearningAttemptSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var question: QuestionPresentedPayload
    public var hintUsed: Bool
    public var answerID: UUID?
    public var answer: String?
    public var grade: AnswerGradedPayload?
    public var skipped: Bool

    public init(
        id: UUID,
        question: QuestionPresentedPayload,
        hintUsed: Bool = false,
        answerID: UUID? = nil,
        answer: String? = nil,
        grade: AnswerGradedPayload? = nil,
        skipped: Bool = false
    ) {
        self.id = id
        self.question = question
        self.hintUsed = hintUsed
        self.answerID = answerID
        self.answer = answer
        self.grade = grade
        self.skipped = skipped
    }
}

public enum LearningSessionStatus: String, Codable, Sendable {
    case active
    case paused
    case completed
}

public struct LearningSessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var status: LearningSessionStatus
    public let startedAt: Date
    public var updatedAt: Date
    public var focusKnowledgePointID: String?
    public var focusTitle: String
    public var focusReason: String
    public var focusPlanKind: LearningSessionPlanKind
    public var attempts: [LearningAttemptSnapshot]
    public var outcome: LearningSessionCompletedPayload.Outcome?
    public var summary: String

    public init(
        id: UUID,
        status: LearningSessionStatus,
        startedAt: Date,
        updatedAt: Date,
        focusKnowledgePointID: String? = nil,
        focusTitle: String = "",
        focusReason: String = "",
        focusPlanKind: LearningSessionPlanKind = .newMaterial,
        attempts: [LearningAttemptSnapshot] = [],
        outcome: LearningSessionCompletedPayload.Outcome? = nil,
        summary: String = ""
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.focusKnowledgePointID = focusKnowledgePointID
        self.focusTitle = focusTitle
        self.focusReason = focusReason
        self.focusPlanKind = focusPlanKind
        self.attempts = attempts
        self.outcome = outcome
        self.summary = summary
    }

    public var activeAttempt: LearningAttemptSnapshot? {
        attempts.last(where: { !$0.skipped })
    }

    public var successfulAttemptCount: Int {
        attempts.filter {
            guard let grade = $0.grade else { return false }
            return grade.targetDemonstrated
                && (grade.verdict == .correct || grade.verdict == .acceptable)
        }.count
    }

    public var consecutiveFailureCount: Int {
        var count = 0
        for attempt in attempts.reversed() {
            guard let grade = attempt.grade else { continue }
            if grade.verdict == .incorrect || grade.verdict == .needsImprovement {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    public var completedQuestionTypes: Set<LearningQuestionType> {
        Set(attempts.compactMap { $0.grade == nil ? nil : $0.question.type })
    }
}

public struct LearningDashboard: Codable, Equatable, Sendable {
    public let knowledgePoints: [KnowledgePointSnapshot]
    public let activeSession: LearningSessionSnapshot?
    public let latestCompletedSession: LearningSessionSnapshot?
    public let analyzedTurnCount: Int
    public let eligibleEnglishTurnCount: Int
    public let lastAnalyzedAt: Date?

    public init(
        knowledgePoints: [KnowledgePointSnapshot],
        activeSession: LearningSessionSnapshot?,
        latestCompletedSession: LearningSessionSnapshot?,
        analyzedTurnCount: Int,
        eligibleEnglishTurnCount: Int,
        lastAnalyzedAt: Date?
    ) {
        self.knowledgePoints = knowledgePoints
        self.activeSession = activeSession
        self.latestCompletedSession = latestCompletedSession
        self.analyzedTurnCount = analyzedTurnCount
        self.eligibleEnglishTurnCount = eligibleEnglishTurnCount
        self.lastAnalyzedAt = lastAnalyzedAt
    }

    public var recommendedFocus: KnowledgePointSnapshot? {
        let now = Date()
        return knowledgePoints.filter {
            $0.dimension.isTrainable
        }.sorted { lhs, rhs in
            let lhsDue = lhs.dueAt.map { $0 <= now } ?? false
            let rhsDue = rhs.dueAt.map { $0 <= now } ?? false
            if lhsDue != rhsDue {
                return lhsDue
            }
            if lhs.lifecycle == .lapsed, rhs.lifecycle != .lapsed {
                return true
            }
            if rhs.lifecycle == .lapsed, lhs.lifecycle != .lapsed {
                return false
            }
            if lhs.mastery != rhs.mastery {
                return lhs.mastery < rhs.mastery
            }
            return lhs.realChatErrorCount > rhs.realChatErrorCount
        }.first
    }
}

public struct LearningSyncResult: Codable, Equatable, Sendable {
    public let analyzedTurnCount: Int
    public let evidenceCount: Int

    public init(analyzedTurnCount: Int, evidenceCount: Int) {
        self.analyzedTurnCount = analyzedTurnCount
        self.evidenceCount = evidenceCount
    }
}

public enum LearningStoreError: LocalizedError {
    case database(String)
    case invalidPayload
    case unsupportedEvent(String)
    case missingSession
    case missingQuestion
    case invalidModelOutput(String)

    public var errorDescription: String? {
        switch self {
        case .database(let message):
            "Learning database error: \(message)"
        case .invalidPayload:
            "The learning event contains invalid data."
        case .unsupportedEvent(let event):
            "The learning event is not supported: \(event)"
        case .missingSession:
            "No active learning session was found."
        case .missingQuestion:
            "No active learning question was found."
        case .invalidModelOutput(let message):
            "The learning response could not be used: \(message)"
        }
    }
}
