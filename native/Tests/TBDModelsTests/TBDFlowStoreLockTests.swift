import Darwin
import XCTest
@testable import TBDModels

/// dev.17 U3: the app and the companion CLI both write `flow.json`. Two stores on one file stand for the two processes:
/// every change runs under `flock` on `flow.json.lock` and starts from what is on disk, so no update is lost.
final class TBDFlowStoreLockTests: TBDFlowTestCase {
    private let day = "2026-10-05"

    func testTwoStoresInterleavedChangesLoseNothing() throws {
        let app = makeStore()
        let cli = makeStore()
        try app.addTask(title: "app 1", day: day)
        try cli.addTask(title: "cli 1", day: day)      // cli never saw "app 1" in memory
        try app.addTask(title: "app 2", day: day)      // app never saw "cli 1" in memory
        try cli.addTask(title: "cli 2", day: day)
        let titles = makeStore().state.tasks.map(\.title)
        XCTAssertEqual(titles, ["app 1", "cli 1", "app 2", "cli 2"])
        XCTAssertEqual(cli.state.tasks.count, 4, "a writer ends with what it saved on top of the disk")
        XCTAssertEqual(app.state.tasks.count, 3, "a reader keeps its copy until it asks")
        XCTAssertTrue(app.reloadIfChanged())
        XCTAssertEqual(app.state.tasks.count, 4)
    }

    func testTheClockTickOfAStaleStoreKeepsTheOtherWritersTasks() throws {
        let app = makeStore()
        try app.addTask(title: "start", day: day, startAt: FlowT.date("2026-10-05T08:00:00Z"))
        let cli = makeStore()
        try cli.commit(drafts: [TBDFlowTaskDraft(title: "from the agent", day: day)], idempotencyKey: "k", payloadHash: "h")
        clock.set("2026-10-05T08:00:30Z")
        let result = try app.tick()          // a change (a reminder), made by a store that did not know the agent's line
        XCTAssertEqual(result.newReminders.count, 1)
        let onDisk = makeStore().state
        XCTAssertEqual(onDisk.tasks.map(\.title), ["start", "from the agent"])
        XCTAssertEqual(onDisk.reminders.count, 1)
        XCTAssertEqual(onDisk.imports["k"]?.taskIDs.count, 1)
    }

    func testConcurrentWritersLoseNoUpdate() throws {
        let a = makeStore()
        let b = makeStore()
        let perWriter = 25
        let failures = FlowCounter()
        DispatchQueue.concurrentPerform(iterations: 2 * perWriter) { i in
            let store = i % 2 == 0 ? a : b
            do { try store.addTask(title: "t\(i)", day: day) } catch { _ = failures.next() }
        }
        XCTAssertEqual(failures.next(), "id-1", "no change failed")
        let titles = Set(makeStore().state.tasks.map(\.title))
        XCTAssertEqual(titles.count, 2 * perWriter)
        XCTAssertEqual(titles, Set((0..<(2 * perWriter)).map { "t\($0)" }))
    }

    func testIdempotencyHoldsAcrossStores() throws {
        let app = makeStore()
        let cli = makeStore()
        let text = "09:00-10:00 Plan\nTODO Call"
        let drafts = try TBDFlowPlanParser.parseSchedule(text: text, day: day, timeZone: FlowT.zone("UTC"))
        let hash = TBDFlowPlanParser.payloadHash(format: TBDFlowPlanParser.format, text: text, day: day, timeZone: FlowT.zone("UTC"))
        _ = app.state   // both stores are opened before anything is saved

        let first = try cli.commit(drafts: drafts, idempotencyKey: "agent-1", payloadHash: hash)
        XCTAssertFalse(first.replayed)
        let again = try app.commit(drafts: drafts, idempotencyKey: "agent-1", payloadHash: hash)
        XCTAssertTrue(again.replayed, "the stale store sees the key the other store saved")
        XCTAssertEqual(again.taskIDs, first.taskIDs)
        XCTAssertThrowsError(try app.commit(drafts: drafts, idempotencyKey: "agent-1", payloadHash: "other")) {
            XCTAssertEqual($0 as? TBDFlowError, .idempotencyConflict)
        }
        XCTAssertEqual(makeStore().state.tasks.count, 2, "saved once")
    }

    func testReloadIfChangedSeesTheOtherWriterAndNotItsOwn() throws {
        let app = makeStore()
        let cli = makeStore()
        XCTAssertFalse(app.reloadIfChanged(), "no file yet")
        try app.addTask(title: "mine", day: day)
        XCTAssertFalse(app.reloadIfChanged(), "its own save is not a change")
        XCTAssertTrue(cli.reloadIfChanged(), "the other store sees the file")
        XCTAssertEqual(cli.state.tasks.map(\.title), ["mine"])
        XCTAssertFalse(cli.reloadIfChanged())

        try cli.addTask(title: "theirs", day: day)
        XCTAssertEqual(app.state.tasks.map(\.title), ["mine"], "a reader keeps its copy until it asks")
        XCTAssertTrue(app.reloadIfChanged())
        XCTAssertEqual(app.state.tasks.map(\.title), ["mine", "theirs"])
        XCTAssertFalse(app.reloadIfChanged())
    }

    func testReloadSeesAFileThatWasRemoved() throws {
        let app = makeStore()
        try app.addTask(title: "x", day: day)
        try FileManager.default.removeItem(at: flowURL)     // the test's own file
        XCTAssertTrue(app.reloadIfChanged())
        XCTAssertTrue(app.state.tasks.isEmpty)
    }

    func testAChangeWaitsForAnotherProcessHoldingTheLock() throws {
        let store = makeStore()
        try store.addTask(title: "first", day: day)
        let outsider = open(flowURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(outsider, 0)
        XCTAssertEqual(flock(outsider, LOCK_EX), 0)
        let released = expectation(description: "lock released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            flock(outsider, LOCK_UN)
            released.fulfill()
        }
        let started = Date()
        try store.addTask(title: "second", day: day)       // blocks until the outsider lets go
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        wait(for: [released], timeout: 5)
        close(outsider)
        XCTAssertEqual(makeStore().state.tasks.map(\.title), ["first", "second"])
    }

    func testAChangeGivesUpWhenTheLockStaysTaken() throws {
        let store = makeStore()
        try store.addTask(title: "first", day: day)
        let outsider = open(flowURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(outsider, LOCK_EX), 0)
        defer { flock(outsider, LOCK_UN); close(outsider) }
        let saved = TBDFlowStore.lockTimeout
        TBDFlowStore.lockTimeout = 0.2
        defer { TBDFlowStore.lockTimeout = saved }
        XCTAssertThrowsError(try store.addTask(title: "second", day: day)) {
            guard case .storage = $0 as? TBDFlowError else { return XCTFail("expected a storage error, got \($0)") }
        }
        XCTAssertEqual(store.state.tasks.map(\.title), ["first"], "a refused change changes nothing")
    }

    func testTheLockFileIsPrivateAndTheListFileIsStillTheOnlyData() throws {
        let store = makeStore()
        try store.addTask(title: "a", day: day)
        let lockPath = flowURL.path + ".lock"
        let mode = ((try? FileManager.default.attributesOfItem(atPath: lockPath)[.posixPermissions]) as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: flowURL.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(names, ["flow.json", "flow.json.lock"], "no temp file is left")
    }

    func testAnUnreadableFileIsMovedAsideOnceEvenWhenTwoStoresOpenIt() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: flowURL)
        let a = makeStore()
        let b = makeStore()
        XCTAssertNotNil(a.corruptBackupURL)
        XCTAssertNil(b.corruptBackupURL, "the second store found no file left")
        XCTAssertFalse(b.isLockedByUnreadableFile)
        try b.addTask(title: "fresh", day: day)
        XCTAssertEqual(a.reloadIfChanged() ? a.state.tasks.map(\.title) : [], ["fresh"])
    }
}
