import XCTest
@testable import TBDModels

/// F4: the Task Board source rules (pure), the "Looks done" hint in the store, and pasted-plan linking.
final class TBDFlowTaskBoardTests: TBDFlowTestCase {
    private let day = "2026-10-05"
    private func at(_ time: String) -> Date { FlowT.date("2026-10-05T\(time)Z") }

    // MARK: Helper shape

    func testListParsesTheHelperAnswerAndDropsOffShapeRows() {
        let value: [String: Any] = [
            "available": true,
            "issues": [
                ["id": "iss_1", "title": "A", "summary": "s", "project": "TBD", "status": "in_progress", "priority": "high", "ready": false],
                ["id": "iss_2", "title": "B", "summary": "", "project": "Ops", "status": "todo", "priority": "low", "ready": true],
                ["id": "iss_3", "title": "C", "status": "todo", "ready": false],
                ["id": "iss_4", "title": "D", "status": "done"],
                ["title": "no id", "status": "todo"],
            ] as [[String: Any]],
        ]
        let list = TBDFlowTaskBoardList(helperValue: value)
        XCTAssertEqual(list?.available, true)
        XCTAssertEqual(list?.issues.map(\.id), ["iss_1", "iss_2", "iss_3"])
        // In progress first, then ready issues only (iss_3 waits on a dependency).
        XCTAssertEqual(list?.pickable.map(\.id), ["iss_1", "iss_2"])
        let off = TBDFlowTaskBoardList(helperValue: ["available": false, "reason": "no access", "issues": []] as [String: Any])
        XCTAssertEqual(off, TBDFlowTaskBoardList(available: false, reason: "no access", issues: []))
        XCTAssertNil(TBDFlowTaskBoardList(helperValue: "nope"))
        XCTAssertNil(TBDFlowTaskBoardList(helperValue: ["issues": []] as [String: Any]))
    }

    // MARK: Decision table

    func testDecisionTable() {
        let ok = "x"
        let probes: [TBDFlowTaskBoardProbe] = [.unanswered, .available, .unavailable(ok), .failed(ok)]
        for connected in [true, false] {
            for probe in probes {
                XCTAssertEqual(TBDFlowSource.decide(access: .locked, agentConnected: connected, probe: probe), .local(.notLicensed))
                XCTAssertEqual(TBDFlowSource.decide(access: .install, agentConnected: connected, probe: probe), .local(.installNeeded))
                XCTAssertEqual(TBDFlowSource.decide(access: .unknown, agentConnected: connected, probe: probe), .local(.checking), "unknown never locks, never uses Task Board")
            }
        }
        for probe in probes { XCTAssertEqual(TBDFlowSource.decide(access: .unlocked, agentConnected: false, probe: probe), .local(.notConnected)) }
        XCTAssertEqual(TBDFlowSource.decide(access: .unlocked, agentConnected: true, probe: .unanswered), .local(.checking))
        XCTAssertEqual(TBDFlowSource.decide(access: .unlocked, agentConnected: true, probe: .available), .taskBoard)
        XCTAssertEqual(TBDFlowSource.decide(access: .unlocked, agentConnected: true, probe: .unavailable(ok)), .local(.notGranted(ok)))
        XCTAssertEqual(TBDFlowSource.decide(access: .unlocked, agentConnected: true, probe: .failed(ok)), .local(.failed(ok)))
    }

    func testNotices() {
        XCTAssertNil(TBDFlowSource.notice(.taskBoard))
        XCTAssertEqual(TBDFlowSource.notice(.local(.notLicensed)), "Task list from Task Board: available with Task Board. Until then TBD keeps this list on this Mac.")
        XCTAssertEqual(TBDFlowSource.notice(.local(.checking)), "Checking Task Board…")
        XCTAssertEqual(TBDFlowSource.notice(.local(.notGranted("no grant sentence"))), "no grant sentence")
    }

    // MARK: Linking

    func testNormalizeIgnoresCaseAccentsSpacesAndEdgePunctuation() {
        XCTAssertEqual(TBDFlowTaskBoardLinker.normalize("  Reply   to Éyal. "), "reply to eyal")
        XCTAssertEqual(TBDFlowTaskBoardLinker.normalize("Weekly review!"), TBDFlowTaskBoardLinker.normalize("weekly   REVIEW"))
    }

    func testLinkingTakesTheIssueOnlyForAnExactUniqueTitle() {
        let issues = [
            TBDFlowTaskBoardIssue(id: "iss_a", title: "Weekly review", project: "Ops"),
            TBDFlowTaskBoardIssue(id: "iss_b", title: "Twin", project: "TBD"),
            TBDFlowTaskBoardIssue(id: "iss_c", title: "twin", project: "Ops"),
            TBDFlowTaskBoardIssue(id: "iss_d", title: "Answer Penpot", project: ""),
        ]
        let drafts = [
            TBDFlowTaskDraft(title: "weekly  review", day: day, startAt: at("16:00:00")),
            TBDFlowTaskDraft(title: "Weekly review", day: day),  // second line for the same issue: stays local
            TBDFlowTaskDraft(title: "Twin", day: day),  // two issues share the title: no guessing
            TBDFlowTaskDraft(title: "Answer Penpot", day: day),
            TBDFlowTaskDraft(title: "Something only here", day: day),
        ]
        let linked = TBDFlowTaskBoardLinker.link(drafts, issues: issues)
        XCTAssertEqual(linked.map(\.taskBoardID), ["iss_a", nil, nil, "iss_d", nil])
        XCTAssertEqual(linked[0].title, "Weekly review", "the title snapshot is the issue's")
        XCTAssertEqual(linked[0].taskBoardProject, "Ops")
        XCTAssertEqual(linked[0].startAt, at("16:00:00"), "the timebox of the line is kept")
        XCTAssertNil(linked[3].taskBoardProject)
        XCTAssertEqual(linked[4], drafts[4])
        XCTAssertEqual(TBDFlowTaskBoardLinker.link(drafts, issues: []).map(\.taskBoardID), [nil, nil, nil, nil, nil])
    }

    func testCommitMakesTaskBoardTasksForLinkedDraftsAndLocalOnesForTheRest() throws {
        let store = makeStore()
        let drafts = TBDFlowTaskBoardLinker.link(
            [TBDFlowTaskDraft(title: "Weekly review", day: day), TBDFlowTaskDraft(title: "Mine", day: day)],
            issues: [TBDFlowTaskBoardIssue(id: "iss_a", title: "Weekly review", project: "Ops")])
        let result = try store.commit(drafts: drafts, idempotencyKey: "k1", payloadHash: "h")
        XCTAssertEqual(result.tasks.map(\.source), [.taskBoard, .local])
        XCTAssertEqual(result.tasks.map(\.taskBoardID), ["iss_a", nil])
        XCTAssertEqual(result.tasks.map(\.taskBoardProject), ["Ops", nil])
        XCTAssertEqual(makeStore().state.tasks.map(\.taskBoardID), ["iss_a", nil], "the link survives a reopen")
    }

    // MARK: Time range

    func testTimeRangeField() {
        let d = at("08:00:00")
        let utc = FlowT.utc
        XCTAssertEqual(TBDFlowTimeRange.parse("", day: d, calendar: utc), .none)
        XCTAssertEqual(TBDFlowTimeRange.parse("09:40 – 11:30", day: d, calendar: utc), .range(at("09:40:00"), at("11:30:00")))
        XCTAssertEqual(TBDFlowTimeRange.parse("9:40-11:30", day: d, calendar: utc), .range(at("09:40:00"), at("11:30:00")))
        XCTAssertEqual(TBDFlowTimeRange.parse("16:00 to 16:30", day: d, calendar: utc), .range(at("16:00:00"), at("16:30:00")))
        XCTAssertEqual(TBDFlowTimeRange.parse("11:30-09:40", day: d, calendar: utc), .invalid("The end must come after the start."))
        for bad in ["9", "25:00-26:00", "09:40", "09:40-", "ab-cd", "09:7-10:00"] {
            XCTAssertEqual(TBDFlowTimeRange.parse(bad, day: d, calendar: utc), .invalid(TBDFlowTimeRange.invalidMessage), bad)
        }
    }

    func testResultText() {
        XCTAssertEqual(TBDFlowTaskBoardResult.text(minutesOnPlan: 45), "Done — tracked in TBD Flow, 45 min on plan")
        XCTAssertEqual(TBDFlowTaskBoardResult.text(minutesOnPlan: 0), "Done — tracked in TBD Flow, 0 min on plan")
        XCTAssertEqual(TBDFlowTaskBoardResult.text(minutesOnPlan: -3), "Done — tracked in TBD Flow, 0 min on plan")
    }

    // MARK: Looks done

    func testLooksDoneIsSetOnceAndWritesNothingElse() throws {
        let store = makeStore()
        let task = try store.addTask(title: "Reply", day: day, source: .taskBoard, taskBoardID: "iss_1", taskBoardProject: "Ops")
        let before = store.state.tasks[0]
        XCTAssertTrue(try store.markLooksDone(id: task.id))
        let after = store.state.tasks[0]
        XCTAssertNotNil(after.looksDoneAt)
        XCTAssertEqual(after.status, .todo, "the hint never changes the status")
        XCTAssertNil(after.completedAt)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertFalse(try store.markLooksDone(id: task.id), "already flagged")
        XCTAssertFalse(try store.markLooksDone(id: "gone"))
        XCTAssertEqual(makeStore().state.tasks[0].looksDoneAt, after.looksDoneAt, "persisted")
    }

    func testNotYetClearsTheHintFor30MinutesThenItCanComeBack() throws {
        let store = makeStore()
        let task = try store.addTask(title: "Reply", day: day, source: .taskBoard, taskBoardID: "iss_1")
        try store.markLooksDone(id: task.id)
        try store.dismissLooksDone(id: task.id)
        XCTAssertNil(store.state.tasks[0].looksDoneAt)
        XCTAssertNotNil(store.state.tasks[0].looksDoneDismissedAt)

        clock.advance(29 * 60)
        XCTAssertFalse(try store.markLooksDone(id: task.id), "re-detected after 29 min: still quiet")
        XCTAssertNil(store.state.tasks[0].looksDoneAt)
        clock.advance(61)
        XCTAssertTrue(try store.markLooksDone(id: task.id), "after 30 min it may come back")
        XCTAssertNotNil(store.state.tasks[0].looksDoneAt)
        XCTAssertNil(store.state.tasks[0].looksDoneDismissedAt)
        XCTAssertThrowsError(try store.dismissLooksDone(id: "gone"))
    }

    func testDoneOrCancelledTasksTakeNoHintAndClearTheOldOne() throws {
        let store = makeStore()
        let a = try store.addTask(title: "A", day: day)
        try store.markLooksDone(id: a.id)
        try store.setStatus(id: a.id, .done)
        XCTAssertNil(store.state.tasks[0].looksDoneAt, "done clears the hint")
        XCTAssertFalse(try store.markLooksDone(id: a.id))
        let b = try store.addTask(title: "B", day: day)
        try store.setStatus(id: b.id, .cancelled)
        XCTAssertFalse(try store.markLooksDone(id: b.id))
    }

    func testAnOldFileWithoutTheNewFieldsLoadsWithDefaults() throws {
        let json = """
        {"version":1,"tasks":[{"id":"t1","title":"Old","notes":"","subtasks":[],"status":"todo","day":"2026-10-05",
        "source":"taskBoard","taskBoardID":"iss_9","taskBoardProject":"Ops","createdAt":"2026-10-05T07:00:00.000Z","updatedAt":"2026-10-05T07:00:00.000Z"}],
        "reminders":[],"settings":{},"cardLabels":{},"imports":{}}
        """
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: flowURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertNil(store.corruptBackupURL, "an old file is not corrupt")
        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertNil(store.state.tasks[0].looksDoneAt)
        XCTAssertNil(store.state.tasks[0].looksDoneDismissedAt)
        XCTAssertEqual(store.state.tasks[0].taskBoardID, "iss_9")
        // And it writes the new fields back and reads them again.
        XCTAssertTrue(try store.markLooksDone(id: "t1"))
        XCTAssertNotNil(makeStore().state.tasks[0].looksDoneAt)
    }
}
