import XCTest
@testable import TBDModels

/// A clock the tests move by hand (Flow never reads the real date in tests).
final class FlowClockBox: @unchecked Sendable {
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

final class FlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "id-\(n)" }
}

enum FlowT {
    static func date(_ iso: String) -> Date { TBDFlowISO.date(iso)! }
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    static func iso(_ d: Date?) -> String? { d.map(TBDFlowISO.string) }
}

/// A test case with its own temp folder (removed in tearDown) and a store factory with fixed clock and ids.
class TBDFlowTestCase: XCTestCase {
    var folder: URL!
    let clock = FlowClockBox("2026-10-05T07:00:00Z")
    let ids = FlowCounter()

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder) // this test's own folder
        super.tearDown()
    }

    var flowURL: URL { folder.appendingPathComponent("Companion/flow.json") }

    func makeStore(url: URL? = nil) -> TBDFlowStore {
        let clock = self.clock, ids = self.ids
        return TBDFlowStore(url: url ?? flowURL, clock: { clock.now }, makeID: { ids.next() })
    }
}
