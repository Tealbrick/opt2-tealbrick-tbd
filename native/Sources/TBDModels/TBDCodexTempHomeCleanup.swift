import Foundation

/// One-time clean-up of the temporary CODEX_HOME folders that builds up to dev.8 created (S2, C287). Those builds
/// copied ~/.codex/auth.json into `<temp>/Dayflow-codex-home-<UUID>` to retry Codex after an "invalid transport"
/// config error, and removed the folder after the retry; a crash could leave one behind. TBD removes ONLY folders it
/// created itself: direct children of the temp folder, exact name prefix, real directories (never a symlink). It
/// never touches ~/.codex or anything else.
public enum TBDCodexTempHomeCleanup {
    public static let prefix = "Dayflow-codex-home-"
    public static let doneKey = "tbd.migration.dev9.codexTempHomes"

    /// Removes the matching folders in `temp`: how many it removed, and how many it could not remove.
    @discardableResult
    public static func run(temp: URL = FileManager.default.temporaryDirectory, fileManager: FileManager = .default) -> (removed: Int, failed: Int) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: temp.path) else { return (0, 0) }
        var removed = 0, failed = 0
        for name in names where name.hasPrefix(prefix) && name.count > prefix.count && !name.contains("/") {
            let url = temp.appendingPathComponent(name, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 } else { failed += 1 }
        }
        return (removed, failed)
    }

    /// Runs until it succeeded once (flag in `defaults`; a folder it could not remove still holds a login copy, so the
    /// next launch tries again, review dev.9 #14). Returns the result, or nil when it already succeeded.
    public static func runOnce(defaults: UserDefaults = .standard, temp: URL = FileManager.default.temporaryDirectory) -> (removed: Int, failed: Int)? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        let result = run(temp: temp)
        if result.failed == 0 { defaults.set(true, forKey: doneKey) }
        return result
    }
}
