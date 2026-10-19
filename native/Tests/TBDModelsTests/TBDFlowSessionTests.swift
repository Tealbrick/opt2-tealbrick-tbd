import XCTest
@testable import TBDModels

/// Session derivation (port of v1 `CompanionPlanner.syncObservation`) and the schedule helpers.
final class TBDFlowSessionTests: XCTestCase {
    private let cal = FlowT.utc
    private func at(_ time: String) -> Date { FlowT.date("2026-10-05T\(time)Z") }
    private func task(_ id: String, _ title: String, _ start: String?, _ end: String?, status: TBDFlowTaskStatus = .todo,
                      notes: String = "", subtasks: [String] = [], day: String = "2026-10-05") -> TBDFlowTask {
        TBDFlowTask(id: id, title: title, notes: notes, subtasks: subtasks.enumerated().map { TBDFlowSubtask(id: "\(id)-s\($0.offset)", title: $0.element) },
                    status: status, day: day, startAt: start.map(at), endAt: end.map(at), createdAt: at("06:00:00"))
    }
    private func plan(_ tasks: [TBDFlowTask], focus: TBDFlowFocus? = nil, now: String, previous: Date? = nil) -> TBDFlowSessionPlan? {
        TBDFlowSession.plan(tasks: tasks, focus: focus, now: at(now), calendar: cal, previousStartsAt: previous)
    }

    func testNoGoalsMeansNoSession() {
        XCTAssertNil(plan([], now: "10:00:00"))
        // Nothing has started yet.
        XCTAssertNil(plan([task("a", "A", "11:00:00", "12:00:00")], now: "10:00:00"))
        // Everything is done.
        XCTAssertNil(plan([task("a", "A", "09:00:00", "12:00:00", status: .done)], now: "10:00:00"))
        // Only a break has started.
        XCTAssertNil(plan([task("b", "Short break", "09:00:00", "12:00:00")], now: "10:00:00"))
        // Tasks without a start are not today's session.
        XCTAssertNil(plan([task("a", "A", nil, "12:00:00")], now: "10:00:00"))
    }

    func testTheSessionEndsWhenTheLastTaskEnds() {
        let t = [task("a", "A", "09:00:00", "10:00:00")]
        XCTAssertNil(plan(t, now: "10:00:00"), "the end is not in the future")
        XCTAssertNotNil(plan(t, now: "09:59:59"))
        // A later task that is done still extends the session; a cancelled one does not.
        let ext = t + [task("c", "C", "13:00:00", "14:00:00", status: .done)]
        XCTAssertEqual(plan(ext, now: "10:30:00")?.endsAt, at("14:00:00"))
        let live = [task("a", "A", "09:00:00", "11:00:00"), task("c", "C", "13:00:00", "14:00:00", status: .cancelled)]
        XCTAssertEqual(plan(live, now: "10:00:00")?.endsAt, at("11:00:00"))
        let withDone = [task("a", "A", "09:00:00", "11:00:00"), task("d", "D", "12:00:00", "14:00:00", status: .done)]
        XCTAssertEqual(plan(withDone, now: "10:00:00")?.endsAt, at("14:00:00"))
    }

    func testGoalsAreStartedOpenTasksInStartOrderAndTheTextFormat() throws {
        // Today is the calendar day of the START (the `day` field is not used), as in v1.
        var yesterday = task("other", "Yesterday", "09:00:00", "10:00:00", day: "2026-10-04")
        yesterday.startAt = FlowT.date("2026-10-04T09:00:00Z")
        yesterday.endAt = FlowT.date("2026-10-04T23:00:00Z")
        let tasks = [
            task("late", "Later", "09:30:00", "10:30:00"),
            task("full", "Write report", "09:00:00", "10:00:00", notes: "Draft only", subtasks: ["outline", "intro"]),
            task("steps", "Plan trip", "09:10:00", "10:00:00", subtasks: ["flights"]),
            task("notes", "Call Anna", "09:20:00", "10:00:00", notes: "ask about June"),
            task("plain", "Tidy desk", "09:25:00", "10:00:00"),
            task("future", "Not yet", "11:00:00", "12:00:00"),
            task("done", "Finished", "08:00:00", "09:00:00", status: .done),
            task("cancelled", "Dropped", "08:00:00", "09:00:00", status: .cancelled),
            yesterday,
        ]
        let p = try XCTUnwrap(plan(tasks, now: "09:45:00"))
        XCTAssertEqual(p.goals.map(\.id), ["full", "steps", "notes", "plain", "late"])
        XCTAssertEqual(p.goals[0].title, "Write report — Required steps: outline; intro — Draft only")
        XCTAssertEqual(p.goals[1].title, "Plan trip — Required steps: flights")
        XCTAssertEqual(p.goals[2].title, "Call Anna — ask about June")
        XCTAssertEqual(p.goals[3].title, "Tidy desk")
        XCTAssertEqual(p.endsAt, at("12:00:00"))
        XCTAssertNil(p.onBreakUntil)
        XCTAssertFalse(p.isOnBreak)
    }

    func testStartsAtIsNowOrTheKeptValue() throws {
        let t = [task("a", "A", "09:00:00", "11:00:00")]
        XCTAssertEqual(plan(t, now: "10:00:00")?.startsAt, at("10:00:00"))
        XCTAssertEqual(plan(t, now: "10:30:00", previous: at("10:00:00"))?.startsAt, at("10:00:00"))
    }

    func testScheduledBreakByTitle() throws {
        for title in ["Lunch / screen break", "Short break"] {
            let tasks = [task("a", "Work", "09:00:00", "13:00:00"), task("b", title, "10:00:00", "10:15:00")]
            let during = try XCTUnwrap(plan(tasks, now: "10:05:00"))
            XCTAssertEqual(during.onBreakUntil, at("10:15:00"))
            XCTAssertEqual(during.goals.map(\.id), ["a"], "a break is not a goal")
            XCTAssertNil(plan(tasks, now: "10:15:00")?.onBreakUntil, "the end of the break is outside it")
            XCTAssertNil(plan(tasks, now: "09:59:59")?.onBreakUntil)
        }
        // Another title is a goal, not a break.
        let other = [task("a", "Break glass", "09:00:00", "13:00:00")]
        XCTAssertNil(plan(other, now: "10:00:00")?.onBreakUntil)
        XCTAssertEqual(plan(other, now: "10:00:00")?.goals.count, 1)
    }

    func testBreakTimerMakesABreakAndWinsOverAScheduledOne() throws {
        let tasks = [task("a", "Work", "09:00:00", "13:00:00"), task("b", "Short break", "10:00:00", "10:15:00")]
        func focus(_ mode: TBDFlowFocusMode, _ status: TBDFlowFocusStatus, endsAt: String?) -> TBDFlowFocus {
            TBDFlowFocus(id: "f", mode: mode, status: status, startedAt: at("10:00:00"), durationSeconds: 300, endsAt: endsAt.map(at))
        }
        let timer = focus(.break, .running, endsAt: "10:08:00")
        XCTAssertEqual(plan(tasks, focus: timer, now: "10:02:00")?.onBreakUntil, at("10:08:00"), "the timer wins")
        XCTAssertEqual(plan([tasks[0]], focus: timer, now: "10:02:00")?.onBreakUntil, at("10:08:00"))
        XCTAssertNil(plan([tasks[0]], focus: focus(.break, .paused, endsAt: nil), now: "10:02:00")?.onBreakUntil)
        XCTAssertNil(plan([tasks[0]], focus: focus(.focus, .running, endsAt: "10:20:00"), now: "10:02:00")?.onBreakUntil)
        XCTAssertNil(plan([tasks[0]], focus: focus(.break, .finished, endsAt: "10:01:00"), now: "10:02:00")?.onBreakUntil)
    }

    func testTodayFollowsTheCalendarDayOfNow() {
        var bangkok = Calendar(identifier: .gregorian)
        bangkok.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        // The task starts 23:00 on 5 Oct in Bangkok; at 17:30Z it is already 00:30 on 6 Oct there.
        let t = [task("a", "A", "16:00:00", "18:00:00")]
        XCTAssertNotNil(TBDFlowSession.plan(tasks: t, focus: nil, now: at("17:30:00"), calendar: cal))
        XCTAssertNil(TBDFlowSession.plan(tasks: t, focus: nil, now: at("17:30:00"), calendar: bangkok))
        XCTAssertNotNil(TBDFlowSession.plan(tasks: t, focus: nil, now: at("16:30:00"), calendar: bangkok))
    }

    func testNowNextAndTimeboxEnded() {
        let tasks = [
            task("c", "C", "12:00:00", "13:00:00"),
            task("a", "A", "09:00:00", "10:00:00"),
            task("b", "B", "10:00:00", "11:00:00"),
            task("d", "D", "09:00:00", "09:30:00", status: .done),
            task("u", "Untimed", nil, nil),
        ]
        XCTAssertEqual(TBDFlowSession.openTasks(tasks, day: "2026-10-05").map(\.id), ["u", "a", "b", "c"])
        XCTAssertEqual(TBDFlowSession.nowTask(tasks, day: "2026-10-05", now: at("09:30:00"))?.id, "a")
        XCTAssertEqual(TBDFlowSession.nowTask(tasks, day: "2026-10-05", now: at("10:00:00"))?.id, "b", "end is exclusive")
        XCTAssertNil(TBDFlowSession.nowTask(tasks, day: "2026-10-05", now: at("11:30:00")))
        XCTAssertEqual(TBDFlowSession.nextTask(tasks, day: "2026-10-05", now: at("09:30:00"))?.id, "b")
        XCTAssertEqual(TBDFlowSession.nextTask(tasks, day: "2026-10-05", now: at("11:30:00"))?.id, "c")
        XCTAssertNil(TBDFlowSession.nextTask(tasks, day: "2026-10-05", now: at("12:30:00")))

        XCTAssertFalse(TBDFlowSession.isTimeboxEnded(tasks[1], now: at("09:59:59")))
        XCTAssertTrue(TBDFlowSession.isTimeboxEnded(tasks[1], now: at("10:00:00")))
        XCTAssertFalse(TBDFlowSession.isTimeboxEnded(tasks[3], now: at("12:00:00")), "done tasks do not show it")
        XCTAssertFalse(TBDFlowSession.isTimeboxEnded(tasks[4], now: at("12:00:00")), "no end, no timebox")
    }
}
