import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { createInterface } from "node:readline";
import { connectMcp, type McpTool } from "@opt2-tealbrick/bridge";
import { ACCOUNTS_LIST_TOOL, CONNECT_MESSAGES, accountOf, connectAccounts, scrubConnectError, type ConnectAccountsDeps } from "../src/main/connectAccounts.ts";
import type { AgentConnection } from "../src/main/agentIdentity.ts";

// Connectors, helper side (C280 C11): the gate (`connect__accounts_list` listed or not), the list, the error sentences.
// A fake relay over in-process streams; no network, no Composio, no Portal.

const connection: AgentConnection = {
  connectionId: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", agentId: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0", workspaceId: "ws_01JABCDEFGHJKMNPQRSTVWXYZ0",
  bridgeId: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0", mcpUrl: "https://bridge.example/mcp", tokenEndpoint: "https://bridge.example/oauth/token", thumbprint: "kid1",
};

interface Call { name: string; arguments: Record<string, unknown> }

function fakeRelay(tools: string[], answer: (call: Call) => unknown | undefined) {
  const toServer = new PassThrough();
  const toClient = new PassThrough();
  const calls: Call[] = [];
  let opened = 0;
  let closed = 0;
  createInterface({ input: toServer }).on("line", (line) => {
    const m = JSON.parse(line) as { id?: number; method: string; params?: Record<string, unknown> };
    if (typeof m.id !== "number") return;
    const reply = (result: unknown) => toClient.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, result })}\n`);
    if (m.method === "initialize") reply({ protocolVersion: "2025-06-18" });
    else if (m.method === "tools/list") reply({ tools: tools.map((name): McpTool => ({ name, inputSchema: { type: "object" } })) });
    else if (m.method === "tools/call") {
      const call: Call = { name: m.params!.name as string, arguments: m.params!.arguments as Record<string, unknown> };
      calls.push(call);
      const result = answer(call);
      if (result !== undefined) reply(result); // undefined: never answer (timeout case)
    }
  });
  const open: ConnectAccountsDeps["openRelay"] = async () => {
    opened += 1;
    const client = connectMcp({ streams: { input: toClient, output: toServer } });
    return { ...client, close: () => { closed += 1; } };
  };
  return { calls, open, opened: () => opened, closed: () => closed };
}

const account = (id: string, extra: Record<string, unknown> = {}) => ({ id, label: `Label ${id}`, service: "gmail", kind: "as_me", access: "read", ...extra });
const list = (accounts: unknown[]) => ({ content: [{ type: "text", text: "{}" }], structuredContent: { accounts } });
const appError = (code: string, message: string) => ({ content: [{ type: "text", text: "x" }], structuredContent: { error: { code, message, requestId: "r" } }, isError: true });
const held = { content: [{ type: "text", text: "Waiting" }], structuredContent: { status: "held", holdId: "hold_1", expiresAt: new Date(Date.now() + 3_600_000).toISOString(), checkWith: "connect__tb_hold_status" }, isError: false };
const deps = (relay: ReturnType<typeof fakeRelay>, extra: Partial<ConnectAccountsDeps> = {}): ConnectAccountsDeps => ({ connection: () => connection, openRelay: relay.open, ...extra });

test("the tool name follows the bridge rule", () => {
  assert.equal(ACCOUNTS_LIST_TOOL, "connect__accounts_list");
});

describe("gate", () => {
  test("the agent is not connected: not available, with the sentence; the relay is never opened", async () => {
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => list([]));
    const result = await connectAccounts(deps(relay, { connection: () => null }));
    assert.deepEqual(result, { available: false, reason: CONNECT_MESSAGES.notConnected, accounts: [] });
    assert.equal(relay.opened(), 0);
  });

  test("the relay does not list accounts_list: no grant, with the Portal and Connect steps; nothing is called", async () => {
    const relay = fakeRelay(["connect__tools_search", "knowledge__document_create"], () => list([]));
    const result = await connectAccounts(deps(relay));
    assert.equal(result.available, false);
    assert.equal(result.reason, CONNECT_MESSAGES.noGrant);
    assert.match(CONNECT_MESSAGES.noGrant, /In Portal, open your workspace, draw a line from TBD's agent to Connect, choose Read, then press Connect\./);
    assert.match(CONNECT_MESSAGES.noGrant, /share an account with TBD's agent/);
    assert.deepEqual(relay.calls, []);
    assert.equal(relay.closed(), 1, "the client is closed");
  });

  test("listed: available, and the one call is accounts_list with no arguments", async () => {
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => list([]));
    const result = await connectAccounts(deps(relay));
    assert.deepEqual(result, { available: true, accounts: [] });
    assert.deepEqual(relay.calls, [{ name: "connect__accounts_list", arguments: {} }]);
    assert.equal(relay.closed(), 1);
  });
});

describe("list", () => {
  test("accounts keep id, label, service, kind and access; off-shape and repeated entries are dropped", async () => {
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => list([
      account("a1", { kind: "as_itself", access: "read_update" }),
      account("a2", { access: "read_update_delete", label: "  Work inbox  " }),
      account("a1"), // repeated id
      account("a3", { kind: "as_owner" }), // unknown kind
      account("a4", { access: "update" }), // "Update" alone is not an access level
      { id: "a5", label: "No service", kind: "as_me", access: "read" },
      "text", null, 7,
    ]));
    const result = await connectAccounts(deps(relay));
    assert.deepEqual(result.accounts, [
      { id: "a1", label: "Label a1", service: "gmail", kind: "as_itself", access: "read_update" },
      { id: "a2", label: "Work inbox", service: "gmail", kind: "as_me", access: "read_update_delete" },
    ]);
  });

  test("at most 100 accounts, labels cut at 200 characters", async () => {
    const many = Array.from({ length: 130 }, (_, i) => account(`a${i}`, { label: "L".repeat(500) }));
    const result = await connectAccounts(deps(fakeRelay([ACCOUNTS_LIST_TOOL], () => list(many))));
    assert.equal(result.accounts.length, 100);
    assert.equal(result.accounts[0].label.length, 200);
  });

  test("accountOf: a manifest account without a field is dropped", () => {
    assert.equal(accountOf({ id: "a", label: "l", service: "s", kind: "as_me" }), undefined);
    assert.deepEqual(accountOf({ id: "a", label: "l", service: "s", kind: "as_me", access: "read" }), { id: "a", label: "l", service: "s", kind: "as_me", access: "read" });
  });

  test("nothing but accounts_list is called (no person op, no search, no call)", async () => {
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL, "connect__tools_call", "connect__account_connect", "connect__accounts_overview", "connect__tools_refresh"], () => list([account("a1")]));
    await connectAccounts(deps(relay));
    assert.deepEqual(relay.calls.map((c) => c.name), ["connect__accounts_list"]);
  });
});

describe("errors", () => {
  test("scope_denied and unknown_tool read as no grant", async () => {
    for (const code of ["scope_denied", "unknown_tool", "forbidden"]) {
      const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => appError(code, "nope"));
      await assert.rejects(connectAccounts(deps(relay)), (e: Error) => e.message === CONNECT_MESSAGES.noGrant);
      assert.equal(relay.closed(), 1);
    }
  });

  test("paused: the owner paused the agent", async () => {
    await assert.rejects(connectAccounts(deps(fakeRelay([ACCOUNTS_LIST_TOOL], () => appError("paused", "x")))), (e: Error) => e.message === CONNECT_MESSAGES.paused);
  });

  test("held: Connect is waiting for the owner", async () => {
    await assert.rejects(connectAccounts(deps(fakeRelay([ACCOUNTS_LIST_TOOL], () => held))), (e: Error) => e.message === CONNECT_MESSAGES.waiting);
  });

  test("an app error is one scrubbed sentence of at most 300 characters", async () => {
    const dirty = `Boom at https://connect.example.com/internal?code=abc /Users/someone/secret.txt Bearer abcdefghijklmnop ${"x".repeat(400)} ${"A1b2".repeat(20)}`;
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => appError("internal", dirty));
    await assert.rejects(connectAccounts(deps(relay)), (e: Error) => {
      assert.match(e.message, /^Connect did not list the accounts: /);
      const detail = e.message.replace("Connect did not list the accounts: ", "");
      assert.ok(e.message.length <= 300, `${e.message.length}`);
      assert.ok(detail.includes("[link]") && detail.includes("[path]"), detail);
      for (const bad of ["https://", "/Users/", "abcdefghijklmnop", "A1b2A1b2A1b2"]) assert.equal(e.message.includes(bad), false, bad);
      assert.equal(e.message.includes("\n"), false);
      return true;
    });
  });

  test("scrubConnectError keeps short plain words", () => {
    assert.equal(scrubConnectError("Connect is busy.\n  Try later."), "Connect is busy. Try later.");
  });

  test("timeout: a relay that never answers ends with the timeout sentence, and the client is closed", async () => {
    const relay = fakeRelay([ACCOUNTS_LIST_TOOL], () => undefined);
    await assert.rejects(connectAccounts(deps(relay, { rpcTimeoutMs: 80 })), (e: Error) => e.message === CONNECT_MESSAGES.timeout);
    assert.equal(relay.closed(), 1);
  });
});
