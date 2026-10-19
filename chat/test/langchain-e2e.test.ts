import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createDefaultAgent, type AgentRoute } from "../src/main/defaultAgent.ts";

// WP-HARNESS L1, end to end: the BUILT out/tbd/agent-langchain.mjs, started through createDefaultAgent, talks to a
// local fake Anthropic server and a local fake OpenAI server. Needs the macOS build output (`node scripts/build-tbd.ts`)
// and /usr/bin/sandbox-exec; skipped elsewhere (Linux CI), like agent-shell-env.test.ts.
//
// EGRESS method (two independent checks, both must pass):
//  1. Enforcement: the agent runs under `sandbox-exec` with a profile that denies every network operation except
//     outbound connections to the fake server's own port on localhost. A call to any other host or port fails.
//  2. Record: the agent preloads test/fixtures/egress-recorder.ts, which logs every net.Socket.connect and every DNS
//     lookup. The test asserts the only target is 127.0.0.1:<fake port> and that nothing was looked up.
// Plus: the fake servers' own request logs, and "no key value" in everything the helper gets (raw stdout lines of
// the agent, deltas, reply, errors) and in the agent's stderr.

const out = fileURLToPath(new URL("../out/tbd/", import.meta.url));
const entry = join(out, "agent.mjs"); // the default entry; the langchain adapter resolves agent-langchain.mjs beside it
const bundle = join(out, "agent-langchain.mjs");
const recorder = pathToFileURL(fileURLToPath(new URL("./fixtures/egress-recorder.ts", import.meta.url))).href;
const ready = process.platform === "darwin" && existsSync(bundle) && existsSync("/usr/bin/sandbox-exec");
const skip = !ready && "needs the macOS build output (node scripts/build-tbd.ts) and sandbox-exec";

// Fake keys built at run time from low-entropy parts, so the secret scanner (gitleaks) sees no key-shaped literal.
const ANTHROPIC_KEY = `fake-anthropic-${"E2ECHECK".repeat(5)}`;
const OPENAI_KEY = `fake-openai-${"E2ECHECK".repeat(5)}`;

interface Seen { method: string; url: string; headers: IncomingMessage["headers"]; body: Record<string, any>; closedEarly: boolean }
type Mode = "ok" | "slow" | "unauthorized";

interface Fake { port: number; seen: Seen[]; close(): Promise<void>; aborted(): number }

/** One local fake model server. `kind` picks the wire format; `mode` picks the behaviour. */
async function fakeServer(kind: "anthropic" | "openai", mode: Mode): Promise<Fake> {
  const seen: Seen[] = [];
  let aborted = 0;
  const pieces = ["Hello", " from", " the fake model."];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      const entry: Seen = { method: req.method ?? "", url: req.url ?? "", headers: req.headers, body: raw ? JSON.parse(raw) : {}, closedEarly: false };
      seen.push(entry);
      const wanted = kind === "anthropic" ? entry.url.startsWith("/v1/messages") : entry.url.endsWith("/chat/completions");
      if (!wanted) { res.writeHead(404).end("{}"); return; }
      const key = String(kind === "anthropic" ? entry.headers["x-api-key"] : String(entry.headers.authorization ?? "").replace("Bearer ", ""));
      if (mode === "unauthorized") {
        // Providers sometimes quote the key back in the error text.
        res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify(
          kind === "anthropic" ? { type: "error", error: { type: "authentication_error", message: `invalid x-api-key: ${key}` } }
            : { error: { message: `Incorrect API key provided: ${key}.`, type: "invalid_request_error", code: "invalid_api_key" } }));
        return;
      }
      res.on("close", () => { if (!res.writableEnded) { entry.closedEarly = true; aborted += 1; } });
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
      const events: string[] = kind === "anthropic" ? anthropicEvents(pieces) : openaiEvents(pieces);
      let i = 0;
      const send = () => {
        if (i >= events.length) { res.end(); return; }
        res.write(events[i++]);
        // "slow": after the first text delta, hold the stream open until the client goes away.
        if (mode === "slow" && i === firstDelta(kind) + 1) return;
        setTimeout(send, 5);
      };
      send();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return {
    port: (server.address() as { port: number }).port, seen, aborted: () => aborted,
    close: () => new Promise<void>((r) => { server.close(() => r()); server.closeAllConnections(); }),
  };
}

const firstDelta = (kind: "anthropic" | "openai") => (kind === "anthropic" ? 2 : 1);

function anthropicEvents(pieces: string[]): string[] {
  const ev = (e: unknown) => `event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`;
  return [
    ev({ type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", model: "claude-fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } }),
    ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
    ...pieces.map((text) => ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } })),
    ev({ type: "content_block_stop", index: 0 }),
    ev({ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } }),
    ev({ type: "message_stop" }),
  ];
}

function openaiEvents(pieces: string[]): string[] {
  const chunk = (delta: unknown, finish: string | null) => `data: ${JSON.stringify({ id: "chatcmpl-1", object: "chat.completion.chunk", created: 1, model: "gpt-fake", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  return [
    chunk({ role: "assistant", content: "" }, null),
    ...pieces.map((content) => chunk({ content }, null)),
    chunk({}, "stop"),
    "data: [DONE]\n\n",
  ];
}

/** Starts the agent as `sandbox-exec … node --import recorder bundle`, tees its raw stdout/stderr and returns the evidence. */
function harness(port: number, route: AgentRoute) {
  const dir = mkdtempSync(join(tmpdir(), "tbd-lc-e2e-"));
  const logFile = join(dir, "egress.jsonl");
  const raw = { stdout: "", stderr: "" };
  const profile = `(version 1)(allow default)(deny network*)(allow network-outbound (remote ip "localhost:${port}"))`;
  const spawnProcess = ((node: string, args: string[], opts: object) => {
    const proc = spawn("/usr/bin/sandbox-exec", ["-p", profile, node, "--import", `${recorder}?log=${encodeURIComponent(logFile)}`, ...args], opts);
    proc.stdout.on("data", (d) => { raw.stdout += d; });
    proc.stderr.on("data", (d) => { raw.stderr += d; });
    return proc;
  }) as typeof spawn;
  const agent = createDefaultAgent({
    node: process.execPath, entry, spawnProcess,
    model: async () => route,
    config: async () => ({ cwd: dir, stateDir: join(dir, "state") }),
    permission: async () => ({ allow: false }),
  });
  const connections = () => (existsSync(logFile) ? readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { kind: string; host?: string; port?: number; path?: string }) : []);
  const sessionFiles = () => { const d = join(dir, "state", "langchain", "sessions"); return existsSync(d) ? readdirSync(d) : []; };
  return { agent, raw, connections, sessionFiles, dir };
}

function assertEgressOnly(connections: ReturnType<ReturnType<typeof harness>["connections"]>, port: number): void {
  const sockets = connections.filter((c) => c.kind === "connect");
  assert.ok(sockets.length > 0, "the recorder saw the agent's connection to the fake server");
  for (const c of sockets) assert.deepEqual([c.host, c.port], ["127.0.0.1", port], `unexpected connection ${JSON.stringify(c)}`);
  assert.deepEqual(connections.filter((c) => c.kind === "lookup"), [], "no DNS lookup: no host name was resolved");
}

function assertNoKey(label: string, key: string, ...texts: string[]): void {
  for (const text of texts) assert.equal(text.includes(key), false, `${label}: the key appears in output`);
}

async function oneTurn(agent: ReturnType<typeof harness>["agent"], text: string, sessionId?: string) {
  const deltas: string[] = [];
  const activity: (string | null)[] = [];
  const result = await agent.sendTurn({ text, sessionId, onDelta: (d) => deltas.push(d), onActivity: (a) => activity.push(a) });
  return { ...result, deltas, activity };
}

const BASE_ROUTE = { harness: "langchain" as const, model: "claude-fake" };

test("e2e: Anthropic route streams deltas and a reply, resumes the session, and contacts only the fake server", { skip, timeout: 120_000 }, async () => {
  const fake = await fakeServer("anthropic", "ok");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
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

test("e2e: OpenAI route streams deltas and a reply from a fake chat-completions server, only that host contacted", { skip, timeout: 120_000 }, async () => {
  const fake = await fakeServer("openai", "ok");
  const h = harness(fake.port, { harness: "langchain", provider: "openai", model: "gpt-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { OPENAI_API_KEY: OPENAI_KEY } });
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
  test(`e2e: the ${kind} provider error that quotes the key reaches Chat without the key`, { skip, timeout: 120_000 }, async () => {
    const key = kind === "anthropic" ? ANTHROPIC_KEY : OPENAI_KEY;
    const fake = await fakeServer(kind, "unauthorized");
    const route: AgentRoute = kind === "anthropic"
      ? { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: key } }
      : { harness: "langchain", provider: "openai", model: "gpt-fake", baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { OPENAI_API_KEY: key } };
    const h = harness(fake.port, route);
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

test("e2e: Stop mid-stream ends the turn and closes the model request", { skip, timeout: 120_000 }, async () => {
  const fake = await fakeServer("anthropic", "slow");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${fake.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
  try {
    let turnId = "";
    const deltas: string[] = [];
    let onFirst: () => void = () => {};
    const firstDelta = new Promise<void>((resolve) => { onFirst = resolve; });
    const pending = h.agent.sendTurn({
      text: "talk", onTurn: (t) => { turnId = t.turnId ?? ""; },
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

test("e2e negative control: the sandbox refuses a connection to another port, so the egress check can fail", { skip, timeout: 60_000 }, async () => {
  // Without this, a sandbox profile that allowed everything would make the checks above pass for the wrong reason.
  const other = await fakeServer("anthropic", "ok");
  const fake = await fakeServer("anthropic", "ok");
  const h = harness(fake.port, { ...BASE_ROUTE, baseUrl: `http://127.0.0.1:${other.port}`, secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC_KEY } });
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
