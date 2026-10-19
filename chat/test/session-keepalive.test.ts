import test from "node:test";
import assert from "node:assert/strict";
import { createPortal, SESSION_ENDED_NOTICE, type PersonSession } from "../src/main/portal.ts";
import { createSessionKeepAlive, KEEPALIVE_INTERVAL_MS } from "../src/main/sessionKeepAlive.ts";

/**
 * C280 C7 proof: TBD stays signed in to Portal without a prompt. A fake Core with the real rules of
 * portal-core `ownerSessionPrincipal` (src/http/auth.ts:99-110): every authenticated request sets
 * idle = LEAST(now + 24 h, absolute); a session is valid while idle > now and absolute > now and it is not revoked.
 * One virtual clock drives Core, the keep-alive and its timers. No network, no real Portal, no real token.
 */

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const T0 = Date.UTC(2026, 9, 20, 18, 0, 0);

function world() {
  let t = T0;
  let seq = 0;
  const timers: { id: number; at: number; fn: () => void }[] = [];
  const flush = async () => { for (let i = 0; i < 3; i++) await new Promise<void>((r) => setImmediate(r)); };
  const fire = async (limit: number) => {
    await flush();
    for (;;) {
      const due = timers.filter((x) => x.at <= limit).sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!due) break;
      timers.splice(timers.indexOf(due), 1);
      t = Math.max(t, due.at);
      due.fn();
      await flush();
    }
  };
  return {
    now: () => t,
    setTimer: (fn: () => void, ms: number) => { const id = ++seq; timers.push({ id, at: t + ms, fn }); return id; },
    clearTimer: (h: unknown) => { const i = timers.findIndex((x) => x.id === h); if (i >= 0) timers.splice(i, 1); },
    /** Time passes with the Mac awake: timers fire in order. */
    async advance(ms: number) { const end = t + ms; await fire(end); t = end; await flush(); },
    /** The Mac sleeps: the clock jumps and no timer runs meanwhile; the first one that was due fires after the wake. */
    async sleep(ms: number) { t += ms; await fire(t); await flush(); },
  };
}
type World = ReturnType<typeof world>;

function fakeCore(w: World) {
  const sessions = new Map<string, { idle: number; abs: number; revoked: boolean }>();
  const requests: { at: number; method: string; path: string; ok: boolean; status: number }[] = [];
  let network: "up" | "down" | "timeout" | "5xx" | "429" = "up";
  let onRequest: ((n: number) => Promise<void>) | null = null;
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  const fetchFn = (async (url: string | URL | Request, init?: RequestInit) => {
    const path = new URL(String(url)).pathname.replace("/api/v1", "");
    const method = init?.method ?? "GET";
    const record = (status: number) => requests.push({ at: w.now(), method, path, ok: status < 400, status });
    if (network === "down") { record(0); throw new TypeError("fetch failed"); }
    if (network === "timeout") { record(0); throw new DOMException("The operation timed out.", "TimeoutError"); }
    if (network === "5xx") { record(503); return reply(503, { error: { code: "internal", message: "down", requestId: "r" } }); }
    if (network === "429") { record(429); return reply(429, { error: { code: "rate_limited", message: "slow", requestId: "r" } }); }
    if (onRequest) await onRequest(requests.length + 1);
    const token = String((init?.headers as Record<string, string> | undefined)?.authorization ?? "").replace("Bearer ", "");
    const s = sessions.get(token);
    // Core: UPDATE ... SET idle_expires_at = LEAST(now + 24 h, expires_at) WHERE not revoked AND idle > now AND expires > now.
    if (!s || s.revoked || s.idle <= w.now() || s.abs <= w.now()) { record(401); return reply(401, { error: { code: "unauthenticated", message: "Sign in again.", requestId: "r" } }); }
    s.idle = Math.min(w.now() + DAY, s.abs);
    record(200);
    if (path === "/me") return reply(200, { person: { email: "qa@example.test" } });
    if (path === "/owner-sessions/logout") { s.revoked = true; return reply(200, { ok: true }); }
    return reply(404, { error: { code: "not_found", message: "no", requestId: "r" } });
  }) as typeof fetch;
  return {
    fetch: fetchFn,
    requests,
    /** Sign-in (device flow end): Core issues K3 with idle 24 h and absolute 30 days. */
    issue(token: string) { sessions.set(token, { idle: w.now() + DAY, abs: w.now() + 30 * DAY, revoked: false }); },
    revoke(token: string) { sessions.get(token)!.revoked = true; },
    idleExpiresAt: (token: string) => sessions.get(token)!.idle,
    setNetwork(n: typeof network) { network = n; },
    beforeRequest(fn: ((n: number) => Promise<void>) | null) { onRequest = fn; },
    count: (status?: number) => requests.filter((r) => status === undefined || r.status === status).length,
  };
}

function memoryStore() {
  let value: PersonSession | null = null;
  return { load: () => value, save: (s: PersonSession | null) => { value = s; } };
}

/** TBD signed in at T0 with a fresh Core session, the helper's keep-alive wired the way services.ts wires it. */
function setup(opts: { signedIn?: boolean; token?: string } = {}) {
  const w = world();
  const core = fakeCore(w);
  const store = memoryStore();
  const token = opts.token ?? "tbo_test_token_not_real";
  const portal = createPortal({ origin: "http://core.test", store, machineLabel: "m", fetch: core.fetch, now: w.now });
  const logs: string[] = [];
  const keepAlive = createSessionKeepAlive({
    signedIn: () => Boolean(portal.session()),
    touch: () => portal.me(),
    now: w.now,
    setTimer: w.setTimer,
    clearTimer: w.clearTimer,
    log: (l) => logs.push(l),
  });
  const signIn = () => {
    core.issue(token);
    store.save({ token, sessionId: "osn_1", expiresAt: w.now() + DAY, email: "qa@example.test" });
  };
  if (opts.signedIn !== false) signIn();
  return { w, core, store, portal, keepAlive, logs, token, signIn };
}

test("C7: idle Mac, 8 h overnight, keep-alive on: still signed in, Core's idle mark slid, no prompt", async () => {
  const { w, core, store, keepAlive, token } = setup();
  keepAlive.start();
  await w.advance(8 * HOUR);
  assert.ok(store.load(), "still signed in");
  assert.equal(core.count(401), 0, "Core never refused");
  assert.ok(core.idleExpiresAt(token) > w.now() + 23 * HOUR, "idle mark is about 24 h ahead of now");
  // One call at the first sight, then one per 30 min: 8 h / 30 min + 1 = 17 (+/- one for tick alignment). Cheap.
  assert.ok(core.count() >= 16 && core.count() <= 18, `calls: ${core.count()}`);
  assert.ok(core.requests.every((r) => r.method === "GET" && r.path === "/me"), "only GET /me");
  keepAlive.stop();
});

test("C7: without the keep-alive the same idle Mac is signed out after 24 h (the gap this closes)", async () => {
  const { w, core, portal, store } = setup();
  await w.advance(25 * HOUR);
  await assert.rejects(portal.me(), (e: any) => e.status === 401);
  assert.equal(store.load(), null);
  assert.equal(core.count(401), 1);
});

test("C7: a closed-lid week with the helper running (10 days, keep-alive on) stays signed in until the absolute limit only", async () => {
  const { w, store, keepAlive, core } = setup();
  keepAlive.start();
  await w.advance(10 * DAY);
  assert.ok(store.load());
  assert.equal(core.count(401), 0);
  assert.ok(core.count() <= 10 * 48 + 2, `about 48 calls per day, got ${core.count()}`);
  keepAlive.stop();
});

test("C7: absolute 30-day expiry -> signed out once, one sentence, no more calls", async () => {
  const { w, core, store, portal, keepAlive } = setup();
  keepAlive.start();
  await w.advance(31 * DAY);
  assert.equal(store.load(), null, "signed out");
  assert.equal(core.count(401), 1, "exactly one refused call");
  assert.equal(portal.endedNotice(), SESSION_ENDED_NOTICE);
  assert.match(SESSION_ENDED_NOTICE, /^[^.]+\. [^.]+\.$/, "one short notice");
  const before = core.count();
  await w.advance(3 * DAY);
  assert.equal(core.count(), before, "no keep-alive call while signed out");
  keepAlive.stop();
});

test("C7: revoked in Portal (401 unauthenticated) -> signed out once with the notice, no repeat", async () => {
  const { w, core, store, portal, keepAlive, token } = setup();
  keepAlive.start();
  await w.advance(2 * HOUR);
  assert.ok(store.load());
  core.revoke(token);
  await w.advance(31 * MIN);
  assert.equal(store.load(), null);
  assert.equal(portal.endedNotice(), SESSION_ENDED_NOTICE);
  assert.equal(core.count(401), 1);
  const before = core.count();
  await w.advance(6 * HOUR);
  assert.equal(core.count(), before);
  keepAlive.stop();
});

test("C7: no keep-alive call while signed out; the first call comes within a minute of a sign-in; none after the person signs out", async () => {
  const { w, core, portal, keepAlive, signIn } = setup({ signedIn: false });
  keepAlive.start();
  await w.advance(3 * HOUR);
  assert.equal(core.count(), 0, "signed out: nothing sent");
  signIn();
  await w.advance(61_000);
  assert.equal(core.count(), 1, "one call after the sign-in");
  await w.advance(KEEPALIVE_INTERVAL_MS - 2 * MIN);
  assert.equal(core.count(), 1, "not before the interval");
  await portal.signOut(); // the person's own sign-out: logout call, then silence
  const afterLogout = core.count();
  assert.equal(portal.endedNotice(), null, "a sign-out by the person is not an 'ended' notice");
  await w.advance(5 * HOUR);
  assert.equal(core.count(), afterLogout);
  keepAlive.stop();
});

test("C7: Mac sleep 23 h 50 min then wake: one call on wake keeps the session that would otherwise end", async () => {
  const { w, core, store, keepAlive, token } = setup();
  keepAlive.start();
  await w.advance(5 * MIN); // first call done
  const before = core.count();
  await w.sleep(23 * HOUR + 50 * MIN);
  assert.ok(store.load(), "signed in after the wake");
  assert.equal(core.count() - before, 1, "exactly one call on wake");
  assert.equal(core.count(401), 0);
  assert.ok(core.idleExpiresAt(token) > w.now() + 23 * HOUR);
  keepAlive.stop();
});

test("C7: an injected wake signal makes one call at once, also during a back-off; none while signed out", async () => {
  const { w, core, keepAlive, store } = setup();
  keepAlive.start();
  await w.advance(10 * MIN);
  const n = core.count();
  core.setNetwork("down");
  await w.advance(31 * MIN); // the due call fails; back-off retries
  const failed = core.count() - n;
  assert.ok(failed >= 1);
  core.setNetwork("up");
  const m = core.count();
  await keepAlive.wake();
  assert.equal(core.count() - m, 1, "wake retried at once");
  assert.equal(core.requests.at(-1)?.status, 200);
  store.save(null);
  const k = core.count();
  await keepAlive.wake();
  assert.equal(core.count(), k, "no call while signed out");
  keepAlive.stop();
});

for (const kind of ["down", "timeout", "5xx", "429"] as const) {
  test(`C7: transient ${kind} for 3 h never signs out; calls back off (<= 10 min apart); recovery resumes at the normal pace`, async () => {
    const { w, core, store, keepAlive, token, logs } = setup();
    keepAlive.start();
    await w.advance(10 * MIN);
    const before = core.count();
    core.setNetwork(kind);
    await w.advance(3 * HOUR);
    assert.ok(store.load(), "still signed in during the outage");
    assert.equal(core.count(401), 0);
    const during = core.count() - before;
    assert.ok(during >= 8 && during <= 3 * 6 + 6, `back-off keeps the calls few: ${during}`);
    assert.ok(logs.length > 0 && logs.every((l) => !l.includes(token) && !l.includes("tbo_")), "log lines carry no token");
    core.setNetwork("up");
    await w.advance(11 * MIN);
    assert.equal(core.requests.at(-1)?.status, 200, "resumed");
    assert.ok(store.load());
    await w.advance(2 * HOUR);
    const good = core.requests.filter((r) => r.status === 200 && r.at > core.requests.findLast((x) => x.status !== 200)!.at);
    assert.ok(good.length >= 4, "calls resumed");
    for (let i = 1; i < good.length; i++) assert.ok(good[i]!.at - good[i - 1]!.at >= KEEPALIVE_INTERVAL_MS, "normal 30 min pace again");
    keepAlive.stop();
  });
}

test("C7: an outage longer than Core's idle window ends the session at the first answer: 401 -> one notice", async () => {
  const { w, core, store, portal, keepAlive } = setup();
  keepAlive.start();
  await w.advance(10 * MIN);
  core.setNetwork("down");
  await w.advance(26 * HOUR);
  assert.ok(store.load(), "no sign-out on errors, even for a long outage");
  core.setNetwork("up");
  await w.advance(11 * MIN);
  assert.equal(store.load(), null, "Core says the session is gone: signed out");
  assert.equal(portal.endedNotice(), SESSION_ENDED_NOTICE);
  assert.equal(core.count(401), 1);
  keepAlive.stop();
});

test("C7: a late 401 for an old token does not sign out a session the person created meanwhile", async () => {
  const { w, core, store, portal, token } = setup();
  core.beforeRequest(async () => {
    // While the old call is in flight the person signs in again (new token).
    core.issue("tbo_new_token_not_real");
    store.save({ token: "tbo_new_token_not_real", sessionId: "osn_2", expiresAt: w.now() + DAY, email: null });
  });
  core.revoke(token);
  await assert.rejects(portal.me(), (e: any) => e.status === 401);
  assert.equal(store.load()?.token, "tbo_new_token_not_real", "the new session stays");
  assert.equal(portal.endedNotice(), null);
});

test("C7: the stored session and the keep-alive never put the token in a log line or the notice", async () => {
  const { w, keepAlive, logs, core, token, portal } = setup();
  keepAlive.start();
  core.setNetwork("5xx");
  await w.advance(2 * HOUR);
  core.setNetwork("up");
  core.revoke(token);
  await w.advance(40 * MIN);
  assert.ok(!JSON.stringify(logs).includes("tbo_"));
  assert.ok(!(portal.endedNotice() ?? "").includes("tbo_"));
  keepAlive.stop();
});

test("C7: TBD quit overnight (20 h) and started again: the loaded session is used at once (one call) and stays", async () => {
  const { w, core, store, keepAlive, token } = setup();
  await w.sleep(20 * HOUR); // app closed: no helper, no calls; the session is still inside Core's idle window
  keepAlive.start(); // the new helper starts; the person session is loaded from the Keychain (store)
  await w.advance(2 * MIN);
  assert.ok(store.load(), "comes back signed in");
  assert.equal(core.count(), 1, "one call at the first sight of the session");
  assert.ok(core.idleExpiresAt(token) > w.now() + 23 * HOUR, "and the window is 24 h again");
  keepAlive.stop();
});

// ---- dev.17 review S6: the keep-alive at helper start, with a stored session and no call from the window --------------------------

/**
 * A relaunch: the Keychain holds the session (`stored`), the helper has not loaded it into memory yet, and nothing in the window
 * has called yet. services.ts wires `prepare` = getServices() + ensurePerson() (one memoised load), so the loop sees the session
 * at its first check.
 */
function relaunch(opts: { prepare: boolean; loadFails?: boolean }) {
  const w = world();
  const core = fakeCore(w);
  const token = "tbo_test_token_not_real";
  core.issue(token); // Core still has the session
  const stored: PersonSession = { token, sessionId: "osn_1", expiresAt: w.now() + DAY, email: "qa@example.test" };
  const store = memoryStore(); // memory is empty at launch
  let keychainReads = 0;
  const ensurePerson = async () => {
    keychainReads += 1;
    if (opts.loadFails) throw new Error("Sign-in access was not confirmed.");
    store.save(stored);
  };
  const portal = createPortal({ origin: "http://core.test", store, machineLabel: "m", fetch: core.fetch, now: w.now });
  const logs: string[] = [];
  const keepAlive = createSessionKeepAlive({
    ...(opts.prepare ? { prepare: ensurePerson } : {}),
    signedIn: () => Boolean(portal.session()),
    touch: () => portal.me(),
    now: w.now, setTimer: w.setTimer, clearTimer: w.clearTimer, log: (l) => logs.push(l),
  });
  return { w, core, store, keepAlive, logs, reads: () => keychainReads };
}

test("S6: helper start with a stored session and no window call -> one keep-alive call within the first minute", async () => {
  const { w, core, keepAlive, reads } = relaunch({ prepare: true });
  keepAlive.start();
  await w.advance(MIN);
  assert.equal(core.count(), 1, "one GET /me within the first minute");
  assert.deepEqual(core.requests.map((r) => `${r.method} ${r.path}`), ["GET /me"]);
  assert.equal(reads(), 1, "the session was loaded once, by the one load the window's first call would also use");
  await w.advance(KEEPALIVE_INTERVAL_MS - 2 * MIN);
  assert.equal(core.count(), 1, "then one per interval, not more");
  keepAlive.stop();
});

test("S6 negative control: without the load at start the same relaunch makes no call (the gap this closes)", async () => {
  const { w, core, keepAlive } = relaunch({ prepare: false });
  keepAlive.start();
  await w.advance(5 * MIN);
  assert.equal(core.count(), 0, "memory is empty until some call loads the session");
  keepAlive.stop();
});

test("S6: a load that fails (the person did not confirm) is logged without a secret, makes no call, and the loop still runs", async () => {
  const { w, core, keepAlive, logs } = relaunch({ prepare: true, loadFails: true });
  keepAlive.start();
  await w.advance(5 * MIN);
  assert.equal(core.count(), 0);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /could not load the session \(Error\)/);
  assert.doesNotMatch(logs[0], /tbo_|confirmed/, "no token and no message text");
  keepAlive.stop();
});

test("S6: stop() before the load ends starts no loop", async () => {
  const w = world();
  let release: () => void = () => {};
  const slow = new Promise<void>((r) => { release = r; });
  let calls = 0;
  const keepAlive = createSessionKeepAlive({ prepare: () => slow, signedIn: () => true, touch: async () => { calls += 1; }, now: w.now, setTimer: w.setTimer, clearTimer: w.clearTimer });
  keepAlive.start();
  keepAlive.stop();
  release();
  await w.advance(5 * MIN);
  assert.equal(calls, 0);
});
