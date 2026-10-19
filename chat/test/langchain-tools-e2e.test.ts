import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { ANTHROPIC_KEY, OPENAI_KEY, assertEgressOnly, assertNoKey, fakeMcp, fakeMcpCommand, fakeServer, harness, script, skip, type Step } from "./fixtures/langchain-harness.ts";
import type { AgentQuestion } from "../src/agent/protocol.ts";

// WP-HARNESS L2, end to end: the BUILT agent-langchain.mjs with fake stdio MCP servers (Companion, Teal Brick relay),
// a fake Listening CLI and a scripted fake Anthropic server. Same sandbox and egress evidence as langchain-e2e.test.ts
// (the MCP servers and the CLI are local child processes, not network). Skipped without the macOS build output.

const route = (port: number) => ({ harness: "langchain" as const, model: "claude-fake", baseUrl: `http://127.0.0.1:${port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
const relayEnv = (dir: string) => ({ PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "", TB_SIGNER_SOCKET: join(dir, "signer.sock"), TB_AGENT_ID: "agt_01JAB3XK7Q9M2Z5R8T4W6Y0C1D" });

/** The tool results of a request body: tool_use_id → text. */
function toolResults(body: Record<string, any>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of body.messages ?? []) {
    if (!Array.isArray(m.content)) continue;
    for (const b of m.content) {
      if (b.type === "tool_result") out[b.tool_use_id] = typeof b.content === "string" ? b.content : (b.content ?? []).map((c: { text?: string }) => c.text ?? "").join("");
    }
  }
  return out;
}

test("e2e tools: a tool call reaches a fake MCP server, its result reaches the model, the final text arrives as deltas", { skip, timeout: 120_000 }, async (t) => {
  const steps: Step[] = [
    { text: ["Let me ", "check."], tool: { id: "toolu_c1", name: "mcp__companion__timeline_search", input: { query: "standup" } } },
    { tool: { id: "toolu_t1", name: "mcp__tealbrick__memory_search", input: { query: "plan" } } },
    { tool: { id: "toolu_l1", name: "mcp__listening__list_meetings", input: {} } },
    { text: ["You were ", "in the standup."] },
  ];
  const fake = await fakeServer("anthropic", steps);
  const h = harness(fake.port, route(fake.port), (dir) => ({
    companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), "timeline_search"),
    listeningCli: script(dir, "tbd-listen", `echo '[{"id":"m1","title":"Standup"}]'`),
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search"], env: relayEnv(dir) },
  }));
  t.after(() => h.cleanup());
  const deltas: string[] = [];
  const activity: (string | null)[] = [];
  let resets = 0;
  try {
    const result = await h.agent.sendTurn({ text: "what was I doing?", onDelta: (d) => deltas.push(d), onReset: () => { resets += 1; }, onActivity: (a) => activity.push(a) });
    assert.equal(result.reply, "You were in the standup.");
    assert.deepEqual(deltas.slice(-2), ["You were ", "in the standup."]);
    assert.equal(resets, 1, "the narration before the first tool call was reset");
    assert.deepEqual(activity.filter((a) => a && a !== "Thinking"), ["Reading your timeline", "Using a Teal Brick app", "Reading your transcripts"]);
    assert.equal(activity.at(-1), null);

    assert.equal(fake.seen.length, 4);
    // The model was offered the tools under the SDK agent's names, and ask_person; no shell, file or web tool.
    const offered = fake.seen[0].body.tools.map((x: { name: string }) => x.name).sort();
    assert.deepEqual(offered, ["ask_person", "mcp__companion__timeline_search", "mcp__listening__list_meetings", "mcp__listening__recent_dictations", "mcp__listening__search_transcripts", "mcp__listening__show_transcript", "mcp__tealbrick__memory_search"]);
    // Each tool result reached the model's next request, keyed by the tool call id.
    assert.equal(toolResults(fake.seen[1].body).toolu_c1, 'timeline_search result for {"query":"standup"}');
    assert.equal(toolResults(fake.seen[2].body).toolu_t1, 'memory_search result for {"query":"plan"}');
    assert.equal(toolResults(fake.seen[3].body).toolu_l1, '[{"id":"m1","title":"Standup"}]\n');
    assert.deepEqual(h.sessionFiles().length, 1);
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("tools", ANTHROPIC_KEY, h.raw.stdout, h.raw.stderr);
});

test("e2e tools: ask_person goes to the question card and the answer comes back; no answer is a plain sentence", { skip, timeout: 120_000 }, async (t) => {
  const question = { question: "Which day?", header: "Day", options: [{ label: "Monday", description: "Start of the week" }, { label: "Tuesday" }] };
  const steps: Step[] = [
    { tool: { id: "toolu_q1", name: "ask_person", input: { questions: [question] } } },
    { text: ["Tuesday it is."] },
    { tool: { id: "toolu_q2", name: "ask_person", input: { questions: [question] } } },
    { text: ["No answer, then."] },
  ];
  const fake = await fakeServer("anthropic", steps);
  const h = harness(fake.port, route(fake.port));
  t.after(() => h.cleanup());
  try {
    const asked: { reqId: string; questions: AgentQuestion[] }[] = [];
    const first = await h.agent.sendTurn({
      text: "plan it", onDelta: () => {}, onActivity: () => {},
      onQuestion: (q) => { asked.push(q); h.agent.answer(q.reqId, { "Which day?": "Tuesday" }); },
    });
    assert.equal(first.reply, "Tuesday it is.");
    assert.equal(asked.length, 1);
    assert.deepEqual(asked[0].questions, [question], "the card gets the question, header and options as the model wrote them");
    assert.equal(toolResults(fake.seen[1].body).toolu_q1, JSON.stringify({ "Which day?": "Tuesday" }));

    const second = await h.agent.sendTurn({
      text: "again", sessionId: first.sessionId, onDelta: () => {}, onActivity: () => {},
      onQuestion: (q) => h.agent.answer(q.reqId, null),
    });
    assert.equal(second.reply, "No answer, then.");
    assert.equal(toolResults(fake.seen[3].body).toolu_q2, "The person did not answer.");
    assert.equal(h.raw.stdout.includes('"type":"permission_request"'), false, "ask_person never opens a consent card");
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
});

test("e2e tools: an MCP server that does not start is absent; the agent and the other families keep working", { skip, timeout: 120_000 }, async (t) => {
  const steps: Step[] = [
    { tool: { id: "toolu_t1", name: "mcp__tealbrick__memory_search", input: { query: "x" } } },
    { text: ["Done without the timeline."] },
  ];
  const fake = await fakeServer("anthropic", steps);
  const h = harness(fake.port, route(fake.port), (dir) => ({
    companionCli: join(dir, "does-not-exist"),
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search"], env: relayEnv(dir) },
  }));
  t.after(() => h.cleanup());
  try {
    const result = await h.agent.sendTurn({ text: "go", onDelta: () => {}, onActivity: () => {} });
    assert.equal(result.reply, "Done without the timeline.");
    const offered = fake.seen[0].body.tools.map((x: { name: string }) => x.name).sort();
    assert.deepEqual(offered, ["ask_person", "mcp__tealbrick__memory_search"], "no companion tool, nothing else lost");
    assert.match(h.raw.stderr, /tools of companion are not available/, "a note on stderr says why");
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
});

test("e2e tools: without a relay in the config there are no Teal Brick tools", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", [{ text: ["Hi."] }]);
  const h = harness(fake.port, route(fake.port), (dir) => ({ companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), "timeline_search") }));
  t.after(() => h.cleanup());
  try {
    await h.agent.sendTurn({ text: "go", onDelta: () => {}, onActivity: () => {} });
    const offered = fake.seen[0].body.tools.map((x: { name: string }) => x.name).sort();
    assert.deepEqual(offered, ["ask_person", "mcp__companion__timeline_search"]);
  } finally {
    h.agent.stop();
    await fake.close();
  }
});

test("e2e tools: the OpenAI route calls a tool too; its result reaches the model as a tool message", { skip, timeout: 120_000 }, async (t) => {
  const steps: Step[] = [
    { text: ["Looking."], tool: { id: "call_c1", name: "mcp__companion__timeline_search", input: { query: "standup" } } },
    { text: ["You were ", "in the standup."] },
  ];
  const fake = await fakeServer("openai", steps);
  const h = harness(fake.port, { harness: "langchain", provider: "openai", model: "gpt-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { OPENAI_API_KEY: OPENAI_KEY } }, (dir) => ({
    companionCli: fakeMcpCommand(dir, "companion", join(dir, "companion-env.json"), "timeline_search"),
  }));
  t.after(() => h.cleanup());
  const deltas: string[] = [];
  const activity: (string | null)[] = [];
  try {
    const result = await h.agent.sendTurn({ text: "what was I doing?", onDelta: (d) => deltas.push(d), onActivity: (a) => activity.push(a) });
    assert.equal(result.reply, "You were in the standup.");
    assert.deepEqual(deltas.slice(-2), ["You were ", "in the standup."]);
    assert.ok(activity.includes("Reading your timeline"));
    assert.equal(fake.seen.length, 2);
    const offered = fake.seen[0].body.tools.map((x: { function: { name: string } }) => x.function.name).sort();
    assert.deepEqual(offered, ["ask_person", "mcp__companion__timeline_search"]);
    const messages = fake.seen[1].body.messages as { role: string; tool_call_id?: string; content?: unknown; tool_calls?: { id: string; function: { name: string; arguments: string } }[] }[];
    const call = messages.find((m) => m.role === "assistant")?.tool_calls?.[0];
    assert.deepEqual([call?.id, call?.function.name, JSON.parse(call?.function.arguments ?? "{}")], ["call_c1", "mcp__companion__timeline_search", { query: "standup" }]);
    const result1 = messages.find((m) => m.role === "tool");
    assert.equal(result1?.tool_call_id, "call_c1");
    assert.ok(JSON.stringify(result1?.content).includes('timeline_search result for {\\"query\\":\\"standup\\"}'));
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("openai tools", OPENAI_KEY, h.raw.stdout, h.raw.stderr);
});

test("e2e tools: a model that calls tools without end stops with a plain sentence (the step limit)", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", [{ tool: { id: "toolu_loop", name: "mcp__tealbrick__memory_search", input: { query: "again" } } }]); // the last step repeats
  const h = harness(fake.port, route(fake.port), (dir) => ({
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search"], env: relayEnv(dir) },
  }));
  t.after(() => h.cleanup());
  try {
    await assert.rejects(h.agent.sendTurn({ text: "loop", onDelta: () => {}, onActivity: () => {} }), (e: Error) => e.message === "The agent stopped after too many steps.");
    assert.equal(h.sessionFiles().length, 0, "a failed turn saves no session");
    assert.ok(fake.seen.length >= 10 && fake.seen.length <= 30, `bounded: ${fake.seen.length} model calls`);
  } finally {
    h.agent.stop();
    await fake.close();
  }
});

test("e2e tools: an MCP server that dies during a call is dropped; the call is an error, the next turn goes on without it (review #13)", { skip, timeout: 120_000 }, async (t) => {
  const steps: Step[] = [
    { tool: { id: "toolu_d1", name: "mcp__tealbrick__memory_search", input: { query: "x" } } },
    { text: ["The app did not answer."] },
    { text: ["Second turn without it."] },
  ];
  const fake = await fakeServer("anthropic", steps);
  const h = harness(fake.port, route(fake.port), (dir) => ({
    relay: { command: process.execPath, args: [fakeMcp, join(dir, "relay-env.json"), "memory_search", "die-on-call"], env: relayEnv(dir) },
  }));
  t.after(() => h.cleanup());
  try {
    const first = await h.agent.sendTurn({ text: "go", onDelta: () => {}, onActivity: () => {} });
    assert.equal(first.reply, "The app did not answer.");
    assert.match(toolResults(fake.seen[1].body).toolu_d1, /^Tool error: /, "the model got the failure as a tool error");
    assert.match(h.raw.stderr, /tools of tealbrick dropped/, "the dead server is dropped, with a note");
    const second = await h.agent.sendTurn({ text: "again", sessionId: first.sessionId, onDelta: () => {}, onActivity: () => {} });
    assert.equal(second.reply, "Second turn without it.");
    const offered = fake.seen[2].body.tools.map((x: { name: string }) => x.name);
    assert.deepEqual(offered, ["ask_person"], "inside the 60 s back-off the family is not started again");
  } finally {
    h.agent.stop();
    await fake.close();
  }
});
