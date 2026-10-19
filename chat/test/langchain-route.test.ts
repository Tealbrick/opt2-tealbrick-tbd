import test from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { createDefaultAgent, harnessFor, HARNESSES, langchain, claudeAgentSdk, MODEL_SECRET_NAMES, type AgentRoute } from "../src/main/defaultAgent.ts";
import { MODEL_SECRET_NAMES as AGENT_SECRET } from "../src/agent/modelEnv.ts";
import { disableTracing, TRACING_OFF } from "../src/agent/harness/tracingOff.ts";
import { PROVIDER_KEY_NAME, createChatModel, providerOf } from "../src/agent/harness/langchainModels.ts";

// WP-HARNESS L1: route → process environment and init message of the LangChain adapter, harness selection,
// and the no-telemetry guard. Keys are fake and built at run time from low-entropy parts (gitleaks).

const host = { HOME: "/Users/p", TMPDIR: "/tmp/x", PATH: "/opt/homebrew/bin", TBD_PERSON_TOKEN: "tbo_never", LANGSMITH_API_KEY: "ls", LANGCHAIN_TRACING_V2: "true" } as NodeJS.ProcessEnv;
const ANTHROPIC_KEY = `fake-anthropic-${"ROUTECHECK".repeat(3)}`;
const OPENAI_KEY = `fake-openai-${"ROUTECHECK".repeat(3)}`;
const BASE = { PATH: "/usr/bin:/bin", HOME: "/Users/p", TMPDIR: "/tmp/x" };

test("langchain route: Anthropic passes only its key; nothing else is inherited", () => {
  const route: AgentRoute = { harness: "langchain", model: "claude-sonnet-5", baseUrl: "https://api.anthropic.com", secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } };
  const adapter = harnessFor(route);
  assert.equal(adapter.id, "langchain");
  assert.deepEqual(adapter.processEnv(route, host), { ...BASE, ANTHROPIC_API_KEY: ANTHROPIC_KEY });
  const init = adapter.initModel(route);
  assert.deepEqual(init, { model: "claude-sonnet-5", baseUrl: "https://api.anthropic.com", secretNames: ["ANTHROPIC_API_KEY"] });
  assert.equal(JSON.stringify(init).includes(ANTHROPIC_KEY), false, "the key never travels in the init message");
});

test("langchain route: a local Ollama (Anthropic-style) route keeps its base URL and the placeholder key", () => {
  const route: AgentRoute = { harness: "langchain", model: "gpt-oss:20b", baseUrl: "http://localhost:11434", secretEnv: { ANTHROPIC_API_KEY: "ollama" } };
  assert.deepEqual(langchain.processEnv(route, host), { ...BASE, ANTHROPIC_API_KEY: "ollama" });
  assert.deepEqual(langchain.initModel(route), { model: "gpt-oss:20b", baseUrl: "http://localhost:11434", secretNames: ["ANTHROPIC_API_KEY"] });
});

test("langchain route: an earlier shape (apiKey only) still works for Anthropic", () => {
  const route: AgentRoute = { harness: "langchain", model: "m", apiKey: ANTHROPIC_KEY };
  assert.deepEqual(langchain.processEnv(route, host), { ...BASE, ANTHROPIC_API_KEY: ANTHROPIC_KEY });
});

test("langchain route: OpenAI passes only the OpenAI key and its provider", () => {
  const route: AgentRoute = { harness: "langchain", provider: "openai", model: "gpt-5", baseUrl: "http://127.0.0.1:9", secretEnv: { OPENAI_API_KEY: OPENAI_KEY }, apiKey: ANTHROPIC_KEY };
  const env = langchain.processEnv(route, host);
  assert.deepEqual(env, { ...BASE, OPENAI_API_KEY: OPENAI_KEY });
  assert.equal(env.ANTHROPIC_API_KEY, undefined, "an Anthropic key is not passed to an OpenAI agent");
  const init = langchain.initModel(route);
  assert.deepEqual(init, { model: "gpt-5", provider: "openai", baseUrl: "http://127.0.0.1:9", secretNames: ["OPENAI_API_KEY"] });
  assert.equal(JSON.stringify(init).includes(OPENAI_KEY), false);
});

test("langchain route: nothing from the host, and no LangSmith or LangChain variable, reaches the agent", () => {
  const route: AgentRoute = { harness: "langchain", model: "m", secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } };
  const env = langchain.processEnv(route, host);
  for (const name of Object.keys(env)) assert.equal(/^(LANGSMITH_|LANGCHAIN_)/.test(name), false, `${name} must not be passed`);
  assert.equal(env.TBD_PERSON_TOKEN, undefined);
  assert.deepEqual(Object.keys(env).sort(), ["ANTHROPIC_API_KEY", "HOME", "PATH", "TMPDIR"]);
});

test("langchain route: unknown secret or provider-setting names are refused", () => {
  assert.throws(() => langchain.processEnv({ harness: "langchain", model: "m", secretEnv: { LANGSMITH_API_KEY: "x" } }, host), /unsupported secret setting \(LANGSMITH_API_KEY\)/);
  assert.throws(() => langchain.initModel({ harness: "langchain", model: "m", env: { LANGSMITH_TRACING: "true" } }), /unsupported provider setting \(LANGSMITH_TRACING\)/);
});

test("harness selection: langchain is registered, unknown ids are still refused, the SDK keeps its entry", () => {
  assert.deepEqual(Object.keys(HARNESSES).sort(), ["claude-agent-sdk", "langchain"]);
  assert.throws(() => harnessFor({ harness: "codex-cli", model: "m" }), /not available in this TBD version yet \(codex-cli\)/);
  assert.equal(harnessFor({ model: "m" }), claudeAgentSdk, "no harness = the Agent SDK");
  assert.equal(claudeAgentSdk.entry, undefined, "the SDK adapter has no entry of its own");
  assert.equal(langchain.entry?.("/App/Resources"), join("/App/Resources", "agent-langchain.mjs"));
});

test("harness lists: OPENAI_API_KEY is a secret name in both copies", () => {
  assert.equal(MODEL_SECRET_NAMES.has("OPENAI_API_KEY"), true);
  assert.equal(AGENT_SECRET.has("OPENAI_API_KEY"), true);
  assert.deepEqual([...MODEL_SECRET_NAMES].sort(), [...AGENT_SECRET].sort());
});

test("supervisor: the langchain harness starts agent-langchain.mjs next to the default entry; the SDK starts the default entry", async () => {
  const started: string[][] = [];
  const spawnProcess = ((_node: string, args: string[]) => {
    started.push(args);
    throw new Error("stop here");
  }) as never;
  for (const harness of ["langchain", "claude-agent-sdk"]) {
    const agent = createDefaultAgent({
      node: "node", entry: "/App/Resources/agent.mjs", spawnProcess,
      model: async () => ({ harness, model: "m", secretEnv: { ANTHROPIC_API_KEY: "k" } }),
      config: async () => ({ cwd: "/", stateDir: "/s" }),
      permission: async () => ({ allow: false }),
    });
    await assert.rejects(agent.sendTurn({ text: "hi", onDelta: () => {}, onActivity: () => {} }), /stop here/);
  }
  assert.deepEqual(started, [[join(dirname("/App/Resources/agent.mjs"), "agent-langchain.mjs")], ["/App/Resources/agent.mjs"]]);
});

test("tracing: explicitly off, every other LangSmith / LangChain variable removed", () => {
  const env: NodeJS.ProcessEnv = {
    LANGSMITH_TRACING: "true", LANGSMITH_API_KEY: "x", LANGSMITH_ENDPOINT: "https://e", langsmith_project: "p",
    LANGCHAIN_TRACING_V2: "true", LANGCHAIN_API_KEY: "y", LANGCHAIN_CALLBACKS_BACKGROUND: "true", HOME: "/h",
  };
  disableTracing(env);
  assert.deepEqual(env, { ...TRACING_OFF, HOME: "/h" });
  assert.deepEqual(TRACING_OFF, { LANGSMITH_TRACING: "false", LANGCHAIN_TRACING_V2: "false" });
});

test("tracing: importing tracingOff.ts switches this process off", async () => {
  // tracingOff.ts runs disableTracing() on import; the bundle imports it before any LangChain module.
  assert.equal(process.env.LANGSMITH_TRACING, "false");
  assert.equal(process.env.LANGCHAIN_TRACING_V2, "false");
});

test("models: provider choice and the key name; no key = a plain sentence", () => {
  assert.equal(providerOf({ model: "m" }), "anthropic");
  assert.equal(providerOf({ model: "m", provider: "openai" }), "openai");
  assert.deepEqual(PROVIDER_KEY_NAME, { anthropic: "ANTHROPIC_API_KEY", openai: "OPENAI_API_KEY" });
  assert.throws(() => createChatModel({ model: "m" }, {}), /No model key is set for this agent \(ANTHROPIC_API_KEY\)/);
  assert.throws(() => createChatModel({ model: "m", provider: "openai" }, { ANTHROPIC_API_KEY: ANTHROPIC_KEY }), /\(OPENAI_API_KEY\)/);
  assert.equal(createChatModel({ model: "m" }, { ANTHROPIC_API_KEY: ANTHROPIC_KEY }).provider, "anthropic");
  assert.equal(createChatModel({ model: "m", provider: "openai", baseUrl: "http://127.0.0.1:9" }, { OPENAI_API_KEY: OPENAI_KEY }).provider, "openai");
});
