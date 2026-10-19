import type { Replayed } from "./sessionReplay";

/**
 * The renderer's whole view of the outside world.
 *
 * These types live in `shared`, not `main`, so the dependency points one way:
 * main imports from shared. The reverse makes the renderer's typecheck pull in
 * Electron main-process code, which then fails to compile for the web target.
 */

export interface Session {
  /** Public account view only; credentials remain in the trusted main process. */
  expiresAt: number;
  email?: string;
  orgName?: string;
}

export interface RemoteAgent {
  id: string;
  name: string;
  runtime: string;
  url: string | null;
  accessMode: string;
  audience: string | null;
  /**
   * The Portal user who owns this agent. TBD sends the owner's session only to
   * an agent whose owner is the signed-in user (F4-1); absent means not owned.
   */
  ownerUserId?: string | null;
  /**
   * Added by the main process, never by Portal: whether TBD will send this
   * agent a credential, and the sentence to show when it will not.
   */
  connection?: { mode: "owner-session" | "chat-token" | "withheld"; note?: string };
  /**
   * Whether the control plane holds an address for this agent — NOT whether it
   * answers. Probe with `agentHealth` for the second thing.
   */
  hasUrl?: boolean;
  /** @deprecated Use `hasUrl`. Kept for control planes not yet redeployed. */
  reachable: boolean;
  daemonLabel: string | null;
  /**
   * The agents this one is allowed to call, from the control plane.
   *
   * Governance state, not a claim by the agent about itself: these are the same
   * rows the admin edits, so revoking an edge there empties this here.
   */
  peers?: { id: string; name: string; purpose?: string }[];
  /**
   * How THIS person shows the agent, kept with the account so the phone and
   * the desktop draw the same picture. Null when they have never chosen.
   */
  profile?: AgentProfile | null;
  /**
   * Added by the main process for the OTHER agents of the Portal workspace (C127): what their
   * card says. Chat with them is not built yet; TBD only lists them.
   */
  workspace?: WorkspaceAgentInfo;
  /** On TBD's own row only: why the workspace agents are missing (shown as a notice, never blocking). */
  rosterNotice?: string;
}

export type WorkspaceAgentState = "online" | "offline" | "paused";

export interface WorkspaceAgentInfo {
  purpose: string;
  state: WorkspaceAgentState;
  /** Harness label from Portal's harness options, else the card's harness id; null when the card has none. */
  harness: string | null;
}

export interface AgentProfile {
  displayName: string | null;
  accent: string | null;
  /** A small data URL, or null for the lettered mark. */
  avatar: string | null;
  /** Where it sits in the person's list. Null means never chosen. */
  pinned?: boolean | null;
  hidden?: boolean | null;
  updatedAt: string;
}

// Must match LOCAL_ACTIONS in main/localExec.ts, which is the enforcement side.
// "local-mcp" was missing here, so the renderer's type claimed an action it can
// actually receive was impossible — a lie directly under a permission boundary.
export type LocalAction = "run-command" | "read-file" | "write-file" | "list-directory" | "local-mcp" | "connect-call" | "web-request";
export type LocalPermission = "always" | "ask" | "never";

/** What the Connect consent card shows (C11): built in the helper from the call's arguments, never from the model's own words. */
export interface ConnectCard {
  title: string;
  service: string;
  tool: string;
  /** The account label the agent named, or "(default account)". */
  account: string;
  accountLine: string;
  effect: string;
  effectLine: string;
  /** Every target argument that is present (who or where it goes); a list shows its count and its items (to ten). */
  target: { label: string; value: string }[];
  subject?: string;
  /** The first 300 characters of the content. */
  content?: string;
  /** "Attachments: 2 files: a.pdf, b.txt", when the call names files. */
  attachments?: string;
  /** "Other arguments: key=value; …" (at most 600 characters): every argument shown nowhere else. */
  other?: string;
  /** Whether "Always allow" is offered (effect write or outward, not a first-contact tool). Approve, Deny and Never allow always are. */
  alwaysOffered: boolean;
  /** The line under the buttons: the Always hint, or "TBD asks every time for this kind of action." */
  hint: string;
}

/**
 * What the card shows for a local action of TBD's agent (a shell command, a file write or edit, a web fetch or search),
 * built in the helper from the call itself (main/localConsent.ts). Same four answers as the Connect card.
 */
export interface LocalCard {
  title: string;
  /** What `text` is: "Command", "File", "Address" or "Search". */
  label: string;
  /** The exact command, file path, address or search words (bidi and control characters removed; a cut is marked with "…"). */
  text: string;
  /** Set when `text` was cut: how much is shown. */
  cut?: string;
  /** "Folder: …" for a file. */
  folderLine?: string;
  /** "Named as: …" when the agent named the file by a link, `~` or a relative path. */
  via?: string;
  /** What "Always allow" covers (only when it is offered). */
  scope?: string;
  /** Why there is no "Always allow", or that the action leaves this Mac. */
  note?: string;
  /** The action sends something over the internet. */
  leavesMac: boolean;
  alwaysOffered: boolean;
  /** The line under the buttons: the Always hint, or "TBD asks every time for this kind of action." */
  hint: string;
}

/** One pending request for something on this machine, awaiting the user. */
export interface LocalAsk {
  id: string;
  agent: string;
  action: LocalAction;
  label: string;
  detail: string;
  /** Set when "always" would add this folder to the agent's allow-list; absent = one-time consent only. */
  folder?: string | null;
  /**
   * Set for a Connect call (action "connect-call"): the card has Approve / Deny / Never allow, and Always allow when `connect.alwaysOffered`.
   * They arrive in `localAnswer` as `{ allow, remember }`: Approve = allow, no remember; Deny = no allow, no remember;
   * Always allow = allow + remember; Never allow = no allow + remember.
   */
  connect?: ConnectCard;
  /**
   * Set for a local action with standing choices (shell, file write or edit, web): same four answers as `connect`
   * (`connectAnswers`); Always allow only when `local.alwaysOffered`.
   */
  local?: LocalCard;
}

/**
 * A file the user is handing to the agent.
 *
 * @remarks
 * Bytes travel with the message rather than a path. A path would be smaller,
 * but it would mean the agent reaching into the filesystem to fetch something —
 * which is a different act, governed by local access and its own consent, and
 * not what a person means when they drag a file into a conversation. Attaching
 * is a deliberate handover of this file and nothing else.
 */
export interface Attachment {
  /** What to call it in the conversation and to the model. */
  name: string;
  /** Sniffed from the file, since a model needs it to decode the bytes. */
  mediaType: string;
  /** Kept so the UI can show a size without re-reading the file. */
  size: number;
  bytes: Uint8Array;
}

/** An attachment on the renderer → helper wire: bytes as base64 (typed arrays do not cross the WebKit bridge). */
export interface WireAttachment {
  name: string;
  mediaType: string;
  size: number;
  data: string;
}

/** What Chat still needs on first run (studio:firstRun). */
export interface FirstRunState {
  model: { ready: boolean; note?: string };
  agentConnected: boolean;
}

/** What came of taking delivery of a file. */
export interface DeliveryResult {
  ok: boolean;
  /** Where it ended up, when it was saved. */
  path?: string;
  error?: string;
  /** The user closed the save dialog. Not a failure worth reporting loudly. */
  cancelled?: boolean;
}

export interface StudioApi {
  portalWorkspaces(): Promise<import("./portalWorkspaces").WorkspaceSelection>;
  selectPortalWorkspace(id: string): Promise<void>;
  controlPlanes(): Promise<import("./controlPlanes").ControlPlaneState>;
  activateControlPlane(id: string): Promise<void>;
  addControlPlane(input: { name: string; issuer: string }): Promise<void>;
  removeControlPlane(id: string): Promise<import("./controlPlanes").ControlPlaneState>;
  session(): Promise<Session | null>;
  signIn(): Promise<{ userCode: string; verificationUri: string }>;
  /** Abandon a sign-in that is still waiting, so a new code can be requested. */
  cancelSignIn(): Promise<void>;
  awaitSignIn(): Promise<Session>;
  signOut(): Promise<void>;
  /** `refreshSession` re-issues the policy bundle first so newly created agents are granted. */
  listAgents(opts?: { refreshSession?: boolean }): Promise<RemoteAgent[]>;
  /** Save how this person shows an agent, for every device they sign in to. Absent leaves a field alone; null clears it. */
  saveAgentProfile(input: { agent: string; displayName?: string | null; accent?: string | null; avatar?: string | null; pinned?: boolean | null; hidden?: boolean | null }): Promise<void>;
  send(input: {
    agentId: string;
    text: string;
    /** Files handed over with this message. */
    attachments?: Attachment[];
    sessionId?: string;
    streamIndex?: number;
    inputResponses?: { requestId: string; optionId?: string; text?: string }[];
    clientContext?: Record<string, unknown>;
    streamId: string;
  }): Promise<{
    reply: string;
    sessionId?: string;
    streamIndex: number;
    askedQuestion: boolean;
  }>;
  /** Whether a file the agent named is actually on this machine. */
  fileExists(path: string): Promise<boolean>;
  openLocalFile(path: string): Promise<DeliveryResult>;
  revealLocalFile(path: string): Promise<DeliveryResult>;
  /** Ask where to keep a published file, then fetch it there. */
  saveRemoteFile(input: { url: string; suggestedName: string }): Promise<DeliveryResult>;
  /** Fetch a published file to a temporary place and open it. */
  openRemoteFile(input: { url: string; suggestedName: string }): Promise<DeliveryResult>;
  /** Subscribe to streaming deltas. Returns an unsubscribe function. */
  onDelta(handler: (payload: { streamId: string; text: string }) => void): () => void;
  /** First-run checks: is a model chosen for TBD's agent, and is the agent connected to the workspace. */
  firstRun(): Promise<FirstRunState>;
  /** Open native Settings at Models ("engine") or Account. */
  openSettings(section: "engine" | "account"): Promise<void>;
  /** TBD's agent identity: a key connection to the selected workspace (K4 stays in the Keychain). */
  agentConnection(): Promise<{ connected: boolean; workspaceId?: string; agentId?: string }>;
  agentConnect(): Promise<{ userCode: string; verificationUri: string }>;
  awaitAgentConnect(): Promise<{ connected: boolean; workspaceId?: string; agentId?: string }>;
  cancelAgentConnect(): Promise<void>;
  agentDisconnect(): Promise<void>;
  /** The agent's working folder and the folders it may read (SEC-04). */
  agentFolders(): Promise<{ workspace: string; folders: string[] }>;
  addAgentFolder(): Promise<{ workspace: string; folders: string[] }>;
  removeAgentFolder(path: string): Promise<{ workspace: string; folders: string[] }>;
  openAgentWorkspace(): Promise<unknown>;
  /** Owner approvals waiting in apps: counts only; the hold pages open in the browser. */
  pendingHolds(): Promise<{ product: string; count: number }[]>;
  openExternal(url: string): Promise<void>;
  cancelTurn(input: { agentId: string; sessionId: string; turnId?: string }): Promise<string>;
  resetSession(input: {
    agentId: string;
    sessionId?: string;
  }): Promise<void>;
  onTurn(
    handler: (payload: { streamId: string; sessionId: string; turnId?: string }) => void,
  ): () => void;
  onReset(handler: (payload: { streamId: string }) => void): () => void;
  onActivity(
    handler: (payload: { streamId: string; label: string | null }) => void,
  ): () => void;
  onCursor(handler: (payload: { streamId: string; index: number }) => void): () => void;
  /** A Connect call of the turn waits for the owner's approval; `url` opens the approval in the system browser (null: none). */
  onHeld(handler: (payload: { streamId: string; label: string; holdId: string; url: string | null }) => void): () => void;
  onAuthorization(
    handler: (payload: {
      streamId: string;
      event: {
        name: string;
        description?: string;
        url?: string;
        userCode?: string;
        instructions?: string;
        expiresAt?: string;
        outcome?: string;
      };
    }) => void,
  ): () => void;
  /** One side of an agent-to-agent hop, as it happens. */
  onPeer(
    handler: (payload: {
      streamId: string;
      event: { direction: 'inbound' | 'outbound'; peer: string; text: string };
    }) => void,
  ): () => void;
  onQuestion(
    handler: (payload: {
      streamId: string;
      request: {
        requestId: string;
        prompt: string;
        options?: { id: string; label: string; description?: string; style?: string }[];
        allowFreeform?: boolean;
      };
    }) => void,
  ): () => void;
  /**
   * Follow a thread something else is driving. Events arrive on the same
   * channels a turn's do, under this streamId; `onLive` marks the other
   * device's message landing and its turn ending.
   */
  /** A native notification; clicking it brings the window forward and opens the agent. */
  notify(input: { title: string; body: string; agentId: string }): Promise<void>;
  onOpenAgent(handler: (payload: { agentId: string }) => void): () => void;
  watch(input: { agentId: string; sessionId: string; streamIndex: number; streamId: string }): Promise<void>;
  unwatch(streamId: string): Promise<void>;
  onLive(handler: (payload: { streamId: string; kind: "received" | "boundary" | "ended" }) => void): () => void;
  agentInfo(agentId: string): Promise<AgentInfo | null>;
  /** Whether the agent itself answers right now. See `agentHealth` in main. */
  agentHealth(agentId: string): Promise<boolean>;
  /** Restart TBD's local agent process (Agent panel). */
  restartAgent(agentId: string): Promise<void>;

  /** A remote agent wants to do something on this machine. */
  onLocalAsk(handler: (ask: LocalAsk) => void): () => void;
  /** The request finished (or was refused) — dismiss its card. */
  onLocalDone(handler: (payload: { id: string }) => void): () => void;
  localAnswer(input: { id: string; allow: boolean; remember: boolean }): Promise<void>;

  /** Rebuild a conversation this device has never seen from the agent's stream. */
  replaySession(input: { agentId: string; sessionId: string; limit?: number }): Promise<Replayed | null>;
  loadState<T>(name: string): Promise<T | null>;
  saveState(input: { name: string; value: unknown }): Promise<void>;
  /** Native folder picker; null when cancelled. */
  pickFolder(): Promise<string | null>;

  /** The control plane this app signs in to, and the default it falls back to. */
  /**
   * Point the app at a different control plane. Null restores the default.
   * The session belongs to the old one, so this signs out.
   */

}

/**
 * A flat, safe view of what an agent reports at `/eve/v1/info`.
 *
 * eve's own payload nests and groups: tools arrive as
 * { authored, available, framework, … }, skills as { static, dynamic },
 * channels as { authored, available, … }, subagents as { local, total }, and
 * the model under an `agent` object. Consuming that shape directly in five
 * components is how one wrong assumption crashed the window — so it is
 * normalized once, defensively, and the UI only ever sees arrays.
 */
export interface AgentSummary {
  harness?: string;
  /** Set when the agent answered with a Teal Brick native adapter manifest (`/tealbrick/v1/info`) instead of eve's. */
  native?: boolean;
  protocol?: string;
  capabilities?: string[];
  name?: string;
  model?: string;
  schedules: { name: string; cron?: string; hasRun?: boolean; markdown?: string; dynamic?: boolean; revision?: number; enabled?: boolean; wake?: boolean; nextRunAt?: number; lastRun?: {status:string;updatedAt:number} }[];
  connections: { name: string; description?: string }[];
  channels: { name: string; urlPath?: string; /** Set for a surface beside the agent, which has a heartbeat; absent for an eve route. */ live?: boolean }[];
  skills: { name: string; description?: string }[];
  tools: { name: string; description?: string }[];
  subagents: { name: string; description?: string }[];
}

/** Raw payload, deliberately loose: a remote agent may run a different eve. */
export type AgentInfo = Record<string, unknown>;
export type CodexAccessState = {sessionId:string;mode:'restricted'|'native'|'full';sandbox:string;shell:boolean;approvalPolicy:string;revision:number};
