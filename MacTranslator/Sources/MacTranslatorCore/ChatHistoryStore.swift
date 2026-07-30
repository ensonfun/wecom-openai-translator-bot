import Foundation
import SQLite3

public enum ChatHistoryStoreError: LocalizedError {
    case database(String)
    case invalidRow

    public var errorDescription: String? {
        switch self {
        case .database(let message):
            return "Chat history database error: \(message)"
        case .invalidRow:
            return "The chat history database contains an invalid message."
        }
    }
}

public struct ChatHistoryStore: Sendable {
    public let databaseURL: URL
    public let legacyJSONURL: URL

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
        legacyJSONURL = directory.appendingPathComponent("chat-history.json", isDirectory: false)
    }

    public func load() throws -> [ChatMessage] {
        try withDatabase { database in
            try migrateLegacyJSONIfNeeded(database)
            return try readMessages(database)
        }
    }

    public func loadRecent(limit: Int) throws -> [ChatMessage] {
        guard limit > 0 else { return [] }
        return try withDatabase { database in
            try migrateLegacyJSONIfNeeded(database)
            return try readRecentMessages(database, limit: limit)
        }
    }

    public func messageCount() throws -> Int {
        try withDatabase { database in
            try migrateLegacyJSONIfNeeded(database)
            let statement = try prepare("SELECT COUNT(*) FROM messages;", database: database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(database)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func learningSourceTurns() throws -> [LearningSourceTurn] {
        let (messages, completedTurnIDs) = try withDatabase { database in
            try migrateLegacyJSONIfNeeded(database)
            return (
                try readMessages(database),
                try readCompletedTurnIDs(database)
            )
        }
        var turns: [LearningSourceTurn] = []
        var assistantByTurnID: [UUID: ChatMessage] = [:]

        for message in messages where message.role == .assistant {
            if let turnID = message.turnID {
                assistantByTurnID[turnID] = message
            }
        }

        for (index, message) in messages.enumerated() {
            guard message.role == .user else {
                continue
            }
            if let turnID = message.turnID,
               message.origin == .native,
               !completedTurnIDs.contains(turnID) {
                continue
            }

            let turnID = message.turnID ?? message.id
            var assistant = message.turnID.flatMap { assistantByTurnID[$0] }
            if assistant == nil, message.turnID == nil, messages.indices.contains(index + 1) {
                let candidate = messages[index + 1]
                if candidate.role == .assistant,
                   candidate.mode == message.mode,
                   candidate.turnID == nil {
                    assistant = candidate
                }
            }

            turns.append(
                LearningSourceTurn(
                    id: turnID,
                    mode: message.mode,
                    userText: message.text,
                    assistantText: assistant?.text.isEmpty == false ? assistant?.text : nil,
                    createdAt: message.createdAt,
                    origin: message.origin
                )
            )
        }
        return turns
    }

    public func upsert(_ message: ChatMessage, position: Int) throws {
        try withDatabase { database in
            try upsert(message, position: position, database: database)
        }
    }

    public func append(_ message: ChatMessage) throws {
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                let position: Int = try {
                    let statement = try prepare(
                        "SELECT COALESCE(MAX(position), -1) + 1 FROM messages;",
                        database: database
                    )
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw databaseError(database)
                    }
                    return Int(sqlite3_column_int64(statement, 0))
                }()
                try upsert(message, position: position, database: database)
                try execute("COMMIT;", database: database)
            } catch {
                try? execute("ROLLBACK;", database: database)
                throw error
            }
        }
    }

    public func updateText(id: UUID, text: String) throws {
        try withDatabase { database in
            let sql = "UPDATE messages SET text = ? WHERE id = ?;"
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(text, at: 1, to: statement, database: database)
            try bind(id.uuidString, at: 2, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    public func upsertTurn(_ turn: ChatTurn) throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO chat_turns (
                id, mode, user_message_id, assistant_message_id, created_at,
                completed_at, status, model, prompt_fingerprint, origin
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mode = excluded.mode,
                user_message_id = excluded.user_message_id,
                assistant_message_id = excluded.assistant_message_id,
                created_at = excluded.created_at,
                completed_at = excluded.completed_at,
                status = excluded.status,
                model = excluded.model,
                prompt_fingerprint = excluded.prompt_fingerprint,
                origin = excluded.origin;
            """
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(turn.id.uuidString, at: 1, to: statement, database: database)
            try bind(turn.mode.rawValue, at: 2, to: statement, database: database)
            try bind(turn.userMessageID.uuidString, at: 3, to: statement, database: database)
            try bindOptional(
                turn.assistantMessageID?.uuidString,
                at: 4,
                to: statement,
                database: database
            )
            try bind(turn.createdAt.timeIntervalSince1970, at: 5, to: statement, database: database)
            try bindOptional(
                turn.completedAt?.timeIntervalSince1970,
                at: 6,
                to: statement,
                database: database
            )
            try bind(turn.status.rawValue, at: 7, to: statement, database: database)
            try bind(turn.model, at: 8, to: statement, database: database)
            try bind(turn.promptFingerprint, at: 9, to: statement, database: database)
            try bind(turn.origin.rawValue, at: 10, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    public func delete(id: UUID) throws {
        try withDatabase { database in
            let statement = try prepare("DELETE FROM messages WHERE id = ?;", database: database)
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, at: 1, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    public func replaceAll(_ messages: [ChatMessage]) throws {
        try withDatabase { database in
            try replaceAll(messages, database: database)
        }
    }

    public func clear() throws {
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                try execute("DELETE FROM chat_turns;", database: database)
                try execute("DELETE FROM messages;", database: database)
                try execute("COMMIT;", database: database)
            } catch {
                try? execute("ROLLBACK;", database: database)
                throw error
            }
        }
        if FileManager.default.fileExists(atPath: legacyJSONURL.path) {
            try FileManager.default.removeItem(at: legacyJSONURL)
        }
    }

    public func exportJSON(to destinationURL: URL) throws {
        let messages = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(messages)
        try data.write(to: destinationURL, options: .atomic)
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
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let database { sqlite3_close(database) }
            throw ChatHistoryStoreError.database(message)
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL;", database: database)
        try execute("PRAGMA synchronous=NORMAL;", database: database)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                mode TEXT NOT NULL,
                turn_id TEXT,
                created_at REAL NOT NULL DEFAULT 0,
                origin TEXT NOT NULL DEFAULT 'legacy'
            );
            """,
            database: database
        )
        try addColumnIfNeeded(
            table: "messages",
            column: "turn_id",
            definition: "TEXT",
            database: database
        )
        try addColumnIfNeeded(
            table: "messages",
            column: "created_at",
            definition: "REAL NOT NULL DEFAULT 0",
            database: database
        )
        try addColumnIfNeeded(
            table: "messages",
            column: "origin",
            definition: "TEXT NOT NULL DEFAULT 'legacy'",
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS messages_position_idx ON messages(position);",
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chat_turns (
                id TEXT PRIMARY KEY NOT NULL,
                mode TEXT NOT NULL,
                user_message_id TEXT NOT NULL,
                assistant_message_id TEXT,
                created_at REAL NOT NULL,
                completed_at REAL,
                status TEXT NOT NULL,
                model TEXT NOT NULL,
                prompt_fingerprint TEXT NOT NULL,
                origin TEXT NOT NULL
            );
            """,
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS chat_turns_created_idx ON chat_turns(created_at);",
            database: database
        )
        return try body(database)
    }

    private func readMessages(_ database: OpaquePointer) throws -> [ChatMessage] {
        let statement = try prepare(
            """
            SELECT id, role, text, mode, turn_id, created_at, origin
            FROM messages
            ORDER BY position ASC;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = columnText(statement, at: 0),
                let id = UUID(uuidString: idText),
                let roleText = columnText(statement, at: 1),
                let role = ChatMessage.Role(rawValue: roleText),
                let text = columnText(statement, at: 2),
                let modeText = columnText(statement, at: 3),
                let mode = CommandMode(rawValue: modeText),
                let originText = columnText(statement, at: 6),
                let origin = ChatMessage.Origin(rawValue: originText)
            else {
                throw ChatHistoryStoreError.invalidRow
            }
            let turnID = columnText(statement, at: 4).flatMap(UUID.init(uuidString:))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            messages.append(
                ChatMessage(
                    id: id,
                    role: role,
                    text: text,
                    mode: mode,
                    turnID: turnID,
                    createdAt: createdAt,
                    origin: origin
                )
            )
        }
        return messages
    }

    private func readRecentMessages(
        _ database: OpaquePointer,
        limit: Int
    ) throws -> [ChatMessage] {
        let statement = try prepare(
            """
            SELECT id, role, text, mode, turn_id, created_at, origin
            FROM messages
            ORDER BY position DESC
            LIMIT ?;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(limit)) == SQLITE_OK else {
            throw databaseError(database)
        }

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = columnText(statement, at: 0),
                let id = UUID(uuidString: idText),
                let roleText = columnText(statement, at: 1),
                let role = ChatMessage.Role(rawValue: roleText),
                let text = columnText(statement, at: 2),
                let modeText = columnText(statement, at: 3),
                let mode = CommandMode(rawValue: modeText),
                let originText = columnText(statement, at: 6),
                let origin = ChatMessage.Origin(rawValue: originText)
            else {
                throw ChatHistoryStoreError.invalidRow
            }
            let turnID = columnText(statement, at: 4).flatMap(UUID.init(uuidString:))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            messages.append(
                ChatMessage(
                    id: id,
                    role: role,
                    text: text,
                    mode: mode,
                    turnID: turnID,
                    createdAt: createdAt,
                    origin: origin
                )
            )
        }
        return Array(messages.reversed())
    }

    private func readCompletedTurnIDs(_ database: OpaquePointer) throws -> Set<UUID> {
        let statement = try prepare(
            "SELECT id FROM chat_turns WHERE status = ?;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(ChatTurn.Status.completed.rawValue, at: 1, to: statement, database: database)

        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = columnText(statement, at: 0),
               let id = UUID(uuidString: text) {
                ids.insert(id)
            }
        }
        return ids
    }

    private func replaceAll(_ messages: [ChatMessage], database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;", database: database)
        do {
            try execute("DELETE FROM messages;", database: database)
            for (position, message) in messages.enumerated() {
                try upsert(message, position: position, database: database)
            }
            try execute("COMMIT;", database: database)
        } catch {
            try? execute("ROLLBACK;", database: database)
            throw error
        }
    }

    private func upsert(_ message: ChatMessage, position: Int, database: OpaquePointer) throws {
        let sql = """
        INSERT INTO messages (id, position, role, text, mode, turn_id, created_at, origin)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            position = excluded.position,
            role = excluded.role,
            text = excluded.text,
            mode = excluded.mode,
            turn_id = excluded.turn_id,
            created_at = excluded.created_at,
            origin = excluded.origin;
        """
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }

        try bind(message.id.uuidString, at: 1, to: statement, database: database)
        guard sqlite3_bind_int64(statement, 2, Int64(position)) == SQLITE_OK else {
            throw databaseError(database)
        }
        try bind(message.role.rawValue, at: 3, to: statement, database: database)
        try bind(message.text, at: 4, to: statement, database: database)
        try bind(message.mode.rawValue, at: 5, to: statement, database: database)
        try bindOptional(
            message.turnID?.uuidString,
            at: 6,
            to: statement,
            database: database
        )
        try bind(message.createdAt.timeIntervalSince1970, at: 7, to: statement, database: database)
        try bind(message.origin.rawValue, at: 8, to: statement, database: database)
        try stepDone(statement, database: database)
    }

    private func migrateLegacyJSONIfNeeded(_ database: OpaquePointer) throws {
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }

        let countStatement = try prepare("SELECT COUNT(*) FROM messages;", database: database)
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        let existingCount = sqlite3_column_int64(countStatement, 0)

        if existingCount == 0 {
            let data = try Data(contentsOf: legacyJSONURL)
            let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            try replaceAll(messages, database: database)
        }
        try FileManager.default.removeItem(at: legacyJSONURL)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw ChatHistoryStoreError.database(message)
        }
    }

    private func addColumnIfNeeded(
        table: String,
        column: String,
        definition: String,
        database: OpaquePointer
    ) throws {
        let statement = try prepare("PRAGMA table_info(\(table));", database: database)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, at: 1) == column {
                return
            }
        }
        try execute(
            "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);",
            database: database
        )
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
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
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
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func databaseError(_ database: OpaquePointer) -> ChatHistoryStoreError {
        ChatHistoryStoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
