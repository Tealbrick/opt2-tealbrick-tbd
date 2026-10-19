import XCTest
import TBDModels

@testable import TBD

/// A clock the Flow tests move by hand (Flow never reads the real date in these tests).
final class FlowTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ iso: String) { value = TBDFlowISO.date(iso)! }
  var now: Date {
    get { lock.lock(); defer { lock.unlock() }; return value }
    set { lock.lock(); defer { lock.unlock() }; value = newValue }
  }
  func set(_ iso: String) { now = TBDFlowISO.date(iso)! }
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class FlowTestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "id-\(n)" }
}

/// What the mirror told the observer.
@MainActor
final class RecordingObserver: FlowObserving {
  var status = "Observer: test"
  private(set) var events: [String] = []
  private(set) var notes: [(text: String, refocused: Bool)] = []

  func start(with snapshot: FlowNativeSnapshot, rebrief: Bool) {
    events.append(rebrief ? "start(rebrief)" : "start")
  }
  func pause() { events.append("pause") }
  func resume() { events.append("resume") }
  func stop() { events.append("stop") }
  func goalsChanged(to snapshot: FlowNativeSnapshot) { events.append("goals") }
  func noteUserEvent(_ note: String, markRefocused: Bool) { notes.append((note, markRefocused)) }
}

/// A test case with its own temp folder, its own UserDefaults suite and a fixed clock.
@MainActor
class FlowTestCase: XCTestCase {
  var folder: URL!
  var defaults: UserDefaults!
  private var suiteName = ""
  let clock = FlowTestClock("2026-10-05T09:30:00Z")
  let ids = FlowTestIDs()
  var observer: RecordingObserver!
  var timeline: FlowSessionTimeline!
  var settings: FlowAgentSettings!
  var mirror: FlowSessionMirror!

  static let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  override func setUp() async throws {
    try await super.setUp()
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tbd-flow-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    suiteName = "Dayflow.FlowTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    observer = RecordingObserver()
    timeline = FlowSessionTimeline(fileURL: folder.appendingPathComponent("flow-session-timeline.json"))
    settings = FlowAgentSettings(defaults: defaults)
    mirror = makeMirror()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: folder)  // this test's own folder
    try await super.tearDown()
  }

  func makeMirror() -> FlowSessionMirror {
    let clock = self.clock
    return FlowSessionMirror(
      defaults: defaults, settings: settings, timeline: timeline, observer: observer, now: { clock.now })
  }

  func makeStore() -> TBDFlowStore {
    let clock = self.clock, ids = self.ids
    return TBDFlowStore(
      url: folder.appendingPathComponent("Companion/flow.json"), clock: { clock.now }, makeID: { ids.next() })
  }

  func makePlanner(
    store: TBDFlowStore? = nil, sound: @escaping () -> Void = {}, taskBoard: FlowTaskBoardSource? = nil,
    cards: [TimelineCard] = []
  ) -> FlowPlanner {
    let clock = self.clock
    // The source is a fake that never asks the helper (no Keychain, no network); the card source is empty.
    return FlowPlanner(
      store: store ?? makeStore(), mirror: mirror, defaults: defaults, calendar: Self.utc, now: { clock.now }, playSound: sound,
      taskBoard: taskBoard ?? FlowTaskBoardSource(client: FakeTaskBoardClient()), cardsForDay: { _ in cards })
  }

  func at(_ time: String) -> Date { TBDFlowISO.date("2026-10-05T\(time)Z")! }

  func snapshot(_ phase: FlowPhase, endsAt: String = "10:30:00Z", breakEndsAt: String? = nil, style: FlowAlertStyle = .friendly)
    -> FlowNativeSnapshot
  {
    var s = FlowNativeSnapshot()
    s.phase = phase
    s.alertStyle = style
    s.sessionStartedAt = Int(clock.now.timeIntervalSince1970)
    s.sessionEndsAt = Int(TBDFlowISO.date("2026-10-05T\(endsAt)")!.timeIntervalSince1970)
    s.breakEndsAt = breakEndsAt.map { Int(TBDFlowISO.date("2026-10-05T\($0)")!.timeIntervalSince1970) }
    s.goals = [TBDFlowGoal(id: "t1", title: "Write report")]
    return s
  }
}
