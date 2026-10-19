import Foundation

/// One-time clean-up of the temporary CODEX_HOME folders that builds up to dev.8 created (S2, C287). Those builds
/// copied ~/.codex/auth.json into `<temp>/Dayflow-codex-home-<UUID>` to retry Codex after an "invalid transport"
/// config error, and removed the folder after the retry; a crash could leave one behind. TBD removes ONLY folders it
/// created itself: direct children of the temp folder, exact name prefix, real directories (never a symlink). It
/// never touches ~/.codex or anything else.
public enum TBDCodexTempHomeCleanup {
    public static let prefix = "Dayflow-codex-home-"
    public static let doneKey = "tbd.migration.dev9.codexTempHomes"

    /// Removes the matching folders in `temp` and returns how many it removed.
    @discardableResult
    public static func run(temp: URL = FileManager.default.temporaryDirectory, fileManager: FileManager = .default) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: temp.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) && name.count > prefix.count && !name.contains("/") {
            let url = temp.appendingPathComponent(name, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Runs once per install (flag in `defaults`). Returns the count, or nil when it already ran.
    public static func runOnce(defaults: UserDefaults = .standard, temp: URL = FileManager.default.temporaryDirectory) -> Int? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        let count = run(temp: temp)
        defaults.set(true, forKey: doneKey)
        return count
    }
}
