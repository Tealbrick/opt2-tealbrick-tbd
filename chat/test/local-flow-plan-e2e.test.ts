import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { createLocalConsentStore, decideLocalCall, type LocalTarget } from "../src/main/localConsent.ts";
import type { LocalCard } from "../src/shared/ipc.ts";
import { existsSync } from "node:fs";
import { fakeConnectModel, toolResultTexts, type ModelStep } from "./fixtures/fake-connect-model.ts";
import { ANTHROPIC_KEY, fakeMcpCommand, fakeServer, harness, skip as lcSkip, type Step } from "./fixtures/langchain-harness.ts";

// dev.17 U3, end to end in BOTH harnesses: the scripted model calls Companion's flow_plan_add; the helper side is the real decision
// chain (decideLocalCall) with a fake card. "save" waits for the card (nothing reaches the tool before the answer); "preview" and
// flow_plan_today never ask; Always and Never are remembered; with the consent layer off (Agent SDK, test switch) the same save
// runs without a card, which proves the hook is what stopped it. The Companion CLI is a fake MCP server that echoes its arguments.
// Needs the macOS build output (node scripts/build-tbd.ts); skipped elsewhere.

const out = fileURLToPath(new URL("../out/tbd/", import.meta.url));
const sdkEntry = join(out, "agent.mjs");
const claude = join(out, "claude");
const sdkSkip = !(process.platform === "darwin" && existsSync(sdkEntry) && existsSync(claude)) && "needs the macOS build output (node scripts/build-tbd.ts)";
const relayScript = fileURLToPath(new URL("./fixtures/fake-connect-relay.ts", import.meta.url));
const relayEnv = (dir: string) => ({ PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "", TB_SIGNER_SOCKET: join(dir, "signer.sock"), TB_AGENT_ID: "agt_01JAB3XK7Q9M2Z5R8T4W6Y0C1D" });

const TOOL = "mcp__companion__flow_plan_add";
const TEXT = "09:00-10:00 Write\nTODO Call";
const ECHO = "flow_plan_add result for";

type Answer = "approve" | "deny" | "always" | "never";

/** The helper side: the real decision chain, a card that records itself, answers in order (default deny). */
function helper(dir: string, answers: Answer[], seed?: (store: ReturnType<typeof createLocalConsentStore>) => void) {
  const store = createLocalConsentStore(join(dir, "local-consent.json"));
  seed?.(store);
  const cards: { card: LocalCard; target: LocalTarget }[] = [];
  const asked: { tool: string; input: Record<string, unknown>; check?: boolean }[] = [];
  let next = 0;
  const permission = async (req: { tool: string; detail: string; input: Record<string, unknown>; check?: boolean }) => {
    asked.push({ tool: req.tool, input: req.input, ...(req.check ? { check: true } : {}) });
    const result = await decideLocalCall(req, {
      store, today: () => "2026-10-20",
      policy: () => ({ kind: "ask", folder: null }), writeScope: () => null, checkOnly: req.check === true,
      askPerson: async (card, target) => {
        cards.push({ card, target });
        const a = answers[next++] ?? "deny";
        return { allow: a === "approve" || a === "always", remember: a === "always" || a === "never" };
      },
    });
    return result ?? { allow: true };
  };
  return { store, cards, asked, permission };
}

// ------------------------------------------------------------------ Agent SDK

async function runSdk(inputs: Record<string, unknown>[], answers: Answer[], options: { noConsent?: boolean; seed?: (s: ReturnType<typeof createLocalConsentStore>) => void; tool?: string; fakeTool?: string } = {}) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "tbd-flow-e2e-")));
  const workspace = join(dir, "workspace");
  mkdirSync(workspace, { recursive: true });
  const steps: ModelStep[] = inputs.map((input) => ({ name: options.tool ?? TOOL, input }));
  const model = await fakeConnectModel(steps, "Done.");
  const h = helper(dir, answers, options.seed);
  const agent = createDefaultAgent({
    node: process.execPath, entry: sdkEntry,
    model: async () => ({ model: "claude-test", baseUrl: `http://127.0.0.1:${model.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } }),
    config: async () => ({
      cwd: workspace, stateDir: join(dir, "state"), claudeExecutable: claude,
      companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), options.fakeTool ?? "flow_plan_add"),
      relay: { command: process.execPath, args: [relayScript, join(dir, "relay.log"), ""], env: relayEnv(dir) },
      ...(options.noConsent ? { testNoLocalConsent: true } : {}),
    }),
    permission: h.permission,
  });
  try {
    const result = await agent.sendTurn({ text: "plan my day", onDelta: () => {}, onActivity: () => {} });
    const results = model.seen.length ? toolResultTexts(model.seen.at(-1)!.body) : [];
    return { result, results, ...h, dir };
  } finally {
    agent.stop();
    await model.close();
  }
}

test("Agent SDK: a save waits for the card (day and lines), and Deny keeps the tool from running", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "save", day: "2026-10-21" }], ["deny"]);
  assert.equal(r.cards.length, 1);
  assert.equal(r.cards[0].card.title, "Allow TBD's agent to add lines to your plan for 2026-10-21?");
  assert.equal(r.cards[0].card.dayLine, "Day: 2026-10-21");
  assert.equal(r.cards[0].card.text, TEXT);
  assert.equal(r.cards[0].card.alwaysOffered, true);
  assert.equal(r.cards[0].card.label, "Plan");
  assert.equal(r.cards[0].target.key, "flow:add");
  assert.equal(r.asked.length, 1, "asked once: the hook, not also the SDK's own permission step");
  assert.equal(r.asked[0].tool, TOOL);
  assert.equal(r.asked[0].check, undefined);
  assert.ok(r.results.at(-1)?.includes("The person declined this action."), r.results.join("|"));
  assert.ok(!r.results.some((t) => t.includes(ECHO)), "the tool did not run");
});

test("Agent SDK: Approve runs the tool once and asks once", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "save" }], ["approve"]);
  assert.equal(r.cards.length, 1);
  assert.equal(r.asked.length, 1);
  assert.ok(r.results.at(-1)?.includes(ECHO), r.results.join("|"));
  assert.deepEqual(r.store.list(), []);
});

test("Agent SDK: preview asks nobody and runs", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "preview" }], []);
  assert.deepEqual(r.asked, []);
  assert.equal(r.cards.length, 0);
  assert.ok(r.results.at(-1)?.includes(ECHO), r.results.join("|"));
});

test("Agent SDK: flow_plan_today asks nobody", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{}], [], { tool: "mcp__companion__flow_plan_today", fakeTool: "flow_plan_today" });
  assert.deepEqual(r.asked, []);
  assert.ok(r.results.at(-1)?.includes("flow_plan_today result for"), r.results.join("|"));
});

test("Agent SDK: Always allow is remembered; the next save needs no card", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "save" }, { text: "TODO more", mode: "save" }], ["always"]);
  assert.equal(r.cards.length, 1);
  assert.equal(r.store.decision("flow:add"), "always");
  assert.equal(r.results.filter((t) => t.includes(ECHO)).length, 2, "both ran");
});

test("Agent SDK: Never allow is remembered; the next save is refused without a card; preview still runs", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "save" }, { text: "TODO more", mode: "save" }, { text: TEXT, mode: "preview" }], ["never"]);
  assert.equal(r.cards.length, 1);
  assert.equal(r.store.decision("flow:add"), "never");
  assert.equal(r.results.filter((t) => t.includes("never to allow adding lines to the plan")).length, 2);
  assert.equal(r.results.filter((t) => t.includes(ECHO)).length, 1, "only the preview ran");
});

// NEGATIVE CONTROL: with only the consent layer off, the same save runs with no card. The tests above would also pass if the tool
// could never run; this one shows the hook is what stops it.
test("Agent SDK negative control: with the consent layer off the same save runs without a card", { skip: sdkSkip, timeout: 180_000 }, async () => {
  const r = await runSdk([{ text: TEXT, mode: "save" }], [], { noConsent: true });
  assert.equal(r.cards.length, 0);
  assert.deepEqual(r.asked, []);
  assert.ok(r.results.at(-1)?.includes(ECHO), r.results.join("|"));
});

// ------------------------------------------------------------------ LangChain

const route = (port: number) => ({ harness: "langchain" as const, model: "claude-fake", baseUrl: `http://127.0.0.1:${port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });

function toolResults(body: Record<string, any>): string[] {
  const out: string[] = [];
  for (const m of body.messages ?? []) {
    if (!Array.isArray(m.content)) continue;
    for (const b of m.content) if (b.type === "tool_result") out.push(typeof b.content === "string" ? b.content : (b.content ?? []).map((c: { text?: string }) => c.text ?? "").join(""));
  }
  return out;
}

async function runLangChain(inputs: Record<string, unknown>[], answers: Answer[]) {
  const steps: Step[] = [
    ...inputs.map((input, i) => ({ tool: { id: `toolu_f${i}`, name: TOOL, input } }) as Step),
    { text: ["Done."] },
  ];
  const fake = await fakeServer("anthropic", steps);
  let ref: ReturnType<typeof helper> | null = null;
  const h = harness(fake.port, route(fake.port), (dir) => ({ companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), "flow_plan_add") }), async (req) => {
    ref ??= helper(h.dir, answers);
    return ref.permission(req);
  });
  try {
    await h.agent.sendTurn({ text: "plan my day", onDelta: () => {}, onActivity: () => {} });
    const results = toolResults(fake.seen.at(-1)!.body);
    const used = ref ?? helper(h.dir, answers);
    // Read the rule now: the harness removes its folder (and the rules file in it) in `finally`.
    return { results, helper: used, rule: used.store.decision("flow:add"), offered: fake.seen[0].body.tools.map((x: { name: string }) => x.name) };
  } finally {
    h.agent.stop();
    await fake.close();
    h.cleanup();
  }
}

test("LangChain: the plan tool is offered; a save waits for the card and Deny keeps it from running", { skip: lcSkip, timeout: 120_000 }, async () => {
  const r = await runLangChain([{ text: TEXT, mode: "save", day: "2026-10-21" }], ["deny"]);
  assert.ok(r.offered.includes(TOOL), r.offered.join(","));
  assert.equal(r.helper.cards.length, 1);
  assert.equal(r.helper.cards[0].card.dayLine, "Day: 2026-10-21");
  assert.equal(r.helper.cards[0].card.text, TEXT);
  assert.equal(r.helper.asked[0].tool, TOOL);
  assert.ok(r.results.at(-1)?.includes("The person declined this action."), r.results.join("|"));
  assert.ok(!r.results.some((t) => t.includes(ECHO)));
});

test("LangChain: Approve runs it; preview asks nobody", { skip: lcSkip, timeout: 120_000 }, async () => {
  const yes = await runLangChain([{ text: TEXT, mode: "save" }], ["approve"]);
  assert.equal(yes.helper.cards.length, 1);
  assert.ok(yes.results.at(-1)?.includes(ECHO), yes.results.join("|"));
  const preview = await runLangChain([{ text: TEXT, mode: "preview" }], []);
  assert.deepEqual(preview.helper.asked, []);
  assert.ok(preview.results.at(-1)?.includes(ECHO), preview.results.join("|"));
});

test("LangChain: Always is remembered; Never is remembered and refuses without a card", { skip: lcSkip, timeout: 120_000 }, async () => {
  const always = await runLangChain([{ text: TEXT, mode: "save" }, { text: "TODO more", mode: "save" }], ["always"]);
  assert.equal(always.helper.cards.length, 1);
  assert.equal(always.rule, "always");
  assert.equal(always.results.filter((t) => t.includes(ECHO)).length, 2);
  const never = await runLangChain([{ text: TEXT, mode: "save" }, { text: "TODO more", mode: "save" }], ["never"]);
  assert.equal(never.helper.cards.length, 1);
  assert.equal(never.rule, "never");
  assert.equal(never.results.filter((t) => t.includes("never to allow adding lines to the plan")).length, 2);
  assert.ok(!never.results.some((t) => t.includes(ECHO)));
});
