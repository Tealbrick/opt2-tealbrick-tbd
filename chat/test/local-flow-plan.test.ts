import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInteractions } from "../src/agent/harness/langchainTools.ts";
import { flowPlanPreToolUse, LOCAL_HOOK_FAILED_MESSAGE } from "../src/agent/localHook.ts";
import { FLOW_PLAN_ADD_TOOLS, PLAN_LINE, describeToolCall, needsPermission, type AgentToHelper } from "../src/agent/protocol.ts";
import {
  ALWAYS_HINT, FLOW_ADD_KEY, FLOW_ADD_TOOLS, FLOW_CARD_LINES, buildLocalCard, createLocalConsentStore, decideLocalCall, isFlowPlanAdd, isLocalConsentTool,
  localNeverMessage, localTarget, type LocalTarget,
} from "../src/main/localConsent.ts";
import { connectAnswers } from "../src/shared/connectButtons.ts";
import type { LocalCard } from "../src/shared/ipc.ts";

// dev.17 U3: Companion's flow_plan_add (mode "save") writes to the person's plan on this Mac. It asks like the other local actions:
// key `flow:add`, the card shows the day and the first lines, Approve / Deny / Always allow / Never allow. "preview" and
// flow_plan_today are free. The same rule runs in both harnesses (the Agent SDK's PreToolUse hook, LangChain's gate).

const SDK = "mcp__companion__flow_plan_add";
const LC = "companion__flow_plan_add";
const TODAY = "2026-10-20";
const signal = new AbortController().signal;
const temp = (): string => realpathSync(mkdtempSync(join(tmpdir(), "tbd-flow-plan-")));
const nowhere = () => null;
const save = (text: string, extra: Record<string, unknown> = {}) => ({ text, mode: "save", ...extra });

describe("which calls ask", () => {
  test("both names are the plan tool, in the protocol and in the consent module", () => {
    assert.deepEqual([...FLOW_PLAN_ADD_TOOLS], [...FLOW_ADD_TOOLS], "the two lists must agree");
    assert.deepEqual([...FLOW_ADD_TOOLS], [SDK, LC]);
    for (const tool of FLOW_ADD_TOOLS) assert.equal(isFlowPlanAdd(tool), true, tool);
    for (const tool of ["mcp__companion__flow_plan_today", "mcp__companion__get_timeline", "companion__flow_plan_today", "Bash", "mcp__tealbrick__flow_plan_add", "mcp__companion__flow_plan_add2"]) assert.equal(isFlowPlanAdd(tool), false, tool);
    assert.equal(isLocalConsentTool(SDK), false, "the Bash/Write/Web check hook is not the plan hook");
  });

  test("needsPermission: only mode preview (exactly) and the read tool are free", () => {
    for (const tool of [SDK, LC]) {
      assert.equal(needsPermission(tool, { mode: "preview", text: "TODO a" }), false, `${tool} preview`);
      assert.equal(needsPermission(tool, { mode: "save", text: "TODO a" }), true, `${tool} save`);
      assert.equal(needsPermission(tool, { mode: "Preview", text: "TODO a" }), true, "capital letters are not preview");
      assert.equal(needsPermission(tool, { mode: " preview" }), true);
      assert.equal(needsPermission(tool, { text: "TODO a" }), true, "no mode");
      assert.equal(needsPermission(tool, { mode: ["preview"] }), true);
      assert.equal(needsPermission(tool, { mode: null }), true);
      assert.equal(needsPermission(tool, {}), true);
      assert.equal(needsPermission(tool), true, "no input at all");
    }
    for (const tool of ["mcp__companion__flow_plan_today", "mcp__companion__get_timeline", "mcp__listening__search_transcripts", "mcp__tealbrick__memory_search"]) assert.equal(needsPermission(tool, { mode: "save" }), false, tool);
    assert.equal(needsPermission("Bash"), true);
  });

  test("the card detail line and the prompt line", () => {
    assert.equal(describeToolCall(SDK, { text: "TODO a", day: "2026-10-21", mode: "save" }), "Add lines to your plan for 2026-10-21: TODO a");
    assert.equal(describeToolCall(LC, { text: "TODO a", mode: "save" }), "Add lines to your plan: TODO a");
    assert.equal(PLAN_LINE, "To plan the person's day, use flow_plan_today and flow_plan_add (preview first, then save). TBD keeps the plan on this Mac.");
  });

  test("both harnesses carry the same prompt line, and both read needsPermission from the protocol", () => {
    const read = (f: string) => readFileSync(new URL(`../src/agent/${f}`, import.meta.url), "utf8");
    assert.match(read("main.ts"), /\bPLAN_LINE,/, "the Agent SDK prompt");
    assert.match(read("harness/langchain.ts"), /\bPLAN_LINE,/, "the LangChain prompt");
    assert.match(read("harness/langchain.ts"), /createInteractions\(out, \{ needsPermission,/);
    assert.match(read("main.ts"), /flowPlanPreToolUse\(/);
    assert.match(read("main.ts"), /needsPermission\(tool, input\)/);
  });
});

describe("the card", () => {
  const target = (input: Record<string, unknown>, today = () => TODAY): LocalTarget => {
    const t = localTarget(SDK, input, nowhere, today);
    assert.ok(t && "key" in t, JSON.stringify(t));
    return t;
  };

  test("key flow:add; Always is offered; the day and the lines show", () => {
    const t = target(save("09:00-10:00 Write\n  - Scope\nTODO Call", { day: "2026-10-21" }));
    assert.equal(t.kind, "plan");
    assert.equal(t.key, FLOW_ADD_KEY);
    assert.equal(t.key, "flow:add");
    assert.equal(t.alwaysOk, true);
    const card = buildLocalCard(t);
    assert.equal(card.title, "Allow TBD's agent to add lines to your plan for 2026-10-21?");
    assert.equal(card.label, "Plan");
    assert.equal(card.dayLine, "Day: 2026-10-21");
    assert.equal(card.text, "09:00-10:00 Write\n  - Scope\nTODO Call");
    assert.equal(card.cut, undefined);
    assert.equal(card.leavesMac, false);
    assert.equal(card.alwaysOffered, true);
    assert.equal(card.hint, ALWAYS_HINT);
    assert.match(card.scope ?? "", /adding lines to your plan on this Mac/);
    assert.equal(card.note, "The lines are saved on this Mac only. They are not sent to Task Board.");
    assert.deepEqual(connectAnswers(card).map((a) => a.label), ["Approve", "Deny", "Always allow", "Never allow"], "Never is there, and so is Always");
  });

  test("the day defaults to today on this Mac's clock", () => {
    assert.equal(target(save("TODO a")).day, TODAY);
    assert.equal(buildLocalCard(target(save("TODO a"))).dayLine, `Day: ${TODAY}`);
    const real = localTarget(SDK, save("TODO a"), nowhere);
    assert.ok(real && "day" in real);
    assert.match(real.day ?? "", /^\d{4}-\d{2}-\d{2}$/, "without a test clock, the day is this Mac's date");
    assert.equal(target(save("TODO a", { day: null })).day, TODAY);
  });

  test("only the first lines are shown, and the card says how many there are", () => {
    const lines = Array.from({ length: 30 }, (_, i) => `TODO task ${i + 1}`);
    const card = buildLocalCard(target(save(lines.join("\n"))));
    assert.equal(card.text.split("\n").length, FLOW_CARD_LINES);
    assert.equal(card.text.split("\n")[0], "TODO task 1");
    assert.equal(card.cut, `Only the first ${FLOW_CARD_LINES} of 30 lines are shown.`);
    const few = buildLocalCard(target(save("TODO a\n\n\nTODO b\r\nTODO c")));
    assert.equal(few.text, "TODO a\nTODO b\nTODO c", "blank lines are not lines");
    assert.equal(few.cut, undefined);
  });

  test("characters that change how a line reads are removed from the card", () => {
    const card = buildLocalCard(target(save("TODO a ‮txt.exe‬\u0007")));
    assert.equal(card.text, "TODO a txt.exe");
  });

  test("a call TBD cannot name is refused: no lines, a bad day", () => {
    for (const input of [{ mode: "save" }, save("  \n "), save("TODO a", { day: "2026-02-30" }), save("TODO a", { day: "today" }), save("TODO a", { day: 20261020 }), save(5 as unknown as string)]) {
      const t = localTarget(SDK, input, nowhere, () => TODAY);
      assert.ok(t && "refuse" in t && t.refuse.endsWith("."), JSON.stringify(input));
    }
  });

  test("the Never sentence", () => {
    assert.equal(localNeverMessage(target(save("TODO a"))), "The person told TBD never to allow adding lines to the plan.");
  });
});

describe("the helper's decision", () => {
  function rig(answers: { allow: boolean; remember: boolean }[] = []) {
    const dir = temp();
    const store = createLocalConsentStore(join(dir, "local-consent.json"));
    const cards: { card: LocalCard; target: LocalTarget }[] = [];
    let n = 0;
    const deps = {
      store, today: () => TODAY,
      // The plan tool names no file: the file policy must not even be asked.
      policy: () => { throw new Error("the file policy is not for the plan tool"); },
      writeScope: () => { throw new Error("no write scope for the plan tool"); },
      askPerson: async (card: LocalCard, target: LocalTarget) => { cards.push({ card, target }); return answers[n++] ?? { allow: false, remember: false }; },
    };
    return { dir, store, cards, deps, file: join(dir, "local-consent.json") };
  }

  test("preview is automatic: no card, no rule, even with a stored Never", async () => {
    const r = rig();
    r.store.remember("flow:add", "never");
    for (const tool of [SDK, LC]) assert.deepEqual(await decideLocalCall({ tool, input: { text: "TODO a", mode: "preview" } }, r.deps), { allow: true }, tool);
    assert.deepEqual(r.cards, []);
  });

  test("save without a rule shows the card; Approve and Deny count once", async () => {
    const r = rig([{ allow: true, remember: false }, { allow: false, remember: false }]);
    const yes = await decideLocalCall({ tool: SDK, input: save("TODO a") }, r.deps);
    assert.deepEqual(yes, { allow: true });
    const no = await decideLocalCall({ tool: LC, input: save("TODO a") }, r.deps);
    assert.deepEqual(no, { allow: false, message: "The person declined this action." });
    assert.equal(r.cards.length, 2);
    assert.equal(r.cards[0].card.title, `Allow TBD's agent to add lines to your plan for ${TODAY}?`);
    assert.equal(r.store.decision("flow:add"), null, "nothing remembered");
  });

  test("Always allow is remembered: the next save, under either tool name, needs no card", async () => {
    const r = rig([{ allow: true, remember: true }]);
    assert.deepEqual(await decideLocalCall({ tool: SDK, input: save("TODO a") }, r.deps), { allow: true, remember: "always" });
    assert.equal(r.cards.length, 1);
    assert.equal(r.store.decision("flow:add"), "always");
    assert.deepEqual(await decideLocalCall({ tool: LC, input: save("TODO other", { day: "2026-10-25" }) }, r.deps), { allow: true, remember: "always" });
    assert.deepEqual(await decideLocalCall({ tool: SDK, input: save("TODO third") }, r.deps), { allow: true, remember: "always" });
    assert.equal(r.cards.length, 1, "no second card");
    const file = JSON.parse(readFileSync(r.file, "utf8"));
    assert.deepEqual(file.rules.map((x: { key: string; decision: string }) => [x.key, x.decision]), [["flow:add", "always"]]);
  });

  test("Never allow is remembered: the next save is refused without a card, preview still works", async () => {
    const r = rig([{ allow: false, remember: true }]);
    const first = await decideLocalCall({ tool: SDK, input: save("TODO a") }, r.deps);
    assert.deepEqual(first, { allow: false, message: "The person told TBD never to allow adding lines to the plan.", remember: "never" });
    assert.equal(r.store.decision("flow:add"), "never");
    const again = await decideLocalCall({ tool: LC, input: save("TODO a") }, r.deps);
    assert.deepEqual(again, { allow: false, message: "The person told TBD never to allow adding lines to the plan.", remember: "never" });
    assert.equal(r.cards.length, 1);
    assert.equal((await decideLocalCall({ tool: SDK, input: { text: "TODO a", mode: "preview" } }, r.deps))?.allow, true);
  });

  test("a save that cannot be named is refused without a card", async () => {
    const r = rig();
    const none = await decideLocalCall({ tool: SDK, input: { mode: "save" } }, r.deps);
    assert.equal(none?.allow, false);
    assert.match(none?.message ?? "", /did not add anything/);
    assert.deepEqual(r.cards, []);
  });

  test("a mode that is not exactly preview asks, whatever else it says", async () => {
    const r = rig([{ allow: false, remember: false }, { allow: false, remember: false }]);
    for (const mode of ["Preview", "commit", undefined]) await decideLocalCall({ tool: SDK, input: { text: "TODO a", ...(mode ? { mode } : {}) } }, r.deps);
    assert.equal(r.cards.length, 3);
  });

  test("the other local rules are unchanged by the new key", async () => {
    const r = rig();
    r.store.remember("flow:add", "never");
    assert.equal(r.store.decision("shell:ls"), null);
    assert.equal(r.store.list().length, 1);
    assert.equal(r.store.unreadable(), false);
  });
});

describe("Agent SDK: the PreToolUse hook", () => {
  const pre = (tool: string, input: unknown) => ({ hook_event_name: "PreToolUse", tool_name: tool, tool_input: input });
  const allowOut = { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } };

  function hookWith(reply: () => Promise<{ allow: boolean; message?: string }>) {
    const asked: { tool: string; input: Record<string, unknown> }[] = [];
    const hook = flowPlanPreToolUse({ needsAsk: needsPermission, request: async (tool, input) => { asked.push({ tool, input }); return reply(); } });
    return { hook, asked };
  }

  test("a save asks the helper; yes is an explicit allow, no is a deny with the helper's sentence", async () => {
    const yes = hookWith(async () => ({ allow: true }));
    assert.deepEqual(await yes.hook(pre(SDK, save("TODO a")), undefined, { signal }), allowOut);
    assert.deepEqual(yes.asked, [{ tool: SDK, input: save("TODO a") }]);
    const no = hookWith(async () => ({ allow: false, message: "The person told TBD never to allow adding lines to the plan." }));
    assert.deepEqual(await no.hook(pre(SDK, save("TODO a")), undefined, { signal }), {
      hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "The person told TBD never to allow adding lines to the plan." },
    });
    const plain = hookWith(async () => ({ allow: false }));
    assert.equal(((await plain.hook(pre(SDK, save("TODO a")), undefined, { signal })) as { hookSpecificOutput: { permissionDecisionReason: string } }).hookSpecificOutput.permissionDecisionReason, "The person declined this action.");
  });

  test("preview, the read tool, other tools and other events pass without asking", async () => {
    const h = hookWith(async () => ({ allow: false }));
    assert.deepEqual(await h.hook(pre(SDK, { text: "TODO a", mode: "preview" }), undefined, { signal }), {});
    assert.deepEqual(await h.hook(pre("mcp__companion__flow_plan_today", {}), undefined, { signal }), {});
    assert.deepEqual(await h.hook(pre("mcp__companion__get_timeline", {}), undefined, { signal }), {});
    assert.deepEqual(await h.hook({ hook_event_name: "PostToolUse", tool_name: SDK }, undefined, { signal }), {});
    assert.deepEqual(h.asked, []);
  });

  test("fails closed: an error, a bad input shape or a closed pipe is a deny; the test switch skips the ask", async () => {
    const broken = hookWith(async () => { throw new Error("pipe closed"); });
    const out = (await broken.hook(pre(SDK, save("TODO a")), undefined, { signal })) as { hookSpecificOutput: { permissionDecision: string; permissionDecisionReason: string } };
    assert.equal(out.hookSpecificOutput.permissionDecision, "deny");
    assert.equal(out.hookSpecificOutput.permissionDecisionReason, LOCAL_HOOK_FAILED_MESSAGE);
    for (const input of [null, "text", 5, undefined]) {
      const h = hookWith(async () => ({ allow: false, message: "no" }));
      const r = (await h.hook(pre(SDK, input), undefined, { signal })) as { hookSpecificOutput?: { permissionDecision: string } };
      assert.equal(r.hookSpecificOutput?.permissionDecision, "deny", `input ${String(input)} has no mode, so it asks and is refused`);
    }
    const off = flowPlanPreToolUse({ needsAsk: () => true, request: async () => ({ allow: false }), disabled: () => true });
    assert.deepEqual(await off(pre(SDK, save("TODO a")), undefined, { signal }), {});
  });
});

describe("LangChain: the gate", () => {
  function gate() {
    const sent: AgentToHelper[] = [];
    const io = createInteractions((m) => sent.push(m), { needsPermission, describe: describeToolCall });
    return { io, sent };
  }
  const reply = (sent: AgentToHelper[], io: ReturnType<typeof createInteractions>, allow: boolean, message?: string) => {
    const req = sent.at(-1) as Extract<AgentToHelper, { type: "permission_request" }>;
    io.onPermission({ reqId: req.reqId, allow, message });
  };

  test("a save is sent to the helper under its own name with the exact input; the answer decides", async () => {
    for (const tool of [SDK, LC]) {
      const { io, sent } = gate();
      const pending = io.gate("turn-1", tool, save("TODO a", { day: "2026-10-21" }));
      await new Promise((r) => setImmediate(r));
      const req = sent[0] as Extract<AgentToHelper, { type: "permission_request" }>;
      assert.equal(req.type, "permission_request");
      assert.equal(req.tool, tool);
      assert.deepEqual(req.input, save("TODO a", { day: "2026-10-21" }));
      assert.equal(req.check, undefined, "a real ask, not a check");
      reply(sent, io, true);
      assert.deepEqual(await pending, { allow: true, message: undefined });

      const second = gate();
      const denied = second.io.gate("turn-1", tool, save("TODO a"));
      await new Promise((r) => setImmediate(r));
      reply(second.sent, second.io, false, "The person told TBD never to allow adding lines to the plan.");
      assert.deepEqual(await denied, { allow: false, message: "The person told TBD never to allow adding lines to the plan." });
    }
  });

  test("preview and the read tool are free: nothing is sent", async () => {
    const { io, sent } = gate();
    assert.deepEqual(await io.gate("t", SDK, { text: "TODO a", mode: "preview" }), { allow: true });
    assert.deepEqual(await io.gate("t", LC, { text: "TODO a", mode: "preview" }), { allow: true });
    assert.deepEqual(await io.gate("t", "mcp__companion__flow_plan_today", {}), { allow: true });
    assert.deepEqual(sent, []);
  });

  test("a stopped turn says no", async () => {
    const { io } = gate();
    const abort = new AbortController();
    const pending = io.gate("t", SDK, save("TODO a"), abort.signal);
    abort.abort();
    assert.deepEqual(await pending, { allow: false, message: "Turn stopped." });
  });
});
