import Foundation

/// Which harness runs TBD's agent (WP-HARNESS L3): the Claude Agent SDK (default) or the bundled LangChain agent.
/// The person switches in the setup's "TBD's agent" step; it sticks only when the setup's 4 checks pass.
public enum TBDAgentHarnessKind: String, CaseIterable, Sendable {
    case claudeAgentSDK = "claude-agent-sdk"
    case langchain

    public var title: String { self == .langchain ? "LangChain agent" : "TBD's agent" }
}

/// The LangChain agent's model provider (design: the person's own Anthropic key or Ollama — the registry route — or
/// the person's own OpenAI key). Never a subscription (C287); cloud providers stay with the Agent SDK.
public enum TBDLangChainProvider: String, CaseIterable, Sendable { case anthropic, openai }

/// Stores the harness choice and the LangChain agent's OpenAI setting. Plain values in UserDefaults; the OpenAI key
/// (only what the person typed) in the Keychain, models service.
public struct TBDAgentHarnessStore: @unchecked Sendable {
    public static let harnessKey = "tbd.agent.harness"
    public static let providerKey = "tbd.agent.langchain.provider"
    public static let openAIModelKey = "tbd.agent.openai.model"
    static let openAISecret = "agent-openai"
    let defaults: UserDefaults
    let secrets: TBDSecretStore

    public init(defaults: UserDefaults = .standard,
                secrets: TBDSecretStore = TBDKeychainStore(service: TBDModelRegistry.keychainService)) {
        self.defaults = defaults; self.secrets = secrets
    }

    public var kind: TBDAgentHarnessKind {
        get { TBDAgentHarnessKind(rawValue: defaults.string(forKey: Self.harnessKey) ?? "") ?? .claudeAgentSDK }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.harnessKey) }
    }

    public var provider: TBDLangChainProvider {
        get { TBDLangChainProvider(rawValue: defaults.string(forKey: Self.providerKey) ?? "") ?? .anthropic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.providerKey) }
    }

    public var openAIModel: String {
        get { defaults.string(forKey: Self.openAIModelKey) ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.openAIModelKey) }
    }

    /// Stores a newly typed key (an empty value keeps the stored one).
    public func saveOpenAIKey(_ typed: String) throws {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try secrets.set(key, for: Self.openAISecret) }
    }
    public func removeOpenAIKey() throws { try secrets.remove(Self.openAISecret) }
    public var hasOpenAIKey: Bool { ((try? secrets.get(Self.openAISecret)) ?? nil) != nil }
    func openAIKey() throws -> String? { try secrets.get(Self.openAISecret) }
}
