// Must stay the first import: it switches LangChain tracing off before any LangChain module loads.
import "./tracingOff";
import { createInterface } from "node:readline";
import type { AgentConfig, AgentToHelper, HelperToAgent } from "../protocol";
import type { ContentBlock } from "../../shared/message";
import { runTurn } from "./langchainGraph";
import { createChatModel } from "./langchainModels";
import { fileSessionStore } from "./langchainSessions";

/**
 * TBD's LangChain agent process (WP-HARNESS L1): the same stdio protocol as the Agent SDK agent (agent/main.ts),
 * a small LangGraph graph behind it. The Chat helper starts it with an allow-listed environment: PATH, HOME,
 * TMPDIR and the person's own model key. No tracing, no tools yet (L2). Thin on purpose: the logic is in
 * langchainGraph.ts, langchainModels.ts and langchainSessions.ts.
 */

const out = (m: AgentToHelper) => process.stdout.write(`${JSON.stringify(m)}\n`);
console.log = console.info = console.debug = (...a: unknown[]) => console.error(...a);

let config: AgentConfig | null = null;
const turns = new Map<string, AbortController>();

/** A provider error can quote the key; the supervisor scrubs too, this is the first line of defence. */
function scrub(text: string): string {
  return ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"].reduce((t, name) => {
    const key = process.env[name];
    return key && key.length >= 8 ? t.split(key).join("[redacted key]") : t;
  }, text);
}

const SYSTEM = [
  "You are TBD, the person's default Teal Brick agent, running on their Mac.",
  "In this version you answer from the conversation only; you have no tools.",
].join("\n");

async function turn(id: string, text: string, sessionId?: string, content?: ContentBlock[]): Promise<void> {
  if (!config) { out({ type: "error", id, message: "Agent is not initialised." }); return; }
  const abort = new AbortController();
  turns.set(id, abort);
  try {
    const { model, provider } = createChatModel(config.model, process.env);
    const result = await runTurn({
      model, provider, sessionId, text, content,
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
    // No tools yet (L2): nothing asks for permission or an answer.
    case "permission": case "answer": break;
    case "shutdown": for (const t of turns.values()) t.abort(); setTimeout(() => process.exit(0), 300); break;
  }
});
lines.on("close", () => process.exit(0));
