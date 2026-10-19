import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";

// S2 (dev.11, Coordinator): a shell command that TBD's agent runs must not see the person's model keys. End to end:
// TBD's real agent (out/tbd/agent.mjs) and the real bundled Claude executable (out/tbd/claude) talk to a local fake
// Anthropic API, which answers with one Bash tool call `env`; the test records what the shell printed. A fake relay
// (stdio MCP server) records the environment it got: TBD's own variables must survive, the keys must not.
// Needs the macOS build output (`node scripts/build-tbd.ts`); skipped elsewhere (Linux CI).

const out = fileURLToPath(new URL("../out/tbd/", import.meta.url));
const agentEntry = join(out, "agent.mjs");
const claude = join(out, "claude");
const ready = process.platform === "darwin" && existsSync(agentEntry) && existsSync(claude);

const KEYS = {
  ANTHROPIC_API_KEY: "sk-ant-api03-SHELLCHECK0000000000000000000000000000000000000000000000000",
  AWS_BEARER_TOKEN_BEDROCK: "ABSKU0hFTExDSEVDSzEyMzQ1Njc4OTBhYmNkZWZnaGlqa2xtbm9wcXJzdA==",
  ANTHROPIC_FOUNDRY_API_KEY: "0f1e2d3c4b5a69788796a5b4c3d2e1f0",
};

function sse(res: ServerResponse, events: unknown[]): void {
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const e of events) res.write(`event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`);
  res.end();
}

const message = (content: unknown[], stop: string) => [
  { type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", model: "claude-test", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } },
  ...content.flatMap((block, index) => (block as { type: string }).type === "tool_use"
    ? [{ type: "content_block_start", index, content_block: { ...(block as object), input: {} } },
       { type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: JSON.stringify((block as { input: unknown }).input) } },
       { type: "content_block_stop", index }]
    : [{ type: "content_block_start", index, content_block: { type: "text", text: "" } },
       { type: "content_block_delta", index, delta: { type: "text_delta", text: (block as { text: string }).text } },
       { type: "content_block_stop", index }]),
  { type: "message_delta", delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } },
  { type: "message_stop" },
];

test("S2: a shell command of TBD's agent sees no model key; the relay keeps its own variables", { skip: !ready && "needs the macOS build output (node scripts/build-tbd.ts)", timeout: 120_000 }, async () => {
  let shellOutput = "";
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      if (!req.url?.startsWith("/v1/messages") || req.url.includes("count_tokens")) { res.writeHead(404).end("{}"); return; }
      const body = JSON.parse(raw || "{}") as { stream?: boolean; tools?: { name: string }[]; messages?: { content: unknown }[] };
      const results = JSON.stringify(body.messages ?? []);
      const main = (body.tools ?? []).some((t) => t.name === "Bash");
      if (!body.stream) { res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: "m", type: "message", role: "assistant", model: "claude-test", content: [{ type: "text", text: "ok" }], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } })); return; }
      if (main && !results.includes("tool_result")) {
        sse(res, message([{ type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "env; echo __END_OF_ENV__", description: "Print the environment" } }], "tool_use"));
      } else {
        if (results.includes("tool_result")) shellOutput = results;
        sse(res, message([{ type: "text", text: "done" }], "end_turn"));
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  const dir = mkdtempSync(join(tmpdir(), "tbd-shell-env-"));
  const relayEnvFile = join(dir, "relay-env.json");
  // Realistic shapes: the scrub also matches "by the shape of its value", so ids must look like real ones (UUIDs, long
  // random strings), not short fakes.
  // Fixed, production-shaped values, so a failure reproduces (review dev.11 #11).
  const relayEnv = {
    PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "",
    TB_SIGNER_SOCKET: "/var/folders/lw/lnvs417x6654wh8s79skzx200000gn/T/tbd-1f0c9e7a2b/signer.sock",
    TB_BRIDGE_URL: "https://bridge-7f3a9c2e.tealbrick.com", TB_CONNECTION_ID: "01928f3e-7c2a-7b4d-9e1f-3a6c8d2b5e70",
    TB_AGENT_ID: "agt_01JAB3XK7Q9M2Z5R8T4W6Y0C1D", TB_BRIDGE_ID: "brg_Zx3Q9vK2mP7tL5nR8wB1cF4hJ6yD0aE3sG9uI2oT5kM",
  };
  const agent = createDefaultAgent({
    node: process.execPath, entry: agentEntry,
    model: async () => ({ model: "claude-test", baseUrl: `http://127.0.0.1:${port}`, secretEnv: KEYS }),
    config: async () => ({
      cwd: dir, stateDir: join(dir, "state"), claudeExecutable: claude,
      relay: { command: process.execPath, args: [fileURLToPath(new URL("./fixtures/fake-relay.ts", import.meta.url)), relayEnvFile], env: relayEnv },
      sandbox: { enabled: true, failIfUnavailable: true, autoAllowBashIfSandboxed: false, allowUnsandboxedCommands: false, filesystem: { allowWrite: [dir] } },
    }),
    permission: async () => ({ allow: true }),
  });
  try {
    await agent.sendTurn({ text: "print the environment", onDelta: () => {}, onActivity: () => {} });
  } finally {
    agent.stop();
    server.close();
  }
  const relayRaw = existsSync(relayEnvFile) ? readFileSync(relayEnvFile, "utf8") : "{}";
  rmSync(dir, { recursive: true, force: true }); // the test's own temp folder
  assert.ok(shellOutput.includes("PATH="), `the Bash call ran and printed its environment: ${shellOutput.slice(0, 400)}`);
  assert.ok(shellOutput.includes("__END_OF_ENV__"), "the whole environment was printed (no truncation hid a key)");
  for (const [name, value] of Object.entries(KEYS)) {
    assert.equal(shellOutput.includes(value), false, `${name} reached the shell`);
    assert.equal(shellOutput.includes(`${name}=`), false, `${name} is set in the shell`);
  }
  const relay = JSON.parse(relayRaw) as Record<string, string>;
  for (const [name, value] of Object.entries(relayEnv)) if (name.startsWith("TB_")) assert.equal(relay[name], value, `relay kept ${name}`);
  for (const value of Object.values(KEYS)) assert.equal(Object.values(relay).includes(value), false, "no model key in the relay's environment");
});
