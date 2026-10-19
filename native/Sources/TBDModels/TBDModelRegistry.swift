import Foundation

/// The API style of a model connection.
public enum TBDModelKind: String, Codable, Sendable, CaseIterable {
    case openAICompatible
    case anthropic
}

/// Shared endpoint metadata. The key is stored once per immutable connection ID, in Keychain.
public struct TBDModelConnection: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: String
    public let kind: TBDModelKind
    public init(id: String = UUID().uuidString, name: String, endpoint: String, kind: TBDModelKind = .openAICompatible) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.kind = kind
    }
}

public struct TBDModelRoute: Codable, Equatable, Sendable {
    public let connectionID: String
    public let model: String
    public init(connectionID: String, model: String) { self.connectionID = connectionID; self.model = model }
}

public struct TBDModelRegistryState: Codable, Sendable {
    public var connections: [TBDModelConnection] = []
    public var routes: [String: TBDModelRoute] = [:]
    public init() {}
}

/// A resolved route: everything a client needs to call the model.
public struct TBDModelConfig: Sendable, Equatable {
    public let kind: TBDModelKind
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let isLocal: Bool
    public init(kind: TBDModelKind, baseURL: URL, apiKey: String?, model: String, isLocal: Bool) {
        self.kind = kind; self.baseURL = baseURL; self.apiKey = apiKey; self.model = model; self.isLocal = isLocal
    }
}

public enum TBDModelRegistryError: Error, LocalizedError, Equatable {
    case invalidEndpoint, invalidRoute, immutableEndpoint, unknownTask
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use an HTTPS endpoint, or HTTP on localhost or a private network. URLs must not contain credentials, queries or fragments."
        case .invalidRoute: return "Choose a saved connection and enter a model ID."
        case .immutableEndpoint: return "Create a new connection for a different endpoint. Keys are scoped to the original connection."
        case .unknownTask: return "Unknown model task."
        }
    }
}

/// Tasks that can have a model route. One route per task, no automatic fallback.
public enum TBDModelTask: String, CaseIterable, Sendable {
    /// The default agent (Claude Agent SDK). Needs an Anthropic connection.
    case agent
    /// Text transformations and general Listening AI.
    case general
    /// Optional transcript correction.
    case cleanup
    /// Meeting and transcript summaries.
    case analysis
    /// Companion screen activity analysis (vision-capable model).
    case screen
    /// Flow observer: checks if you work on your plan. Set in Flow › Observer, not in Settings › Models.
    case flow
}

public final class TBDModelRegistry: @unchecked Sendable {
    public static let defaultsKey = "tbd.models.v2"
    public static let keychainService = TBDIdentity.keychainService("models")
    private let defaults: UserDefaults
    private let credentials: TBDSecretStore
    private static let lock = NSLock()

    public init(defaults: UserDefaults = .standard, credentials: TBDSecretStore = TBDKeychainStore(service: TBDModelRegistry.keychainService)) {
        self.defaults = defaults; self.credentials = credentials
    }

    public func load() throws -> TBDModelRegistryState {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return TBDModelRegistryState() }
        return try JSONDecoder().decode(TBDModelRegistryState.self, from: data)
    }

    /// HTTPS anywhere; plain HTTP only for loopback and private-network hosts.
    public static func endpointURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw TBDModelRegistryError.invalidEndpoint }
        guard url.scheme == "https" || (url.scheme == "http" && isPrivateHost(host)) else { throw TBDModelRegistryError.invalidEndpoint }
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) || host.hasSuffix(".local") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
    }

    public func saveConnection(_ connection: TBDModelConnection, apiKey: String?) throws {
        _ = try Self.endpointURL(connection.endpoint)
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TBDModelRegistryError.invalidRoute }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        if let old = state.connections.first(where: { $0.id == connection.id }), old.endpoint != connection.endpoint || old.kind != connection.kind {
            throw TBDModelRegistryError.immutableEndpoint
        }
        if let apiKey, !apiKey.isEmpty { try credentials.set(apiKey, for: connection.id) }
        state.connections.removeAll { $0.id == connection.id }
        state.connections.append(connection)
        defaults.set(try JSONEncoder().encode(state), forKey: Self.defaultsKey)
    }

    public func removeConnection(id: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        state.connections.removeAll { $0.id == id }
        state.routes = state.routes.filter { $0.value.connectionID != id }
        try credentials.remove(id)
        defaults.set(try JSONEncoder().encode(state), forKey: Self.defaultsKey)
    }

    public func assign(_ route: TBDModelRoute?, to task: String) throws {
        guard TBDModelTask(rawValue: task) != nil else { throw TBDModelRegistryError.unknownTask }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        if let route {
            guard state.connections.contains(where: { $0.id == route.connectionID }),
                  !route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TBDModelRegistryError.invalidRoute }
        }
        state.routes[task] = route
        defaults.set(try JSONEncoder().encode(state), forKey: Self.defaultsKey)
    }

    public func configuration(for task: String) throws -> TBDModelConfig? {
        let state = try load()
        guard let route = state.routes[task] else { return nil }
        guard let connection = state.connections.first(where: { $0.id == route.connectionID }) else { throw TBDModelRegistryError.invalidRoute }
        let url = try Self.endpointURL(connection.endpoint)
        return TBDModelConfig(kind: connection.kind, baseURL: url, apiKey: try credentials.get(connection.id),
                              model: route.model, isLocal: Self.isLoopback(url))
    }

    public func configuration(for task: TBDModelTask) throws -> TBDModelConfig? { try configuration(for: task.rawValue) }

    /// Whether a key is stored for a connection (the key itself stays in the Keychain).
    public func hasKey(for connectionID: String) -> Bool { storedKey(for: connectionID) != nil }

    /// The stored key, for a request to that connection's own endpoint only.
    func storedKey(for connectionID: String) -> String? {
        guard let key = (try? credentials.get(connectionID)) ?? nil, !key.isEmpty else { return nil }
        return key
    }
}

/// Per-feature switches for transcript cleanup. Both are off by default.
public enum TBDCleanupPolicy {
    public static let chatKey = "tbd.cleanup.chat"
    public static let voiceNoteKey = "tbd.cleanup.voiceNotes"
    public static func enabled(voiceNote: Bool, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: voiceNote ? voiceNoteKey : chatKey)
    }
}

public enum TBDProductLinks {
    public static let supportKey = "tbd.supportURL"
    public static var website: URL { URL(string: "https://tealbrick.com")! }
    public static func support(defaults: UserDefaults = .standard) -> URL? {
        guard let raw = defaults.string(forKey: supportKey), let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
