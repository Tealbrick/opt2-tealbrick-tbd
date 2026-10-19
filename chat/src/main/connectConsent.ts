import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ConnectAsk } from "../agent/protocol";
import type { ConnectCard } from "../shared/ipc";

/**
 * Consent rules for TBD's agent when it uses Connect (C280 C11, D-C1). ONE shared module, used by BOTH agent
 * harnesses (the Agent SDK agent in agent/main.ts and the LangChain agent in agent/harness/langchain.ts) and by the
 * helper (main/services.ts):
 *
 *   classify   which Connect calls are free (reads) and which need the person's card (everything else, and every
 *              tool whose effect is not known to be `read`)
 *   effects    the effect of each Connect tool, learned from the `connect__tools_search` results the agent saw
 *   card       what the card shows, built from the call's arguments (service, account, target, first 300 characters)
 *   rules      "Always allow" / "Never allow" per (account, tool) and workspace, in `connect-consent.json`
 *
 * Kept free of relative value imports (type imports only) so node tests can load it directly under type stripping.
 * Server holds always stay on top of this: the card never replaces them.
 */

// ---------------------------------------------------------------- classification

/** The relay lists Connect tools as `connect__<op>`; the harnesses add `mcp__tealbrick__` in front. */
const PREFIXES = ["mcp__tealbrick__connect__", "connect__"] as const;

/** The op name of a Connect tool call, or null when the tool is not a Connect tool. */
export function connectOp(tool: string): string | null {
  for (const prefix of PREFIXES) {
    if (tool.startsWith(prefix)) return tool.slice(prefix.length) || null;
  }
  return null;
}

/** Connect ops that only read: free without a card. Every other op asks. */
export const CONNECT_READ_OPS: ReadonlySet<string> = new Set([
  "accounts_list", "tools_search", "tb_hold_status", "buzz_identity", "buzz_channels", "buzz_read",
  "identities_list", "buzz_scheduled", "channel_inbox", "channel_conversations",
]);

/** The effect word each Connect op has in its manifest (Connect 0.5.12), for the card. */
const OP_EFFECT: Readonly<Record<string, string>> = {
  buzz_post: "outward", buzz_dm_first: "outward", buzz_dm: "outward", buzz_react: "outward", buzz_edit: "outward",
  buzz_delete: "destructive", buzz_schedule: "outward", buzz_schedule_cancel: "write",
  channel_send: "outward", channel_reply: "outward", channel_dm_first: "outward", channel_dm: "outward",
  channel_edit: "outward", channel_delete: "destructive", channel_react: "outward",
};

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/** The `arguments` of a `tools_call` (an object, or a JSON object in a string). */
function innerArguments(input: Record<string, unknown>): Record<string, unknown> {
  const a = input.arguments;
  if (isRecord(a)) return a;
  if (typeof a === "string") {
    try { const parsed: unknown = JSON.parse(a); if (isRecord(parsed)) return parsed; } catch { /* not JSON: no arguments */ }
  }
  return {};
}

const DEFAULT_ACCOUNT = "default";

function accountOf(value: unknown): string {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, 200) : DEFAULT_ACCOUNT;
}

const titleCase = (s: string) => (s ? s[0].toUpperCase() + s.slice(1).toLowerCase() : s);

/** "GMAIL_SEND_EMAIL" → "Gmail"; Buzz and chat-channel ops get their own names. */
function serviceOf(op: string, tool: string): string {
  if (op.startsWith("buzz_")) return "Buzz";
  if (op.startsWith("channel_")) return "Chat channel";
  if (op === "tools_call") return titleCase(tool.split(/[_.\-:]/)[0] ?? "") || "a connected service";
  return "Connect";
}

export type ConnectVerdict =
  | { kind: "none" }
  | { kind: "allow"; op: string }
  | { kind: "ask"; ask: ConnectAsk };

export interface EffectLookup { effectOf(tool: string): string | undefined }

/**
 * Classify one tool call. Not a Connect tool → `none` (the caller's own rules stay). A read op, or a `tools_call` of a
 * tool whose search result said `read` → `allow`. Everything else, and every tool the agent never saw in a search → `ask`.
 */
export function classifyConnect(tool: string, input: unknown, effects: EffectLookup): ConnectVerdict {
  const op = connectOp(tool);
  if (op === null) return { kind: "none" };
  if (CONNECT_READ_OPS.has(op)) return { kind: "allow", op };
  const args = isRecord(input) ? input : {};
  if (op === "tools_call") {
    const inner = typeof args.tool === "string" ? args.tool.trim() : "";
    const effect = inner ? effects.effectOf(inner) : undefined;
    if (effect === "read") return { kind: "allow", op };
    const account = accountOf(innerArguments(args).connect_account ?? args.connect_account);
    return { kind: "ask", ask: { op, tool: inner || op, account, service: serviceOf(op, inner), effect: effect ?? "unknown" } };
  }
  return { kind: "ask", ask: { op, tool: op, account: accountOf(args.account), service: serviceOf(op, ""), effect: OP_EFFECT[op] ?? "unknown" } };
}

// ---------------------------------------------------------------- results the agent saw

/** The structured part of a tool result, whichever harness it came from (MCP result, SDK hook response, LangChain message). */
export function structuredOf(value: unknown): Record<string, unknown> | null {
  if (!isRecord(value)) {
    if (typeof value === "string") return jsonObject(value);
    if (Array.isArray(value)) return jsonObject(textOf(value));
    return null;
  }
  if (isRecord(value.structuredContent)) return value.structuredContent;
  // LangChain MCP adapter: ToolMessage.artifact = [{ type: "mcp_structured_content", data }, …]
  if (Array.isArray(value.artifact)) {
    for (const part of value.artifact) {
      if (isRecord(part) && part.type === "mcp_structured_content" && isRecord(part.data)) return part.data;
    }
  }
  const content = value.content;
  if (typeof content === "string") return jsonObject(content);
  if (Array.isArray(content)) return jsonObject(textOf(content));
  return null;
}

function textOf(blocks: unknown[]): string {
  return blocks.map((b) => (isRecord(b) && b.type === "text" && typeof b.text === "string" ? b.text : typeof b === "string" ? b : "")).join("");
}

function jsonObject(text: string): Record<string, unknown> | null {
  try { const parsed: unknown = JSON.parse(text); return isRecord(parsed) ? parsed : null; } catch { return null; }
}

/** `connect__tools_search` output: `{ tools: [{ tool, effect, … }] }` → name and effect pairs. */
export function searchedEffects(result: unknown): { tool: string; effect: string }[] {
  const list = structuredOf(result)?.tools;
  if (!Array.isArray(list)) return [];
  const out: { tool: string; effect: string }[] = [];
  for (const item of list) {
    if (isRecord(item) && typeof item.tool === "string" && item.tool && typeof item.effect === "string") out.push({ tool: item.tool, effect: item.effect });
  }
  return out;
}

/** What a held result says (the shape of @opt2-tealbrick/bridge `heldOf`), from any harness's result value. */
export function heldOfResult(result: unknown): { holdId: string; expiresAt: string; checkWith: string } | undefined {
  const s = structuredOf(result);
  if (s?.status !== "held") return undefined;
  if (typeof s.holdId !== "string" || typeof s.checkWith !== "string" || typeof s.expiresAt !== "string") return undefined;
  return { holdId: s.holdId, expiresAt: s.expiresAt, checkWith: s.checkWith };
}

/**
 * The effect of each Connect tool the agent saw in a `connect__tools_search` result of this agent process (memory only,
 * never written to disk). The effect is Connect's own classification of the tool, not text from the model or the service.
 * A tool the agent did not see in a search has no effect here: its call asks.
 */
export function createEffectCache(max = 5000) {
  const effects = new Map<string, string>();
  return {
    record(result: unknown): number {
      const found = searchedEffects(result);
      for (const { tool, effect } of found) {
        effects.delete(tool); // newest last
        effects.set(tool, effect);
        if (effects.size > max) effects.delete(effects.keys().next().value as string);
      }
      return found.length;
    },
    effectOf: (tool: string): string | undefined => effects.get(tool),
    size: (): number => effects.size,
  };
}

/** How long a call the owner has to approve may be repeated without a second card (the bridge's repeat window). */
export const HOLD_REPEAT_MS = 15 * 60_000;

/** A stable text for one call: the tool and its input with object keys sorted. */
export function callFingerprint(tool: string, input: unknown): string {
  const sorted = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(sorted);
    if (isRecord(v)) return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])]));
    return v;
  };
  return `${tool}\n${JSON.stringify(sorted(input ?? {}))}`;
}

/**
 * One per agent process: classify calls and learn from the results that pass through.
 *
 * Two things are remembered, in memory only: the effect of each tool the agent found with `connect__tools_search`, and
 * the calls the owner still has to approve. The person approved such a call on the card already; after the owner approves
 * it the model repeats the exact same call, and that repeat does not ask the person a second time.
 */
export function createConnectConsent(now: () => number = Date.now) {
  const cache = createEffectCache();
  const repeats = new Map<string, number>();
  const pruned = () => { for (const [key, until] of repeats) if (until <= now()) repeats.delete(key); return repeats; };
  const verdict = (tool: string, input: unknown): ConnectVerdict => {
    const v = classifyConnect(tool, input, cache);
    return v.kind === "ask" && pruned().has(callFingerprint(tool, input)) ? { kind: "allow", op: v.ask.op } : v;
  };
  return {
    classify: verdict,
    /** Whether the person must decide this call. */
    needsAsk: (tool: string, input: unknown): boolean => verdict(tool, input).kind === "ask",
    /** The ask to send with the permission request, if this call needs one. */
    askOf(tool: string, input: unknown): ConnectAsk | undefined {
      const v = verdict(tool, input);
      return v.kind === "ask" ? v.ask : undefined;
    },
    /**
     * Call with every tool result. `connect__tools_search` results teach effects. A held result of a call that asked
     * lets its exact repeat pass without a card; any other result of that call ends the allowance.
     */
    observe(tool: string, input: unknown, result: unknown): void {
      const op = connectOp(tool);
      if (op === null) return;
      if (op === "tools_search") { cache.record(result); return; }
      const key = callFingerprint(tool, input);
      repeats.delete(key);
      const held = heldOfResult(result);
      if (held && classifyConnect(tool, input, cache).kind === "ask") {
        const until = Date.parse(held.expiresAt);
        repeats.set(key, Math.min(Number.isFinite(until) ? until : Infinity, now() + HOLD_REPEAT_MS));
      }
    },
    effects: cache,
  };
}

export type ConnectConsent = ReturnType<typeof createConnectConsent>;

// ---------------------------------------------------------------- the card

export const CARD_CONTENT_MAX = 300;
export const ALWAYS_HINT = "Always allow is TBD's own permission on this Mac for this account and tool. It is not a Rules rule (that needs Rules).";

const EFFECT_LINES: Readonly<Record<string, string>> = {
  read: "read: only reads",
  write: "write: changes data",
  outward: "outward: sends something to other people",
  destructive: "destructive: deletes something",
  money: "money: can move money",
  unknown: "unknown: TBD cannot tell what this does",
};

/** Argument fields that name who or where something goes. */
const TARGET_FIELDS = ["to", "recipients", "recipient", "recipient_email", "cc", "bcc", "email", "emails", "channel", "conversation", "person", "url", "link"] as const;
const CONTENT_FIELDS = ["body", "text", "message", "content"] as const;

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function shown(value: unknown): string | undefined {
  if (typeof value === "string") return value.trim() || undefined;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    const parts = value.map((v) => shown(v)).filter((v): v is string => Boolean(v));
    return parts.length ? parts.join(", ") : undefined;
  }
  return undefined;
}

/** The arguments the card reads: `arguments` of a tools_call, else the call's own input. */
function cardArguments(op: string, input: unknown): Record<string, unknown> {
  const args = isRecord(input) ? input : {};
  return op === "tools_call" ? innerArguments(args) : args;
}

export function buildConnectCard(ask: ConnectAsk, input: unknown): ConnectCard {
  const args = cardArguments(ask.op, input);
  const target: ConnectCard["target"] = [];
  for (const field of TARGET_FIELDS) {
    const v = shown(args[field]);
    if (v) target.push({ label: field, value: clip(v, 200) });
  }
  let content: string | undefined;
  for (const field of CONTENT_FIELDS) {
    const v = shown(args[field]);
    if (v) { content = clip(v, CARD_CONTENT_MAX); break; }
  }
  const subjectText = shown(args.subject);
  return {
    title: `Allow TBD's agent to use ${ask.service}: ${ask.tool}?`,
    service: ask.service,
    tool: ask.tool,
    account: ask.account,
    accountLine: ask.account === DEFAULT_ACCOUNT ? "Account: default (the account Connect picks)" : `Account: ${ask.account}`,
    effect: ask.effect,
    effectLine: `Effect: ${EFFECT_LINES[ask.effect] ?? EFFECT_LINES.unknown}`,
    target,
    ...(subjectText ? { subject: clip(subjectText, 200) } : {}),
    ...(content ? { content } : {}),
    hint: ALWAYS_HINT,
  };
}

// ---------------------------------------------------------------- remembered rules

export type ConsentDecision = "always" | "never";

export interface ConsentRule {
  account: string;
  tool: string;
  decision: ConsentDecision;
  /** ISO time the person chose it. */
  at: string;
}

interface ConsentFile {
  version: 1;
  /** Rules by workspace key (issuer and workspace id): one workspace's rules never apply to another. */
  workspaces: Record<string, ConsentRule[]>;
}

/** The key one workspace of one control plane has in the rules file. */
export function workspaceKey(issuer: string, workspaceId: string): string {
  return `${issuer.replace(/\/+$/, "")}|${workspaceId}`;
}

const emptyFile = (): ConsentFile => ({ version: 1, workspaces: {} });

function validRule(r: unknown): r is ConsentRule {
  return isRecord(r) && typeof r.account === "string" && typeof r.tool === "string" && (r.decision === "always" || r.decision === "never") && typeof r.at === "string";
}

/**
 * The rules file `connect-consent.json` in the helper's state folder: mode 0600, written atomically (temp file, then
 * rename). A file that cannot be read or has the wrong shape is moved aside (`.corrupt-<time>`) and the rules start
 * empty. It holds account labels and tool names the person chose, nothing else (no tool results, no message content).
 */
export function createConsentStore(file: string, now: () => number = Date.now) {
  function load(): ConsentFile {
    if (!existsSync(file)) return emptyFile();
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      if (!isRecord(parsed) || parsed.version !== 1 || !isRecord(parsed.workspaces)) throw new Error("unexpected shape");
      const workspaces: Record<string, ConsentRule[]> = {};
      for (const [key, rules] of Object.entries(parsed.workspaces)) {
        if (!Array.isArray(rules) || !rules.every(validRule)) throw new Error("unexpected rules");
        workspaces[key] = rules.map((r) => ({ account: r.account, tool: r.tool, decision: r.decision, at: r.at }));
      }
      return { version: 1, workspaces };
    } catch {
      try { renameSync(file, `${file}.corrupt-${now()}`); } catch { /* cannot move it: start empty anyway */ }
      return emptyFile();
    }
  }
  function save(data: ConsentFile): void {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
    chmodSync(temp, 0o600);
    renameSync(temp, file);
  }
  const same = (r: ConsentRule, account: string, tool: string) => r.account === account && r.tool === tool;
  return {
    decision(ws: string, account: string, tool: string): ConsentDecision | null {
      return load().workspaces[ws]?.find((r) => same(r, account, tool))?.decision ?? null;
    },
    remember(ws: string, account: string, tool: string, decision: ConsentDecision): void {
      const data = load();
      const rules = (data.workspaces[ws] ?? []).filter((r) => !same(r, account, tool));
      rules.push({ account, tool, decision, at: new Date(now()).toISOString() });
      data.workspaces[ws] = rules;
      save(data);
    },
    list(ws: string): ConsentRule[] {
      return [...(load().workspaces[ws] ?? [])];
    },
    /** True when a rule was removed. */
    revoke(ws: string, account: string, tool: string): boolean {
      const data = load();
      const before = data.workspaces[ws] ?? [];
      const after = before.filter((r) => !same(r, account, tool));
      if (after.length === before.length) return false;
      if (after.length) data.workspaces[ws] = after; else delete data.workspaces[ws];
      save(data);
      return true;
    },
  };
}

export type ConsentStore = ReturnType<typeof createConsentStore>;

// ---------------------------------------------------------------- the helper's decision

export interface ConnectPermissionRequest {
  tool: string;
  input: Record<string, unknown>;
  /** What the agent process classified (its effect cache knows the tool's effect; the helper's does not). */
  connect?: ConnectAsk;
}

export interface ConnectPermissionDeps {
  store: ConsentStore;
  /** The workspace TBD's agent is connected to (`workspaceKey`), or null when it is not connected. */
  workspace: string | null;
  /** Show the card. `remember` with `allow` = Always allow; `remember` without `allow` = Never allow. */
  askPerson(card: ConnectCard, ask: ConnectAsk): Promise<{ allow: boolean; remember: boolean }>;
}

export interface ConnectPermissionResult {
  allow: boolean;
  message?: string;
  /** Set when a remembered rule decided, or the person chose Always/Never on the card. */
  remember?: ConsentDecision;
}

export const NEVER_MESSAGE = (tool: string, account: string) => `The person told TBD never to allow ${tool} for ${account}.`;

/**
 * Decide one Connect call that the agent process sent as a permission request. The account and tool of the rule come from
 * the helper's own reading of the call (never from the agent's word); the agent only adds the tool's effect.
 * `never` denies without asking, `always` allows without a card, otherwise the person decides on the card.
 */
export async function decideConnectCall(req: ConnectPermissionRequest, deps: ConnectPermissionDeps): Promise<ConnectPermissionResult> {
  const verdict = classifyConnect(req.tool, req.input, { effectOf: () => undefined });
  if (verdict.kind === "allow") return { allow: true };
  if (verdict.kind === "none") return { allow: false, message: "This is not a Connect call." };
  const ask: ConnectAsk = { ...verdict.ask, effect: typeof req.connect?.effect === "string" ? req.connect.effect : verdict.ask.effect };
  if (deps.workspace) {
    const rule = deps.store.decision(deps.workspace, ask.account, ask.tool);
    if (rule === "never") return { allow: false, message: NEVER_MESSAGE(ask.tool, ask.account), remember: "never" };
    if (rule === "always") return { allow: true, remember: "always" };
  }
  const answer = await deps.askPerson(buildConnectCard(ask, req.input), ask);
  const choice: ConsentDecision | undefined = answer.remember ? (answer.allow ? "always" : "never") : undefined;
  // Without a workspace there is nothing to key a rule to: the choice counts once.
  if (choice && deps.workspace) deps.store.remember(deps.workspace, ask.account, ask.tool, choice);
  if (answer.allow) return { allow: true, ...(choice ? { remember: choice } : {}) };
  return { allow: false, message: choice === "never" ? NEVER_MESSAGE(ask.tool, ask.account) : "The person declined this action.", ...(choice ? { remember: choice } : {}) };
}
