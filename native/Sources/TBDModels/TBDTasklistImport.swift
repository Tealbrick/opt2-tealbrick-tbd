import Foundation
import SQLite3

public enum TBDTasklistImportError: Error, Equatable, LocalizedError, Sendable {
    case missing
    case unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .missing: return "Tasklist data was not found on this Mac."
        case .unreadable(let why): return "Tasklist data could not be read: \(why)"
        }
    }
}

public struct TBDTasklistImportResult: Equatable, Sendable {
    /// New tasks added to the Flow list.
    public var imported: Int
    /// Open tasks whose `tasklist-<id>` was already in the list.
    public var alreadyImported: Int
    /// Rows left out: done or cancelled, a past day, no usable title or unreadable JSON.
    public var ignored: Int
}

/// One-time, READ-ONLY import of open tasks from the v1 Tasklist database (DESIGN-FLOW.md 2.2).
///
/// The Tasklist files are never opened by us, written, moved or deleted. The import copies `tasklist.sqlite3` and, when
/// there is one, its `-wal` (never the `-shm`) into a fresh folder in the temporary directory, opens the COPY so SQLite
/// replays the copied log, reads, closes, and then removes only the files it made there, one by one by exact name. A copy
/// taken while the service writes is checked: if the source files changed during the copy, it is taken again. Tasks are
/// JSON blobs in `tasks(id TEXT PRIMARY KEY, data TEXT NOT NULL)`.
///
/// What comes in: status `todo` or `doing`, and a `day` that is today or later, or no `day`. Each task keeps its id with
/// the prefix `tasklist-`; a task already in the list is skipped. Fields without a Flow home (priority, reminder minutes,
/// recurrence) are left behind.
public enum TBDTasklistImport {
    public static let idPrefix = "tasklist-"

    /// `~/Library/Application Support/Tasklist/tasklist.sqlite3`.
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tasklist/tasklist.sqlite3")
    }

    /// The Tasklist database exists at the default path (Flow shows "Import from Tasklist" only then).
    public static var isAvailable: Bool { isAvailable(at: defaultPath) }

    public static func isAvailable(at path: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Reads the database and adds its open tasks to `store`. Sets `tasklistImportedAt`.
    @discardableResult
    public static func importOpenTasks(into store: TBDFlowStore, from path: URL = defaultPath, now: Date = Date(),
                                       calendar: Calendar = .current) throws -> TBDTasklistImportResult {
        let read = try readOpenTasks(at: path, now: now, calendar: calendar)
        let (added, skipped) = try store.addImported(read.tasks, importedAt: now)
        return TBDTasklistImportResult(imported: added, alreadyImported: skipped, ignored: read.ignored)
    }

    /// The open tasks of the database as Flow tasks, without touching a store.
    public static func readOpenTasks(at path: URL, now: Date, calendar: Calendar) throws -> (tasks: [TBDFlowTask], ignored: Int) {
        guard isAvailable(at: path) else { throw TBDTasklistImportError.missing }
        let rows = try readRows(path)
        let today = TBDFlowDay.string(from: now, calendar: calendar)
        var tasks: [TBDFlowTask] = []
        var ignored = 0
        for (id, json) in rows {
            if let t = map(id: id, json: json, now: now, today: today, calendar: calendar) { tasks.append(t) } else { ignored += 1 }
        }
        tasks.sort { ($0.day, $0.startAt ?? .distantPast, $0.id) < ($1.day, $1.startAt ?? .distantPast, $1.id) }
        return (tasks, ignored)
    }

    // MARK: Mapping

    static func map(id rowID: String, json: String, now: Date, today: String, calendar: Calendar) -> TBDFlowTask? {
        guard let data = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let status = (o["status"] as? String).flatMap(TBDFlowTaskStatus.init(rawValue:))
        guard status == .todo || status == .doing else { return nil }
        let title = (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        func date(_ key: String) -> Date? { (o[key] as? String).flatMap(TBDFlowISO.date) }
        let start = date("start_at")
        var end = date("due_at")
        if let s = start, let e = end, e < s { end = nil }
        var day: String?
        if let d = o["day"] as? String, TBDFlowDay.isValid(d) { day = d }
        if let day, day < today { return nil }
        let resolvedDay = day ?? start.map { TBDFlowDay.string(from: $0, calendar: calendar) } ?? today
        let sourceID = (o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rowID
        let subtasks: [TBDFlowSubtask] = ((o["subtasks"] as? [[String: Any]]) ?? []).prefix(TBDFlowTask.maxSubtasks).enumerated().compactMap { i, s in
            let t = (s["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let sid = (s["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(idPrefix)\(sourceID)-sub-\(i + 1)"
            return TBDFlowSubtask(id: sid, title: String(t.prefix(TBDFlowTask.maxTitle)), done: s["done"] as? Bool ?? false)
        }
        let created = date("created_at") ?? now
        return TBDFlowTask(
            id: idPrefix + sourceID, title: String(title.prefix(TBDFlowTask.maxTitle)),
            notes: String((o["notes"] as? String ?? "").prefix(TBDFlowTask.maxNotes)), subtasks: subtasks, status: status ?? .todo,
            day: resolvedDay, startAt: start, endAt: end, createdAt: created, updatedAt: date("updated_at") ?? created)
    }

    // MARK: SQLite (on a copy)

    private struct FileSignature: Equatable {
        var size: Int
        var modified: Date?
    }

    private static func signature(_ url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileSignature(size: (attrs[.size] as? NSNumber)?.intValue ?? 0, modified: attrs[.modificationDate] as? Date)
    }

    private static func readRows(_ path: URL) throws -> [(String, String)] {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("tbd-tasklist-import-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw TBDTasklistImportError.unreadable("no temporary folder: \(error.localizedDescription)")
        }
        let name = path.lastPathComponent
        let copy = scratch.appendingPathComponent(name)
        // Only files this function creates are ever removed, by exact name. SQLite adds the log, shared-memory and
        // journal files of the copy; it removes them itself on a clean close and the loop below catches the rest.
        let ours = [name, name + "-wal", name + "-shm", name + "-journal"].map { scratch.appendingPathComponent($0) }
        defer {
            for file in ours where fm.fileExists(atPath: file.path) { try? fm.removeItem(at: file) }
            try? fm.removeItem(at: scratch) // empty by now: this removes only the folder we made
        }
        let sourceWAL = URL(fileURLWithPath: path.path + "-wal")
        let copyWAL = URL(fileURLWithPath: copy.path + "-wal")
        var copied = false
        for _ in 0..<3 {
            let before = (signature(path), signature(sourceWAL))
            for file in [copy, copyWAL] where fm.fileExists(atPath: file.path) { try? fm.removeItem(at: file) }
            do {
                if before.1 != nil { try fm.copyItem(at: sourceWAL, to: copyWAL) }
                try fm.copyItem(at: path, to: copy)
            } catch {
                throw TBDTasklistImportError.unreadable("copy failed: \(error.localizedDescription)")
            }
            if (signature(path), signature(sourceWAL)) == before { copied = true; break }
        }
        if !copied { throw TBDTasklistImportError.unreadable("the database kept changing while it was copied; try again") }
        for file in [copy, copyWAL] where fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) // the source may be read-only
        }
        return try query(copy: copy)
    }

    private static func query(copy: URL) throws -> [(String, String)] {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else { throw TBDTasklistImportError.unreadable(db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed") }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, data FROM tasks", -1, &statement, nil) == SQLITE_OK else {
            throw TBDTasklistImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw TBDTasklistImportError.unreadable(String(cString: sqlite3_errmsg(db))) }
            guard let id = sqlite3_column_text(statement, 0), let data = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: id), String(cString: data)))
        }
        return rows
    }
}
