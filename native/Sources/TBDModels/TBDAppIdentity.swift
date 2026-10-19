import Foundation

/// Which identity this process runs as: the owner's live TBD, or the DEBUG-only development copy ("TBD Dev").
///
/// TBD v2 has its OWN identity and data (C280 C10, C284): bundle id `com.tealbrick.desktop`. It never reads or writes
/// the archived v1 app's names (`com.tealbrick.tbd`, `~/Library/Application Support/TBD` and `Dayflow`); they stay
/// untouched as reference only.
///
/// The one switch is the Debug build setting `PRODUCT_BUNDLE_IDENTIFIER = com.tealbrick.desktop.dev` (companion/Dayflow
/// project, Debug configuration only). A DEBUG build running under that bundle id is the dev identity; every per-user
/// location then gets a separate name, so the dev app never reads or writes the live app's data:
///
/// - folders (`~/Library/Application Support/com.tealbrick.desktop`, `~/Library/Logs/com.tealbrick.desktop`,
///   `~/Documents/TBD Desktop`): `dataFolder` / `documentsFolder` → `<name>-dev`
/// - Keychain services: `keychainService("models")` = `com.tealbrick.desktop.models` → `com.tealbrick.desktop.models.dev`
/// - UserDefaults: separate by bundle id (`com.tealbrick.desktop.dev`); no code uses the live suite in the app
///
/// `--design-shots <dir>` (DEBUG only) renders companion screens to PNG; it uses `<name>-dev-shots` so a run starts
/// from its own demo data and never touches the dev person's data either.
///
/// Release builds compile the `#else` branches: `isDev` is the constant `false` and `folder(_:)` / `service(_:)` return
/// their argument unchanged.
public enum TBDIdentity {
    public static let liveBundleID = "com.tealbrick.desktop"
    public static let devBundleID = "com.tealbrick.desktop.dev"
    /// The archived v1 app (reference only). TBD v2 never opens its data; the agent's file policy also denies it.
    public static let archivedV1BundleID = "com.tealbrick.tbd"
    public static let archivedV1Folders = ["TBD", "TBD Agent", "Dayflow"]

    /// The app's per-user folder in Application Support and Logs (Apple's bundle-id convention).
    public static let liveDataFolder = liveBundleID
    /// The user-visible folder in ~/Documents (auto-saved transcripts).
    public static let liveDocumentsFolder = "TBD Desktop"

    #if DEBUG
    /// True in a DEBUG build running as `com.tealbrick.desktop.dev`.
    public static let isDev: Bool = Bundle.main.bundleIdentifier == devBundleID
    /// True when the dev app was launched with `--design-shots <dir>`.
    public static let isDesignShots: Bool = isDev && CommandLine.arguments.contains("--design-shots")

    /// DEBUG only: `TBD_DEV_IDENTITY=<name>` (1–12 of a-z, 0-9) gives the dev app a separate, fresh identity for a
    /// scripted fresh-install run (WP-ONB clicks measurement): folders `<name>-dev-<x>`, Keychain `<service>.dev-<x>`.
    /// Without it, an existing dev Keychain item made by an older ad-hoc build makes macOS ask for the login password.
    public static let devVariant: String? = {
        guard isDev, !isDesignShots, let raw = ProcessInfo.processInfo.environment["TBD_DEV_IDENTITY"],
              (1...12).contains(raw.unicodeScalars.count),
              raw.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return raw
    }()

    /// A per-user folder name: `name` → `name-dev` (`name-dev-shots` in a design-shots run, `name-dev-<x>` with
    /// `TBD_DEV_IDENTITY`).
    public static func folder(_ live: String) -> String {
        guard isDev else { return live }
        if isDesignShots { return live + "-dev-shots" }
        return live + (devVariant.map { "-dev-" + $0 } ?? "-dev")
    }

    /// A Keychain service name: `x` → `x.dev` (`x.dev-<x>` with `TBD_DEV_IDENTITY`).
    public static func service(_ live: String) -> String {
        guard isDev else { return live }
        return live + (devVariant.map { ".dev-" + $0 } ?? ".dev")
    }
    #else
    public static let isDev = false
    public static let isDesignShots = false
    @inline(__always) public static func folder(_ live: String) -> String { live }
    @inline(__always) public static func service(_ live: String) -> String { live }
    #endif

    /// `com.tealbrick.desktop` (dev: `com.tealbrick.desktop-dev`).
    public static var dataFolder: String { folder(liveDataFolder) }
    /// `TBD Desktop` (dev: `TBD Desktop-dev`).
    public static var documentsFolder: String { folder(liveDocumentsFolder) }
    /// A Keychain service under the app's own bundle id: `keychainService("models")` = `com.tealbrick.desktop.models`.
    public static func keychainService(_ name: String) -> String { service(liveBundleID + "." + name) }

    /// `~/Library/Application Support/<dataFolder>` (or a sub-folder of it).
    public static func applicationSupport(_ subfolder: String? = nil) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolder, isDirectory: true)
        guard let subfolder else { return root }
        return root.appendingPathComponent(subfolder, isDirectory: true)
    }
}
