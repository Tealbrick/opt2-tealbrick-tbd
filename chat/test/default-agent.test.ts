import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
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

const route = async () => ({ model: "m", apiKey: "sk-test" });
const baseDeps = { node: process.execPath, entry, model: route, config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }), permission: async () => ({ allow: false }) };

test("restart() while the old agent is still leaving: a slow turn on the new agent survives the old exit (review #1)", async () => {
  const agent = createDefaultAgent(baseDeps);
  try {
    assert.equal((await agent.sendTurn({ text: "quick", onDelta: () => {}, onActivity: () => {} })).reply, "quick");
    await agent.restart(); // the old process exits 300 ms later
    const started = Date.now();
    const r = await agent.sendTurn({ text: "slow", onDelta: () => {}, onActivity: () => {} });
    assert.equal(r.reply, "slow done");
    assert.ok(Date.now() - started >= 800, "the turn was open while the old process exited");
    assert.equal(agent.running(), true);
  } finally { agent.stop(); }
});

/** A process the test drives by hand: what the supervisor writes arrives in `written`, what the test writes to `stdout` is the agent's output. */
function handProcess() {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const written: Record<string, unknown>[] = [];
  stdin.on("data", (d) => { for (const l of String(d).split("\n").filter(Boolean)) written.push(JSON.parse(l)); });
  const proc = Object.assign(new EventEmitter(), { stdin, stdout, stderr, kill: () => true });
  const say = (m: unknown) => stdout.write(`${JSON.stringify(m)}\n`);
  return { proc, written, say, ready: () => say({ type: "ready" }) };
}
const until = async (fn: () => boolean) => { for (let i = 0; i < 100 && !fn(); i += 1) await new Promise((r) => setTimeout(r, 10)); };

test("lines from a replaced process are ignored (review #6)", async () => {
  const procs = [handProcess(), handProcess()];
  let n = 0;
  const agent = createDefaultAgent({ ...baseDeps, spawnProcess: (() => procs[n++].proc) as unknown as typeof spawn });
  try {
    for (const p of procs) {
      const started = agent.restart(); // the second restart replaces the first process
      await until(() => p.written.some((m) => m.type === "init"));
      p.ready();
      await started;
    }
    const turn = agent.sendTurn({ text: "t", onDelta: () => {}, onActivity: () => {} });
    await until(() => procs[1].written.some((m) => m.type === "turn"));
    const id = String(procs[1].written.find((m) => m.type === "turn")?.id);
    procs[0].say({ type: "done", id, sessionId: "old", reply: "STALE" });
    await new Promise((r) => setTimeout(r, 50));
    procs[1].say({ type: "done", id, sessionId: "new", reply: "FRESH" });
    assert.equal((await turn).reply, "FRESH");
    procs[0].proc.emit("exit", 0); // the old process leaving does not end anything either
  } finally { agent.stop(); }
});

test("restart() tries once more when another stop() ended its start (review #7)", async () => {
  let release: () => void = () => {};
  let calls = 0;
  const agent = createDefaultAgent({
    ...baseDeps,
    model: async () => {
      calls += 1;
      if (calls === 1) await new Promise<void>((r) => { release = r; });
      return { model: "m", apiKey: "sk-test" };
    },
  });
  try {
    const restarting = agent.restart();
    await until(() => calls === 1);
    agent.stop(); // e.g. the workspace changed while the restart was starting
    release();
    await restarting; // would reject with "The agent was stopped." without the retry
    assert.equal(agent.running(), true);
    assert.equal(calls, 2);
  } finally { agent.stop(); }
});

test("restart() does not hide other start errors", async () => {
  const agent = createDefaultAgent({ ...baseDeps, model: async () => { throw new Error("no model"); } });
  await assert.rejects(agent.restart(), /no model/);
});

// ---------------------------------------------------------------- selfTest() (review #2, #8)

async function startedHand(extra: Partial<Parameters<typeof createDefaultAgent>[0]> = {}) {
  const p = handProcess();
  const agent = createDefaultAgent({ ...baseDeps, ...extra, spawnProcess: (() => p.proc) as unknown as typeof spawn });
  return { p, agent, readyWhenAsked: () => until(() => p.written.some((m) => m.type === "init")).then(() => p.ready()) };
}

test("selfTest: the report comes in done.selfTest, not in the reply; the key is scrubbed from it", async () => {
  const key = `fake-key-${"SELFTEST".repeat(3)}`;
  const { p, agent, readyWhenAsked } = await startedHand({ model: async () => ({ model: "m", secretEnv: { ANTHROPIC_API_KEY: key } }) });
  try {
    void readyWhenAsked();
    const result = agent.selfTest();
    await until(() => p.written.some((m) => m.type === "turn"));
    const turn = p.written.find((m) => m.type === "turn") as { id: string; selfTest?: boolean };
    assert.equal(turn.selfTest, true);
    p.say({ type: "done", id: turn.id, sessionId: "s", reply: "OK", selfTest: {
      configured: ["companion", "listening"], loaded: ["companion"], probes: { companion: null, listening: `refused ${key}` },
    } });
    const r = await result;
    assert.equal(r.ok, true);
    assert.equal(r.reply, "OK");
    assert.deepEqual(r.tools, { configured: ["companion", "listening"], loaded: ["companion"], probes: { companion: null, listening: "refused [redacted key]" } });
    assert.equal(JSON.stringify(r).includes(key), false);
  } finally { agent.stop(); }
});

test("selfTest: a harness without a report answers ok with no tools; an agent error is reported, not thrown", async () => {
  const { p, agent, readyWhenAsked } = await startedHand();
  try {
    void readyWhenAsked();
    const first = agent.selfTest();
    await until(() => p.written.some((m) => m.type === "turn"));
    const id1 = String((p.written.find((m) => m.type === "turn") as { id: string }).id);
    p.say({ type: "done", id: id1, sessionId: "s", reply: "OK" });
    assert.deepEqual(await first, { ok: true, reply: "OK" });
    const second = agent.selfTest();
    await until(() => p.written.filter((m) => m.type === "turn").length === 2);
    const id2 = String((p.written.filter((m) => m.type === "turn")[1] as { id: string }).id);
    p.say({ type: "error", id: id2, message: "The key was refused." });
    assert.deepEqual(await second, { ok: false, error: "The key was refused." });
  } finally { agent.stop(); }
});

test("selfTest: on a timeout the turn is cancelled", async () => {
  const { p, agent, readyWhenAsked } = await startedHand();
  try {
    void readyWhenAsked();
    const result = await agent.selfTest(150);
    assert.equal(result.ok, false);
    assert.match(result.error ?? "", /did not answer within/);
    const turn = p.written.find((m) => m.type === "turn") as { id: string };
    await until(() => p.written.some((m) => m.type === "cancel"));
    assert.deepEqual(p.written.find((m) => m.type === "cancel"), { type: "cancel", id: turn.id });
  } finally { agent.stop(); }
});
