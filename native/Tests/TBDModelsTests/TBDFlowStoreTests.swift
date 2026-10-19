import XCTest
@testable import TBDModels

/// The Flow store: persistence, task rules, reminders, focus timer and card labels (ported from Tasklist `tests/test_api.py`).
final class TBDFlowStoreTests: TBDFlowTestCase {
    private let day = "2026-10-05"
    private func at(_ time: String) -> Date { FlowT.date("2026-10-05T\(time)Z") }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    // MARK: Persistence

    func testRoundTripThroughTheFileKeepsEverything() throws {
        let store = makeStore()
        let task = try store.addTask(title: "Write", notes: "n", subtasks: ["a", "b"], day: day, startAt: at("08:00:00"), endAt: at("09:00:00"))
        try store.setCardLabel(cardID: "card-1", label: .onPlan, taskID: task.id, by: .person)
        try store.updateSettings { $0.focusMinutes = 30 }
        clock.set("2026-10-05T08:00:00Z")
        try store.tick()
        try store.startFocus(taskID: task.id)
        let before = store.state

        let reopened = makeStore()
        XCTAssertEqual(reopened.state, before)
        XCTAssertEqual(reopened.state.tasks.count, 1)
        XCTAssertEqual(reopened.state.reminders.count, 1)
        XCTAssertEqual(reopened.state.settings.focusMinutes, 30)
        XCTAssertEqual(reopened.state.focus?.status, .running)
        XCTAssertNil(reopened.corruptBackupURL)
    }

    func testFileIs0600FolderIs0700AndNoTempFileIsLeft() throws {
        let store = makeStore()
        try store.addTask(title: "A", day: day)
        try store.addTask(title: "B", day: day)
        XCTAssertEqual(mode(flowURL), 0o600)
        XCTAssertEqual(mode(flowURL.deletingLastPathComponent()), 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: flowURL.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["flow.json"])
    }

    func testFileIsReadableJSONWithISODates() throws {
        let store = makeStore()
        try store.addTask(title: "A", day: day, startAt: at("08:00:00"))
        let text = try String(contentsOf: flowURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertTrue(text.contains("2026-10-05T08:00:00.000Z"))
    }

    func testNothingIsWrittenForAFailedOrEmptyChange() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.addTask(title: "", day: day))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flowURL.path), "a refused change writes nothing")
        try store.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: flowURL.path), "a tick that changes nothing writes nothing")
    }

    func testCorruptFileIsMovedAsideNeverDeleted() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("{ this is not json".utf8)
        try junk.write(to: flowURL)
        let store = makeStore()
        XCTAssertTrue(store.state.tasks.isEmpty)
        let backup = try XCTUnwrap(store.corruptBackupURL)
        XCTAssertEqual(backup.lastPathComponent, "flow.json.corrupt-20261005T070000Z")
        XCTAssertEqual(try Data(contentsOf: backup), junk, "the bytes are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: flowURL.path))
        // Flow goes on with an empty list and writes a fresh file.
        try store.addTask(title: "Fresh", day: day)
        XCTAssertEqual(makeStore().state.tasks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testWhenTheCorruptFileCannotBeMovedAsideTheStoreRefusesToWrite() throws {
        let dir = flowURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = Data("{ this is not json".utf8)
        try junk.write(to: flowURL)
        // A folder nobody can add files to: the rename fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let store = makeStore()
        XCTAssertNil(store.corruptBackupURL)
        XCTAssertTrue(store.isLockedByUnreadableFile)
        XCTAssertTrue(store.state.tasks.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try store.addTask(title: "Fresh", day: day))
        XCTAssertEqual(try Data(contentsOf: flowURL), junk, "the unreadable file is never overwritten")
        XCTAssertTrue(store.state.tasks.isEmpty)
    }

    func testAMovedAsideFileLeavesTheStoreWritable() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: flowURL)
        let store = makeStore()
        XCTAssertFalse(store.isLockedByUnreadableFile)
        XCTAssertNoThrow(try store.addTask(title: "Fresh", day: day))
    }

    func testSecondCorruptFileOfTheSameSecondGetsAnotherName() throws {
        let dir = flowURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("bad1".utf8).write(to: flowURL)
        let first = try XCTUnwrap(makeStore().corruptBackupURL)
        try Data("bad2".utf8).write(to: flowURL)
        let second = try XCTUnwrap(makeStore().corruptBackupURL)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "bad1")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "bad2")
    }

    func testFileFromANewerVersionIsMovedAsideToo() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "tasks": []}"#.utf8).write(to: flowURL)
        let store = makeStore()
        XCTAssertNotNil(store.corruptBackupURL)
        XCTAssertEqual(store.state.version, 1)
    }

    func testMissingSectionsInTheFileTakeDefaults() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1}"#.utf8).write(to: flowURL)
        let store = makeStore()
        XCTAssertNil(store.corruptBackupURL)
        XCTAssertEqual(store.state.settings, TBDFlowSettings())
        XCTAssertEqual(store.state.settings.repeatSeconds, 60)
        XCTAssertEqual(store.state.settings.focusMinutes, 25)
        XCTAssertEqual(store.state.settings.breakMinutes, 5)
        XCTAssertTrue(store.state.settings.sound)
        XCTAssertTrue(store.state.settings.overlay)
    }

    func testDefaultLocationIsInsideTheTBDDataFolderNotTheArchivedV1Folder() {
        let path = TBDFlowStore.defaultURL.path
        XCTAssertTrue(path.hasSuffix("/Companion/flow.json"))
        XCTAssertTrue(path.contains("/Application Support/" + TBDIdentity.dataFolder + "/"))
        XCTAssertFalse(path.contains("/Application Support/TBD/"))
    }

    func testStoreIsSafeToUseFromSeveralThreads() throws {
        let store = makeStore()
        let group = DispatchGroup()
        for i in 0..<20 {
            DispatchQueue.global().async(group: group) { _ = try? store.addTask(title: "T\(i)", day: "2026-10-05") }
        }
        group.wait()
        XCTAssertEqual(store.state.tasks.count, 20)
        XCTAssertEqual(makeStore().state.tasks.count, 20)
    }

    // MARK: Tasks

    func testTaskLimits() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.addTask(title: "   ", day: day)) { XCTAssertEqual($0 as? TBDFlowError, .invalid("Title required (max 500 characters)")) }
        XCTAssertThrowsError(try store.addTask(title: String(repeating: "x", count: 501), day: day))
        XCTAssertNoThrow(try store.addTask(title: String(repeating: "x", count: 500), day: day))
        XCTAssertThrowsError(try store.addTask(title: "n", notes: String(repeating: "x", count: 100_001), day: day)) { XCTAssertEqual($0 as? TBDFlowError, .invalid("Notes too long")) }
        XCTAssertThrowsError(try store.addTask(title: "s", subtasks: Array(repeating: "x", count: 201), day: day)) { XCTAssertEqual($0 as? TBDFlowError, .invalid("Invalid subtasks")) }
        XCTAssertNoThrow(try store.addTask(title: "s", subtasks: Array(repeating: "x", count: 200), day: day))
        XCTAssertThrowsError(try store.addTask(title: "e", day: day, startAt: at("09:00:00"), endAt: at("08:00:00"))) { XCTAssertEqual($0 as? TBDFlowError, .invalid("End must follow start")) }
        XCTAssertThrowsError(try store.addTask(title: "d", day: "2026-10-5"))
        XCTAssertThrowsError(try store.addTask(title: "d", day: "2026-02-30"))
    }

    func testDurationMinutes() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day, startAt: at("08:00:00"), endAt: at("09:30:00"))
        XCTAssertEqual(t.durationMinutes, 90)
        XCTAssertEqual(try store.addTask(title: "B", day: day, startAt: at("08:00:00")).durationMinutes, 0)
    }

    func testDoneSetsCompletedAtAndTodoClearsIt() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day)
        XCTAssertNil(t.completedAt)
        clock.set("2026-10-05T10:00:00Z")
        let done = try store.setStatus(id: t.id, .done)
        XCTAssertEqual(done.completedAt, clock.now)
        XCTAssertEqual(done.updatedAt, clock.now)
        clock.set("2026-10-05T11:00:00Z")
        XCTAssertEqual(try store.setStatus(id: t.id, .done).completedAt, at("10:00:00"), "done again keeps the first time")
        XCTAssertNil(try store.setStatus(id: t.id, .todo).completedAt)
        XCTAssertEqual(try store.setStatus(id: t.id, .cancelled).status, .cancelled)
    }

    func testUpdateCannotChangeIdOrCreatedAtAndMissingTaskIsAnError() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day)
        clock.advance(60)
        let u = try store.updateTask(id: t.id) { $0.id = "other"; $0.createdAt = .distantPast; $0.title = "B" }
        XCTAssertEqual(u.id, t.id)
        XCTAssertEqual(u.createdAt, t.createdAt)
        XCTAssertEqual(u.title, "B")
        XCTAssertThrowsError(try store.updateTask(id: "nope") { _ in }) { XCTAssertEqual($0 as? TBDFlowError, .notFound("Task")) }
        XCTAssertThrowsError(try store.updateTask(id: t.id) { $0.title = "" })
        XCTAssertEqual(store.task(id: t.id)?.title, "B", "a refused change leaves the task as it was")
    }

    func testToggleSubtaskAndDelete() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", subtasks: ["a", "b"], day: day)
        let sub = t.subtasks[1].id
        XCTAssertEqual(try store.toggleSubtask(taskID: t.id, subtaskID: sub).subtasks.map(\.done), [false, true])
        XCTAssertEqual(try store.toggleSubtask(taskID: t.id, subtaskID: sub).subtasks.map(\.done), [false, false])
        XCTAssertThrowsError(try store.toggleSubtask(taskID: t.id, subtaskID: "nope")) { XCTAssertEqual($0 as? TBDFlowError, .notFound("Subtask")) }
        try store.deleteTask(id: t.id)
        XCTAssertNil(store.task(id: t.id))
        XCTAssertThrowsError(try store.deleteTask(id: t.id))
    }

    func testTasksOfADayAreOrderedByStart() throws {
        let store = makeStore()
        try store.addTask(title: "late", day: day, startAt: at("10:00:00"))
        try store.addTask(title: "none", day: day)
        try store.addTask(title: "early", day: day, startAt: at("08:00:00"))
        try store.addTask(title: "other day", day: "2026-10-06")
        XCTAssertEqual(store.tasks(onDay: day).map(\.title), ["none", "early", "late"])
    }

    func testSettingsLimits() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.updateSettings { $0.focusMinutes = 0 }) { XCTAssertEqual($0 as? TBDFlowError, .invalid("Duration must be 1–240 minutes")) }
        XCTAssertThrowsError(try store.updateSettings { $0.breakMinutes = 241 })
        XCTAssertThrowsError(try store.updateSettings { $0.repeatSeconds = 14 }) { XCTAssertEqual($0 as? TBDFlowError, .invalid("Repeat interval must be 15–3600 seconds")) }
        XCTAssertThrowsError(try store.updateSettings { $0.repeatSeconds = 3601 })
        XCTAssertEqual(store.state.settings, TBDFlowSettings())
        XCTAssertEqual(try store.updateSettings { $0.sound = false; $0.repeatSeconds = 15 }.repeatSeconds, 15)
    }

    // MARK: Reminders

    func testStartReminderIsCreatedOnceAtTheStartTime() throws {
        let store = makeStore()
        let t = try store.addTask(title: "Due task", day: day, startAt: at("08:00:00"))
        clock.set("2026-10-05T07:59:59Z")
        XCTAssertEqual(try store.tick(), TBDFlowTickResult(newReminders: [], finishedFocus: nil))
        clock.set("2026-10-05T08:00:00Z")
        let r = try store.tick()
        XCTAssertEqual(r.newReminders.count, 1)
        let reminder = try XCTUnwrap(r.newReminders.first)
        XCTAssertEqual(reminder.kind, .start)
        XCTAssertEqual(reminder.taskID, t.id)
        XCTAssertEqual(reminder.title, "Start: Due task")
        XCTAssertEqual(reminder.dedupKey, "start:\(t.id):2026-10-05T08:00:00.000Z")
        // Three more ticks add nothing (Tasklist test_reminder_deduplication_and_ack).
        for _ in 0..<3 { clock.advance(1); XCTAssertFalse(try store.tick().changed) }
        XCTAssertEqual(store.state.reminders.count, 1)
    }

    func testPastingAMorningPlanAt1400MakesNoToast() throws {
        let store = makeStore()
        try store.addTask(title: "Morning A", day: day, startAt: at("08:00:00"), endAt: at("09:00:00"))
        try store.addTask(title: "Morning B", day: day, startAt: at("09:00:00"))
        try store.addTask(title: "Running", day: day, startAt: at("13:50:00"))
        clock.set("2026-10-05T14:00:00Z")
        let r = try store.tick()
        XCTAssertEqual(r.newReminders.map(\.title), ["Start: Running"], "only the one that is 10 minutes old is shown")
        XCTAssertEqual(store.state.reminders.count, 3)
        let stale = store.state.reminders.filter { $0.title != "Start: Running" }
        XCTAssertTrue(stale.allSatisfy { $0.acknowledgedAt == clock.now }, "stored acknowledged")
        XCTAssertEqual(store.pendingReminders(now: clock.now).map(\.title), ["Start: Running"])
        clock.advance(60)
        XCTAssertFalse(try store.tick().changed, "no catch-up on the next tick either")
    }

    func testAReminderExactlyAtTheEdgeOfTheWindowStillShows() throws {
        let store = makeStore()
        try store.addTask(title: "Edge", day: day, startAt: at("13:45:00"))
        clock.set("2026-10-05T14:00:00Z")
        XCTAssertEqual(try store.tick().newReminders.count, 1, "exactly 15 minutes is not more than 15 minutes")
    }

    func testSnoozeHidesTheReminderUntilItsTimeAndDoneAcknowledgesIt() throws {
        let store = makeStore()
        let t = try store.addTask(title: "Due", day: day, startAt: at("08:00:00"))
        clock.set("2026-10-05T08:00:10Z")
        try store.tick()
        let id = try XCTUnwrap(store.state.reminders.first?.id)
        XCTAssertEqual(store.reminderToShow(now: clock.now)?.id, id)
        try store.snoozeReminder(id: id, minutes: 5)
        XCTAssertEqual(store.state.reminders[0].snoozedUntil, at("08:05:10"))
        try store.tick()
        XCTAssertNil(store.reminderToShow(now: at("08:05:09")))
        XCTAssertEqual(store.reminderToShow(now: at("08:05:10"))?.id, id, "it comes back after the snooze")
        clock.set("2026-10-05T08:06:00Z")
        try store.setStatus(id: t.id, .done)
        XCTAssertEqual(store.state.reminders[0].acknowledgedAt, at("08:06:00"))
        XCTAssertNil(store.reminderToShow(now: at("09:00:00")))
        try store.tick()
        XCTAssertEqual(store.state.reminders.count, 1, "a done task makes no new reminder")
    }

    func testSnoozeRange() throws {
        let store = makeStore()
        try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        try store.tick()
        let id = store.state.reminders[0].id
        XCTAssertThrowsError(try store.snoozeReminder(id: id, minutes: 0)) { XCTAssertEqual($0 as? TBDFlowError, .invalidSnooze) }
        XCTAssertThrowsError(try store.snoozeReminder(id: id, minutes: 1441))
        XCTAssertNoThrow(try store.snoozeReminder(id: id, minutes: 1))
        XCTAssertNoThrow(try store.snoozeReminder(id: id, minutes: 1440))
        XCTAssertEqual(store.state.reminders[0].snoozedUntil, at("07:00:00").addingTimeInterval(1440 * 60))
        XCTAssertThrowsError(try store.snoozeReminder(id: "nope")) { XCTAssertEqual($0 as? TBDFlowError, .notFound("Reminder")) }
        XCTAssertThrowsError(try store.acknowledgeReminder(id: "nope"))
    }

    func testTimeboxEndSupersedesTheStartReminderWithoutCompletingTheTask() throws {
        let store = makeStore()
        let t = try store.addTask(title: "Budgeted work", day: day, startAt: at("07:00:00"), endAt: at("08:00:00"))
        clock.set("2026-10-05T07:10:00Z")
        try store.tick()
        XCTAssertEqual(store.state.reminders.map(\.kind), [.start])
        clock.set("2026-10-05T08:00:00Z")
        let r = try store.tick()
        XCTAssertEqual(r.newReminders.map(\.kind), [.timeboxEnded])
        XCTAssertEqual(r.newReminders[0].title, "Timebox ended: Budgeted work — finish or replan")
        XCTAssertEqual(r.newReminders[0].dedupKey, "timeboxEnded:\(t.id):2026-10-05T08:00:00.000Z")
        let pending = store.state.reminders.filter { $0.acknowledgedAt == nil }
        XCTAssertEqual(pending.map(\.kind), [.timeboxEnded], "the start reminder was acknowledged")
        XCTAssertEqual(store.task(id: t.id)?.status, .todo, "the end of the budget is not completion")
        try store.tick(); try store.tick()
        XCTAssertEqual(store.state.reminders.count, 2)
    }

    func testTaskWhoseTimeboxAlreadyEndedGetsOnlyTheEndReminder() throws {
        let store = makeStore()
        try store.addTask(title: "Old", day: day, startAt: at("05:00:00"), endAt: at("06:00:00"))
        try store.tick()
        XCTAssertEqual(store.state.reminders.map(\.kind), [.timeboxEnded])
    }

    func testTaskWithOnlyAnEndRemindsAtTheEndAsStart() throws {
        let store = makeStore()
        try store.addTask(title: "Due", day: day, endAt: at("09:00:00"))
        clock.set("2026-10-05T08:59:00Z")
        try store.tick()
        XCTAssertTrue(store.state.reminders.isEmpty)
        clock.set("2026-10-05T09:00:00Z")
        try store.tick()
        XCTAssertEqual(store.state.reminders.map(\.dedupKey).first?.hasPrefix("start:"), true)
        XCTAssertTrue(store.state.reminders[0].dedupKey.hasSuffix(":2026-10-05T09:00:00.000Z"))
    }

    func testDoneCancelledAndUntimedTasksMakeNoReminder() throws {
        let store = makeStore()
        let a = try store.addTask(title: "done", day: day, startAt: at("05:00:00"), endAt: at("06:00:00"))
        let b = try store.addTask(title: "cancelled", day: day, startAt: at("05:00:00"))
        try store.addTask(title: "untimed", day: day)
        try store.setStatus(id: a.id, .done)
        try store.setStatus(id: b.id, .cancelled)
        try store.tick()
        XCTAssertTrue(store.state.reminders.isEmpty)
    }

    func testChangingTheTimeAcknowledgesTheOldReminderAndMakesANewOne() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        try store.tick()
        XCTAssertEqual(store.state.reminders.count, 1)
        clock.set("2026-10-05T07:30:00Z")
        try store.updateTask(id: t.id) { $0.startAt = at("07:20:00") }
        XCTAssertEqual(store.state.reminders[0].acknowledgedAt, clock.now, "server.py l.293-295")
        try store.tick()
        XCTAssertEqual(store.state.reminders.count, 2, "the new time has its own dedup key")
        XCTAssertNil(store.state.reminders[1].acknowledgedAt)
        // A change that is not a time change does not acknowledge.
        try store.updateTask(id: t.id) { $0.title = "A2" }
        XCTAssertNil(store.state.reminders[1].acknowledgedAt)
    }

    func testDeleteAndCancelAcknowledgeTheTasksReminders() throws {
        let store = makeStore()
        let a = try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        let b = try store.addTask(title: "B", day: day, startAt: at("07:00:00"))
        try store.tick()
        XCTAssertEqual(store.state.reminders.count, 2)
        try store.deleteTask(id: a.id)
        try store.setStatus(id: b.id, .cancelled)
        XCTAssertTrue(store.state.reminders.allSatisfy { $0.acknowledgedAt != nil })
        XCTAssertNil(store.reminderToShow(now: at("12:00:00")))
    }

    func testRepeatSelectionShowsTheLeastRecentlyShownAfterTheRepeatInterval() throws {
        let store = makeStore()
        try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        try store.tick()
        clock.set("2026-10-05T07:00:30Z")
        try store.addTask(title: "B", day: day, startAt: at("07:00:20"))
        try store.tick()
        let (ra, rb) = (store.state.reminders[0], store.state.reminders[1])

        // Both are new: the older one first.
        XCTAssertEqual(store.reminderToShow(now: at("07:00:30"))?.id, ra.id)
        try store.markShown(id: ra.id, at: at("07:00:30"))
        // A new reminder is not starved by the old one.
        XCTAssertEqual(store.reminderToShow(now: at("07:00:31"))?.id, rb.id)
        try store.markShown(id: rb.id, at: at("07:00:31"))
        // Within the 60 s repeat interval nothing shows.
        XCTAssertNil(store.reminderToShow(now: at("07:01:29")))
        // After it, the least recently shown comes first.
        XCTAssertEqual(store.reminderToShow(now: at("07:01:30"))?.id, ra.id)
        XCTAssertEqual(store.reminderToShow(now: at("07:01:31"))?.id, ra.id)
        try store.markShown(id: ra.id, at: at("07:01:31"))
        XCTAssertEqual(store.reminderToShow(now: at("07:01:32"))?.id, rb.id)
        // Acknowledged: gone.
        try store.acknowledgeReminder(id: rb.id)
        XCTAssertNil(store.reminderToShow(now: at("07:01:32")))
        XCTAssertEqual(store.reminderToShow(now: at("07:02:31"))?.id, ra.id)
    }

    func testRepeatIntervalComesFromTheSettings() throws {
        let store = makeStore()
        try store.updateSettings { $0.repeatSeconds = 15 }
        try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        try store.tick()
        let id = store.state.reminders[0].id
        try store.markShown(id: id, at: at("07:00:00"))
        XCTAssertNil(store.reminderToShow(now: at("07:00:14")))
        XCTAssertEqual(store.reminderToShow(now: at("07:00:15"))?.id, id)
    }

    func testPendingRemindersListsUnacknowledgedAndUnsnoozed() throws {
        let store = makeStore()
        try store.addTask(title: "A", day: day, startAt: at("07:00:00"))
        try store.addTask(title: "B", day: day, startAt: at("07:00:00"))
        try store.tick()
        try store.snoozeReminder(id: store.state.reminders[1].id, minutes: 10)
        XCTAssertEqual(store.pendingReminders(now: at("07:05:00")).count, 1)
        XCTAssertEqual(store.pendingReminders(now: at("07:10:00")).count, 2)
    }

    func testOldAcknowledgedRemindersOfFinishedTasksAreDroppedButLiveOnesStayForDedup() throws {
        let store = makeStore()
        let done = try store.addTask(title: "done", day: day, startAt: at("07:00:00"))
        let live = try store.addTask(title: "live", day: day, startAt: at("07:00:00"))
        try store.tick()
        try store.setStatus(id: done.id, .done)
        try store.acknowledgeReminder(id: store.state.reminders.first { $0.taskID == live.id }!.id)
        clock.set("2026-10-20T07:00:00Z")
        try store.tick()
        XCTAssertEqual(store.state.reminders.map(\.taskID), [live.id], "the live task keeps its record, so it never repeats")
        XCTAssertFalse(try store.tick().changed)
    }

    // MARK: Focus

    func testFocusIsCappedByTheTimebox() throws {
        let store = makeStore()
        let short = try store.addTask(title: "short", day: day, startAt: at("06:50:00"), endAt: at("07:10:00"))
        let long = try store.addTask(title: "long", day: day, startAt: at("06:50:00"), endAt: at("09:00:00"))
        let open = try store.addTask(title: "no end", day: day)

        let f1 = try store.startFocus(taskID: short.id)
        XCTAssertEqual(f1.durationSeconds, 600, "10 minutes are left in the timebox")
        XCTAssertEqual(f1.endsAt, at("07:10:00"))
        XCTAssertEqual(f1.mode, .focus)
        XCTAssertEqual(f1.status, .running)
        try store.stopFocus()
        XCTAssertEqual(try store.startFocus(taskID: long.id).durationSeconds, 1500, "25 minutes")
        try store.stopFocus()
        XCTAssertEqual(try store.startFocus(taskID: open.id).durationSeconds, 1500)
        try store.stopFocus()
        XCTAssertEqual(try store.startFocus().durationSeconds, 1500, "no task, no cap")
        try store.stopFocus()
        try store.updateSettings { $0.focusMinutes = 40 }
        XCTAssertEqual(try store.startFocus(taskID: long.id).durationSeconds, 2400)
    }

    func testFocusExactlyAtTheEndOrAfterIsRefusedWithTheV1Text() throws {
        let store = makeStore()
        let t = try store.addTask(title: "over", day: day, startAt: at("06:00:00"), endAt: at("07:00:00"))
        XCTAssertThrowsError(try store.startFocus(taskID: t.id)) { error in
            XCTAssertEqual(error as? TBDFlowError, .timeboxEnded)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "This timebox has ended. Replan it before starting focus.")
        }
        clock.advance(600)
        XCTAssertThrowsError(try store.startFocus(taskID: t.id))
        XCTAssertNil(store.state.focus)
    }

    func testBreakIsNotCappedAndUsesTheBreakSetting() throws {
        let store = makeStore()
        let t = try store.addTask(title: "over", day: day, startAt: at("06:00:00"), endAt: at("07:00:00"))
        let b = try store.startFocus(taskID: t.id, mode: .break)
        XCTAssertEqual(b.durationSeconds, 300)
        try store.stopFocus()
        XCTAssertEqual(try store.startFocus(mode: .break, minutes: 10).durationSeconds, 600)
    }

    func testFocusArgumentChecks() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.startFocus(minutes: 0))
        XCTAssertThrowsError(try store.startFocus(minutes: 241))
        XCTAssertThrowsError(try store.startFocus(taskID: "nope")) { XCTAssertEqual($0 as? TBDFlowError, .notFound("Task")) }
        XCTAssertNil(store.state.focus)
    }

    func testTimerTransitions() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.pauseFocus()) { XCTAssertEqual($0 as? TBDFlowError, .noTimer) }
        XCTAssertThrowsError(try store.stopFocus())
        try store.startFocus(minutes: 25)
        XCTAssertThrowsError(try store.startFocus(minutes: 5)) { XCTAssertEqual($0 as? TBDFlowError, .timerBusy) }
        XCTAssertThrowsError(try store.resumeFocus()) { XCTAssertEqual($0 as? TBDFlowError, .invalidTimerTransition) }

        clock.advance(10 * 60)
        let paused = try store.pauseFocus()
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.remainingSeconds, 900)
        XCTAssertNil(paused.endsAt)
        XCTAssertEqual(paused.remaining(at: clock.now), 900)
        XCTAssertThrowsError(try store.pauseFocus()) { XCTAssertEqual($0 as? TBDFlowError, .invalidTimerTransition) }
        XCTAssertThrowsError(try store.startFocus(minutes: 5), "a paused timer is still busy")

        clock.advance(3600) // a long pause does not eat the time
        XCTAssertFalse(try store.tick().changed)
        let resumed = try store.resumeFocus()
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.endsAt, clock.now.addingTimeInterval(900))
        XCTAssertNil(resumed.remainingSeconds)
        XCTAssertEqual(resumed.remaining(at: clock.now.addingTimeInterval(0.4)), 900)

        XCTAssertEqual(try store.stopFocus().status, .stopped)
        XCTAssertThrowsError(try store.pauseFocus())
        XCTAssertNoThrow(try store.startFocus(minutes: 5), "a stopped timer frees the slot")
    }

    func testTickFinishesAnExpiredTimerOnce() throws {
        let store = makeStore()
        try store.startFocus(minutes: 5)
        clock.advance(299)
        XCTAssertNil(try store.tick().finishedFocus)
        clock.advance(1)
        let r = try store.tick()
        XCTAssertEqual(r.finishedFocus?.status, .finished)
        XCTAssertEqual(r.finishedFocus?.finishedAt, clock.now)
        XCTAssertEqual(store.state.focus?.status, .finished)
        XCTAssertNil(try store.tick().finishedFocus)
        XCTAssertNoThrow(try store.startFocus(minutes: 5), "a finished timer frees the slot")
    }

    // MARK: Card labels

    func testPersonLabelIsNeverOverwrittenByModelOrRule() throws {
        let store = makeStore()
        XCTAssertTrue(try store.setCardLabel(cardID: "c1", label: .offPlan, by: .rule))
        XCTAssertTrue(try store.setCardLabel(cardID: "c1", label: .onPlan, taskID: "t1", by: .model))
        XCTAssertFalse(try store.setCardLabel(cardID: "c1", label: .offPlan, by: .rule), "a rule does not overwrite the model")
        XCTAssertEqual(store.cardLabels["c1"]?.label, .onPlan)
        XCTAssertTrue(try store.setCardLabel(cardID: "c1", label: .rest, by: .person))
        XCTAssertFalse(try store.setCardLabel(cardID: "c1", label: .onPlan, taskID: "t1", by: .model))
        XCTAssertFalse(try store.setCardLabel(cardID: "c1", label: .offPlan, by: .rule))
        XCTAssertEqual(store.cardLabels["c1"]?.label, .rest)
        XCTAssertEqual(store.cardLabels["c1"]?.by, .person)
        // The person can change their own mind.
        XCTAssertTrue(try store.setCardLabel(cardID: "c1", label: .onPlan, taskID: "t2", by: .person))
        XCTAssertEqual(store.cardLabels["c1"]?.taskID, "t2")
        // It stays after a restart.
        XCTAssertEqual(makeStore().cardLabels["c1"]?.by, .person)
        // Only the person can clear it.
        try store.clearCardLabel(cardID: "c1")
        XCTAssertNil(store.cardLabels["c1"])
        XCTAssertTrue(try store.setCardLabel(cardID: "c1", label: .offPlan, by: .rule))
    }

    func testSameAuthorReplacesAndOnPlanNeedsATask() throws {
        let store = makeStore()
        try store.setCardLabel(cardID: "c", label: .onPlan, taskID: "t1", by: .rule, at: at("08:00:00"))
        try store.setCardLabel(cardID: "c", label: .offPlan, taskID: "ignored", by: .rule, at: at("08:05:00"))
        XCTAssertEqual(store.cardLabels["c"], TBDFlowCardLabel(cardID: "c", label: .offPlan, taskID: nil, by: .rule, at: at("08:05:00")))
        XCTAssertThrowsError(try store.setCardLabel(cardID: "c", label: .onPlan, by: .person))
    }

    // MARK: Stable card labels (review 18)

    private func card(_ id: String, _ from: String, _ to: String) -> TBDFlowCardEvidence {
        TBDFlowCardEvidence(id: id, start: at(from), end: at(to), title: "T")
    }

    func testALabelKeepsTheSpanOfItsCardAndOldFilesStillLoad() throws {
        let store = makeStore()
        try store.setCardLabel(cardID: "1", label: .offPlan, by: .person, cardStart: at("08:00:00"), cardEnd: at("08:30:00"))
        let reopened = makeStore()
        XCTAssertEqual(reopened.cardLabels["1"]?.start, at("08:00:00"))
        XCTAssertEqual(reopened.cardLabels["1"]?.end, at("08:30:00"))
        try Data(#"{"version":1,"cardLabels":{"9":{"cardID":"9","label":"offPlan","by":"person","at":"2026-10-05T07:00:00.000Z"}}}"#.utf8)
            .write(to: flowURL)
        let old = makeStore()
        XCTAssertNotNil(old.cardLabels["9"])
        XCTAssertNil(old.cardLabels["9"]?.start, "an old label has no span")
    }

    func testALabelWhoseCardIdIsGoneMovesToTheCardAtTheSameTime() throws {
        let store = makeStore()
        try store.setCardLabel(cardID: "old", label: .onPlan, taskID: "t1", by: .person, cardStart: at("08:00:00"), cardEnd: at("08:30:00"))
        // Companion rebuilt the card: same time, new record id.
        let moved = try store.reattachCardLabels(to: [card("new", "08:01:00", "08:30:00"), card("other", "09:00:00", "09:30:00")])
        XCTAssertEqual(moved, 1)
        XCTAssertNil(store.cardLabels["old"])
        XCTAssertEqual(store.cardLabels["new"]?.label, .onPlan)
        XCTAssertEqual(store.cardLabels["new"]?.taskID, "t1")
        XCTAssertEqual(store.cardLabels["new"]?.by, .person)
        XCTAssertEqual(store.cardLabels["new"]?.start, at("08:01:00"), "the span follows the new card")
        XCTAssertNil(store.cardLabels["other"])
        XCTAssertEqual(makeStore().cardLabels["new"]?.by, .person, "the move is saved")
        XCTAssertEqual(try store.reattachCardLabels(to: [card("new", "08:01:00", "08:30:00")]), 0, "nothing to move twice")
    }

    func testReattachNeedsAHalfOverlapAndAKnownSpan() throws {
        let store = makeStore()
        try store.setCardLabel(cardID: "a", label: .offPlan, by: .person, cardStart: at("08:00:00"), cardEnd: at("08:30:00"))
        try store.setCardLabel(cardID: "nospan", label: .rest, by: .person)
        // 10 of 30 minutes overlap: not enough.
        XCTAssertEqual(try store.reattachCardLabels(to: [card("n1", "08:20:00", "08:50:00"), card("n2", "10:00:00", "11:00:00")]), 0)
        XCTAssertNotNil(store.cardLabels["a"])
        XCTAssertNotNil(store.cardLabels["nospan"])
        // A card three times as long that holds the old span is not the same card either.
        XCTAssertEqual(try store.reattachCardLabels(to: [card("big", "07:00:00", "09:30:00")]), 0)
        // 15 of 30 minutes: exactly half is enough.
        XCTAssertEqual(try store.reattachCardLabels(to: [card("half", "08:15:00", "08:45:00")]), 1)
        XCTAssertEqual(store.cardLabels["half"]?.label, .offPlan)
        XCTAssertNotNil(store.cardLabels["nospan"], "a label with no span stays")
    }

    func testPersonLabelsMoveFirstAndNeverLoseToAWeakerOne() throws {
        let store = makeStore()
        try store.setCardLabel(cardID: "m", label: .offPlan, by: .model, cardStart: at("08:00:00"), cardEnd: at("08:30:00"))
        try store.setCardLabel(cardID: "p", label: .rest, by: .person, cardStart: at("08:00:00"), cardEnd: at("08:30:00"))
        XCTAssertEqual(try store.reattachCardLabels(to: [card("new", "08:00:00", "08:30:00")]), 1)
        XCTAssertEqual(store.cardLabels["new"]?.by, .person)
        XCTAssertEqual(store.cardLabels["new"]?.label, .rest)
        XCTAssertNil(store.cardLabels["m"], "the weaker label is dropped, not kept on a gone card")
        XCTAssertNil(store.cardLabels["p"])
    }

    // MARK: Reopened tasks and the frozen Task Board result

    func testReopeningADoneTaskIsRemembered() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day, startAt: at("08:00:00"))
        try store.setStatus(id: t.id, .done)
        XCTAssertNil(store.task(id: t.id)?.reopenedAt)
        clock.set("2026-10-05T09:00:00Z")
        try store.setStatus(id: t.id, .todo)
        XCTAssertEqual(store.task(id: t.id)?.reopenedAt, at("09:00:00"))
        XCTAssertEqual(makeStore().task(id: t.id)?.reopenedAt, at("09:00:00"), "saved")
        let c = try store.addTask(title: "C", day: day)
        try store.setStatus(id: c.id, .cancelled)
        XCTAssertNil(store.task(id: c.id)?.reopenedAt)
    }

    func testTheFrozenTaskBoardResultIsSaved() throws {
        let store = makeStore()
        let t = try store.addTask(title: "A", day: day, source: .taskBoard, taskBoardID: "iss_1")
        XCTAssertNil(t.taskBoardResult)
        try store.updateTask(id: t.id) { $0.taskBoardResult = "Done — tracked in TBD Flow, 45 min on plan" }
        XCTAssertEqual(makeStore().task(id: t.id)?.taskBoardResult, "Done — tracked in TBD Flow, 45 min on plan")
    }
}
