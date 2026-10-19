import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { createTurnRouter } from "../src/main/turns.ts";
import type { ConnectAsk } from "../src/agent/protocol.ts";

// Holds and the permission plumbing (C280 C11, C4): the agent process's `held` event reaches the turn's callbacks, the turn
// router turns it into the Chat's "Waiting for owner approval" notice with the link the helper built, and a Connect
// permission request carries the agent's ask to the helper and the remembered choice back.

const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
const agentDeps = (permission: Parameters<typeof createDefaultAgent>[0]["permission"]) => ({
  node: process.execPath, entry,
  model: async () => ({ model: "m", apiKey: "sk-test" }),
  config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
  permission,
});

test("a held event from the agent reaches onHeld", async () => {
  const agent = createDefaultAgent(agentDeps(async () => ({ allow: false })));
  try {
    const held: unknown[] = [];
    await agent.sendTurn({ text: "held", onDelta: () => {}, onActivity: () => {}, onHeld: (h) => held.push(h) });
    assert.deepEqual(held, [{ tool: "mcp__tealbrick__connect__tools_call", holdId: "hold_7", expiresAt: "2026-10-20T10:00:00Z" }]);
  } finally { agent.stop(); }
});

test("a Connect permission request carries the agent's ask to the helper; the remembered choice goes back", async () => {
  const seen: { tool: string; connect?: ConnectAsk }[] = [];
  const agent = createDefaultAgent(agentDeps(async (req) => { seen.push({ tool: req.tool, connect: req.connect }); return { allow: false, message: "The person told TBD never to allow GMAIL_SEND_EMAIL for default.", remember: "never" }; }));
  try {
    const r = await agent.sendTurn({ text: "connect", onDelta: () => {}, onActivity: () => {} });
    assert.deepEqual(seen, [{ tool: "mcp__tealbrick__connect__tools_call", connect: { op: "tools_call", tool: "GMAIL_SEND_EMAIL", account: "default", service: "Gmail", effect: "outward" } }]);
    assert.deepEqual(JSON.parse(r.reply), { allow: false, message: "The person told TBD never to allow GMAIL_SEND_EMAIL for default.", remember: "never" });
  } finally { agent.stop(); }
});

test("an old-shape permission request (no connect field) and reply (no remember) still work", async () => {
  const agent = createDefaultAgent(agentDeps(async (req) => { assert.equal("connect" in req, false); return { allow: true }; }));
  try {
    const r = await agent.sendTurn({ text: "x", onDelta: () => {}, onActivity: () => {} });
    assert.equal(r.reply.split("|")[1], "true");
  } finally { agent.stop(); }
});

test("the turn router shows a held Connect call as a notice with the link the helper built", async () => {
  const emitted: { streamId: string; channel: string; payload: Record<string, unknown> }[] = [];
  const router = createTurnRouter({
    agent: () => ({
      answer() {},
      async sendTurn(input) {
        input.onHeld?.({ tool: "mcp__tealbrick__connect__tools_call", holdId: "hold_7", expiresAt: "2026-10-20T10:00:00Z" });
        return { sessionId: "s1", reply: "ok", turnId: "t1" };
      },
    }),
    emit: (streamId, channel, payload) => emitted.push({ streamId, channel, payload }),
    holdUrl: (h) => `https://portal.example/w/ws_1/open?product=connect&path=/holds/${h.holdId}`,
  });
  await router.start({ text: "x", streamId: "s-1" });
  assert.deepEqual(emitted.filter((e) => e.channel === "studio:held"), [
    { streamId: "s-1", channel: "studio:held", payload: { label: "Waiting for owner approval", holdId: "hold_7", url: "https://portal.example/w/ws_1/open?product=connect&path=/holds/hold_7" } },
  ]);
});

test("with no link to build (agent not connected) the notice has no URL", async () => {
  const emitted: { channel: string; payload: Record<string, unknown> }[] = [];
  const router = createTurnRouter({
    agent: () => ({ answer() {}, async sendTurn(input) { input.onHeld?.({ tool: "t", holdId: "h", expiresAt: "e" }); return { sessionId: "s1", reply: "ok", turnId: "t1" }; } }),
    emit: (_s, channel, payload) => emitted.push({ channel, payload }),
    holdUrl: () => null,
  });
  await router.start({ text: "x", streamId: "s-1" });
  assert.equal(emitted.find((e) => e.channel === "studio:held")?.payload.url, null);
});
