import Foundation

public enum LearningDimension: String, Codable, CaseIterable, Sendable {
    case grammar
    case vocabulary
    case expression
    case pragmatics
    case mechanics

    public var title: String {
        switch self {
        case .grammar: "Grammar"
        case .vocabulary: "Vocabulary"
        case .expression: "Expression"
        case .pragmatics: "Workplace communication"
        case .mechanics: "Writing mechanics"
        }
    }
}

public struct KnowledgePointDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let dimension: LearningDimension

    public init(id: String, title: String, dimension: LearningDimension) {
        self.id = id
        self.title = title
        self.dimension = dimension
    }
}

public enum LearningTaxonomy {
    public static let version = 1

    public static let all: [KnowledgePointDefinition] = [
        .init(id: "grammar.tense_aspect", title: "Tense and aspect", dimension: .grammar),
        .init(id: "grammar.subject_verb_agreement", title: "Subject–verb agreement", dimension: .grammar),
        .init(id: "grammar.articles_determiners", title: "Articles and determiners", dimension: .grammar),
        .init(id: "grammar.countability_plurals", title: "Countability and plurals", dimension: .grammar),
        .init(id: "grammar.prepositions", title: "Prepositions", dimension: .grammar),
        .init(id: "grammar.pronouns_reference", title: "Pronouns and reference", dimension: .grammar),
        .init(id: "grammar.negation", title: "Negation", dimension: .grammar),
        .init(id: "grammar.modals", title: "Modal verbs", dimension: .grammar),
        .init(id: "grammar.word_order", title: "Word order", dimension: .grammar),
        .init(id: "grammar.clauses_conjunctions", title: "Clauses and conjunctions", dimension: .grammar),
        .init(id: "grammar.comparatives", title: "Comparatives", dimension: .grammar),
        .init(id: "vocabulary.word_choice", title: "Word choice", dimension: .vocabulary),
        .init(id: "vocabulary.collocation", title: "Collocation", dimension: .vocabulary),
        .init(id: "vocabulary.phrasal_verbs", title: "Phrasal verbs", dimension: .vocabulary),
        .init(id: "vocabulary.idiomaticity", title: "Idiomatic English", dimension: .vocabulary),
        .init(id: "vocabulary.technical", title: "Technical vocabulary", dimension: .vocabulary),
        .init(id: "vocabulary.chinglish_transfer", title: "Chinese-to-English transfer", dimension: .vocabulary),
        .init(id: "expression.sentence_construction", title: "Sentence construction", dimension: .expression),
        .init(id: "expression.concision", title: "Concision", dimension: .expression),
        .init(id: "expression.clarity", title: "Clarity", dimension: .expression),
        .init(id: "expression.ambiguity", title: "Avoiding ambiguity", dimension: .expression),
        .init(id: "expression.naturalness", title: "Natural expression", dimension: .expression),
        .init(id: "expression.register", title: "Register", dimension: .expression),
        .init(id: "pragmatics.slack_directness", title: "Slack directness", dimension: .pragmatics),
        .init(id: "pragmatics.politeness", title: "Politeness", dimension: .pragmatics),
        .init(id: "pragmatics.requests_followups", title: "Requests and follow-ups", dimension: .pragmatics),
        .init(id: "pragmatics.disagreement_uncertainty", title: "Disagreement and uncertainty", dimension: .pragmatics),
        .init(id: "pragmatics.incident_updates", title: "Incident and status updates", dimension: .pragmatics),
        .init(id: "pragmatics.audience", title: "Audience-appropriate communication", dimension: .pragmatics),
        .init(id: "mechanics.spelling", title: "Spelling", dimension: .mechanics),
        .init(id: "mechanics.capitalization", title: "Capitalization", dimension: .mechanics),
        .init(id: "mechanics.punctuation", title: "Punctuation", dimension: .mechanics),
        .init(id: "mechanics.formatting", title: "Formatting", dimension: .mechanics)
    ]

    public static let fallback = KnowledgePointDefinition(
        id: "expression.sentence_construction",
        title: "Sentence construction",
        dimension: .expression
    )

    public static func definition(for id: String) -> KnowledgePointDefinition? {
        definitionsByID[id]
    }

    public static var ids: [String] {
        all.map(\.id)
    }

    private static let definitionsByID = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )
}
