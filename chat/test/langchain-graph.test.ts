import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AIMessage, AIMessageChunk, HumanMessage, ToolMessage, type BaseMessage } from "@langchain/core/messages";
import { FakeStreamingChatModel } from "@langchain/core/utils/testing";
import { contentText, humanContent, runTurn, type ChatModelLike, type ToolSeam, type TurnHooks } from "../src/agent/harness/langchainGraph.ts";
import { fileSessionStore, isSessionId, sessionsDir, type SessionStore } from "../src/agent/harness/langchainSessions.ts";

// WP-HARNESS L1: the graph with a fake chat model (no network), sessions on disk, cancel.

const chunks = (...parts: string[]) => parts.map((content) => new AIMessageChunk({ content }));
const fakeModel = (parts: string[], sleep = 0) => new FakeStreamingChatModel({ chunks: chunks(...parts), sleep }) as unknown as ChatModelLike;

function memoryStore(): SessionStore & { saved: Map<string, BaseMessage[]> } {
  const saved = new Map<string, BaseMessage[]>();
  return { saved, load: (id) => saved.get(id) ?? null, save: (id, m) => { saved.set(id, m); } };
}

function recorder() {
  const log: string[] = [];
  const hooks: TurnHooks = {
    onSession: (s) => log.push(`session:${s}`),
    onDelta: (t) => log.push(`delta:${t}`),
    onReset: () => log.push("reset"),
    onActivity: (l) => log.push(`activity:${l}`),
  };
  return { log, hooks };
}

const fixedId = () => "sess-1";
const privateTemp = () => mkdtempSync(join(tmpdir(), "tbd-lc-"));

test("graph: deltas arrive in order, then the final reply; the session is saved", async () => {
  const { log, hooks } = recorder();
  const store = memoryStore();
  const result = await runTurn({ model: fakeModel(["Hel", "lo ", "there"]), provider: "anthropic", store, text: "hi", signal: new AbortController().signal, hooks, newSessionId: fixedId });
  assert.deepEqual(result, { sessionId: "sess-1", reply: "Hello there" });
  assert.deepEqual(log, ["session:sess-1", "activity:Thinking", "delta:Hel", "delta:lo ", "delta:there", "activity:null"]);
  const saved = store.saved.get("sess-1") ?? [];
  assert.deepEqual(saved.map((m) => [m.getType(), contentText(m.content)]), [["human", "hi"], ["ai", "Hello there"]]);
});

test("graph: the system text goes to the model first and is not saved in the history", async () => {
  const seen: BaseMessage[][] = [];
  const model: ChatModelLike = { invoke: async (input) => { seen.push(input); return new AIMessage("ok"); } };
  const store = memoryStore();
  await runTurn({ model, provider: "anthropic", system: "You are TBD.", store, text: "hi", signal: new AbortController().signal, hooks: recorder().hooks, newSessionId: fixedId });
  assert.deepEqual(seen[0].map((m) => [m.getType(), contentText(m.content)]), [["system", "You are TBD."], ["human", "hi"]]);
  assert.deepEqual((store.saved.get("sess-1") ?? []).map((m) => m.getType()), ["human", "ai"]);
});

test("graph: a model that does not stream still shows its answer once", async () => {
  const { log, hooks } = recorder();
  const model: ChatModelLike = { invoke: async () => new AIMessage("whole answer") };
  const result = await runTurn({ model, provider: "anthropic", store: memoryStore(), text: "hi", signal: new AbortController().signal, hooks, newSessionId: fixedId });
  assert.equal(result.reply, "whole answer");
  assert.deepEqual(log.filter((l) => l.startsWith("delta:")), ["delta:whole answer"]);
});

test("graph: cancel in the middle of a stream stops the turn and keeps the old history", async () => {
  const { log, hooks } = recorder();
  const store = memoryStore();
  store.saved.set("sess-1", [new HumanMessage("before"), new AIMessage("earlier")]);
  const abort = new AbortController();
  const hooked: TurnHooks = { ...hooks, onDelta: (t) => { hooks.onDelta(t); if (t === "b") abort.abort(); } };
  await assert.rejects(
    runTurn({ model: fakeModel(["a", "b", "c", "d", "e", "f"], 40), provider: "anthropic", store, sessionId: "sess-1", text: "go", signal: abort.signal, hooks: hooked }),
    (e: Error) => e.name === "AbortError" && e.message === "Stopped.",
  );
  assert.deepEqual(log.filter((l) => l.startsWith("delta:")), ["delta:a", "delta:b"], "no delta after the stop");
  assert.deepEqual((store.saved.get("sess-1") ?? []).map((m) => contentText(m.content)), ["before", "earlier"], "a stopped turn is not saved");
});

test("graph: a signal that is already aborted never calls the model", async () => {
  let calls = 0;
  const model: ChatModelLike = { invoke: async () => { calls += 1; return new AIMessage("x"); } };
  const abort = new AbortController();
  abort.abort();
  await assert.rejects(runTurn({ model, provider: "anthropic", store: memoryStore(), text: "hi", signal: abort.signal, hooks: recorder().hooks }), /Stopped/);
  assert.equal(calls, 0);
});

test("graph: a failing model is an error and nothing is saved", async () => {
  const store = memoryStore();
  const model: ChatModelLike = { invoke: async () => { throw new Error("provider said no"); } };
  await assert.rejects(runTurn({ model, provider: "anthropic", store, text: "hi", signal: new AbortController().signal, hooks: recorder().hooks, newSessionId: fixedId }), /provider said no/);
  assert.equal(store.saved.size, 0);
});

test("graph: the tool seam runs a tool, resets narration, and answers from the last model call", async () => {
  const first = new FakeStreamingChatModel({
    chunks: [
      new AIMessageChunk({ content: "Let me look." }),
      new AIMessageChunk({ content: "", tool_call_chunks: [{ id: "t1", name: "mcp__companion__timeline", args: "{}", index: 0 }] }),
    ],
  });
  const second = new FakeStreamingChatModel({ chunks: chunks("You were ", "in the editor.") });
  let call = 0;
  const bound: ChatModelLike = { invoke: (input, config) => (call++ === 0 ? first : second).invoke(input, config) };
  const tools: ToolSeam = {
    bind: () => bound,
    run: async (state) => {
      const last = state.messages.at(-1) as AIMessage;
      return { messages: (last.tool_calls ?? []).map((c) => new ToolMessage({ tool_call_id: c.id ?? "", content: "editor 10:00" })) };
    },
    label: (tool) => (tool.startsWith("mcp__companion__") ? "Reading your timeline" : tool),
  };
  const { log, hooks } = recorder();
  const store = memoryStore();
  const result = await runTurn({ model: bound, provider: "anthropic", tools, store, text: "what was I doing?", signal: new AbortController().signal, hooks, newSessionId: fixedId });
  assert.equal(result.reply, "You were in the editor.");
  assert.deepEqual(log, [
    "session:sess-1", "activity:Thinking", "delta:Let me look.", "reset", "activity:Reading your timeline",
    "activity:Thinking", "delta:You were ", "delta:in the editor.", "activity:null",
  ]);
  assert.deepEqual((store.saved.get("sess-1") ?? []).map((m) => m.getType()), ["human", "ai", "tool", "ai"]);
});

test("graph: a server that repeats its response id does not overwrite the earlier answer", async () => {
  const store = memoryStore();
  const model: ChatModelLike = { invoke: async () => new AIMessage({ content: "same id", id: "msg_1" }) };
  const first = await runTurn({ model, provider: "anthropic", store, text: "one", signal: new AbortController().signal, hooks: recorder().hooks, newSessionId: fixedId });
  const second = await runTurn({ model, provider: "anthropic", store, sessionId: first.sessionId, text: "two", signal: new AbortController().signal, hooks: recorder().hooks });
  assert.equal(second.reply, "same id");
  assert.deepEqual((store.saved.get("sess-1") ?? []).map((m) => m.getType()), ["human", "ai", "human", "ai"]);
});

// ---------------------------------------------------------------- content

test("content: Anthropic takes the Chat's blocks unchanged; OpenAI gets image_url and text parts", () => {
  const blocks = [
    { type: "text" as const, text: "look" },
    { type: "image" as const, source: { type: "base64" as const, media_type: "image/png" as const, data: "AAAA" } },
    { type: "document" as const, title: "a.txt", source: { type: "text" as const, media_type: "text/plain" as const, data: "hello" } },
    { type: "document" as const, title: "b.pdf", source: { type: "base64" as const, media_type: "application/pdf" as const, data: "JVBER" } },
  ];
  assert.deepEqual(humanContent("look", undefined, "anthropic"), "look");
  assert.deepEqual(humanContent("look", blocks, "anthropic"), blocks);
  assert.deepEqual(humanContent("look", blocks, "openai"), [
    { type: "text", text: "look" },
    { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
    { type: "text", text: "a.txt\n\nhello" },
    { type: "text", text: '[The attached PDF "b.pdf" cannot be read by this model.]' },
  ]);
});

test("content: only text blocks are visible text (never thinking or tool blocks)", () => {
  assert.equal(contentText("plain"), "plain");
  assert.equal(contentText([{ type: "thinking", thinking: "hmm" }, { type: "text", text: "a" }, { type: "tool_use", name: "x" }, { type: "text_delta", text: "b" }]), "ab");
  assert.equal(contentText(undefined), "");
});

// ---------------------------------------------------------------- sessions

test("sessions: save and load round trip on disk, files private", () => {
  const dir = privateTemp();
  const store = fileSessionStore(dir);
  assert.equal(store.load("abc"), null);
  store.save("abc", [new HumanMessage("hi"), new AIMessage("hello")]);
  const file = join(sessionsDir(dir), "abc.json");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(statSync(sessionsDir(dir)).mode & 0o777, 0o700);
  assert.equal(statSync(join(dir, "langchain")).mode & 0o777, 0o700);
  const loaded = store.load("abc") ?? [];
  assert.deepEqual(loaded.map((m) => [m.getType(), contentText(m.content)]), [["human", "hi"], ["ai", "hello"]]);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).version, 1);
  assert.equal(existsSync(`${file}.${process.pid}.tmp`), false, "no temp file is left behind");
});

test("sessions: a turn with a session id resumes the saved history, and the next save grows it", async () => {
  const dir = privateTemp();
  const store = fileSessionStore(dir);
  const seen: string[][] = [];
  const model: ChatModelLike = { invoke: async (input) => { seen.push(input.map((m) => contentText(m.content))); return new AIMessage(`answer ${seen.length}`); } };
  const first = await runTurn({ model, provider: "anthropic", store, text: "one", signal: new AbortController().signal, hooks: recorder().hooks });
  const second = await runTurn({ model, provider: "anthropic", store: fileSessionStore(dir), sessionId: first.sessionId, text: "two", signal: new AbortController().signal, hooks: recorder().hooks });
  assert.equal(second.sessionId, first.sessionId);
  assert.deepEqual(seen, [["one"], ["one", "answer 1", "two"]]);
  assert.deepEqual((fileSessionStore(dir).load(first.sessionId) ?? []).map((m) => contentText(m.content)), ["one", "answer 1", "two", "answer 2"]);
});

test("sessions: a session id with a path part is refused; a damaged file is an error, not a crash", () => {
  const dir = privateTemp();
  const store = fileSessionStore(dir);
  for (const id of ["../x", "a/b", "", ".hidden", "a b", "x".repeat(200)]) {
    assert.equal(isSessionId(id), false, id);
    assert.throws(() => store.load(id), /not valid/);
    assert.throws(() => store.save(id, []), /not valid/);
  }
  assert.equal(isSessionId("0f8fad5b-d9cb-469f-a165-70867728950e"), true);
  store.save("good", []);
  writeFileSync(join(sessionsDir(dir), "good.json"), "{\"version\":2}");
  assert.throws(() => store.load("good"), /not readable/);
});
