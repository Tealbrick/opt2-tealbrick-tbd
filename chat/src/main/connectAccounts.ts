import { heldOf, type McpClient, type McpToolResult } from "@opt2-tealbrick/bridge";
import { TOOL_NAME_RULE } from "@opt2-tealbrick/spec/bridge";
import type { AgentConnection } from "./agentIdentity";

/**
 * Connectors: the accounts Connect lets TBD's agent use (C280 C11, DESIGN-CONNECTORS §1, §2). One read, through TBD's OWN
 * agent identity (key connection K4, signer socket) and the local relay, exactly like Save to Knowledge and Flow's Task
 * Board (knowledgeSave.ts, flowTaskBoard.ts): this module never sees the person session and never calls Portal, Connect
 * or a provider. It calls `connect__accounts_list` only (a read) and only when the relay lists it: the bridge lists the
 * tools the owner granted, so no tool means no grant. Nothing it reads is written to disk.
 *
 * The entitlement read for `connect` stays in entitlements.ts; the native side combines both (gate, §1).
 */

/** `connect__accounts_list` (Connect manifest op `accounts_list`, BRIDGE tool name rule). */
export const ACCOUNTS_LIST_TOOL = `connect${TOOL_NAME_RULE.separator}accounts_list`;

export const CONNECT_MESSAGES = {
  notConnected: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect).",
  noGrant: "TBD's agent has no Connect access. In Portal, open your workspace, draw a line from TBD's agent to Connect, choose Read, then press Connect. Then open Connect and share an account with TBD's agent.",
  waiting: "Connect is waiting for the owner to approve sharing the account list. Check again after the owner approves.",
  timeout: "Connect did not answer in time. Try again.",
  paused: "The owner paused TBD's agent. Ask the owner to resume it in Portal.",
} as const;

export class ConnectAccountsError extends Error {
  readonly code: keyof typeof CONNECT_MESSAGES | "app_error";
  constructor(message: string, code: ConnectAccountsError["code"]) {
    super(message);
    this.name = "ConnectAccountsError";
    this.code = code;
  }
}

/** `as_me`: the owner's own account; `as_itself`: an account TBD's agent acts as itself. */
export type ConnectAccountKind = "as_me" | "as_itself";
/** The access TBD's agent has with the account (manifest enum). The words for the person come from the native side. */
export type ConnectAccountAccess = "read" | "read_update" | "read_update_delete";

export interface ConnectAccount {
  id: string;
  label: string;
  service: string;
  kind: ConnectAccountKind;
  access: ConnectAccountAccess;
}

export interface ConnectAccountsResult {
  /** false when Connectors cannot be used now (agent not connected, or the tool is not granted); `reason` says why. */
  available: boolean;
  reason?: string;
  accounts: ConnectAccount[];
}

export interface ConnectAccountsDeps {
  /** TBD's agent connection (ids and URLs only), or null when the agent is not connected. */
  connection(): AgentConnection | null;
  /** One MCP client to the local relay, started for this connection (relayLaunch.ts). */
  openRelay(c: AgentConnection): Promise<McpClient>;
  /** Per-RPC timeout (L23). Default 30 s. */
  rpcTimeoutMs?: number;
}

const LIMITS = { accounts: 100, id: 128, label: 200, service: 64, error: 300 } as const;

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new ConnectAccountsError(CONNECT_MESSAGES.timeout, "timeout")), ms);
  });
  return Promise.race([work, limit]).finally(() => clearTimeout(timer));
}

/** App error text for the person: no URLs, no long token-like runs, no home paths; one line, capped at 300 characters. */
export function scrubConnectError(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, "[link]")
    .replace(/\/(?:Users|home)\/[^\s"']+/g, "[path]")
    .replace(/\b(?:Bearer|Basic)\s+\S+/gi, "[hidden]")
    .replace(/[A-Za-z0-9_\-.=+/]{24,}/g, "[hidden]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, LIMITS.error);
}

function errorOf(result: McpToolResult): ConnectAccountsError {
  const env = result.structuredContent?.error as { code?: unknown; message?: unknown } | undefined;
  const code = typeof env?.code === "string" ? env.code : "app_error";
  if (code === "unknown_tool" || code === "forbidden" || code === "scope_denied") return new ConnectAccountsError(CONNECT_MESSAGES.noGrant, "noGrant");
  if (code === "paused") return new ConnectAccountsError(CONNECT_MESSAGES.paused, "paused");
  const raw = typeof env?.message === "string" && env.message ? env.message : (result.content?.find((c) => c.type === "text")?.text ?? code);
  const prefix = "Connect did not list the accounts: ";
  // The whole sentence stays within 300 characters.
  return new ConnectAccountsError(`${prefix}${scrubConnectError(raw).slice(0, LIMITS.error - prefix.length)}`, "app_error");
}

/** One manifest account → the reduced shape; anything off-shape is dropped (never trusted, never shown). */
export function accountOf(raw: unknown): ConnectAccount | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const o = raw as Record<string, unknown>;
  const text = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");
  const id = text(o.id, LIMITS.id);
  const label = text(o.label, LIMITS.label);
  const service = text(o.service, LIMITS.service);
  const kind = o.kind;
  const access = o.access;
  if (!id || !label || !service) return undefined;
  if (kind !== "as_me" && kind !== "as_itself") return undefined;
  if (access !== "read" && access !== "read_update" && access !== "read_update_delete") return undefined;
  return { id, label, service, kind, access };
}

/**
 * The accounts TBD's agent may use. `available:false` (no error) when the agent is not connected or the relay does not
 * list `connect__accounts_list`. Real failures (timeout, pause, app error) throw a `ConnectAccountsError` with a plain
 * sentence. The relay client is always closed.
 */
export async function connectAccounts(deps: ConnectAccountsDeps): Promise<ConnectAccountsResult> {
  const connection = deps.connection();
  if (!connection) return { available: false, reason: CONNECT_MESSAGES.notConnected, accounts: [] };
  const rpc = deps.rpcTimeoutMs ?? 30_000;
  const client = await withTimeout(deps.openRelay(connection), rpc);
  try {
    await withTimeout(client.initialize("tbd-connect"), rpc);
    const tools = await withTimeout(client.listTools(), rpc);
    // The relay lists only what the owner granted: no tool, no grant.
    if (!tools.some((t) => t.name === ACCOUNTS_LIST_TOOL)) return { available: false, reason: CONNECT_MESSAGES.noGrant, accounts: [] };
    const result = await withTimeout(client.callTool(ACCOUNTS_LIST_TOOL, {}), rpc);
    if (heldOf(result)) throw new ConnectAccountsError(CONNECT_MESSAGES.waiting, "waiting");
    if (result.isError) throw errorOf(result);
    const list = result.structuredContent?.accounts;
    const accounts: ConnectAccount[] = [];
    const seen = new Set<string>();
    for (const raw of Array.isArray(list) ? list : []) {
      const account = accountOf(raw);
      if (account && !seen.has(account.id) && accounts.length < LIMITS.accounts) { seen.add(account.id); accounts.push(account); }
    }
    return { available: true, accounts };
  } finally {
    client.close();
  }
}
