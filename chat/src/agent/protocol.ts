/**
 * The private stdio protocol between the TBD Chat helper (person side) and
 * TBD's default agent process (agent side). One JSON object per line.
 *
 * The agent process never receives the person credential (K3): its config
 * carries only the model route, its own MCP servers and local paths. The
 * Teal Brick relay authenticates as the AGENT (K4 handle via the signer
 * socket), never as the person.
 */

import type { ContentBlock } from "../shared/message";

/** The SDK tool the agent uses to ask the person; answered through TBD's question cards. */
export const ASK_TOOL = "AskUserQuestion";

export interface AgentModel {
  /** Model id, e.g. from the "agent" route in Settings → Models. */
  model: string;
  /** Anthropic API base URL (default https://api.anthropic.com). */
  baseUrl?: string;
  /** Cloud provider settings (Bedrock, Vertex AI, Foundry; model pins), names from the fixed list in agent/modelEnv.ts only. */
  env?: Record<string, string>;
  /** Names (fixed list in agent/modelEnv.ts) of the person's model credential in the agent's own environment. */
  secretNames?: string[];
}


export interface AgentConfig {
  model: AgentModel;
  /** Default working folder for the agent's file tools. */
  cwd: string;
  /** Where the harness keeps its own state (never the user's ~/.claude). */
  stateDir: string;
  /** Path of the bundled Claude Code executable used by the Agent SDK. */
  claudeExecutable?: string;
  /** Harness-local tools (C5): Companion timeline MCP server and Listening CLI. */
  companionCli?: string;
  listeningCli?: string;
  /** Teal Brick apps through the local relay (stdio MCP child), once connected. */
  relay?: { command: string; args: string[]; env: Record<string, string> };
  /** Extra system prompt text (identity, workspace). */
  systemAppend?: string;
  /** OS sandbox for the shell tool (filePolicy.sandboxSettings, SEC-04). */
  sandbox?: Record<string, unknown>;
}

/** One question of the SDK's AskUserQuestion tool (1–4 per call; "Other" free text is always allowed). */
export interface AgentQuestion {
  question: string;
  header?: string;
  options: { label: string; description?: string }[];
  multiSelect?: boolean;
}

export type HelperToAgent =
  | { type: "init"; config: AgentConfig }
  /** `content` carries attached files (Anthropic content blocks, text first); `text` alone otherwise. */
  | { type: "turn"; id: string; text: string; content?: ContentBlock[]; sessionId?: string }
  | { type: "cancel"; id: string }
  | { type: "permission"; reqId: string; allow: boolean; message?: string }
  /** The person's answers, keyed by question text; null = not answered (declined, stopped, timed out). */
  | { type: "answer"; reqId: string; answers: Record<string, string> | null }
  | { type: "shutdown" };

export type AgentEvent =
  | { kind: "delta"; text: string }
  | { kind: "reset" }
  | { kind: "activity"; label: string | null }
  | { kind: "session"; sessionId: string };

export type AgentToHelper =
  | { type: "ready" }
  | { type: "event"; id: string; event: AgentEvent }
  | { type: "permission_request"; id: string; reqId: string; tool: string; detail: string; input: Record<string, unknown> }
  | { type: "question"; id: string; reqId: string; questions: AgentQuestion[] }
  | { type: "done"; id: string; sessionId: string; reply: string }
  | { type: "error"; id?: string; message: string };

/**
 * Built-in tools the default agent has at all; anything that changes this Mac asks the person first.
 * AskUserQuestion is the agent's way to ask the person a question (v1 question cards); it changes nothing.
 */
export const AGENT_TOOLS = ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "WebFetch", "WebSearch", ASK_TOOL];

/**
 * Whether TBD's helper must decide a tool call (SEC-04). Harness-local tools, the bridge
 * (which decides its own calls) and AskUserQuestion (answered on a question card) pass; every built-in file, shell and web tool goes to the
 * helper's file policy: free inside the agent workspace and granted folders, secrets refused,
 * everything else asks the person.
 */
export function needsPermission(tool: string): boolean {
  return !(tool === ASK_TOOL || tool.startsWith("mcp__companion__") || tool.startsWith("mcp__listening__") || tool.startsWith("mcp__tealbrick__"));
}

/** One line for the consent card: the exact effect, never "the agent wants a tool". */
export function describeToolCall(tool: string, input: Record<string, unknown>): string {
  const s = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v ?? ""));
  switch (tool) {
    case "Bash": return `Run: ${s(input.command)}`;
    case "Write": return `Write file ${s(input.file_path)}`;
    case "Edit": return `Edit file ${s(input.file_path)}`;
    case "WebFetch": return `Fetch ${s(input.url)}`;
    case "WebSearch": return `Search the web: ${s(input.query)}`;
    default: return `${tool} ${s(input).slice(0, 200)}`;
  }
}
