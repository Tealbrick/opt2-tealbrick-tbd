import { createInterface } from "node:readline";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { query, type Options, type McpServerConfig, type PermissionResult, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { buildOptions, BRIDGE_SERVER_NAME, BRIDGE_TOOL_PATTERN } from "@opt2-tealbrick/harness-claude";
import { AGENT_TOOLS, ASK_TOOL, describeToolCall, needsPermission, type AgentConfig, type AgentQuestion, type AgentToHelper, type HelperToAgent } from "./protocol";
import type { ContentBlock } from "../shared/message";
import { listeningServer } from "./listeningTools";
import { modelEnv } from "./modelEnv";

/**
 * TBD's default agent process (C24): the Claude Agent SDK harness with the
 * user's own model key, its own state directory (never ~/.claude), no user or
 * project settings, harness-local tools (Companion timeline, Listening) and
 * Teal Brick apps through the local relay. Every built-in tool that changes
 * this Mac asks the person through TBD's consent card first.
 *
 * Started by the Chat helper with an allow-listed environment: the model key
 * and nothing that belongs to the person's Portal session.
 */

const out = (m: AgentToHelper) => process.stdout.write(`${JSON.stringify(m)}\n`);
console.log = console.info = console.debug = (...a: unknown[]) => console.error(...a);

let config: AgentConfig | null = null;
const turns = new Map<string, AbortController>();
const permissions = new Map<string, (r: { allow: boolean; message?: string }) => void>();
const answers = new Map<string, (a: Record<string, string> | null) => void>();
let nextReq = 0;

/** Harness-local tool servers (C5); the bridge relay is added by harness-claude. */
function localServers(c: AgentConfig): Record<string, McpServerConfig> {
  const servers: Record<string, McpServerConfig> = {};
  if (c.companionCli) servers.companion = { type: "stdio", command: c.companionCli, args: ["mcp"], env: { HOME: process.env.HOME ?? "" } };
  if (c.listeningCli) servers.listening = listeningServer(c.listeningCli);
  return servers;
}

function options(c: AgentConfig, id: string, abort: AbortController, sessionId?: string): Options {
  // harness-claude: isolation (no user/project settings, strict MCP, never bypass), allow-listed env,
  // the bridge reached only through the relay MCP server "tealbrick", held-call guidance.
  const base = buildOptions({
    bridge: { agentId: "tbd-default", command: c.relay?.command ?? "false", args: c.relay?.args ?? [] },
    cwd: c.cwd,
    env: process.env,
    modelKeyEnv: "ANTHROPIC_API_KEY",
    model: c.model.model,
    builtinTools: [],
    extraMcpServers: localServers(c),
    appendSystemPrompt: [
      "You are TBD, the person's default Teal Brick agent, running on their Mac.",
      "You can read their screen-activity timeline (companion tools) and their transcripts and meetings (listening tools).",
      "Teal Brick apps (memory, connected accounts) are available through the tealbrick tools when connected; the workspace bridge decides what you may do there.",
      c.systemAppend ?? "",
    ].join("\n"),
    onHeld: (held) => out({ type: "event", id, event: { kind: "activity", label: `Waiting for owner approval (${held.tool.replace(BRIDGE_TOOL_PATTERN, "")})` } }),
  }) as Options & { mcpServers: Record<string, McpServerConfig>; allowedTools: string[]; env: Record<string, string> };
  if (c.relay) {
    base.mcpServers[BRIDGE_SERVER_NAME] = { type: "stdio", command: c.relay.command, args: c.relay.args, env: c.relay.env };
  } else {
    // Not connected to a workspace yet: no Teal Brick tools at all.
    delete base.mcpServers[BRIDGE_SERVER_NAME];
    base.allowedTools = base.allowedTools.filter((t) => !t.startsWith(BRIDGE_TOOL_PATTERN));
  }
  return {
    ...base,
    abortController: abort,
    resume: sessionId,
    includePartialMessages: true,
    // Available built-ins; none is auto-allowed: every call goes through canUseTool (SEC-04).
    tools: AGENT_TOOLS,
    pathToClaudeCodeExecutable: c.claudeExecutable,
    ...(c.sandbox ? { sandbox: c.sandbox as Options["sandbox"] } : {}),
    env: {
      ...base.env,
      // The harness's own state, isolated from the person's Claude setup.
      CLAUDE_CONFIG_DIR: join(c.stateDir, "claude"),
      ...modelEnv(c.model, process.env),
    },
    canUseTool: async (tool, input, { signal }): Promise<PermissionResult> => {
      if (tool === ASK_TOOL) return ask(id, input, signal);
      if (!needsPermission(tool)) return { behavior: "allow", updatedInput: input };
      const reqId = `p${++nextReq}`;
      out({ type: "permission_request", id, reqId, tool, detail: describeToolCall(tool, input), input });
      const decision = await new Promise<{ allow: boolean; message?: string }>((resolve) => {
        permissions.set(reqId, resolve);
        signal.addEventListener("abort", () => resolve({ allow: false, message: "Turn stopped." }), { once: true });
      });
      permissions.delete(reqId);
      return decision.allow ? { behavior: "allow", updatedInput: input } : { behavior: "deny", message: decision.message ?? "The person declined this action." };
    },
  };
}

/**
 * AskUserQuestion (v1 question cards): the questions go to the person's Chat; their answers come back
 * keyed by question text, the shape the SDK tool expects in `answers`. No answer is a refusal.
 */
async function ask(id: string, input: Record<string, unknown>, signal: AbortSignal): Promise<PermissionResult> {
  const questions = (Array.isArray(input.questions) ? input.questions : []) as AgentQuestion[];
  if (questions.length === 0) return { behavior: "deny", message: "No question to ask." };
  const reqId = `q${++nextReq}`;
  out({ type: "question", id, reqId, questions });
  const answer = await new Promise<Record<string, string> | null>((resolve) => {
    answers.set(reqId, resolve);
    signal.addEventListener("abort", () => resolve(null), { once: true });
  });
  answers.delete(reqId);
  return answer ? { behavior: "allow", updatedInput: { ...input, answers: answer } } : { behavior: "deny", message: "The person did not answer." };
}

/** The turn's prompt: plain text, or one user message with the attached files (text first). */
function prompt(text: string, content?: ContentBlock[]): string | AsyncIterable<SDKUserMessage> {
  if (!content?.length) return text;
  return (async function* () {
    yield { type: "user", message: { role: "user", content }, parent_tool_use_id: null } as SDKUserMessage;
  })();
}

/** Map SDK messages to the Chat's event vocabulary. */
function relay(id: string, m: SDKMessage, state: { text: string }): void {
  if (m.type === "stream_event" && m.parent_tool_use_id === null) {
    const e = m.event;
    if (e.type === "content_block_start" && e.content_block.type === "tool_use") {
      out({ type: "event", id, event: { kind: "activity", label: activityLabel(e.content_block.name) } });
      // Narration before a tool call is not the answer.
      if (state.text) { state.text = ""; out({ type: "event", id, event: { kind: "reset" } }); }
    } else if (e.type === "content_block_delta" && e.delta.type === "text_delta") {
      state.text += e.delta.text;
      out({ type: "event", id, event: { kind: "delta", text: e.delta.text } });
    } else if (e.type === "message_start") {
      out({ type: "event", id, event: { kind: "activity", label: "Thinking" } });
    }
  } else if (m.type === "system" && m.subtype === "init") {
    out({ type: "event", id, event: { kind: "session", sessionId: m.session_id } });
  }
}

function activityLabel(tool: string): string {
  if (tool.startsWith("mcp__companion__")) return "Reading your timeline";
  if (tool.startsWith("mcp__listening__")) return "Reading your transcripts";
  if (tool.startsWith("mcp__tealbrick__")) return "Using a Teal Brick app";
  return { Read: "Reading a file", Glob: "Finding files", Grep: "Searching files", Edit: "Editing a file", Write: "Writing a file", Bash: "Running a command", WebFetch: "Fetching a page", WebSearch: "Searching the web" }[tool] ?? `Using ${tool}`;
}

async function runTurn(id: string, text: string, sessionId?: string, content?: ContentBlock[]): Promise<void> {
  if (!config) { out({ type: "error", id, message: "Agent is not initialised." }); return; }
  const abort = new AbortController();
  turns.set(id, abort);
  const state = { text: "" };
  let session = sessionId ?? "";
  try {
    for await (const m of query({ prompt: prompt(text, content), options: options(config, id, abort, sessionId) })) {
      if ("session_id" in m && typeof m.session_id === "string") session = m.session_id;
      relay(id, m, state);
      if (m.type === "result") {
        out({ type: "event", id, event: { kind: "activity", label: null } });
        if (m.subtype === "success" && !m.is_error) out({ type: "done", id, sessionId: session, reply: m.result });
        else out({ type: "error", id, message: m.subtype === "success" ? m.result : `The agent stopped (${m.subtype}).` });
        return;
      }
    }
    out({ type: "error", id, message: abort.signal.aborted ? "Stopped." : "The agent ended without an answer." });
  } catch (error) {
    out({ type: "error", id, message: abort.signal.aborted ? "Stopped." : error instanceof Error ? error.message : String(error) });
  } finally {
    turns.delete(id);
  }
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  let m: HelperToAgent;
  try { m = JSON.parse(line) as HelperToAgent; } catch { return; }
  switch (m.type) {
    case "init":
      config = m.config;
      mkdirSync(join(config.stateDir, "claude"), { recursive: true, mode: 0o700 });
      out({ type: "ready" });
      break;
    case "turn": void runTurn(m.id, m.text, m.sessionId, m.content); break;
    case "cancel": turns.get(m.id)?.abort(); break;
    case "permission": permissions.get(m.reqId)?.({ allow: m.allow, message: m.message }); break;
    case "answer": answers.get(m.reqId)?.(m.answers); break;
    case "shutdown": for (const t of turns.values()) t.abort(); setTimeout(() => process.exit(0), 300); break;
  }
});
lines.on("close", () => process.exit(0));
