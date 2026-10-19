import Foundation

/// C282 (Martin): "TBD app's functionalities should unlock with what's currently paid for in the portal."
/// The Chat helper reads the workspace's licences and installed apps from Core (chat/src/main/entitlements.ts) and
/// hands this snapshot to the native side (`studio:entitlements`). TBD has no licence logic of its own.

/// An app a TBD function needs. Raw values = product ids of the release index; names = what a locked function shows.
public enum TBDGatedApp: String, CaseIterable, Sendable {
    case connect, inbox, rules, kanban, knowledge, evolution, fleet

    public var displayName: String {
        switch self {
        case .connect: return "Connect"
        case .inbox: return "Operator Inbox"
        case .rules: return "Rules & Approvals"
        case .kanban: return "Task Board"
        case .knowledge: return "Knowledge"
        case .evolution: return "Evolving Workflows"
        case .fleet: return "Governance"
        }
    }
}

/// unlocked = paid, installed and running; install = paid but not running in this workspace; locked = not paid;
/// unknown = the plan could not be read (or had an unexpected shape). Fail-safe (Coordinator, dev.12): unknown never
/// locks a function; Core enforces the plan on every call.
public enum TBDAppAccess: String, Sendable { case unlocked, install, locked, unknown }

public struct TBDEntitlements: Equatable, Sendable {
    public private(set) var apps: [TBDGatedApp: TBDAppAccess]
    /// The workspace the snapshot is for; nil when nobody is signed in or no workspace is selected.
    public let workspace: String?

    /// The plan could not be read: every app unknown (never locked, never shown as paid).
    public static let unknown = TBDEntitlements(apps: Dictionary(uniqueKeysWithValues: TBDGatedApp.allCases.map { ($0, .unknown) }), workspace: nil)

    public init(apps: [TBDGatedApp: TBDAppAccess], workspace: String?) {
        self.apps = apps
        self.workspace = workspace
    }

    /// The helper's snapshot `{ ws, fetchedAt, apps: { rules: { access: "unlocked" }, … } }`; anything else = `.unknown`.
    public init(helperValue: Any?) {
        guard let root = helperValue as? [String: Any], let apps = root["apps"] as? [String: Any] else { self = .unknown; return }
        var parsed: [TBDGatedApp: TBDAppAccess] = [:]
        for (key, value) in apps {
            guard let app = TBDGatedApp(rawValue: key), let entry = value as? [String: Any],
                  let raw = entry["access"] as? String, let access = TBDAppAccess(rawValue: raw) else { continue }
            parsed[app] = access
        }
        self.init(apps: parsed, workspace: root["ws"] as? String)
    }

    /// An app missing from a snapshot is an unexpected shape: unknown, not locked (fail-safe).
    public func access(_ app: TBDGatedApp) -> TBDAppAccess { apps[app] ?? .unknown }

    /// The sentence a locked function shows; nil when the function is available. Same text as the helper.
    public func availability(_ app: TBDGatedApp) -> String? {
        switch access(app) {
        case .unlocked, .unknown: return nil
        case .install: return "Install \(app.displayName) in Portal to use this."
        case .locked: return "Available with \(app.displayName)."
        }
    }
}
