import Foundation
import TBDModels

/// File locations for Listening. Everything lives under one private (0700) root.
public enum TBDListeningPaths {
    /// Overrides the root for tests and tooling.
    public static let rootEnvironmentKey = "TBD_LISTENING_ROOT"

    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment[rootEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TBDIdentity.dataFolder + "/Listening", isDirectory: true)   // <dataFolder>-dev in the DEBUG dev app
    }

    public static var database: URL { root.appendingPathComponent("listening.sqlite") }
    /// Overrides the model folder (tooling that uses a scratch root but the real models).
    public static let modelsEnvironmentKey = "TBD_LISTENING_MODELS"
    public static var models: URL {
        if let override = ProcessInfo.processInfo.environment[modelsEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return root.appendingPathComponent("Models", isDirectory: true)
    }
    public static var voiceNotes: URL { root.appendingPathComponent("VoiceNotes", isDirectory: true) }
    public static var dictations: URL { root.appendingPathComponent("Dictations", isDirectory: true) }
    /// Meeting recordings. A chosen `meetingArtifactsFolder` replaces the default (v1 setting); a test root wins over it.
    public static var meetings: URL {
        let overridden = ProcessInfo.processInfo.environment[rootEnvironmentKey].map { !$0.isEmpty } ?? false
        if !overridden, let path = TBDListeningPreferences().meetingArtifactsFolder { return URL(fileURLWithPath: path, isDirectory: true) }
        return root.appendingPathComponent("Meetings", isDirectory: true)
    }
    public static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(TBDIdentity.folder(TBDIdentity.liveDataFolder + "-listening"), isDirectory: true)
    }

    /// Creates `url` (and parents) with owner-only permissions and returns it.
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Size of a file or directory tree in bytes.
    public static func diskUsage(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map { Int64($0) } ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in walker {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
