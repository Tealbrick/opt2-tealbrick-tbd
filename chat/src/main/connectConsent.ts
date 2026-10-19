import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
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
  "identities_list", "buzz_scheduled", "channel_inbox", "channel_conversations", "tb_skills",
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

/** The rule key of a call that names no account. Reserved: it cannot be confused with an account label. */
export const DEFAULT_ACCOUNT = "(default account)";

/** The account the call names, as written (trimmed), or the reserved default. */
function accountOf(value: unknown): string {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, 200) : DEFAULT_ACCOUNT;
}

/** The form of an account in a rule: trimmed and lower case, so "Work Inbox" and "work inbox" are one account. */
export const normaliseAccount = (account: string): string => account.trim().toLowerCase();
const normaliseTool = (tool: string): string => tool.trim().toLowerCase();

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
 * What a Connect call is, from the call itself. The account of a `tools_call` is `arguments.connect_account` and nothing
 * else (never a field next to `arguments`); a named op has its own `account` argument. A call without an account gets the
 * reserved default key. The effect of a `tools_call` is `unknown` here: only the agent's search results tell.
 */
function describeCall(op: string, input: unknown): ConnectAsk {
  const args = isRecord(input) ? input : {};
  if (op === "tools_call") {
    const inner = typeof args.tool === "string" ? args.tool.trim() : "";
    return { op, tool: inner || op, account: accountOf(innerArguments(args).connect_account), service: serviceOf(op, inner), effect: "unknown" };
  }
  return { op, tool: op, account: accountOf(args.account), service: serviceOf(op, ""), effect: CONNECT_READ_OPS.has(op) ? "read" : (OP_EFFECT[op] ?? "unknown") };
}

/**
 * Classify one tool call. Not a Connect tool → `none` (the caller's own rules stay). A read op, or a `tools_call` of a
 * tool whose search result said `read` → `allow`. Everything else, and every tool the agent never saw in a search → `ask`.
 * `allow` is only the card verdict: the person's Never rule is checked before it (decideConnectCall).
 */
export function classifyConnect(tool: string, input: unknown, effects: EffectLookup): ConnectVerdict {
  const op = connectOp(tool);
  if (op === null) return { kind: "none" };
  if (CONNECT_READ_OPS.has(op)) return { kind: "allow", op };
  const ask = describeCall(op, input);
  if (op === "tools_call") {
    const effect = ask.tool !== op ? effects.effectOf(ask.tool) : undefined;
    if (effect === "read") return { kind: "allow", op };
    return { kind: "ask", ask: { ...ask, effect: effect ?? "unknown" } };
  }
  return { kind: "ask", ask };
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
  return searchedTools(result).filter((t): t is { tool: string; effect: string } => typeof t.effect === "string");
}

/** Every tool a `connect__tools_search` result lists; `effect` is absent when the result gives none for that tool. */
export function searchedTools(result: unknown): { tool: string; effect?: string }[] {
  const list = structuredOf(result)?.tools;
  if (!Array.isArray(list)) return [];
  const out: { tool: string; effect?: string }[] = [];
  for (const item of list) {
    if (isRecord(item) && typeof item.tool === "string" && item.tool) out.push({ tool: item.tool, ...(typeof item.effect === "string" && item.effect ? { effect: item.effect } : {}) });
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

/** How long an effect the agent learned from a search stays good. After this the tool asks again until a search shows it again. */
export const EFFECT_TTL_MS = 15 * 60_000;

/** Tools of the Teal Brick workspace bridge (every app: Connect, Knowledge, Kanban, …) as the harnesses name them. */
export const isRelayTool = (tool: string): boolean => tool.startsWith("mcp__tealbrick__");

/** A hold in the result of a call to any tool of the workspace bridge, not only Connect (the Chat shows one notice per hold). */
export function heldOfRelayResult(tool: string, result: unknown): ReturnType<typeof heldOfResult> {
  return isRelayTool(tool) ? heldOfResult(result) : undefined;
}

/**
 * The effect of each Connect tool the agent saw in a `connect__tools_search` result of this agent process (memory only,
 * never written to disk). The effect is Connect's own classification of the tool, not text from the model or the service.
 * A tool the agent did not see in a search has no effect here: its call asks.
 *
 * An entry expires after 15 minutes. Every search result replaces the entries of the tools it lists (a tool the search
 * lists without an effect loses its entry), so a tool that changed from read to write asks at once; a tool the latest search
 * did not list keeps its entry only until it expires. Names compare without regard to case.
 */
export function createEffectCache(max = 5000, now: () => number = Date.now, ttlMs = EFFECT_TTL_MS) {
  const effects = new Map<string, { effect: string; at: number }>();
  const key = normaliseTool;
  const prune = () => { for (const [k, e] of effects) if (now() - e.at >= ttlMs) effects.delete(k); };
  return {
    record(result: unknown): number {
      const found = searchedTools(result);
      for (const { tool, effect } of found) {
        effects.delete(key(tool)); // newest last
        if (effect === undefined) continue;
        effects.set(key(tool), { effect, at: now() });
        if (effects.size > max) effects.delete(effects.keys().next().value as string);
      }
      return found.filter((t) => t.effect !== undefined).length;
    },
    effectOf(tool: string): string | undefined {
      const entry = effects.get(key(tool));
      if (!entry) return undefined;
      if (now() - entry.at >= ttlMs) { effects.delete(key(tool)); return undefined; }
      return entry.effect;
    },
    size: (): number => { prune(); return effects.size; },
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
export interface ConnectConsentOptions {
  /**
   * TEST ONLY. Returns true to switch the whole Connect consent layer off in this agent process (nothing is routed to the
   * helper, so no card ever shows). It exists for the negative control of the injection fixture: with it, the injected send
   * must reach the relay, which proves the fixture can see a send at all. The helper never sets it (see test/connect-negative-control.test.ts).
   */
  disabled?: () => boolean;
}

export function createConnectConsent(now: () => number = Date.now, options: ConnectConsentOptions = {}) {
  const cache = createEffectCache(5000, now);
  const repeats = new Map<string, number>();
  const pruned = () => { for (const [key, until] of repeats) if (until <= now()) repeats.delete(key); return repeats; };
  const off = () => options.disabled?.() === true;
  const verdict = (tool: string, input: unknown): ConnectVerdict => {
    if (off()) return { kind: "none" };
    const v = classifyConnect(tool, input, cache);
    return v.kind === "ask" && pruned().has(callFingerprint(tool, input)) ? { kind: "allow", op: v.ask.op } : v;
  };
  return {
    classify: verdict,
    /** Whether the person must decide this call. */
    needsAsk: (tool: string, input: unknown): boolean => verdict(tool, input).kind === "ask",
    /** The ask to send with the permission request, if this call needs a card. */
    askOf(tool: string, input: unknown): ConnectAsk | undefined {
      const v = verdict(tool, input);
      return v.kind === "ask" ? v.ask : undefined;
    },
    /**
     * What to send the helper for EVERY Connect call, free or not: the helper checks the person's Never rules before it lets
     * a free call pass (a Never rule on a tool that was later found to be read still denies). A call that needs no card carries
     * `free`: "read" (a read op, or a tool the search showed as read) or "repeat" (the exact repeat of a held call).
     */
    routeOf(tool: string, input: unknown): ConnectAsk | undefined {
      if (off()) return undefined;
      const op = connectOp(tool);
      if (op === null) return undefined;
      const v = classifyConnect(tool, input, cache);
      if (v.kind === "allow") return { ...describeCall(op, input), effect: "read", free: "read" };
      if (v.kind === "ask") return pruned().has(callFingerprint(tool, input)) ? { ...v.ask, free: "repeat" } : v.ask;
      return undefined;
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
/** The line on a card that has no "Always allow" (destructive, money, unknown effect, first contact). */
export const EVERY_TIME_LINE = "TBD asks every time for this kind of action.";

/**
 * Whether the card offers "Always allow": only for a tool whose effect is known to be `write` or `outward`, and never for a
 * first-contact tool. Destructive, money and unknown effects ask every time. (Never allow is offered for every tool.)
 */
export function alwaysOffered(effect: string, tool: string): boolean {
  return (effect === "write" || effect === "outward") && !/__first_contact/i.test(tool);
}

const EFFECT_LINES: Readonly<Record<string, string>> = {
  read: "read: only reads",
  write: "write: changes data",
  outward: "outward: sends something to other people",
  destructive: "destructive: deletes something",
  money: "money: can move money",
  unknown: "unknown: TBD cannot tell what this does",
};

/** Argument fields that name who or where something goes: every one that is present shows on the card. */
const TARGET_FIELDS = [
  "to", "recipients", "recipient", "recipient_email", "to_email", "extra_recipients", "cc", "bcc", "email", "emails",
  "attendees", "participants", "users", "user_id", "relays", "channel", "channel_id", "conversation", "chat_id", "person", "phone_number", "url", "link",
] as const;
/** The first present one is the content shown on the card. */
const CONTENT_FIELDS = ["body", "text", "message", "content", "markdown_text", "html", "caption"] as const;
const ATTACHMENT_FIELDS = ["attachments", "attachment", "files", "file"] as const;
const ATTACHMENT_NAME_FIELDS = ["name", "filename", "file_name", "title"] as const;
const SHOWN_ELSEWHERE: ReadonlySet<string> = new Set<string>([...TARGET_FIELDS, ...CONTENT_FIELDS, ...ATTACHMENT_FIELDS, "subject", "connect_account"]);

const LIST_MAX = 10;
const ITEM_MAX = 600;
const OTHER_LINE_MAX = 600;
const OTHER_VALUE_MAX = 80;

/**
 * Text for the card from the model or a service: without the characters that change what a line looks like. Bidirectional
 * controls (U+202A–U+202E, U+2066–U+2069, and the marks U+200E, U+200F, U+061C) and control characters (C0 and C1, and DEL)
 * go, except the line feed. A card must show the text in the order it will be sent.
 */
export function cleanCardText(text: string): string {
  let out = "";
  for (const ch of text) {
    const c = ch.codePointAt(0) ?? 0;
    const bidi = (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) || c === 0x200e || c === 0x200f || c === 0x061c;
    const control = (c < 0x20 && c !== 0x0a) || (c >= 0x7f && c <= 0x9f);
    if (!bidi && !control) out += ch;
  }
  return out;
}

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

/** One value as text: a string as it is, a number or boolean as a word, anything else as JSON. Null when there is nothing to show. */
function itemText(value: unknown): string | null {
  if (typeof value === "string") return cleanCardText(value).trim() || null;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (value === null || value === undefined) return null;
  try { return cleanCardText(JSON.stringify(value) ?? ""); } catch { return "[a value too deep to show]"; }
}

/** "3 items: a, b, c"; more than ten: the first ten, then "and N more". An item is never cut short of ITEM_MAX characters. */
function counted(parts: string[], noun: readonly [string, string] = ["item", "items"]): string | null {
  if (parts.length === 0) return null;
  const shownParts = parts.slice(0, LIST_MAX).map((p) => clip(p, ITEM_MAX));
  const more = parts.length - shownParts.length;
  return `${parts.length} ${parts.length === 1 ? noun[0] : noun[1]}: ${shownParts.join(", ")}${more > 0 ? `, and ${more} more` : ""}`;
}

/** A target value: a list shows its count and every item (to ten); a text with several addresses is a list too. */
function targetText(value: unknown): string | null {
  if (Array.isArray(value)) return counted(value.map(itemText).filter((p): p is string => p !== null));
  if (typeof value === "string") {
    const parts = cleanCardText(value).split(/[,;\n]/).map((p) => p.trim()).filter(Boolean);
    if (parts.length > 1) return counted(parts);
    return parts.length === 1 ? clip(parts[0], ITEM_MAX) : null;
  }
  const one = itemText(value);
  return one === null ? null : clip(one, ITEM_MAX);
}

function contentText(args: Record<string, unknown>): string | undefined {
  for (const field of CONTENT_FIELDS) {
    const v = itemText(args[field]);
    if (v) return clip(v, CARD_CONTENT_MAX);
  }
  return undefined;
}

function attachmentText(args: Record<string, unknown>): string | undefined {
  const names: string[] = [];
  for (const field of ATTACHMENT_FIELDS) {
    const v = args[field];
    for (const item of Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]) {
      if (typeof item === "string") { const t = cleanCardText(item).trim(); if (t) names.push(t); continue; }
      const named = isRecord(item) ? ATTACHMENT_NAME_FIELDS.map((f) => item[f]).find((n) => typeof n === "string" && n.trim()) : undefined;
      names.push(typeof named === "string" ? cleanCardText(named).trim() : "(a file without a name)");
    }
  }
  return counted(names, ["file", "files"]) ?? undefined;
}

/** "Other arguments: key=value; …": every argument the card shows nowhere else, each value clipped, the whole line at most 600 characters. */
function otherText(args: Record<string, unknown>, op: string): string | undefined {
  const pairs: string[] = [];
  for (const [key, value] of Object.entries(args)) {
    if (SHOWN_ELSEWHERE.has(key) || (op !== "tools_call" && key === "account")) continue;
    pairs.push(`${clip(cleanCardText(key), 40)}=${clip(itemText(value) ?? "null", OTHER_VALUE_MAX)}`);
  }
  if (pairs.length === 0) return undefined;
  const prefix = "Other arguments: ";
  const budget = OTHER_LINE_MAX - prefix.length;
  const rest = (left: number) => (left > 0 ? `; and ${left} more` : "");
  let body = "";
  for (let n = 0; n < pairs.length; n++) {
    const next = body ? `${body}; ${pairs[n]}` : pairs[n];
    if (next.length + rest(pairs.length - n - 1).length > budget) {
      // This pair does not fit with the note about the ones after it: stop before it (the first pair is cut to fit).
      if (n === 0) return prefix + clip(pairs[0], budget - rest(pairs.length - 1).length) + rest(pairs.length - 1);
      return prefix + body + rest(pairs.length - n);
    }
    body = next;
  }
  return prefix + body;
}

/** The arguments the card reads: `arguments` of a tools_call, else the call's own input. */
function cardArguments(op: string, input: unknown): Record<string, unknown> {
  const args = isRecord(input) ? input : {};
  return op === "tools_call" ? innerArguments(args) : args;
}

export function buildConnectCard(ask: ConnectAsk, input: unknown): ConnectCard {
  const args = cardArguments(ask.op, input);
  const service = cleanCardText(ask.service);
  const tool = cleanCardText(ask.tool);
  const account = cleanCardText(ask.account);
  const effect = EFFECT_LINES[ask.effect] ? ask.effect : "unknown";
  const target: ConnectCard["target"] = [];
  for (const field of TARGET_FIELDS) {
    const v = targetText(args[field]);
    if (v) target.push({ label: field, value: v });
  }
  const content = contentText(args);
  const attachments = attachmentText(args);
  const other = otherText(args, ask.op);
  const subjectText = itemText(args.subject);
  const offered = alwaysOffered(effect, ask.tool);
  return {
    title: `Allow TBD's agent to use ${service}: ${tool}?`,
    service,
    tool,
    account,
    accountLine: ask.account === DEFAULT_ACCOUNT ? "Account: default (the account Connect picks)" : `Account: ${account}`,
    effect,
    effectLine: `Effect: ${EFFECT_LINES[effect]}`,
    target,
    ...(subjectText ? { subject: clip(subjectText, 200) } : {}),
    ...(content ? { content } : {}),
    ...(attachments ? { attachments: `Attachments: ${attachments}` } : {}),
    ...(other ? { other } : {}),
    alwaysOffered: offered,
    hint: offered ? ALWAYS_HINT : EVERY_TIME_LINE,
  };
}

// ---------------------------------------------------------------- remembered rules

export type ConsentDecision = "always" | "never";

export interface ConsentRule {
  /** The account in its rule form (`normaliseAccount`), or the reserved "(default account)". */
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

/** A rule as the file keeps it. The "default" of earlier versions is the reserved default key now. */
function ruleAccount(account: string): string {
  const a = normaliseAccount(account);
  return a === "" || a === "default" ? DEFAULT_ACCOUNT : a;
}

/** At most this many `.corrupt-*` copies are made; after that a bad file is left where it is and the next save replaces it. */
export const MAX_CORRUPT_COPIES = 3;

export interface ConsentIo {
  /** Test seam: the rename that puts the new file in place. */
  rename(from: string, to: string): void;
}

/**
 * The rules file `connect-consent.json` in the helper's state folder: mode 0600, written atomically (temp file, then
 * rename; the temp file is removed when the write fails). A file that cannot be read or has the wrong shape is moved aside
 * (`.corrupt-<time>`, at most three copies, never deleted by TBD) and the rules start empty; `unreadable()` says so until the
 * person's next choice is saved. It holds account labels and tool names the person chose, nothing else (no tool results, no
 * message content). Accounts compare trimmed and in lower case; tools compare in lower case.
 */
export function createConsentStore(file: string, now: () => number = Date.now, io: ConsentIo = { rename: renameSync }) {
  const folder = dirname(file);
  const copyName = new RegExp(`^${basename(file).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\.corrupt-\\d+$`);
  /** Our own corrupt copies, by exact name. */
  const copies = (): string[] => {
    try { return readdirSync(folder).filter((n) => copyName.test(n)).map((n) => join(folder, n)); } catch { return []; }
  };
  const mtime = (path: string): number => { try { return statSync(path).mtimeMs; } catch { return 0; } };

  function load(): ConsentFile {
    if (!existsSync(file)) return emptyFile();
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      if (!isRecord(parsed) || parsed.version !== 1 || !isRecord(parsed.workspaces)) throw new Error("unexpected shape");
      const workspaces: Record<string, ConsentRule[]> = {};
      for (const [key, rules] of Object.entries(parsed.workspaces)) {
        if (!Array.isArray(rules) || !rules.every(validRule)) throw new Error("unexpected rules");
        workspaces[key] = merged(rules.map((r) => ({ account: ruleAccount(r.account), tool: r.tool, decision: r.decision, at: r.at })));
      }
      return { version: 1, workspaces };
    } catch {
      if (copies().length < MAX_CORRUPT_COPIES) {
        try { renameSync(file, `${file}.corrupt-${now()}`); } catch { /* cannot move it: start empty anyway */ }
      }
      return emptyFile();
    }
  }
  /** Two rules for the same account and tool (after normalising) become one: Never wins, else the newer. */
  function merged(rules: ConsentRule[]): ConsentRule[] {
    const byKey = new Map<string, ConsentRule>();
    for (const r of rules) {
      const key = `${r.account}\u0000${normaliseTool(r.tool)}`;
      const old = byKey.get(key);
      if (!old || (old.decision !== "never" && (r.decision === "never" || r.at >= old.at))) byKey.set(key, r);
    }
    return [...byKey.values()];
  }
  function save(data: ConsentFile): void {
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    const temp = `${file}.${process.pid}.tmp`;
    try {
      writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
      chmodSync(temp, 0o600);
      io.rename(temp, file);
    } catch (error) {
      try { unlinkSync(temp); } catch { /* it was never made */ }
      throw error;
    }
  }
  const same = (r: ConsentRule, account: string, tool: string) => r.account === ruleAccount(account) && normaliseTool(r.tool) === normaliseTool(tool);
  return {
    decision(ws: string, account: string, tool: string): ConsentDecision | null {
      return load().workspaces[ws]?.find((r) => same(r, account, tool))?.decision ?? null;
    },
    remember(ws: string, account: string, tool: string, decision: ConsentDecision): void {
      const data = load();
      const rules = (data.workspaces[ws] ?? []).filter((r) => !same(r, account, tool));
      rules.push({ account: ruleAccount(account), tool: tool.trim(), decision, at: new Date(now()).toISOString() });
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
    /**
     * True when the rules file could not be read and TBD kept a copy: the file in place is bad, or a kept copy is newer than the
     * file in place (no file yet). It stays true until the person's next choice is saved. Settings says so.
     */
    unreadable(): boolean {
      const kept = copies();
      if (existsSync(file)) {
        try {
          const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
          if (!isRecord(parsed) || parsed.version !== 1 || !isRecord(parsed.workspaces)) return true;
        } catch { return true; }
        return kept.some((c) => mtime(c) > mtime(file));
      }
      return kept.length > 0;
    },
  };
}

export type ConsentStore = ReturnType<typeof createConsentStore>;

/** What Settings › Connectors reads: the rules of one workspace (none without one) and whether the file was unreadable (a copy was kept). */
export function consentListing(store: ConsentStore, workspace: string | null): { choices: ConsentRule[]; unreadable: boolean } {
  const choices = workspace ? store.list(workspace) : [];
  return { choices, unreadable: store.unreadable() };
}

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
 * the helper's own reading of the call (never from the agent's word); for a `tools_call` the agent adds the tool's effect (only
 * its search results tell) and says when a call is free (a read, or the repeat of a held call).
 *
 * Order: a `never` rule denies first, before anything that lets a call pass (a read the agent found, a read op, a held
 * repeat). Then a free call passes. Then an `always` rule allows, but only for a tool whose effect allows "Always"
 * (`alwaysOffered`): destructive, money, unknown and first-contact tools ask every time, whatever an older rule says.
 * Otherwise the person decides on the card; an "Always allow" answer to a card that did not offer it counts once.
 */
export async function decideConnectCall(req: ConnectPermissionRequest, deps: ConnectPermissionDeps): Promise<ConnectPermissionResult> {
  const op = connectOp(req.tool);
  if (op === null) return { allow: false, message: "This is not a Connect call." };
  const own = describeCall(op, req.input);
  const free = CONNECT_READ_OPS.has(op) || (op === "tools_call" && (req.connect?.free === "read" || req.connect?.free === "repeat"));
  const ask: ConnectAsk = { ...own, effect: op === "tools_call" && typeof req.connect?.effect === "string" ? req.connect.effect : own.effect };
  const rule = deps.workspace ? deps.store.decision(deps.workspace, ask.account, ask.tool) : null;
  if (rule === "never") return { allow: false, message: NEVER_MESSAGE(ask.tool, ask.account), remember: "never" };
  if (free) return { allow: true };
  const offered = alwaysOffered(ask.effect, ask.tool);
  if (rule === "always" && offered) return { allow: true, remember: "always" };
  const answer = await deps.askPerson(buildConnectCard(ask, req.input), ask);
  const choice: ConsentDecision | undefined = answer.remember ? (answer.allow ? (offered ? "always" : undefined) : "never") : undefined;
  // Without a workspace there is nothing to key a rule to: the choice counts once.
  if (choice && deps.workspace) deps.store.remember(deps.workspace, ask.account, ask.tool, choice);
  if (answer.allow) return { allow: true, ...(choice ? { remember: choice } : {}) };
  return { allow: false, message: choice === "never" ? NEVER_MESSAGE(ask.tool, ask.account) : "The person declined this action.", ...(choice ? { remember: choice } : {}) };
}
