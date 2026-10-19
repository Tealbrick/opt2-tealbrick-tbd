import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";

// Coordinator dev.10 check: the person's model key, which the helper puts in the agent's environment, never reaches
// the helper's own output (its stderr is the source of ~/Library/Logs/<app>/chat-helper.log) or an error it raises,
// even when the agent prints the key and crashes.

const entry = fileURLToPath(new URL("./fixtures/leaky-agent.ts", import.meta.url));
const KEYS = { anthropic: "sk-ant-api03-Zx9LEAKCHECKaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", foundry: "fk0LEAKCHECK0123456789abcdef0123456789" };

async function runAndCapture(route: Parameters<typeof createDefaultAgent>[0]["model"]): Promise<string> {
  const captured: string[] = [];
  const write = process.stderr.write.bind(process.stderr);
  const error = console.error;
  process.stderr.write = ((chunk: unknown, ...rest: unknown[]) => { captured.push(String(chunk)); return true; }) as typeof process.stderr.write;
  console.error = (...args: unknown[]) => { captured.push(args.map(String).join(" ")); };
  const agent = createDefaultAgent({
    node: process.execPath, entry, model: route,
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-key-logs" }),
    permission: async () => ({ allow: false }),
  });
  try {
    await agent.sendTurn({ text: "hi", onDelta: () => {}, onActivity: () => {} }).catch((e: unknown) => {
      captured.push(e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e));
    });
    // Let the crashed child's exit and any late stderr arrive.
    await new Promise((r) => setTimeout(r, 300));
  } finally {
    agent.stop();
    process.stderr.write = write;
    console.error = error;
  }
  return captured.join("\n");
}

test("the Anthropic key in the agent's environment never reaches the helper's output or errors", async () => {
  const out = await runAndCapture(async () => ({ model: "m", apiKey: KEYS.anthropic }));
  assert.equal(out.includes(KEYS.anthropic), false, out);
  assert.equal(out.includes("LEAKCHECK"), false);
});

test("a cloud key (Foundry) never reaches the helper's output or errors", async () => {
  const out = await runAndCapture(async () => ({
    harness: "claude-agent-sdk", model: "claude-sonnet-5",
    env: { CLAUDE_CODE_USE_FOUNDRY: "1", ANTHROPIC_FOUNDRY_RESOURCE: "res" }, secretEnv: { ANTHROPIC_FOUNDRY_API_KEY: KEYS.foundry },
  }));
  assert.equal(out.includes(KEYS.foundry), false, out);
});

test("a refused route names the variable, never its value", async () => {
  const out = await runAndCapture(async () => ({ model: "m", secretEnv: { TB_PERSON_TOKEN: "tbo_LEAKCHECK_value" } }));
  assert.match(out, /unsupported secret setting \(TB_PERSON_TOKEN\)/);
  assert.equal(out.includes("tbo_LEAKCHECK_value"), false);
});
