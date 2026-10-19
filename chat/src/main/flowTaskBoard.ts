import { createHash } from "node:crypto";
import { heldOf, pollHold, type McpClient, type McpToolResult } from "@opt2-tealbrick/bridge";
import { TOOL_NAME_RULE } from "@opt2-tealbrick/spec/bridge";
import type { AgentConnection } from "./agentIdentity";

/**
 * Flow's Task Board source (F4, C282). The person's own open issues are read, and an issue is marked done
 * ONLY after the person's tap. Both calls go through TBD's OWN agent identity (key connection K4, local
 * relay), exactly like Listening's "Save to Knowledge" (knowledgeSave.ts): this module never sees the
 * person session and never calls Portal. Grants, holds and receipts apply as for any agent call.
 *
 * Q1: Flow never creates Task Board issues. Only `issues_list` (read) and `issue_complete` are called.
 */

/** `kanban__issues_list` and `kanban__issue_complete` (Task Board manifest ops, BRIDGE tool name rule). */
export const ISSUES_LIST_TOOL = `kanban${TOOL_NAME_RULE.separator}issues_list`;
export const ISSUE_COMPLETE_TOOL = `kanban${TOOL_NAME_RULE.separator}issue_complete`;

export const TASKBOARD_MESSAGES = {
  notConnected: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect).",
  noGrant: "TBD's agent has no Task Board access. In Portal, open your workspace, draw a line from TBD's agent to Task Board, choose Read and work, then press Connect.",
  waiting: "Waiting for owner approval",
  stillWaiting: "Still waiting for owner approval. Mark it done again after the owner approves.",
  listWaiting: "Task Board is waiting for the owner to approve sharing your list. Check again after the owner approves.",
  denied: "The owner declined marking this done on Task Board.",
  expired: "The owner approval expired. Mark it done again to ask the owner again.",
  timeout: "Task Board did not answer in time. Try again.",
  paused: "The owner paused TBD's agent. Ask the owner to resume it in Portal.",
  noStatus: "Task Board did not confirm the new status. Check the issue on Task Board.",
} as const;

export class FlowTaskBoardError extends Error {
  readonly code: keyof typeof TASKBOARD_MESSAGES | "app_error" | "input_invalid";
  constructor(message: string, code: FlowTaskBoardError["code"]) {
    super(message);
    this.name = "FlowTaskBoardError";
    this.code = code;
  }
}

/** One issue as Flow shows it (the manifest output, reduced to what the sheet and the plan row need). */
export interface FlowIssue {
  id: string;
  title: string;
  summary: string;
  project: string;
  status: "in_progress" | "todo";
  priority: "low" | "medium" | "high";
  ready: boolean;
}

export interface FlowTaskBoardListResult {
  /** false when Flow cannot use Task Board now (not connected, or the tool is not granted). */
  available: boolean;
  reason?: string;
  issues: FlowIssue[];
}

export interface FlowTaskBoardCompleteInput {
  issue: string;
  result: string;
}

export interface FlowTaskBoardCompleteResult {
  issue: string;
  status: string;
}

export interface FlowTaskBoardDeps {
  /** TBD's agent connection (ids and URLs only), or null when the agent is not connected. */
  connection(): AgentConnection | null;
  /** One MCP client to the local relay, started for this connection (relayLaunch.ts). */
  openRelay(c: AgentConnection): Promise<McpClient>;
  /** Progress for the person ("Waiting for owner approval"). */
  onStatus?(message: string): void;
  /** Per-RPC timeout (L23). Default 30 s. */
  rpcTimeoutMs?: number;
  /** How long to wait for an owner decision before answering "still waiting". Default 10 min. */
  holdWaitMs?: number;
  /** Hold poll interval (pollHold enforces at least 10 s). */
  pollIntervalMs?: number;
}

const PAGE_SIZE = 100;
const MAX_ISSUES = 200;
const MAX_PAGES = 8;
const LIMITS = { issue: 64, result: 4000, title: 500, summary: 500, project: 64, error: 300 } as const;

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new FlowTaskBoardError(TASKBOARD_MESSAGES.timeout, "timeout")), ms);
  });
  return Promise.race([work, limit]).finally(() => clearTimeout(timer));
}

/** App error text for the person: no URLs, no long token-like runs, no home paths; one line, capped. */
export function scrubErrorText(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, "[link]")
    .replace(/\/(?:Users|home)\/[^\s"']+/g, "[path]")
    .replace(/\b(?:Bearer|Basic)\s+\S+/gi, "[hidden]")
    .replace(/[A-Za-z0-9_\-.=+/]{24,}/g, "[hidden]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, LIMITS.error);
}

function errorOf(result: McpToolResult, what: string): FlowTaskBoardError {
  const env = result.structuredContent?.error as { code?: unknown; message?: unknown } | undefined;
  const code = typeof env?.code === "string" ? env.code : "app_error";
  if (code === "unknown_tool" || code === "forbidden" || code === "scope_denied") return new FlowTaskBoardError(TASKBOARD_MESSAGES.noGrant, "noGrant");
  if (code === "paused") return new FlowTaskBoardError(TASKBOARD_MESSAGES.paused, "paused");
  const raw = typeof env?.message === "string" && env.message ? env.message : (result.content?.find((c) => c.type === "text")?.text ?? code);
  return new FlowTaskBoardError(`Task Board did not ${what}: ${scrubErrorText(raw)}`, "app_error");
}

/** Opens the relay, runs `work`, always closes the client. */
async function withRelay<T>(deps: FlowTaskBoardDeps, connection: AgentConnection, work: (client: McpClient, rpc: number) => Promise<T>): Promise<T> {
  const rpc = deps.rpcTimeoutMs ?? 30_000;
  const client = await withTimeout(deps.openRelay(connection), rpc);
  try {
    await withTimeout(client.initialize("tbd-flow"), rpc);
    return await work(client, rpc);
  } finally {
    client.close();
  }
}

// MARK: list

function str(value: unknown, max: number): string | undefined {
  return typeof value === "string" ? value.slice(0, max) : undefined;
}

/** One manifest issue → the reduced shape; anything off-shape is dropped (never trusted, never shown). */
export function issueOf(raw: unknown): FlowIssue | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const o = raw as Record<string, unknown>;
  const id = str(o.id, LIMITS.issue);
  const title = str(o.title, LIMITS.title)?.trim();
  const status = o.status;
  if (!id || !title || (status !== "in_progress" && status !== "todo")) return undefined;
  const priority = o.priority === "high" || o.priority === "low" ? o.priority : "medium";
  return { id, title, summary: str(o.summary, LIMITS.summary) ?? "", project: str(o.project, LIMITS.project) ?? "", status, priority, ready: o.ready === true };
}

/** Pages of one status (follows the cursor, stops at the cap, at a repeated cursor and at MAX_PAGES). */
async function listStatus(client: McpClient, rpc: number, status: "in_progress" | "todo", room: number): Promise<FlowIssue[]> {
  const out: FlowIssue[] = [];
  let cursor: string | undefined;
  const seen = new Set<string>();
  const ids = new Set<string>();
  for (let page = 0; page < MAX_PAGES && out.length < room; page += 1) {
    const args: Record<string, unknown> = { assignee: "owner", status, limit: PAGE_SIZE };
    if (cursor) args.cursor = cursor;
    const result = await withTimeout(client.callTool(ISSUES_LIST_TOOL, args), rpc);
    if (heldOf(result)) throw new FlowTaskBoardError(TASKBOARD_MESSAGES.listWaiting, "listWaiting");
    if (result.isError) throw errorOf(result, "list your issues");
    const body = result.structuredContent ?? {};
    const issues = Array.isArray(body.issues) ? body.issues : [];
    for (const raw of issues) {
      const issue = issueOf(raw);
      // One id once, even when a page repeats (a cursor that does not move).
      if (issue && issue.status === status && out.length < room && !ids.has(issue.id)) { ids.add(issue.id); out.push(issue); }
    }
    const next = typeof body.cursor === "string" && body.cursor ? body.cursor : undefined;
    if (!next || seen.has(next)) break;
    seen.add(next);
    cursor = next;
  }
  return out;
}

/**
 * The owner's open issues: in progress first, then todo (cursor pages, at most 200 in all). `available:false`
 * (no error) when the agent is not connected or the relay does not list the tool: the person has no Task Board
 * access, so Flow keeps its list on this Mac. Real failures (timeout, pause, app error) throw.
 */
export async function flowTaskBoardList(deps: FlowTaskBoardDeps): Promise<FlowTaskBoardListResult> {
  const connection = deps.connection();
  if (!connection) return { available: false, reason: TASKBOARD_MESSAGES.notConnected, issues: [] };
  return withRelay(deps, connection, async (client, rpc) => {
    const tools = await withTimeout(client.listTools(), rpc);
    // The relay lists only what the owner granted: no tool, no grant.
    if (!tools.some((t) => t.name === ISSUES_LIST_TOOL)) return { available: false, reason: TASKBOARD_MESSAGES.noGrant, issues: [] };
    const inProgress = await listStatus(client, rpc, "in_progress", MAX_ISSUES);
    const todo = await listStatus(client, rpc, "todo", MAX_ISSUES - inProgress.length);
    return { available: true, issues: [...inProgress, ...todo] };
  });
}

// MARK: complete

/** Exact `issue_complete` arguments: trimmed, within the manifest limits. */
export function completeArguments(input: FlowTaskBoardCompleteInput): { issue: string; result: string } {
  const issue = input.issue.trim();
  if (!issue || issue.length > LIMITS.issue) throw new FlowTaskBoardError("Choose a Task Board issue first.", "input_invalid");
  const result = input.result.trim().slice(0, LIMITS.result);
  if (!result) throw new FlowTaskBoardError("Write a short result for the issue.", "input_invalid");
  return { issue, result };
}

/**
 * Deterministic idempotency key: issue id + hash of the result. A retry of the same tap (lost reply, restart,
 * approval) never completes twice. 8-128 chars (BRIDGE rule).
 */
export function idempotencyKey(args: { issue: string; result: string }): string {
  const id = args.issue.toLowerCase().replace(/[^a-z0-9_-]/g, "").slice(0, 48) || "issue";
  const hash = createHash("sha256").update(args.result).digest("hex").slice(0, 32);
  return `tbd-flow-${id}-${hash}`;
}

function completeResultOf(result: McpToolResult, issue: string): FlowTaskBoardCompleteResult {
  if (result.isError) throw errorOf(result, "mark it done");
  const out = result.structuredContent ?? {};
  // manifest output: { issue: { id, status, ... }, promoted }
  const status = (out.issue as { status?: unknown } | undefined)?.status;
  if (typeof status !== "string") throw new FlowTaskBoardError(TASKBOARD_MESSAGES.noStatus, "noStatus");
  return { issue, status };
}

export async function flowTaskBoardComplete(input: FlowTaskBoardCompleteInput, deps: FlowTaskBoardDeps): Promise<FlowTaskBoardCompleteResult> {
  const connection = deps.connection();
  if (!connection) throw new FlowTaskBoardError(TASKBOARD_MESSAGES.notConnected, "notConnected");
  const args = completeArguments(input);
  const meta = { [TOOL_NAME_RULE.idempotencyMetaKey]: idempotencyKey(args) };
  return withRelay(deps, connection, async (client, rpc) => {
    const tools = await withTimeout(client.listTools(), rpc);
    if (!tools.some((t) => t.name === ISSUE_COMPLETE_TOOL)) throw new FlowTaskBoardError(TASKBOARD_MESSAGES.noGrant, "noGrant");
    const call = () => withTimeout(client.callTool(ISSUE_COMPLETE_TOOL, args, meta), rpc);
    const first = await call();
    const held = heldOf(first);
    if (!held) return completeResultOf(first, args.issue);

    deps.onStatus?.(TASKBOARD_MESSAGES.waiting);
    // pollHold checks its signal only between waits; the cap answers at once and stops the poll loop.
    const stop = new AbortController();
    let capped = false;
    let cap: NodeJS.Timeout | undefined;
    const limit = new Promise<"expired">((resolve) => { cap = setTimeout(() => { capped = true; stop.abort(); resolve("expired"); }, deps.holdWaitMs ?? 600_000); });
    let outcome: "approved" | "denied" | "expired";
    try {
      // After the cap the relay client is closed: a late check must not touch it.
      const check: McpClient["callTool"] = (name, a, m) => (stop.signal.aborted ? Promise.reject(new Error("stopped")) : withTimeout(client.callTool(name, a, m), rpc));
      const poll = pollHold(check, held, { intervalMs: deps.pollIntervalMs, signal: stop.signal });
      outcome = await Promise.race([poll, limit]);
    } finally { clearTimeout(cap); stop.abort(); }
    if (outcome === "denied") throw new FlowTaskBoardError(TASKBOARD_MESSAGES.denied, "denied");
    if (outcome === "expired") throw new FlowTaskBoardError(capped ? TASKBOARD_MESSAGES.stillWaiting : TASKBOARD_MESSAGES.expired, capped ? "stillWaiting" : "expired");
    // Approved: repeat the exact same call (same arguments, same idempotency key).
    const second = await call();
    if (heldOf(second)) throw new FlowTaskBoardError(TASKBOARD_MESSAGES.stillWaiting, "stillWaiting");
    return completeResultOf(second, args.issue);
  });
}
