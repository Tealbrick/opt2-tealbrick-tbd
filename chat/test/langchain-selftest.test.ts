import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { ANTHROPIC_KEY, assertEgressOnly, assertNoKey, fakeMcp, fakeServer, harness, script, skip } from "./fixtures/langchain-harness.ts";

// WP-HARNESS L3: the setup's 4 checks run through the supervisor's selfTest() against the BUILT agent-langchain.mjs:
// the process starts (1), the model answers (2) one round trip (3), and the loaded tool families are reported (4).
// A self-test writes no session. Same sandbox and egress evidence as the other LangChain e2e tests.

const route = (port: number) => ({ harness: "langchain" as const, model: "claude-fake", baseUrl: `http://127.0.0.1:${port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });

test("self-test: one round trip, the tool families, no session written", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", "ok");
  const h = harness(fake.port, route(fake.port), (dir) => ({
    listeningCli: script(dir, "tbd-listen", "echo '[]'"),
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search"], env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "", TB_AGENT_ID: "agt_01JAB3XK7Q9M2Z5R8T4W6Y0C1D" } },
  }));
  t.after(async () => { h.agent.stop(); await fake.close(); h.cleanup(); });
  const result = await h.agent.selfTest();
  assert.equal(result.ok, true, result.error);
  assert.ok((result.reply ?? "").length > 0, "the model answered");
  assert.deepEqual([...(result.tools ?? [])].sort(), ["ask_person", "listening", "tealbrick"]);
  assert.deepEqual(h.sessionFiles(), [], "a self-test writes no session");
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("self-test", ANTHROPIC_KEY, JSON.stringify(result), h.raw.stdout, h.raw.stderr);
});

test("self-test: a refused key is reported (never thrown), without the key", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", "unauthorized");
  const h = harness(fake.port, route(fake.port));
  t.after(async () => { h.agent.stop(); await fake.close(); h.cleanup(); });
  const result = await h.agent.selfTest();
  assert.equal(result.ok, false);
  assert.ok((result.error ?? "").length > 0);
  assertNoKey("self-test error", ANTHROPIC_KEY, JSON.stringify(result));
});
