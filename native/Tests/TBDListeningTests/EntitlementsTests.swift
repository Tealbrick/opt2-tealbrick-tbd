import Foundation
import XCTest
import TBDModels

/// C282: the native side reads the helper's entitlement snapshot and shows the same sentences as the helper.
final class EntitlementsTests: XCTestCase {
    func testTheHelperSnapshotIsParsedAndNothingUnknownUnlocks() {
        let value: [String: Any] = ["ws": "ws_1", "fetchedAt": 5, "apps": [
            "rules": ["access": "unlocked", "paid": true, "installed": true],
            "kanban": ["access": "install"],
            "knowledge": ["access": "locked"],
            "marketplace": ["access": "unlocked"],   // not a gated app: ignored
            "connect": ["access": "maybe"],          // unknown value: locked
        ]]
        let ent = TBDEntitlements(helperValue: value)
        XCTAssertEqual(ent.workspace, "ws_1")
        XCTAssertEqual(ent.access(.rules), .unlocked)
        XCTAssertEqual(ent.access(.kanban), .install)
        XCTAssertEqual(ent.access(.knowledge), .locked)
        XCTAssertEqual(ent.access(.connect), .locked)
        XCTAssertEqual(ent.access(.inbox), .locked, "missing = locked")
        XCTAssertEqual(TBDEntitlements(helperValue: nil), .none)
        XCTAssertEqual(TBDEntitlements(helperValue: "garbage").access(.rules), .locked)
    }

    func testSentencesMatchTheHelper() throws {
        let ent = TBDEntitlements(apps: [.rules: .install, .knowledge: .unlocked], workspace: "ws_1")
        XCTAssertEqual(ent.availability(.rules), "Install Rules & Approvals in Portal to use this.")
        XCTAssertEqual(ent.availability(.kanban), "Available with Task Board.")
        XCTAssertNil(ent.availability(.knowledge))
        // Same product ids and names as chat/src/main/entitlements.ts GATED_APPS.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ts = try String(contentsOf: repo.appendingPathComponent("chat/src/main/entitlements.ts"), encoding: .utf8)
        for app in TBDGatedApp.allCases {
            XCTAssertTrue(ts.contains("  \(app.rawValue): \"\(app.displayName)\","), "\(app.rawValue) differs from the helper")
        }
        XCTAssertTrue(ts.contains("`Install ${name} in Portal to use this.`"))
        XCTAssertTrue(ts.contains("`Available with ${name}.`"))
    }
}
