import XCTest
@testable import TBDModels

/// TBD's agent route (WP-HARNESS step 1, dev.10): the registry route as before, or a cloud provider (C287 (1)).
final class TBDAgentRouteTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
    private func fixture() -> (TBDModelRegistry, TBDAgentCloudStore) {
        let name = "tbd.tests.agentroute.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let secrets = TBDMemorySecretStore()
        return (TBDModelRegistry(defaults: defaults, credentials: secrets), TBDAgentCloudStore(defaults: defaults, secrets: secrets))
    }

    func testTheRegistryRouteIsUnchanged() throws {
        let (registry, cloud) = fixture()
        XCTAssertThrowsError(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)) { XCTAssertEqual($0 as? TBDAgentModelError, .noModel) }
        try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "sk-test", model: "claude-opus-5-5", registry: registry)
        let route = try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)
        XCTAssertEqual(route.harness, "claude-agent-sdk")
        XCTAssertEqual(route.model, "claude-opus-5-5")
        XCTAssertEqual(route.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(route.environment, [:])
        XCTAssertEqual(route.secrets, ["ANTHROPIC_API_KEY": "sk-test"])
        XCTAssertEqual(route.source, "Anthropic")
    }

    func testBedrockUsesTheAWSChainAndPinsEveryAlias() throws {
        let (registry, cloud) = fixture()
        try cloud.save(TBDAgentCloud(provider: .bedrock, model: "us.anthropic.claude-sonnet-4-6"), key: "")
        XCTAssertThrowsError(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)) {
            XCTAssertEqual($0 as? TBDAgentModelError, .cloudIncomplete("Type the AWS region, for example us-east-1."))
        }
        try cloud.save(TBDAgentCloud(provider: .bedrock, model: "us.anthropic.claude-sonnet-4-6", region: "us-east-1", awsProfile: "work"), key: "")
        let route = try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)
        XCTAssertNil(route.baseURL)
        XCTAssertEqual(route.environment["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(route.environment["AWS_REGION"], "us-east-1")
        XCTAssertEqual(route.environment["AWS_PROFILE"], "work")
        for alias in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
            XCTAssertEqual(route.environment[alias], "us.anthropic.claude-sonnet-4-6")
        }
        XCTAssertEqual(route.secrets, [:], "no key: the AWS chain (profile, SSO) signs")
        XCTAssertEqual(route.source, "Amazon Bedrock")
        // An optional Bedrock API key goes only to its own variable.
        try cloud.save(TBDAgentCloud(provider: .bedrock, model: "m", region: "eu-west-1"), key: " br-key ")
        XCTAssertEqual(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud).secrets, ["AWS_BEARER_TOKEN_BEDROCK": "br-key"])
        // An expired key can be removed: back to the AWS profile.
        try cloud.removeKey(.bedrock)
        XCTAssertFalse(cloud.hasKey(.bedrock))
        XCTAssertEqual(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud).secrets, [:])
    }

    func testVertexNeedsProjectAndRegionAndTakesNoKey() throws {
        let (registry, cloud) = fixture()
        try cloud.save(TBDAgentCloud(provider: .vertex, model: "claude-sonnet-5", region: "us-east5"), key: "ignored")
        XCTAssertThrowsError(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud))
        try cloud.save(TBDAgentCloud(provider: .vertex, model: "claude-sonnet-5", region: "us-east5", project: "p-1"), key: "")
        let route = try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)
        XCTAssertEqual(route.environment["CLAUDE_CODE_USE_VERTEX"], "1")
        XCTAssertEqual(route.environment["ANTHROPIC_VERTEX_PROJECT_ID"], "p-1")
        XCTAssertEqual(route.environment["CLOUD_ML_REGION"], "us-east5")
        XCTAssertEqual(route.secrets, [:])
        XCTAssertFalse(cloud.hasKey(.vertex), "Vertex never stores a typed key")
    }

    func testFoundryNeedsItsKey() throws {
        let (registry, cloud) = fixture()
        try cloud.save(TBDAgentCloud(provider: .foundry, model: "claude-sonnet-5", resource: "my-res"), key: "")
        XCTAssertThrowsError(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)) {
            XCTAssertEqual($0 as? TBDAgentModelError, .cloudIncomplete("Type the Foundry API key."))
            XCTAssertEqual($0.localizedDescription, "TBD's agent cloud setting is not complete. Type the Foundry API key.")
        }
        try cloud.save(TBDAgentCloud(provider: .foundry, model: "claude-sonnet-5", resource: "my-res"), key: "fk")
        let route = try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)
        XCTAssertEqual(route.environment["CLAUDE_CODE_USE_FOUNDRY"], "1")
        XCTAssertEqual(route.environment["ANTHROPIC_FOUNDRY_RESOURCE"], "my-res")
        XCTAssertEqual(route.secrets, ["ANTHROPIC_FOUNDRY_API_KEY": "fk"])
    }

    func testDeactivatingTheCloudGoesBackToTheRegistryRoute() throws {
        let (registry, cloud) = fixture()
        try cloud.save(TBDAgentCloud(provider: .vertex, model: "m", region: "global", project: "p"), key: "")
        XCTAssertEqual(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud).source, "Google Vertex AI")
        cloud.deactivate()
        XCTAssertThrowsError(try TBDAgentModelSetup.resolveRoute(registry, cloud: cloud)) { XCTAssertEqual($0 as? TBDAgentModelError, .noModel) }
        XCTAssertEqual(cloud.load()?.project, "p", "the cloud setting stays for later")
    }
}
