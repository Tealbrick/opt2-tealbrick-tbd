// Neutral demo data and a fake `window.studio` (StudioApi, src/shared/ipc.ts) for the design proof.
// Reaching the main chat view needs, in this order (store.bootstrap): controlPlanes -> session ->
// portalWorkspaces (selectedId set) -> loadState("conversations.json") -> listAgents -> firstRun
// (checkAgentModel: model.ready true, else the composer shows "Set up a model" instead of Send).
import type { RemoteAgent, StudioApi } from "@shared/ipc";
import type { Block } from "@shared/types";

/** TBD's own agent: the row src/main/ipc.ts defaultAgentRow() builds; id from lib/agentModel.ts TBD_AGENT_ID. */
export const TBD_ID = "tbd-default";
/** The workspace agent that gets an unread dot (see proof.tsx). */
export const UNREAD_AGENT_ID = "agent-research";

const now = Date.now();
const MIN = 60_000;
const base = { accessMode: "private", audience: null, daemonLabel: null, peers: [], profile: null };

const agents: RemoteAgent[] = [
  { ...base, id: TBD_ID, name: "TBD", runtime: "tbd-default", url: "local://tbd", hasUrl: true, reachable: true },
  // Other agents of the Portal workspace are cards: url null, `workspace` set, listed only (workspaceAgentRow).
  { ...base, id: UNREAD_AGENT_ID, name: "Research Scout", runtime: "workspace", url: null, hasUrl: false, reachable: true, workspace: { purpose: "Collects sources and summarises them for review.", state: "online", harness: "Claude Code" } },
  { ...base, id: "agent-ops", name: "Ops Helper", runtime: "workspace", url: null, hasUrl: false, reachable: true, workspace: { purpose: "Watches deploys and files tickets.", state: "online", harness: "Codex" } },
  { ...base, id: "agent-archive", name: "Archive Keeper", runtime: "workspace", url: null, hasUrl: false, reachable: false, workspace: { purpose: "Keeps long-term notes.", state: "paused", harness: null } },
];

const text = (id: string, role: "user" | "agent", body: string, minsAgo: number): Block => ({ kind: "text", id, role, text: body, at: now - minsAgo * MIN });

// conversations.json, as store.persist() writes it. The sidebar preview and order come from these blocks.
const conversations: Record<string, Block[]> = {
  [TBD_ID]: [
    text("m1", "user", "Can you summarise what I worked on yesterday afternoon?", 42),
    text("m2", "agent", "You spent most of the afternoon in the design review and two calls. Notes are in `~/TBD/notes/review.md`.", 41),
    text("m3", "user", "Which calls were those?", 12),
    text("m4", "agent", "A planning call at 14:00 and a vendor call at 16:30. The agenda for the first is [on the shared board](https://example.com/board).", 11),
    text("m5", "user", "Thanks. Add a follow-up task for the vendor call.", 3),
    text("m6", "agent", "Done. I added **Follow up with the vendor** to tomorrow, due 10:00.", 2),
  ],
  [UNREAD_AGENT_ID]: [text("r1", "agent", "Three new sources are ready for your review.", 18)],
  "agent-ops": [text("o1", "agent", "Deploy finished with no errors.", 95)],
};

const model = { name: "TBD", harness: "tbd-default", protocol: "tealbrick-native", native: true, model: "claude-sonnet-demo", capabilities: ["chat"], tools: [{ name: "Companion timeline", description: "Your screen-activity timeline." }] };
const folders = { workspace: "/Users/demo/TBD", folders: [] };

/** A fixture value for a call that never answers (a device-flow approval the person has not given yet). */
export const PENDING = "__pending__";

/** Return values by method name; anything not listed falls through to harmlessDefault. */
const fixtures: Partial<Record<keyof StudioApi, unknown>> = {
  controlPlanes: { activeId: "tealbrick", profiles: [{ id: "tealbrick", name: "Teal Brick Portal", issuer: "https://portal.tealbrick.com", builtIn: true }, { id: "tealbrick-dev", name: "Teal Brick Dev", issuer: "https://dev.tealbrick.com", builtIn: true }] },
  session: { expiresAt: now + 3_600_000, email: "demo@example.com", orgName: "Demo workspace" },
  portalWorkspaces: { accountId: "acct-demo", organizationId: "org-demo", workspaces: [{ id: "ws-demo", name: "Demo workspace" }], selectedId: "ws-demo" },
  listAgents: agents,
  // `loadState` is keyed by file name; null means "nothing saved" (see harmlessDefault).
  firstRun: { model: { ready: true }, agentConnected: true },
  agentConnection: { connected: true, workspaceId: "ws-demo", agentId: "card-tbd" },
  agentInfo: model,
  agentHealth: true,
  agentFolders: folders, addAgentFolder: folders, removeAgentFolder: folders,
  pendingHolds: [],
  fileExists: false,
};

const states: Record<string, unknown> = {
  "conversations.json": { conversations, sessions: {}, streamIndexes: {}, prefs: {} },
  "workspaces.json": {},
};

/** Async invokes resolve undefined (saveState, watch, openExternal, ...); loadState reads `states`. */
function harmlessDefault(name: string, args: unknown[]): unknown {
  return name === "loadState" ? (states[args[0] as string] ?? null) : undefined;
}

/** window.studio = Proxy over the fixtures. `then` stays undefined so awaiting the proxy is safe. */
export function installStudio(): void {
  const studio = new Proxy({} as Record<string, unknown>, {
    get(_t, prop) {
      if (typeof prop !== "string" || prop === "then") return undefined;
      if (prop in fixtures) return () => { const v = (fixtures as Record<string, unknown>)[prop]; return v === PENDING ? new Promise(() => undefined) : Promise.resolve(v); };
      // Subscriptions (onDelta, onTurn, ...) are synchronous and return an unsubscribe no-op.
      if (/^on[A-Z]/.test(prop)) return () => () => undefined;
      return (...args: unknown[]) => Promise.resolve(harmlessDefault(prop, args));
    },
  });
  (window as unknown as { studio: StudioApi }).studio = studio as unknown as StudioApi;
}

/** Proof-only: change what a call answers (first-run state, agent connection) between screenshots. */
export function setFixture(name: keyof StudioApi, value: unknown): void {
  (fixtures as Record<string, unknown>)[name] = value;
}
