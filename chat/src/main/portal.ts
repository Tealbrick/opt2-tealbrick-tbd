import type {
  AccountMe,
  AgentCard,
  AgentList,
  HarnessOptionList,
  DeviceStart,
  DeviceStartOwnerInput,
  DeviceToken,
  DeviceTokenInput,
  ErrorEnvelope,
  InstanceList,
  WorkspaceList,
} from "@opt2-tealbrick/spec/routes";

/**
 * TBD's PERSON identity at Portal (CREDENTIALS §12 a): device flow
 * `client_id=tbd, scope=owner` → K3 "owner native session" (opaque `tbo_`).
 *
 * K3 reads and drafts only. It never applies, never gets a launch/keys ticket
 * (B4: launches open in the system browser), and it is never sent anywhere but
 * Portal's `/api/v1` gateway. The agent identity lives in agentIdentity.ts and
 * never sees this module's token.
 *
 * Pure on purpose: storage, clock and fetch are injected, so tests run against
 * a fake Portal and the helper wires the real host.
 */

export interface PersonSession {
  /** K3, `tbo_…`. Never leaves the helper process except to Portal. */
  token: string;
  sessionId: string;
  /** Absolute expiry Portal reported at issue (idle timeout is Portal's to enforce). */
  expiresAt: number;
  email: string | null;
}

/** What the renderer may see. */
export interface PublicPersonSession {
  email: string | null;
  expiresAt: number;
}

export interface SessionStore {
  load(): PersonSession | null;
  save(session: PersonSession | null): void;
}

export interface PortalDeps {
  /** Portal origin, e.g. https://portal.tealbrick.com (no path). */
  origin: string;
  store: SessionStore;
  machineLabel: string;
  fetch?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

export class PortalError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const OWNER_CLIENT_ID = "tbd" as const;
const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code" as const;

/**
 * A stored person session, checked. Anything else (an older app's record, a damaged
 * value) is no session: the person signs in again instead of TBD sending a bad token.
 */
export function parsePersonSession(raw: string | null): PersonSession | null {
  if (!raw) return null;
  let value: unknown;
  try { value = JSON.parse(raw); } catch { return null; }
  if (!value || typeof value !== "object") return null;
  const s = value as Record<string, unknown>;
  if (typeof s.token !== "string" || !s.token || typeof s.sessionId !== "string" || !s.sessionId) return null;
  if (typeof s.expiresAt !== "number" || !Number.isFinite(s.expiresAt)) return null;
  if (s.email !== null && typeof s.email !== "string") return null;
  return { token: s.token, sessionId: s.sessionId, expiresAt: s.expiresAt, email: s.email };
}

export function publicPersonSession(s: PersonSession | null): PublicPersonSession | null {
  return s ? { email: s.email, expiresAt: s.expiresAt } : null;
}

export function createPortal(deps: PortalDeps) {
  const http = deps.fetch ?? fetch;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const base = `${new URL(deps.origin).origin}/api/v1`;
  let cancelled = false;

  async function call<T>(method: string, path: string, body?: unknown, token?: string): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (token) headers.authorization = `Bearer ${token}`;
    const res = await http(`${base}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
    });
    const text = await res.text();
    const json = text ? (JSON.parse(text) as unknown) : null;
    if (!res.ok) {
      const env = json as Partial<ErrorEnvelope> | null;
      throw new PortalError(res.status, env?.error?.code ?? "internal", env?.error?.message ?? `Portal answered ${res.status}`);
    }
    return json as T;
  }

  /**
   * The saved session, never expired on a local clock (C280 C7): `expiresAt` is only the 24 h IDLE mark from the
   * sign-in answer, and Core slides that window on every use (absolute limit 30 days). Portal decides: a 401 on any
   * call ends the session (`read` below), so TBD stays signed in for as long as it is used.
   */
  function current(): PersonSession | null {
    return deps.store.load();
  }

  /** A K3 read. A 401 means Portal ended the session (revoked, idle): sign out locally. */
  async function read<T>(path: string): Promise<T> {
    const s = current();
    if (!s) throw new PortalError(401, "unauthenticated", "Not signed in.");
    try {
      return await call<T>("GET", path, undefined, s.token);
    } catch (error) {
      if (error instanceof PortalError && error.status === 401) deps.store.save(null);
      throw error;
    }
  }

  return {
    session: current,

    async startSignIn(): Promise<DeviceStart> {
      cancelled = false;
      const input: DeviceStartOwnerInput = { scope: "owner", client_id: OWNER_CLIENT_ID, machine_label: deps.machineLabel.slice(0, 64) };
      return call<DeviceStart>("POST", "/device/authorize", input);
    },

    cancelSignIn(): void {
      cancelled = true;
    },

    /** RFC 8628 polling: authorization_pending → wait, slow_down → +5 s, denied/expired → error. */
    async awaitSignIn(start: DeviceStart): Promise<PersonSession> {
      let interval = Math.max(1, start.interval) * 1000;
      const deadline = now() + start.expires_in * 1000;
      const input: DeviceTokenInput = { grant_type: DEVICE_GRANT, device_code: start.device_code, client_id: OWNER_CLIENT_ID };
      while (now() < deadline) {
        await sleep(interval);
        if (cancelled) throw new PortalError(0, "cancelled", "Sign-in cancelled.");
        try {
          const token = await call<DeviceToken>("POST", "/device/token", input);
          if (token.scope !== "owner") throw new PortalError(0, "bad_request", "Portal returned an agent token for a person sign-in.");
          const session: PersonSession = {
            token: token.access_token,
            sessionId: token.session_id,
            expiresAt: now() + token.expires_in * 1000,
            email: null,
          };
          deps.store.save(session);
          try {
            const me = await call<AccountMe>("GET", "/me", undefined, session.token);
            session.email = me.person.email;
            deps.store.save(session);
          } catch {
            /* the session is valid; the name can come later */
          }
          return session;
        } catch (error) {
          if (!(error instanceof PortalError)) throw error;
          if (error.code === "authorization_pending") continue;
          if (error.code === "slow_down") { interval += 5000; continue; }
          if (error.code === "access_denied") throw new PortalError(error.status, error.code, "Sign-in was denied in the browser.");
          if (error.code === "expired_token") break;
          throw error;
        }
      }
      throw new PortalError(0, "expired_token", "The sign-in code expired. Start again.");
    },

    /** Server-side revoke first (sign-out revokes, CREDENTIALS §12), then forget locally either way. */
    async signOut(): Promise<void> {
      const s = deps.store.load();
      deps.store.save(null);
      if (!s) return;
      try {
        await call("POST", "/owner-sessions/logout", {}, s.token);
      } catch {
        /* offline or already revoked: the local copy is gone, Portal expires it */
      }
    },

    me: () => read<AccountMe>("/me"),
    workspaces: () => read<WorkspaceList>("/workspaces?limit=200"),
    instances: (ws: string) => read<InstanceList>(`/workspaces/${encodeURIComponent(ws)}/instances`),

    /** agents.list: every agent card of the workspace (C127), all pages (bounded). */
    async agents(ws: string): Promise<AgentCard[]> {
      const items: AgentCard[] = [];
      let cursor: string | null = null;
      for (let page = 0; page < 10; page++) {
        const query: string = cursor ? `?limit=200&cursor=${encodeURIComponent(cursor)}` : "?limit=200";
        const list: AgentList = await read<AgentList>(`/workspaces/${encodeURIComponent(ws)}/agents${query}`);
        items.push(...list.items);
        cursor = list.nextCursor;
        if (!cursor) break;
      }
      return items;
    },
    /** Harness labels for the agent cards ("Claude Code", …). */
    harnessOptions: () => read<HarnessOptionList>("/harness-options"),

    /** Pending holds per app (count only, S2/C24). The hold pages themselves open in the system browser. */
    async pendingHolds(ws: string): Promise<{ product: string; count: number }[]> {
      const list = await read<InstanceList>(`/workspaces/${encodeURIComponent(ws)}/instances`);
      return list.items.filter((i) => i.pendingHolds > 0).map((i) => ({ product: i.product, count: i.pendingHolds }));
    },
  };
}

export type Portal = ReturnType<typeof createPortal>;
