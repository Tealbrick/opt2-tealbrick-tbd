import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { createInterface } from "node:readline";
import { connectMcp, type McpTool } from "@opt2-tealbrick/bridge";
import {
  ISSUES_LIST_TOOL, ISSUE_COMPLETE_TOOL, ISSUE_GET_TOOL, TASKBOARD_MESSAGES, completeArguments, flowTaskBoardComplete, flowTaskBoardList,
  idempotencyKey, scrubErrorText, type FlowTaskBoardDeps,
} from "../src/main/flowTaskBoard.ts";
import type { AgentConnection } from "../src/main/agentIdentity.ts";

const connection: AgentConnection = {
  connectionId: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", agentId: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0", workspaceId: "ws_01JABCDEFGHJKMNPQRSTVWXYZ0",
  bridgeId: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0", mcpUrl: "https://bridge.example/mcp", tokenEndpoint: "https://bridge.example/oauth/token", thumbprint: "kid1",
};

interface Call { name: string; arguments: Record<string, unknown>; meta?: Record<string, unknown> }

/** A fake relay MCP server over in-process streams: a fixed tool list and scripted tools/call answers. */
function fakeRelay(tools: string[], answer: (call: Call, index: number) => unknown | undefined) {
  const toServer = new PassThrough();
  const toClient = new PassThrough();
  const calls: Call[] = [];
  createInterface({ input: toServer }).on("line", (line) => {
    const m = JSON.parse(line) as { id?: number; method: string; params?: Record<string, unknown> };
    if (typeof m.id !== "number") return;
    const reply = (result: unknown) => toClient.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, result })}\n`);
    if (m.method === "initialize") reply({ protocolVersion: "2025-06-18" });
    else if (m.method === "tools/list") reply({ tools: tools.map((name): McpTool => ({ name, inputSchema: { type: "object" } })) });
    else if (m.method === "tools/call") {
      const call: Call = { name: m.params!.name as string, arguments: m.params!.arguments as Record<string, unknown>, meta: m.params!._meta as Record<string, unknown> | undefined };
      calls.push(call);
      const result = answer(call, calls.length - 1);
      if (result !== undefined) reply(result); // undefined: never answer (timeout case)
    }
  });
  let closed = 0;
  const open: FlowTaskBoardDeps["openRelay"] = async () => {
    const client = connectMcp({ streams: { input: toClient, output: toServer } });
    return { ...client, close: () => { closed += 1; } };
  };
  return { calls, open, closed: () => closed };
}

const issue = (id: string, status: string, extra: Record<string, unknown> = {}) => ({
  id, project: "website", title: `Title ${id}`, summary: `Summary ${id}`, status, priority: "high", ready: status === "todo",
  assignee: { kind: "owner", id: "own_1", name: "Owner" }, goal: null, dependsOn: [], blockedReason: null, result: null,
  documents: [], createdBy: { kind: "owner", id: "own_1", name: "Owner" }, createdAt: "2026-10-19T00:00:00Z", updatedAt: "2026-10-19T00:00:00Z", completedAt: null, template: null, ...extra,
});
const page = (issues: unknown[], cursor: string | null = null) => ({ content: [{ type: "text", text: "{}" }], structuredContent: { issues, cursor } });
const done = { content: [{ type: "text", text: "{}" }], structuredContent: { issue: issue("iss_1", "done"), promoted: [] } };
const held = { content: [{ type: "text", text: "Waiting" }], structuredContent: { status: "held", holdId: "hold_1", expiresAt: new Date(Date.now() + 3_600_000).toISOString(), checkWith: "kanban__tb_hold_status" }, isError: false };
const holdStatus = (status: string) => ({ content: [{ type: "text", text: status }], structuredContent: { status } });
const appError = (code: string, message: string) => ({ content: [{ type: "text", text: "x" }], structuredContent: { error: { code, message, requestId: "r" } }, isError: true });
const deps = (relay: ReturnType<typeof fakeRelay>, extra: Partial<FlowTaskBoardDeps> = {}): FlowTaskBoardDeps => ({ connection: () => connection, openRelay: relay.open, ...extra });

test("tool names follow the bridge rule", () => {
  assert.equal(ISSUES_LIST_TOOL, "kanban__issues_list");
  assert.equal(ISSUE_COMPLETE_TOOL, "kanban__issue_complete");
});

describe("list", () => {
  test("two statuses: in progress first, then todo; owner filter; mapped fields only", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL], (call) =>
      call.arguments.status === "in_progress" ? page([issue("iss_a", "in_progress")]) : page([issue("iss_b", "todo", { priority: "low" })]));
    const result = await flowTaskBoardList(deps(relay));
    assert.equal(result.available, true);
    assert.deepEqual(result.issues, [
      { id: "iss_a", title: "Title iss_a", summary: "Summary iss_a", project: "website", status: "in_progress", priority: "high", ready: false },
      { id: "iss_b", title: "Title iss_b", summary: "Summary iss_b", project: "website", status: "todo", priority: "low", ready: true },
    ]);
    assert.deepEqual(relay.calls.map((c) => c.name), [ISSUES_LIST_TOOL, ISSUES_LIST_TOOL]);
    assert.deepEqual(relay.calls.map((c) => [c.arguments.assignee, c.arguments.status]), [["owner", "in_progress"], ["owner", "todo"]]);
    assert.equal(relay.closed(), 1);
  });

  test("a cursor is followed until the last page", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL], (call) => {
      if (call.arguments.status === "in_progress") return page([]);
      return call.arguments.cursor === "c1" ? page([issue("iss_2", "todo")], "c2")
        : call.arguments.cursor === "c2" ? page([issue("iss_3", "todo")], null)
        : page([issue("iss_1", "todo")], "c1");
    });
    const result = await flowTaskBoardList(deps(relay));
    assert.deepEqual(result.issues.map((i) => i.id), ["iss_1", "iss_2", "iss_3"]);
    assert.deepEqual(relay.calls.filter((c) => c.arguments.status === "todo").map((c) => c.arguments.cursor), [undefined, "c1", "c2"]);
  });

  test("the cap is 200 issues in all; a cursor that repeats stops the loop", async () => {
    const many = (prefix: string, n: number, status: string) => Array.from({ length: n }, (_, i) => issue(`${prefix}${i}`, status));
    const relay = fakeRelay([ISSUES_LIST_TOOL], (call) =>
      call.arguments.status === "in_progress" ? page(many("p", 100, "in_progress"), "same") : page(many("t", 100, "todo"), "more"));
    const result = await flowTaskBoardList(deps(relay));
    assert.equal(result.issues.length, 200);
    assert.equal(result.issues.filter((i) => i.status === "in_progress").length, 100);
    assert.equal(result.issues[0].id, "p0");
    // in_progress: page 1 (cursor "same"), page 2 returns the same cursor, so it stops. todo then fills the rest.
    const inProgressCalls = relay.calls.filter((c) => c.arguments.status === "in_progress").length;
    assert.ok(inProgressCalls <= 2, `repeated cursor must stop the loop (${inProgressCalls})`);
  });

  test("off-shape rows and other statuses are dropped", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL], (call) =>
      call.arguments.status === "in_progress" ? page([issue("iss_ok", "in_progress"), { id: 5 }, null, issue("iss_x", "done"), issue("iss_nt", "in_progress", { title: "  " })]) : page([]));
    const result = await flowTaskBoardList(deps(relay));
    assert.deepEqual(result.issues.map((i) => i.id), ["iss_ok"]);
  });

  test("tool not in the relay's list (not granted): available false with the Task Board sentence, no call", async () => {
    const relay = fakeRelay(["knowledge__recall", "kanban__issue_get"], () => page([]));
    const result = await flowTaskBoardList(deps(relay));
    assert.deepEqual(result, { available: false, reason: "TBD's agent has no Task Board access. In Portal, open your workspace, draw a line from TBD's agent to Task Board, choose Read and work, then press Connect.", issues: [] });
    assert.equal(relay.calls.length, 0);
    assert.equal(relay.closed(), 1);
  });

  test("agent not connected: available false, the relay is never opened", async () => {
    let opened = false;
    const result = await flowTaskBoardList({ connection: () => null, openRelay: async () => { opened = true; throw new Error("unreachable"); } });
    assert.deepEqual(result, { available: false, reason: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect).", issues: [] });
    assert.equal(opened, false);
  });

  test("a grant removed between list and call, a pause, an app error and a hold on the read", async () => {
    await assert.rejects(flowTaskBoardList(deps(fakeRelay([ISSUES_LIST_TOOL], () => appError("unknown_tool", "")))), { message: TASKBOARD_MESSAGES.noGrant });
    await assert.rejects(flowTaskBoardList(deps(fakeRelay([ISSUES_LIST_TOOL], () => appError("paused", "")))), { message: TASKBOARD_MESSAGES.paused });
    await assert.rejects(flowTaskBoardList(deps(fakeRelay([ISSUES_LIST_TOOL], () => appError("internal", "database down")))), { message: "Task Board did not list your issues: database down" });
    await assert.rejects(flowTaskBoardList(deps(fakeRelay([ISSUES_LIST_TOOL], () => held))), { message: TASKBOARD_MESSAGES.listWaiting });
  });

  test("timeout: a call the relay never answers ends with the exact error and closes the client", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL], () => undefined);
    await assert.rejects(flowTaskBoardList(deps(relay, { rpcTimeoutMs: 100 })), { message: "Task Board did not answer in time. Try again." });
    assert.equal(relay.closed(), 1);
  });

  test("Q1: only the list tool is called, never a create tool", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL, "kanban__issue_create"], () => page([]));
    await flowTaskBoardList(deps(relay));
    assert.ok(relay.calls.every((c) => c.name === ISSUES_LIST_TOOL));
  });
});

describe("complete", () => {
  const input = { issue: "iss_1", result: "Done — tracked in TBD Flow, 45 min on plan" };

  test("granted tool: exact name, exact arguments, exact key, returns the new status", async () => {
    const relay = fakeRelay([ISSUE_COMPLETE_TOOL], () => done);
    const result = await flowTaskBoardComplete(input, deps(relay));
    assert.deepEqual(result, { issue: "iss_1", status: "done" });
    assert.equal(relay.calls.length, 1);
    assert.equal(relay.calls[0].name, "kanban__issue_complete");
    assert.deepEqual(relay.calls[0].arguments, { issue: "iss_1", result: "Done — tracked in TBD Flow, 45 min on plan" });
    const key = idempotencyKey(completeArguments(input));
    assert.equal(key, "tbd-flow-iss_1");
    assert.deepEqual(relay.calls[0].meta, { "tealbrick/idempotencyKey": key });
    assert.equal(relay.closed(), 1);
  });

  test("the key is the issue id only: another result text is the same request; the key stays within 8-128 chars", () => {
    const a = idempotencyKey(completeArguments(input));
    assert.equal(a, "tbd-flow-iss_1");
    assert.equal(a, idempotencyKey(completeArguments({ ...input, result: "Done — tracked in TBD Flow, 0 min on plan" })), "a retry with other minutes keeps the key");
    assert.notEqual(a, idempotencyKey(completeArguments({ ...input, issue: "iss_2" })));
    const long = idempotencyKey(completeArguments({ issue: "i".repeat(64), result: "x" }));
    assert.ok(long.length >= 8 && long.length <= 128);
    assert.ok(a.length >= 8);
  });

  test("a retry with another result text sends the same key (the app freezes the text, the key never depends on it)", async () => {
    const relay = fakeRelay([ISSUE_COMPLETE_TOOL], () => done);
    await flowTaskBoardComplete(input, deps(relay));
    await flowTaskBoardComplete({ ...input, result: "Done — tracked in TBD Flow, 99 min on plan" }, deps(relay));
    assert.equal(relay.calls.length, 2);
    assert.deepEqual(relay.calls[0].meta, relay.calls[1].meta);
  });

  test("issue_complete fails because the issue is already done: by code, by text, or by one issue_get read", async () => {
    const byCode = fakeRelay([ISSUE_COMPLETE_TOOL], () => appError("already_done", "x"));
    assert.deepEqual(await flowTaskBoardComplete(input, deps(byCode)), { issue: "iss_1", status: "done" });
    const byText = fakeRelay([ISSUE_COMPLETE_TOOL], () => appError("conflict", "The issue is already done"));
    assert.deepEqual(await flowTaskBoardComplete(input, deps(byText)), { issue: "iss_1", status: "done" });
    assert.equal(byText.calls.length, 1, "the text was enough: no read");

    const byRead = fakeRelay([ISSUE_COMPLETE_TOOL, ISSUE_GET_TOOL], (call) =>
      call.name === ISSUE_GET_TOOL ? { content: [], structuredContent: { issue: issue("iss_1", "done") } } : appError("conflict", "no"));
    assert.deepEqual(await flowTaskBoardComplete(input, deps(byRead)), { issue: "iss_1", status: "done" });
    assert.deepEqual(byRead.calls.map((c) => c.name), [ISSUE_COMPLETE_TOOL, ISSUE_GET_TOOL], "one read, no second complete");
    assert.deepEqual(byRead.calls[1].arguments, { issue: "iss_1" });
  });

  test("a failed complete on an issue that is not done stays an error (read says todo, read missing, read fails)", async () => {
    const notDone = fakeRelay([ISSUE_COMPLETE_TOOL, ISSUE_GET_TOOL], (call) =>
      call.name === ISSUE_GET_TOOL ? { content: [], structuredContent: { issue: issue("iss_1", "todo") } } : appError("internal", "database down"));
    await assert.rejects(flowTaskBoardComplete(input, deps(notDone)), { message: "Task Board did not mark it done: database down" });
    const noRead = fakeRelay([ISSUE_COMPLETE_TOOL], () => appError("internal", "database down"));
    await assert.rejects(flowTaskBoardComplete(input, deps(noRead)), { message: "Task Board did not mark it done: database down" });
    assert.equal(noRead.calls.length, 1);
    const readFails = fakeRelay([ISSUE_COMPLETE_TOOL, ISSUE_GET_TOOL], (call) => (call.name === ISSUE_GET_TOOL ? appError("internal", "x") : appError("internal", "database down")));
    await assert.rejects(flowTaskBoardComplete(input, deps(readFails)), { message: "Task Board did not mark it done: database down" });
  });

  test("input limits: empty issue, empty result, 4000+ characters cut", () => {
    assert.throws(() => completeArguments({ issue: " ", result: "x" }), { code: "input_invalid" });
    assert.throws(() => completeArguments({ issue: "iss_1", result: "  " }), { code: "input_invalid" });
    assert.equal(completeArguments({ issue: "iss_1", result: "y".repeat(5000) }).result.length, 4000);
  });

  test("tool not granted: the Task Board sentence, no call", async () => {
    const relay = fakeRelay([ISSUES_LIST_TOOL], () => done);
    await assert.rejects(flowTaskBoardComplete(input, deps(relay)), { message: TASKBOARD_MESSAGES.noGrant });
    assert.equal(relay.calls.length, 0);
  });

  test("agent not connected: exact message, relay never opened", async () => {
    let opened = false;
    await assert.rejects(
      flowTaskBoardComplete(input, { connection: () => null, openRelay: async () => { opened = true; throw new Error("unreachable"); } }),
      { message: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect)." });
    assert.equal(opened, false);
  });

  test("paused agent and an answer without a status", async () => {
    await assert.rejects(flowTaskBoardComplete(input, deps(fakeRelay([ISSUE_COMPLETE_TOOL], () => appError("paused", "")))), { message: TASKBOARD_MESSAGES.paused });
    await assert.rejects(flowTaskBoardComplete(input, deps(fakeRelay([ISSUE_COMPLETE_TOOL], () => ({ content: [], structuredContent: { promoted: [] } })))), { message: TASKBOARD_MESSAGES.noStatus });
  });

  test("timeout", async () => {
    const relay = fakeRelay([ISSUE_COMPLETE_TOOL], () => undefined);
    await assert.rejects(flowTaskBoardComplete(input, deps(relay, { rpcTimeoutMs: 100 })), { message: "Task Board did not answer in time. Try again." });
    assert.equal(relay.closed(), 1);
  });

  test("app error text is capped and scrubbed (links, token-like runs, home paths)", async () => {
    const fakeToken = ["tb", "k_", "Q".repeat(30)].join("");
    const message = `bad request https://portal.example/a?x=1 token ${fakeToken} at /Users/someone/secret.txt ${"word ".repeat(120)}`;
    const relay = fakeRelay([ISSUE_COMPLETE_TOOL], () => appError("input_invalid", message));
    let thrown: Error | undefined;
    try { await flowTaskBoardComplete(input, deps(relay)); } catch (e) { thrown = e as Error; }
    assert.ok(thrown);
    assert.match(thrown.message, /^Task Board did not mark it done: bad request \[link\] token \[hidden\] at \[path\] word/);
    assert.ok(!thrown.message.includes(fakeToken));
    assert.ok(!thrown.message.includes("portal.example"));
    assert.ok(!thrown.message.includes("/Users/"));
    assert.ok(thrown.message.length <= "Task Board did not mark it done: ".length + 300);
    assert.equal(scrubErrorText("a\n\n  b"), "a b");
  });

  // pollHold waits at least 10 s per check (CLI.md §7); the two hold cases run side by side.
  describe("holds", { concurrency: 2 }, () => {
    test("held → approved: waiting status, then the exact same call and key are repeated once", async () => {
      const relay = fakeRelay([ISSUE_COMPLETE_TOOL], (call, i) => (call.name === "kanban__tb_hold_status" ? holdStatus("approved") : i === 0 ? held : done));
      const status: string[] = [];
      const result = await flowTaskBoardComplete(input, deps(relay, { onStatus: (m) => status.push(m) }));
      assert.deepEqual(result, { issue: "iss_1", status: "done" });
      assert.deepEqual(status, ["Waiting for owner approval"]);
      assert.deepEqual(relay.calls.map((c) => c.name), ["kanban__issue_complete", "kanban__tb_hold_status", "kanban__issue_complete"]);
      assert.deepEqual(relay.calls[1].arguments, { holdId: "hold_1" });
      assert.deepEqual(relay.calls[2].arguments, relay.calls[0].arguments);
      assert.deepEqual(relay.calls[2].meta, relay.calls[0].meta);
    });

    test("held → denied: exact message, no second complete", async () => {
      const relay = fakeRelay([ISSUE_COMPLETE_TOOL], (call) => (call.name === "kanban__tb_hold_status" ? holdStatus("denied") : held));
      await assert.rejects(flowTaskBoardComplete(input, deps(relay)), { message: "The owner declined marking this done on Task Board." });
      assert.deepEqual(relay.calls.map((c) => c.name), ["kanban__issue_complete", "kanban__tb_hold_status"]);
    });
  });

  test("held past the wait limit: still-waiting message (a later tap repeats the same key)", async () => {
    const relay = fakeRelay([ISSUE_COMPLETE_TOOL], () => held);
    await assert.rejects(flowTaskBoardComplete(input, deps(relay, { holdWaitMs: 50 })), {
      message: "Still waiting for owner approval. Mark it done again after the owner approves.",
    });
    assert.equal(relay.calls.length, 1);
  });
});

test("the module's inputs carry no person session: only the connection, a relay opener and progress/timing knobs", () => {
  const d: FlowTaskBoardDeps = { connection: () => connection, openRelay: async () => { throw new Error("x"); } };
  assert.deepEqual(Object.keys(d).sort(), ["connection", "openRelay"]);
});
