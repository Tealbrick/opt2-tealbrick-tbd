import TBDFlowShared
import XCTest

@testable import DayflowFlowTools

/// dev.17 U3: the Flow plan tools of the companion MCP server. Every test uses its own temp Flow file; none reads or
/// writes the person's own list.
final class FlowPlanToolsTests: XCTestCase {
  private var folder: URL!
  private let bangkok = TimeZone(identifier: "Asia/Bangkok")!
  // 2026-10-20 10:00 in Bangkok (UTC+7).
  private let now = ISO8601DateFormatter().date(from: "2026-10-20T03:00:00Z")!
  private let today = "2026-10-20"

  override func setUp() {
    super.setUp()
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-flow-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)  // this test's own folder
    super.tearDown()
  }

  private var flowURL: URL { folder.appendingPathComponent("Companion/flow.json") }
  private func makeStore() -> TBDFlowStore { TBDFlowStore(url: flowURL) }

  private func call(_ name: String, _ arguments: [String: Any], store: TBDFlowStore? = nil) -> FlowToolOutcome {
    FlowPlanTools.call(name: name, arguments: arguments, store: store ?? makeStore(), now: now, timeZone: bangkok)
  }

  private func add(_ text: String, mode: String = "save", extra: [String: Any] = [:], store: TBDFlowStore? = nil) -> FlowToolOutcome {
    var arguments: [String: Any] = ["text": text, "mode": mode]
    for (k, v) in extra { arguments[k] = v }
    return call(FlowPlanTools.addTool, arguments, store: store)
  }

  private func tasks(_ outcome: FlowToolOutcome) -> [[String: Any]] { outcome.payload["tasks"] as? [[String: Any]] ?? [] }
  private var fileExists: Bool { FileManager.default.fileExists(atPath: flowURL.path) }

  // MARK: Definitions

  func testBothToolsAreListedWithTheRightHints() {
    let defs = FlowPlanTools.definitions()
    XCTAssertEqual(defs.compactMap { $0["name"] as? String }, ["flow_plan_today", "flow_plan_add"])
    let today = defs[0], addDef = defs[1]
    XCTAssertEqual((today["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    XCTAssertEqual((addDef["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, false)
    XCTAssertEqual((addDef["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, false)
    let schema = addDef["inputSchema"] as? [String: Any]
    XCTAssertEqual(schema?["required"] as? [String], ["text", "mode"])
    let mode = (schema?["properties"] as? [String: Any])?["mode"] as? [String: Any]
    XCTAssertEqual(mode?["enum"] as? [String], ["preview", "save"])
    XCTAssertTrue((addDef["description"] as? String ?? "").contains("agent-schedule-v1"))
    XCTAssertTrue(FlowPlanTools.handles("flow_plan_add"))
    XCTAssertFalse(FlowPlanTools.handles("get_status"))
  }

  // MARK: flow_plan_today

  func testTodayOfAnEmptyListIsEmptyAndWritesNothing() {
    let outcome = call("flow_plan_today", [:])
    XCTAssertFalse(outcome.isError)
    XCTAssertEqual(outcome.payload["day"] as? String, today)
    XCTAssertEqual(outcome.payload["count"] as? Int, 0)
    XCTAssertFalse(fileExists, "reading creates no file")
    let format = outcome.payload["format"] as? [String: Any]
    XCTAssertEqual(format?["name"] as? String, "agent-schedule-v1")
    XCTAssertEqual((format?["lines"] as? [String])?.count, 3, "one line per rule")
  }

  func testTodayListsOnlyTodaysTasksWithLocalTimes() throws {
    let store = makeStore()
    let start = ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z")!   // 09:00 Bangkok
    let end = ISO8601DateFormatter().date(from: "2026-10-20T03:30:00Z")!     // 10:30 Bangkok
    try store.addTask(title: "Write", subtasks: ["Scope"], day: today, startAt: start, endAt: end)
    let other = try store.addTask(title: "Tomorrow", day: "2026-10-21")
    let done = try store.addTask(title: "Done thing", day: today)
    try store.setStatus(id: done.id, .done)
    XCTAssertNotNil(other)

    let listed = tasks(call("flow_plan_today", [:], store: store))
    XCTAssertEqual(listed.map { $0["title"] as? String }, ["Done thing", "Write"], "no start first, as in the app")
    let write = listed[1]
    XCTAssertEqual(write["start"] as? String, "09:00")
    XCTAssertEqual(write["end"] as? String, "10:30")
    XCTAssertEqual(write["status"] as? String, "todo")
    XCTAssertEqual(write["done"] as? Bool, false)
    XCTAssertEqual(write["source"] as? String, "local")
    XCTAssertEqual(write["steps"] as? Int, 1)
    XCTAssertTrue(listed[0]["start"] is NSNull)
    XCTAssertEqual(listed[0]["done"] as? Bool, true)
  }

  func testTodayShowsATaskBoardTaskAsTaskBoard() throws {
    let store = makeStore()
    try store.addTask(title: "Linked", day: today, source: .taskBoard, taskBoardID: "KYB-1", taskBoardProject: "KYB")
    let listed = tasks(call("flow_plan_today", [:], store: store))
    XCTAssertEqual(listed.first?["source"] as? String, "taskBoard")
  }

  func testTodayLooksAtTheFileAgainEveryTime() throws {
    let reader = makeStore()
    XCTAssertEqual(call("flow_plan_today", [:], store: reader).payload["count"] as? Int, 0)
    try makeStore().addTask(title: "From the app", day: today)       // another writer (the app)
    XCTAssertEqual(call("flow_plan_today", [:], store: reader).payload["count"] as? Int, 1)
  }

  // MARK: flow_plan_add: input

  func testInputIsValidated() {
    let bad: [(String, [String: Any])] = [
      ("no mode", ["text": "TODO a"]),
      ("mode in capitals", ["text": "TODO a", "mode": "Preview"]),
      ("unknown mode", ["text": "TODO a", "mode": "commit"]),
      ("mode not a string", ["text": "TODO a", "mode": true]),
      ("no text", ["mode": "preview"]),
      ("empty text", ["text": "  \n ", "mode": "preview"]),
      ("text not a string", ["text": 5, "mode": "preview"]),
      ("bad day", ["text": "TODO a", "mode": "preview", "day": "2026-02-30"]),
      ("day in words", ["text": "TODO a", "mode": "preview", "day": "today"]),
      ("day not a string", ["text": "TODO a", "mode": "preview", "day": 20261020]),
      ("empty key", ["text": "TODO a", "mode": "save", "idempotency_key": ""]),
      ("key too long", ["text": "TODO a", "mode": "save", "idempotency_key": String(repeating: "k", count: 201)]),
      ("key not a string", ["text": "TODO a", "mode": "save", "idempotency_key": 7]),
      ("text too long", ["text": String(repeating: "TODO a\n", count: 1000), "mode": "preview"]),
    ]
    for (label, arguments) in bad {
      let outcome = call("flow_plan_add", arguments)
      XCTAssertTrue(outcome.isError, label)
      XCTAssertEqual(outcome.failureCategory, "invalid_input", label)
    }
    XCTAssertFalse(fileExists, "a refused call writes nothing")
  }

  func testNullOptionalFieldsAreIgnored() {
    let outcome = add("TODO a", mode: "preview", extra: ["day": NSNull(), "idempotency_key": NSNull()])
    XCTAssertFalse(outcome.isError)
    XCTAssertEqual(outcome.payload["day"] as? String, today)
  }

  // MARK: flow_plan_add: preview

  func testPreviewShowsTheDraftsAndWritesNothing() throws {
    let store = makeStore()
    let outcome = add("09:00-10:00 Write\n  - Scope\n  > Before lunch\nTODO Call", mode: "preview", store: store)
    XCTAssertFalse(outcome.isError)
    XCTAssertEqual(outcome.payload["saved"] as? Bool, false)
    XCTAssertEqual(outcome.payload["engine"] as? String, "strict")
    XCTAssertEqual(outcome.payload["count"] as? Int, 2)
    XCTAssertEqual(outcome.payload["requires_review"] as? Bool, false)
    let drafts = tasks(outcome)
    XCTAssertEqual(drafts[0]["title"] as? String, "Write")
    XCTAssertEqual(drafts[0]["start"] as? String, "09:00")
    XCTAssertEqual(drafts[0]["end"] as? String, "10:00")
    XCTAssertEqual(drafts[0]["minutes"] as? Int, 60)
    XCTAssertEqual(drafts[0]["steps"] as? [String], ["Scope"])
    XCTAssertEqual(drafts[0]["notes"] as? String, "Before lunch")
    XCTAssertEqual(drafts[1]["source"] as? String, "local")
    XCTAssertFalse(fileExists, "preview writes no file")
    XCTAssertTrue(store.state.tasks.isEmpty)
    XCTAssertNil(outcome.payload["task_ids"])
  }

  func testPreviewOfAnOtherFormatIsReadLooselyWithWarnings() {
    let outcome = add("- 9:00 Write the offer\n- Call the bank", mode: "preview")
    XCTAssertFalse(outcome.isError)
    XCTAssertEqual(outcome.payload["engine"] as? String, "lenient")
    XCTAssertEqual(outcome.payload["requires_review"] as? Bool, true)
    XCTAssertFalse((outcome.payload["warnings"] as? [String] ?? []).isEmpty)
    XCTAssertNotNil(outcome.payload["strict_error"] as? String)
    XCTAssertEqual(tasks(outcome).map { $0["title"] as? String }, ["Write the offer", "Call the bank"])
    XCTAssertFalse(fileExists)
  }

  func testAPreviewThenASaveGiveTheSameLines() {
    let text = "08:30-09:00 Plan\nTODO Mail"
    let preview = add(text, mode: "preview")
    let saved = add(text, mode: "save")
    XCTAssertEqual(tasks(preview).map { $0["title"] as? String }, tasks(saved).map { $0["title"] as? String })
    XCTAssertEqual(tasks(preview).map { $0["start"] as? String }, tasks(saved).map { $0["start"] as? String })
  }

  // MARK: flow_plan_add: save

  func testSaveWritesOnceAndTheLinesAreLocal() throws {
    let store = makeStore()
    let outcome = add("09:00-10:00 Write\nTODO Call", mode: "save", extra: ["idempotency_key": "plan-1"], store: store)
    XCTAssertFalse(outcome.isError)
    XCTAssertEqual(outcome.payload["saved"] as? Bool, true)
    XCTAssertEqual(outcome.payload["replayed"] as? Bool, false)
    XCTAssertEqual((outcome.payload["task_ids"] as? [String])?.count, 2)
    XCTAssertTrue(fileExists)
    let saved = makeStore().state.tasks
    XCTAssertEqual(saved.map(\.title), ["Write", "Call"])
    XCTAssertEqual(saved.map(\.day), [today, today])
    XCTAssertEqual(saved.map(\.source), [.local, .local])
    XCTAssertEqual(saved.map(\.taskBoardID), [nil, nil])
    XCTAssertEqual(saved[0].status, .todo)
    // 09:00 in Bangkok is 02:00 UTC.
    XCTAssertEqual(saved[0].startAt, ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z"))
    // And the app's own store reads them back (the same file).
    XCTAssertEqual(tasks(call("flow_plan_today", [:])).count, 2)
  }

  func testTheSameKeyAndTextAddsNothingTwice() {
    let first = add("TODO a\nTODO b", extra: ["idempotency_key": "k"])
    let again = add("TODO a\nTODO b", extra: ["idempotency_key": "k"])
    XCTAssertEqual(again.payload["replayed"] as? Bool, true)
    XCTAssertEqual(again.payload["saved"] as? Bool, false)
    XCTAssertEqual(again.payload["task_ids"] as? [String], first.payload["task_ids"] as? [String], "the same ids")
    XCTAssertEqual(makeStore().state.tasks.count, 2)
  }

  func testTheSameKeyWithOtherTextIsAnErrorAndAddsNothing() {
    _ = add("TODO a", extra: ["idempotency_key": "k"])
    let other = add("TODO b", extra: ["idempotency_key": "k"])
    XCTAssertTrue(other.isError)
    XCTAssertEqual(other.failureCategory, "conflict")
    XCTAssertEqual(makeStore().state.tasks.map(\.title), ["a"])
  }

  func testTheSameKeyForAnotherDayIsAConflictToo() {
    _ = add("TODO a", extra: ["idempotency_key": "k"])
    let other = add("TODO a", extra: ["idempotency_key": "k", "day": "2026-10-21"])
    XCTAssertTrue(other.isError)
    XCTAssertEqual(other.failureCategory, "conflict")
  }

  func testWithoutAKeyTheSameTextAddsOnceAndOtherTextAddsAgain() {
    let first = add("TODO a")
    let again = add("TODO a")
    XCTAssertEqual(again.payload["replayed"] as? Bool, true)
    XCTAssertEqual(first.payload["idempotency_key"] as? String, again.payload["idempotency_key"] as? String)
    XCTAssertEqual(makeStore().state.tasks.count, 1)
    _ = add("TODO b")
    XCTAssertEqual(makeStore().state.tasks.map(\.title), ["a", "b"], "a new plan appends; it never replaces")
  }

  func testTheDayDefaultsToTodayAndAnExplicitDayIsUsed() {
    XCTAssertEqual(add("TODO a", mode: "preview").payload["day"] as? String, today)
    let tomorrow = add("TODO a", extra: ["day": "2026-10-21"])
    XCTAssertEqual(tomorrow.payload["day"] as? String, "2026-10-21")
    XCTAssertEqual(makeStore().state.tasks.first?.day, "2026-10-21")
    XCTAssertEqual(tasks(call("flow_plan_today", [:])).count, 0, "tomorrow's line is not today's plan")
  }

  func testTheDayDefaultFollowsTheTimeZoneNotUTC() {
    // 2026-10-19 20:00 UTC is already 20 October in Bangkok, still 19 October in New York.
    let late = ISO8601DateFormatter().date(from: "2026-10-19T20:00:00Z")!
    let ny = TimeZone(identifier: "America/New_York")!
    XCTAssertEqual(FlowPlanTools.todayString(now: late, timeZone: bangkok), "2026-10-20")
    XCTAssertEqual(FlowPlanTools.todayString(now: late, timeZone: ny), "2026-10-19")
  }

  func testAPlanWithTaskBoardTasksInTheListStillAddsLocalLines() throws {
    let store = makeStore()
    try store.addTask(title: "Linked", day: today, source: .taskBoard, taskBoardID: "KYB-1", taskBoardProject: "KYB")
    let outcome = add("Linked\nTODO Linked", mode: "save", store: store)   // not strict: a title equal to an open issue
    XCTAssertFalse(outcome.isError)
    let added = makeStore().state.tasks.filter { $0.id != store.state.tasks.first?.id }
    XCTAssertFalse(added.isEmpty)
    XCTAssertTrue(added.allSatisfy { $0.source == .local && $0.taskBoardID == nil && $0.taskBoardProject == nil })
    XCTAssertEqual(makeStore().state.tasks.filter { $0.source == .taskBoard }.count, 1, "no Task Board task was made")
  }

  // MARK: flow_plan_add: limits

  func testThirtyLinesAreFineAndThirtyOneAreRefused() {
    let thirty = (1...30).map { "TODO task \($0)" }.joined(separator: "\n")
    let ok = add(thirty, mode: "save")
    XCTAssertFalse(ok.isError)
    XCTAssertEqual(ok.payload["count"] as? Int, 30)
    XCTAssertEqual(makeStore().state.tasks.count, 30)

    let thirtyOne = (1...31).map { "TODO other \($0)" }.joined(separator: "\n")
    for mode in ["preview", "save"] {
      let refused = add(thirtyOne, mode: mode)
      XCTAssertTrue(refused.isError, mode)
      XCTAssertTrue((refused.payload["error"] as? String ?? "").contains("at most 30"), mode)
    }
    XCTAssertEqual(makeStore().state.tasks.count, 30, "a refused plan adds nothing")
  }

  func testThirtyOneLooseLinesAreRefusedToo() {
    // Not in the strict format, so the loose reader would take up to 200; this tool keeps the 30 limit.
    let loose = (1...31).map { "- loose task \($0)" }.joined(separator: "\n")
    let refused = add(loose, mode: "preview")
    XCTAssertTrue(refused.isError)
    XCTAssertTrue((refused.payload["error"] as? String ?? "").contains("at most 30"))
    XCTAssertFalse(fileExists)
  }

  func testLinesWithStepsCountOnlyTheirTasks() {
    let text = (1...30).map { "TODO t\($0)\n  - step a\n  - step b" }.joined(separator: "\n")
    XCTAssertFalse(add(text, mode: "preview").isError)
  }

  // MARK: Two writers

  func testTheToolAndTheAppKeepEachOthersChanges() throws {
    let app = makeStore()
    let toolStore = makeStore()
    try app.addTask(title: "App 1", day: today)
    XCTAssertFalse(add("TODO Agent 1", store: toolStore).isError)
    try app.addTask(title: "App 2", day: today)
    XCTAssertFalse(add("TODO Agent 2", store: toolStore).isError)
    XCTAssertEqual(makeStore().state.tasks.map(\.title), ["App 1", "Agent 1", "App 2", "Agent 2"])
  }

  func testUnknownToolIsAnError() {
    XCTAssertTrue(call("flow_plan_delete", [:]).isError)
  }

  // MARK: dev.17 review

  private var folderNames: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: flowURL.deletingLastPathComponent().path)) ?? []).sorted()
  }

  /// A store that only reads until the first change: what the MCP server uses.
  private func makeReadOnlyStore() -> TBDFlowStore { TBDFlowStore(url: flowURL, quarantine: .onFirstWrite) }

  // S5: a plan replays only while one of its tasks exists.
  func testASavedPlanIsNewAgainWhenThePersonRemovedAllItsLines() throws {
    let first = add("TODO One\nTODO Two", extra: ["idempotency_key": "plan-1"])
    XCTAssertEqual(first.payload["saved"] as? Bool, true)
    let ids = first.payload["task_ids"] as? [String] ?? []
    XCTAssertEqual(ids.count, 2)
    let again = add("TODO One\nTODO Two", extra: ["idempotency_key": "plan-1"])
    XCTAssertEqual(again.payload["replayed"] as? Bool, true, "the lines are still there: a replay")
    let store = makeStore()
    try store.deleteTask(id: ids[0])
    XCTAssertEqual(add("TODO One\nTODO Two", extra: ["idempotency_key": "plan-1"]).payload["replayed"] as? Bool, true, "one line is left: still a replay")
    XCTAssertEqual(makeStore().state.tasks.count, 1)
    try makeStore().deleteTask(id: ids[1])
    XCTAssertTrue(makeStore().state.tasks.isEmpty)
    let fresh = add("TODO One\nTODO Two", extra: ["idempotency_key": "plan-1"])
    XCTAssertEqual(fresh.payload["saved"] as? Bool, true, "all lines gone: the same plan is saved again")
    XCTAssertEqual(fresh.payload["replayed"] as? Bool, false)
    let newIDs = fresh.payload["task_ids"] as? [String] ?? []
    XCTAssertEqual(newIDs.count, 2)
    XCTAssertTrue(Set(newIDs).isDisjoint(with: ids), "new ids")
    XCTAssertEqual(makeStore().state.tasks.count, 2)
  }

  // Nits: the read tools do not write anything, not even a lock file or a moved file.
  func testTodayAndPreviewMakeNoLockFileAndMoveNoUnreadableFile() throws {
    try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: flowURL)
    let store = makeReadOnlyStore()
    let today = call("flow_plan_today", [:], store: store)
    XCTAssertFalse(today.isError)
    XCTAssertEqual(today.payload["count"] as? Int, 0)
    XCTAssertTrue((today.payload["warning"] as? String ?? "").contains("could not read the plan file"), "the person's agent is told")
    XCTAssertFalse((today.payload["warning"] as? String ?? "").contains("nothing can be added"), "a save would keep a copy and go on")
    XCTAssertFalse(add("09:00-10:00 Write", mode: "preview", store: store).isError)
    XCTAssertEqual(folderNames, ["flow.json"], "no flow.json.lock, no .corrupt copy")
    XCTAssertEqual(try String(contentsOf: flowURL, encoding: .utf8), "not json")
    // A save keeps a copy of the unreadable file (never deleted) and then saves.
    let saved = add("TODO Fresh", store: store)
    XCTAssertEqual(saved.payload["saved"] as? Bool, true)
    XCTAssertEqual(folderNames.filter { $0.contains(".corrupt-") }.count, 1)
    XCTAssertEqual(makeStore().state.tasks.map(\.title), ["Fresh"])
  }

  func testTodayAndPreviewOfAMissingListMakeNothingAtAll() {
    let store = makeReadOnlyStore()
    XCTAssertFalse(call("flow_plan_today", [:], store: store).isError)
    XCTAssertFalse(add("TODO x", mode: "preview", store: store).isError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: flowURL.deletingLastPathComponent().path), "not even the folder")
  }

  // L70: the sentence is surfaced by the MCP tool.
  private func realDataStore(_ context: TBDRealDataGuard.Context) -> (store: TBDFlowStore, url: URL) {
    let home = folder.appendingPathComponent("RealHome", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let url = home.appendingPathComponent("Library/Application Support/com.tealbrick.desktop/Companion/flow.json")
    var ctx = context
    ctx.realHome = home.path
    return (TBDFlowStore(url: url, quarantine: .onFirstWrite, realDataGuard: ctx), url)
  }

  func testASaveIntoTheRealDataFromATestOrToolRunIsRefusedAndTheToolShowsTheSentence() {
    let sentence = "TBD refused to write to your real TBD data from a test or tool run. Set CFFIXED_USER_HOME to a test folder."
    let conditions: [(String, TBDRealDataGuard.Context)] = [
      ("TBD_TEST=1", .init(realHome: "", environment: ["TBD_TEST": "1"], executablePath: "/Applications/TBD.app/Contents/Helpers/dayflow", underXCTest: false)),
      ("XCTest", .init(realHome: "", environment: [:], executablePath: "/Applications/TBD.app/Contents/Helpers/dayflow", underXCTest: true)),
      ("a tool outside the bundle", .init(realHome: "", environment: [:], executablePath: "/Users/x/work/.build/debug/dayflow", underXCTest: false)),
    ]
    for (label, context) in conditions {
      let (store, url) = realDataStore(context)
      let saved = call(FlowPlanTools.addTool, ["text": "TODO Nope", "mode": "save"], store: store)
      XCTAssertTrue(saved.isError, label)
      XCTAssertEqual(saved.payload["error"] as? String, sentence, "\(label): the sentence, as it is")
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "\(label): nothing was made")
      // preview and today are reads: they still work
      XCTAssertFalse(call(FlowPlanTools.addTool, ["text": "TODO Nope", "mode": "preview"], store: store).isError, label)
      XCTAssertFalse(call(FlowPlanTools.todayTool, [:], store: store).isError, label)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), label)
    }
  }

  func testTheAppsAgentCLIFromTheBundleMayStillSave() throws {
    let (store, url) = realDataStore(.init(realHome: "", environment: ["TBD_APP_SUPPORT_DIR": "/x"], executablePath: "/Applications/TBD.app/Contents/Helpers/dayflow", underXCTest: false))
    let saved = call(FlowPlanTools.addTool, ["text": "TODO Fine", "mode": "save"], store: store)
    XCTAssertFalse(saved.isError, "\(saved.payload)")
    XCTAssertEqual(saved.payload["saved"] as? Bool, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  // S8: the CLI takes the data folder from TBD_APP_SUPPORT_DIR (the mapping lives in TBDIdentity, shared with the app).
  func testTheCLIUsesTheEnvironmentFolderForItsFilesInsteadOfItsCompiledDefault() throws {
    let dev = "/Users/x/Library/Application Support/com.tealbrick.desktop-dev"
    let live = "/Users/x/Library/Application Support/com.tealbrick.desktop"
    XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": dev]).path, dev)
    XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": live]).path, live)
    XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": dev]).appendingPathComponent("Companion/flow.json").path, dev + "/Companion/flow.json")
    XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": "relative"]).lastPathComponent, TBDIdentity.dataFolder, "a relative value is ignored")
    XCTAssertEqual(TBDIdentity.defaultsDomain(forDataDirectory: URL(fileURLWithPath: dev)), "com.tealbrick.desktop.dev")
    // The CLI's own files (socket, database, telemetry queue, settings domain) all come from that one mapping.
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/dayflow")
    for (file, needle) in [("Bridge.swift", "tbdDataDirectory().appendingPathComponent(\"Companion/agent.sock\")"), ("Database.swift", "tbdDataDirectory().appendingPathComponent(\"Companion/chunks.sqlite\")"),
                           ("AgentUsageTelemetry.swift", "tbdDataDirectory().appendingPathComponent(\"Companion\""), ("Categories.swift", "tbdDefaultsDomain()"), ("Bridge.swift", "tbdDefaultsDomain()")] {
      let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
      XCTAssertTrue(text.contains(needle), "\(file) must use the environment folder: \(needle)")
    }
    for file in ["Bridge.swift", "Database.swift", "AgentUsageTelemetry.swift", "Categories.swift"] {
      let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
      XCTAssertFalse(text.contains("tbdAppDataFolder"), "\(file) must not build the folder from the compiled default")
    }
  }
}
