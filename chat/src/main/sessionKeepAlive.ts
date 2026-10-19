/**
 * C280 C7 (Martin): "refresh the Portal session without a prompt."
 *
 * Core's owner session (K3, `tbo_`) lives 30 days absolute and 24 h idle, and Core slides the idle mark to now + 24 h on
 * EVERY authenticated request (portal-core src/http/auth.ts `ownerSessionPrincipal`). There is no refresh route, and none is
 * needed: any call keeps the session. The gap is a TBD that runs but makes no call for a day (window closed to the menu bar,
 * an idle Mac). This keep-alive makes one cheap read (`GET /me`) while a person is signed in:
 *
 *  - about every 30 min (the idle mark is 24 h), once at the first sight of a session, and once after the Mac wakes;
 *  - a failure that is not Portal's 401 (network down, timeout, 5xx, 429) never ends the session: retry with a back-off
 *    (1 min, doubling, at most 10 min) until Portal answers;
 *  - a 401 is handled by Portal's own client (`portal.ts` read): it signs out once and shows one sentence. This module
 *    then sees "not signed in" and makes no more calls.
 *
 * Pure on purpose: clock, timers and the read are injected. It holds no token and logs none.
 * (No relative value imports: node tests import this file directly.)
 */

export interface KeepAliveDeps {
  /**
   * Runs once before the first check (dev.17 review S6): loads what `signedIn` needs, so a helper that starts with a stored session
   * and no call from the window keeps the session alive within the first minute. It is the same load the first account call
   * does (once, memoised), so it asks the Keychain no earlier than that call would. A failure is logged; the loop starts anyway.
   */
  prepare?(): Promise<unknown>;
  /** True while a person session is loaded in memory. Must not touch the Keychain. */
  signedIn(): boolean;
  /** One cheap authenticated read. Throws on any failure. Portal's client signs out on a 401 itself. */
  touch(): Promise<unknown>;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Distance between two calls while all is well. Default 30 min. */
  intervalMs?: number;
  /** How often the (local, free) check runs. Default 60 s. A longer gap than 3 checks means the Mac slept. */
  checkMs?: number;
  /** First retry after a failure; doubles up to `maxBackoffMs`. Defaults 60 s and 10 min. */
  backoffMs?: number;
  maxBackoffMs?: number;
  /** A line without any secret (status code or error name only). */
  log?: (line: string) => void;
}

export const KEEPALIVE_INTERVAL_MS = 30 * 60_000;

export function createSessionKeepAlive(deps: KeepAliveDeps) {
  const now = deps.now ?? Date.now;
  const interval = deps.intervalMs ?? KEEPALIVE_INTERVAL_MS;
  const check = deps.checkMs ?? 60_000;
  const firstBackoff = deps.backoffMs ?? 60_000;
  const maxBackoff = deps.maxBackoffMs ?? 600_000;
  const setTimer = deps.setTimer ?? ((fn: () => void, ms: number) => {
    const handle = setTimeout(fn, ms);
    handle.unref?.(); // the keep-alive never keeps the helper alive
    return handle;
  });
  const clearTimer = deps.clearTimer ?? ((handle: unknown) => clearTimeout(handle as ReturnType<typeof setTimeout>));

  let handle: unknown = null;
  let running = false;
  let lastTick = 0;
  let dueAt = 0; // 0 = a session was just seen: call at once
  let failures = 0;
  let inFlight = false;
  let wasSignedIn = false;

  async function attempt(): Promise<void> {
    inFlight = true;
    try {
      await deps.touch();
      failures = 0;
      dueAt = now() + interval;
    } catch (error) {
      if (!deps.signedIn()) return; // Portal ended the session (401): its client signed out; nothing more to do
      failures += 1;
      dueAt = now() + Math.min(maxBackoff, firstBackoff * 2 ** (failures - 1));
      const status = (error as { status?: unknown } | null)?.status;
      deps.log?.(`session keep-alive failed (${typeof status === "number" ? status : error instanceof Error ? error.name : "error"}); retry in ${Math.round((dueAt - now()) / 1000)} s`);
    } finally {
      inFlight = false;
    }
  }

  /** One free local check; calls Portal only when a call is due. */
  async function tick(): Promise<void> {
    const t = now();
    const slept = lastTick !== 0 && t - lastTick > check * 3;
    lastTick = t;
    if (!deps.signedIn()) { wasSignedIn = false; failures = 0; dueAt = 0; return; }
    if (!wasSignedIn) { wasSignedIn = true; dueAt = 0; } // a new session (start, sign-in): one call now
    if (slept) dueAt = 0; // wake: one call now, whatever the back-off said
    if (inFlight || t < dueAt) return;
    await attempt();
  }

  function loop(): void {
    if (!running) return;
    void tick().catch(() => { /* touch errors are handled in attempt */ }).finally(() => {
      if (running) handle = setTimer(loop, check);
    });
  }

  return {
    start(): void {
      if (running) return;
      running = true;
      lastTick = now();
      if (!deps.prepare) { loop(); return; }
      void Promise.resolve().then(() => deps.prepare?.()).catch((error: unknown) => {
        deps.log?.(`session keep-alive could not load the session (${error instanceof Error ? error.name : "error"})`);
      }).finally(() => { lastTick = now(); if (running) loop(); });
    },
    stop(): void {
      running = false;
      if (handle !== null) clearTimer(handle);
      handle = null;
    },
    /** The Mac woke (or the network came back): one call now if a person is signed in. */
    wake(): Promise<void> {
      dueAt = 0;
      lastTick = now();
      if (!deps.signedIn() || inFlight) return Promise.resolve();
      wasSignedIn = true;
      return attempt();
    },
  };
}

export type SessionKeepAlive = ReturnType<typeof createSessionKeepAlive>;
