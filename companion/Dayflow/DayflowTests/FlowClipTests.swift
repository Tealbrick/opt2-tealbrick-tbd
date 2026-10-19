import XCTest

@testable import TBD

/// The creature's clips are bundled for both palettes, and the exit clip follows the v1 table.
@MainActor
final class FlowClipTests: XCTestCase {
  func testEveryClipStemResolvesToABundledFileForBothPalettes() throws {
    XCTAssertEqual(FlowCreatureClip.allCases.count, 21)
    XCTAssertEqual(TealbrickPalette.allCases, [.teal, .burgundy])
    for palette in TealbrickPalette.allCases {
      for clip in FlowCreatureClip.allCases {
        let url = try XCTUnwrap(clip.url(palette: palette), "missing \(clip.stem(palette: palette)).mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        XCTAssertEqual(url.lastPathComponent, "tb_brickie_\(palette.rawValue)_\(clip.rawValue).mov")
      }
    }
  }

  func testAMissingClipFailsSoftWithNoFallbackToAnotherSet() {
    // A bundle with no clips (the test bundle's own resources have none): no URL, and never `flow_<name>.mov`.
    let empty = Bundle(for: FlowClipTests.self)
    for clip in FlowCreatureClip.allCases {
      XCTAssertNil(clip.url(palette: .teal, in: empty))
    }
  }

  func testOnlyBrickieHasClips() {
    XCTAssertEqual(FlowCreatureClip.character, "brickie")
    XCTAssertEqual(FlowCreatureClip.entrance.stem(palette: .burgundy), "tb_brickie_burgundy_flow_entrance")
  }

  func testAnchorsAndTheTopLayoutOffset() {
    XCTAssertEqual(FlowCreatureClip.entrance.anchor, .side)
    XCTAssertEqual(FlowCreatureClip.listen1.anchor, .stand)
    XCTAssertEqual(FlowCreatureClip.exitCopter.anchor, .land)
    XCTAssertEqual(FlowCreatureClip.peekExit.anchor, .peek)
    XCTAssertEqual(FlowCreatureClip.bathLoop.anchor, .tub)
    // Only a standing clip in the top layout is shifted onto the landing spot.
    XCTAssertEqual(FlowCreatureClip.listen1.canvasOffset(in: .top), CGPoint(x: 671 - 990, y: 447 - 527))
    XCTAssertEqual(FlowCreatureClip.listen1.canvasOffset(in: .side), .zero)
    XCTAssertEqual(FlowCreatureClip.dropFromTop.canvasOffset(in: .top), .zero)
  }

  func testExitClipTable() {
    func exit(_ p: FlowOverlayPresentation, _ v: FlowNudgeVariant, _ r: FlowNudgeReply? = nil) -> FlowCreatureClip? {
      FlowOverlayController.exitClip(for: p, variant: v, lastReply: r)
    }
    let nudge = FlowOverlayPresentation.nudge(message: "m", escalated: false)
    let fire = FlowOverlayPresentation.nudge(message: "m", escalated: true)
    let toast = FlowOverlayPresentation.toast(message: "t")

    XCTAssertNil(exit(.hidden, .side))
    XCTAssertEqual(exit(.onBreak, .side), .bathEnd)
    XCTAssertEqual(exit(fire, .side), .fireEnd)
    XCTAssertEqual(exit(fire, .top), .fireEnd)
    // Side: the session-ended bubble leaves by plane, everything else by a random wave or move.
    XCTAssertEqual(exit(.sessionEnded, .side), .exitPlane)
    for p in [nudge, toast] {
      for _ in 0..<20 { XCTAssertTrue(FlowCreatureClip.sideExits.contains(try! XCTUnwrap(exit(p, .side)))) }
    }
    XCTAssertEqual(Set(FlowCreatureClip.sideExits), [.exitWave1, .exitWave2, .exitMove1, .exitMove2])
    // Top: copter after "back to work", plane otherwise.
    XCTAssertEqual(exit(nudge, .top, .backToWork), .exitCopter)
    XCTAssertEqual(exit(nudge, .top, .snooze), .exitPlane)
    XCTAssertEqual(exit(toast, .top, nil), .exitPlane)
    XCTAssertEqual(exit(.sessionEnded, .top), .exitPlane)
    // Peek: its own exit.
    XCTAssertEqual(exit(nudge, .peek), .peekExit)
    XCTAssertEqual(exit(toast, .peek, .backToWork), .peekExit)
  }

  func testNudgeVariantCycles() {
    XCTAssertEqual(FlowNudgeVariant.side.next, .top)
    XCTAssertEqual(FlowNudgeVariant.top.next, .peek)
    XCTAssertEqual(FlowNudgeVariant.peek.next, .side)
    XCTAssertFalse(FlowNudgeVariant.side.anchorsToTop)
    XCTAssertTrue(FlowNudgeVariant.top.anchorsToTop)
    XCTAssertTrue(FlowNudgeVariant.peek.anchorsToTop)
  }
}
