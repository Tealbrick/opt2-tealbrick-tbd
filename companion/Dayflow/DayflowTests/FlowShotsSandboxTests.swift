#if DEBUG
  import XCTest
  import TBDModels

  @testable import TBD

  /// The Flow design shots touch only their own temp folder: no app-support folder, no real StorageManager cards, no shared
  /// Task Board source (review 20).
  @MainActor
  final class FlowShotsSandboxTests: XCTestCase {
    func testEveryStoreAndFileOfTheShotsIsUnderTheTempFolderNotTheAppSupportFolder() throws {
      let sandbox = FlowShotsSandbox()
      defer { sandbox.cleanUp() }
      let planners = [
        FlowShotsSeed.planner(sandbox), FlowShotsSeed.taskBoardPlanner(sandbox), FlowShotsSeed.planVsActualPlanner(sandbox),
      ]
      let observers = FlowShotsSeed.observerScreens(sandbox)
      defer { observers.cleanUp() }

      let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
      let support = TBDIdentity.applicationSupport().deletingLastPathComponent().standardizedFileURL.path
      XCTAssertTrue(sandbox.isContained())
      XCTAssertTrue(sandbox.root.standardizedFileURL.path.hasPrefix(temp + "/"))
      for planner in planners {
        let path = planner.store.url.standardizedFileURL.path
        XCTAssertTrue(path.hasPrefix(sandbox.root.standardizedFileURL.path + "/"), path)
        XCTAssertFalse(path.hasPrefix(support), "not the app-support folder: \(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the seeded list is in the sandbox")
        XCTAssertFalse(planner.taskBoard === FlowTaskBoardSource.shared, "never the shared Task Board source")
      }
      XCTAssertEqual(observers.screens.count, 3)
      XCTAssertGreaterThanOrEqual(sandbox.handedOutURLs.count, 3)
    }

    func testTheShotsNeverReadStorageManagerCards() {
      let sandbox = FlowShotsSandbox()
      defer { sandbox.cleanUp() }
      let planner = FlowShotsSeed.planner(sandbox)
      XCTAssertEqual(planner.timelineEvidence(), [], "the first Today shot has no timeline cards from the real database")
      let board = FlowShotsSeed.taskBoardPlanner(sandbox)
      XCTAssertEqual(board.timelineEvidence(), [])
    }

    func testSeededSourcesNeverAskTheHelper() async {
      let sandbox = FlowShotsSandbox()
      defer { sandbox.cleanUp() }
      for planner in [FlowShotsSeed.planner(sandbox), FlowShotsSeed.taskBoardPlanner(sandbox)] {
        let before = planner.taskBoard.mode
        planner.taskBoard.pageDidAppear()
        await planner.taskBoard.recheck(force: true)
        XCTAssertFalse(planner.taskBoard.isPolling)
        XCTAssertEqual(planner.taskBoard.mode, before, "a frozen source stays as seeded")
      }
    }

    func testTheContainmentRule() {
      let temp = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)
      let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
      let root = temp.appendingPathComponent("tbd-flow-shots-1", isDirectory: true)
      let inside = [root.appendingPathComponent("a/flow.json")]
      XCTAssertTrue(FlowShotsSandbox.contains(root: root, urls: inside, temporary: temp, support: support))
      // A file outside the root.
      XCTAssertFalse(
        FlowShotsSandbox.contains(root: root, urls: inside + [support.appendingPathComponent("com.tealbrick.desktop/flow.json")], temporary: temp, support: support))
      // A root that is not in the temp folder.
      let other = support.appendingPathComponent("tbd-flow-shots-2", isDirectory: true)
      XCTAssertFalse(FlowShotsSandbox.contains(root: other, urls: [], temporary: temp, support: support))
      // A temp folder that lies inside the app-support folder is refused too.
      XCTAssertFalse(FlowShotsSandbox.contains(root: other, urls: [], temporary: support, support: support))
      // A path that only starts with the same letters is not inside.
      let sibling = URL(fileURLWithPath: "/var/folders/xx/T-evil/tbd-flow-shots-3", isDirectory: true)
      XCTAssertFalse(FlowShotsSandbox.contains(root: sibling, urls: [], temporary: temp, support: support))
    }

    func testCleanUpRemovesOnlyTheSandboxFolder() {
      let sandbox = FlowShotsSandbox()
      _ = FlowShotsSeed.planner(sandbox)
      let root = sandbox.root
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
      sandbox.cleanUp()
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.path))
    }
  }
#endif
