// Must stay the first import: it switches LangChain tracing off before any LangChain module loads.
import "./tracingOff";
import { createInterface } from "node:readline";
import type { StructuredToolInterface } from "@langchain/core/tools";
import { describeToolCall, needsPermission, type AgentConfig, type AgentToHelper, type HelperToAgent } from "../protocol";
import type { ContentBlock } from "../../shared/message";
import { LISTENING_TOOLS, listeningFailure } from "../listeningDefs";
import { runTurn } from "./langchainGraph";
import { createChatModel } from "./langchainModels";
import { fileSessionStore } from "./langchainSessions";
import { ASK_PERSON, askPersonTool, createInteractions, createToolSeam, listeningTools, loadMcpServer, type LoadedTools, type McpServerSpec } from "./langchainTools";

/**
 * TBD's LangChain agent process (WP-HARNESS L1): the same stdio protocol as the Agent SDK agent (agent/main.ts),
 * a small LangGraph graph behind it. The Chat helper starts it with an allow-listed environment: PATH, HOME,
 * TMPDIR and the person's own model key. No tracing. Tools (L2): Companion timeline, Listening and the Teal Brick
 * relay under the SDK agent's names, plus ask_person. Thin on purpose: the logic is in langchainGraph.ts,
 * langchainModels.ts, langchainSessions.ts and langchainTools.ts.
 */

const out = (m: AgentToHelper) => process.stdout.write(`${JSON.stringify(m)}\n`);
console.log = console.info = console.debug = (...a: unknown[]) => console.error(...a);

let config: AgentConfig | null = null;
const turns = new Map<string, AbortController>();
const interactions = createInteractions(out, { needsPermission, describe: describeToolCall });
const note = (text: string) => console.error(`[agent-langchain] ${text}`);

/** MCP servers that started, by family. A family that failed is tried again on the next turn. */
const mcp = new Map<string, LoadedTools>();
let loading: Promise<void> | null = null;

/** Harness-local servers (C5): Companion timeline and, once connected, the Teal Brick relay. Explicit environments only. */
function mcpSpecs(c: AgentConfig): McpServerSpec[] {
  const specs: McpServerSpec[] = [];
  if (c.companionCli) specs.push({ name: "companion", command: c.companionCli, args: ["mcp"], env: { HOME: process.env.HOME ?? "" } });
  // Not connected to a workspace yet: no Teal Brick tools at all.
  if (c.relay) specs.push({ name: "tealbrick", command: c.relay.command, args: c.relay.args, env: c.relay.env });
  return specs;
}

async function ensureMcp(c: AgentConfig): Promise<void> {
  loading ??= Promise.all(mcpSpecs(c).filter((s) => !mcp.has(s.name)).map(async (spec) => {
    const loaded = await loadMcpServer(spec, note);
    if (loaded) mcp.set(spec.name, loaded);
  })).then(() => {}).finally(() => { loading = null; });
  await loading;
}

async function closeMcp(): Promise<void> {
  await Promise.race([Promise.all([...mcp.values()].map((m) => m.close())), new Promise((r) => setTimeout(r, 800))]);
}

/** A provider error can quote the key; the supervisor scrubs too, this is the first line of defence. */
function scrub(text: string): string {
  return ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"].reduce((t, name) => {
    const key = process.env[name];
    return key && key.length >= 8 ? t.split(key).join("[redacted key]") : t;
  }, text);
}

const SYSTEM = [
  "You are TBD, the person's default Teal Brick agent, running on their Mac.",
  "You can read their screen-activity timeline (companion tools) and their transcripts and meetings (listening tools) when those tools are listed.",
  "Teal Brick apps (memory, connected accounts) are available through the tealbrick tools when connected; the workspace bridge decides what you may do there.",
  `When you need a choice or a fact only the person has, use ${ASK_PERSON}. You have no shell, file or web tools.`,
].join("\n");

async function turn(id: string, text: string, sessionId?: string, content?: ContentBlock[]): Promise<void> {
  if (!config) { out({ type: "error", id, message: "Agent is not initialised." }); return; }
  const abort = new AbortController();
  turns.set(id, abort);
  try {
    const { model, provider } = createChatModel(config.model, process.env);
    await ensureMcp(config);
    const tools: StructuredToolInterface[] = [
      ...[...mcp.values()].flatMap((m) => m.tools),
      ...(config.listeningCli ? listeningTools(LISTENING_TOOLS, config.listeningCli, listeningFailure) : []),
      askPersonTool((questions, signal) => interactions.ask(id, questions, signal)),
    ];
    const result = await runTurn({
      model, provider, sessionId, text, content,
      tools: createToolSeam({ tools, gate: (name, input, signal) => interactions.gate(id, name, input, signal), ungated: new Set([ASK_PERSON]) }),
      system: [SYSTEM, config.systemAppend ?? ""].filter(Boolean).join("\n"),
      store: fileSessionStore(config.stateDir),
      signal: abort.signal,
      hooks: {
        onSession: (s) => out({ type: "event", id, event: { kind: "session", sessionId: s } }),
        onDelta: (t) => out({ type: "event", id, event: { kind: "delta", text: t } }),
        onReset: () => out({ type: "event", id, event: { kind: "reset" } }),
        onActivity: (label) => out({ type: "event", id, event: { kind: "activity", label } }),
      },
    });
    out({ type: "event", id, event: { kind: "activity", label: null } });
    out({ type: "done", id, sessionId: result.sessionId, reply: result.reply });
  } catch (error) {
    out({ type: "event", id, event: { kind: "activity", label: null } });
    out({ type: "error", id, message: abort.signal.aborted ? "Stopped." : scrub(error instanceof Error ? error.message : String(error)) });
  } finally {
    turns.delete(id);
  }
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  let m: HelperToAgent;
  try { m = JSON.parse(line) as HelperToAgent; } catch { return; }
  switch (m.type) {
    case "init": config = m.config; out({ type: "ready" }); break;
    case "turn": void turn(m.id, m.text, m.sessionId, m.content); break;
    case "cancel": turns.get(m.id)?.abort(); break;
    case "permission": interactions.onPermission(m); break;
    case "answer": interactions.onAnswer(m); break;
    case "shutdown": for (const t of turns.values()) t.abort(); void closeMcp().finally(() => setTimeout(() => process.exit(0), 300)); break;
  }
});
lines.on("close", () => { void closeMcp().finally(() => process.exit(0)); });
