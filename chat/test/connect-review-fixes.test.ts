import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AIMessage } from "@langchain/core/messages";
import { tool, type StructuredToolInterface } from "@langchain/core/tools";
import { z } from "zod";
import {
  ALWAYS_HINT, DEFAULT_ACCOUNT, EFFECT_TTL_MS, EVERY_TIME_LINE, MAX_CORRUPT_COPIES, alwaysOffered, buildConnectCard, classifyConnect, cleanCardText,
  consentListing, createConnectConsent, createConsentStore, createEffectCache, decideConnectCall, heldOfRelayResult, normaliseAccount, workspaceKey,
  type ConnectCard,
} from "../src/main/connectConsent.ts";
import { connectPreToolUse, HOOK_FAILED_MESSAGE } from "../src/agent/connectHook.ts";
import { createRequestIds } from "../src/agent/requestIds.ts";
import { connectAnswers } from "../src/shared/connectButtons.ts";
import { createInteractions, createToolSeam } from "../src/agent/harness/langchainTools.ts";
import { needsPermission, type AgentToHelper, type ConnectAsk } from "../src/agent/protocol.ts";

// The dev.16 Connectors review fixes (S1–S8, N2–N6). Every test here fails on the code of 2bdc427 and passes after the fixes.

const temp = () => mkdtempSync(join(tmpdir(), "tbd-connect-fixes-"));
const askOf = (over: Partial<ConnectAsk> = {}): ConnectAsk => ({ op: "tools_call", tool: "gmail_send_email", account: "Work inbox", service: "Gmail", effect: "outward", ...over });
const card = (args: Record<string, unknown>, over: Partial<ConnectAsk> = {}): ConnectCard => buildConnectCard(askOf(over), { tool: over.tool ?? "gmail_send_email", arguments: args });

// ---------------------------------------------------------------- S1, N3: the card shows every target

describe("S1 the card shows every target", () => {
  test("an array of objects shows as JSON, with a count (recipients: [{email}])", () => {
    const c = card({ recipients: [{ email: "a@example.com" }, { email: "b@example.com", name: "Bea" }] });
    assert.deepEqual(c.target, [{ label: "recipients", value: '2 items: {"email":"a@example.com"}, {"email":"b@example.com","name":"Bea"}' }]);
  });

  test("an object value shows as JSON, never dropped", () => {
    assert.deepEqual(card({ to: { email: "a@example.com" } }).target, [{ label: "to", value: '{"email":"a@example.com"}' }]);
  });

  test("every added target key shows when present", () => {
    const keys = ["attendees", "channel_id", "chat_id", "phone_number", "to_email", "extra_recipients", "relays", "cc", "bcc", "emails", "participants", "users", "user_id"];
    for (const key of keys) {
      const c = card({ [key]: key === "emails" ? ["x@example.com"] : `value-of-${key}` });
      assert.equal(c.target.length, 1, key);
      assert.equal(c.target[0].label, key);
      assert.ok(c.target[0].value.includes(key === "emails" ? "x@example.com" : `value-of-${key}`), key);
      assert.equal(c.other, undefined, `${key} is a target, not an other argument`);
    }
  });

  test("a list shows its count and every item up to ten, then 'and N more'; no address is cut", () => {
    const mails = Array.from({ length: 13 }, (_, i) => `person-number-${i}@example.com`);
    const c = card({ to: mails });
    const value = c.target[0].value;
    assert.ok(value.startsWith("13 items: "), value);
    for (const m of mails.slice(0, 10)) assert.ok(value.includes(m), m);
    for (const m of mails.slice(10)) assert.ok(!value.includes(m), `${m} is behind 'and 3 more'`);
    assert.ok(value.endsWith(", and 3 more"), value);
    assert.equal(card({ to: mails.slice(0, 10) }).target[0].value.includes("more"), false, "ten items: all of them, no 'more'");
    assert.equal(card({ to: ["only@example.com"] }).target[0].value, "1 item: only@example.com");
  });

  test("a text with several addresses is a list too (a hidden recipient behind a long string)", () => {
    const many = Array.from({ length: 40 }, (_, i) => `user${i}@example.com`).join(", ");
    const value = card({ to: many }).target[0].value;
    assert.ok(value.startsWith("40 items: user0@example.com, user1@example.com"), value);
    assert.ok(value.endsWith(", and 30 more"));
    assert.equal(card({ to: "a@example.com; b@example.com" }).target[0].value, "2 items: a@example.com, b@example.com");
  });

  test("an item is never cut inside an address (a long item is cut only past 600 characters and says so)", () => {
    const longAddress = `${"a".repeat(240)}@${"b".repeat(60)}.example.com`;
    assert.equal(card({ to: [longAddress] }).target[0].value, `1 item: ${longAddress}`);
    const huge = "x".repeat(2000);
    assert.ok(card({ to: [huge] }).target[0].value.endsWith("…"));
  });

  test("other arguments: every remaining non-content key=value, each value clipped, the whole line at most 600 characters", () => {
    const c = card({ to: "a@example.com", body: "hi", subject: "s", connect_account: "Work inbox", priority: "high", thread_id: "t-1", flags: { urgent: true }, note: "n".repeat(500) });
    assert.ok(c.other?.startsWith("Other arguments: "));
    assert.ok(c.other?.includes("priority=high; thread_id=t-1; flags={\"urgent\":true}; note="));
    assert.ok(!c.other?.includes("to=") && !c.other?.includes("body=") && !c.other?.includes("subject=") && !c.other?.includes("connect_account="));
    assert.ok(c.other?.includes(`note=${"n".repeat(80)}…`), "a value is clipped to 80 characters");
    const many: Record<string, unknown> = {};
    for (let i = 0; i < 60; i++) many[`argument_${i}`] = `value-${i}-${"v".repeat(60)}`;
    const wide = card(many).other ?? "";
    assert.ok(wide.length <= 600, `${wide.length}`);
    assert.match(wide, /; and \d+ more$/, "the rest is counted, not hidden");
    assert.equal(card({ a: 1 }).other, "Other arguments: a=1");
    assert.equal(card({}).other, undefined);
  });

  test("the content is the first of body, text, message, content, markdown_text, html, caption", () => {
    assert.equal(card({ markdown_text: "md", html: "h", caption: "c" }).content, "md");
    assert.equal(card({ html: "<b>h</b>", caption: "c" }).content, "<b>h</b>");
    assert.equal(card({ caption: "just a caption" }).content, "just a caption");
    assert.equal(card({ body: "b", text: "t" }).content, "b");
    assert.equal(card({ body: "x".repeat(400) }).content, `${"x".repeat(300)}…`);
    assert.equal(card({ body: { parts: ["x"] } }).content, '{"parts":["x"]}');
  });

  test("attachment names show when the call names files", () => {
    const c = card({ to: "a@example.com", attachments: [{ filename: "plan.pdf", data: "AAAA".repeat(1000) }, "notes.txt", { name: "pic.png" }, {}] });
    assert.equal(c.attachments, "Attachments: 4 files: plan.pdf, notes.txt, pic.png, (a file without a name)");
    assert.equal(c.other, undefined, "the file data is not an 'other argument'");
    assert.equal(card({ body: "x" }).attachments, undefined);
    assert.equal(card({ file: { title: "one.txt" } }).attachments, "Attachments: 1 file: one.txt");
  });

  test("a value that cannot be shown as JSON is said so, not dropped", () => {
    const cyclic: Record<string, unknown> = {};
    cyclic.self = cyclic;
    assert.deepEqual(card({ to: cyclic }).target, [{ label: "to", value: "[a value too deep to show]" }]);
  });
});

describe("N3 bidi and control characters never reach the card", () => {
  const RLO = "‮";
  test("cleanCardText strips U+202A–U+202E, U+2066–U+2069, C0 and C1 controls except the line feed", () => {
    for (let c = 0x202a; c <= 0x202e; c++) assert.equal(cleanCardText(`a${String.fromCodePoint(c)}b`), "ab");
    for (let c = 0x2066; c <= 0x2069; c++) assert.equal(cleanCardText(`a${String.fromCodePoint(c)}b`), "ab");
    for (let c = 0; c < 0x20; c++) assert.equal(cleanCardText(`a${String.fromCodePoint(c)}b`), c === 0x0a ? "a\nb" : "ab", `C0 ${c}`);
    for (let c = 0x7f; c <= 0x9f; c++) assert.equal(cleanCardText(`a${String.fromCodePoint(c)}b`), "ab", `C1 ${c}`);
    assert.equal(cleanCardText("plain ünïcode — ok"), "plain ünïcode — ok");
  });

  test("every string of the card is clean: title, tool, account, target, subject, content, attachments, other", () => {
    const dirty = (s: string) => `${s.slice(0, 1)}${RLO}${s.slice(1)}⁦\u0007`;
    const c = buildConnectCard(
      askOf({ tool: dirty("tool"), service: dirty("Gmail"), account: dirty("Work") }),
      { tool: "x", arguments: { to: [dirty("to@example.com")], subject: dirty("subject"), body: dirty("body"), attachments: [dirty("f.pdf")], extra: dirty("value"), [dirty("key")]: "v" } },
    );
    const all = [c.title, c.service, c.tool, c.account, c.accountLine, ...c.target.flatMap((t) => [t.label, t.value]), c.subject, c.content, c.attachments, c.other, c.effectLine, c.hint];
    for (const text of all) assert.ok(text !== undefined && cleanCardText(text) === text, JSON.stringify(text));
    assert.equal(c.target[0].value, "1 item: to@example.com");
  });
});

// ---------------------------------------------------------------- S2: per-process request ids, replies only to the asker

describe("S2 request ids carry a per-process nonce", () => {
  test("ids look like <nonce>:p1 / <nonce>:q2 and differ between processes", () => {
    const a = createRequestIds();
    const b = createRequestIds();
    assert.match(a.permission(), /^[0-9a-f]{12}:p1$/);
    assert.match(a.question(), /^[0-9a-f]{12}:q2$/);
    assert.notEqual(a.nonce, b.nonce);
    assert.notEqual(a.permission(), b.permission(), "both count from 1; the nonce keeps them apart");
    assert.equal(createRequestIds("fixed").permission(), "fixed:p1");
  });

  test("the LangChain agent's interactions use them", async () => {
    const sent: AgentToHelper[] = [];
    const first = createInteractions((m) => sent.push(m), { needsPermission, describe: (t) => t });
    const second = createInteractions((m) => sent.push(m), { needsPermission, describe: (t) => t });
    void first.gate("t", "Bash", { command: "ls" });
    void second.gate("t", "Bash", { command: "ls" });
    const ids = sent.map((m) => (m as { reqId: string }).reqId);
    assert.match(ids[0], /^[0-9a-f]{12}:p1$/);
    assert.match(ids[1], /^[0-9a-f]{12}:p1$/);
    assert.notEqual(ids[0], ids[1]);
    // an answer for the other process's id opens nothing
    first.onPermission({ reqId: ids[1], allow: true });
    const decision = await Promise.race([first.gate("t", "Bash", { command: "pwd" }, AbortSignal.abort()), new Promise((r) => setTimeout(() => r("pending"), 20))]);
    assert.deepEqual(decision, { allow: false, message: "Turn stopped." });
  });
});

// ---------------------------------------------------------------- S3: tb_skills is a read

test("S3 tb_skills is a read op: free, in both name forms", () => {
  for (const name of ["connect__tb_skills", "mcp__tealbrick__connect__tb_skills"]) {
    assert.deepEqual(classifyConnect(name, {}, { effectOf: () => undefined }), { kind: "allow", op: "tb_skills" });
  }
});

// ---------------------------------------------------------------- S4: the hook fails closed

describe("S4 the PreToolUse hook denies on any error", () => {
  const pre = { hook_event_name: "PreToolUse", tool_name: "mcp__tealbrick__connect__tools_call", tool_input: { tool: "gmail_send_email", arguments: { to: "a@example.com" } } };
  const signal = new AbortController().signal;
  const denied = (out: unknown) => (out as { hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string } }).hookSpecificOutput;

  test("a classifier that throws is a deny, and nothing is sent to the helper", async () => {
    let requested = 0;
    const hook = connectPreToolUse({ route: () => { throw new Error("classifier broke"); }, request: async () => { requested++; return { allow: true }; } });
    const out = await hook(pre, undefined, { signal });
    assert.equal(denied(out)?.permissionDecision, "deny");
    assert.equal(denied(out)?.permissionDecisionReason, HOOK_FAILED_MESSAGE);
    assert.equal(requested, 0);
  });

  test("a request that throws (closed pipe, input that cannot be sent) is a deny", async () => {
    const hook = connectPreToolUse({ route: () => askOf(), request: async () => { throw new Error("EPIPE"); } });
    assert.equal(denied(await hook(pre, undefined, { signal }))?.permissionDecision, "deny");
  });

  test("deeply nested arguments through the real classifier are a deny, not an exception", async () => {
    const consent = createConnectConsent();
    let deep: unknown = "end";
    for (let i = 0; i < 60_000; i++) deep = { n: deep };
    let requested = 0;
    const hook = connectPreToolUse({ route: (t, i) => consent.routeOf(t, i), request: async () => { requested++; return { allow: true }; } });
    const out = await hook({ ...pre, tool_input: { tool: "gmail_send_email", arguments: { to: "a@example.com", deep } } }, undefined, { signal });
    assert.equal(denied(out)?.permissionDecision, "deny");
    assert.equal(requested, 0, "the call never reached the helper");
  });

  test("the normal paths stay as they were: allow, deny with the helper's sentence, not Connect, other events", async () => {
    const allow = connectPreToolUse({ route: () => askOf(), request: async () => ({ allow: true }) });
    assert.equal(denied(await allow(pre, undefined, { signal }))?.permissionDecision, "allow");
    const no = connectPreToolUse({ route: () => askOf(), request: async () => ({ allow: false, message: "The person declined this action." }) });
    assert.equal(denied(await no(pre, undefined, { signal }))?.permissionDecisionReason, "The person declined this action.");
    const free = connectPreToolUse({ route: () => undefined, request: async () => { throw new Error("not asked"); } });
    assert.deepEqual(await free({ ...pre, tool_name: "mcp__tealbrick__knowledge__document_create" }, undefined, { signal }), {});
    assert.deepEqual(await allow({ ...pre, hook_event_name: "PostToolUse" }, undefined, { signal }), {});
  });

  test("the LangChain gate fails closed too", async () => {
    const io = createInteractions(() => {}, { needsPermission, describe: (t) => t, connect: () => { throw new Error("classifier broke"); } });
    const decision = await io.gate("t", "mcp__tealbrick__connect__tools_call", { tool: "x" });
    assert.equal(decision.allow, false);
  });
});

// ---------------------------------------------------------------- S5: rule keys, Never first

describe("S5 rule keys and Never first", () => {
  const WS = workspaceKey("https://portal.example", "ws_a");
  const name = "mcp__tealbrick__connect__tools_call";
  const call = (account: string | undefined, toolName = "gmail_send_email") => ({ tool: toolName, arguments: { to: "a@example.com", ...(account === undefined ? {} : { connect_account: account }) } });

  function setup(answers: { allow: boolean; remember: boolean }[] = []) {
    const store = createConsentStore(join(temp(), "connect-consent.json"));
    const cards: ConnectCard[] = [];
    let i = 0;
    const decide = (req: Parameters<typeof decideConnectCall>[0]) => decideConnectCall(req, {
      store, workspace: WS, askPerson: async (c) => { cards.push(c); return answers[i++] ?? { allow: false, remember: false }; },
    });
    return { store, cards, decide };
  }
  const ask = (account: string, over: Partial<ConnectAsk> = {}): ConnectAsk => askOf({ account, ...over });

  test("'Work Inbox' and 'work inbox' (and ' work inbox ') are one account", async () => {
    const s = setup([{ allow: true, remember: true }]);
    await s.decide({ tool: name, input: call("Work Inbox"), connect: ask("Work Inbox") });
    assert.deepEqual(s.store.list(WS).map((r) => r.account), ["work inbox"]);
    for (const account of ["work inbox", "WORK INBOX", "  Work Inbox  "]) {
      assert.deepEqual(await s.decide({ tool: name, input: call(account), connect: ask(account) }), { allow: true, remember: "always" }, account);
    }
    assert.equal(s.cards.length, 1, "one card for all four spellings");
    assert.equal(normaliseAccount("  Work Inbox "), "work inbox");
    // and a Never for one spelling denies another
    const n = setup([{ allow: false, remember: true }]);
    await n.decide({ tool: name, input: call("Work Inbox"), connect: ask("Work Inbox") });
    const again = await n.decide({ tool: name, input: call("work inbox"), connect: ask("work inbox") });
    assert.equal(again.allow, false);
    assert.equal(again.remember, "never");
    assert.equal(n.cards.length, 1);
  });

  test("a call without an account uses the reserved '(default account)' key, kept apart from any account label", async () => {
    const s = setup([{ allow: true, remember: true }]);
    await s.decide({ tool: name, input: call(undefined), connect: ask(DEFAULT_ACCOUNT) });
    assert.deepEqual(s.store.list(WS).map((r) => r.account), [DEFAULT_ACCOUNT]);
    assert.equal(s.store.decision(WS, DEFAULT_ACCOUNT, "gmail_send_email"), "always");
    assert.equal(s.store.decision(WS, "Work inbox", "gmail_send_email"), null);
    assert.deepEqual(await s.decide({ tool: name, input: call(undefined), connect: ask(DEFAULT_ACCOUNT) }), { allow: true, remember: "always" });
    assert.equal(s.cards.length, 1);
  });

  test("a rule of an earlier version ('default', upper case) is read as today's keys", () => {
    const dir = temp();
    const file = join(dir, "connect-consent.json");
    writeFileSync(file, JSON.stringify({ version: 1, workspaces: { [WS]: [
      { account: "default", tool: "gmail_send_email", decision: "always", at: "2026-10-01T00:00:00.000Z" },
      { account: "Work Inbox", tool: "GMAIL_SEND_EMAIL", decision: "always", at: "2026-10-01T00:00:00.000Z" },
      { account: "work inbox", tool: "gmail_send_email", decision: "never", at: "2026-10-02T00:00:00.000Z" },
    ] } }));
    const store = createConsentStore(file);
    assert.equal(store.decision(WS, DEFAULT_ACCOUNT, "gmail_send_email"), "always");
    assert.equal(store.decision(WS, "WORK INBOX", "Gmail_Send_Email"), "never", "the same rule twice: Never wins; the tool name compares without case");
    assert.deepEqual(store.list(WS).map((r) => r.account).sort(), ["(default account)", "work inbox"]);
    assert.equal(store.revoke(WS, "Work Inbox", "gmail_send_email"), true);
  });

  test("a Never rule is checked BEFORE the read shortcut: a tool later learned as read still denies", async () => {
    const s = setup([{ allow: false, remember: true }]);
    // the person said Never to this tool while it asked (its effect was unknown or outward)
    await s.decide({ tool: name, input: call("Work inbox", "gmail_fetch_emails"), connect: ask("Work inbox", { tool: "gmail_fetch_emails", effect: "unknown" }) });
    // now a search shows it as read: the agent marks the call free, but the helper checks the rule first
    const consent = createConnectConsent();
    consent.observe("mcp__tealbrick__connect__tools_search", { query: "mail" }, { structuredContent: { tools: [{ tool: "gmail_fetch_emails", effect: "read" }] } });
    const route = consent.routeOf(name, call("Work inbox", "gmail_fetch_emails"));
    assert.equal(route?.free, "read", "the agent marks it free, and still sends it to the helper");
    const decided = await s.decide({ tool: name, input: call("Work inbox", "gmail_fetch_emails"), connect: route });
    assert.equal(decided.allow, false);
    assert.equal(decided.remember, "never");
    assert.equal(s.cards.length, 1, "no new card");
    // without the rule the same free call passes with no card
    const clean = setup();
    assert.deepEqual(await clean.decide({ tool: name, input: call("Work inbox", "gmail_fetch_emails"), connect: route }), { allow: true });
    assert.equal(clean.cards.length, 0);
  });

  test("a Never rule on a read op of the list (tb_skills was an ask op before S3) denies it too", async () => {
    const s = setup();
    s.store.remember(WS, DEFAULT_ACCOUNT, "tb_skills", "never");
    const decided = await s.decide({ tool: "mcp__tealbrick__connect__tb_skills", input: {} });
    assert.equal(decided.allow, false);
    assert.equal(decided.remember, "never");
    assert.deepEqual(await setup().decide({ tool: "mcp__tealbrick__connect__tb_skills", input: {} }), { allow: true });
  });

  test("every Connect call, free or not, goes to the helper from the agent (routeOf); a repeat of a held call is marked free", () => {
    let now = 1_000_000;
    const consent = createConnectConsent(() => now);
    assert.equal(consent.routeOf("mcp__tealbrick__connect__accounts_list", {})?.free, "read");
    assert.equal(consent.routeOf("mcp__tealbrick__connect__tools_search", { query: "x" })?.free, "read");
    assert.equal(consent.routeOf("mcp__tealbrick__connect__channel_send", { text: "x" })?.free, undefined);
    assert.equal(consent.routeOf("mcp__tealbrick__knowledge__document_create", {}), undefined, "not a Connect call");
    const send = call("Work inbox");
    consent.observe(name, send, { structuredContent: { status: "held", holdId: "h", expiresAt: new Date(now + 3_600_000).toISOString(), checkWith: "connect__tb_hold_status" } });
    assert.equal(consent.routeOf(name, send)?.free, "repeat");
  });

  test("the helper trusts the agent's 'free' only for a tools_call, never for another op", async () => {
    const s = setup([{ allow: false, remember: false }]);
    const decided = await s.decide({ tool: "mcp__tealbrick__connect__channel_send", input: { text: "x" }, connect: askOf({ op: "channel_send", tool: "channel_send", effect: "read", free: "read" }) });
    assert.equal(decided.allow, false);
    assert.equal(s.cards.length, 1);
    assert.equal(s.cards[0].effect, "outward", "the op's own effect, not the agent's claim");
  });
});

// ---------------------------------------------------------------- S6: no Always for dangerous effects

describe("S6 Always allow only for write and outward tools with a known effect", () => {
  const WS = workspaceKey("https://portal.example", "ws_a");
  const name = "mcp__tealbrick__connect__tools_call";

  test("alwaysOffered: write and outward only; destructive, money, unknown and any __first_contact tool never", () => {
    assert.equal(alwaysOffered("write", "gmail_create_draft"), true);
    assert.equal(alwaysOffered("outward", "gmail_send_email"), true);
    for (const effect of ["destructive", "money", "unknown", "read", "", "whatever"]) assert.equal(alwaysOffered(effect, "gmail_send_email"), false, effect);
    assert.equal(alwaysOffered("outward", "slack__first_contact"), false);
    assert.equal(alwaysOffered("write", "SLACK__FIRST_CONTACT_DM"), false);
  });

  test("the card carries the flag and the line under the buttons", () => {
    const ok = card({ to: "a@example.com" }, { effect: "outward" });
    assert.equal(ok.alwaysOffered, true);
    assert.equal(ok.hint, ALWAYS_HINT);
    for (const effect of ["destructive", "money", "unknown"]) {
      const c = card({ to: "a@example.com" }, { effect });
      assert.equal(c.alwaysOffered, false, effect);
      assert.equal(c.hint, "TBD asks every time for this kind of action.");
      assert.equal(c.hint, EVERY_TIME_LINE);
    }
    const first = card({ to: "a@example.com" }, { effect: "outward", tool: "slack_dm__first_contact" });
    assert.equal(first.alwaysOffered, false);
    assert.equal(first.hint, EVERY_TIME_LINE);
  });

  test("the button sets: Approve / Deny / Always allow / Never allow, or Approve / Deny / Never allow", () => {
    const labels = (c: { alwaysOffered: boolean }) => connectAnswers(c).map((a) => a.label);
    assert.deepEqual(labels({ alwaysOffered: true }), ["Approve", "Deny", "Always allow", "Never allow"]);
    assert.deepEqual(labels({ alwaysOffered: false }), ["Approve", "Deny", "Never allow"]);
    const byLabel = Object.fromEntries(connectAnswers({ alwaysOffered: true }).map((a) => [a.label, [a.allow, a.remember]]));
    assert.deepEqual(byLabel, { Approve: [true, false], Deny: [false, false], "Always allow": [true, true], "Never allow": [false, true] });
    assert.equal(connectAnswers({ alwaysOffered: false }).find((a) => a.label === "Approve")?.primary, true);
  });

  test("an 'Always allow' answer to a card that did not offer it counts once and stores nothing", async () => {
    const store = createConsentStore(join(temp(), "connect-consent.json"));
    const cards: ConnectCard[] = [];
    const deps = { store, workspace: WS, askPerson: async (c: ConnectCard) => { cards.push(c); return { allow: true, remember: true }; } };
    const input = { tool: "gmail_delete_all", arguments: { connect_account: "Work inbox" } };
    const first = await decideConnectCall({ tool: name, input, connect: askOf({ tool: "gmail_delete_all", effect: "destructive" }) }, deps);
    assert.deepEqual(first, { allow: true });
    assert.deepEqual(store.list(WS), []);
    await decideConnectCall({ tool: name, input, connect: askOf({ tool: "gmail_delete_all", effect: "destructive" }) }, deps);
    assert.equal(cards.length, 2, "asked every time");
    assert.deepEqual(cards.map((c) => c.alwaysOffered), [false, false]);
    // an unknown effect (the call reached the helper without the agent's ask) is the same
    await decideConnectCall({ tool: name, input }, deps);
    assert.equal(cards.length, 3);
  });

  test("an older Always rule on a dangerous tool no longer lets the call pass, but still lists and revokes; Never still applies", async () => {
    const store = createConsentStore(join(temp(), "connect-consent.json"));
    store.remember(WS, "Work inbox", "gmail_delete_all", "always");
    store.remember(WS, "Work inbox", "gmail_send_email", "always");
    store.remember(WS, "Work inbox", "gmail_purge", "never");
    let cards = 0;
    const deps = { store, workspace: WS, askPerson: async () => { cards++; return { allow: false, remember: false }; } };
    const del = await decideConnectCall({ tool: name, input: { tool: "gmail_delete_all", arguments: { connect_account: "Work inbox" } }, connect: askOf({ tool: "gmail_delete_all", effect: "destructive" }) }, deps);
    assert.equal(del.allow, false);
    assert.equal(cards, 1, "the old Always did not skip the card");
    const send = await decideConnectCall({ tool: name, input: { tool: "gmail_send_email", arguments: { connect_account: "Work inbox" } }, connect: askOf({ effect: "outward" }) }, deps);
    assert.deepEqual(send, { allow: true, remember: "always" });
    const purge = await decideConnectCall({ tool: name, input: { tool: "gmail_purge", arguments: { connect_account: "Work inbox" } }, connect: askOf({ tool: "gmail_purge", effect: "destructive" }) }, deps);
    assert.equal(purge.remember, "never");
    assert.equal(cards, 1);
    assert.deepEqual(store.list(WS).map((r) => r.tool).sort(), ["gmail_delete_all", "gmail_purge", "gmail_send_email"], "Settings still lists them");
    assert.equal(store.revoke(WS, "Work inbox", "gmail_delete_all"), true, "and can revoke");
  });
});

// ---------------------------------------------------------------- S7: the effect cache

describe("S7 effect cache: expiry and replacement", () => {
  const search = (...tools: { tool: string; effect?: string }[]) => ({ structuredContent: { tools } });
  const name = "mcp__tealbrick__connect__tools_call";
  const send = { tool: "gmail_send_email", arguments: { to: "a@example.com", connect_account: "Work inbox" } };

  test("an entry expires after 15 minutes", () => {
    let now = 0;
    const cache = createEffectCache(100, () => now);
    cache.record(search({ tool: "gmail_fetch_emails", effect: "read" }));
    now = EFFECT_TTL_MS - 1;
    assert.equal(cache.effectOf("gmail_fetch_emails"), "read");
    now = EFFECT_TTL_MS;
    assert.equal(cache.effectOf("gmail_fetch_emails"), undefined);
    assert.equal(cache.size(), 0);
    assert.equal(EFFECT_TTL_MS, 15 * 60_000);
  });

  test("read → write re-classification: a new search replaces the effect, and the tool asks at once", () => {
    let now = 0;
    const c = createConnectConsent(() => now);
    c.observe("mcp__tealbrick__connect__tools_search", {}, search({ tool: "gmail_send_email", effect: "read" }));
    assert.equal(c.needsAsk(name, send), false, "read: free");
    now += 60_000;
    c.observe("mcp__tealbrick__connect__tools_search", {}, search({ tool: "gmail_send_email", effect: "outward" }));
    assert.equal(c.needsAsk(name, send), true, "the latest search says outward: it asks");
    assert.equal(c.routeOf(name, send)?.effect, "outward");
    now += 60_000;
    c.observe("mcp__tealbrick__connect__tools_search", {}, search({ tool: "gmail_send_email" })); // listed without an effect
    assert.equal(c.routeOf(name, send)?.effect, "unknown");
  });

  test("a tool missing from the latest search keeps its entry only until it expires", () => {
    let now = 0;
    const c = createConnectConsent(() => now);
    c.observe("mcp__tealbrick__connect__tools_search", {}, search({ tool: "gmail_fetch_emails", effect: "read" }));
    now += 10 * 60_000;
    c.observe("mcp__tealbrick__connect__tools_search", {}, search({ tool: "calendar_list_events", effect: "read" }));
    const fetch = { tool: "gmail_fetch_emails", arguments: {} };
    assert.equal(c.needsAsk(name, fetch), false, "still good at 10 minutes");
    now += 6 * 60_000;
    assert.equal(c.needsAsk(name, fetch), true, "expired at 16 minutes");
    assert.equal(c.needsAsk(name, { tool: "calendar_list_events", arguments: {} }), false, "the tool the latest search listed is fresh");
  });
});

// ---------------------------------------------------------------- S8, N2: hold notices

describe("S8 / N2 a hold of any Teal Brick app reaches the Chat in both harnesses", () => {
  const held = { structuredContent: { status: "held", holdId: "hold_know_1", expiresAt: "2026-10-20T10:00:00Z", checkWith: "connect__tb_hold_status" } };

  test("heldOfRelayResult reads the hold for every mcp__tealbrick__ tool, not only Connect, and for nothing else", () => {
    for (const name of ["mcp__tealbrick__connect__tools_call", "mcp__tealbrick__knowledge__document_create", "mcp__tealbrick__kanban__issue_complete"]) {
      assert.deepEqual(heldOfRelayResult(name, held), { holdId: "hold_know_1", expiresAt: "2026-10-20T10:00:00Z", checkWith: "connect__tb_hold_status" }, name);
    }
    for (const name of ["mcp__companion__timeline_search", "Bash", "ask_person", "connect__tools_call"]) assert.equal(heldOfRelayResult(name, held), undefined, name);
  });

  test("LangChain seam: the observe hook sees the Knowledge hold (the agent turns it into the held event)", async () => {
    const seen: string[] = [];
    const doc = tool(async () => JSON.stringify({ status: "held", holdId: "hold_know_1", expiresAt: "2026-10-20T10:00:00Z", checkWith: "connect__tb_hold_status" }),
      { name: "mcp__tealbrick__knowledge__document_create", description: "d", schema: z.object({}).passthrough() }) as unknown as StructuredToolInterface;
    const seam = createToolSeam({
      tools: [doc], gate: async () => ({ allow: true }),
      observe: (n, _i, r) => { const h = heldOfRelayResult(n, r); if (h) seen.push(`${n}:${h.holdId}`); },
    });
    await seam.run({ messages: [new AIMessage({ content: "", tool_calls: [{ id: "c1", name: "mcp__tealbrick__knowledge__document_create", args: {}, type: "tool_call" }] })] } as never, {});
    assert.deepEqual(seen, ["mcp__tealbrick__knowledge__document_create:hold_know_1"]);
  });
});

// ---------------------------------------------------------------- N5: the rules file

describe("N5 the rules file", () => {
  const WS = workspaceKey("https://portal.example", "ws_a");

  test("a failed write removes its temp file and leaves the old file whole", () => {
    const dir = temp();
    const file = join(dir, "connect-consent.json");
    const store = createConsentStore(file);
    store.remember(WS, "a", "t1", "always");
    const before = readFileSync(file, "utf8");
    const broken = createConsentStore(file, Date.now, { rename: () => { throw new Error("disk full"); } });
    assert.throws(() => broken.remember(WS, "a", "t2", "never"), /disk full/);
    assert.deepEqual(readdirSync(dir), ["connect-consent.json"], "no temp file is left");
    assert.equal(readFileSync(file, "utf8"), before);
  });

  test("a corrupt file is moved aside; unreadable() says so until the next choice is saved", () => {
    const dir = temp();
    const file = join(dir, "connect-consent.json");
    writeFileSync(file, "{ not json");
    const store = createConsentStore(file, () => 100);
    assert.equal(store.unreadable(), true, "a bad file in place");
    assert.deepEqual(consentListing(store, WS), { choices: [], unreadable: true });
    assert.equal(existsSync(file), false);
    assert.equal(existsSync(`${file}.corrupt-100`), true);
    assert.equal(store.unreadable(), true, "still, with the copy and no file");
    store.remember(WS, "a", "t", "always");
    assert.equal(store.unreadable(), false, "the next saved choice clears it");
    assert.deepEqual(consentListing(store, WS).choices.map((r) => r.tool), ["t"]);
    assert.deepEqual(consentListing(store, null), { choices: [], unreadable: false });
    assert.equal(createConsentStore(join(temp(), "none.json")).unreadable(), false, "no file, no copy: nothing wrong");
  });

  test("at most three .corrupt-* copies are made; older ones and other files are never deleted", () => {
    const dir = temp();
    const file = join(dir, "connect-consent.json");
    writeFileSync(join(dir, "connect-consent.json.corrupt-notes"), "not ours (no digits)");
    writeFileSync(join(dir, "connect-consent.json.bak"), "not ours");
    writeFileSync(join(dir, "other.json.corrupt-1"), "another file's copy");
    let t = 0;
    const store = createConsentStore(file, () => ++t);
    for (let round = 1; round <= 5; round++) {
      writeFileSync(file, `{ bad ${round}`);
      assert.deepEqual(store.list(WS), [], `round ${round}`);
      store.remember(WS, "a", `t${round}`, "always"); // replaces the bad file when no copy could be made
    }
    const names = readdirSync(dir).sort();
    const copies = names.filter((n) => /^connect-consent\.json\.corrupt-\d+$/.test(n));
    assert.equal(copies.length, MAX_CORRUPT_COPIES);
    assert.deepEqual(copies.map((c) => readFileSync(join(dir, c), "utf8")).sort(), ["{ bad 1", "{ bad 2", "{ bad 3"], "the first three are kept as they were; bad 4 and 5 made no copy");
    for (const other of ["connect-consent.json.corrupt-notes", "connect-consent.json.bak", "other.json.corrupt-1"]) assert.ok(names.includes(other), `${other} is untouched`);
    assert.ok(names.includes("connect-consent.json"));
    assert.equal(createConsentStore(file).decision(WS, "a", "t5"), "always", "the file works after the fourth and fifth bad file");
  });

  test("unreadable() is false when a good file is newer than the kept copy", () => {
    const dir = temp();
    const file = join(dir, "connect-consent.json");
    writeFileSync(`${file}.corrupt-5`, "old");
    utimesSync(`${file}.corrupt-5`, new Date(2026, 0, 1), new Date(2026, 0, 1));
    const store = createConsentStore(file);
    assert.equal(store.unreadable(), true, "a copy and no file");
    store.remember(WS, "a", "t", "never");
    assert.equal(statSync(file).mtimeMs > statSync(`${file}.corrupt-5`).mtimeMs, true);
    assert.equal(store.unreadable(), false);
    mkdirSync(join(dir, "sub"));
  });
});
