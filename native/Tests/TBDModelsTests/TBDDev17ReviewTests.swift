import Darwin
import XCTest
@testable import TBDModels

/// dev.17 review fixes: no lock on a quiet tick, a read-only open, the plan replay rule, the 500-record cap, the data folder
/// from `TBD_APP_SUPPORT_DIR`, and the L70 guard against writing the person's real TBD data from a test or a tool run.
/// Every path here is in the test's own temp folder; the "real home" of the guard tests is a temp folder too.
final class TBDDev17ReviewTests: TBDFlowTestCase {
    private let day = "2026-10-20"
    private let zone = FlowT.zone("UTC")

    private func listing(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []).sorted()
    }

    // MARK: Nits: a quiet tick takes no lock

    func testAQuietTickTakesNoFileLockAndWritesNothing() throws {
        let store = makeStore()
        try store.addTask(title: "later", day: day, startAt: FlowT.date("2026-10-05T12:00:00Z"))   // not due at 07:00
        let outsider = open(flowURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(outsider, LOCK_EX), 0)
        defer { flock(outsider, LOCK_UN); close(outsider) }
        let saved = TBDFlowStore.lockTimeout
        TBDFlowStore.lockTimeout = 0.2
        defer { TBDFlowStore.lockTimeout = saved }
        let before = try FileManager.default.attributesOfItem(atPath: flowURL.path)[.modificationDate] as? Date
        for _ in 0..<5 {
            let result = try store.tick()          // would throw "another part of TBD is using it" if it took the lock
            XCTAssertFalse(result.changed)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: flowURL.path)[.modificationDate] as? Date, before, "nothing was written")
        // Negative control: a tick that has something to do needs the lock, and it is the lock that the outsider holds.
        clock.set("2026-10-05T12:00:30Z")
        XCTAssertThrowsError(try store.tick()) {
            guard case .storage = $0 as? TBDFlowError else { return XCTFail("expected a storage error, got \($0)") }
        }
    }

    func testAQuietTickStillSeesTheOtherWritersLines() throws {
        let app = makeStore()
        let cli = makeStore()
        try cli.addTask(title: "from the agent", day: day, startAt: FlowT.date("2026-10-05T07:00:00Z"))
        let result = try app.tick()    // the app never saw the line; the tick reloads, finds a reminder due, and saves it
        XCTAssertEqual(result.newReminders.count, 1)
        XCTAssertEqual(makeStore().state.tasks.map(\.title), ["from the agent"])
    }

    // MARK: Nits: a read-only open

    func testAReadOnlyOpenMakesNoLockFileAndMovesNoUnreadableFile() throws {
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: flowURL)
        let reader = TBDFlowStore(url: flowURL, clock: { self.clock.now }, makeID: { self.ids.next() }, quarantine: .onFirstWrite)
        XCTAssertTrue(reader.state.tasks.isEmpty)
        XCTAssertTrue(reader.isUnreadable)
        XCTAssertFalse(reader.isLockedByUnreadableFile, "it can still be moved aside by a change")
        XCTAssertNil(reader.corruptBackupURL)
        XCTAssertFalse(reader.reloadIfChanged())
        XCTAssertEqual(listing(flowURL), ["flow.json"], "no lock file, no .corrupt copy")
        XCTAssertEqual(try String(contentsOf: flowURL, encoding: .utf8), "not json")
        // The first change moves it aside (kept, never deleted) and saves.
        try reader.addTask(title: "fresh", day: day)
        XCTAssertFalse(reader.isUnreadable)
        XCTAssertNotNil(reader.corruptBackupURL)
        let names = listing(flowURL)
        XCTAssertTrue(names.contains("flow.json") && names.contains("flow.json.lock"), "\(names)")
        XCTAssertEqual(names.filter { $0.contains(".corrupt-") }.count, 1)
        XCTAssertEqual(makeStore().state.tasks.map(\.title), ["fresh"])
    }

    func testAReadOnlyOpenOfAMissingFolderMakesNothingAndSeesLaterWrites() throws {
        let reader = TBDFlowStore(url: flowURL, quarantine: .onFirstWrite)
        XCTAssertTrue(reader.state.tasks.isEmpty)
        XCTAssertFalse(reader.reloadIfChanged())
        XCTAssertFalse(FileManager.default.fileExists(atPath: flowURL.deletingLastPathComponent().path), "not even the folder")
        try makeStore().addTask(title: "app", day: day)
        XCTAssertTrue(reader.reloadIfChanged())
        XCTAssertEqual(reader.state.tasks.map(\.title), ["app"])
    }

    // MARK: S5: a plan replays only while its tasks exist; the records are capped

    func testACommitReplaysOnlyWhileAtLeastOneTaskOfTheRecordExists() throws {
        let store = makeStore()
        let text = "09:00-10:00 Plan\nTODO Call"
        let drafts = try TBDFlowPlanParser.parseSchedule(text: text, day: day, timeZone: zone)
        let hash = TBDFlowPlanParser.payloadHash(format: TBDFlowPlanParser.format, text: text, day: day, timeZone: zone)
        let first = try store.commit(drafts: drafts, idempotencyKey: "k", payloadHash: hash)
        XCTAssertFalse(first.replayed)
        // The person removes one line: the replay returns the one that is left, and adds nothing.
        try store.deleteTask(id: first.taskIDs[0])
        let partial = try store.commit(drafts: drafts, idempotencyKey: "k", payloadHash: hash)
        XCTAssertTrue(partial.replayed)
        XCTAssertEqual(partial.tasks.map(\.id), [first.taskIDs[1]])
        XCTAssertEqual(store.state.tasks.count, 1)
        // The same key with other text is still a conflict while a task of the record exists.
        XCTAssertThrowsError(try store.commit(drafts: drafts, idempotencyKey: "k", payloadHash: "other")) {
            XCTAssertEqual($0 as? TBDFlowError, .idempotencyConflict)
        }
        // The person removes the rest: the record is stale. The same plan is new again (new ids), the record is replaced.
        try store.deleteTask(id: first.taskIDs[1])
        XCTAssertTrue(store.state.tasks.isEmpty)
        let again = try store.commit(drafts: drafts, idempotencyKey: "k", payloadHash: hash)
        XCTAssertFalse(again.replayed)
        XCTAssertEqual(again.taskIDs.count, 2)
        XCTAssertTrue(Set(again.taskIDs).isDisjoint(with: first.taskIDs), "new ids")
        XCTAssertEqual(store.state.tasks.count, 2)
        XCTAssertEqual(store.state.imports["k"]?.taskIDs, again.taskIDs, "the record was replaced")
        // And a stale record never blocks another text under the same key.
        for id in again.taskIDs { try store.deleteTask(id: id) }
        let other = try store.commit(drafts: [TBDFlowTaskDraft(title: "other", day: day)], idempotencyKey: "k", payloadHash: "other-hash")
        XCTAssertFalse(other.replayed)
        XCTAssertEqual(store.state.imports["k"]?.sha256, "other-hash")
    }

    func testOnlyThe500NewestImportRecordsStay() throws {
        let store = makeStore()
        let draft = TBDFlowTaskDraft(title: "x", day: day)
        let total = TBDFlowStore.maxImportRecords + 5
        for i in 0..<total {
            clock.advance(1)
            try store.commit(drafts: [draft], idempotencyKey: "key-\(i)", payloadHash: "h\(i)")
        }
        let imports = makeStore().state.imports
        XCTAssertEqual(imports.count, TBDFlowStore.maxImportRecords)
        for i in 0..<5 { XCTAssertNil(imports["key-\(i)"], "the oldest go first: key-\(i)") }
        for i in 5..<total { XCTAssertNotNil(imports["key-\(i)"], "key-\(i)") }
        XCTAssertNotNil(imports["key-\(total - 1)"], "the newest record is always kept")
        XCTAssertEqual(makeStore().state.tasks.count, total, "tasks are never dropped with their records")
        // A dropped key can be used again: it is new.
        let reuse = try store.commit(drafts: [draft], idempotencyKey: "key-0", payloadHash: "h0")
        XCTAssertFalse(reuse.replayed)
    }

    // MARK: S8: TBD_APP_SUPPORT_DIR

    func testTheDataFolderFollowsTBD_APP_SUPPORT_DIRInTheCLIAndTheApp() {
        let dev = "/Users/x/Library/Application Support/com.tealbrick.desktop-dev"
        XCTAssertEqual(TBDIdentity.appSupportEnvironmentKey, "TBD_APP_SUPPORT_DIR")
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": dev]).path, dev)
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": dev + "/"]).path, dev, "a closing slash does not matter")
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": "/Users/x/a/../Library/Application Support/com.tealbrick.desktop-dev"]).path, "/Users/x/Library/Application Support/com.tealbrick.desktop-dev")
        // not an absolute path, or empty: the compiled default
        let fallback = TBDIdentity.dataDirectory(environment: [:]).path
        XCTAssertTrue(fallback.hasSuffix("/Library/Application Support/" + TBDIdentity.dataFolder), fallback)
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": "relative/dir"]).path, fallback)
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": ""]).path, fallback)
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": "~/x"]).path, fallback, "no tilde expansion: a path must be absolute")
        // The Companion files are under it.
        XCTAssertEqual(TBDIdentity.dataDirectory(environment: ["TBD_APP_SUPPORT_DIR": dev]).appendingPathComponent("Companion/flow.json").path, dev + "/Companion/flow.json")
        // The dev folders belong to the dev bundle id (the CLI reads its settings from there).
        XCTAssertEqual(TBDIdentity.defaultsDomain(forDataDirectory: URL(fileURLWithPath: dev)), "com.tealbrick.desktop.dev")
        XCTAssertEqual(TBDIdentity.defaultsDomain(forDataDirectory: URL(fileURLWithPath: dev + "-x1")), "com.tealbrick.desktop.dev")
        XCTAssertEqual(TBDIdentity.defaultsDomain(forDataDirectory: URL(fileURLWithPath: "/Users/x/Library/Application Support/com.tealbrick.desktop")), "com.tealbrick.desktop")
    }

    // MARK: L70: the guard against writing the real TBD data

    private let sentence = "TBD refused to write to your real TBD data from a test or tool run. Set CFFIXED_USER_HOME to a test folder."

    /// A pretend real home inside the test folder, and a Flow file in its TBD data folder.
    private func realHome(_ folderName: String = "com.tealbrick.desktop") -> (home: String, url: URL) {
        let home = folder.appendingPathComponent("RealHome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("Library/Application Support/\(folderName)/Companion/flow.json")
        return (home.path, url)
    }
    private func context(_ home: String, env: [String: String] = [:], executable: String? = "/Users/x/work/dayflow-cli/.build/debug/dayflow", xctest: Bool = false) -> TBDRealDataGuard.Context {
        TBDRealDataGuard.Context(realHome: home, environment: env, executablePath: executable, underXCTest: xctest)
    }
    private func guarded(_ url: URL, _ context: TBDRealDataGuard.Context, quarantine: TBDFlowStore.Quarantine = .onFirstWrite) -> TBDFlowStore {
        TBDFlowStore(url: url, clock: { self.clock.now }, makeID: { self.ids.next() }, quarantine: quarantine, realDataGuard: context)
    }

    func testTheSentenceIsExactAndTheErrorShowsIt() {
        XCTAssertEqual(TBDRealDataGuard.refusal, sentence)
        XCTAssertEqual(TBDRealDataGuard.Refused().localizedDescription, sentence)
        XCTAssertEqual(TBDRealDataGuard.Refused().errorDescription, sentence)
    }

    func testEachRefusingConditionStopsEveryKindOfWriteAndLeavesNothingBehind() throws {
        let cases: [(String, (String) -> TBDRealDataGuard.Context)] = [
            ("TBD_TEST=1 inside the app bundle", { self.context($0, env: ["TBD_TEST": "1"], executable: "/Applications/TBD.app/Contents/MacOS/TBD") }),
            ("TBD_TEST=1 with every redirect set", { self.context($0, env: ["TBD_TEST": "1", "CFFIXED_USER_HOME": "/tmp/x", "TBD_APP_SUPPORT_DIR": "/tmp/y"]) }),
            ("under XCTest, inside the app bundle (DayflowTests host)", { self.context($0, executable: "/Applications/TBD.app/Contents/MacOS/TBD", xctest: true) }),
            ("under XCTest with a redirect set", { self.context($0, env: ["CFFIXED_USER_HOME": "/tmp/x"], xctest: true) }),
            ("not in a bundle, no redirect (a tool run)", { self.context($0) }),
            ("not in a bundle, empty redirects", { self.context($0, env: ["CFFIXED_USER_HOME": "", "TBD_APP_SUPPORT_DIR": ""]) }),
            ("unknown executable, no redirect", { self.context($0, executable: nil) }),
        ]
        for (label, make) in cases {
            let (home, url) = realHome()
            let store = guarded(url, make(home))
            XCTAssertThrowsError(try store.addTask(title: "x", day: day), label) {
                XCTAssertEqual($0 as? TBDRealDataGuard.Refused, TBDRealDataGuard.Refused(), label)
                XCTAssertEqual($0.localizedDescription, sentence, label)
            }
            XCTAssertThrowsError(try store.commit(drafts: [TBDFlowTaskDraft(title: "x", day: day)], idempotencyKey: "k", payloadHash: "h"), label)
            XCTAssertThrowsError(try store.updateSettings { $0.focusMinutes = 30 }, label)
            XCTAssertFalse(try store.tick(now: FlowT.date("2026-10-05T07:00:00Z")).changed, "\(label): a tick with nothing to do writes nothing and does not fail")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "\(label): no folder was made")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".lock"), "\(label): no lock file")
            // the same with the store that moves an unreadable file aside when it opens (the app's way)
            let opened = guarded(url, make(home), quarantine: .atOpen)
            XCTAssertThrowsError(try opened.addTask(title: "x", day: day), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "\(label): an app-style store made nothing either")
        }
    }

    func testReadsStayAllowedAndAnUnreadableRealFileIsNotMovedAside() throws {
        let (home, url) = realHome()
        // The data exists (a store with a pass writes it; this is the pretend real folder).
        let owner = guarded(url, context(home, executable: "/Applications/TBD.app/Contents/MacOS/TBD"), quarantine: .atOpen)
        try owner.addTask(title: "mine", day: day)
        for ctx in [context(home, env: ["TBD_TEST": "1"]), context(home, xctest: true), context(home)] {
            let reader = guarded(url, ctx)
            XCTAssertEqual(reader.state.tasks.map(\.title), ["mine"])
            XCTAssertTrue(reader.reloadIfChanged() == false)
            XCTAssertEqual(reader.tasks(onDay: day).count, 1)
        }
        let namesBefore = listing(url)
        // An unreadable real file: the guarded store reads "empty" and leaves the file and its folder as they are.
        try Data("not json".utf8).write(to: url)
        for quarantine in [TBDFlowStore.Quarantine.atOpen, .onFirstWrite] {
            let store = guarded(url, context(home, env: ["TBD_TEST": "1"]), quarantine: quarantine)
            XCTAssertTrue(store.state.tasks.isEmpty)
            XCTAssertTrue(store.isUnreadable)
            XCTAssertNil(store.corruptBackupURL)
            XCTAssertThrowsError(try store.addTask(title: "x", day: day))
        }
        XCTAssertEqual(listing(url), namesBefore)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testTheAppInItsBundleAndItsAgentsCLIMayWrite() throws {
        let appExecutable = "/Applications/TBD.app/Contents/MacOS/TBD"
        let helperExecutable = "/Applications/TBD.app/Contents/Helpers/dayflow"
        let devExecutable = "/Users/x/Library/Developer/Xcode/DerivedData/TBD-abc/Build/Products/Debug/TBD Dev.app/Contents/Helpers/dayflow"
        for (label, ctx) in [
            ("the app", { (h: String) in self.context(h, executable: appExecutable) }),
            ("its agent's CLI, from the bundle, with TBD_APP_SUPPORT_DIR", { (h: String) in self.context(h, env: ["TBD_APP_SUPPORT_DIR": h + "/Library/Application Support/com.tealbrick.desktop"], executable: helperExecutable) }),
            ("the dev app's CLI", { (h: String) in self.context(h, env: ["TBD_APP_SUPPORT_DIR": h + "/Library/Application Support/com.tealbrick.desktop-dev"], executable: devExecutable) }),
            ("a tool with CFFIXED_USER_HOME set", { (h: String) in self.context(h, env: ["CFFIXED_USER_HOME": h]) }),
            ("a tool with TBD_APP_SUPPORT_DIR set", { (h: String) in self.context(h, env: ["TBD_APP_SUPPORT_DIR": h]) }),
        ] as [(String, (String) -> TBDRealDataGuard.Context)] {
            let (home, url) = realHome()
            let store = guarded(url, ctx(home), quarantine: .atOpen)
            let task = try store.addTask(title: "ok", day: day)
            XCTAssertEqual(guarded(url, ctx(home)).state.tasks.map(\.id), [task.id], label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), label)
        }
    }

    func testOnlyTheRealDataFolderIsGuarded() throws {
        let (home, _) = realHome()
        let ctx = context(home, env: ["TBD_TEST": "1"], xctest: true)
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
        for name in ["com.tealbrick.desktop", "com.tealbrick.desktop-dev", "com.tealbrick.desktop-dev-shots", "com.tealbrick.desktop-agent", "com.tealbrick.desktop-dev-x1", "COM.TEALBRICK.DESKTOP"] {
            XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: support.appendingPathComponent("\(name)/Companion/flow.json"), context: ctx), name)
            XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: support.appendingPathComponent(name), context: ctx), "the folder itself: \(name)")
        }
        for other in ["Library/Application Support/Dayflow/x", "Library/Application Support/com.tealbrick.other/x", "Library/Application Support/x/com.tealbrick.desktop/y",
                      "Library/Caches/com.tealbrick.desktop/x", "Documents/com.tealbrick.desktop/x", "Library/Application Support"] {
            XCTAssertFalse(TBDRealDataGuard.refuses(writingTo: URL(fileURLWithPath: home).appendingPathComponent(other), context: ctx), other)
        }
        // a test's own temp folder is never refused, whatever the conditions
        XCTAssertFalse(TBDRealDataGuard.refuses(writingTo: flowURL, context: ctx))
        // the folder named by a link is the real one
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link-to-support-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: support)
        XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: link.appendingPathComponent("com.tealbrick.desktop/Companion/flow.json"), context: ctx), "through a link")
        // ".." does not get out of the check
        XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: support.appendingPathComponent("Dayflow/../com.tealbrick.desktop/x"), context: ctx))
    }

    func testBundleDetection() {
        XCTAssertTrue(TBDRealDataGuard.isInsideAppBundle("/Applications/TBD.app/Contents/MacOS/TBD"))
        XCTAssertTrue(TBDRealDataGuard.isInsideAppBundle("/Applications/TBD Dev.app/Contents/Helpers/dayflow"))
        XCTAssertTrue(TBDRealDataGuard.isInsideAppBundle("/x/Some.APP/Contents/MacOS/y"))
        XCTAssertFalse(TBDRealDataGuard.isInsideAppBundle("/Users/x/work/tool/.build/debug/dayflow"))
        XCTAssertFalse(TBDRealDataGuard.isInsideAppBundle("/Users/x/Foo.app/dayflow"), "not under Contents")
        XCTAssertFalse(TBDRealDataGuard.isInsideAppBundle("/Users/x/Foo.app"))
        XCTAssertFalse(TBDRealDataGuard.isInsideAppBundle(nil))
    }

    func testThisTestRunIsRecognisedAndTheRealDefaultPathIsRefused() {
        // Pure checks: nothing is written.
        XCTAssertTrue(TBDRealDataGuard.Context.current.underXCTest)
        XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: TBDFlowStore.defaultURL), "an accidental write to the default Flow file fails in a test")
        XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: TBDFlowStore.defaultURL.appendingPathExtension("lock")))
        XCTAssertTrue(TBDRealDataGuard.refuses(writingTo: TBDIdentity.applicationSupport("Companion").appendingPathComponent("anything")))
        XCTAssertFalse(TBDRealDataGuard.refuses(writingTo: flowURL), "a test folder is fine")
        XCTAssertFalse(TBDRealDataGuard.realHomeDirectory().isEmpty)
    }
}
