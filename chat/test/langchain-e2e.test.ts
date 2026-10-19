import test from "node:test";
import assert from "node:assert/strict";
import { ANTHROPIC_KEY, OPENAI_KEY, assertEgressOnly, assertNoKey, fakeServer, harness, oneTurn, skip } from "./fixtures/langchain-harness.ts";
import type { AgentRoute } from "../src/main/defaultAgent.ts";

// WP-HARNESS L1, end to end: the BUILT out/tbd/agent-langchain.mjs, started through createDefaultAgent, talks to a
// local fake Anthropic server and a local fake OpenAI server. Needs the macOS build output (`node scripts/build-tbd.ts`)
// and /usr/bin/sandbox-exec; skipped elsewhere (Linux CI), like agent-shell-env.test.ts. The helpers are in
// fixtures/langchain-harness.ts.
//
// EGRESS method (two independent checks, both must pass):
//  1. Enforcement: the agent runs under `sandbox-exec` with a profile that denies every network operation except
//     outbound connections to the fake server's own port on localhost. A call to any other host or port fails.
//  2. Record: the agent preloads test/fixtures/egress-recorder.ts, which logs every net.Socket.connect and every DNS
//     lookup. The test asserts the only target is 127.0.0.1:<fake port> and that nothing was looked up.
// Plus: the fake servers' own request logs, and "no key value" in everything the helper gets (raw stdout lines of
// the agent, deltas, reply, errors) and in the agent's stderr.

const BASE_ROUTE = { harness: "langchain" as const, model: "claude-fake" };

test("e2e: Anthropic route streams deltas and a reply, resumes the session, and contacts only the fake server", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", "ok");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
  t.after(() => h.cleanup());
  try {
    const first = await oneTurn(h.agent, "hi");
    assert.deepEqual(first.deltas, ["Hello", " from", " the fake model."]);
    assert.equal(first.reply, "Hello from the fake model.");
    assert.ok(first.sessionId.length > 8);
    assert.equal(first.activity.at(-1), null, "the activity label is cleared at the end");
    assert.deepEqual(h.sessionFiles(), [`${first.sessionId}.json`]);

    const second = await oneTurn(h.agent, "and again", first.sessionId);
    assert.equal(second.sessionId, first.sessionId);
    assert.equal(second.reply, "Hello from the fake model.");

    // What the model server saw.
    assert.equal(fake.seen.length, 2);
    const [a, b] = fake.seen;
    assert.equal(a.method, "POST");
    assert.equal(a.headers["x-api-key"], ANTHROPIC_KEY);
    assert.equal(a.body.model, "claude-fake");
    assert.equal(a.body.stream, true);
    assert.deepEqual(b.body.messages.map((m: { role: string }) => m.role), ["user", "assistant", "user"], "the second turn carries the first exchange");
    assert.ok(JSON.stringify(b.body.messages).includes("Hello from the fake model."));
    assert.ok(String(a.body.system ? JSON.stringify(a.body.system) : "").includes("TBD"), "the system text is sent");
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("anthropic", ANTHROPIC_KEY, h.raw.stdout, h.raw.stderr);
  assert.ok(h.raw.stdout.includes('"type":"ready"'));
});

test("e2e: OpenAI route streams deltas and a reply from a fake chat-completions server, only that host contacted", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("openai", "ok");
  const h = harness(fake.port, { harness: "langchain", provider: "openai", model: "gpt-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { OPENAI_API_KEY: OPENAI_KEY } });
  t.after(() => h.cleanup());
  try {
    const turn = await oneTurn(h.agent, "hi");
    assert.deepEqual(turn.deltas, ["Hello", " from", " the fake model."]);
    assert.equal(turn.reply, "Hello from the fake model.");
    assert.equal(fake.seen.length, 1);
    assert.equal(fake.seen[0].headers.authorization, `Bearer ${OPENAI_KEY}`);
    assert.equal(fake.seen[0].body.model, "gpt-fake");
    assert.equal(fake.seen[0].body.stream, true);
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("openai", OPENAI_KEY, h.raw.stdout, h.raw.stderr);
});

for (const kind of ["anthropic", "openai"] as const) {
  test(`e2e: the ${kind} provider error that quotes the key reaches Chat without the key`, { skip, timeout: 120_000 }, async (t) => {
    const key = kind === "anthropic" ? ANTHROPIC_KEY : OPENAI_KEY;
    const fake = await fakeServer(kind, "unauthorized");
    const route: AgentRoute = kind === "anthropic"
      ? { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: key } }
      : { harness: "langchain", provider: "openai", model: "gpt-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { OPENAI_API_KEY: key } };
    const h = harness(fake.port, route);
    t.after(() => h.cleanup());
    let message = "";
    try {
      await oneTurn(h.agent, "hi");
      assert.fail("the turn should fail");
    } catch (error) {
      message = (error as Error).message;
    } finally {
      h.agent.stop();
      await fake.close();
    }
    assert.ok(fake.seen.length >= 1, "the fake server was asked");
    assert.ok(message.length > 0 && message !== "the turn should fail");
    assert.ok(message.includes("[redacted key]"), `the provider quoted the key and it was redacted: ${message.slice(0, 200)}`);
    assert.ok(h.raw.stdout.includes("[redacted key]"), "the agent itself redacted it before it reached the helper");
    assertNoKey(kind, key, message, h.raw.stdout, h.raw.stderr);
    assert.equal(h.sessionFiles().length, 0, "a failed turn saves no session");
    assertEgressOnly(h.connections(), fake.port);
  });
}

test("e2e: Stop mid-stream ends the turn and closes the model request", { skip, timeout: 120_000 }, async (t) => {
  const fake = await fakeServer("anthropic", "slow");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
  t.after(() => h.cleanup());
  try {
    let turnId = "";
    const deltas: string[] = [];
    let onFirst: () => void = () => {};
    const firstDelta = new Promise<void>((resolve) => { onFirst = resolve; });
    const pending = h.agent.sendTurn({
      text: "talk", onTurn: (turn) => { turnId = turn.turnId ?? ""; },
      onDelta: (d) => { deltas.push(d); onFirst(); }, onActivity: () => {},
    });
    pending.catch(() => {});
    await firstDelta;
    assert.deepEqual(deltas, ["Hello"], "the stream is held open after the first delta");
    assert.ok(turnId, "the supervisor reported the turn id");
    h.agent.cancel(turnId);
    await assert.rejects(pending, /Stopped\./);
    // The abort reached the HTTP request, not just the turn.
    for (let i = 0; i < 50 && fake.aborted() === 0; i += 1) await new Promise((r) => setTimeout(r, 100));
    assert.equal(fake.aborted(), 1, "the model request was closed by the client");
    assert.deepEqual(deltas, ["Hello"], "nothing arrives after the stop");
    assert.equal(h.sessionFiles().length, 0, "a stopped turn saves no session");
  } finally {
    h.agent.stop();
    await fake.close();
  }
  assertEgressOnly(h.connections(), fake.port);
  assertNoKey("cancel", ANTHROPIC_KEY, h.raw.stdout, h.raw.stderr);
});

test("e2e negative control: the sandbox refuses a connection to another port, so the egress check can fail", { skip, timeout: 60_000 }, async (t) => {
  // Without this, a sandbox profile that allowed everything would make the checks above pass for the wrong reason.
  const other = await fakeServer("anthropic", "ok");
  const fake = await fakeServer("anthropic", "ok");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${other.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
  t.after(() => h.cleanup());
  try {
    await assert.rejects(oneTurn(h.agent, "hi"));
    assert.equal(other.seen.length, 0, "the sandbox kept the agent from the other server");
    assert.throws(() => assertEgressOnly(h.connections(), fake.port), /unexpected connection/, "the recorder saw the attempt");
  } finally {
    h.agent.stop();
    await fake.close();
    await other.close();
  }
});
