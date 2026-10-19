import Foundation
import GRDB

/// The Listening library (`listening.sqlite`): dictations, transcriptions, vocabulary, snippets,
/// summaries and full-text search. Safe to share across threads.
public final class TBDListeningDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter
    public let url: URL?

    /// Opens (and migrates) the database at `url`. `readOnly` opens without migrating.
    public init(url: URL = TBDListeningPaths.database, readOnly: Bool = false) throws {
        self.url = url
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.busyMode = .timeout(5)
        if readOnly {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TBDSpeechError.audioUnreadable("No Listen library exists yet.")
            }
            writer = try DatabasePool(path: url.path, configuration: configuration)
        } else {
            try TBDListeningPaths.ensure(url.deletingLastPathComponent())
            writer = try DatabasePool(path: url.path, configuration: configuration)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Self.migrator.migrate(writer)
        }
    }

    /// In-memory database for tests.
    public init(inMemory: Void) throws {
        url = nil
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictation") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("durationMs", .integer).notNull()
                t.column("rawText", .text).notNull()
                t.column("cleanText", .text)
                t.column("targetApp", .text)
                t.column("audioPath", .text)
                t.column("engine", .text)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "transcription") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("sourceKind", .text).notNull()
                t.column("sourcePath", .text)
                t.column("sourceURL", .text)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("language", .text)
                t.column("engine", .text)
                t.column("status", .text).notNull()
                t.column("errorMessage", .text)
                t.column("rawText", .text).notNull().defaults(to: "")
                t.column("cleanText", .text)
                t.column("segments", .jsonText).notNull().defaults(to: "[]")
                t.column("words", .jsonText).notNull().defaults(to: "[]")
                t.column("speakers", .jsonText).notNull().defaults(to: "[]")
                t.column("audioPaths", .jsonText).notNull().defaults(to: "[]")
            }
            try db.create(table: "customWord") { t in
                t.primaryKey("id", .text)
                t.column("word", .text).notNull()
                t.column("replacement", .text)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "snippet") { t in
                t.primaryKey("id", .text)
                t.column("trigger", .text).notNull()
                t.column("expansion", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "summary") { t in
                t.primaryKey("id", .text)
                t.column("transcriptionId", .text).notNull().indexed()
                    .references("transcription", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(virtualTable: "transcription_ft", using: FTS5()) { t in
                t.synchronize(withTable: "transcription")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("rawText")
                t.column("cleanText")
            }
            try db.create(virtualTable: "dictation_ft", using: FTS5()) { t in
                t.synchronize(withTable: "dictation")
                t.tokenizer = .unicode61()
                t.column("rawText")
                t.column("cleanText")
            }
        }
        // Retention: record kinds and the audio retention clock.
        migrator.registerMigration("v2-retention") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "kind", .text).notNull().defaults(to: TBDDictationKind.dictation.rawValue)
            }
            try db.execute(sql: "UPDATE dictation SET kind = 'voiceNote' WHERE targetApp = 'TBD Voice note'")
            try db.execute(sql: "UPDATE dictation SET kind = 'chat' WHERE targetApp = 'TBD Chat'")
            try db.create(index: "dictation_kind_createdAt", on: "dictation", columns: ["kind", "createdAt"])
            try db.alter(table: "transcription") { t in t.add(column: "audioRetentionStartedAt", .datetime) }
            try db.create(index: "transcription_kind_createdAt", on: "transcription", columns: ["sourceKind", "createdAt"])
        }
        // Meeting notes and saved Ask conversations.
        migrator.registerMigration("v3-notes-ask") { db in
            try db.alter(table: "transcription") { t in t.add(column: "userNotes", .text) }
            try db.create(table: "askConversation") { t in
                t.primaryKey("id", .text)
                t.column("transcriptionId", .text).notNull().indexed().references("transcription", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("messages", .jsonText).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        // Manual transcript edits, replayed over the recognised words.
        migrator.registerMigration("v4-transcript-edits") { db in
            try db.create(table: "transcriptCorrection") { t in
                t.primaryKey("id", .text)
                t.column("transcriptionId", .text).notNull().indexed().references("transcription", onDelete: .cascade)
                t.column("sequence", .integer).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("edit", .jsonText).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        // Unused since C284 (TBD v2 never imports the v1 library); the table stays so the schema migrations stay append-only.
        migrator.registerMigration("v5-legacy-import") { db in
            try db.create(table: "legacyImport") { t in
                t.primaryKey("source", .text)
                t.column("sourcePath", .text).notNull()
                t.column("completedAt", .datetime).notNull()
                t.column("summary", .text).notNull()
            }
        }
        // Snippets can carry a key action ("return") instead of text, as in v1 vocabulary backups.
        migrator.registerMigration("v6-transcribe-vocab") { db in
            try db.alter(table: "snippet") { t in t.add(column: "action", .text) }
        }
        // Dictation end status, for "Preserve discarded dictations" (v1 stored `cancelled` rows in History).
        migrator.registerMigration("v6-dictation-autosave") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "status", .text).notNull().defaults(to: TBDDictationStatus.completed.rawValue)
            }
        }
        // Prompt library, Transforms, quick prompts and Transform history (see `TBDPromptLibrary`).
        migrator.registerMigration("v6-prompts-transforms") { db in try TBDPromptLibrary.migrate(db) }
        // Knowledge documents created from transcripts ("Save to Knowledge", see `TBDKnowledgeLink`).
        migrator.registerMigration("v6-knowledge") { db in
            try db.create(table: "knowledgeDocument") { t in
                t.primaryKey("transcriptionId", .text).references("transcription", onDelete: .cascade)
                t.column("documentId", .text).notNull()
                t.column("area", .text)
                t.column("savedAt", .datetime).notNull()
            }
        }
        // Favorites: the star on library items (v1 `isFavorite`).
        migrator.registerMigration("v7-favorites") { db in
            try db.alter(table: "transcription") { t in t.add(column: "isFavorite", .boolean).notNull().defaults(to: false) }
            try db.create(index: "transcription_favorite_createdAt", on: "transcription", columns: ["isFavorite", "createdAt"])
        }
        // Labels on transcripts and prompts aimed at labels (see `TBDMeetingClassification`).
        migrator.registerMigration("v7-meeting-classification") { db in try TBDMeetingClassification.migrate(db) }
        // Capture notice kept with a transcript (C124: "System audio is not recorded — only your microphone").
        migrator.registerMigration("v7-capture-notice") { db in
            try db.alter(table: "transcription") { t in t.add(column: "captureNotice", .text) }
        }
        return migrator
    }

    // MARK: - Notes and Ask

    /// Saves meeting notes; blank text clears them.
    public func updateUserNotes(id: String, notes: String?) throws {
        let value = notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        try writer.write { db in
            try db.execute(sql: "UPDATE transcription SET userNotes = ?, updatedAt = ? WHERE id = ?", arguments: [value, Date(), id])
        }
    }

    /// Conversations about a transcript, newest first. Empty ones are dropped.
    public func askConversations(for transcriptionId: String) throws -> [TBDAskConversation] {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM askConversation WHERE transcriptionId = ? AND messages = '[]'", arguments: [transcriptionId])
            return try TBDAskConversation.filter(Column("transcriptionId") == transcriptionId)
                .order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    public func save(_ conversation: TBDAskConversation) throws {
        var item = conversation
        item.updatedAt = Date()
        try writer.write { try item.save($0) }
    }

    public func deleteAskConversation(id: String) throws { _ = try writer.write { try TBDAskConversation.deleteOne($0, key: id) } }

    // MARK: - Retention

    /// Removes every Listening record (history, library, summaries, Transform history). Vocabulary and snippets stay.
    public func deleteAllListeningData() throws {
        try writer.write { db in
            try TBDSummary.deleteAll(db)
            try TBDTransformRun.deleteAll(db)
            try TBDAskConversation.deleteAll(db)
            try TBDTranscription.deleteAll(db)
            try TBDDictation.deleteAll(db)
        }
    }

    // MARK: - Dictations

    public func save(_ dictation: TBDDictation) throws { try writer.write { try dictation.save($0) } }

    public func dictations(limit: Int = 200, matching query: String? = nil) throws -> [TBDDictation] {
        try writer.read { db in
            if let pattern = Self.pattern(query) {
                let sql = """
                    SELECT dictation.* FROM dictation JOIN dictation_ft ON dictation_ft.rowid = dictation.rowid
                    WHERE dictation_ft MATCH ? ORDER BY dictation.createdAt DESC LIMIT ?
                    """
                return try TBDDictation.fetchAll(db, sql: sql, arguments: [pattern, limit])
            }
            return try TBDDictation.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    public func deleteDictation(id: String) throws { _ = try writer.write { try TBDDictation.deleteOne($0, key: id) } }
    public func deleteAllDictations() throws { _ = try writer.write { try TBDDictation.deleteAll($0) } }

    public struct DictationStats: Sendable, Equatable {
        public var count = 0
        public var words = 0
        public var durationMs = 0
        public var today = 0
        public init(count: Int = 0, words: Int = 0, durationMs: Int = 0, today: Int = 0) {
            self.count = count; self.words = words; self.durationMs = durationMs; self.today = today
        }
        /// Words per minute of speech, or 0.
        public var wordsPerMinute: Int { durationMs > 0 ? Int(Double(words) / (Double(durationMs) / 60_000)) : 0 }
    }

    public func dictationStats(now: Date = Date()) throws -> DictationStats {
        try writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*), COALESCE(SUM(wordCount),0), COALESCE(SUM(durationMs),0) FROM dictation")
            let startOfDay = Calendar.current.startOfDay(for: now)
            let today = try TBDDictation.filter(Column("createdAt") >= startOfDay).fetchCount(db)
            return DictationStats(count: row?[0] ?? 0, words: row?[1] ?? 0, durationMs: row?[2] ?? 0, today: today)
        }
    }

    // MARK: - Transcriptions

    /// Saves a library item. The star of a stored item changes only through `setFavorite`, so a save of an
    /// item read earlier (a transcription that finishes after the person starred it) keeps the star.
    public func save(_ transcription: TBDTranscription) throws {
        var item = transcription
        item.updatedAt = Date()
        try writer.write { db in
            if let stored = try Bool.fetchOne(db, sql: "SELECT isFavorite FROM transcription WHERE id = ?", arguments: [item.id]) {
                item.isFavorite = stored
            }
            try item.save(db)
        }
    }

    public func transcription(id: String) throws -> TBDTranscription? {
        try writer.read { db in
            if let exact = try TBDTranscription.fetchOne(db, key: id) { return exact }
            // Accept unique id prefixes (CLI convenience).
            let matches = try TBDTranscription.filter(Column("id").like("\(id.lowercased())%")).limit(2).fetchAll(db)
            return matches.count == 1 ? matches[0] : nil
        }
    }

    public func transcriptions(limit: Int = 500, kind: TBDSourceKind? = nil, matching query: String? = nil,
                               favoritesOnly: Bool = false) throws -> [TBDTranscription] {
        try writer.read { db in
            if let pattern = Self.pattern(query) {
                var sql = """
                    SELECT transcription.* FROM transcription JOIN transcription_ft ON transcription_ft.rowid = transcription.rowid
                    WHERE transcription_ft MATCH ?
                    """
                var arguments: StatementArguments = [pattern]
                if let kind { sql += " AND transcription.sourceKind = ?"; arguments += [kind.rawValue] }
                if favoritesOnly { sql += " AND transcription.isFavorite = 1" }
                sql += " ORDER BY transcription.createdAt DESC LIMIT ?"
                arguments += [limit]
                return try TBDTranscription.fetchAll(db, sql: sql, arguments: arguments)
            }
            var request = TBDTranscription.order(Column("createdAt").desc).limit(limit)
            if let kind { request = request.filter(Column("sourceKind") == kind.rawValue) }
            if favoritesOnly { request = request.filter(Column("isFavorite") == true) }
            return try request.fetchAll(db)
        }
    }

    public func deleteTranscription(id: String) throws {
        _ = try writer.write { try TBDTranscription.deleteOne($0, key: id) }
    }

    /// Items left `processing` by a crash or quit become `failed` so the user can retry them.
    public func markInterruptedTranscriptions() throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE transcription SET status = 'failed', errorMessage = 'Interrupted before it finished.' WHERE status = 'processing' AND sourceKind != 'meeting'")
        }
    }

    // MARK: - Vocabulary and snippets

    public func customWords() throws -> [TBDCustomWord] { try writer.read { try TBDCustomWord.order(Column("word")).fetchAll($0) } }
    public func save(_ word: TBDCustomWord) throws { try writer.write { try word.save($0) } }
    public func deleteCustomWord(id: String) throws { _ = try writer.write { try TBDCustomWord.deleteOne($0, key: id) } }

    public func snippets() throws -> [TBDSnippet] { try writer.read { try TBDSnippet.order(Column("trigger")).fetchAll($0) } }
    public func save(_ snippet: TBDSnippet) throws { try writer.write { try snippet.save($0) } }
    public func deleteSnippet(id: String) throws { _ = try writer.write { try TBDSnippet.deleteOne($0, key: id) } }
    public func incrementSnippetUse(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            for id in ids { try db.execute(sql: "UPDATE snippet SET useCount = useCount + 1 WHERE id = ?", arguments: [id]) }
        }
    }

    // MARK: - Summaries

    public func summaries(for transcriptionId: String) throws -> [TBDSummary] {
        try writer.read { try TBDSummary.filter(Column("transcriptionId") == transcriptionId).order(Column("createdAt")).fetchAll($0) }
    }
    public func save(_ summary: TBDSummary) throws { try writer.write { try summary.save($0) } }
    public func deleteSummary(id: String) throws { _ = try writer.write { try TBDSummary.deleteOne($0, key: id) } }

    /// Prefix-matching FTS pattern for free text, or nil for an empty query.
    static func pattern(_ query: String?) -> FTS5Pattern? {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return FTS5Pattern(matchingAllPrefixesIn: query)
    }
}
