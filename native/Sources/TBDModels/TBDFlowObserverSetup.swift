import Foundation

/// How the Flow observer looks at the screen (DESIGN-FLOW 2.5). Never the Neuu endpoint: every mode uses a TBD model route.
public enum TBDFlowObserverMode: String, Codable, CaseIterable, Sendable {
    /// Apple Vision reads the text of the screen on this Mac. A local text model in Ollama judges it. Nothing leaves the Mac.
    case textLocal
    /// A local vision model in Ollama looks at the screenshot. Nothing leaves the Mac.
    case visionLocal
    /// A saved cloud connection (Anthropic or OpenAI-compatible) gets a screenshot. Only after the person chose it.
    case cloud
}

/// What the model gets to see of the screen.
public enum TBDFlowObserverEvidence: Equatable, Sendable { case text, image }

/// A resolved observer route: ready to call.
public struct TBDFlowObserverRoute: Equatable, Sendable {
    public let mode: TBDFlowObserverMode
    public let config: TBDModelConfig
    public let evidence: TBDFlowObserverEvidence
}

/// Why the observer cannot run. The text is the sentence the Flow page shows.
public enum TBDFlowObserverError: Error, LocalizedError, Equatable {
    case notSetUp
    case ollamaNotRunning
    case modelMissing(String)
    case cloudNeedsConsent
    case cloudNeedsKey
    public var errorDescription: String? {
        switch self {
        case .notSetUp: return "Set up a model for the Flow observer in Flow › Observer."
        case .ollamaNotRunning: return "Ollama is not running on this Mac."
        case .modelMissing(let model): return "The model \"\(model)\" is not downloaded in Ollama. Choose another model in Flow › Observer."
        case .cloudNeedsConsent: return "The cloud model needs your choice first. Choose Cloud model in Flow › Observer."
        case .cloudNeedsKey: return "The cloud connection has no API key. Add the key in Settings › Models."
        }
    }
}

/// The Flow observer's setup: the mode, the switch, the consent for cloud, and the "flow" model route (C142, Q2).
///
/// - Off until the person turns it on (`watching`).
/// - The local modes use Ollama on this Mac through its OpenAI-compatible API (`http://localhost:11434/v1`, no key).
///   A local mode never resolves to a route that is not on loopback.
/// - The cloud mode resolves only when the person chose it for this connection (`cloudConsentAt`).
public final class TBDFlowObserverSetup: @unchecked Sendable {
    public static let modeKey = "tbd.flow.observer.mode"
    public static let watchingKey = "tbd.flow.observer.on"
    public static let cloudConsentKey = "tbd.flow.observer.cloudConsent"
    static let cloudConsentConnectionKey = "tbd.flow.observer.cloudConsentConnection"
    static let textModelKey = "tbd.flow.observer.textModel"
    static let visionModelKey = "tbd.flow.observer.visionModel"

    /// Ollama's OpenAI-compatible API on this Mac.
    public static let ollamaEndpoint = "http://localhost:11434/v1"
    /// Offered for download in "Screenshots, on this Mac".
    public static let defaultVisionModel = "qwen2.5vl:3b"
    public static let visionDownloadSize = "3.2 GB"
    static let connectionName = "Ollama on this Mac (Flow observer)"

    private let registry: TBDModelRegistry
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date

    public init(registry: TBDModelRegistry = TBDModelRegistry(), defaults: UserDefaults = .standard,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry; self.defaults = defaults; self.clock = clock
    }

    // MARK: Stored choices

    /// The chosen mode. The default is text only on this Mac.
    public var mode: TBDFlowObserverMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(TBDFlowObserverMode.init(rawValue:)) ?? .textLocal }
        set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    /// "Watch my screen for focus". Off until the person turns it on (Q2).
    public var watching: Bool {
        get { defaults.bool(forKey: Self.watchingKey) }
        set { defaults.set(newValue, forKey: Self.watchingKey) }
    }

    /// When the person chose the cloud model. Nothing else sets it.
    public var cloudConsentAt: Date? {
        guard let seconds = defaults.object(forKey: Self.cloudConsentKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The connection the consent is for.
    public var cloudConsentConnectionID: String? { defaults.string(forKey: Self.cloudConsentConnectionKey) }

    /// The model last chosen for a local mode, if any.
    public func rememberedModel(for mode: TBDFlowObserverMode) -> String? {
        switch mode {
        case .textLocal: return defaults.string(forKey: Self.textModelKey)
        case .visionLocal: return defaults.string(forKey: Self.visionModelKey)
        case .cloud: return nil
        }
    }

    /// The route the registry holds for the observer (whatever mode it was saved for).
    public func currentRoute() -> (connection: TBDModelConnection, model: String)? {
        guard let state = try? registry.load(), let route = state.routes[TBDModelTask.flow.rawValue],
              let connection = state.connections.first(where: { $0.id == route.connectionID }) else { return nil }
        return (connection, route.model)
    }

    /// Every saved connection, for the cloud picker.
    public func connections() -> [TBDModelConnection] { (try? registry.load().connections) ?? [] }

    // MARK: Choosing

    /// Chooses a local mode with a model from Ollama. Finds or creates the Ollama connection, sets the route and
    /// withdraws the cloud consent.
    public func chooseLocal(_ mode: TBDFlowObserverMode, model: String) throws {
        guard mode != .cloud else { throw TBDFlowObserverError.notSetUp }
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TBDModelRegistryError.invalidRoute }
        let connection = try ollamaConnection()
        try registry.assign(TBDModelRoute(connectionID: connection.id, model: id), to: TBDModelTask.flow.rawValue)
        defaults.set(id, forKey: mode == .textLocal ? Self.textModelKey : Self.visionModelKey)
        self.mode = mode
        withdrawCloudConsent()
    }

    /// The person's tap on "Cloud model": uses a saved connection with a model ID and records the consent for it.
    public func chooseCloud(connectionID: String, model: String) throws {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, connections().contains(where: { $0.id == connectionID }) else { throw TBDModelRegistryError.invalidRoute }
        try registry.assign(TBDModelRoute(connectionID: connectionID, model: id), to: TBDModelTask.flow.rawValue)
        self.mode = .cloud
        defaults.set(clock().timeIntervalSince1970, forKey: Self.cloudConsentKey)
        defaults.set(connectionID, forKey: Self.cloudConsentConnectionKey)
    }

    public func withdrawCloudConsent() {
        defaults.removeObject(forKey: Self.cloudConsentKey)
        defaults.removeObject(forKey: Self.cloudConsentConnectionKey)
    }

    /// The saved Ollama connection for the observer, or a new one (no key).
    @discardableResult
    func ollamaConnection() throws -> TBDModelConnection {
        let known = ["http://localhost:11434/v1", "http://127.0.0.1:11434/v1"]
        if let existing = try registry.load().connections.first(where: {
            $0.kind == .openAICompatible && known.contains(TBDAgentModelSetup.normalized($0.endpoint))
        }) { return existing }
        let connection = TBDModelConnection(name: Self.connectionName, endpoint: Self.ollamaEndpoint, kind: .openAICompatible)
        try registry.saveConnection(connection, apiKey: nil)
        return connection
    }

    // MARK: Defaults for the pickers

    /// The text model to offer first: the agent route's model when that is an Ollama model, else the first installed model
    /// (an embedding model is skipped: it cannot answer).
    public func defaultTextModel(installed: [String]) -> String? {
        if let state = try? registry.load(), let route = state.routes[TBDModelTask.agent.rawValue],
           let connection = state.connections.first(where: { $0.id == route.connectionID }),
           let url = URL(string: connection.endpoint), url.host.map({ ["localhost", "127.0.0.1"].contains($0) }) == true, url.port == 11434 {
            return route.model
        }
        return installed.first { !$0.lowercased().contains("embed") }
    }

    // MARK: Resolve

    /// The route the observer uses now, or the sentence that says why it cannot run.
    public func resolve() throws -> TBDFlowObserverRoute {
        let config: TBDModelConfig
        do {
            guard let found = try registry.configuration(for: .flow) else { throw TBDFlowObserverError.notSetUp }
            config = found
        } catch { throw TBDFlowObserverError.notSetUp }
        switch mode {
        case .textLocal, .visionLocal:
            // Never send a local mode anywhere but this Mac.
            guard config.isLocal, config.kind == .openAICompatible else { throw TBDFlowObserverError.notSetUp }
            return TBDFlowObserverRoute(mode: mode, config: config, evidence: mode == .textLocal ? .text : .image)
        case .cloud:
            guard cloudConsentAt != nil, let routeID = currentRoute()?.connection.id, cloudConsentConnectionID == routeID else {
                throw TBDFlowObserverError.cloudNeedsConsent
            }
            if config.kind == .anthropic, (config.apiKey ?? "").isEmpty { throw TBDFlowObserverError.cloudNeedsKey }
            return TBDFlowObserverRoute(mode: .cloud, config: config, evidence: .image)
        }
    }

    /// Whether the observer's route would leave this Mac (for the labeller and the page).
    public var leavesThisMac: Bool { mode == .cloud }

    // MARK: Ollama on this Mac

    /// Ollama's installed models, or nil when it does not answer.
    public static func installedModels(
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> [String]? {
        guard let (data, response) = try? await transport(TBDAgentModelSetup.ollamaTagsRequest()),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return TBDAgentModelSetup.ollamaModels(from: data)
    }

    /// Checks a local route before the first check: Ollama answers and the model is there. nil = ready (or not local).
    public static func localProblem(
        for route: TBDFlowObserverRoute,
        transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async -> TBDFlowObserverError? {
        guard route.mode != .cloud else { return nil }
        guard let names = await installedModels(transport: transport) else { return .ollamaNotRunning }
        return TBDAgentModelSetup.localModelPresent(route.config.model, in: names) ? nil : .modelMissing(route.config.model)
    }

    // MARK: Words for the page

    /// "Anthropic" for the hosted Anthropic API, "OpenAI" for api.openai.com, else the connection's own name.
    public static func providerName(_ connection: TBDModelConnection) -> String {
        let host = URL(string: connection.endpoint)?.host?.lowercased() ?? ""
        if host == "api.anthropic.com" { return "Anthropic" }
        if host == "api.openai.com" { return "OpenAI" }
        return connection.name
    }

    /// The consent sentence for the cloud choice.
    public static func consentSentence(provider: String) -> String {
        "Every 15 seconds a screenshot goes to \(provider). Use this only if you accept that."
    }
}
