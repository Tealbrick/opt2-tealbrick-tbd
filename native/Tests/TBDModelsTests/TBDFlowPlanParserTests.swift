import XCTest
@testable import TBDModels

/// The two plan parsers and the idempotent commit (ported from Tasklist `tests/test_schedule.py` and `test_api.py`).
final class TBDFlowPlanParserTests: TBDFlowTestCase {
    private let bratislava = FlowT.zone("Europe/Bratislava")
    private let newYork = FlowT.zone("America/New_York")
    private let bangkok = FlowT.zone("Asia/Bangkok")

    private func strict(_ text: String, day: String = "2026-10-05", zone: TimeZone? = nil) throws -> [TBDFlowTaskDraft] {
        try TBDFlowPlanParser.parseSchedule(text: text, day: day, timeZone: zone ?? bratislava)
    }
    private func message(_ text: String, day: String = "2026-10-05", zone: TimeZone? = nil) -> String? {
        do { _ = try strict(text, day: day, zone: zone); return nil } catch { return (error as? TBDFlowPlanError)?.message }
    }

    // MARK: Strict

    func testValidScheduleWithSubtaskNoteAndTodoLine() throws {
        let d = try strict("09:00–10:00 Návrh ponuky\n  - Rozsah\n  > Zachovať zadanie.\nTODO Zavolať klientovi")
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].title, "Návrh ponuky")
        XCTAssertEqual(FlowT.iso(d[0].startAt), "2026-10-05T07:00:00.000Z") // Bratislava is UTC+2 on 2026-10-05
        XCTAssertEqual(FlowT.iso(d[0].endAt), "2026-10-05T08:00:00.000Z")
        XCTAssertEqual(d[0].durationMinutes, 60)
        XCTAssertEqual(d[0].subtasks, ["Rozsah"])
        XCTAssertEqual(d[0].notes, "Zachovať zadanie.")
        XCTAssertEqual(d[0].day, "2026-10-05")
        XCTAssertEqual(d[1].title, "Zavolať klientovi")
        XCTAssertNil(d[1].startAt)
        XCTAssertNil(d[1].endAt)
        XCTAssertEqual(d[1].durationMinutes, 0)
    }

    func testHyphenSeparatorSingleDigitHourStartOnlyAndMultipleNotes() throws {
        let d = try strict("9:05-9:50 Standup\n  > one\n  > two\n11:30 Call Martin\n  - a\n  - b")
        XCTAssertEqual(d[0].durationMinutes, 45)
        XCTAssertEqual(FlowT.iso(d[0].startAt), "2026-10-05T07:05:00.000Z")
        XCTAssertEqual(d[0].notes, "one\ntwo")
        XCTAssertNotNil(d[1].startAt)
        XCTAssertNil(d[1].endAt, "a start without an end stays open (Tasklist: duration 0)")
        XCTAssertEqual(d[1].subtasks, ["a", "b"])
    }

    func testTitleIsTrimmedBlankLinesAndCRLFAreAccepted() throws {
        let d = try strict("TODO   Buy milk   \r\n\r\n  - 2 liters\r\n\r\nTODO Pay rent")
        XCTAssertEqual(d.map(\.title), ["Buy milk", "Pay rent"])
        XCTAssertEqual(d[0].subtasks, ["2 liters"])
    }

    func testErrorsNameTheLine() {
        XCTAssertEqual(message("  - Orphan"), "Line 1: detail has no parent task")
        XCTAssertEqual(message("09:00–08:00 Bad"), "Line 1: end must follow start on the same day")
        XCTAssertEqual(message("09:00–09:00 Same"), "Line 1: end must follow start on the same day")
        XCTAssertEqual(message("Random prose"), "Line 1: use HH:MM[-HH:MM] Title or TODO Title; no headings")
        XCTAssertEqual(message("09:00 Fine\n  Lost detail"), "Line 2: indented detail must start with - or >")
        XCTAssertEqual(message("# Heading\n09:00 A"), "Line 1: use HH:MM[-HH:MM] Title or TODO Title; no headings")
        XCTAssertEqual(message("TODO A\n\n\nplain"), "Line 4: use HH:MM[-HH:MM] Title or TODO Title; no headings", "blank lines count")
        XCTAssertEqual(message("09:00"), "Line 1: use HH:MM[-HH:MM] Title or TODO Title; no headings")
    }

    func testInvalidClockTimesAreRefused() {
        XCTAssertEqual(message("24:99 Invalid"), "Line 1: Invalid time 24:99")
        XCTAssertEqual(message("24:00 Midnight"), "Line 1: Invalid time 24:00")
        XCTAssertEqual(message("08:60 Late"), "Line 1: Invalid time 08:60")
        XCTAssertEqual(message("TODO ok\n09:00-25:00 Long"), "Line 2: Invalid time 25:00")
    }

    func testSizeLimits() throws {
        XCTAssertEqual(message(""), "Schedule requires 1–6000 characters")
        XCTAssertEqual(message("  \n \n"), "Schedule requires 1–6000 characters")
        let thirty = (1...30).map { "TODO task \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try strict(thirty).count, 30)
        let thirtyOne = (1...31).map { "TODO task \($0)" }.joined(separator: "\n")
        XCTAssertEqual(message(thirtyOne), "Schedule must have 1–30 tasks")
        let tooLong = "TODO " + String(repeating: "x", count: 6000)
        XCTAssertEqual(message(tooLong), "Schedule requires 1–6000 characters")
        XCTAssertEqual(message("TODO " + String(repeating: "x", count: 501)), "Line 1: Title required (max 500 characters)")
        XCTAssertEqual(message("TODO a", day: "2026-13-01"), "day must be an ISO date (yyyy-MM-dd)")
        XCTAssertEqual(message("TODO a", day: "tomorrow"), "day must be an ISO date (yyyy-MM-dd)")
    }

    func testDaylightSavingGapIsRefused() throws {
        // America/New_York 2026-03-08: 02:00 -> 03:00, so 02:30 does not exist.
        let dst = "Ambiguous or nonexistent DST time; use reviewed task API with explicit offsets"
        XCTAssertEqual(message("02:30 Gap", day: "2026-03-08", zone: newYork), "Line 1: " + dst)
        XCTAssertEqual(message("01:00-02:30 Gap end", day: "2026-03-08", zone: newYork), "Line 1: " + dst)
        // The times next to the gap are fine, and 03:00 is EDT (UTC-4).
        let ok = try strict("01:59 Before\n03:00 After", day: "2026-03-08", zone: newYork)
        XCTAssertEqual(FlowT.iso(ok[0].startAt), "2026-03-08T06:59:00.000Z")
        XCTAssertEqual(FlowT.iso(ok[1].startAt), "2026-03-08T07:00:00.000Z")
    }

    func testDaylightSavingRepeatedHourIsRefused() throws {
        // America/New_York 2026-11-01: 02:00 EDT -> 01:00 EST, so 01:30 happens twice.
        let dst = "Ambiguous or nonexistent DST time; use reviewed task API with explicit offsets"
        XCTAssertEqual(message("01:30 Twice", day: "2026-11-01", zone: newYork), "Line 1: " + dst)
        XCTAssertEqual(message("09:00-01:30 x", day: "2026-11-01", zone: newYork), "Line 1: " + dst)
        // 02:30 is only EST; 00:59 is only EDT.
        let ok = try strict("00:59 Before\n02:30 After", day: "2026-11-01", zone: newYork)
        XCTAssertEqual(FlowT.iso(ok[0].startAt), "2026-11-01T04:59:00.000Z")
        XCTAssertEqual(FlowT.iso(ok[1].startAt), "2026-11-01T07:30:00.000Z")
        // The Tasklist test case: Europe/Bratislava 2026-10-25 02:30 happens twice.
        XCTAssertEqual(message("02:30 Ambiguous time", day: "2026-10-25", zone: bratislava), "Line 1: " + dst)
    }

    func testDaylightSavingBoundariesMatchThePythonParser() throws {
        // Checked against schedule_ingest.parse_schedule (zoneinfo) for the same inputs.
        let dst = "Line 1: Ambiguous or nonexistent DST time; use reviewed task API with explicit offsets"
        XCTAssertEqual(message("02:00 x", day: "2026-10-25", zone: bratislava), dst, "02:00-02:59 CEST/CET happens twice")
        XCTAssertEqual(FlowT.iso(try strict("03:00 x", day: "2026-10-25", zone: bratislava)[0].startAt), "2026-10-25T02:00:00.000Z")
        XCTAssertEqual(message("02:00 x", day: "2026-03-29", zone: bratislava), dst, "02:00-02:59 does not exist")
        XCTAssertEqual(FlowT.iso(try strict("03:00 x", day: "2026-03-29", zone: bratislava)[0].startAt), "2026-03-29T01:00:00.000Z")
        XCTAssertEqual(message("01:00 x", day: "2026-11-01", zone: newYork), dst)
        XCTAssertEqual(FlowT.iso(try strict("02:00 x", day: "2026-11-01", zone: newYork)[0].startAt), "2026-11-01T07:00:00.000Z")
    }

    // MARK: Lenient

    func testLenientPortOfTheTasklistParserTest() throws {
        let r = try TBDFlowPlanParser.parseLenient(text: "09:00–10:00 Proposal\n  Outline\n  Estimate\n14:00 Call Martin", day: "2026-09-22", timeZone: bangkok)
        XCTAssertEqual(r.engine, .lenient)
        XCTAssertEqual(r.drafts.count, 2)
        XCTAssertEqual(r.drafts[0].title, "Proposal")
        XCTAssertEqual(r.drafts[0].subtasks, ["Outline", "Estimate"])
        XCTAssertEqual(r.drafts[0].durationMinutes, 60)
        XCTAssertEqual(FlowT.iso(r.drafts[0].startAt), "2026-09-22T02:00:00.000Z") // Bangkok UTC+7
        XCTAssertEqual(r.drafts[1].title, "Call Martin")
        XCTAssertNil(r.drafts[1].endAt)
        XCTAssertTrue(r.requiresReview)
        XCTAssertEqual(r.warnings, ["Review dates and task boundaries. This parser does not infer plans from prose."])
    }

    func testLenientStripsBulletsAndNumbering() throws {
        let text = "- Buy milk\n* Call Anna\n• Write report\n1. First\n2) Second\n  - sub one\n  * sub two\n10. 09:30 Standup"
        let r = try TBDFlowPlanParser.parseLenient(text: text, day: "2026-09-22", timeZone: bangkok)
        XCTAssertEqual(r.drafts.map(\.title), ["Buy milk", "Call Anna", "Write report", "First", "Second", "Standup"])
        XCTAssertEqual(r.drafts[4].subtasks, ["sub one", "sub two"])
        XCTAssertNotNil(r.drafts[5].startAt, "a time after the number is a timebox")
        XCTAssertTrue(r.drafts.allSatisfy { $0.day == "2026-09-22" })
    }

    func testLenientWarnsAboutWrongTimesAndKeepsTheLine() throws {
        let r = try TBDFlowPlanParser.parseLenient(text: "25:00 Foo\n10:00-09:00 Backwards", day: "2026-09-22", timeZone: bangkok)
        XCTAssertEqual(r.drafts[0].title, "25:00 Foo")
        XCTAssertNil(r.drafts[0].startAt)
        XCTAssertEqual(r.drafts[1].title, "Backwards", "as in Python: the start is kept, the title loses its times")
        XCTAssertNotNil(r.drafts[1].startAt)
        XCTAssertNil(r.drafts[1].endAt)
        XCTAssertTrue(r.warnings.contains("Check time: 25:00 Foo"))
        XCTAssertTrue(r.warnings.contains("Check time: 10:00-09:00 Backwards"))
    }

    func testLenientIndentedFirstLineAndEmptyInput() throws {
        let r = try TBDFlowPlanParser.parseLenient(text: "  orphan line", day: "2026-09-22", timeZone: bangkok)
        XCTAssertEqual(r.drafts.map(\.title), ["orphan line"], "no parent: it is a task")
        XCTAssertThrowsError(try TBDFlowPlanParser.parseLenient(text: " \n\n", day: "2026-09-22", timeZone: bangkok)) {
            XCTAssertEqual(($0 as? TBDFlowPlanError)?.message, "Paste at least one task")
        }
    }

    func testLenientWarnsInTheDaylightSavingGap() throws {
        let r = try TBDFlowPlanParser.parseLenient(text: "02:30 Gap", day: "2026-03-08", timeZone: newYork)
        XCTAssertEqual(r.drafts.count, 1)
        XCTAssertTrue(r.warnings.contains("Check time (daylight saving): 02:30 Gap"))
    }

    // MARK: Preview

    func testPreviewUsesStrictWhenTheTextFitsAndLenientWhenItDoesNot() throws {
        let s = try TBDFlowPlanParser.preview(text: "09:00-10:00 A\nTODO B", day: "2026-10-05", timeZone: bratislava)
        XCTAssertEqual(s.engine, .strict)
        XCTAssertEqual(s.warnings, [])
        XCTAssertFalse(s.requiresReview)
        XCTAssertNil(s.strictError)

        let l = try TBDFlowPlanParser.preview(text: "- Buy milk\n- 09:00 Call", day: "2026-10-05", timeZone: bratislava)
        XCTAssertEqual(l.engine, .lenient)
        XCTAssertEqual(l.strictError, "Line 1: use HH:MM[-HH:MM] Title or TODO Title; no headings")
        XCTAssertEqual(l.drafts.count, 2)
        XCTAssertTrue(l.requiresReview)
        XCTAssertFalse(l.warnings.isEmpty)
    }

    func testPreviewOfNothingIsAnError() {
        XCTAssertThrowsError(try TBDFlowPlanParser.preview(text: "   ", day: "2026-10-05", timeZone: bratislava))
    }

    // MARK: Idempotency

    func testPayloadHashIsStableAndSensitive() {
        let a = TBDFlowPlanParser.payloadHash(format: "agent-schedule-v1", text: "TODO a", day: "2026-10-05", timeZone: bratislava)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, TBDFlowPlanParser.payloadHash(format: "agent-schedule-v1", text: "TODO a", day: "2026-10-05", timeZone: bratislava))
        XCTAssertNotEqual(a, TBDFlowPlanParser.payloadHash(format: "agent-schedule-v1", text: "TODO b", day: "2026-10-05", timeZone: bratislava))
        XCTAssertNotEqual(a, TBDFlowPlanParser.payloadHash(format: "agent-schedule-v1", text: "TODO a", day: "2026-10-06", timeZone: bratislava))
        XCTAssertNotEqual(a, TBDFlowPlanParser.payloadHash(format: "agent-schedule-v1", text: "TODO a", day: "2026-10-05", timeZone: bangkok))
        XCTAssertNotEqual(a, TBDFlowPlanParser.payloadHash(format: "lenient", text: "TODO a", day: "2026-10-05", timeZone: bratislava))
    }

    func testCommitSameKeyAndPayloadReturnsTheOriginalTasksWithoutAdding() throws {
        let store = makeStore()
        let text = "09:00–10:00 Návrh ponuky\n  - Rozsah\nTODO Zavolať klientovi"
        let drafts = try strict(text)
        let hash = TBDFlowPlanParser.payloadHash(format: TBDFlowPlanParser.format, text: text, day: "2026-10-05", timeZone: bratislava)

        let first = try store.commit(drafts: drafts, idempotencyKey: "plan-1", payloadHash: hash)
        XCTAssertFalse(first.replayed)
        XCTAssertEqual(first.taskIDs.count, 2)
        XCTAssertEqual(store.state.tasks.count, 2)
        XCTAssertEqual(store.state.tasks[0].subtasks.map(\.title), ["Rozsah"])

        let retry = try store.commit(drafts: drafts, idempotencyKey: "plan-1", payloadHash: hash)
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.taskIDs, first.taskIDs)
        XCTAssertEqual(retry.tasks, first.tasks)
        XCTAssertEqual(store.state.tasks.count, 2, "nothing was added")

        // The record survives a restart.
        let reopened = makeStore()
        XCTAssertEqual(try reopened.commit(drafts: drafts, idempotencyKey: "plan-1", payloadHash: hash).taskIDs, first.taskIDs)
        XCTAssertEqual(reopened.state.tasks.count, 2)
    }

    func testCommitSameKeyWithDifferentPayloadIsAConflict() throws {
        let store = makeStore()
        let a = try strict("TODO a")
        let b = try strict("TODO Other")
        _ = try store.commit(drafts: a, idempotencyKey: "k", payloadHash: "hash-a")
        XCTAssertThrowsError(try store.commit(drafts: b, idempotencyKey: "k", payloadHash: "hash-b")) {
            XCTAssertEqual($0 as? TBDFlowError, .idempotencyConflict)
        }
        XCTAssertEqual(store.state.tasks.count, 1)
        // A new key appends; it never replaces.
        _ = try store.commit(drafts: b, idempotencyKey: "k2", payloadHash: "hash-b")
        XCTAssertEqual(store.state.tasks.map(\.title), ["a", "Other"])
    }

    func testCommitKeyAndDraftLimitsAndAtomicity() throws {
        let store = makeStore()
        let one = try strict("TODO a")
        XCTAssertThrowsError(try store.commit(drafts: one, idempotencyKey: "", payloadHash: "h")) { XCTAssertEqual($0 as? TBDFlowError, .idempotencyKeyRequired) }
        XCTAssertThrowsError(try store.commit(drafts: one, idempotencyKey: String(repeating: "k", count: 201), payloadHash: "h"))
        XCTAssertThrowsError(try store.commit(drafts: [], idempotencyKey: "k", payloadHash: "h"))
        // One bad draft saves nothing (Tasklist: "atomic import").
        let bad = TBDFlowTaskDraft(title: "", day: "2026-10-05")
        XCTAssertThrowsError(try store.commit(drafts: one + [bad], idempotencyKey: "k", payloadHash: "h"))
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertTrue(store.state.imports.isEmpty)
    }
}
