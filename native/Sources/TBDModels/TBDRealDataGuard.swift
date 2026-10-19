import Foundation

/// L70 (Coordinator): a test run or a tool run must never WRITE to the person's real TBD data.
///
/// The real data is `~/Library/Application Support/com.tealbrick.desktop*` in the REAL home folder (from the password
/// database, `getpwuid(getuid())`), not the home that `HOME` or `CFFIXED_USER_HOME` names. A write is refused when its path is
/// under that folder and ANY of these holds:
///
/// 1. `TBD_TEST=1` is set;
/// 2. the process runs under XCTest (`XCTestConfigurationFilePath` in the environment, or the class `XCTestCase` is loaded);
/// 3. the main executable is NOT inside a `.app` bundle, and neither `CFFIXED_USER_HOME` nor `TBD_APP_SUPPORT_DIR` is set.
///
/// The app inside its bundle is allowed, and so is its agent's CLI (it starts from the bundle and gets `TBD_APP_SUPPORT_DIR`).
/// `CFFIXED_USER_HOME` (macOS reads it as the home for `FileManager`) moves the data folder away from the real one, so the
/// refused path is simply not the path any more. Reads are always allowed. Known limit: a person who points
/// `TBD_APP_SUPPORT_DIR` at the real folder on purpose, from a tool outside the bundle, is not stopped by condition 3.
public enum TBDRealDataGuard {
    /// The sentence a refused write shows (the MCP tool and the app show it as it is).
    public static let refusal = "TBD refused to write to your real TBD data from a test or tool run. Set CFFIXED_USER_HOME to a test folder."
    public static let appSupportEnvironmentKey = "TBD_APP_SUPPORT_DIR"
    public static let testEnvironmentKey = "TBD_TEST"
    /// The start of every folder name that is real TBD data: `com.tealbrick.desktop`, `-dev`, `-dev-shots`, `-agent`.
    public static let dataFolderPrefix = "com.tealbrick.desktop"

    public struct Refused: Error, LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? { TBDRealDataGuard.refusal }
    }

    /// What the guard looks at. Tests build their own, so they never touch the real folder.
    public struct Context: Sendable {
        /// The real home folder (not HOME, not CFFIXED_USER_HOME).
        public var realHome: String
        public var environment: [String: String]
        /// The main executable, as a path (nil when unknown).
        public var executablePath: String?
        public var underXCTest: Bool

        public init(realHome: String, environment: [String: String], executablePath: String?, underXCTest: Bool) {
            self.realHome = realHome
            self.environment = environment
            self.executablePath = executablePath
            self.underXCTest = underXCTest
        }

        /// This process.
        public static var current: Context {
            let env = ProcessInfo.processInfo.environment
            return Context(
                realHome: TBDRealDataGuard.realHomeDirectory(), environment: env,
                executablePath: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                underXCTest: env["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil)
        }
    }

    /// The home folder of the user who runs this process, from the password database.
    public static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// True when `path` has a folder named `*.app` followed by `Contents` (an app bundle's executable).
    public static func isInsideAppBundle(_ path: String?) -> Bool {
        guard let path else { return false }
        let parts = path.split(separator: "/").map(String.init)
        for i in parts.indices.dropLast() where parts[i].lowercased().hasSuffix(".app") && parts[i + 1] == "Contents" { return true }
        return false
    }

    /// True when `url` is the real data folder or something inside it. The path is compared with links in its folders resolved
    /// (the file itself need not exist) and without regard to case, as on a default macOS volume.
    public static func isRealData(_ url: URL, context: Context) -> Bool {
        let support = URL(fileURLWithPath: context.realHome, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        let base = Self.resolved(support).path.lowercased()
        let path = Self.resolved(url).path.lowercased()
        guard path.hasPrefix(base + "/") else { return false }
        let first = path.dropFirst(base.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return first.hasPrefix(dataFolderPrefix)
    }

    /// Links in the existing part of the path are resolved; the rest (a folder or file not made yet) is kept as it is.
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path) && existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for name in rest { out.appendPathComponent(name) }
        return out
    }

    /// True when a write to `url` must not happen (see the rules above).
    public static func refuses(writingTo url: URL, context: Context = .current) -> Bool {
        guard isRealData(url, context: context) else { return false }
        let env = context.environment
        func set(_ key: String) -> Bool { !(env[key] ?? "").isEmpty }
        if env[testEnvironmentKey] == "1" { return true }
        if context.underXCTest { return true }
        return !isInsideAppBundle(context.executablePath) && !set("CFFIXED_USER_HOME") && !set(appSupportEnvironmentKey)
    }

    /// Throws `Refused` (its text is `refusal`) when a write to `url` must not happen. Call it before every write, rename,
    /// folder creation and lock file under the app's data folder.
    public static func check(writingTo url: URL, context: Context = .current) throws {
        if refuses(writingTo: url, context: context) { throw Refused() }
    }
}
