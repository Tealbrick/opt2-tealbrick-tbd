import XCTest
@testable import TBDModels

/// S2 (C287): the one-time clean-up removes only TBD's own temporary CODEX_HOME folders, never ~/.codex.
final class TBDCodexTempHomeCleanupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-codex-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mkdir(_ path: String, auth: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if auth { try Data("{}".utf8).write(to: url.appendingPathComponent("auth.json")) }
        return url
    }

    func testRemovesOnlyItsOwnFoldersAndNeverTheCodexHome() throws {
        let temp = try mkdir("T")
        let home = try mkdir("home")
        let codex = try mkdir("home/.codex", auth: true)
        _ = try mkdir("T/Dayflow-codex-home-\(UUID().uuidString)", auth: true)
        _ = try mkdir("T/Dayflow-codex-home-\(UUID().uuidString)")
        // Not ours: other names, a bare prefix, a file with the prefix, a symlink with the prefix that points at ~/.codex.
        _ = try mkdir("T/other-codex-home")
        _ = try mkdir("T/Dayflow-codex-home-")
        try Data().write(to: temp.appendingPathComponent("Dayflow-codex-home-file"))
        try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("Dayflow-codex-home-link"), withDestinationURL: codex)

        XCTAssertEqual(TBDCodexTempHomeCleanup.run(temp: temp), 2)

        let left = try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted()
        XCTAssertEqual(left, ["Dayflow-codex-home-", "Dayflow-codex-home-file", "Dayflow-codex-home-link", "other-codex-home"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("auth.json").path), "~/.codex is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
    }

    func testRunsOnce() throws {
        let temp = try mkdir("T")
        let name = "tbd.tests.codexcleanup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        _ = try mkdir("T/Dayflow-codex-home-a")
        XCTAssertEqual(TBDCodexTempHomeCleanup.runOnce(defaults: defaults, temp: temp), 1)
        _ = try mkdir("T/Dayflow-codex-home-b")
        XCTAssertNil(TBDCodexTempHomeCleanup.runOnce(defaults: defaults, temp: temp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("Dayflow-codex-home-b").path))
    }
}
