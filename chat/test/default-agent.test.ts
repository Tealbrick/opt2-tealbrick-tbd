import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";

const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));

test("default agent: allow-listed env with only the model key, events streamed, consent card decides tools", async () => {
  process.env.TBD_FAKE_PORTAL_TOKEN = "tbo_should_not_leak";
  const asks: string[] = [];
  const agent = createDefaultAgent({
    node: process.execPath,
    entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async (r) => { asks.push(r.detail); return { allow: true }; },
  });
  try {
    const deltas: string[] = [];
    const activity: (string | null)[] = [];
    let session = "";
    const r = await agent.sendTurn({ text: "hi", onDelta: (t) => deltas.push(t), onActivity: (l) => activity.push(l), onTurn: (t) => { session = t.sessionId; } });
    const [text, allowed, envJson] = r.reply.split("|");
    assert.equal(text, "hi"); assert.equal(allowed, "true");
    const env = JSON.parse(envJson);
    assert.equal(env.hasKey, true);
    assert.deepEqual(env.leaked, [], "no portal/token variables reach the agent");
    assert.deepEqual(deltas, ["Hello ", "allowed"]);
    assert.deepEqual(asks, ["Run: ls"]);
    assert.equal(session, "sess-1"); assert.equal(r.sessionId, "sess-1");
    assert.deepEqual(activity, ["Thinking"]);
  } finally {
    agent.stop();
    delete process.env.TBD_FAKE_PORTAL_TOKEN;
  }
});

test("a denied tool call is reported back to the agent", async () => {
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: false }),
  });
  try {
    const r = await agent.sendTurn({ text: "x", onDelta: () => {}, onActivity: () => {} });
    assert.equal(r.reply.split("|")[1], "false");
  } finally { agent.stop(); }
});

test("a question from the agent reaches onQuestion and the answer goes back to the agent", async () => {
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: false }),
  });
  try {
    const asked: unknown[] = [];
    const r = await agent.sendTurn({
      text: "ask", onDelta: () => {}, onActivity: () => {},
      onQuestion: (q) => { asked.push(q); agent.answer(q.reqId, { "Which day?": "Yesterday" }); },
    });
    assert.deepEqual(asked, [{ reqId: "q1", questions: [{ question: "Which day?", options: [{ label: "Today" }, { label: "Yesterday" }] }] }]);
    assert.deepEqual(JSON.parse(r.reply), { reqId: "q1", answers: { "Which day?": "Yesterday" } });
  } finally { agent.stop(); }
});

test("a turn without a question handler refuses the question instead of hanging", async () => {
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: false }),
  });
  try {
    const r = await agent.sendTurn({ text: "ask", onDelta: () => {}, onActivity: () => {} });
    assert.deepEqual(JSON.parse(r.reply), { reqId: "q1", answers: null });
  } finally { agent.stop(); }
});

test("attached files cross to the agent process as content blocks", async () => {
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: false }),
  });
  try {
    const content = [{ type: "text" as const, text: "look" }, { type: "document" as const, title: "a.pdf", source: { type: "base64" as const, media_type: "application/pdf" as const, data: "aGk=" } }];
    const r = await agent.sendTurn({ text: "look", content, onDelta: () => {}, onActivity: () => {} });
    assert.deepEqual(JSON.parse(r.reply), content);
  } finally { agent.stop(); }
});

test("stop() while the agent is still starting leaves no orphan process (L3 fix)", async () => {
  let release: () => void = () => {};
  let spawned = 0;
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => { await new Promise<void>((r) => { release = r; }); return { model: "m", apiKey: "sk-test" }; },
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: true }),
    spawnProcess: ((...args: Parameters<typeof spawn>) => { spawned++; return spawn(...args); }) as typeof spawn,
  });
  const turn = agent.sendTurn({ text: "hi", onDelta: () => {}, onActivity: () => {} }).catch((e: Error) => e.message);
  await new Promise((r) => setTimeout(r, 20));
  agent.stop();
  release();
  assert.equal(await turn, "The agent was stopped.");
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(spawned, 0, "no process was started after stop()");
});
