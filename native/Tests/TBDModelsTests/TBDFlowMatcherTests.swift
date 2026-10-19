import XCTest
@testable import TBDModels

/// The rule matcher for plan vs actual (DESIGN-FLOW.md 2.4): proposals, thresholds, corrections and minutes.
final class TBDFlowMatcherTests: TBDFlowTestCase {
    private func at(_ time: String) -> Date { FlowT.date("2026-10-05T\(time)Z") }
    private func card(_ id: String, _ from: String, _ to: String, _ title: String, _ summary: String = "", category: String? = nil) -> TBDFlowCardEvidence {
        TBDFlowCardEvidence(id: id, start: at(from + ":00"), end: at(to + ":00"), title: title, summary: summary, apps: [], category: category)
    }
    private func task(_ id: String, _ title: String, _ from: String?, _ to: String?, notes: String = "", subtasks: [String] = [],
                      status: TBDFlowTaskStatus = .todo) -> TBDFlowTask {
        TBDFlowTask(id: id, title: title, notes: notes, subtasks: subtasks.enumerated().map { TBDFlowSubtask(id: "\(id)\($0.offset)", title: $0.element) },
                    status: status, day: "2026-10-05", startAt: from.map { at($0 + ":00") }, endAt: to.map { at($0 + ":00") }, createdAt: at("06:00:00"))
    }
    private var plan: [TBDFlowTask] {
        [
            task("t1", "Write proposal", "09:00", "10:00", notes: "client scope", subtasks: ["pricing table"]),
            task("br", "Short break", "10:00", "10:30"),
            task("t2", "Review invoices", "10:30", "12:00"),
        ]
    }
    private func propose(_ c: TBDFlowCardEvidence, _ tasks: [TBDFlowTask]? = nil) -> TBDFlowMatch? {
        TBDFlowMatcher.propose(card: c, tasks: tasks ?? plan)
    }

    func testThresholdConstantsArePinned() {
        XCTAssertEqual(TBDFlowMatcher.timeboxOverlapFraction, 0.5)
        XCTAssertEqual(TBDFlowMatcher.titleWordWeight, 1.0)
        XCTAssertEqual(TBDFlowMatcher.detailWordWeight, 0.5)
        XCTAssertEqual(TBDFlowMatcher.timeboxWordThreshold, 1.0)
        XCTAssertEqual(TBDFlowMatcher.strongWordThreshold, 2.0)
        XCTAssertEqual(TBDFlowMatcher.minWordLength, 3)
    }

    // MARK: Words

    func testWordsDropStopWordsShortWordsAndPlurals() {
        XCTAssertEqual(TBDFlowMatcher.words("The Work of a Page"), [])
        XCTAssertEqual(TBDFlowMatcher.words("Invoices, INVOICE; policies (policy) boxes box class bus"), ["invoice", "policy", "box", "class", "bus"])
        XCTAssertEqual(TBDFlowMatcher.words("Q3 budget-review 2026"), ["budget", "review", "2026"])
        XCTAssertEqual(TBDFlowMatcher.stem("watches"), "watch")
        XCTAssertEqual(TBDFlowMatcher.stem("glasses"), "glass")
        XCTAssertEqual(TBDFlowMatcher.stem("analysis"), "analysis")
    }

    // MARK: On plan, off plan

    func testCardInTheTimeboxWithSharedWordsIsOnPlan() throws {
        let m = try XCTUnwrap(propose(card("c", "09:10", "09:40", "Proposal draft — Google Docs")))
        XCTAssertEqual(m.label, .onPlan)
        XCTAssertEqual(m.taskID, "t1")
        XCTAssertEqual(m.score, 1.0)
    }

    func testCardInTheTimeboxWithoutSharedWordsIsOffPlan() {
        let m = propose(card("c", "09:10", "09:40", "Slack", "chatting with the team"))
        XCTAssertEqual(m, TBDFlowMatch(label: .offPlan, taskID: nil, score: 0))
    }

    func testTimeboxNeedsOneTitleWordOrTwoDetailWords() {
        // One word from the notes: 0.5, below 1.0.
        XCTAssertEqual(propose(card("a", "09:10", "09:40", "client chat"))?.label, .offPlan)
        // Two words from notes and subtasks: 1.0.
        XCTAssertEqual(propose(card("b", "09:10", "09:40", "client scope"))?.taskID, "t1")
        XCTAssertEqual(propose(card("c", "09:10", "09:40", "pricing", "table"))?.taskID, "t1")
    }

    func testWithoutATimeboxMatchTheWordsMustBeStrong() {
        // 11:00 lies in the invoices timebox. "proposal client scope" = 1 + 0.5 + 0.5 = 2.0 for t1.
        let strong = propose(card("a", "11:00", "11:20", "Proposal client scope"))
        XCTAssertEqual(strong?.label, .onPlan)
        XCTAssertEqual(strong?.taskID, "t1")
        XCTAssertEqual(strong?.score, 2.0)
        // One title word is 1.0: not enough outside the timebox.
        XCTAssertEqual(propose(card("b", "11:00", "11:20", "Proposal"))?.label, .offPlan)
        // 1.5 is still below the bar.
        XCTAssertEqual(propose(card("c", "11:00", "11:20", "Proposal client"))?.label, .offPlan)
    }

    func testPluralsMatch() {
        XCTAssertEqual(propose(card("a", "10:35", "11:00", "invoice review notes"))?.taskID, "t2")
        XCTAssertEqual(propose(card("b", "09:10", "09:40", "Proposals"))?.taskID, "t1")
    }

    func testTheTimeboxMatchWinsAnOtherwiseEqualScore() {
        let tasks = [task("a", "Design review", "09:00", "10:00"), task("b", "Design review", "10:00", "11:00")]
        XCTAssertEqual(propose(card("c1", "10:10", "10:40", "design review"), tasks)?.taskID, "b")
        XCTAssertEqual(propose(card("c2", "09:10", "09:40", "design review"), tasks)?.taskID, "a")
        // A higher score beats the timebox (strong words for the other task).
        let three = [task("a", "Design review sprint", "09:00", "10:00"), task("b", "Design review", "10:00", "11:00")]
        XCTAssertEqual(propose(card("c3", "10:10", "10:40", "design review sprint"), three)?.taskID, "a")
        // No times at all: the earlier task of the list wins a tie.
        let untimed = [task("x", "Design review", nil, nil), task("y", "Design review", nil, nil)]
        XCTAssertEqual(propose(card("c4", "10:10", "10:40", "design review"), untimed)?.taskID, "x")
    }

    func testCardsOnlyPartlyInATimeboxUseTheHalfRule() {
        let tasks = [task("t1", "Write proposal", "09:00", "10:00"), task("t2", "Review invoices", "10:00", "11:00")]
        // 09:50-10:20: 10 of 30 minutes in the proposal timebox (33%), so one title word is not enough.
        XCTAssertEqual(propose(card("a", "09:50", "10:20", "Proposal"), tasks)?.label, .offPlan)
        // 09:40-10:10: 20 of 30 minutes (67%).
        XCTAssertEqual(propose(card("b", "09:40", "10:10", "Proposal"), tasks)?.taskID, "t1")
    }

    func testCancelledTasksAreIgnoredAndNoTasksMeansNoPlan() {
        let tasks = [task("t1", "Write proposal", "09:00", "10:00", status: .cancelled)]
        XCTAssertNil(propose(card("a", "09:10", "09:40", "proposal"), tasks))
        XCTAssertNil(propose(card("a", "09:10", "09:40", "proposal"), []))
        let two = tasks + [task("t2", "Other thing", "09:00", "10:00")]
        XCTAssertEqual(propose(card("a", "09:10", "09:40", "proposal"), two)?.label, .offPlan, "the cancelled task cannot take the card")
    }

    func testDoneTasksStillTakeTheirCards() {
        let tasks = [task("t1", "Write proposal", "09:00", "10:00", status: .done), task("t2", "Other", "10:00", "11:00")]
        XCTAssertEqual(propose(card("a", "09:10", "09:40", "proposal"), tasks)?.taskID, "t1")
    }

    // MARK: Outside the plan

    func testCardsBeforeTheFirstTaskOrAfterTheLastAreNotCounted() {
        XCTAssertNil(propose(card("a", "08:00", "08:30", "Youtube")))
        XCTAssertNil(propose(card("b", "08:30", "09:00", "Youtube")), "ends exactly at the first start")
        XCTAssertNotNil(propose(card("c", "08:40", "09:10", "Youtube")), "overlaps the plan")
        XCTAssertNil(propose(card("d", "12:00", "12:30", "Youtube")), "starts exactly at the last end")
        XCTAssertNil(propose(card("e", "15:00", "15:10", "proposal client scope")))
        XCTAssertNotNil(propose(card("f", "11:50", "12:10", "Youtube")))
    }

    // MARK: Rest

    func testCardInABreakTaskIsRest() {
        XCTAssertEqual(propose(card("a", "10:05", "10:25", "Twitter"))?.label, .rest)
        // 10:20-10:50: a third in the break, two thirds in the invoices timebox.
        XCTAssertNotEqual(propose(card("b", "10:20", "10:50", "Twitter"))?.label, .rest)
        XCTAssertEqual(propose(card("c", "10:20", "10:50", "Invoice review"))?.taskID, "t2")
        // The lunch title works too.
        let lunch = [task("w", "Work", "09:00", "17:00"), task("l", "Lunch / screen break", "12:00", "12:45")]
        XCTAssertEqual(propose(card("d", "12:05", "12:40", "Email"), lunch)?.label, .rest)
    }

    func testIdleOrBreakCategoryIsRest() {
        XCTAssertEqual(propose(card("a", "09:10", "09:40", "Screen locked", category: "Idle"))?.label, .rest)
        XCTAssertEqual(propose(card("b", "09:10", "09:40", "x", category: "Break time"))?.label, .rest)
        XCTAssertEqual(propose(card("c", "11:10", "11:40", "x", category: "Away"))?.label, .rest)
        XCTAssertNotEqual(propose(card("d", "09:10", "09:40", "x", category: "Productivity"))?.label, .rest)
        // Outside the plan stays outside, even when idle.
        XCTAssertNil(propose(card("e", "07:00", "07:30", "x", category: "Idle")))
    }

    // MARK: Rule label

    func testRuleLabelIsStoredAsByRule() throws {
        let l = try XCTUnwrap(TBDFlowMatcher.ruleLabel(for: card("c", "09:10", "09:40", "proposal"), tasks: plan, at: at("12:00:00")))
        XCTAssertEqual(l, TBDFlowCardLabel(cardID: "c", label: .onPlan, taskID: "t1", by: .rule, at: at("12:00:00")))
        XCTAssertNil(TBDFlowMatcher.ruleLabel(for: card("o", "07:00", "07:30", "x"), tasks: plan, at: at("12:00:00")))
    }

    // MARK: Corrections and minutes

    private var cards: [TBDFlowCardEvidence] {
        [
            card("c1", "09:00", "09:30", "Proposal draft"),   // on plan t1, 30
            card("c2", "09:30", "10:00", "YouTube"),          // off plan, 30
            card("c3", "10:00", "10:20", "Phone"),            // rest, 20
            card("c4", "08:00", "08:20", "Email"),            // outside, 20
            card("c5", "10:30", "11:00", "Invoice review"),   // on plan t2, 30
        ]
    }

    func testTotalsFromTheRulesAlone() {
        let t = TBDFlowMatcher.totals(labels: [:], cards: cards, tasks: plan)
        XCTAssertEqual(t.onPlanMinutes, 60)
        XCTAssertEqual(t.offPlanMinutes, 30)
        XCTAssertEqual(t.restMinutes, 20)
        XCTAssertEqual(t.outsideMinutes, 20, "outside the plan is not counted as off plan")
        XCTAssertEqual(TBDFlowMatcher.minutesPerTask(labels: [:], cards: cards, tasks: plan), ["t1": 30, "t2": 30])
    }

    func testWithoutTasksOnlyStoredLabelsCount() {
        let labels = ["c1": TBDFlowCardLabel(cardID: "c1", label: .onPlan, taskID: "t1", by: .model, at: at("12:00:00"))]
        let t = TBDFlowMatcher.totals(labels: labels, cards: cards)
        XCTAssertEqual(t.onPlanMinutes, 30)
        XCTAssertEqual(t.outsideMinutes, 100, "no plan: nothing to compare with")
        XCTAssertEqual(TBDFlowMatcher.minutesPerTask(labels: labels, cards: cards), ["t1": 30])
    }

    func testPersonCorrectionWinsOverModelAndRule() throws {
        let store = makeStore()
        // c2: the rule says off plan. The model says rest. The person says it was t1.
        try store.setCardLabel(cardID: "c2", label: .rest, by: .model, at: at("12:00:00"))
        var effective = try XCTUnwrap(TBDFlowMatcher.effectiveLabel(for: cards[1], stored: store.cardLabels, tasks: plan))
        XCTAssertEqual(effective.label, .rest, "a stored model label beats the live rule")
        XCTAssertEqual(effective.by, .model)

        try store.setCardLabel(cardID: "c2", label: .onPlan, taskID: "t1", by: .person, at: at("12:05:00"))
        // Later the model and the rule try again: refused.
        XCTAssertFalse(try store.setCardLabel(cardID: "c2", label: .offPlan, by: .model))
        XCTAssertFalse(try store.setCardLabel(cardID: "c2", label: .offPlan, by: .rule))
        effective = try XCTUnwrap(TBDFlowMatcher.effectiveLabel(for: cards[1], stored: store.cardLabels, tasks: plan))
        XCTAssertEqual(effective.label, .onPlan)
        XCTAssertEqual(effective.taskID, "t1")
        XCTAssertEqual(effective.by, .person)

        let t = TBDFlowMatcher.totals(labels: store.cardLabels, cards: cards, tasks: plan)
        XCTAssertEqual(t.onPlanMinutes, 90)
        XCTAssertEqual(t.offPlanMinutes, 0)
        XCTAssertEqual(t.restMinutes, 20)
        XCTAssertEqual(TBDFlowMatcher.minutesPerTask(labels: store.cardLabels, cards: cards, tasks: plan), ["t1": 60, "t2": 30])
    }

    func testAPersonCanMoveACardToOffPlanAndRestAndTheMinutesFollow() throws {
        let labels: [String: TBDFlowCardLabel] = [
            "c1": TBDFlowCardLabel(cardID: "c1", label: .offPlan, by: .person, at: at("12:00:00")),
            "c5": TBDFlowCardLabel(cardID: "c5", label: .rest, by: .person, at: at("12:00:00")),
            "c4": TBDFlowCardLabel(cardID: "c4", label: .onPlan, taskID: "t2", by: .person, at: at("12:00:00")),
        ]
        let t = TBDFlowMatcher.totals(labels: labels, cards: cards, tasks: plan)
        XCTAssertEqual(t.onPlanMinutes, 20, "c4 was outside, the person put it on t2")
        XCTAssertEqual(t.offPlanMinutes, 60)
        XCTAssertEqual(t.restMinutes, 50)
        XCTAssertEqual(t.outsideMinutes, 0)
        XCTAssertEqual(TBDFlowMatcher.minutesPerTask(labels: labels, cards: cards, tasks: plan), ["t2": 20])
    }

    func testCardMinutes() {
        XCTAssertEqual(card("a", "09:00", "09:45", "x").minutes, 45)
        let backwards = TBDFlowCardEvidence(id: "b", start: at("10:00:00"), end: at("09:00:00"), title: "x", summary: "")
        XCTAssertEqual(backwards.minutes, 0)
    }
}
