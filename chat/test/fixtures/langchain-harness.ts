// Shared helpers of the LangChain agent end-to-end tests (langchain-e2e, langchain-tools-e2e, langchain-tools-env):
// fake model servers, the sandboxed agent harness with its egress evidence, and small file helpers.
// Everything here is local: fake servers on 127.0.0.1, the BUILT out/tbd/agent-langchain.mjs as the agent.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createDefaultAgent, type AgentRoute } from "../../src/main/defaultAgent.ts";
import type { AgentConfig } from "../../src/agent/protocol.ts";

const out = fileURLToPath(new URL("../../out/tbd/", import.meta.url));
export const entry = join(out, "agent.mjs"); // the default entry; the langchain adapter resolves agent-langchain.mjs beside it
export const bundle = join(out, "agent-langchain.mjs");
export const recorder = pathToFileURL(fileURLToPath(new URL("./egress-recorder.ts", import.meta.url))).href;
export const fakeMcp = fileURLToPath(new URL("./fake-mcp.ts", import.meta.url));
export const ready = process.platform === "darwin" && existsSync(bundle) && existsSync("/usr/bin/sandbox-exec");
export const skip = !ready && "needs the macOS build output (node scripts/build-tbd.ts) and sandbox-exec";

// Fake keys built at run time from low-entropy parts, so the secret scanner (gitleaks) sees no key-shaped literal.
export const ANTHROPIC_KEY = `fake-anthropic-${"E2ECHECK".repeat(5)}`;
export const OPENAI_KEY = `fake-openai-${"E2ECHECK".repeat(5)}`;

export interface Seen { method: string; url: string; headers: IncomingMessage["headers"]; body: Record<string, any>; closedEarly: boolean }
/** One scripted model answer: text pieces, then optionally one tool call (Anthropic wire format). */
export interface Step { text?: string[]; tool?: { id: string; name: string; input: unknown } }
export type Mode = "ok" | "slow" | "unauthorized" | Step[];
export interface Fake { port: number; seen: Seen[]; close(): Promise<void>; aborted(): number }

/** One local fake model server. `kind` picks the wire format; `mode` picks the behaviour (a Step[] = scripted answers in order, the last repeats). */
export async function fakeServer(kind: "anthropic" | "openai", mode: Mode): Promise<Fake> {
  const seen: Seen[] = [];
  let aborted = 0;
  let served = 0;
  const pieces = ["Hello", " from", " the fake model."];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      const item: Seen = { method: req.method ?? "", url: req.url ?? "", headers: req.headers, body: raw ? JSON.parse(raw) : {}, closedEarly: false };
      seen.push(item);
      const wanted = kind === "anthropic" ? item.url.startsWith("/v1/messages") : item.url.endsWith("/chat/completions");
      if (!wanted) { res.writeHead(404).end("{}"); return; }
      const key = String(kind === "anthropic" ? item.headers["x-api-key"] : String(item.headers.authorization ?? "").replace("Bearer ", ""));
      if (mode === "unauthorized") {
        // Providers sometimes quote the key back in the error text.
        res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify(
          kind === "anthropic" ? { type: "error", error: { type: "authentication_error", message: `invalid x-api-key: ${key}` } }
            : { error: { message: `Incorrect API key provided: ${key}.`, type: "invalid_request_error", code: "invalid_api_key" } }));
        return;
      }
      res.on("close", () => { if (!res.writableEnded) { item.closedEarly = true; aborted += 1; } });
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
      const step = Array.isArray(mode) ? mode[Math.min(served, mode.length - 1)] : { text: pieces };
      served += 1;
      const events: string[] = kind === "anthropic" ? anthropicEvents(step) : openaiEvents(step.text ?? pieces);
      let i = 0;
      const send = () => {
        if (i >= events.length) { res.end(); return; }
        res.write(events[i++]);
        // "slow": after the first text delta, hold the stream open until the client goes away.
        if (mode === "slow" && i === (kind === "anthropic" ? 3 : 2)) return;
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

function anthropicEvents(step: Step): string[] {
  const ev = (e: unknown) => `event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`;
  const events: string[] = [ev({ type: "message_start", message: { id: `msg_${Math.random().toString(36).slice(2)}`, type: "message", role: "assistant", model: "claude-fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } })];
  let index = 0;
  if (step.text?.length) {
    events.push(ev({ type: "content_block_start", index, content_block: { type: "text", text: "" } }));
    for (const text of step.text) events.push(ev({ type: "content_block_delta", index, delta: { type: "text_delta", text } }));
    events.push(ev({ type: "content_block_stop", index }));
    index += 1;
  }
  if (step.tool) {
    events.push(ev({ type: "content_block_start", index, content_block: { type: "tool_use", id: step.tool.id, name: step.tool.name, input: {} } }));
    events.push(ev({ type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: JSON.stringify(step.tool.input) } }));
    events.push(ev({ type: "content_block_stop", index }));
  }
  events.push(ev({ type: "message_delta", delta: { stop_reason: step.tool ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } }), ev({ type: "message_stop" }));
  return events;
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

export interface Harness {
  agent: ReturnType<typeof createDefaultAgent>;
  raw: { stdout: string; stderr: string };
  connections(): Connection[];
  sessionFiles(): string[];
  dir: string;
  /** Remove this test's own temp folder (call in `finally`). */
  cleanup(): void;
}
export interface Connection { kind: string; host?: string; port?: number; path?: string }

/**
 * Starts the agent as `sandbox-exec … node --import recorder bundle`, tees its raw stdout/stderr and returns the evidence.
 * `extra` adds to the agent's init config (tools, relay…); its `cwd` and `stateDir` are the test's temp folder.
 */
export function harness(port: number, route: AgentRoute, extra: (dir: string) => Partial<Omit<AgentConfig, "model">> = () => ({})): Harness {
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
    config: async () => ({ cwd: dir, stateDir: join(dir, "state"), ...extra(dir) }),
    permission: async () => ({ allow: false }),
  });
  return {
    agent, raw, dir,
    connections: () => (existsSync(logFile) ? readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as Connection) : []),
    sessionFiles: () => { const d = join(dir, "state", "langchain", "sessions"); return existsSync(d) ? readdirSync(d) : []; },
    cleanup: () => rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }), // the test's own mkdtemp folder
  };
}

export function assertEgressOnly(connections: Connection[], port: number): void {
  const sockets = connections.filter((c) => c.kind === "connect");
  assert.ok(sockets.length > 0, "the recorder saw the agent's connection to the fake server");
  for (const c of sockets) assert.deepEqual([c.host, c.port], ["127.0.0.1", port], `unexpected connection ${JSON.stringify(c)}`);
  assert.deepEqual(connections.filter((c) => c.kind === "lookup"), [], "no DNS lookup: no host name was resolved");
}

export function assertNoKey(label: string, key: string, ...texts: string[]): void {
  for (const text of texts) assert.equal(text.includes(key), false, `${label}: the key appears in output`);
}

export async function oneTurn(agent: Harness["agent"], text: string, sessionId?: string) {
  const deltas: string[] = [];
  const activity: (string | null)[] = [];
  const result = await agent.sendTurn({ text, sessionId, onDelta: (d) => deltas.push(d), onActivity: (a) => activity.push(a) });
  return { ...result, deltas, activity };
}

/** A small executable script, written at run time (the agent starts `companionCli mcp` and `listeningCli …` as commands). */
export function script(dir: string, name: string, body: string): string {
  const file = join(dir, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
  return file;
}

/** A command that runs the fake MCP server (fixtures/fake-mcp.ts) and ignores the arguments the agent adds ("mcp"). */
export function fakeMcpCommand(dir: string, name: string, envFile: string, tool: string): string {
  return script(dir, name, `exec "${process.execPath}" "${fakeMcp}" "${envFile}" "${tool}"`);
}

export const readEnv = (file: string): Record<string, string> => JSON.parse(readFileSync(file, "utf8")) as Record<string, string>;
