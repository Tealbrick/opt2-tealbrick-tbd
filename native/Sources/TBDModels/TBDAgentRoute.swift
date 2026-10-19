import Foundation

/// How TBD's own agent reaches its model (WP-HARNESS step 1, dev.10). The harness is the Claude Agent SDK; its
/// model runs on the person's own Anthropic API key or local model (the "agent" route in TBDModelRegistry), or on
/// a cloud provider the person has (C287 (1): Amazon Bedrock, Google Vertex AI, Microsoft Foundry). Never on a
/// subscription login (C287).
///
/// Environment names from code.claude.com/docs/en/{amazon-bedrock,google-vertex-ai,microsoft-foundry}
/// (fetched 2026-10-19). Credentials stay with the provider's own tools where they exist (AWS profile / SSO,
/// Google Application Default Credentials); TBD stores only what the person types (a Bedrock API key or a
/// Foundry API key), in the Keychain.
public enum TBDAgentCloudProvider: String, Codable, CaseIterable, Sendable {
    case bedrock, vertex, foundry

    public var title: String {
        switch self {
        case .bedrock: "Amazon Bedrock"
        case .vertex: "Google Vertex AI"
        case .foundry: "Microsoft Foundry"
        }
    }

    /// A model id the provider accepts, shown as the start value.
    public var exampleModel: String {
        switch self {
        case .bedrock: "us.anthropic.claude-sonnet-4-6"
        case .vertex: "claude-sonnet-5"
        case .foundry: "claude-sonnet-5"
        }
    }
}

/// The person's cloud setting for TBD's agent. Plain values only; the key (if any) is in the Keychain.
public struct TBDAgentCloud: Codable, Equatable, Sendable {
    public var provider: TBDAgentCloudProvider
    public var model: String
    /// Bedrock: AWS region (e.g. us-east-1). Vertex: CLOUD_ML_REGION (global, eu, us, us-east5…).
    public var region: String
    /// Bedrock: optional AWS profile name (SSO or ~/.aws). Empty = the default chain.
    public var awsProfile: String
    /// Vertex: Google Cloud project id.
    public var project: String
    /// Foundry: the Azure resource name (not the URL).
    public var resource: String

    public init(provider: TBDAgentCloudProvider, model: String = "", region: String = "", awsProfile: String = "",
                project: String = "", resource: String = "") {
        self.provider = provider; self.model = model; self.region = region; self.awsProfile = awsProfile
        self.project = project; self.resource = resource
    }

    /// What is still missing, in plain words; nil when the setting is complete.
    public func missing(hasKey: Bool) -> String? {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if t(model).isEmpty { return "Type the model ID." }
        switch provider {
        case .bedrock:
            if t(region).isEmpty { return "Type the AWS region, for example us-east-1." }
        case .vertex:
            if t(project).isEmpty { return "Type the Google Cloud project ID." }
            if t(region).isEmpty { return "Type the region, for example us-east5 or global." }
        case .foundry:
            if t(resource).isEmpty { return "Type the Foundry resource name." }
            if !hasKey { return "Type the Foundry API key." }
        }
        return nil
    }

    /// The Agent SDK's environment for this provider (no secret). Every model alias is pinned to the chosen model,
    /// so the agent never asks for a model the account has not enabled.
    public var environment: [String: String] {
        let model = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var env = ["ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
                   "ANTHROPIC_DEFAULT_SONNET_MODEL": model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": model]
        let v = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch provider {
        case .bedrock:
            env["CLAUDE_CODE_USE_BEDROCK"] = "1"
            env["AWS_REGION"] = v(region)
            if !v(awsProfile).isEmpty { env["AWS_PROFILE"] = v(awsProfile) }
        case .vertex:
            env["CLAUDE_CODE_USE_VERTEX"] = "1"
            env["ANTHROPIC_VERTEX_PROJECT_ID"] = v(project)
            env["CLOUD_ML_REGION"] = v(region)
        case .foundry:
            env["CLAUDE_CODE_USE_FOUNDRY"] = "1"
            env["ANTHROPIC_FOUNDRY_RESOURCE"] = v(resource)
        }
        return env
    }

    /// The environment name of the person's key for this provider, if it takes one.
    public var secretName: String? {
        switch provider {
        case .bedrock: "AWS_BEARER_TOKEN_BEDROCK"   // optional "Bedrock API key"; else the AWS chain
        case .vertex: nil                           // Google Application Default Credentials
        case .foundry: "ANTHROPIC_FOUNDRY_API_KEY"
        }
    }
}

/// Stores the cloud setting (UserDefaults `tbd.agent.cloud`) and its key (Keychain, the models service).
public struct TBDAgentCloudStore: @unchecked Sendable {
    public static let key = "tbd.agent.cloud"
    /// Which route TBD's agent uses: "cloud" or absent (the registry's "agent" route).
    public static let sourceKey = "tbd.agent.source"
    let defaults: UserDefaults
    let secrets: TBDSecretStore

    public init(defaults: UserDefaults = .standard,
                secrets: TBDSecretStore = TBDKeychainStore(service: TBDModelRegistry.keychainService)) {
        self.defaults = defaults; self.secrets = secrets
    }

    private func secretKey(_ provider: TBDAgentCloudProvider) -> String { "agent-cloud-" + provider.rawValue }

    public func load() -> TBDAgentCloud? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(TBDAgentCloud.self, from: data)
    }

    public var isActive: Bool { defaults.string(forKey: Self.sourceKey) == "cloud" }

    /// Saves the setting, stores a newly typed key, and makes the cloud TBD's agent's route.
    public func save(_ cloud: TBDAgentCloud, key typed: String) throws {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, cloud.secretName != nil { try secrets.set(key, for: secretKey(cloud.provider)) }
        defaults.set(try JSONEncoder().encode(cloud), forKey: Self.key)
        defaults.set("cloud", forKey: Self.sourceKey)
    }

    /// Back to the registry's "agent" route (API key / local model). The cloud setting stays for later.
    public func deactivate() { defaults.removeObject(forKey: Self.sourceKey) }

    public func hasKey(_ provider: TBDAgentCloudProvider) -> Bool { ((try? secrets.get(secretKey(provider))) ?? nil) != nil }
    func key(_ provider: TBDAgentCloudProvider) throws -> String? { try secrets.get(secretKey(provider)) }
}

/// The resolved route the Chat helper starts TBD's agent with.
public struct TBDAgentRoute: Equatable, Sendable {
    /// The harness adapter (WP-HARNESS registry in the helper). Only the Agent SDK exists today.
    public var harness: String
    public var model: String
    /// Anthropic or Anthropic-compatible base URL (registry route); nil for a cloud provider. The helper derives the
    /// gateway settings from it (agent/modelEnv.ts), as before.
    public var baseURL: String?
    /// Plain settings for the agent process (base URL, provider switches, region, model pins).
    public var environment: [String: String]
    /// Secrets for the agent process (the person's own key), by environment name. Never logged.
    public var secrets: [String: String]
    /// For the UI: "Anthropic", "Ollama on this Mac", "Amazon Bedrock"…
    public var source: String

    public static let defaultHarness = "claude-agent-sdk"
}

public extension TBDAgentModelSetup {
    /// TBD's agent's route: the cloud setting when it is active and complete, else the registry's "agent" route
    /// (which throws the "No model set" sentences). Daily's own use of the agent route stays `resolve(_:)`
    /// (Anthropic only), because Daily calls the model itself.
    static func resolveRoute(_ registry: TBDModelRegistry, cloud: TBDAgentCloudStore = TBDAgentCloudStore()) throws -> TBDAgentRoute {
        if cloud.isActive, let setting = cloud.load() {
            let key = try cloud.key(setting.provider)
            if let missing = setting.missing(hasKey: key != nil) {
                throw TBDAgentModelError.cloudIncomplete(missing)
            }
            var secrets: [String: String] = [:]
            if let name = setting.secretName, let key, !key.isEmpty { secrets[name] = key }
            return TBDAgentRoute(harness: TBDAgentRoute.defaultHarness, model: setting.model.trimmingCharacters(in: .whitespacesAndNewlines),
                                 baseURL: nil, environment: setting.environment, secrets: secrets, source: setting.provider.title)
        }
        let config = try resolve(registry)
        let anthropic = config.baseURL.host?.lowercased() == "api.anthropic.com"
        return TBDAgentRoute(harness: TBDAgentRoute.defaultHarness, model: config.model, baseURL: config.baseURL.absoluteString,
                             environment: [:], secrets: ["ANTHROPIC_API_KEY": config.apiKey ?? ""],
                             source: config.isLocal ? "Ollama on this Mac" : (anthropic ? "Anthropic" : "Anthropic-compatible"))
    }
}
