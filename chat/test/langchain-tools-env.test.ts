import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MODEL_SECRET_NAMES } from "../src/main/defaultAgent.ts";
import { loadMcpServer } from "../src/agent/harness/langchainTools.ts";
import { ANTHROPIC_KEY, OPENAI_KEY, fakeMcp, fakeMcpCommand, fakeServer, harness, readEnv, skip } from "./fixtures/langchain-harness.ts";

// WP-HARNESS L2, the dev.11 rule for the LangChain agent: the person's model key never reaches a child process.
// Fake stdio MCP servers (fixtures/fake-mcp.ts) record the environment they were started with.
//  - End to end: the BUILT agent-langchain.mjs, whose own environment holds the key, starts the Companion and relay
//    servers; the recorded environments must hold no model key (name or value) and the relay must keep its TB_* values.
//  - Negative control: the same check, run on a server started the WRONG way (env = a copy of the agent's own
//    environment), must fail. Without it a check that never looks at the right thing would pass for the wrong reason.

// Production-shaped relay variables, as in agent-shell-env.test.ts.
const RELAY_ENV = {
  PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "",
  TB_SIGNER_SOCKET: "/var/folders/lw/lnvs417x6654wh8s79skzx200000gn/T/tbd-1f0c9e7a2b/signer.sock",
  TB_BRIDGE_URL: "https://bridge-7f3a9c2e.tealbrick.com", TB_CONNECTION_ID: "01928f3e-7c2a-7b4d-9e1f-3a6c8d2b5e70",
  TB_AGENT_ID: "agt_01JAB3XK7Q9M2Z5R8T4W6Y0C1D", TB_BRIDGE_ID: "brg_Zx3Q9vK2mP7tL5nR8wB1cF4hJ6yD0aE3sG9uI2oT5kM",
};
const KEYS = [ANTHROPIC_KEY, OPENAI_KEY];
/** The MCP client adds these names from the agent's own environment under a server's explicit env; macOS adds the last one. */
const CLIENT_DEFAULTS = ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER", "__CF_USER_TEXT_ENCODING"];

/** /bin/sh adds these to anything it starts: the Companion fixture is a shell wrapper (the agent runs `companionCli mcp` as a command). */
const SHELL_ADDED = ["PWD", "SHLVL", "_", "OLDPWD"];

/** The isolation check. `explicit` = the environment the agent configured for this server. */
function assertIsolated(label: string, env: Record<string, string>, explicit: Record<string, string>, shell = false): void {
  for (const name of MODEL_SECRET_NAMES) assert.equal(name in env, false, `${label}: ${name} is set in the child`);
  for (const [name, value] of Object.entries(env)) for (const key of KEYS) assert.equal(value.includes(key), false, `${label}: a model key is the value of ${name}`);
  for (const [name, value] of Object.entries(explicit)) assert.equal(env[name], value, `${label}: ${name} was not kept`);
  const allowed = new Set([...Object.keys(explicit), ...CLIENT_DEFAULTS, ...(shell ? SHELL_ADDED : [])]);
  for (const name of Object.keys(env)) assert.equal(allowed.has(name), true, `${label}: ${name} was inherited from the agent`);
}

test("env isolation e2e: no model key in any MCP child; the relay keeps its TB_* values; Companion gets HOME", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", [{ text: ["ok"] }]);
  const h = harness(fake.port, { harness: "langchain", model: "claude-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } }, (dir) => ({
    companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), "timeline_search"),
    companionDataDir: join(dir, "app-data-dev"), // S8 (dev.17 review): the Companion server learns which app's data folder to use
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search"], env: RELAY_ENV },
  }));
  t.after(() => h.cleanup());
  try {
    await h.agent.sendTurn({ text: "hi", onDelta: () => {}, onActivity: () => {} });
  } finally {
    h.agent.stop();
    await fake.close();
  }
  const companion = join(h.dir, "companion-env.json");
  const relay = join(h.dir, "relay-env.json");
  assert.ok(existsSync(companion) && existsSync(relay), "both servers started and recorded their environment");
  assertIsolated("companion", readEnv(companion), { HOME: process.env.HOME ?? "", TBD_APP_SUPPORT_DIR: join(h.dir, "app-data-dev") }, true);
  assertIsolated("relay", readEnv(relay), RELAY_ENV);
  const relayEnv = readEnv(relay);
  for (const name of Object.keys(RELAY_ENV).filter((n) => n.startsWith("TB_"))) assert.equal(relayEnv[name], RELAY_ENV[name as keyof typeof RELAY_ENV], `relay kept ${name}`);
  assert.equal("TMPDIR" in relayEnv, false, "the agent's TMPDIR is not passed on either");
});

test("env isolation negative control: a server started with a copy of the agent's own environment fails the same check", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tbd-lc-env-"));
  try {
    // What the agent's own environment looks like: PATH, HOME, TMPDIR and the model key.
    const agentEnv = { PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "", TMPDIR: "/tmp/agent", ANTHROPIC_API_KEY: ANTHROPIC_KEY };
    const note: string[] = [];

    // Correct start (what langchain.ts does): explicit env only. The check passes.
    const good = join(dir, "good.json");
    const goodTools = await loadMcpServer({ name: "companion", command: process.execPath, args: [fakeMcp, good, "timeline_search"], env: { HOME: agentEnv.HOME } }, (n) => note.push(n));
    assert.ok(goodTools, note.join("; "));
    try { assertIsolated("good", readEnv(good), { HOME: agentEnv.HOME }); } finally { await goodTools.close(); }

    // Wrong start: env = a copy of process.env of the agent. The very same check must throw.
    const bad = join(dir, "bad.json");
    const badTools = await loadMcpServer({ name: "companion", command: process.execPath, args: [fakeMcp, bad, "timeline_search"], env: { ...agentEnv } }, (n) => note.push(n));
    assert.ok(badTools, note.join("; "));
    try {
      assert.equal(readEnv(bad).ANTHROPIC_API_KEY, ANTHROPIC_KEY, "the control really did hand the key to the child");
      assert.throws(() => assertIsolated("bad", readEnv(bad), { HOME: agentEnv.HOME }), /ANTHROPIC_API_KEY is set in the child/);
    } finally { await badTools.close(); }
  } finally {
    rmSync(dir, { recursive: true, force: true }); // the test's own mkdtemp folder
  }
});

test("env isolation check: a leaked value or an inherited name is caught, even under another name", () => {
  const base = { HOME: "/h" };
  assertIsolated("clean", { HOME: "/h", PATH: "/usr/bin:/bin" }, base);
  assert.throws(() => assertIsolated("value", { HOME: "/h", SOMETHING: `x-${OPENAI_KEY}-y` }, base), /a model key is the value of SOMETHING/);
  assert.throws(() => assertIsolated("name", { HOME: "/h", OPENAI_API_KEY: "k" }, base), /OPENAI_API_KEY is set in the child/);
  assert.throws(() => assertIsolated("tmp", { HOME: "/h", TMPDIR: "/tmp/agent" }, base), /TMPDIR was inherited from the agent/);
  assert.throws(() => assertIsolated("lost", { PATH: "/usr/bin" }, base), /HOME was not kept/);
});
