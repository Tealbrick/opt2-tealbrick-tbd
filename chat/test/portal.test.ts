import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { createPortal, publicPersonSession, type PersonSession } from "../src/main/portal.ts";

type Handler = (req: IncomingMessage, body: any, res: ServerResponse) => void;

async function fakePortal(handler: Handler) {
  const seen: { method: string; url: string; auth?: string; body: any }[] = [];
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const body = raw ? JSON.parse(raw) : null;
      seen.push({ method: req.method!, url: req.url!, auth: req.headers.authorization, body });
      handler(req, body, res);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { origin, seen, close: () => new Promise<void>((r) => server.close(() => r())) };
}

const json = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const err = (res: ServerResponse, status: number, code: string) => json(res, status, { error: { code, message: code, requestId: "req_1" } });

function memoryStore() {
  let value: PersonSession | null = null;
  return { load: () => value, save: (s: PersonSession | null) => { value = s; } };
}

test("owner device flow: tbd/owner start, pending + slow_down polling, K3 stored, email from /me", async () => {
  let polls = 0;
  const portal = await fakePortal((req, body, res) => {
    if (req.url === "/api/v1/device/authorize") return json(res, 200, { device_code: "tbdv_x", user_code: "BCDF-GHJK", verification_uri: "https://p/device", verification_uri_complete: "https://p/device?code=BCDF-GHJK", expires_in: 600, interval: 5 });
    if (req.url === "/api/v1/device/token") {
      polls++;
      if (polls === 1) return err(res, 400, "authorization_pending");
      if (polls === 2) return err(res, 400, "slow_down");
      return json(res, 200, { scope: "owner", access_token: "tbo_secret", token_type: "Bearer", expires_in: 86400, session_id: "osn_1" });
    }
    if (req.url === "/api/v1/me") return json(res, 200, { person: { email: "owner@example.test" } });
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  const waits: number[] = [];
  const p = createPortal({ origin: portal.origin, store, machineLabel: "TBD on test", sleep: async (ms) => { waits.push(ms); } });
  try {
    const start = await p.startSignIn();
    const s = await p.awaitSignIn(start);
    assert.equal(s.token, "tbo_secret");
    assert.equal(store.load()?.email, "owner@example.test");
    assert.deepEqual(waits, [5000, 5000, 10000]);
    const startReq = portal.seen[0];
    assert.deepEqual(startReq.body, { scope: "owner", client_id: "tbd", machine_label: "TBD on test" });
    assert.equal(startReq.auth, undefined);
    const tokenReq = portal.seen.find((r) => r.url === "/api/v1/device/token")!;
    assert.deepEqual(tokenReq.body, { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: "tbdv_x", client_id: "tbd" });
    assert.deepEqual(publicPersonSession(s), { email: "owner@example.test", expiresAt: s.expiresAt });
    assert.equal(JSON.stringify(publicPersonSession(s)).includes("tbo_"), false);
  } finally { await portal.close(); }
});

test("denied sign-in surfaces a clear error and stores nothing", async () => {
  const portal = await fakePortal((req, _b, res) => {
    if (req.url === "/api/v1/device/authorize") return json(res, 200, { device_code: "d", user_code: "u", verification_uri: "v", verification_uri_complete: "v", expires_in: 600, interval: 1 });
    err(res, 400, "access_denied");
  });
  const store = memoryStore();
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m", sleep: async () => {} });
  try {
    await assert.rejects(p.awaitSignIn(await p.startSignIn()), /denied/);
    assert.equal(store.load(), null);
  } finally { await portal.close(); }
});

test("sign-out revokes at Portal with the K3 and clears the local copy; a 401 read signs out", async () => {
  const portal = await fakePortal((req, _b, res) => {
    if (req.url === "/api/v1/owner-sessions/logout") return json(res, 200, { ok: true });
    if (req.url?.startsWith("/api/v1/workspaces")) return err(res, 401, "unauthenticated");
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  store.save({ token: "tbo_a", sessionId: "osn_a", expiresAt: Date.now() + 60_000, email: null });
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m" });
  try {
    await assert.rejects(p.workspaces(), (e: any) => e.status === 401);
    assert.equal(store.load(), null);
    store.save({ token: "tbo_b", sessionId: "osn_b", expiresAt: Date.now() + 60_000, email: null });
    await p.signOut();
    assert.equal(store.load(), null);
    const logout = portal.seen.find((r) => r.url === "/api/v1/owner-sessions/logout")!;
    assert.equal(logout.auth, "Bearer tbo_b");
  } finally { await portal.close(); }
});

test("C7: a session past its local idle mark stays signed in while Portal accepts it; a 401 still ends it", async () => {
  let accept = true;
  const portal = await fakePortal((req, _b, res) => {
    if (req.url?.startsWith("/api/v1/workspaces")) return accept ? json(res, 200, { items: [], nextCursor: null }) : err(res, 401, "unauthenticated");
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  // 25 h ago Portal said "idle until +24 h"; Core has slid the window since (src/http/auth.ts:99-109).
  store.save({ token: "tbo_old", sessionId: "osn_old", expiresAt: Date.now() - 3_600_000, email: null });
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m" });
  try {
    assert.ok(p.session(), "no local sign-out on the idle mark");
    await p.workspaces();
    assert.equal(portal.seen.at(-1)?.auth, "Bearer tbo_old");
    assert.ok(store.load(), "still signed in after a successful call");
    accept = false;
    await assert.rejects(p.workspaces(), (e: any) => e.status === 401);
    assert.equal(store.load(), null, "Portal's 401 ends the session");
  } finally { await portal.close(); }
});

test("C282: licences.list is read assigned-only, across pages", async () => {
  const portal = await fakePortal((req, _b, res) => {
    if (req.url === "/api/v1/licences?assigned=true&limit=200") return json(res, 200, { items: [{ id: "lic_1", product: "rules" }], nextCursor: "c1" });
    if (req.url === "/api/v1/licences?assigned=true&limit=200&cursor=c1") return json(res, 200, { items: [{ id: "lic_2", product: "kanban" }], nextCursor: null });
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  store.save({ token: "tbo_a", sessionId: "osn_a", expiresAt: Date.now() + 60_000, email: null });
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m" });
  try {
    assert.deepEqual((await p.licences()).map((l) => l.product), ["rules", "kanban"]);
    assert.equal(portal.seen.at(-1)?.auth, "Bearer tbo_a");
  } finally { await portal.close(); }
});

test("pending holds are counts per app from instances.list", async () => {
  const portal = await fakePortal((req, _b, res) => {
    if (req.url === "/api/v1/workspaces/ws_1/instances") return json(res, 200, { items: [{ product: "knowledge", pendingHolds: 0 }, { product: "connect", pendingHolds: 2 }] });
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  store.save({ token: "tbo_a", sessionId: "osn_a", expiresAt: Date.now() + 60_000, email: null });
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m" });
  try {
    assert.deepEqual(await p.pendingHolds("ws_1"), [{ product: "connect", count: 2 }]);
  } finally { await portal.close(); }
});

test("C282 fail-safe: a licence list longer than 10 pages is an error (never a short list read as 'not paid')", async () => {
  const portal = await fakePortal((req, _b, res) => {
    if (req.url?.startsWith("/api/v1/licences?assigned=true&limit=200")) return json(res, 200, { items: [{ id: "lic", product: "rules" }], nextCursor: "more" });
    err(res, 404, "not_found");
  });
  const store = memoryStore();
  store.save({ token: "tbo_a", sessionId: "osn_a", expiresAt: Date.now() + 60_000, email: null });
  const p = createPortal({ origin: portal.origin, store, machineLabel: "m" });
  try {
    await assert.rejects(p.licences(), /longer than 10 pages/);
  } finally { await portal.close(); }
});
