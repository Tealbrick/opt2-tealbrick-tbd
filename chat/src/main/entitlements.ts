import type { Instance, Licence } from "@opt2-tealbrick/spec/routes";

/**
 * C282 (Martin): "TBD app's functionalities should unlock with what's currently paid for in the portal."
 * TBD has no licence logic of its own. It reads the workspace's licences (`GET /licences?assigned=true`, Core
 * registries/entitlements.ts `licences.list`) and installed apps (`GET /workspaces/{ws}/instances`, `instances.list`)
 * and gates each function on them. The paid rule is Core's own `isEntitled`: an `active` licence assigned to this
 * workspace; an installed instance also carries Core's `licensed` flag.
 */

/** The apps TBD gates on (product ids of the release index) and the name a locked function shows. */
export const GATED_APPS = {
  connect: "Connect",
  inbox: "Operator Inbox",
  rules: "Rules & Approvals",
  kanban: "Task Board",
  knowledge: "Knowledge",
  evolution: "Evolving Workflows",
  fleet: "Governance",
} as const;
export type GatedApp = keyof typeof GATED_APPS;

/** unlocked = paid, installed and running; install = paid but not (yet) running in this workspace; locked = not paid;
 *  unknown = the plan could not be read or had an unexpected shape. Fail-safe (Coordinator, dev.12): unknown NEVER locks
 *  a function — Core still enforces the plan on every call; TBD only shows "Could not check your plan". */
export type AppAccess = "unlocked" | "install" | "locked" | "unknown";

export interface AppEntitlement {
  access: AppAccess;
  paid: boolean;
  installed: boolean;
}

export interface EntitlementSnapshot {
  ws: string | null;
  /** ms since epoch of the last successful read; 0 = never read. */
  fetchedAt: number;
  /** Present when the last refresh failed: the apps below are the last good read (or all locked). */
  error?: string;
  apps: Record<GatedApp, AppEntitlement>;
}

const LOCKED: AppEntitlement = { access: "locked", paid: false, installed: false };

/** The plan could not be read (no good read yet): every app unknown, never locked. */
export function unknownSnapshot(ws: string | null, error: string): EntitlementSnapshot {
  const apps = Object.fromEntries(Object.keys(GATED_APPS).map((id) => [id, { access: "unknown", paid: false, installed: false }])) as Record<GatedApp, AppEntitlement>;
  return { ws, fetchedAt: 0, error, apps };
}

/** Fail-safe: the reads must have the contract's shape (@opt2-tealbrick/spec Licence / Instance); else nothing is decided. */
export function checkShape(licences: unknown, instances: unknown): void {
  const isText = (v: unknown) => typeof v === "string";
  const okLicence = (l: unknown) => !!l && typeof l === "object" && isText((l as Licence).product) && isText((l as Licence).status)
    && ((l as Licence).assignment === null || (l as Licence).assignment === undefined || (typeof (l as Licence).assignment === "object" && isText((l as Licence).assignment?.ws)));
  const okInstance = (i: unknown) => !!i && typeof i === "object" && isText((i as Instance).product) && isText((i as Instance).ws)
    && isText((i as Instance).state) && typeof (i as Instance).licensed === "boolean";
  if (!Array.isArray(licences) || !licences.every(okLicence)) throw new Error("unexpected licences shape");
  if (!Array.isArray(instances) || !instances.every(okInstance)) throw new Error("unexpected instances shape");
}

export function emptySnapshot(ws: string | null): EntitlementSnapshot {
  const apps = Object.fromEntries(Object.keys(GATED_APPS).map((id) => [id, { ...LOCKED }])) as Record<GatedApp, AppEntitlement>;
  return { ws, fetchedAt: 0, apps };
}

/** Pure: licences + instances of one workspace → access per gated app. */
export function computeEntitlements(ws: string, licences: readonly Licence[], instances: readonly Instance[], now: number): EntitlementSnapshot {
  const snapshot = emptySnapshot(ws);
  snapshot.fetchedAt = now;
  for (const id of Object.keys(GATED_APPS) as GatedApp[]) {
    const paid = licences.some((l) => l.product === id && l.status === "active" && l.assignment?.ws === ws);
    const instance = instances.find((i) => i.product === id && i.ws === ws && i.state !== "removed" && i.state !== "removing");
    const running = !!instance && instance.state === "running" && instance.licensed;
    snapshot.apps[id] = { paid, installed: !!instance, access: paid && running ? "unlocked" : paid ? "install" : "locked" };
  }
  return snapshot;
}

/** The sentence a locked function shows. */
export function availabilityText(app: GatedApp, access: AppAccess): string | null {
  const name = GATED_APPS[app];
  if (access === "unlocked" || access === "unknown") return null;
  if (access === "install") return `Install ${name} in Portal to use this.`;
  return `Available with ${name}.`;
}

/**
 * Field names and counts only, never values (C282 proof: the reads' real shape, without printing workspace data).
 * `{ items: [{ product, status, … }] }` → "items[3]{assignment,createdAt,id,…}".
 */
export function shapeOf(value: unknown, depth = 0): string {
  if (Array.isArray(value)) return `[${value.length}]${value.length ? shapeOf(value[0], depth) : ""}`;
  if (value && typeof value === "object") {
    if (depth >= 2) return "{…}";
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b));
    return `{${entries.map(([k, v]) => (v && typeof v === "object" ? `${k}${shapeOf(v, depth + 1)}` : k)).join(",")}}`;
  }
  return "";
}

/** Reads and caches the snapshot. An error or an unexpected shape keeps the last good read for this workspace; with no
 *  good read, every app is "unknown" (never locked). A Portal outage never locks a paid function. */
export function createEntitlements(deps: {
  licences: () => Promise<Licence[]>;
  instances: (ws: string) => Promise<{ items: Instance[] }>;
  now?: () => number;
  log?: (line: string) => void;
}) {
  const now = deps.now ?? Date.now;
  let last: EntitlementSnapshot = emptySnapshot(null);
  return {
    current: (): EntitlementSnapshot => last,
    async refresh(ws: string | null): Promise<EntitlementSnapshot> {
      if (!ws) {
        last = emptySnapshot(null);
        return last;
      }
      try {
        const [licences, instances] = await Promise.all([deps.licences(), deps.instances(ws)]);
        deps.log?.(`entitlements shape: licences ${shapeOf(licences)} instances ${shapeOf(instances?.items)}`);
        checkShape(licences, instances?.items);
        last = computeEntitlements(ws, licences, instances.items, now());
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        last = last.ws === ws && last.fetchedAt > 0 ? { ...last, error: message } : unknownSnapshot(ws, message);
      }
      return last;
    },
  };
}

export type Entitlements = ReturnType<typeof createEntitlements>;
