import SQLite3
import XCTest
@testable import TBDModels

/// The one-time Tasklist import: maps open tasks and never writes to the source database.
final class TBDTasklistImportTests: TBDFlowTestCase {
    private let now = FlowT.date("2026-10-05T12:00:00Z")
    private var dbURL: URL { folder.appendingPathComponent("Tasklist/tasklist.sqlite3") }

    // MARK: A throwaway Tasklist database (the real one is never opened)

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func insert(_ db: OpaquePointer?, id: String, json: String) {
        var st: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO tasks(id, data) VALUES (?, ?)", -1, &st, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, id, -1, transient)
        sqlite3_bind_text(st, 2, json, -1, transient)
        XCTAssertEqual(sqlite3_step(st), SQLITE_DONE)
        sqlite3_finalize(st)
    }

    private func task(_ id: String, title: String = "T", status: String = "todo", day: String? = "2026-10-05", start: String? = nil, due: String? = nil,
                      notes: String = "", subtasks: String = "[]") -> String {
        func q(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(id)","title":"\(title)","notes":"\(notes)","status":"\(status)","priority":"high","subtasks":\(subtasks),
        "start_at":\(q(start)),"due_at":\(q(due)),"day":\(q(day)),"duration_minutes":25,"reminder_minutes":5,"recurrence":"daily",
        "created_at":"2026-10-01T10:00:00.123456+00:00","updated_at":"2026-10-02T11:30:00+00:00"}
        """
    }

    private func makeDB(wal: Bool = false, keepOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        if wal { exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        exec(db, "CREATE TABLE tasks(id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        insert(db, id: "a1", json: task("a1", title: "Prepare proposal", start: "2026-10-05T07:00:00+00:00", due: "2026-10-05T08:00:00+00:00",
                                        notes: "Keep scope", subtasks: #"[{"id":"s1","title":"Outline","done":true},{"id":"s2","title":"Pricing","done":false},{"title":" ","done":false}]"#))
        insert(db, id: "a2", json: task("a2", title: "Future doing", status: "doing", day: "2026-10-07"))
        insert(db, id: "a3", json: task("a3", title: "Done already", status: "done"))
        insert(db, id: "a4", json: task("a4", title: "Cancelled", status: "cancelled"))
        insert(db, id: "a5", json: task("a5", title: "Yesterday", day: "2026-10-04"))
        insert(db, id: "a6", json: task("a6", title: "No day, with start", day: nil, start: "2026-10-09T09:00:00+00:00", due: "2026-10-09T10:00:00+00:00"))
        insert(db, id: "a7", json: task("a7", title: "No day at all", day: nil))
        insert(db, id: "a8", json: "this is not json")
        insert(db, id: "a9", json: task("a9", title: "   "))
        if !keepOpen { sqlite3_close(db); return nil }
        return db
    }

    private func fingerprint(_ url: URL) throws -> (Data, Date) {
        (try Data(contentsOf: url), try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date))
    }

    // MARK: Tests

    func testDefaultPathAndAvailability() throws {
        XCTAssertTrue(TBDTasklistImport.defaultPath.path.hasSuffix("Library/Application Support/Tasklist/tasklist.sqlite3"))
        XCTAssertFalse(TBDTasklistImport.isAvailable(at: dbURL))
        XCTAssertFalse(TBDTasklistImport.isAvailable(at: folder), "a folder is not a database")
        _ = try makeDB()
        XCTAssertTrue(TBDTasklistImport.isAvailable(at: dbURL))
    }

    func testMissingFileThrowsAndTheStoreStaysEmpty() {
        let store = makeStore()
        XCTAssertThrowsError(try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)) {
            XCTAssertEqual($0 as? TBDTasklistImportError, .missing)
        }
        XCTAssertNil(store.state.tasklistImportedAt)
    }

    func testImportsOpenTasksFromTodayOnAndMapsTheFields() throws {
        _ = try makeDB()
        let store = makeStore()
        let r = try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)
        XCTAssertEqual(r, TBDTasklistImportResult(imported: 4, alreadyImported: 0, ignored: 5))
        XCTAssertEqual(store.state.tasklistImportedAt, now)
        XCTAssertEqual(store.state.tasks.map(\.id), ["tasklist-a7", "tasklist-a1", "tasklist-a2", "tasklist-a6"], "by day, then start (untimed first)")

        let a1 = try XCTUnwrap(store.task(id: "tasklist-a1"))
        XCTAssertEqual(a1.title, "Prepare proposal")
        XCTAssertEqual(a1.notes, "Keep scope")
        XCTAssertEqual(a1.status, .todo)
        XCTAssertEqual(a1.day, "2026-10-05")
        XCTAssertEqual(FlowT.iso(a1.startAt), "2026-10-05T07:00:00.000Z")
        XCTAssertEqual(FlowT.iso(a1.endAt), "2026-10-05T08:00:00.000Z")
        XCTAssertEqual(a1.durationMinutes, 60)
        XCTAssertEqual(a1.source, .local)
        XCTAssertEqual(a1.subtasks, [TBDFlowSubtask(id: "s1", title: "Outline", done: true), TBDFlowSubtask(id: "s2", title: "Pricing", done: false)])
        XCTAssertEqual(FlowT.iso(a1.createdAt), "2026-10-01T10:00:00.123Z", "microseconds are read")
        XCTAssertEqual(FlowT.iso(a1.updatedAt), "2026-10-02T11:30:00.000Z")
        XCTAssertNil(a1.completedAt)

        XCTAssertEqual(store.task(id: "tasklist-a2")?.status, .doing)
        XCTAssertEqual(store.task(id: "tasklist-a6")?.day, "2026-10-09", "no day: the day of its start")
        XCTAssertEqual(store.task(id: "tasklist-a7")?.day, "2026-10-05", "no day, no start: the day of the import")
    }

    func testTodayFollowsTheGivenCalendar() throws {
        _ = try makeDB()
        var bangkok = Calendar(identifier: .gregorian)
        bangkok.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        // 2026-10-05T20:00Z is 2026-10-06 in Bangkok: a task on 2026-10-05 is then in the past.
        let late = FlowT.date("2026-10-05T20:00:00Z")
        let r = try TBDTasklistImport.readOpenTasks(at: dbURL, now: late, calendar: bangkok)
        XCTAssertFalse(r.tasks.contains { $0.id == "tasklist-a1" })
        XCTAssertEqual(r.tasks.first { $0.id == "tasklist-a7" }?.day, "2026-10-06")
    }

    func testRunningTwiceSkipsWhatIsAlreadyIn() throws {
        _ = try makeDB()
        let store = makeStore()
        try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)
        // The person finished one in Flow and edited another: neither comes back changed.
        try store.setStatus(id: "tasklist-a1", .done)
        try store.updateTask(id: "tasklist-a2") { $0.title = "Renamed" }
        let again = try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now.addingTimeInterval(60), calendar: FlowT.utc)
        XCTAssertEqual(again, TBDTasklistImportResult(imported: 0, alreadyImported: 4, ignored: 5))
        XCTAssertEqual(store.state.tasks.count, 4)
        XCTAssertEqual(store.task(id: "tasklist-a2")?.title, "Renamed")
        XCTAssertEqual(store.state.tasklistImportedAt, now.addingTimeInterval(60))
        // And it is saved.
        XCTAssertEqual(makeStore().state.tasks.count, 4)
    }

    func testImportNeverChangesTheSourceFileOrAddsFilesNextToIt() throws {
        _ = try makeDB()
        let before = try fingerprint(dbURL)
        let listing = try FileManager.default.contentsOfDirectory(atPath: dbURL.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(listing, ["tasklist.sqlite3"])
        // Let the clock move so a write would show in the modification time.
        Thread.sleep(forTimeInterval: 1.1)
        let store = makeStore()
        try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)
        try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)
        let after = try fingerprint(dbURL)
        XCTAssertEqual(after.0, before.0, "same bytes")
        XCTAssertEqual(after.1, before.1, "same modification time")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dbURL.deletingLastPathComponent().path).sorted(), listing,
                       "no -wal, -shm or -journal file was made")
        XCTAssertEqual(store.state.tasks.count, 4)
    }

    func testAReadOnlyDatabaseFileStillImports() throws {
        _ = try makeDB()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dbURL.path)
        let store = makeStore()
        XCTAssertNoThrow(try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc))
        XCTAssertEqual(store.state.tasks.count, 4)
    }

    func testALiveWriteAheadLogIsReadInPlaceWithoutTouchingTheMainFile() throws {
        // The Tasklist service runs in WAL mode; a task it just wrote is only in the -wal file.
        let writer = try makeDB(wal: true, keepOpen: true)
        defer { sqlite3_close(writer) }
        insert(writer, id: "w1", json: task("w1", title: "Only in the log", day: "2026-10-06"))
        let wal = dbURL.path + "-wal"
        XCTAssertGreaterThan(((try FileManager.default.attributesOfItem(atPath: wal)[.size]) as? NSNumber)?.intValue ?? 0, 0, "the test needs a live log")
        let before = try fingerprint(dbURL)
        Thread.sleep(forTimeInterval: 1.1)

        let store = makeStore()
        try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)
        XCTAssertNotNil(store.task(id: "tasklist-w1"), "the log content was read")
        XCTAssertEqual(store.state.tasks.count, 5)
        let after = try fingerprint(dbURL)
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        // The service can still write after the import (we held no lock).
        insert(writer, id: "w2", json: task("w2", title: "Later"))
    }

    func testAFileThatIsNotADatabaseIsAnError() throws {
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database at all, just text".utf8).write(to: dbURL)
        let store = makeStore()
        XCTAssertThrowsError(try TBDTasklistImport.importOpenTasks(into: store, from: dbURL, now: now, calendar: FlowT.utc)) {
            guard case .unreadable? = $0 as? TBDTasklistImportError else { return XCTFail("expected unreadable, got \($0)") }
        }
        XCTAssertNil(store.state.tasklistImportedAt)
        XCTAssertEqual(try String(contentsOf: dbURL, encoding: .utf8), "not a database at all, just text")
    }
}
