import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createDefaultAgent, type AgentRoute } from "../src/main/defaultAgent.ts";

// Coordinator dev.10 check: the person's model key, which the helper puts in the agent's environment, never reaches
// anything the helper hands on (Chat callbacks, the consent card, errors) or writes (its stderr is the source of
// ~/Library/Logs/<app>/chat-helper.log), and never travels in the init message — even when the agent misbehaves.
// The agent's own stderr is dropped by the supervisor; these tests check every path that IS forwarded.

const entry = fileURLToPath(new URL("./fixtures/leaky-agent.ts", import.meta.url));
const ANTHROPIC = "sk-ant-api03-Zx9LEAKCHECKaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const FOUNDRY = "fk0LEAKCHECK0123456789abcdef0123456789";

async function run(route: AgentRoute, text: string): Promise<{ seen: string[]; logged: string; init: string }> {
  const seen: string[] = [];
  const logged: string[] = [];
  const write = process.stderr.write.bind(process.stderr);
  const error = console.error;
  process.stderr.write = ((chunk: unknown) => { logged.push(String(chunk)); return true; }) as typeof process.stderr.write;
  console.error = (...args: unknown[]) => { logged.push(args.map(String).join(" ")); };
  let init = "";
  const agent = createDefaultAgent({
    node: process.execPath, entry, model: async () => route,
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-key-logs" }),
    permission: async (r) => { seen.push(`permission:${r.detail}|${JSON.stringify(r.input)}`); return { allow: true }; },
  });
  try {
    const r = await agent.sendTurn({
      text, onDelta: (t) => seen.push(`delta:${t}`), onActivity: (l) => seen.push(`activity:${l}`),
      onQuestion: (q) => { seen.push(`question:${JSON.stringify(q.questions)}`); agent.answer(q.reqId, null); },
    }).catch((e: unknown) => { seen.push(`error:${e instanceof Error ? e.message : String(e)}`); return undefined; });
    if (r) { seen.push(`reply:${r.reply}`); init = String((JSON.parse(r.reply) as { initLine?: string }).initLine ?? ""); }
    await new Promise((res) => setTimeout(res, 200));
  } finally {
    agent.stop();
    process.stderr.write = write;
    console.error = error;
  }
  return { seen, logged: logged.join("\n"), init };
}

for (const [name, route, key] of [
  ["Anthropic route", { model: "m", baseUrl: "https://api.anthropic.com", secretEnv: { ANTHROPIC_API_KEY: ANTHROPIC } }, ANTHROPIC],
  ["Foundry route", { harness: "claude-agent-sdk", model: "claude-sonnet-5", env: { CLAUDE_CODE_USE_FOUNDRY: "1", ANTHROPIC_FOUNDRY_RESOURCE: "res" }, secretEnv: { ANTHROPIC_FOUNDRY_API_KEY: FOUNDRY } }, FOUNDRY],
] as const) {
  test(`${name}: the key never reaches a delta, activity, consent card, question, reply or the helper's output`, async () => {
    const { seen, logged, init } = await run(route as AgentRoute, "hi");
    const kinds = new Set(seen.map((s) => s.split(":")[0]));
    for (const kind of ["activity", "delta", "permission", "question", "reply"]) assert.ok(kinds.has(kind), `path ${kind} was exercised`);
    for (const s of seen) assert.equal(s.includes(key), false, s);
    assert.ok(seen.some((s) => s.includes("[redacted key]")), "the scrub replaced the key");
    assert.equal(logged.includes(key), false);
    assert.ok(init.includes('"type":"init"'), "the agent saw the init line");
    assert.equal(init.includes(key), false, "the key never travels in the init message");
  });

  test(`${name}: an agent error that quotes the key is scrubbed`, async () => {
    const { seen, logged } = await run(route as AgentRoute, "crash");
    const error = seen.find((s) => s.startsWith("error:")) ?? "";
    assert.match(error, /provider refused key \[redacted key\]/);
    assert.equal(logged.includes(key), false);
  });
}

test("a refused route names the variable, never its value", async () => {
  const { seen } = await run({ model: "m", secretEnv: { TB_PERSON_TOKEN: "tbo_LEAKCHECK_value" } }, "hi");
  const error = seen.find((s) => s.startsWith("error:")) ?? "";
  assert.match(error, /unsupported secret setting \(TB_PERSON_TOKEN\)/);
  assert.equal(seen.join("\n").includes("tbo_LEAKCHECK_value"), false);
});
