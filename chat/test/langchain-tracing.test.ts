import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type IncomingMessage } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { ANTHROPIC_KEY, bundle, fakeServer, ready, recorder } from "./fixtures/langchain-harness.ts";

// Review #9: the agent must not send a trace anywhere even when it is started with a hostile environment that
// asks for LangSmith tracing (as a parent process, a shell profile or a wrong route could). The BUILT bundle runs
// with LANGSMITH_* / LANGCHAIN_* set to "trace to this endpoint"; a local recorder plays the endpoint.
//
// Negative control: the same scenario with a scratch copy of the agent built WITHOUT tracingOff.ts (the module that
// switches tracing off). That copy must reach the recorder, otherwise this test would pass for the wrong reason.

const skip = !ready && "needs the macOS build output (node scripts/build-tbd.ts)";
const entry = fileURLToPath(new URL("../src/agent/harness/langchain.ts", import.meta.url));
const TRACE_KEY = `fake-langsmith-${"TRACECHECK".repeat(3)}`;

async function traceRecorder() {
  const hits: string[] = [];
  const server = createServer((req: IncomingMessage, res) => {
    req.on("data", () => {});
    req.on("end", () => { hits.push(`${req.method} ${req.url}`); res.writeHead(200, { "content-type": "application/json" }).end("{}"); });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return { hits, port: (server.address() as { port: number }).port, close: () => new Promise<void>((r) => { server.close(() => r()); server.closeAllConnections(); }) };
}

/** Start `bundlePath` with a hostile environment, run one turn against the fake model, return what happened. */
async function runHostile(bundlePath: string, dir: string, modelPort: number, tracePort: number) {
  const log = join(dir, "egress.jsonl");
  const env = {
    PATH: "/usr/bin:/bin", HOME: dir, TMPDIR: dir, ANTHROPIC_API_KEY: ANTHROPIC_KEY,
    LANGSMITH_TRACING: "true", LANGSMITH_API_KEY: TRACE_KEY, LANGSMITH_ENDPOINT: `http://127.0.0.1:${tracePort}`, LANGSMITH_PROJECT: "leak",
    LANGCHAIN_TRACING_V2: "true", LANGCHAIN_API_KEY: TRACE_KEY, LANGCHAIN_ENDPOINT: `http://127.0.0.1:${tracePort}`, LANGCHAIN_PROJECT: "leak",
    LANGCHAIN_CALLBACKS_BACKGROUND: "false",
  };
  const child = spawn(process.execPath, ["--import", `${recorder}?log=${encodeURIComponent(log)}`, bundlePath], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  child.stdout.on("data", (d) => { stdout += d; });
  child.stderr.on("data", () => {});
  const send = (m: unknown) => child.stdin.write(`${JSON.stringify(m)}\n`);
  send({ type: "init", config: { cwd: dir, stateDir: join(dir, "state"), model: { model: "claude-fake", baseUrl: `http://127.0.0.1:${modelPort}`, secretNames: ["ANTHROPIC_API_KEY"] } } });
  send({ type: "turn", id: "t1", text: "hi" });
  for (let i = 0; i < 200 && !/"type":"(done|error)"/.test(stdout); i += 1) await new Promise((r) => setTimeout(r, 50));
  await new Promise((r) => setTimeout(r, 500)); // a late trace would arrive here
  send({ type: "shutdown" });
  await new Promise((r) => setTimeout(r, 500));
  child.kill("SIGTERM");
  const targets = existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { kind: string; host?: string; port?: number }) : [];
  return { stdout, targets, finished: /"type":"done"/.test(stdout) };
}

test("tracing: a hostile LANGSMITH_* / LANGCHAIN_* environment sends nothing to the trace endpoint", { skip, timeout: 120_000 }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "tbd-lc-trace-"));
  t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
  const model = await fakeServer("anthropic", "ok");
  const trace = await traceRecorder();
  t.after(async () => { await model.close(); await trace.close(); });
  const run = await runHostile(bundle, dir, model.port, trace.port);
  assert.equal(run.finished, true, run.stdout);
  assert.equal(model.seen.length, 1, "the model server was asked once");
  assert.deepEqual(trace.hits, [], "no trace request reached the trace endpoint");
  for (const c of run.targets.filter((x) => x.kind === "connect")) assert.deepEqual([c.host, c.port], ["127.0.0.1", model.port], "the only connection is to the model server");
  assert.equal(run.stdout.includes(TRACE_KEY), false);
});

test("tracing negative control: an agent built without tracingOff.ts DOES send traces under the same environment", { skip, timeout: 120_000 }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "tbd-lc-trace-"));
  t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }));
  const scratch = join(dir, "agent-without-tracing-off.mjs");
  await build({
    entryPoints: [entry], outfile: scratch, bundle: true, platform: "node", format: "esm", target: "node24", logLevel: "error",
    banner: { js: "import { createRequire as __tbdRequire } from 'node:module'; const require = __tbdRequire(import.meta.url);" },
    plugins: [{ name: "without-tracing-off", setup(b) {
      b.onResolve({ filter: /\/tracingOff$/ }, () => ({ path: "tracing-off-removed", namespace: "removed" }));
      b.onLoad({ filter: /.*/, namespace: "removed" }, () => ({ contents: "export {};" }));
    } }],
  });
  const model = await fakeServer("anthropic", "ok");
  const trace = await traceRecorder();
  t.after(async () => { await model.close(); await trace.close(); });
  const run = await runHostile(scratch, dir, model.port, trace.port);
  assert.equal(run.finished, true, run.stdout);
  assert.ok(trace.hits.length > 0, "the control sent traces; so the test above would have seen them");
});
