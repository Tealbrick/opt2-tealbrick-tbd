import Foundation

/// Where TBD's agent (Claude Agent SDK) gets its model. Local first (C142: TBD's own node prefers local
/// inference): Ollama on this Mac, which speaks the Anthropic Messages API since 0.14. Then hosted Anthropic,
/// then any other Anthropic-compatible endpoint (gateway, LM Studio).
public enum TBDAgentProvider: String, CaseIterable, Sendable {
    case ollama, anthropic, anthropicCompatible

    public var title: String {
        switch self {
        case .ollama: "On this Mac (Ollama)"
        case .anthropic: "Anthropic"
        case .anthropicCompatible: "Anthropic-compatible endpoint"
        }
    }
    /// The fixed endpoint; nil when the person enters one.
    public var fixedEndpoint: String? {
        switch self {
        case .ollama: TBDAgentModelSetup.ollamaEndpoint
        case .anthropic: TBDAgentModelSetup.anthropicEndpoint
        case .anthropicCompatible: nil
        }
    }
    /// The model ID the form prefills.
    public var defaultModel: String { self == .ollama ? TBDAgentModelSetup.defaultLocalModel : TBDAgentModelSetup.defaultModel }
    /// A local server needs no key; TBD stores a placeholder because the agent SDK requires one.
    public var needsKey: Bool { self != .ollama }
}

/// Why TBD's agent cannot answer yet. The texts are what Chat and Settings show.
public enum TBDAgentModelError: Error, LocalizedError, Equatable {
    case noModel, notAnthropic, noKey
    /// The cloud setting for TBD's agent misses a value (the sentence says which).
    case cloudIncomplete(String)
    /// The LangChain agent runs on the person's own key or a local model; cloud providers stay with TBD's agent.
    case cloudNotForLangChain
    /// The LangChain agent's OpenAI setting misses a value (the sentence says which).
    case openAIIncomplete(String)
    public var errorDescription: String? {
        switch self {
        case .noModel: return "No model set for TBD's agent. Set up a model in Settings → Models."
        case .notAnthropic: return "TBD's agent needs an Anthropic connection. Set up a model in Settings → Models."
        case .noKey: return "TBD's agent has no API key. Set up a model in Settings → Models."
        case .cloudIncomplete(let what): return "TBD's agent cloud setting is not complete. \(what)"
        case .cloudNotForLangChain: return "The LangChain agent cannot use a cloud provider. Choose an API key or a model on this Mac, or use TBD's agent."
        case .openAIIncomplete(let what): return "The LangChain agent's OpenAI setting is not complete. \(what)"
        }
    }
}

/// The result of "Test connection".
public enum TBDAgentModelTestResult: Equatable, Sendable {
    case ok
    case badKey
    case unknownModel(String)
    case failed(String)

    public var message: String {
        switch self {
        case .ok: return "Connection works. The key and the model are accepted."
        case .badKey: return "The API key was refused. Check the key and try again."
        case .unknownModel(let model): return "The endpoint does not know the model \"\(model)\". Check the model ID."
        case .failed(let reason): return "The test failed: \(reason)"
        }
    }
    public var isOK: Bool { self == .ok }
}

/// One-form setup for the "agent" route (Settings → Models → TBD agent model): provider, key, model,
/// Test connection, Save. Save reuses a saved connection to the same Anthropic endpoint, so the key stays
/// one Keychain item per endpoint, and assigns the "agent" route.
public enum TBDAgentModelSetup {
    public static let anthropicEndpoint = "https://api.anthropic.com"
    /// Prefilled model ID for hosted Anthropic (the current default Claude model).
    public static let defaultModel = "claude-opus-5-5"
    /// Ollama on this Mac (Anthropic Messages API since Ollama 0.14).
    public static let ollamaEndpoint = "http://localhost:11434"
    /// Prefilled local model: gpt-oss 20B (about 14 GB, native tool calls, Apache-2.0). Needs about 24 GB of memory.
    public static let defaultLocalModel = "gpt-oss:20b"
    /// Stored as the key of a local connection: Ollama ignores it, the agent SDK needs a value.
    static let localKeyPlaceholder = "ollama"
    static let connectionName = "Anthropic (TBD agent)"

    /// The agent route as Chat needs it: an Anthropic connection with a key. Throws the reason it is not ready.
    public static func resolve(_ registry: TBDModelRegistry) throws -> TBDModelConfig {
        guard let config = try registry.configuration(for: .agent) else { throw TBDAgentModelError.noModel }
        guard config.kind == .anthropic else { throw TBDAgentModelError.notAnthropic }
        guard let key = config.apiKey, !key.isEmpty else { throw TBDAgentModelError.noKey }
        return config
    }

    /// What the form shows when it opens: the current agent route, else Anthropic with the default model.
    /// No route yet: the local option first (C142). An existing route is shown as it is (never changed here).
    public static func current(_ registry: TBDModelRegistry) -> (provider: TBDAgentProvider, endpoint: String, model: String, hasKey: Bool) {
        guard let state = try? registry.load(), let route = state.routes[TBDModelTask.agent.rawValue],
              let connection = state.connections.first(where: { $0.id == route.connectionID }), connection.kind == .anthropic else {
            return (.ollama, ollamaEndpoint, defaultLocalModel, false)
        }
        return (provider(for: connection.endpoint), connection.endpoint, route.model, registry.hasKey(for: connection.id))
    }

    static func provider(for endpoint: String) -> TBDAgentProvider {
        switch normalized(endpoint) {
        case anthropicEndpoint: .anthropic
        case ollamaEndpoint, "http://127.0.0.1:11434": .ollama
        default: .anthropicCompatible
        }
    }

    /// Saves the form: finds or creates the Anthropic connection for `endpoint`, stores a new key when one is
    /// given, and sets the "agent" route. A key is required unless the reused connection already holds one.
    @discardableResult
    public static func save(provider: TBDAgentProvider, endpoint: String, apiKey: String, model: String,
                            registry: TBDModelRegistry) throws -> TBDModelConnection {
        let url = normalized(provider.fixedEndpoint ?? endpoint)
        _ = try TBDModelRegistry.endpointURL(url)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw TBDModelRegistryError.invalidRoute }
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty && !provider.needsKey ? localKeyPlaceholder : typed
        let existing = try registry.load().connections.first { $0.kind == .anthropic && normalized($0.endpoint) == url }
        let names: [TBDAgentProvider: String] = [.ollama: "Ollama on this Mac (TBD agent)", .anthropic: connectionName,
                                                 .anthropicCompatible: "Anthropic-compatible (TBD agent)"]
        let connection = existing ?? TBDModelConnection(name: names[provider] ?? connectionName, endpoint: url, kind: .anthropic)
        guard !key.isEmpty || registry.hasKey(for: connection.id) else { throw TBDAgentModelError.noKey }
        try registry.saveConnection(connection, apiKey: key.isEmpty ? nil : key)
        try registry.assign(TBDModelRoute(connectionID: connection.id, model: modelID), to: TBDModelTask.agent.rawValue)
        return connection
    }

    /// The key to test with: the typed one, else the one stored for that endpoint.
    public static func testKey(provider: TBDAgentProvider, endpoint: String, typed: String, registry: TBDModelRegistry) -> String? {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        if !provider.needsKey { return localKeyPlaceholder }
        let url = normalized(provider.fixedEndpoint ?? endpoint)
        guard let connection = (try? registry.load())?.connections.first(where: { $0.kind == .anthropic && normalized($0.endpoint) == url }) else { return nil }
        return registry.storedKey(for: connection.id)   // sent only to that same endpoint
    }

    /// "Test connection": GET /v1/models/{model}. Checks the key and the model ID without spending tokens.
    public static func testRequest(endpoint: String, apiKey: String, model: String) throws -> URLRequest {
        let base = try TBDModelRegistry.endpointURL(normalized(endpoint))
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains("/") else { throw TBDModelRegistryError.invalidRoute }
        var request = URLRequest(url: base.appendingPathComponent("v1/models").appendingPathComponent(id))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// Reads the test response. Only an HTTP 200 counts as working (L27: the exact good outcome).
    public static func interpret(status: Int, body: Data, model: String) -> TBDAgentModelTestResult {
        switch status {
        case 200: return .ok
        case 401, 403: return .badKey
        case 404: return .unknownModel(model.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            return .failed(message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        }
    }

    /// Runs the test. `transport` is replaceable for tests.
    public static func test(endpoint: String, apiKey: String, model: String,
                            transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> TBDAgentModelTestResult {
        do {
            let (data, response) = try await transport(try testRequest(endpoint: endpoint, apiKey: apiKey, model: model))
            return interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, model: model)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Ollama on this Mac

    /// What the form says about the local option before Test connection.
    public enum LocalStatus: Equatable, Sendable {
        /// Ollama does not answer on localhost:11434: install or open it.
        case notRunning
        /// Running, but the model is not downloaded.
        case modelMissing(String)
        case ready
        public var message: String {
            switch self {
            case .notRunning:
                return "Ollama is not running on this Mac. Install it from ollama.com and open it. Then run: ollama pull \(TBDAgentModelSetup.defaultLocalModel). Set its context length to 64k in Ollama's settings. About 24 GB of memory is needed."
            case .modelMissing(let model):
                return "Ollama is running, but the model \"\(model)\" is not downloaded. Run: ollama pull \(model)"
            case .ready:
                return "Ollama is running and the model is downloaded."
            }
        }
    }

    /// Ollama's list of downloaded models (GET /api/tags).
    public static func ollamaTagsRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: ollamaEndpoint + "/api/tags")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        return request
    }

    /// Model names from an /api/tags answer; nil when it is not one.
    public static func ollamaModels(from data: Data) -> [String]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    /// "gpt-oss:20b" matches "gpt-oss:20b"; a name without a tag matches ":latest".
    public static func localModelPresent(_ model: String, in names: [String]) -> Bool {
        let wanted = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = wanted.contains(":") ? wanted : wanted + ":latest"
        return names.contains { $0 == wanted || $0 == full }
    }

    public static func localStatus(model: String,
                                   transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> LocalStatus {
        guard let (data, response) = try? await transport(ollamaTagsRequest()),
              (response as? HTTPURLResponse)?.statusCode == 200, let names = ollamaModels(from: data) else { return .notRunning }
        return localModelPresent(model, in: names) ? .ready : .modelMissing(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "Test connection" for the local option: Ollama's own model list, not /v1/models.
    public static func testResult(_ status: LocalStatus) -> TBDAgentModelTestResult {
        switch status {
        case .ready: .ok
        case .modelMissing(let model): .unknownModel(model)
        case .notRunning: .failed(status.message)
        }
    }

    static func normalized(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
