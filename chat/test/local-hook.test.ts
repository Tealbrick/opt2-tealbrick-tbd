import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { LOCAL_HOOK_FAILED_MESSAGE, localPreToolUse } from "../src/agent/localHook.ts";
import { isLocalConsentTool } from "../src/main/localConsent.ts";

// The local-action check hook (agent/localHook.ts): it only ever refuses; it fails closed; it asks the helper with `check: true`
// (no card). The test switch that turns the whole local layer off must never be set by the helper.

const signal = new AbortController().signal;
const pre = (tool: string, input: unknown = { command: "pwd" }) => ({ hook_event_name: "PreToolUse", tool_name: tool, tool_input: input });

test("the hook refuses a call the helper refuses, with the helper's sentence", async () => {
  const hook = localPreToolUse({ isLocal: isLocalConsentTool, check: async () => ({ allow: false, message: "The person told TBD never to allow running this command." }) });
  assert.deepEqual(await hook(pre("Bash"), undefined, { signal }), {
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "The person told TBD never to allow running this command." },
  });
});

test("the hook NEVER allows: a call that is not refused goes on to the normal flow (empty output)", async () => {
  const hook = localPreToolUse({ isLocal: isLocalConsentTool, check: async () => ({ allow: true }) });
  assert.deepEqual(await hook(pre("Bash"), undefined, { signal }), {});
  assert.deepEqual(await hook(pre("Write", { file_path: "a" }), undefined, { signal }), {});
});

test("the hook fails closed: an error, a closed pipe or a bad input is a deny", async () => {
  const hook = localPreToolUse({ isLocal: isLocalConsentTool, check: async () => { throw new Error("pipe closed"); } });
  const out = (await hook(pre("Bash"), undefined, { signal })) as { hookSpecificOutput: { permissionDecision: string; permissionDecisionReason: string } };
  assert.equal(out.hookSpecificOutput.permissionDecision, "deny");
  assert.equal(out.hookSpecificOutput.permissionDecisionReason, LOCAL_HOOK_FAILED_MESSAGE);
  const throwing = localPreToolUse({ isLocal: () => { throw new Error("boom"); }, check: async () => ({ allow: true }) });
  assert.equal(((await throwing(pre("Bash"), undefined, { signal })) as { hookSpecificOutput: { permissionDecision: string } }).hookSpecificOutput.permissionDecision, "deny");
});

test("tools of no local rule, other events and the test switch skip the check", async () => {
  let asked = 0;
  const seams = { isLocal: isLocalConsentTool, check: async () => { asked++; return { allow: false, message: "no" }; } };
  const hook = localPreToolUse(seams);
  for (const tool of ["Read", "Glob", "Grep", "AskUserQuestion", "mcp__tealbrick__connect__tools_call"]) assert.deepEqual(await hook(pre(tool), undefined, { signal }), {}, tool);
  assert.deepEqual(await hook({ hook_event_name: "PostToolUse", tool_name: "Bash" }, undefined, { signal }), {});
  assert.equal(asked, 0);
  assert.deepEqual(await localPreToolUse({ ...seams, disabled: () => true })(pre("Bash"), undefined, { signal }), {});
  assert.equal(asked, 0);
});

test("the helper forwards `check` to the permission seam, and a plain request has none", async () => {
  const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
  const seen: { tool: string; check?: boolean }[] = [];
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => ({ model: "m", apiKey: "sk-test" }),
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async (req) => { seen.push({ tool: req.tool, ...(req.check ? { check: true } : {}) }); return { allow: true }; },
  });
  try {
    await agent.sendTurn({ text: "local-check", onDelta: () => {}, onActivity: () => {} });
    await agent.sendTurn({ text: "local", onDelta: () => {}, onActivity: () => {} });
    assert.deepEqual(seen, [{ tool: "Bash", check: true }, { tool: "Bash" }]);
  } finally { agent.stop(); }
});

test("the test switch for the local layer is not set anywhere the helper builds the agent's config", () => {
  for (const file of ["../src/main/services.ts", "../src/main/defaultAgent.ts", "../src/main/ipc.ts", "../src/main/localConsent.ts"]) {
    const text = readFileSync(fileURLToPath(new URL(file, import.meta.url)), "utf8");
    assert.ok(!text.includes("testNoLocalConsent"), `${file} must never set the test switch`);
  }
});
