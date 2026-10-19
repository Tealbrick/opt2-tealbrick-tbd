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
  /** Model provider for harnesses that support more than one (LangChain); absent = "anthropic". */
  provider?: "anthropic" | "openai";
  /** Model API base URL (default: the provider's own). Anthropic-compatible for "anthropic", OpenAI-compatible for "openai". */
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
  /**
   * TEST ONLY: switches the Connect consent layer off in the agent process (negative control of the injection fixture,
   * test/connect-injection.test.ts). The helper (main/services.ts) never sets it; test/connect-negative-control.test.ts checks that.
   */
  testNoConnectConsent?: boolean;
  /**
   * TEST ONLY: the negative control of the local-action injection fixture (test/local-injection.test.ts). The agent process
   * allows every local tool call at once, without asking the helper, so the fixture can see that the injected command really
   * runs when nothing stops it. The helper (main/services.ts) never sets it; test/local-negative-control.test.ts checks that.
   */
  testNoLocalConsent?: boolean;
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
  /** `selfTest`: the setup's check (WP-HARNESS L3): one throwaway exchange, no session saved, no tools bound to the model.
   *  A harness that can report its tool families answers `done.selfTest`. */
  | { type: "turn"; id: string; text: string; content?: ContentBlock[]; sessionId?: string; selfTest?: boolean }
  | { type: "cancel"; id: string }
  /** `remember`: the person's standing choice on a Connect card ("Always allow" / "Never allow"), or a remembered rule that decided. */
  | { type: "permission"; reqId: string; allow: boolean; message?: string; remember?: "always" | "never" }
  /** The person's answers, keyed by question text; null = not answered (declined, stopped, timed out). */
  | { type: "answer"; reqId: string; answers: Record<string, string> | null }
  | { type: "shutdown" };

export type AgentEvent =
  | { kind: "delta"; text: string }
  | { kind: "reset" }
  | { kind: "activity"; label: string | null }
  | { kind: "session"; sessionId: string }
  /** A Connect call is waiting for the owner's approval (C4): the Chat shows "Waiting for owner approval" with a link. */
  | { kind: "held"; tool: string; holdId: string; expiresAt: string };

/**
 * What a self-test turn reports about the tool families (WP-HARNESS L3, check 4): the families the config asked for,
 * the ones that came up, and one cheap read-only probe each (null = answered, text = the error).
 */
export interface SelfTestTools {
  configured: string[];
  loaded: string[];
  probes: Record<string, string | null>;
}

/**
 * What the agent process knows about a Connect call that needs the person's card (main/connectConsent.ts). The helper
 * reads the account and tool from the call itself for its rules; the agent adds the tool's effect, which only its
 * search results tell.
 */
export interface ConnectAsk {
  /** The Connect op ("tools_call", "channel_send", …). */
  op: string;
  /** The inner tool of a `tools_call`, else the op. The rule key. */
  tool: string;
  /** The account label the call names (`arguments.connect_account` of a tools_call, `account` of a named op), or "(default account)". The rule key (the helper compares it trimmed and in lower case). */
  account: string;
  /** For the card: "Gmail", "Buzz", "Chat channel". */
  service: string;
  /** read | write | outward | destructive | money | unknown. */
  effect: string;
  /**
   * Set when the call needs no card: "read" (a read op, or a tool the search showed as read) or "repeat" (the exact repeat of
   * a call the owner holds). The agent still sends the request: the helper checks the person's Never rules first.
   */
  free?: "read" | "repeat";
}

export type AgentToHelper =
  | { type: "ready" }
  | { type: "event"; id: string; event: AgentEvent }
  /** `connect` is set for a Connect call (the card is built in the helper from `input`). */
  /**
   * `check` is set by the agent's PreToolUse hook for a local tool (shell, file write, web): the helper answers only whether a
   * protected location or the person's Never rule refuses the call; it shows no card and the normal permission flow follows.
   */
  | { type: "permission_request"; id: string; reqId: string; tool: string; detail: string; input: Record<string, unknown>; connect?: ConnectAsk; check?: boolean }
  | { type: "question"; id: string; reqId: string; questions: AgentQuestion[] }
  | { type: "done"; id: string; sessionId: string; reply: string; selfTest?: SelfTestTools }
  | { type: "error"; id?: string; message: string };

/**
 * Built-in tools the default agent has at all; anything that changes this Mac asks the person first.
 * AskUserQuestion is the agent's way to ask the person a question (v1 question cards); it changes nothing.
 */
export const AGENT_TOOLS = ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "WebFetch", "WebSearch", ASK_TOOL];

/**
 * The Companion MCP tool that adds lines to the person's plan, under both harnesses' names. Equals FLOW_ADD_TOOLS in
 * main/localConsent.ts (that file has no relative imports, so the list is repeated here; test/local-flow-plan.test.ts checks both).
 */
export const FLOW_PLAN_ADD_TOOLS: readonly string[] = ["mcp__companion__flow_plan_add", "companion__flow_plan_add"];

/** The system-prompt line about planning the person's day: the same in both harnesses. */
export const PLAN_LINE = "To plan the person's day, use flow_plan_today and flow_plan_add (preview first, then save). TBD keeps the plan on this Mac.";

/**
 * Whether TBD's helper must decide a tool call (SEC-04). Harness-local tools, the bridge
 * (which decides its own calls) and AskUserQuestion (answered on a question card) pass; every built-in file, shell and web tool goes to the
 * helper's file policy: free inside the agent workspace and granted folders, secrets refused,
 * everything else asks the person.
 * Connect calls are the exception inside `mcp__tealbrick__`: their consent (reads free, everything else on the card, the
 * person's Always/Never rules) is main/connectConsent.ts, applied by both harnesses before this check.
 */
export function needsPermission(tool: string, input?: Record<string, unknown>): boolean {
  // The Companion plan tool: only `mode: "preview"` (exactly) is free. A save, any other mode and a call without arguments ask
  // (main/localConsent.ts decides: the person's Always/Never for `flow:add`, else the card). The CLI refuses every other mode.
  if (FLOW_PLAN_ADD_TOOLS.includes(tool)) return input?.mode !== "preview";
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
    case "mcp__companion__flow_plan_add":
    case "companion__flow_plan_add": return `Add lines to your plan${typeof input.day === "string" ? ` for ${input.day}` : ""}: ${s(input.text).slice(0, 200)}`;
    default: return `${tool} ${s(input).slice(0, 200)}`;
  }
}
