import XCTest

@testable import TBD

/// TBD-DEV7-1: a fresh TBD v2 identity must not end setup with screen capture saved as OFF.
@MainActor
final class RecordingDefaultTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() {
    suite = "tbd.tests.recording.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  func testSetupWithTheGrantTurnsCaptureOnAndSavesIt() {
    var calls: [(Bool, Bool)] = []
    var notices = 0
    TBDCompanionSetup.finishSetup(screenRecordingGranted: true, setRecording: { calls.append(($0, $1)) }, postNotice: { notices += 1 })
    XCTAssertEqual(calls.map(\.0), [true], "isRecording = true")
    XCTAssertEqual(calls.map(\.1), [true], "and saved")
    XCTAssertEqual(notices, 0)
  }

  func testSetupWithoutTheGrantKeepsCaptureOffWithoutSavingOffAndPostsTheNotice() {
    var calls: [(Bool, Bool)] = []
    var notices = 0
    TBDCompanionSetup.finishSetup(screenRecordingGranted: false, setRecording: { calls.append(($0, $1)) }, postNotice: { notices += 1 })
    XCTAssertEqual(calls.map(\.0), [false])
    XCTAssertEqual(calls.map(\.1), [false], "'off' is not saved: capture starts once macOS has the grant")
    XCTAssertEqual(notices, 1)
  }

  func testTheMigrationClearsDev7sSavedOffExactlyOnce() {
    defaults.set(false, forKey: "isRecording")   // what dev.7's setup wrote
    XCTAssertTrue(AppState.migrateRecordingDefaultIfNeeded(defaults))
    XCTAssertNil(defaults.object(forKey: "isRecording"), "saved 'off' cleared: launch defaults to ON when granted")
    XCTAssertTrue(defaults.bool(forKey: AppState.recordingDefaultMigrationKey))
    XCTAssertFalse(AppState.migrateRecordingDefaultIfNeeded(defaults), "runs once")
  }

  func testAPauseMadeAfterTheMigrationIsKept() {
    XCTAssertTrue(AppState.migrateRecordingDefaultIfNeeded(defaults))
    defaults.set(false, forKey: "isRecording")   // Martin pauses capture after dev.8
    XCTAssertFalse(AppState.migrateRecordingDefaultIfNeeded(defaults))
    XCTAssertEqual(defaults.object(forKey: "isRecording") as? Bool, false, "his pause is never overridden")
  }
}
