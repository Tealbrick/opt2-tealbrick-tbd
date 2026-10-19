import Foundation
import XCTest
import TBDModels
@testable import TBDSpeech

/// C280 C10 / C284: TBD v2 has its own bundle id and data; it never uses the archived v1 names.
final class AppIdentityTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheLiveIdentityIsTBDv2() {
        XCTAssertEqual(TBDIdentity.liveBundleID, "com.tealbrick.desktop")
        XCTAssertEqual(TBDIdentity.devBundleID, "com.tealbrick.desktop.dev")
        XCTAssertEqual(TBDIdentity.archivedV1BundleID, "com.tealbrick.tbd")
        XCTAssertNotEqual(TBDIdentity.liveBundleID, TBDIdentity.archivedV1BundleID)
        XCTAssertNotEqual(TBDIdentity.devBundleID, "com.tealbrick.tbd.dev")
    }

    func testNoPerUserNameIsAV1Name() {
        // The test process is not the dev app, so these are the live names.
        XCTAssertEqual(TBDIdentity.dataFolder, "com.tealbrick.desktop")
        XCTAssertEqual(TBDIdentity.documentsFolder, "TBD Desktop")
        XCTAssertFalse(TBDIdentity.archivedV1Folders.contains(TBDIdentity.dataFolder))
        XCTAssertFalse(TBDIdentity.archivedV1Folders.contains(TBDIdentity.documentsFolder))
        XCTAssertEqual(TBDIdentity.applicationSupport().lastPathComponent, "com.tealbrick.desktop")
        XCTAssertEqual(TBDIdentity.applicationSupport("Listening").lastPathComponent, "Listening")
        for name in ["models", "chat", "person", "agent", "companion.apikeys"] {
            let service = TBDIdentity.keychainService(name)
            XCTAssertTrue(service.hasPrefix("com.tealbrick.desktop."), service)
            XCTAssertFalse(service.hasPrefix("com.tealbrick.tbd"), service)
        }
        XCTAssertEqual(TBDModelRegistry.keychainService, "com.tealbrick.desktop.models")
    }

    func testListeningRootIsInsideTheAppsOwnFolder() {
        guard ProcessInfo.processInfo.environment[TBDListeningPaths.rootEnvironmentKey] == nil else { return }
        let root = TBDListeningPaths.root.path
        XCTAssertTrue(root.hasSuffix("/com.tealbrick.desktop/Listening"), root)
        for v1 in TBDIdentity.archivedV1Folders {
            XCTAssertFalse(root.contains("/Application Support/\(v1)/"), root)
        }
    }

    func testTheCompanionCLIUsesTheSameNames() throws {
        let cli = try String(contentsOf: repo.appendingPathComponent("companion/tools/dayflow-cli/Sources/dayflow/AppIdentity.swift"), encoding: .utf8)
        XCTAssertTrue(cli.contains("tbdAppDefaultsDomain = \"\(TBDIdentity.liveBundleID)\""))
        XCTAssertTrue(cli.contains("tbdAppDataFolder = \"\(TBDIdentity.liveDataFolder)\""))
    }

    /// A v1 name in a source file would read or write the archived v1 app's data.
    func testNoSourceFileUsesTheV1Identity() throws {
        let roots = ["native/Sources", "companion/Dayflow/Dayflow", "companion/tools/dayflow-cli/Sources", "chat/src",
                     "companion/Dayflow/Config", "companion/Dayflow/Dayflow.xcodeproj", "scripts"]
        let allowed: Set<String> = ["TBDAppIdentity.swift", "appIdentity.ts"]   // name the archive so it can be refused
        var hits: [String] = []
        var scanned = 0
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: repo.appendingPathComponent(root), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                guard ["swift", "ts", "tsx", "pbxproj", "xcconfig", "plist", "entitlements", "sh"].contains(url.pathExtension),
                      !allowed.contains(url.lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for marker in ["com.tealbrick.tbd", "tealbrick-tbd:", "\"tealbrick-tbd\"", "Application Support/TBD/", "\"TBD/Companion"]
                where text.contains(marker) {
                    hits.append("\(url.path.replacingOccurrences(of: repo.path + "/", with: "")): \(marker)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 300, "the scan must see the sources")
        XCTAssertEqual(hits, [], "v1 identity used in: \(hits.joined(separator: ", "))")
    }
}
