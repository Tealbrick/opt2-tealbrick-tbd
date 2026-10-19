import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { answerAsk, askPerson, setAskWindow } from "../src/main/asks.ts";
import type { LocalAsk } from "../src/shared/ipc.ts";

// S2: a reply goes only to the agent process that asked. The fake agent (fixtures/fake-agent.ts) uses the SAME request ids in
// every process ("p9", "q1"), the worst case: the ids alone cannot keep two processes apart, so the helper must.

const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
type Decision = { allow: boolean; message?: string; remember?: "always" | "never" };

function deferredPermissions() {
  const open: { resolve(d: Decision): void; signal?: AbortSignal; tool: string }[] = [];
  const permission = (req: { tool: string }, signal?: AbortSignal) => new Promise<Decision>((resolve) => { open.push({ resolve, signal, tool: req.tool }); });
  return { open, permission };
}

const agentWith = (permission: (req: { tool: string; detail: string; input: Record<string, unknown> }, signal?: AbortSignal) => Promise<Decision>) =>
  createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission,
  });

test("S2: answering the card of the old process never approves the new process's request with the same id", async () => {
  const helper = deferredPermissions();
  const agent = agentWith(helper.permission);
  try {
    // Process A asks (id p9) and waits for the person.
    const turnA = agent.sendTurn({ text: "connect", onDelta: () => {}, onActivity: () => {} }).catch((e: Error) => e.message);
    while (helper.open.length < 1) await sleep(10);
    const cardA = helper.open[0];
    assert.equal(cardA.signal?.aborted, false);

    // The agent restarts: process A is gone. Its card is closed as denied (the signal aborts), and its turn ends.
    await agent.restart();
    assert.equal(await turnA, "The agent was stopped.");
    assert.equal(cardA.signal?.aborted, true, "the old process's card is closed");

    // Process B asks with the same id p9.
    const turnB = agent.sendTurn({ text: "connect", onDelta: () => {}, onActivity: () => {} });
    while (helper.open.length < 2) await sleep(10);
    const cardB = helper.open[1];
    assert.equal(cardB.signal?.aborted, false);

    // The person answers A's card (Approve) late. B must not be approved by it.
    cardA.resolve({ allow: true });
    await sleep(150);
    const early = await Promise.race([turnB.then(() => "finished"), sleep(100).then(() => "waiting")]);
    assert.equal(early, "waiting", "B is still waiting for its own card");

    // B's own card says Deny: B ends with allow false.
    cardB.resolve({ allow: false, message: "The person declined this action." });
    const result = await turnB;
    assert.equal((JSON.parse(result.reply) as { allow: boolean }).allow, false);
  } finally { agent.stop(); }
});

test("S2: stopping the agent closes every open card of the process as denied", async () => {
  const helper = deferredPermissions();
  const agent = agentWith(helper.permission);
  try {
    const turn = agent.sendTurn({ text: "connect", onDelta: () => {}, onActivity: () => {} }).catch((e: Error) => e.message);
    while (helper.open.length < 1) await sleep(10);
    agent.stop();
    assert.equal(helper.open[0].signal?.aborted, true);
    assert.equal(await turn, "The agent was stopped.");
    helper.open[0].resolve({ allow: true }); // a late answer: nobody is listening, nothing throws
    await sleep(50);
  } finally { agent.stop(); }
});

test("S2: a question of the old process cannot be answered into the new one", async () => {
  const agent = agentWith(async () => ({ allow: false }));
  try {
    const asked: string[] = [];
    const turnA = agent.sendTurn({ text: "ask", onDelta: () => {}, onActivity: () => {}, onQuestion: (q) => { asked.push(q.reqId); } }).catch((e: Error) => e.message);
    while (asked.length < 1) await sleep(10);
    await agent.restart();
    assert.equal(await turnA, "The agent was stopped.");
    // The Chat answers the old card (id q1) now. The new process has not asked anything: the answer is dropped, not delivered
    // (the fake agent would crash on an answer it never asked for).
    agent.answer("q1", { "Which day?": "Yesterday" });
    await sleep(100);
    // The new process asks q1 itself and gets only the answer meant for it.
    const asked2: string[] = [];
    const turnB = agent.sendTurn({ text: "ask", onDelta: () => {}, onActivity: () => {}, onQuestion: (q) => { asked2.push(q.reqId); } });
    while (asked2.length < 1) await sleep(10);
    agent.answer("q1", { "Which day?": "Today" });
    const result = await turnB;
    assert.deepEqual(JSON.parse(result.reply), { reqId: "q1", answers: { "Which day?": "Today" } });
  } finally { agent.stop(); }
});

test("S2: askPerson with an aborted signal closes the card as denied (studio:local-done) and resolves", async () => {
  const sent: { channel: string; payload: unknown }[] = [];
  setAskWindow({ send: (channel, payload) => { sent.push({ channel, payload }); }, isDestroyed: () => false });
  try {
    const ask: LocalAsk = { id: "ask-1", agent: "TBD's agent", action: "connect-call", label: "Allow?", detail: "" };
    const controller = new AbortController();
    const pending = askPerson(ask, controller.signal);
    assert.deepEqual(sent.map((s) => s.channel), ["studio:local-ask"]);
    controller.abort();
    assert.deepEqual(await pending, { allow: false, remember: false });
    assert.deepEqual(sent.map((s) => s.channel), ["studio:local-ask", "studio:local-done"]);
    assert.deepEqual(sent[1].payload, { id: "ask-1" });
    answerAsk("ask-1", true, false); // a late answer from the renderer changes nothing and does not throw
    // an already aborted signal shows no card at all
    sent.length = 0;
    assert.deepEqual(await askPerson({ ...ask, id: "ask-2" }, AbortSignal.abort()), { allow: false, remember: false });
    assert.deepEqual(sent, []);
    // and a card that is answered in time still resolves with the person's answer
    const answered = askPerson({ ...ask, id: "ask-3" }, new AbortController().signal);
    answerAsk("ask-3", true, true);
    assert.deepEqual(await answered, { allow: true, remember: true });
  } finally { setAskWindow(null); }
});
