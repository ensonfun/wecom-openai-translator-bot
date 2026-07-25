import Foundation
import SQLite3

public struct LearningStore: Sendable {
    public static let projectorName = "learning_core"
    public static let projectorVersion = 1

    public let databaseURL: URL

    public init(directoryURL: URL? = nil) {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            directory = applicationSupport.appendingPathComponent("MacTranslator", isDirectory: true)
        }
        databaseURL = directory.appendingPathComponent("chat-history.sqlite3", isDirectory: false)
    }

    @discardableResult
    public func append(_ events: [PendingLearningEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        let inserted = try withDatabase { database in
            let epoch = try currentEpoch(database)
            try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                var inserted = 0
                for event in events {
                    if try insert(event, defaultEpoch: epoch, database: database) {
                        inserted += 1
                    }
                }
                try execute("COMMIT;", database: database)
                return inserted
            } catch {
                try? execute("ROLLBACK;", database: database)
                throw error
            }
        }
        if inserted > 0 {
            try rebuildProjections()
        }
        return inserted
    }

    @discardableResult
    public func append(_ event: PendingLearningEvent) throws -> Bool {
        try append([event]) > 0
    }

    public func loadEvents() throws -> [LearningEventRecord] {
        try withDatabase { database in
            try readEvents(database)
        }
    }

    public func dashboard() throws -> LearningDashboard {
        try ensureProjectionIsCurrent()
        return try withDatabase { database in
            let knowledge = try readKnowledge(database)
            let activeSession = try readActiveSession(database)
            let latestCompletedSession = try readLatestCompletedSession(database)
            let coverage = try readCoverageSummary(database)
            return LearningDashboard(
                knowledgePoints: knowledge,
                activeSession: activeSession,
                latestCompletedSession: latestCompletedSession,
                analyzedTurnCount: coverage.count,
                eligibleEnglishTurnCount: coverage.eligibleCount,
                lastAnalyzedAt: coverage.lastAnalyzedAt
            )
        }
    }

    public func analyzedTurnIDs(analyzerVersion: String) throws -> Set<UUID> {
        try ensureProjectionIsCurrent()
        return try withDatabase { database in
            let statement = try prepare(
                """
                SELECT turn_id
                FROM learning_source_projection
                WHERE analyzer_version = ?;
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(analyzerVersion, at: 1, to: statement, database: database)
            var ids = Set<UUID>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = columnText(statement, at: 0),
                   let id = UUID(uuidString: text) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    public func rebuildProjections() throws {
        try withDatabase { database in
            let events = try readEvents(database)
            let state = try ProjectionReducer.reduce(events)
            try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                try execute("DELETE FROM learning_knowledge_projection;", database: database)
                try execute("DELETE FROM learning_session_projection;", database: database)
                try execute("DELETE FROM learning_source_projection;", database: database)

                for knowledge in state.knowledge.values {
                    try insertKnowledge(knowledge.snapshot, database: database)
                }
                for session in state.sessions.values {
                    try insertSession(session, database: database)
                }
                for coverage in state.coverage.values {
                    try insertCoverage(coverage, database: database)
                }

                let checkpoint = events.last?.sequence ?? 0
                let statement = try prepare(
                    """
                    INSERT INTO learning_projection_checkpoints (
                        projector_name, projector_version, last_sequence, updated_at
                    )
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(projector_name) DO UPDATE SET
                        projector_version = excluded.projector_version,
                        last_sequence = excluded.last_sequence,
                        updated_at = excluded.updated_at;
                    """,
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                try bind(Self.projectorName, at: 1, to: statement, database: database)
                try bind(Int64(Self.projectorVersion), at: 2, to: statement, database: database)
                try bind(checkpoint, at: 3, to: statement, database: database)
                try bind(Date().timeIntervalSince1970, at: 4, to: statement, database: database)
                try stepDone(statement, database: database)

                if let currentEpoch = state.currentEpoch {
                    try setMetadata(
                        key: "current_epoch",
                        value: currentEpoch.uuidString,
                        database: database
                    )
                }
                try execute("COMMIT;", database: database)
            } catch {
                try? execute("ROLLBACK;", database: database)
                throw error
            }
        }
    }

    public func startNewEpoch(keepExtractedEvidence: Bool = true) throws {
        let epoch = UUID()
        let payload = LearningEpochStartedPayload(
            epochID: epoch,
            keepExtractedEvidence: keepExtractedEvidence,
            startedAt: Date()
        )
        let event = try PendingLearningEvent(
            type: .learningEpochStarted,
            learnerEpoch: epoch,
            idempotencyKey: "epoch:\(epoch.uuidString)",
            producer: "app",
            payload: payload
        )
        try append(event)
    }

    public func deleteAllLearningData() throws {
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                try execute("DELETE FROM learning_events;", database: database)
                try execute("DELETE FROM learning_knowledge_projection;", database: database)
                try execute("DELETE FROM learning_session_projection;", database: database)
                try execute("DELETE FROM learning_source_projection;", database: database)
                try execute("DELETE FROM learning_projection_checkpoints;", database: database)
                try setMetadata(
                    key: "current_epoch",
                    value: UUID().uuidString,
                    database: database
                )
                try execute("COMMIT;", database: database)
            } catch {
                try? execute("ROLLBACK;", database: database)
                throw error
            }
        }
    }

    public func exportEvents(to destinationURL: URL) throws {
        let events = try loadEvents()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(events).write(to: destinationURL, options: .atomic)
    }

    private func ensureProjectionIsCurrent() throws {
        let needsRebuild = try withDatabase { database in
            let latestStatement = try prepare(
                "SELECT COALESCE(MAX(sequence), 0) FROM learning_events;",
                database: database
            )
            defer { sqlite3_finalize(latestStatement) }
            guard sqlite3_step(latestStatement) == SQLITE_ROW else {
                throw databaseError(database)
            }
            let latest = sqlite3_column_int64(latestStatement, 0)

            let checkpointStatement = try prepare(
                """
                SELECT projector_version, last_sequence
                FROM learning_projection_checkpoints
                WHERE projector_name = ?;
                """,
                database: database
            )
            defer { sqlite3_finalize(checkpointStatement) }
            try bind(Self.projectorName, at: 1, to: checkpointStatement, database: database)
            guard sqlite3_step(checkpointStatement) == SQLITE_ROW else {
                return true
            }
            let version = Int(sqlite3_column_int64(checkpointStatement, 0))
            let checkpoint = sqlite3_column_int64(checkpointStatement, 1)
            return version != Self.projectorVersion || checkpoint != latest
        }
        if needsRebuild {
            try rebuildProjections()
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open database"
            if let database {
                sqlite3_close(database)
            }
            throw LearningStoreError.database(message)
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL;", database: database)
        try execute("PRAGMA synchronous=NORMAL;", database: database)
        try createSchema(database)
        _ = try currentEpoch(database)
        return try body(database)
    }

    private func createSchema(_ database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                event_type TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                recorded_at REAL NOT NULL,
                schema_version INTEGER NOT NULL,
                learner_epoch TEXT NOT NULL,
                session_id TEXT,
                knowledge_point_id TEXT,
                source_turn_id TEXT,
                correlation_id TEXT,
                causation_id TEXT,
                idempotency_key TEXT NOT NULL UNIQUE,
                producer TEXT NOT NULL,
                model TEXT,
                prompt_version TEXT,
                payload_json TEXT NOT NULL
            );
            """,
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS learning_events_type_idx ON learning_events(event_type);",
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS learning_events_session_idx ON learning_events(session_id);",
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS learning_events_source_idx ON learning_events(source_turn_id);",
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_knowledge_projection (
                knowledge_point_id TEXT PRIMARY KEY NOT NULL,
                snapshot_json TEXT NOT NULL,
                mastery REAL NOT NULL,
                confidence REAL NOT NULL,
                due_at REAL,
                lifecycle TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_session_projection (
                session_id TEXT PRIMARY KEY NOT NULL,
                status TEXT NOT NULL,
                updated_at REAL NOT NULL,
                snapshot_json TEXT NOT NULL
            );
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_source_projection (
                turn_id TEXT PRIMARY KEY NOT NULL,
                analyzer_version TEXT NOT NULL,
                input_language TEXT NOT NULL,
                is_proficiency_evidence INTEGER NOT NULL,
                analyzed_at REAL NOT NULL
            );
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_projection_checkpoints (
                projector_name TEXT PRIMARY KEY NOT NULL,
                projector_version INTEGER NOT NULL,
                last_sequence INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """,
            database: database
        )
    }

    private func currentEpoch(_ database: OpaquePointer) throws -> UUID {
        let statement = try prepare(
            "SELECT value FROM learning_metadata WHERE key = 'current_epoch';",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW,
           let value = columnText(statement, at: 0),
           let epoch = UUID(uuidString: value) {
            return epoch
        }
        let epoch = UUID()
        try setMetadata(key: "current_epoch", value: epoch.uuidString, database: database)
        return epoch
    }

    private func setMetadata(
        key: String,
        value: String,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO learning_metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement, database: database)
        try bind(value, at: 2, to: statement, database: database)
        try stepDone(statement, database: database)
    }

    private func insert(
        _ event: PendingLearningEvent,
        defaultEpoch: UUID,
        database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO learning_events (
                event_id, event_type, occurred_at, recorded_at, schema_version,
                learner_epoch, session_id, knowledge_point_id, source_turn_id,
                correlation_id, causation_id, idempotency_key, producer, model,
                prompt_version, payload_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        try bind(event.id.uuidString, at: 1, to: statement, database: database)
        try bind(event.type.rawValue, at: 2, to: statement, database: database)
        try bind(event.occurredAt.timeIntervalSince1970, at: 3, to: statement, database: database)
        try bind(Date().timeIntervalSince1970, at: 4, to: statement, database: database)
        try bind(Int64(event.schemaVersion), at: 5, to: statement, database: database)
        try bind((event.learnerEpoch ?? defaultEpoch).uuidString, at: 6, to: statement, database: database)
        try bindOptional(event.sessionID?.uuidString, at: 7, to: statement, database: database)
        try bindOptional(event.knowledgePointID, at: 8, to: statement, database: database)
        try bindOptional(event.sourceTurnID?.uuidString, at: 9, to: statement, database: database)
        try bindOptional(event.correlationID?.uuidString, at: 10, to: statement, database: database)
        try bindOptional(event.causationID?.uuidString, at: 11, to: statement, database: database)
        try bind(event.idempotencyKey, at: 12, to: statement, database: database)
        try bind(event.producer, at: 13, to: statement, database: database)
        try bindOptional(event.model, at: 14, to: statement, database: database)
        try bindOptional(event.promptVersion, at: 15, to: statement, database: database)
        try bind(event.payloadJSON, at: 16, to: statement, database: database)
        try stepDone(statement, database: database)
        return sqlite3_changes(database) > 0
    }

    private func readEvents(_ database: OpaquePointer) throws -> [LearningEventRecord] {
        let statement = try prepare(
            """
            SELECT
                sequence, event_id, event_type, occurred_at, recorded_at,
                schema_version, learner_epoch, session_id, knowledge_point_id,
                source_turn_id, correlation_id, causation_id, idempotency_key,
                producer, model, prompt_version, payload_json
            FROM learning_events
            ORDER BY sequence ASC;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var events: [LearningEventRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let eventIDText = columnText(statement, at: 1),
                let eventID = UUID(uuidString: eventIDText),
                let typeText = columnText(statement, at: 2),
                let type = LearningEventType(rawValue: typeText),
                let epochText = columnText(statement, at: 6),
                let epoch = UUID(uuidString: epochText),
                let idempotencyKey = columnText(statement, at: 12),
                let producer = columnText(statement, at: 13),
                let payloadJSON = columnText(statement, at: 16)
            else {
                throw LearningStoreError.invalidPayload
            }
            events.append(
                LearningEventRecord(
                    sequence: sqlite3_column_int64(statement, 0),
                    id: eventID,
                    type: type,
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    schemaVersion: Int(sqlite3_column_int64(statement, 5)),
                    learnerEpoch: epoch,
                    sessionID: columnUUID(statement, at: 7),
                    knowledgePointID: columnText(statement, at: 8),
                    sourceTurnID: columnUUID(statement, at: 9),
                    correlationID: columnUUID(statement, at: 10),
                    causationID: columnUUID(statement, at: 11),
                    idempotencyKey: idempotencyKey,
                    producer: producer,
                    model: columnText(statement, at: 14),
                    promptVersion: columnText(statement, at: 15),
                    payloadJSON: payloadJSON
                )
            )
        }
        return events
    }

    private func insertKnowledge(
        _ snapshot: KnowledgePointSnapshot,
        database: OpaquePointer
    ) throws {
        let data = try projectionEncoder.encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LearningStoreError.invalidPayload
        }
        let statement = try prepare(
            """
            INSERT INTO learning_knowledge_projection (
                knowledge_point_id, snapshot_json, mastery, confidence,
                due_at, lifecycle, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(snapshot.id, at: 1, to: statement, database: database)
        try bind(json, at: 2, to: statement, database: database)
        try bind(snapshot.mastery, at: 3, to: statement, database: database)
        try bind(snapshot.confidence, at: 4, to: statement, database: database)
        try bindOptional(snapshot.dueAt?.timeIntervalSince1970, at: 5, to: statement, database: database)
        try bind(snapshot.lifecycle.rawValue, at: 6, to: statement, database: database)
        try bind((snapshot.lastEvidenceAt ?? Date()).timeIntervalSince1970, at: 7, to: statement, database: database)
        try stepDone(statement, database: database)
    }

    private func insertSession(
        _ snapshot: LearningSessionSnapshot,
        database: OpaquePointer
    ) throws {
        let data = try projectionEncoder.encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LearningStoreError.invalidPayload
        }
        let statement = try prepare(
            """
            INSERT INTO learning_session_projection (
                session_id, status, updated_at, snapshot_json
            )
            VALUES (?, ?, ?, ?);
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(snapshot.id.uuidString, at: 1, to: statement, database: database)
        try bind(snapshot.status.rawValue, at: 2, to: statement, database: database)
        try bind(snapshot.updatedAt.timeIntervalSince1970, at: 3, to: statement, database: database)
        try bind(json, at: 4, to: statement, database: database)
        try stepDone(statement, database: database)
    }

    private func insertCoverage(
        _ coverage: SourceCoverage,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO learning_source_projection (
                turn_id, analyzer_version, input_language,
                is_proficiency_evidence, analyzed_at
            )
            VALUES (?, ?, ?, ?, ?);
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(coverage.turnID.uuidString, at: 1, to: statement, database: database)
        try bind(coverage.analyzerVersion, at: 2, to: statement, database: database)
        try bind(coverage.inputLanguage.rawValue, at: 3, to: statement, database: database)
        try bind(coverage.isProficiencyEvidence ? Int64(1) : Int64(0), at: 4, to: statement, database: database)
        try bind(coverage.analyzedAt.timeIntervalSince1970, at: 5, to: statement, database: database)
        try stepDone(statement, database: database)
    }

    private func readKnowledge(_ database: OpaquePointer) throws -> [KnowledgePointSnapshot] {
        let statement = try prepare(
            """
            SELECT snapshot_json
            FROM learning_knowledge_projection
            ORDER BY
                CASE WHEN due_at IS NOT NULL AND due_at <= strftime('%s', 'now') THEN 0 ELSE 1 END,
                mastery ASC,
                confidence DESC;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        var snapshots: [KnowledgePointSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let json = columnText(statement, at: 0),
                  let data = json.data(using: .utf8) else {
                throw LearningStoreError.invalidPayload
            }
            snapshots.append(try projectionDecoder.decode(KnowledgePointSnapshot.self, from: data))
        }
        return snapshots
    }

    private func readActiveSession(_ database: OpaquePointer) throws -> LearningSessionSnapshot? {
        let statement = try prepare(
            """
            SELECT snapshot_json
            FROM learning_session_projection
            WHERE status IN ('active', 'paused')
            ORDER BY updated_at DESC
            LIMIT 1;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let json = columnText(statement, at: 0),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try projectionDecoder.decode(LearningSessionSnapshot.self, from: data)
    }

    private func readLatestCompletedSession(
        _ database: OpaquePointer
    ) throws -> LearningSessionSnapshot? {
        let statement = try prepare(
            """
            SELECT snapshot_json
            FROM learning_session_projection
            WHERE status = 'completed'
            ORDER BY updated_at DESC
            LIMIT 1;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let json = columnText(statement, at: 0),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try projectionDecoder.decode(LearningSessionSnapshot.self, from: data)
    }

    private func readCoverageSummary(
        _ database: OpaquePointer
    ) throws -> (count: Int, eligibleCount: Int, lastAnalyzedAt: Date?) {
        let statement = try prepare(
            """
            SELECT
                COUNT(*),
                COALESCE(SUM(is_proficiency_evidence), 0),
                MAX(analyzed_at)
            FROM learning_source_projection;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        let eligible = Int(sqlite3_column_int64(statement, 1))
        let last = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return (count, eligible, last)
    }

    private var projectionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var projectionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw LearningStoreError.database(message)
        }
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        return statement
    }

    private func bind(
        _ value: String,
        at index: Int32,
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, learningSQLiteTransient)
        }
        guard result == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ value: Double,
        at index: Int32,
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ value: Int64,
        at index: Int32,
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bindOptional(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        if let value {
            try bind(value, at: index, to: statement, database: database)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw databaseError(database)
            }
        }
    }

    private func bindOptional(
        _ value: Double?,
        at index: Int32,
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        if let value {
            try bind(value, at: index, to: statement, database: database)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw databaseError(database)
            }
        }
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func columnUUID(_ statement: OpaquePointer, at index: Int32) -> UUID? {
        columnText(statement, at: index).flatMap(UUID.init(uuidString:))
    }

    private func databaseError(_ database: OpaquePointer) -> LearningStoreError {
        LearningStoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}

private struct SourceCoverage {
    let turnID: UUID
    let analyzerVersion: String
    let inputLanguage: LearningInputLanguage
    let isProficiencyEvidence: Bool
    let analyzedAt: Date
}

private struct MutableKnowledge {
    let definition: KnowledgePointDefinition
    var mastery = 0.50
    var confidence = 0.0
    var lifecycle = KnowledgeLifecycleState.unobserved
    var weightedEvidenceCount = 0.0
    var realChatErrorCount = 0
    var realChatCorrectCount = 0
    var successfulAttempts = 0
    var lapseCount = 0
    var dueAt: Date?
    var lastEvidenceAt: Date?
    var lastSuccessAt: Date?
    var successSessions = Set<UUID>()
    var successfulQuestionTypes = Set<LearningQuestionType>()
    var hasFreeProduction = false
    var hasDelayedSuccess = false
    var sourceExcerpt = ""
    var correctedForm = ""
    var explanationZH = ""

    var snapshot: KnowledgePointSnapshot {
        KnowledgePointSnapshot(
            id: definition.id,
            title: definition.title,
            dimension: definition.dimension,
            mastery: mastery,
            confidence: confidence,
            lifecycle: lifecycle,
            weightedEvidenceCount: weightedEvidenceCount,
            realChatErrorCount: realChatErrorCount,
            realChatCorrectCount: realChatCorrectCount,
            successfulAttempts: successfulAttempts,
            lapseCount: lapseCount,
            dueAt: dueAt,
            lastEvidenceAt: lastEvidenceAt,
            sourceExcerpt: sourceExcerpt,
            correctedForm: correctedForm,
            explanationZH: explanationZH
        )
    }
}

private struct ProjectionState {
    var currentEpoch: UUID?
    var knowledge: [String: MutableKnowledge] = [:]
    var sessions: [UUID: LearningSessionSnapshot] = [:]
    var coverage: [UUID: SourceCoverage] = [:]
}

private enum ProjectionReducer {
    static func reduce(_ events: [LearningEventRecord]) throws -> ProjectionState {
        var state = ProjectionState()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for event in events {
            state.currentEpoch = event.learnerEpoch
            switch event.type {
            case .sourceTurnAnalysisCompleted:
                let payload = try decode(
                    SourceTurnAnalysisCompletedPayload.self,
                    event: event,
                    decoder: decoder
                )
                state.coverage[payload.sourceTurnID] = SourceCoverage(
                    turnID: payload.sourceTurnID,
                    analyzerVersion: payload.analyzerVersion,
                    inputLanguage: payload.inputLanguage,
                    isProficiencyEvidence: payload.isProficiencyEvidence,
                    analyzedAt: event.occurredAt
                )

            case .errorEvidenceObserved, .correctUsageObserved,
                 .learningInterestObserved, .levelEvidenceObserved:
                let payload = try decode(
                    EvidenceObservedPayload.self,
                    event: event,
                    decoder: decoder
                )
                applyEvidence(payload, event: event, state: &state)

            case .learningSessionStarted:
                let payload = try decode(
                    LearningSessionStartedPayload.self,
                    event: event,
                    decoder: decoder
                )
                state.sessions[payload.sessionID] = LearningSessionSnapshot(
                    id: payload.sessionID,
                    status: .active,
                    startedAt: payload.startedAt,
                    updatedAt: event.occurredAt
                )

            case .sessionFocusSelected:
                let payload = try decode(
                    SessionFocusSelectedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID] else { continue }
                session.focusKnowledgePointID = payload.knowledgePointID
                session.focusTitle = payload.title
                session.focusReason = payload.reason
                session.updatedAt = event.occurredAt
                state.sessions[payload.sessionID] = session
                ensureKnowledge(payload.knowledgePointID, title: payload.title, state: &state)

            case .questionPresented:
                let payload = try decode(
                    QuestionPresentedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID] else { continue }
                session.attempts.append(
                    LearningAttemptSnapshot(id: payload.id, question: payload)
                )
                session.updatedAt = event.occurredAt
                state.sessions[payload.sessionID] = session

            case .hintRequested:
                let payload = try decode(
                    HintRequestedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID],
                      let index = session.attempts.lastIndex(where: {
                          $0.question.id == payload.questionID
                      }) else {
                    continue
                }
                session.attempts[index].hintUsed = true
                session.updatedAt = event.occurredAt
                state.sessions[payload.sessionID] = session

            case .answerSubmitted:
                let payload = try decode(
                    AnswerSubmittedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID],
                      let index = session.attempts.lastIndex(where: {
                          $0.question.id == payload.questionID
                      }) else {
                    continue
                }
                session.attempts[index].answerID = payload.answerID
                session.attempts[index].answer = payload.answer
                session.updatedAt = event.occurredAt
                state.sessions[payload.sessionID] = session

            case .answerGraded:
                let payload = try decode(
                    AnswerGradedPayload.self,
                    event: event,
                    decoder: decoder
                )
                if var session = state.sessions[payload.sessionID],
                   let index = session.attempts.lastIndex(where: {
                       $0.question.id == payload.questionID
                   }) {
                    session.attempts[index].grade = payload
                    session.updatedAt = event.occurredAt
                    state.sessions[payload.sessionID] = session
                }
                applyGrade(payload, event: event, state: &state)

            case .questionSkipped:
                let payload = try decode(
                    QuestionSkippedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID],
                      let index = session.attempts.lastIndex(where: {
                          $0.question.id == payload.questionID
                      }) else {
                    continue
                }
                session.attempts[index].skipped = true
                session.updatedAt = event.occurredAt
                state.sessions[payload.sessionID] = session

            case .learningSessionPaused:
                if let sessionID = event.sessionID, var session = state.sessions[sessionID] {
                    session.status = .paused
                    session.updatedAt = event.occurredAt
                    state.sessions[sessionID] = session
                }

            case .learningSessionResumed:
                if let sessionID = event.sessionID, var session = state.sessions[sessionID] {
                    session.status = .active
                    session.updatedAt = event.occurredAt
                    state.sessions[sessionID] = session
                }

            case .learningSessionCompleted:
                let payload = try decode(
                    LearningSessionCompletedPayload.self,
                    event: event,
                    decoder: decoder
                )
                guard var session = state.sessions[payload.sessionID] else { continue }
                session.status = .completed
                session.outcome = payload.outcome
                session.summary = payload.summary
                session.updatedAt = payload.completedAt
                state.sessions[payload.sessionID] = session

            case .learningEpochStarted:
                let payload = try decode(
                    LearningEpochStartedPayload.self,
                    event: event,
                    decoder: decoder
                )
                state.currentEpoch = payload.epochID
                state.sessions.removeAll()
                if payload.keepExtractedEvidence {
                    for id in state.knowledge.keys {
                        guard var knowledge = state.knowledge[id] else { continue }
                        knowledge.successfulAttempts = 0
                        knowledge.lapseCount = 0
                        knowledge.successSessions.removeAll()
                        knowledge.successfulQuestionTypes.removeAll()
                        knowledge.hasFreeProduction = false
                        knowledge.hasDelayedSuccess = false
                        knowledge.lastSuccessAt = nil
                        knowledge.mastery = min(
                            0.70,
                            max(
                                0.20,
                                0.50
                                    + Double(knowledge.realChatCorrectCount) * 0.06
                                    - Double(knowledge.realChatErrorCount) * 0.08
                            )
                        )
                        knowledge.lifecycle = knowledge.realChatErrorCount > 0
                            ? .weaknessDetected
                            : .unobserved
                        knowledge.dueAt = knowledge.realChatErrorCount > 0 ? payload.startedAt : nil
                        state.knowledge[id] = knowledge
                    }
                } else {
                    state.knowledge.removeAll()
                    state.coverage.removeAll()
                }

            case .sourceTurnAnalysisFailed, .analysisEvidenceSuperseded,
                 .explanationPresented:
                continue
            }
        }
        return state
    }

    private static func applyEvidence(
        _ payload: EvidenceObservedPayload,
        event: LearningEventRecord,
        state: inout ProjectionState
    ) {
        guard payload.isProficiencyEvidence || event.type == .learningInterestObserved else {
            return
        }
        ensureKnowledge(payload.knowledgePointID, title: payload.title, state: &state)
        guard var knowledge = state.knowledge[payload.knowledgePointID] else { return }

        let weight = payload.severity.weight * min(1, max(0, payload.confidence))
        knowledge.weightedEvidenceCount += weight
        knowledge.confidence = confidence(for: knowledge.weightedEvidenceCount)
        knowledge.lastEvidenceAt = event.occurredAt
        if !payload.sourceExcerpt.isEmpty {
            knowledge.sourceExcerpt = payload.sourceExcerpt
        }
        if !payload.correctedForm.isEmpty {
            knowledge.correctedForm = payload.correctedForm
        }
        if !payload.explanationZH.isEmpty {
            knowledge.explanationZH = payload.explanationZH
        }

        switch event.type {
        case .errorEvidenceObserved:
            knowledge.realChatErrorCount += 1
            let rate = min(0.30, 0.12 + 0.18 * weight)
            knowledge.mastery += rate * (0 - knowledge.mastery)
            knowledge.lifecycle = knowledge.lifecycle == .maintained ? .lapsed : .weaknessDetected
            knowledge.dueAt = event.occurredAt

        case .correctUsageObserved:
            knowledge.realChatCorrectCount += 1
            let rate = min(0.26, 0.10 + 0.16 * weight)
            knowledge.mastery += rate * (1 - knowledge.mastery)
            if knowledge.lifecycle == .unobserved {
                knowledge.lifecycle = .consolidating
            }

        case .learningInterestObserved:
            if knowledge.lifecycle == .unobserved {
                knowledge.lifecycle = .learning
                knowledge.dueAt = event.occurredAt
            }

        default:
            break
        }
        knowledge.mastery = min(1, max(0, knowledge.mastery))
        state.knowledge[payload.knowledgePointID] = knowledge
    }

    private static func applyGrade(
        _ payload: AnswerGradedPayload,
        event: LearningEventRecord,
        state: inout ProjectionState
    ) {
        ensureKnowledge(payload.knowledgePointID, title: "", state: &state)
        guard var knowledge = state.knowledge[payload.knowledgePointID],
              let baseScore = payload.verdict.baseScore else {
            return
        }

        var effectiveScore = baseScore
        if payload.usedHint {
            effectiveScore *= 0.65
        }
        if payload.isRetry {
            effectiveScore *= 0.75
        }
        let weight = payload.questionType.evidenceWeight * min(1, max(0, payload.confidence))
        let learningRate = min(0.35, max(0.12, 0.12 + 0.18 * weight))
        knowledge.mastery += learningRate * (effectiveScore - knowledge.mastery)
        knowledge.mastery = min(1, max(0, knowledge.mastery))
        knowledge.weightedEvidenceCount += weight
        knowledge.confidence = confidence(for: knowledge.weightedEvidenceCount)
        knowledge.lastEvidenceAt = event.occurredAt

        let success = payload.targetDemonstrated
            && (payload.verdict == .correct || payload.verdict == .acceptable)
            && effectiveScore >= 0.58
        if success {
            if let lastSuccessAt = knowledge.lastSuccessAt,
               event.occurredAt.timeIntervalSince(lastSuccessAt) >= 3 * 86_400 {
                knowledge.hasDelayedSuccess = true
            }
            knowledge.lastSuccessAt = event.occurredAt
            knowledge.successfulAttempts += 1
            knowledge.successSessions.insert(payload.sessionID)
            knowledge.successfulQuestionTypes.insert(payload.questionType)
            knowledge.hasFreeProduction = knowledge.hasFreeProduction
                || payload.questionType == .freeProduction
                || payload.questionType == .chineseToEnglish
            knowledge.lifecycle = .consolidating
            let intervals = [1, 3, 7, 14, 30, 60, 120]
            let index = min(max(0, knowledge.successfulAttempts - 1), intervals.count - 1)
            knowledge.dueAt = Calendar.current.date(
                byAdding: .day,
                value: intervals[index],
                to: event.occurredAt
            )
        } else if payload.verdict == .incorrect || payload.verdict == .needsImprovement {
            knowledge.lapseCount += 1
            knowledge.lifecycle = knowledge.successfulAttempts > 0 ? .lapsed : .learning
            knowledge.dueAt = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: event.occurredAt
            )
        }

        if knowledge.mastery >= 0.85,
           knowledge.successfulAttempts >= 3,
           knowledge.successSessions.count >= 2,
           knowledge.successfulQuestionTypes.count >= 2,
           knowledge.hasFreeProduction,
           knowledge.hasDelayedSuccess {
            knowledge.lifecycle = .maintained
        } else if knowledge.mastery >= 0.78, knowledge.successfulAttempts >= 2 {
            knowledge.lifecycle = .masteryCandidate
        }
        state.knowledge[payload.knowledgePointID] = knowledge
    }

    private static func ensureKnowledge(
        _ id: String,
        title: String,
        state: inout ProjectionState
    ) {
        guard state.knowledge[id] == nil else { return }
        let known = LearningTaxonomy.definition(for: id)
        let definition = known ?? KnowledgePointDefinition(
            id: id,
            title: title.isEmpty ? LearningTaxonomy.fallback.title : title,
            dimension: LearningTaxonomy.fallback.dimension
        )
        state.knowledge[id] = MutableKnowledge(definition: definition)
    }

    private static func confidence(for weightedEvidence: Double) -> Double {
        min(1, max(0, 1 - Foundation.exp(-weightedEvidence / 4)))
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        event: LearningEventRecord,
        decoder: JSONDecoder
    ) throws -> T {
        guard event.schemaVersion == 1,
              let data = event.payloadJSON.data(using: .utf8) else {
            throw LearningStoreError.unsupportedEvent(event.type.rawValue)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LearningStoreError.invalidPayload
        }
    }
}

private let learningSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
