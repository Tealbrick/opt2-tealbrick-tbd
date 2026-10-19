import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { answerAsk, askPerson, setAskWindow } from "../src/main/asks.ts";
import { createLocalConsentStore, decideLocalCall } from "../src/main/localConsent.ts";
import { decide, writeScope, type PolicyContext } from "../src/main/filePolicy.ts";
import type { LocalAsk } from "../src/shared/ipc.ts";

// A reply goes only to the agent process that asked (dev.16 S2), also for the cards of local actions (shell, file write, web).
// The fake agent uses the SAME request id ("p9") in every process: the worst case. The helper side here is the real chain:
// decideLocalCall -> askPerson (asks.ts, the real card channel) -> answerAsk, with a fake window that records the cards.

const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function helper() {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "tbd-local-replies-")));
  const workspace = join(home, "ws");
  mkdirSync(workspace, { recursive: true });
  const ctx: PolicyContext = { home, workspace, tbdData: join(home, "data"), allowed: [] };
  const store = createLocalConsentStore(join(home, "local-consent.json"));
  const sent: { channel: string; payload: any }[] = [];
  setAskWindow({ send: (channel, payload) => { sent.push({ channel, payload }); }, isDestroyed: () => false });
  const cards = () => sent.filter((s) => s.channel === "studio:local-ask").map((s) => s.payload as LocalAsk);
  const permission = (req: { tool: string; input: Record<string, unknown> }, signal?: AbortSignal) =>
    decideLocalCall(req, {
      store, policy: (t, i) => decide(t, i, ctx), writeScope: (t, i) => writeScope(t, i, ctx),
      askPerson: (card) => askPerson({ id: `ask-${cards().length + 1}`, agent: "TBD's agent", action: "run-command", label: card.title, detail: "", local: card }, signal),
    }).then((r) => r ?? { allow: false, message: "not local" });
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: (req, signal) => permission(req, signal),
  });
  return { agent, cards, sent, store };
}

test("a local card of a replaced process closes as denied; its late Approve cannot approve the new process's request with the same id", async () => {
  const h = helper();
  try {
    const turnA = h.agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} }).catch((e: Error) => e.message);
    while (h.cards().length < 1) await sleep(10);
    const cardA = h.cards()[0];
    assert.equal(cardA.local?.text, "npm test", "the local card shows the exact command");
    assert.equal(cardA.local?.alwaysOffered, true);

    await h.agent.restart();
    assert.equal(await turnA, "The agent was stopped.");
    assert.ok(h.sent.some((s) => s.channel === "studio:local-done" && s.payload.id === cardA.id), "the old card is closed");

    const turnB = h.agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} });
    while (h.cards().length < 2) await sleep(10);
    const cardB = h.cards()[1];
    assert.notEqual(cardB.id, cardA.id);

    // The person's late answer to card A (Always allow!) changes nothing: nothing is remembered, B still waits.
    answerAsk(cardA.id, true, true);
    await sleep(150);
    assert.equal(await Promise.race([turnB.then(() => "finished"), sleep(100).then(() => "waiting")]), "waiting", "B waits for its own card");
    assert.deepEqual(h.store.list(), [], "a closed card remembers nothing");

    answerAsk(cardB.id, false, false);
    const result = await turnB;
    assert.equal((JSON.parse(result.reply) as { allow: boolean }).allow, false);
  } finally { h.agent.stop(); setAskWindow(null); }
});

test("stopping the agent closes the open local card as denied and a late Always allow is not remembered", async () => {
  const h = helper();
  try {
    const turn = h.agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} }).catch((e: Error) => e.message);
    while (h.cards().length < 1) await sleep(10);
    const card = h.cards()[0];
    h.agent.stop();
    assert.equal(await turn, "The agent was stopped.");
    assert.ok(h.sent.some((s) => s.channel === "studio:local-done" && s.payload.id === card.id));
    answerAsk(card.id, true, true);
    await sleep(50);
    assert.deepEqual(h.store.list(), []);
  } finally { h.agent.stop(); setAskWindow(null); }
});

test("the card's own process gets its answer, and Always allow is remembered for that process's command", async () => {
  const h = helper();
  try {
    const turn = h.agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} });
    while (h.cards().length < 1) await sleep(10);
    answerAsk(h.cards()[0].id, true, true);
    const result = await turn;
    assert.deepEqual(JSON.parse(result.reply), { allow: true, remember: "always" });
    assert.deepEqual(h.store.list().map((r) => [r.key, r.decision]), [["shell:npm test", "always"]]);
    // the next turn needs no card
    const again = await h.agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} });
    assert.deepEqual(JSON.parse(again.reply), { allow: true, remember: "always" });
    assert.equal(h.cards().length, 1);
  } finally { h.agent.stop(); setAskWindow(null); }
});
