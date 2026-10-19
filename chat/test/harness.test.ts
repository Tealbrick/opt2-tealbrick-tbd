import test from "node:test";
import assert from "node:assert/strict";
import { claudeAgentSdk, harnessFor, MODEL_PLAIN_NAMES, MODEL_SECRET_NAMES } from "../src/main/defaultAgent.ts";
import { modelEnv, MODEL_PLAIN_NAMES as AGENT_PLAIN, MODEL_SECRET_NAMES as AGENT_SECRET } from "../src/agent/modelEnv.ts";

// WP-HARNESS step 1: the seam. The Agent SDK adapter keeps the earlier behaviour and adds cloud providers (C287 (1)).

const host = { HOME: "/Users/p", TMPDIR: "/tmp/x", TBD_PERSON_TOKEN: "tbo_never", PATH: "/opt/homebrew/bin" } as NodeJS.ProcessEnv;

test("harness: an earlier native route (apiKey only) still starts the Agent SDK with only its key", () => {
  const route = { model: "claude-opus-5-5", baseUrl: "https://api.anthropic.com", apiKey: "sk-1" };
  const adapter = harnessFor(route);
  assert.equal(adapter.id, "claude-agent-sdk");
  assert.deepEqual(adapter.processEnv(route, host), { PATH: "/usr/bin:/bin", HOME: "/Users/p", TMPDIR: "/tmp/x", ANTHROPIC_API_KEY: "sk-1" });
  assert.deepEqual(adapter.initModel(route), { model: "claude-opus-5-5", baseUrl: "https://api.anthropic.com" });
});

test("harness: a Foundry route passes its settings in init and its key only in the agent's environment", () => {
  const route = {
    harness: "claude-agent-sdk", model: "claude-sonnet-5",
    env: { CLAUDE_CODE_USE_FOUNDRY: "1", ANTHROPIC_FOUNDRY_RESOURCE: "res", ANTHROPIC_MODEL: "claude-sonnet-5" },
    secretEnv: { ANTHROPIC_FOUNDRY_API_KEY: "fk" }, apiKey: "",
  };
  const env = claudeAgentSdk.processEnv(route, host);
  assert.equal(env.ANTHROPIC_FOUNDRY_API_KEY, "fk");
  assert.equal(env.ANTHROPIC_API_KEY, undefined);
  assert.equal(env.TBD_PERSON_TOKEN, undefined, "nothing else is inherited");
  const model = claudeAgentSdk.initModel(route);
  assert.deepEqual(model, { model: "claude-sonnet-5", baseUrl: undefined, env: route.env, secretNames: ["ANTHROPIC_FOUNDRY_API_KEY"] });
  assert.equal(JSON.stringify(model).includes("fk"), false, "the key never travels in the init message");
  // In the agent process: settings + the key under its declared name, for the SDK.
  assert.deepEqual(modelEnv(model, { ANTHROPIC_FOUNDRY_API_KEY: "fk", AWS_BEARER_TOKEN_BEDROCK: "other" }), {
    CLAUDE_CODE_USE_FOUNDRY: "1", ANTHROPIC_FOUNDRY_RESOURCE: "res", ANTHROPIC_MODEL: "claude-sonnet-5", ANTHROPIC_FOUNDRY_API_KEY: "fk",
  });
});

test("harness: a Bedrock route on the AWS chain needs no key", () => {
  const route = { model: "us.anthropic.claude-sonnet-4-6", env: { CLAUDE_CODE_USE_BEDROCK: "1", AWS_REGION: "us-east-1", AWS_PROFILE: "work" }, secretEnv: {} };
  assert.deepEqual(claudeAgentSdk.processEnv(route, host), { PATH: "/usr/bin:/bin", HOME: "/Users/p", TMPDIR: "/tmp/x" });
  assert.deepEqual(modelEnv(claudeAgentSdk.initModel(route), {}), { CLAUDE_CODE_USE_BEDROCK: "1", AWS_REGION: "us-east-1", AWS_PROFILE: "work" });
});

test("harness: unknown setting or secret names and unknown harnesses are refused", () => {
  assert.throws(() => claudeAgentSdk.initModel({ model: "m", env: { NODE_OPTIONS: "--require x" } }), /unsupported provider setting \(NODE_OPTIONS\)/);
  assert.throws(() => claudeAgentSdk.processEnv({ model: "m", secretEnv: { TB_PERSON_TOKEN: "x" } }, host), /unsupported secret setting \(TB_PERSON_TOKEN\)/);
  assert.throws(() => harnessFor({ harness: "codex-cli", model: "m" }), /not available in this TBD version yet \(codex-cli\)/);
});

test("model env: the agent drops names outside the fixed lists even if a route carried them", () => {
  assert.deepEqual(modelEnv({ model: "m", env: { CLAUDE_CODE_USE_VERTEX: "1", PATH: "/evil" }, secretNames: ["HOME", "ANTHROPIC_API_KEY"] }, { HOME: "/h", ANTHROPIC_API_KEY: "k" }),
    { CLAUDE_CODE_USE_VERTEX: "1", ANTHROPIC_API_KEY: "k" });
});

test("harness: the helper's and the agent's name lists are the same", () => {
  assert.deepEqual([...MODEL_PLAIN_NAMES].sort(), [...AGENT_PLAIN].sort());
  assert.deepEqual([...MODEL_SECRET_NAMES].sort(), [...AGENT_SECRET].sort());
});
