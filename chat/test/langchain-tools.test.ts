import test from "node:test";
import assert from "node:assert/strict";
import { AIMessage, AIMessageChunk, HumanMessage, type ToolMessage } from "@langchain/core/messages";
import { tool } from "@langchain/core/tools";
import { FakeStreamingChatModel } from "@langchain/core/utils/testing";
import { z } from "zod";
import { LISTENING_TOOLS, listeningFailure } from "../src/agent/listeningDefs.ts";
import { describeToolCall, needsPermission, type AgentQuestion, type AgentToHelper } from "../src/agent/protocol.ts";
import { runTurn, type ChatModelLike } from "../src/agent/harness/langchainGraph.ts";
import { ASK_PERSON, askPersonTool, createInteractions, createToolSeam, listeningTools, loadMcpServer, toolLabel } from "../src/agent/harness/langchainTools.ts";

// WP-HARNESS L2, unit level: the tool seam, the permission and question round trips, Listening tools, MCP failures.

const policy = { needsPermission, describe: describeToolCall };
const aiWithCall = (name: string, args: Record<string, unknown>, id = "t1") => new AIMessage({ content: "", tool_calls: [{ id, name, args, type: "tool_call" }] });
const signal = () => new AbortController().signal;

/** A tool that records its calls. */
function spyTool(name: string, result = "ok") {
  const calls: unknown[] = [];
  const t = tool(async (input: Record<string, unknown>) => { calls.push(input); return result; }, { name, description: `spy ${name}`, schema: z.object({ q: z.string().optional() }) });
  return { t, calls };
}

test("labels: the SDK agent's wording for the three families, ask_person, and the rest", () => {
  assert.equal(toolLabel("mcp__companion__timeline_search"), "Reading your timeline");
  assert.equal(toolLabel("mcp__listening__search_transcripts"), "Reading your transcripts");
  assert.equal(toolLabel("mcp__tealbrick__memory_search"), "Using a Teal Brick app");
  assert.equal(toolLabel(ASK_PERSON), "Asking you a question");
  assert.equal(toolLabel("fake_shell"), "Using fake_shell");
});

test("seam: the three families pass without a consent card; the call runs and returns a tool message", async () => {
  const sent: AgentToHelper[] = [];
  const io = createInteractions((m) => sent.push(m), policy);
  for (const name of ["mcp__companion__timeline_search", "mcp__listening__list_meetings", "mcp__tealbrick__memory_search"]) {
    const spy = spyTool(name, `result of ${name}`);
    const seam = createToolSeam({ tools: [spy.t], gate: (n, i, s) => io.gate("turn1", n, i, s) });
    const { messages } = await seam.run({ messages: [new HumanMessage("x"), aiWithCall(name, { q: "a" })] }, { signal: signal() });
    assert.equal(messages.length, 1);
    assert.equal((messages[0] as ToolMessage).content, `result of ${name}`);
    assert.equal((messages[0] as ToolMessage).tool_call_id, "t1");
    assert.deepEqual(spy.calls, [{ q: "a" }]);
  }
  assert.deepEqual(sent, [], "no permission_request for the harness-local families");
});

test("seam: a gated tool sends permission_request and waits; allow runs it, deny does not", async () => {
  const sent: AgentToHelper[] = [];
  const io = createInteractions((m) => sent.push(m), policy);
  const spy = spyTool("fake_shell", "ran");
  const seam = createToolSeam({ tools: [spy.t], gate: (n, i, s) => io.gate("turn7", n, i, s) });
  const state = { messages: [aiWithCall("fake_shell", { q: "rm -rf /tmp/x" })] };

  const allowed = seam.run(state, { signal: signal() });
  await new Promise((r) => setImmediate(r));
  assert.equal(spy.calls.length, 0, "nothing runs before the person decides");
  assert.equal(sent.length, 1);
  const request = sent[0] as Extract<AgentToHelper, { type: "permission_request" }>;
  assert.deepEqual([request.type, request.id, request.tool, request.input], ["permission_request", "turn7", "fake_shell", { q: "rm -rf /tmp/x" }]);
  assert.match(request.detail, /^fake_shell /, "describeToolCall wording");
  io.onPermission({ reqId: request.reqId, allow: true });
  assert.equal(((await allowed).messages[0] as ToolMessage).content, "ran");
  assert.equal(spy.calls.length, 1);

  const denied = seam.run(state, { signal: signal() });
  await new Promise((r) => setImmediate(r));
  io.onPermission({ reqId: (sent[1] as { reqId: string }).reqId, allow: false, message: "Not that folder." });
  const out = (await denied).messages[0] as ToolMessage;
  assert.equal(out.content, "Not that folder.");
  assert.equal(out.status, "error");
  assert.equal(spy.calls.length, 1, "a denied call never runs");

  const declined = seam.run(state, { signal: signal() });
  await new Promise((r) => setImmediate(r));
  io.onPermission({ reqId: (sent[2] as { reqId: string }).reqId, allow: false });
  assert.equal(((await declined).messages[0] as ToolMessage).content, "The person declined this action.");
});

test("seam: stopping the turn while the consent card is open denies the call", async () => {
  const sent: AgentToHelper[] = [];
  const io = createInteractions((m) => sent.push(m), policy);
  const spy = spyTool("fake_shell");
  const seam = createToolSeam({ tools: [spy.t], gate: (n, i, s) => io.gate("t", n, i, s) });
  const abort = new AbortController();
  const pending = seam.run({ messages: [aiWithCall("fake_shell", {})] }, { signal: abort.signal });
  await new Promise((r) => setImmediate(r));
  abort.abort();
  assert.equal(((await pending).messages[0] as ToolMessage).content, "Turn stopped.");
  assert.equal(spy.calls.length, 0);
});

test("seam: an unknown tool and a tool that throws become tool errors, not a crash", async () => {
  const boom = tool(async () => { throw new Error("disk on fire"); }, { name: "mcp__companion__boom", description: "x", schema: z.object({}) });
  const seam = createToolSeam({ tools: [boom], gate: async () => ({ allow: true }) });
  const { messages } = await seam.run({ messages: [new AIMessage({ content: "", tool_calls: [
    { id: "a", name: "nope", args: {}, type: "tool_call" }, { id: "b", name: "mcp__companion__boom", args: {}, type: "tool_call" },
  ] })] }, { signal: signal() });
  assert.deepEqual(messages.map((m) => [(m as ToolMessage).tool_call_id, (m as ToolMessage).status, m.content]), [
    ["a", "error", "There is no tool named nope."], ["b", "error", "Tool error: disk on fire"],
  ]);
});

test("ask_person: the question goes out in the card shape; the answer comes back keyed by question; null is a plain sentence", async () => {
  const sent: AgentToHelper[] = [];
  const io = createInteractions((m) => sent.push(m), policy);
  const seam = createToolSeam({ tools: [askPersonTool((q, s) => io.ask("turn3", q, s))], gate: (n, i, s) => io.gate("turn3", n, i, s), ungated: new Set([ASK_PERSON]) });
  const questions: AgentQuestion[] = [{ question: "Which day?", header: "Day", options: [{ label: "Mon" }, { label: "Tue", description: "Second" }], multiSelect: false }];
  const state = { messages: [aiWithCall(ASK_PERSON, { questions })] };

  const first = seam.run(state, { signal: signal() });
  await new Promise((r) => setImmediate(r));
  assert.equal(sent.length, 1, "ask_person opens a question card and no consent card");
  const q = sent[0] as Extract<AgentToHelper, { type: "question" }>;
  assert.deepEqual([q.type, q.id, q.questions], ["question", "turn3", questions]);
  io.onAnswer({ reqId: q.reqId, answers: { "Which day?": "Tue" } });
  assert.equal(((await first).messages[0] as ToolMessage).content, JSON.stringify({ "Which day?": "Tue" }));

  const second = seam.run(state, { signal: signal() });
  await new Promise((r) => setImmediate(r));
  io.onAnswer({ reqId: (sent[1] as { reqId: string }).reqId, answers: null });
  assert.equal(((await second).messages[0] as ToolMessage).content, "The person did not answer.");

  // Stopped while the card is open = not answered, and nothing waits forever.
  const abort = new AbortController();
  const waiting = io.ask("turn3", questions, abort.signal);
  abort.abort();
  assert.equal(await waiting, null);
  assert.equal(await io.ask("turn3", questions, abort.signal), null, "an already stopped turn is not asked");
});

test("ask_person: a question with fewer than two options or more than four questions is refused by the schema", async () => {
  const tl = askPersonTool(async () => ({}));
  await assert.rejects(tl.invoke({ questions: [{ question: "q?", options: [{ label: "only" }] }] }));
  await assert.rejects(tl.invoke({ questions: [] }));
});

test("listening tools: the SDK agent's four names, descriptions and arguments, the same CLI calls, the same failure text", async () => {
  assert.deepEqual(LISTENING_TOOLS.map((d) => [d.name, d.description]), [
    ["search_transcripts", "Full-text search over the person's local transcripts and meetings. Returns matches as JSON."],
    ["show_transcript", "The full transcript of one recording by id, with timestamps and speakers, as JSON."],
    ["list_meetings", "Recent meeting recordings (id, title, date, duration) as JSON."],
    ["recent_dictations", "Recent dictations and voice notes."],
  ]);
  const calls: string[][] = [];
  const exec = async (cli: string, args: string[]) => { calls.push([cli, ...args]); return `out ${args[0]}`; };
  const tools = listeningTools(LISTENING_TOOLS, "/bin/tbd-listen", listeningFailure, exec);
  assert.deepEqual(tools.map((t) => t.name), ["mcp__listening__search_transcripts", "mcp__listening__show_transcript", "mcp__listening__list_meetings", "mcp__listening__recent_dictations"]);
  assert.ok(tools.every((t) => !needsPermission(t.name)), "harness-local: the consent rules treat them as before");
  const by = Object.fromEntries(tools.map((t) => [t.name.replace("mcp__listening__", ""), t]));
  assert.equal(await by.search_transcripts.invoke({ query: "--help" }), "out search");
  await by.show_transcript.invoke({ id: "r1" });
  await by.list_meetings.invoke({});
  await by.recent_dictations.invoke({});
  await by.recent_dictations.invoke({ limit: 5 });
  assert.deepEqual(calls, [
    ["/bin/tbd-listen", "search", "--json", "--", "--help"],
    ["/bin/tbd-listen", "show", "--format", "json", "--", "r1"],
    ["/bin/tbd-listen", "meetings", "--json"],
    ["/bin/tbd-listen", "history", "--json", "--limit", "20"],
    ["/bin/tbd-listen", "history", "--json", "--limit", "5"],
  ]);
  await assert.rejects(by.search_transcripts.invoke({ query: "" }), "the zod limits are the same");
  await assert.rejects(by.recent_dictations.invoke({ limit: 101 }));
  const failing = listeningTools(LISTENING_TOOLS, "/bin/x", listeningFailure, async () => { throw new Error("no such recording"); });
  assert.equal(await failing[1].invoke({ id: "zz" }), "Listening error: no such recording");
});

test("mcp: a command that does not exist, and a server that exits at once, are absent with a note", async () => {
  const notes: string[] = [];
  assert.equal(await loadMcpServer({ name: "companion", command: "/nonexistent/companion", args: ["mcp"], env: { HOME: "/h" } }, (n) => notes.push(n)), null);
  assert.match(notes[0], /tools of companion are not available/);
  assert.equal(await loadMcpServer({ name: "tealbrick", command: "/usr/bin/true", args: [], env: {} }, (n) => notes.push(n)), null);
  assert.match(notes[1], /tools of tealbrick are not available/);
  // (A server that stays silent ends the same way after 20 s; not tested here: the MCP client keeps a 60 s timer alive.)
});

test("graph with the real seam: model tool call → gate → tool → model, a denied call reaches the model as an error", async () => {
  const sent: AgentToHelper[] = [];
  const io = createInteractions((m) => sent.push(m), policy);
  const spy = spyTool("fake_shell");
  const seam = createToolSeam({ tools: [spy.t], gate: (n, i, s) => io.gate("turn9", n, i, s) });
  const seenByModel: string[] = [];
  let call = 0;
  const bound: ChatModelLike = {
    invoke: async (input) => {
      seenByModel.push(input.map((m) => (m.getType() === "tool" ? `tool:${String(m.content)}` : m.getType())).join(","));
      return call++ === 0 ? aiWithCall("fake_shell", { q: "x" }, "toolu_1") : new AIMessage("I could not run that.");
    },
  };
  const model = { invoke: bound.invoke, bindTools: () => bound } as unknown as ChatModelLike;
  const activity: (string | null)[] = [];
  const done = runTurn({
    model, provider: "anthropic", tools: seam, store: { load: () => null, save: () => {} }, text: "run it", signal: signal(),
    hooks: { onSession: () => {}, onDelta: () => {}, onReset: () => {}, onActivity: (l) => activity.push(l) },
  });
  for (let i = 0; i < 50 && sent.length === 0; i += 1) await new Promise((r) => setTimeout(r, 10));
  io.onPermission({ reqId: (sent[0] as { reqId: string }).reqId, allow: false, message: "Declined." });
  assert.equal((await done).reply, "I could not run that.");
  assert.equal(spy.calls.length, 0);
  assert.deepEqual(seenByModel, ["human", "human,ai,tool:Declined."]);
  assert.ok(activity.includes("Using fake_shell"));
});

test("seam bind: a model without bindTools is a plain error; no tools leaves the model as it is", () => {
  const plain = new FakeStreamingChatModel({ chunks: [new AIMessageChunk({ content: "x" })] }) as unknown as ChatModelLike;
  const withTools = createToolSeam({ tools: [spyTool("a").t], gate: async () => ({ allow: true }) });
  assert.doesNotThrow(() => withTools.bind(plain), "the real chat models have bindTools");
  const none = createToolSeam({ tools: [], gate: async () => ({ allow: true }) });
  assert.equal(none.bind(plain), plain);
  assert.throws(() => withTools.bind({ invoke: async () => new AIMessage("x") }), /cannot use tools/);
});
