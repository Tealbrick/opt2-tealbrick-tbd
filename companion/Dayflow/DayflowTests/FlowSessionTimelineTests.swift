import XCTest

@testable import TBD

/// The session timeline file (review 17): mode 0600 and a trim at the end of a session.
@MainActor
final class FlowSessionTimelineTests: FlowTestCase {
  private var url: URL { folder.appendingPathComponent("flow-session-timeline.json") }

  private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
  }

  func testTheFileIsWrittenWithMode0600FromTheFirstByte() throws {
    let timeline = FlowSessionTimeline(fileURL: url)
    timeline.begin(sessionStartedAt: clock.now)
    XCTAssertEqual(mode(url), 0o600)
    timeline.observe(offTask: true, front: .none, reason: "YouTube", at: clock.now)
    timeline.beginBreak(at: clock.now)
    timeline.finish(at: clock.now.addingTimeInterval(60))
    XCTAssertEqual(mode(url), 0o600, "every rewrite keeps the mode")
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
    XCTAssertEqual(left, [], "no temp file is left")
    // A folder made by the timeline is private too.
    let nested = folder.appendingPathComponent("a/b/flow-session-timeline.json")
    let other = FlowSessionTimeline(fileURL: nested)
    other.begin(sessionStartedAt: clock.now)
    XCTAssertEqual(mode(nested), 0o600)
  }

  func testTheEndOfASessionKeepsThisSessionsChecksAndDropsOlderOnes() throws {
    let timeline = FlowSessionTimeline(fileURL: url)
    let start = clock.now
    timeline.begin(sessionStartedAt: start)
    timeline.observe(offTask: true, front: .none, reason: "old session", at: start.addingTimeInterval(-3 * 3600))
    timeline.observe(offTask: false, front: .none, reason: "Xcode", at: start.addingTimeInterval(120))
    timeline.observe(offTask: true, front: .none, reason: "YouTube", at: start.addingTimeInterval(240))
    timeline.finish(at: start.addingTimeInterval(600))
    XCTAssertEqual(timeline.observations.map(\.reason), ["Xcode", "YouTube"])
    // And it is what the file holds.
    let reloaded = FlowSessionTimeline(fileURL: url)
    reloaded.begin(sessionStartedAt: start)
    XCTAssertEqual(reloaded.observations.map(\.reason), ["Xcode", "YouTube"])
  }

  func testReasonsFromBeforeTodayAreClearedButTheChecksStay() throws {
    let timeline = FlowSessionTimeline(fileURL: url)
    let startOfToday = Calendar.current.startOfDay(for: clock.now)
    let start = startOfToday.addingTimeInterval(-3600)  // a session that began an hour before midnight
    timeline.begin(sessionStartedAt: start)
    timeline.observe(offTask: true, front: .none, reason: "late last night", at: start.addingTimeInterval(1800))
    timeline.observe(offTask: false, front: .none, reason: "this morning", at: startOfToday.addingTimeInterval(600))
    timeline.finish(at: startOfToday.addingTimeInterval(1200))
    XCTAssertEqual(timeline.observations.count, 2)
    XCTAssertNil(timeline.observations[0].reason)
    XCTAssertEqual(timeline.observations[1].reason, "this morning")
  }

  func testTheEntriesSurviveTheTrim() throws {
    let timeline = FlowSessionTimeline(fileURL: url)
    let start = clock.now
    timeline.begin(sessionStartedAt: start)
    timeline.observe(offTask: false, front: .none, reason: "Xcode", at: start.addingTimeInterval(60))
    timeline.apply(
      modelItems: [FlowSessionTimeline.ModelItem(start: FlowSessionTimeline.clock(start), end: FlowSessionTimeline.clock(start.addingTimeInterval(600)), title: "Write the report", kind: "focused")],
      at: start.addingTimeInterval(600))
    let before = timeline.entries
    XCTAssertFalse(before.isEmpty)
    timeline.finish(at: start.addingTimeInterval(660))
    XCTAssertEqual(timeline.entries.map(\.title), before.map(\.title))
  }
}
