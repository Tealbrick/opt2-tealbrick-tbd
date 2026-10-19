import { create } from "zustand";
import type { PendingAttachment } from "./attachments";
import type { AgentSummary, FirstRunState } from "@shared/ipc";
import { NO_AGENT_NOTE, modelGate, notSentReply, type AgentModelState } from "./agentModel";
import { summarize } from "./agentInfo";
import type { Agent, Block, PeerEvent } from "@shared/types";
import { reconcile } from "@shared/sessionReplay";
import { DEFAULT_ISSUER } from "@shared/controlPlanes";

/** Snapshot from a native adapter's /tealbrick/v1/capabilities (no credentials). */
/**
 * Renderer state.
 *
 * Seeded from local fixtures so the shell is explorable before the transport
 * exists. Everything a real deployment would own — conversations, routines,
 * plugin state — is keyed by agent id, so swapping the fixture for the HTTP
 * client is a change of source, not of shape.
 */

/**
 * Stream listeners are registered ONCE, not per turn.
 *
 * Subscribing inside send() and unsubscribing in its finally() looks tidy and
 * is a race: IPC delivery to the renderer is asynchronous, so a message emitted
 * just before the turn resolved can arrive just after the listener is removed.
 * That is exactly how a question the agent asked — dispatched to a live window,
 * confirmed in the logs — vanished before anything rendered it, intermittently,
 * which is the worst way for it to fail.
 *
 * Instead each stream registers its owning agent here, and the listeners route
 * by that. Nothing is torn down mid-flight because nothing is scoped to a turn.
 */
const streamOwners = new Map<string, string>();

/**
 * Which agent is behind a stream, when the conversation has more than one.
 *
 * The reply bubble is created by the first delta, before the turn returns — so
 * attributing it only when the turn finishes leaves the bubble anonymous for
 * the whole time it is being written, which in a room is exactly when you need
 * to know who is talking. Registered with the stream, read when the bubble is
 * created.
 */
const streamSpeakers = new Map<string, { id: string; name: string; accent: string }>();
let listenersReady = false;
let crossDeviceReady = false;

/**
 * Notice what was said on this account's other machines.
 *
 * Driven by ATTENTION rather than by a clock: the moment someone looks at this
 * window is the moment a stale transcript starts being wrong, and it is also
 * the only moment the freshness is worth anything. A window nobody is watching
 * can be as stale as it likes for free.
 *
 * The slow tick behind it exists for the case attention never changes — two
 * machines side by side, both focused-ish, one being typed into. Half a minute
 * is far below the threshold where a conversation feels broken and far above
 * the rate at which polling costs anything.
 */
let rosterRefreshReady = false;

/** The roster follows Portal (C127): again on window focus and every 60 s. Workspace switches reload it directly. */
export const ROSTER_REFRESH_MS = 60_000;
function startRosterRefresh(get: () => State): void {
  if (rosterRefreshReady) return;
  rosterRefreshReady = true;
  const refresh = (): void => { if (get().portalWorkspaceId) void get().refreshAgents(); };
  window.addEventListener("focus", refresh);
  setInterval(refresh, ROSTER_REFRESH_MS);
}

function startCrossDeviceRefresh(get: () => State): void {
  if (crossDeviceReady) return;
  crossDeviceReady = true;

  const refresh = (): void => void get().refreshFromOthers();

  window.addEventListener("focus", refresh);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refresh();
  });
  setInterval(() => {
    if (document.visibilityState === "visible") refresh();
  }, 30_000);

  refresh();
}

function ensureListeners(
  get: () => State,
  set: (partial: Partial<State> | ((s: State) => Partial<State>)) => void,
): void {
  if (listenersReady || !window.studio) return;
  listenersReady = true;

  window.studio.onDelta(({ streamId, text }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    const next = (get().streaming[streamId] ?? "") + text;
    set((s) => ({ streaming: { ...s.streaming, [streamId]: next } }));
    upsertBlock(get, set, agentId, `a${streamId.slice(1)}`, next, streamSpeakers.get(streamId));
  });

  window.studio.onTurn(({ streamId, sessionId, turnId }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    set((s) => ({
      inflight: { ...s.inflight, [agentId]: { streamId, sessionId, turnId } },
    }));
  });

  window.studio.onReset(({ streamId }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    // The block that just ended was the agent saying what it was about to do.
    // Drop it from the transcript: it has already been shown as activity, and
    // keeping it would leave a paragraph of intentions above the answer.
    set((s) => ({ streaming: { ...s.streaming, [streamId]: "" } }));
    const bubbleId = `a${streamId.slice(1)}`;
    set((s) => ({
      conversations: {
        ...s.conversations,
        [agentId]: (s.conversations[agentId] ?? []).filter((b) => b.id !== bubbleId),
      },
    }));
  });

  window.studio.onActivity(({ streamId, label }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    set((s) => ({ activity: { ...s.activity, [agentId]: label } }));
    if (get().inflight[agentId]) armDeadMan(get, set, agentId);
  });

  window.studio.onCursor(({ streamId, index }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    // Saved continuously, not just on success: a stale cursor makes the next
    // turn replay old questions.
    set((s) => ({ streamIndexes: { ...s.streamIndexes, [agentId]: index } }));
  });

  /**
   * Agent-to-agent traffic, collapsed into one openable line per turn.
   *
   * The alternative — letting each hop through as ordinary tool activity — is
   * what happened before, and it reads as the agent using a tool named after a
   * colleague rather than as two agents talking. Grouping them keeps it about
   * the conversation the user is having, with the exchange one click away when
   * they want to see who said what.
   *
   * Merged into the block only while it is still the LAST thing in the
   * transcript. Once the agent has said something else, a later exchange is a
   * new event in the conversation, not more of the old one — folding it back in
   * would put it above a reply that came first.
   */
  window.studio.onPeer(({ streamId, event }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;

    set((s) => {
      const conv = s.conversations[agentId] ?? [];
      // Peers that are also agents in this sidebar keep their own identity —
      // the same avatar and colour as their row above, so the exchange names a
      // recognisable agent rather than a generic peer.
      // Compared loosely on purpose. A discovered peer's name reaches us through
      // a TOOL NAME, where punctuation cannot survive — a hyphenated agent name
      // arrives with underscores. An exact match would leave that agent
      // unrecognised and paint the exchange in a stranger's colour, directly
      // beside its own row in the sidebar.
      const key = (name: string): string => name.toLowerCase().replace(/[^a-z0-9]+/g, "");
      const known = s.agents.find((a) => key(a.name) === key(event.peer));
      const peer = {
        id: known?.id ?? event.peer,
        name: known?.name ?? event.peer,
        accent: known?.accent ?? "var(--tb-tone-moss)",
      };
      const entry: PeerEvent = {
        id: `pe${Date.now()}-${conv.length}`,
        direction: event.direction,
        peer,
        text: event.text,
        at: Date.now(),
      };

      const last = conv[conv.length - 1];
      if (last?.kind === "peer-activity" && last.id === `peer-${streamId}`) {
        return {
          conversations: {
            ...s.conversations,
            [agentId]: conv.map((b) =>
              b.id === last.id && b.kind === "peer-activity"
                ? { ...b, events: [...b.events, entry] }
                : b,
            ),
          },
        };
      }

      return {
        conversations: {
          ...s.conversations,
          [agentId]: [
            ...conv,
            { kind: "peer-activity", id: `peer-${streamId}`, at: Date.now(), events: [entry] },
          ],
        },
      };
    });
    get().persist();
  });

  window.studio.onHeld(({ streamId, label, holdId, url }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    // One notice per hold; it stays in the thread so the link outlives the turn.
    const id = `hold-${holdId}`;
    set((s) => {
      const conv = s.conversations[agentId] ?? [];
      if (conv.some((b) => b.id === id)) return {};
      return { conversations: { ...s.conversations, [agentId]: [...conv, { kind: "hold", id, at: Date.now(), label, holdId, ...(url ? { url } : {}) }] } };
    });
    get().persist();
  });

  window.studio.onAuthorization(({ streamId, event }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    // One card per connection, updated in place. The completed event carries the
    // outcome for the same connection, so a second card would be the same
    // question twice with different answers.
    const id = `auth-${event.name}`;
    set((s) => {
      const conv = s.conversations[agentId] ?? [];
      const existing = conv.find((b) => b.id === id);
      if (existing) {
        return {
          conversations: {
            ...s.conversations,
            [agentId]: conv.map((b) =>
              b.id === id && b.kind === "authorization" ? { ...b, ...event } : b,
            ),
          },
        };
      }
      return {
        conversations: {
          ...s.conversations,
          [agentId]: [...conv, { kind: "authorization", id, at: Date.now(), ...event }],
        },
      };
    });
    get().persist();
  });

  /**
   * The other device's message landed, or its turn ended. Re-read the thread
   * from the agent — the one copy that cannot drift — and, at a boundary,
   * start a fresh watch so the next reply gets a bubble of its own.
   */
  window.studio.onOpenAgent(({ agentId }) => {
    if (get().agents.some((a) => a.id === agentId)) get().select(agentId);
  });

  window.studio.onLive(({ streamId, kind }) => {
    const agentId = streamOwners.get(streamId);
    console.log(`[live] ${kind} on ${streamId} → ${agentId ?? "NO OWNER"}`);
    if (!agentId) return;
    if (kind === "boundary" || kind === "ended") {
      set((s) => ({ activity: { ...s.activity, [agentId]: null } }));
      // A watched turn was started elsewhere; that device owns its notification.
      get().stopWatching();
    }
    if (!get().inflight[agentId]) {
      void get().hydrate(agentId, "merge").then(() => get().watchActive());
    }
  });

  window.studio.onQuestion(({ streamId, request }) => {
    const agentId = streamOwners.get(streamId);
    if (!agentId) return;
    const id = `q${request.requestId}`;
    // Only for a turn this desktop started. A question in a turn the phone is
    // driving is the phone's to raise; notifications never cross devices.
    if (streamId.startsWith("s") && !(get().conversations[agentId] ?? []).some((b) => b.id === id)) {
      alertIfAway(get, agentId, `${get().agents.find((a) => a.id === agentId)?.name ?? "An agent"} needs you`, request.prompt);
    }
    set((s) => {
      const conv = s.conversations[agentId] ?? [];
      // A resumed turn can re-emit a request it already asked; keep one card.
      if (conv.some((b) => b.id === id)) return {};
      return {
        conversations: {
          ...s.conversations,
          [agentId]: [
            ...conv,
            {
              kind: "question",
              id,
              at: Date.now(),
              requestId: request.requestId,
              prompt: request.prompt,
              options: request.options,
              allowFreeform: request.allowFreeform,
            },
          ],
        },
      };
    });
    get().persist();
  });
}

type Speaker = { id: string; name: string; accent: string };

/**
 * Tell the person, if they are not already looking.
 *
 * Looking means the window has focus AND this agent's thread is the one on
 * screen; anything else — another agent open, the window behind something,
 * the person on their phone — gets a notification. Off per agent from its
 * Settings; on by default, because the question an agent asks while nobody
 * is watching is the one that stalls it for an hour.
 */
function alertIfAway(get: () => State, agentId: string, title: string, body: string): void {
  const s = get();
  const agent = s.agents.find((a) => a.id === agentId);
  const looking = document.hasFocus() && s.activeAgentId === agentId;
  const why = !agent ? "unknown agent" : agent.notifications === false ? "off for this agent" : looking ? "looking" : null;
  console.log(`[notify] ${agent?.name ?? agentId}: ${why ?? "shown"}`);
  if (why) return;
  void window.studio?.notify({ title, body: body.replace(/\s+/g, " ").trim().slice(0, 160), agentId });
}

function upsertBlock(
  get: () => State,
  set: (partial: Partial<State> | ((s: State) => Partial<State>)) => void,
  agentId: string,
  id: string,
  body: string,
  speaker?: { id: string; name: string; accent: string },
): void {
  set((s) => {
    const conv = s.conversations[agentId] ?? [];
    const exists = conv.some((b) => b.id === id);
    return {
      conversations: {
        ...s.conversations,
        [agentId]: exists
          ? conv.map((b) => (b.id === id && b.kind === "text" ? { ...b, text: body } : b))
          : [
              ...conv,
              { kind: "text", id, role: "agent", at: Date.now(), text: body, ...(speaker ? { speaker } : {}) },
            ],
      },
      agents: s.agents.map((a) =>
        a.id === agentId ? { ...a, lastMessageAt: Date.now(), lastMessagePreview: body } : a,
      ),
    };
  });
}

/**
 * Retire questions the agent has moved past.
 *
 * A turn that ends with a real answer and no new question means anything still
 * unanswered above it is moot — the agent is not waiting on it. Leaving those
 * cards live invites the user to answer a question that will never be read.
 */
function retireStaleQuestions(
  get: () => State,
  set: (partial: Partial<State> | ((s: State) => Partial<State>)) => void,
  agentId: string,
): void {
  set((s) => ({
    conversations: {
      ...s.conversations,
      [agentId]: (s.conversations[agentId] ?? []).map((b) =>
        b.kind === "question" && !b.answered ? { ...b, answered: "— no longer needed" } : b,
      ),
    },
  }));
}

/**
 * A turn cannot hold the composer hostage, whatever the transport does.
 *
 * Every fix so far has been a timeout somewhere in the send path, and each one
 * only covered the failure that had already happened. This is the layer that
 * does not care WHERE it broke: the window arms its own timer when it marks an
 * agent busy, and if nothing has come back by the time it fires, the user gets
 * their input back. A client whose usability depends on the transport being
 * correct is a client that will wedge in front of someone who is paying for it.
 *
 * Generous on purpose — a long tool run is normal, and any real activity
 * (a delta, a tool call, a question) rearms it.
 */
const DEAD_MAN_MS = 240_000;
const deadMan = new Map<string, ReturnType<typeof setTimeout>>();

/**
 * How many times each agent's conversation has been retired.
 *
 * @remarks
 * A send that is already in flight cannot be recalled: the request is with the
 * agent, and the answer — or the timeout — arrives whenever it arrives. When
 * someone resets a stuck conversation and carries on, the old request is still
 * out there, and up to 150 seconds later it fails and reports itself.
 *
 * That report is worse than useless. It describes a turn the person has already
 * abandoned, it arrives after a NEW message has been answered successfully, and
 * it reads as though the agent that just replied is broken. This counter is how
 * a late answer knows it belongs to a conversation nobody is having any more.
 */
const generation = new Map<string, number>();

function currentGeneration(agentId: string): number {
  return generation.get(agentId) ?? 0;
}

/** Retire everything in flight for this agent, so late results stay quiet. */
function retireGeneration(agentId: string): void {
  generation.set(agentId, currentGeneration(agentId) + 1);
}

function armDeadMan(
  get: () => State,
  set: (partial: Partial<State> | ((s: State) => Partial<State>)) => void,
  flightKey: string,
  // Where to write the notice, when that is not the same as the flight key: a
  // room's flight keys are per MEMBER, and the message belongs in the room.
  chatId: string = flightKey,
  speaker?: Speaker,
): void {
  clearTimeout(deadMan.get(flightKey));
  deadMan.set(
    flightKey,
    setTimeout(() => {
      if (!get().inflight[flightKey]) return;
      set((s) => {
        const flight = { ...s.inflight };
        delete flight[flightKey];
        return { inflight: flight, activity: { ...s.activity, [chatId]: null } };
      });
      upsertBlock(
        get,
        set,
        chatId,
        `a${Date.now()}`,
        speaker
          ? `${speaker.name} stopped responding, so I let that turn go. Nothing was lost — send it again.`
          : "That turn stopped responding, so I let it go. Nothing was lost — send it again.",
        speaker,
      );
      if (chatId === flightKey) flushQueue(get, flightKey);
    }, DEAD_MAN_MS),
  );
}

function disarmDeadMan(agentId: string): void {
  clearTimeout(deadMan.get(agentId));
  deadMan.delete(agentId);
}

/**
 * Send the next message that was typed while the agent was busy.
 *
 * One at a time, and only once the previous turn has actually settled — the
 * queue exists precisely because posting them together is what breaks ordering.
 */
function flushQueue(get: () => State, agentId: string): void {
  const pending = get().queued[agentId];
  if (!pending?.length) return;
  const [next, ...rest] = pending;
  useStore.setState((s) => ({ queued: { ...s.queued, [agentId]: rest } }));
  setTimeout(() => get().send(agentId, next, true), 0);
}

export type PanelView = "none" | "overview" | "routine" | "settings";

interface State {
  agents: Agent[];
  conversations: Record<string, Block[]>;

  activeAgentId: string;
  panel: PanelView;
  activeRoutineId: string | null;
  paletteOpen: boolean;

  authState: "loading" | "signed-in" | "signed-out";
  authError: string | null;
  issuer: string;
  account: { email?: string; orgName?: string } | null;
  /**
   * What the user decided about each agent, as opposed to what the control
   * plane says about it.
   *
   * The agent LIST belongs to the control plane — a revoked grant has to remove
   * an agent from the sidebar. But renaming one, pinning it, or hiding it are
   * decisions about this person's own workspace, and rebuilding the list on
   * every launch was quietly discarding all three. Kept apart so the two
   * cannot overwrite each other: the server owns the set, the user owns the
   * presentation.
   */
  prefs: Record<
    string,
    {
      name?: string;
      pinned?: boolean;
      hidden?: boolean;
      notifications?: boolean;
      accent?: string;
      /** The picture chosen for this agent, as a data URL. */
      avatar?: string;
    }
  >;
  /**
   * The agent-to-agent exchange being read, if any.
   *
   * Its own view rather than an accordion in the transcript: the exchange is a
   * conversation between two agents, and inlining it makes the user's own
   * thread the container for someone else's. Opened from the summary line,
   * closed back to where you were.
   */
  exchange: { agentId: string; blockId: string } | null;
  openExchange: (agentId: string, blockId: string) => void;
  closeExchange: () => void;
  /** Per-agent eve session id, so a conversation keeps its thread across turns. */
  sessions: Record<string, string | undefined>;
  streamIndexes: Record<string, number | undefined>;
  /** Per-agent "what it is doing right now", or null when idle. */
  activity: Record<string, string | null>;
  /**
   * The turn each agent is running right now, if any.
   *
   * eve accepts one turn at a time per session and parks between them. A client
   * that posts a second message before the first has settled is racing the
   * runtime: the message is held, arrives out of order, or lands on a session
   * that is not waiting yet. So a turn in flight is state the UI has to know
   * about, not something to discover by failing.
   */
  inflight: Record<string, { streamId: string; sessionId?: string; turnId?: string } | undefined>;
  /** Messages typed while a turn was running, sent in order once it settles. */
  queued: Record<string, string[] | undefined>;
  /** Per-agent model id, read from the agent's own /eve/v1/info. */
  models: Record<string, string | undefined>;
  /**
   * What each agent reports about itself. Undefined means "not fetched yet";
   * a present-but-empty section means the agent genuinely has none. The panels
   * must not conflate those.
   */
  details: Record<string, AgentSummary | undefined>;
  infoError: string | null;
  /** Per-agent project folder on this machine, sent as context each turn. */
  workspaces: Record<string, string | undefined>;
  streaming: Record<string, string>;

  select(id: string): void;
  /**
   * Read a thread from the agent that holds it.
   *
   * "fill" builds a conversation this device has never seen; "merge" adds only
   * the turns that happened somewhere else.
   */
  hydrate(agentId: string, mode?: "fill" | "merge"): Promise<void>;
  /** Pick up turns that happened on another device. Cheap; safe to call often. */
  refreshFromOthers(): Promise<void>;
  /** The thread being followed live, if this device is not the one talking in it. */
  watching: { agentId: string; sessionId: string; streamId: string } | null;
  /** Follow the active agent's thread while nothing of ours is in flight there; stop any other. */
  watchActive(): void;
  stopWatching(): void;
  setPanel(v: PanelView): void;
  openRoutine(id: string): void;
  setPaletteOpen(open: boolean): void;

  /** Why the workspace's other agents are missing (Portal error); shown as a notice, never blocking. */
  rosterNotice: string | null;
  /** Whether TBD's agent has a model (studio:firstRun); null until checked. Drives "No model set". */
  agentModel: AgentModelState;
  /** Re-check the first-run state (model, connection); also refreshes `agentModel`. */
  checkAgentModel(): Promise<FirstRunState | null>;
  send(agentId: string, text: string, fromQueue?: boolean, attachments?: PendingAttachment[]): void;
  /** Ask the agent to stop the turn it is running. */
  stopTurn(agentId: string): void;
  /**
   * Retire the eve session and start a fresh one.
   *
   * The escape hatch for a conversation that cannot move: a turn interrupted by
   * an agent restart never settles, so the session never parks and every later
   * message queues behind it forever.
   */
  resetConversation(agentId: string): void;
  answerQuestion(agentId: string, blockId: string, answer: { optionId?: string; text?: string }): void;
  patchAgent(id: string, patch: Partial<Agent>): void;

  portalWorkspaceId: string | null;
  portalWorkspaces: { id: string; name: string }[];
  workspaceLoading: boolean;
  workspaceError: string | null;
  loadPortalWorkspaces(): Promise<void>;
  switchPortalWorkspace(id: string): Promise<void>;
  bootstrap(): Promise<void>;
  restore(): Promise<void>;
  persist(): void;
  /** `refreshSession` (the explicit Refresh agents action) re-issues the session bundle first. */
  refreshAgents(opts?: { refreshSession?: boolean }): Promise<void>;
  /** Ask each agent whether it answers, and record it as their status. */
  refreshLiveness(): Promise<void>;
  loadAgentInfo(agentId: string): Promise<void>;
  setWorkspace(agentId: string, path: string | null): void;
  chooseWorkspace(agentId: string): Promise<void>;
  signIn(onCode: (code: string, verificationUri?: string) => void): Promise<boolean>;
  /** Abandon a sign-in that is still waiting, so a new code can be requested. */
  cancelSignIn(): Promise<void>;
  signOut(): Promise<void>;
}

/**
 * Re-read what an agent says about itself, shortly after a turn.
 *
 * An agent can change ITSELF during a conversation — "make me a routine that
 * does X" writes the routine and the agent harness restarts the agent about
 * twenty seconds later. The new routine only reaches /eve/v1/info once that
 * rebuild lands, so a single refresh when the turn ends always reads the old
 * manifest and the sidebar stays stale until the person switches agent, signs
 * out, or restarts the app. That is the bug this exists to end.
 *
 * So: look now, then a few times across the restart window, and stop the moment
 * anything actually changed. Bounded and cheap — at most four small GETs, and
 * usually one, because most turns change nothing.
 */
const infoWatches = new Map<string, ReturnType<typeof setTimeout>[]>();

function fingerprint(info: AgentSummary | undefined): string {
  if (!info) return "";
  return JSON.stringify([
    info.schedules?.map((x) => x.name).sort(),
    info.channels?.map((x) => x.name).sort(),
    info.skills?.map((x) => x.name).sort(),
    info.connections?.map((x) => x.name).sort(),
    info.tools?.length,
  ]);
}

function refreshAgentInfoAcrossRestart(get: () => State, agentId: string): void {
  for (const t of infoWatches.get(agentId) ?? []) clearTimeout(t);
  const before = fingerprint(get().details[agentId]);
  const timers: ReturnType<typeof setTimeout>[] = [];
  const look = async (): Promise<void> => {
    await get().loadAgentInfo(agentId);
    if (fingerprint(get().details[agentId]) !== before) {
      for (const t of infoWatches.get(agentId) ?? []) clearTimeout(t);
      infoWatches.delete(agentId);
    }
  };
  void look();
  // Across the restart the agent harness performs ~20s after a change.
  for (const delay of [10_000, 25_000, 45_000]) timers.push(setTimeout(() => void look(), delay));
  infoWatches.set(agentId, timers);
}

/** Never retain agent metadata, queued input or local folder choices across workspace boundaries. */
function emptyWorkspaceView(): Partial<State> {
  return { agents: [], conversations: {}, sessions: {}, streamIndexes: {}, prefs: {}, details: {}, infoError: null, models: {}, workspaces: {}, activity: {}, inflight: {}, queued: {}, streaming: {}, exchange: null, activeAgentId: '', panel: 'none', activeRoutineId: null, paletteOpen: false };
}

export const useStore = create<State>((set, get) => ({
  agents: [],
  conversations: {},

  activeAgentId: "",
  rosterNotice: null,
  agentModel: null,
  panel: "none",
  activeRoutineId: null,
  paletteOpen: false,

  authState: "loading",
  authError: null,
  issuer: DEFAULT_ISSUER,
  account: null,
  sessions: {},
  streamIndexes: {},
  exchange: null,
  prefs: {},
  activity: {},
  inflight: {},
  queued: {},
  models: {},
  infoError: null,
  details: {},
  workspaces: {},
  streaming: {},

  select: (id) => {
    set((s) => ({
      activeAgentId: id,
      agents: s.agents.map((a) => (a.id === id ? { ...a, unread: false } : a)),
    }));
    // Opening is when a conversation is worth fetching, not launch: a person
    // with thirty agents would otherwise pay for thirty replays to read one.
    void get().hydrate(id);
  },
  /**
   * Learn which conversations this account has, wherever they were started.
   *
   * Only fills in what this device is missing. A local transcript is the richer
   * copy — it holds the cards, the questions, the local-execution blocks that
   * the agent's own stream does not describe — so the directory is treated as
   * news about threads this machine has never met, never as a correction of
   * one it has.
   */

  /**
   * Rebuild a conversation from the agent that has been holding it.
   *
   * Runs only when this device has a session id and no transcript for it —
   * the case that used to look like a brand-new chat with an agent you have
   * been talking to for a month. Anything already here is left alone, because
   * replacing a live transcript with a reconstruction can only lose detail.
   */
  hydrate: async (agentId, mode = "fill") => {
    if (!window.studio) return;
    const sessionId = get().sessions[agentId];
    if (!sessionId) return;
    if (mode === "fill" && (get().conversations[agentId] ?? []).length > 0) return;
    const agent = get().agents.find((a) => a.id === agentId);
    if (!agent?.url) return;

    const replayed = await window.studio.replaySession({ agentId: agent.id, sessionId });
    if (!replayed || replayed.blocks.length === 0) return;
    if (mode === "fill" && (get().conversations[agentId] ?? []).length > 0) return;

    /**
     * "merge" adds what this device has not seen; "fill" builds from nothing.
     *
     * The difference matters because a local transcript holds things the
     * agent's stream never described — the question cards, the connection
     * prompts, the peer exchanges. Replacing it on every refresh would quietly
     * strip those out, so a refresh only ever APPENDS turns that happened
     * elsewhere, keyed on the durable event id so the same turn cannot arrive
     * twice.
     */
    const existing = get().conversations[agentId] ?? [];

    // Peers keep their own identity for the same reason they do live: the
    // exchange should name a recognisable colleague, in that colleague's own
    // colour, rather than a generic peer.
    const key = (name: string): string => name.toLowerCase().replace(/[^a-z0-9]+/g, "");
    const identify = (name: string): { id: string; name: string; accent: string } => {
      const known = get().agents.find((a) => key(a.name) === key(name));
      return { id: known?.id ?? name, name: known?.name ?? name, accent: known?.accent ?? "var(--tb-tone-moss)" };
    };

    const fromAgent: Block[] = [
      ...replayed.blocks.map(
        (b): Block => ({ kind: "text", id: b.eventId, role: b.role, text: b.text, at: b.at }),
      ),
      ...(replayed.peerBlocks ?? []).map(
        (p): Block => ({
          kind: "peer-activity",
          // Keyed on the TURN: event ids differ per read, the turn does not.
          id: `peer-${sessionId}-${p.turnId}`,
          at: p.at,
          events: p.events.map((e, n) => ({
            id: `pe-${p.turnId}-${n}`,
            direction: e.direction,
            peer: identify(e.peer),
            text: e.text,
            at: p.at,
          })),
        }),
      ),
    ];

    /**
     * Reconciled by CONTENT, not by id.
     *
     * The same message carries two names — the client's when this device wrote
     * it, the durable event's when the agent hands it back — so an id
     * comparison matches nothing and re-adds the whole conversation on every
     * refresh. With both devices refreshing, that compounds until a greeting
     * appears four times.
     */
    const next = reconcile(existing, fromAgent);
    if (mode === "merge" && next.length === existing.length) return;


    set((s) => ({
      conversations: { ...s.conversations, [agentId]: next },
      // Taken from the stream rather than stored anywhere: the token is a live
      // Resume streaming after what was just read, so the next turn does not
      // replay the history it already has.
      streamIndexes: { ...s.streamIndexes, [agentId]: replayed.streamIndex },
    }));
    get().persist();
  },

  /**
   * Pick up what was said on another device.
   *
   * Launch-only sync meant a machine sitting open all evening showed a stale
   * conversation until it was quit and reopened, which is not synchronised in
   * any sense a person would recognise.
   *
   * Two layers, and neither needs a push service. The AGENT already holds the
   * conversation and streams it, and since both devices now share one session,
   * re-reading the open thread is the whole of "live". The control plane is
   * only asked about threads that are NEW to this device, which is rare — so
   * it is checked on the same beat rather than on its own.
   *
   * Only while the window is focused. A background window polling every half
   * minute is a battery cost paid for nothing: nobody is reading it, and the
   * moment they look, focus fires.
   */
  watching: null,


  watchActive: () => {
    const { activeAgentId, watching, agents, sessions, inflight, streamIndexes } = get();
    const agent = activeAgentId ? agents.find((a) => a.id === activeAgentId) : undefined;
    const sessionId = agent ? sessions[agent.id] : undefined;
    const wanted = agent && agent.url && sessionId && !inflight[agent.id] ? { agentId: agent.id, sessionId } : null;
    if (watching && wanted && watching.agentId === wanted.agentId && watching.sessionId === wanted.sessionId) return;
    get().stopWatching();
    if (!wanted || !agent?.url || !window.studio) return;
    const streamId = `w${Date.now().toString(36)}${Math.floor(Math.random() * 1e4).toString(36)}`;
    // The stream listeners were registered lazily by the first SEND from this
    // window. A watch started before any send had nobody listening, so a turn
    // driven from the phone arrived in main and went nowhere.
    ensureListeners(get, set);
    streamOwners.set(streamId, agent.id);
    console.log(`[live] watching ${agent.name} ${wanted.sessionId.slice(0, 18)} as ${streamId} from ${streamIndexes[agent.id] ?? 0}`);
    set({ watching: { agentId: agent.id, sessionId: wanted.sessionId, streamId } });
    void window.studio.watch({ agentId: agent.id, sessionId: wanted.sessionId, streamIndex: streamIndexes[agent.id] ?? 0, streamId });
  },

  stopWatching: () => {
    const { watching } = get();
    if (!watching) return;
    streamOwners.delete(watching.streamId);
    set((s) => {
      const streaming = { ...s.streaming };
      delete streaming[watching.streamId];
      return { watching: null, streaming };
    });
    void window.studio?.unwatch(watching.streamId);
  },

  refreshFromOthers: async () => {
    if (!window.studio) return;
    ensureListeners(get, set);
    const active = get().activeAgentId;
    // The open conversation only. Refreshing every thread would multiply the
    // cost by the size of the sidebar to update something nobody is looking at.
    if (active && !get().inflight[active]) {
      await get().hydrate(active, "merge");
    }
  },

  setPanel: (panel) => set({ panel, activeRoutineId: null }),
  openRoutine: (id) => set({ panel: "routine", activeRoutineId: id }),
  setPaletteOpen: (paletteOpen) => set({ paletteOpen }),
  openExchange: (agentId, blockId) => set({ exchange: { agentId, blockId } }),
  closeExchange: () => set({ exchange: null }),


  checkAgentModel: async () => {
    if (!window.studio) return null;
    try {
      const state = await window.studio.firstRun();
      set({ agentModel: state.model });
      return state;
    } catch {
      return null;
    }
  },

  send: (agentId, text, fromQueue, attachments) => {
    // Workspace agents are listed only (C127); there is no chat transport to them yet.
    if (get().agents.find((a) => a.id === agentId)?.workspace) return;
    const at = Date.now();
    // No model: the message is not sent, and the conversation says so (never a send that goes nowhere).
    const gate = modelGate(agentId, get().agentModel);
    // A queued message was already shown when the user typed it. Adding it again
    // on flush is how one message becomes two identical bubbles.
    if (!fromQueue) {
      set((s) => ({
        conversations: {
          ...s.conversations,
          [agentId]: [
            ...(s.conversations[agentId] ?? []),
            {
              kind: "text",
              id: `u${at}`,
              role: "user",
              // The bubble records the handover: a message that attached three
              // files and said "have a look" reads as blank without it.
              text: attachments?.length
                ? [text, attachments.map((a) => `📎 ${a.name}`).join("\n")].filter(Boolean).join("\n\n")
                : text,
              at,
            },
          ],
        },
        agents: s.agents.map((a) =>
          a.id === agentId ? { ...a, lastMessageAt: at, lastMessagePreview: text } : a,
        ),
      }));
    }
    // Save the question immediately. If the app dies mid-turn, losing the answer
    // is annoying; losing what you asked is worse.
    get().persist();

    if (gate.blocked) {
      const id = `a${at}`;
      set((s) => ({
        conversations: {
          ...s.conversations,
          [agentId]: [...(s.conversations[agentId] ?? []), { kind: "text", id, role: "agent", at: Date.now(), text: notSentReply(gate.note) }],
        },
      }));
      get().persist();
      return;
    }

    const agent = get().agents.find((a) => a.id === agentId);

    // Create the reply bubble on first content rather than up front. An empty
    // "…" bubble alongside the activity line says the same thing twice, and it
    // claims the agent is composing a message before it has written a word.
    const upsert = (id: string, body: string): void => {
      set((s) => {
        const conv = s.conversations[agentId] ?? [];
        const exists = conv.some((b) => b.id === id);
        return {
          conversations: {
            ...s.conversations,
            [agentId]: exists
              ? conv.map((b) => (b.id === id && b.kind === "text" ? { ...b, text: body } : b))
              : [...conv, { kind: "text", id, role: "agent", at: Date.now(), text: body }],
          },
          agents: s.agents.map((a) =>
            a.id === agentId ? { ...a, lastMessageAt: Date.now(), lastMessagePreview: body } : a,
          ),
        };
      });
    };

    if (!window.studio || !agent?.url) {
      const id = `a${Date.now()}`;
      set((s) => ({
        conversations: {
          ...s.conversations,
          [agentId]: [
            ...(s.conversations[agentId] ?? []),
            {
              kind: "text",
              id,
              role: "agent",
              at: Date.now(),
              text: "This agent has no URL on file in the control plane, so there is nowhere to send it.",
            },
          ],
        },
      }));
      return;
    }

    // A turn is already running: hold this one rather than post it into a
    // session that has not parked. It goes out, in order, the moment the
    // current turn settles.
    if (get().inflight[agentId]) {
      set((s) => ({
        queued: { ...s.queued, [agentId]: [...(s.queued[agentId] ?? []), text] },
      }));
      return;
    }

    const streamId = `s${at}`;
    const bubbleId = `a${at}`;
    set((s) => ({ streaming: { ...s.streaming, [streamId]: "" } }));
    ensureListeners(get, set);
    streamOwners.set(streamId, agentId);
    set((s) => ({ inflight: { ...s.inflight, [agentId]: { streamId } } }));
    armDeadMan(get, set, agentId);

    const sentAtGeneration = currentGeneration(agentId);
    void window.studio
      .send({
        agentId: agent.id,
        text,
        // Stripped of the id the UI needed: it is a renderer concern and has no
        // meaning to the agent.
        attachments: attachments?.map(({ name, mediaType, size, bytes }) => ({
          name,
          mediaType,
          size,
          bytes,
        })),
        sessionId: get().sessions[agentId],
        streamIndex: get().streamIndexes[agentId],
        clientContext: get().workspaces[agentId]
          ? {
              workingFolder: get().workspaces[agentId],
              note: "Default working directory on the user's own computer. Other paths are still fine when they ask.",
            }
          : undefined,
        streamId,
      })
      .then((res) => {
        set((s) => ({
          sessions: { ...s.sessions, [agentId]: res.sessionId },
          streamIndexes: { ...s.streamIndexes, [agentId]: res.streamIndex },
        }));
        if (res.reply) {
          if (!res.askedQuestion) retireStaleQuestions(get, set, agentId);
          upsertBlock(get, set, agentId, bubbleId, res.reply);
          alertIfAway(get, agentId, get().agents.find((a) => a.id === agentId)?.name ?? "An agent", res.reply);
        } else if (!res.askedQuestion) {
          upsertBlock(get, set, agentId, bubbleId, "(the agent returned no text for this turn)");
        }
      })
      .catch((e: unknown) => {
        // The conversation this belonged to has been retired. Saying anything
        // now would blame the current conversation for a failure that happened
        // in one the person already walked away from.
        if (sentAtGeneration !== currentGeneration(agentId)) return;
        upsertBlock(get, set, agentId, bubbleId, e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        set((s) => ({ activity: { ...s.activity, [agentId]: null } }));
        set((s) => {
          const rest = { ...s.streaming };
          delete rest[streamId];
          const flight = { ...s.inflight };
          delete flight[agentId];
          return { streaming: rest, inflight: flight };
        });
        // Keep the owner mapping briefly: a late event that arrives after the
        // response is exactly what this whole change is about.
        disarmDeadMan(agentId);
        setTimeout(() => streamOwners.delete(streamId), 30_000);
        get().persist();
        flushQueue(get, agentId);
        // The agent may have just changed itself — a new routine, a channel, a
        // skill. Notice it without the person having to refresh.
        refreshAgentInfoAcrossRestart(get, agentId);
      });
  },




  stopTurn: (agentId) => {
    const live = get().inflight[agentId];
    const agent = get().agents.find((a) => a.id === agentId);
    if (!live || !window.studio) return;

    if (live.sessionId && agent?.url) {
      void window.studio
        .cancelTurn({ agentId: agent.id, sessionId: live.sessionId, turnId: live.turnId })
        .catch(() => undefined);
    }

    // Release the composer here, without waiting to hear back. Cancellation is a
    // request to a runtime that may be gone, and pressing stop must always give
    // the user their input back — a stop button that can itself hang is not a
    // stop button. The stream's own cleanup is idempotent when it arrives.
    disarmDeadMan(agentId);
    set((s) => {
      const flight = { ...s.inflight };
      delete flight[agentId];
      return { inflight: flight, activity: { ...s.activity, [agentId]: null } };
    });
    flushQueue(get, agentId);
  },

  resetConversation: (agentId) => {
    const agent = get().agents.find((a) => a.id === agentId);
    if (!agent?.url || !window.studio) return;
    const sessionId = get().sessions[agentId];
    // Drop the local handles first. Even if the agent cannot retire the session
    // (its owner may already be gone), the next message must not be posted into
    // the session that was stuck — that is the whole point of resetting.
    disarmDeadMan(agentId);
    retireGeneration(agentId);
    set((s) => ({
      sessions: { ...s.sessions, [agentId]: undefined },
      streamIndexes: { ...s.streamIndexes, [agentId]: 0 },
      inflight: { ...s.inflight, [agentId]: undefined },
      activity: { ...s.activity, [agentId]: null },
    }));
    get().persist();
    void window.studio.resetSession({ agentId, sessionId }).catch(() => undefined);
  },

  answerQuestion: (agentId, blockId, answer) => {
    const block = (get().conversations[agentId] ?? []).find((b) => b.id === blockId);
    if (!block || block.kind !== "question") return;

    const label =
      answer.text ??
      block.options?.find((o) => o.id === answer.optionId)?.label ??
      answer.optionId ??
      "";

    set((s) => ({
      conversations: {
        ...s.conversations,
        [agentId]: (s.conversations[agentId] ?? []).map((b) =>
          b.id === blockId && b.kind === "question" ? { ...b, answered: label } : b,
        ),
      },
    }));
    get().persist();

    const agent = get().agents.find((a) => a.id === agentId);
    if (!window.studio || !agent?.url) return;

    const at = Date.now();
    const streamId = `s${at}`;
    const bubbleId = `a${at}`;
    ensureListeners(get, set);
    streamOwners.set(streamId, agentId);
    set((s) => ({ inflight: { ...s.inflight, [agentId]: { streamId } } }));
    armDeadMan(get, set, agentId);

    void window.studio
      .send({
        agentId: agent.id,
        // No new message: this turn resumes on the answer alone.
        text: "",
        sessionId: get().sessions[agentId],
        streamIndex: get().streamIndexes[agentId],
        inputResponses: [
          { requestId: block.requestId, optionId: answer.optionId, text: answer.text },
        ],
        streamId,
      })
      .then((res) => {
        set((s) => ({
          sessions: { ...s.sessions, [agentId]: res.sessionId },
          streamIndexes: { ...s.streamIndexes, [agentId]: res.streamIndex },
        }));
        if (res.reply) {
          if (!res.askedQuestion) retireStaleQuestions(get, set, agentId);
          upsertBlock(get, set, agentId, bubbleId, res.reply);
        } else if (!res.askedQuestion) {
          upsertBlock(get, set, agentId, bubbleId, "(the agent returned no text for this turn)");
        }
      })
      .catch((e: unknown) =>
        upsertBlock(get, set, agentId, bubbleId, e instanceof Error ? e.message : String(e)),
      )
      .finally(() => {
        set((s) => {
          const flight = { ...s.inflight };
          delete flight[agentId];
          return { activity: { ...s.activity, [agentId]: null }, inflight: flight };
        });
        disarmDeadMan(agentId);
        setTimeout(() => streamOwners.delete(streamId), 30_000);
        get().persist();
        flushQueue(get, agentId);
      });
  },

  patchAgent: (id, patch) => {
    set((s) => ({
      agents: s.agents.map((a) => (a.id === id ? { ...a, ...patch } : a)),
      // Only the fields a person chooses. Status, previews, and unread counts
      // are observations about the world and must not survive a relaunch.
      prefs: {
        ...s.prefs,
        [id]: {
          ...s.prefs[id],
          ...("name" in patch ? { name: patch.name } : {}),
          ...("pinned" in patch ? { pinned: patch.pinned } : {}),
          ...("hidden" in patch ? { hidden: patch.hidden } : {}),
          ...("notifications" in patch ? { notifications: patch.notifications } : {}),
          ...("accent" in patch ? { accent: patch.accent } : {}),
          ...("avatar" in patch ? { avatar: patch.avatar } : {}),
        },
      },
    }));
    get().persist();

    // The picture, the name, the colour and the arrangement are the account's,
    // not this machine's. Sent as a patch — absent leaves a field alone, null
    // clears it — so changing one never clobbers another chosen elsewhere.
    // Every field sent below must also appear in this condition.
    if ("name" in patch || "accent" in patch || "avatar" in patch || "pinned" in patch || "hidden" in patch) {
      const agent = get().agents.find((a) => a.id === id);
      if (agent) {
        void window.studio?.saveAgentProfile({
          agent: agent.registeredName ?? agent.name,
          ...("name" in patch ? { displayName: patch.name?.trim() || null } : {}),
          ...("accent" in patch ? { accent: patch.accent ?? null } : {}),
          ...("avatar" in patch ? { avatar: patch.avatar ?? null } : {}),
          ...("pinned" in patch ? { pinned: patch.pinned ?? null } : {}),
          ...("hidden" in patch ? { hidden: patch.hidden ?? null } : {}),
        });
      }
    }
  },







  setWorkspace: (agentId, path) => {
    set((s) => ({ workspaces: { ...s.workspaces, [agentId]: path ?? undefined } }));
    void window.studio?.saveState({ name: "workspaces.json", value: get().workspaces });
  },

  chooseWorkspace: async (agentId) => {
    const path = await window.studio?.pickFolder();
    if (path) get().setWorkspace(agentId, path);
  },

  /**
   * Rehydrate from disk. Called on launch AND after signing in — signing in
   * used to skip it, so a fresh login started empty and the next completed turn
   * saved that emptiness over the real history.
   */
  restore: async () => {
    if (!window.studio) return;
    const saved = await window.studio.loadState<{
      conversations: Record<string, Block[]>;
      sessions: Record<string, string | undefined>;
      streamIndexes: Record<string, number | undefined>;
      prefs: State["prefs"];
    }>("conversations.json");
    if (saved?.prefs && !saved?.conversations) set({ prefs: saved.prefs });
    if (saved?.conversations) {
      set({
        conversations: saved.conversations,
        sessions: saved.sessions ?? {},
        streamIndexes: saved.streamIndexes ?? {},
        prefs: saved.prefs ?? {},
      });
    }
    const ws = await window.studio.loadState<Record<string, string>>("workspaces.json");
    if (ws) set({ workspaces: ws });

  },

  /** Write the transcript now. Cheap, and called at every point worth surviving. */
  persist: () => {
    if (!get().portalWorkspaceId) return;
    void window.studio?.saveState({
      name: "conversations.json",
      value: {
        conversations: get().conversations,
        sessions: get().sessions,
        streamIndexes: get().streamIndexes,
        prefs: get().prefs,
      },
    });
  },

  portalWorkspaceId: null,
  portalWorkspaces: [],
  workspaceLoading: true,
  workspaceError: null,
  loadPortalWorkspaces: async () => {
    set({ workspaceLoading: true, workspaceError: null });
    try {
      const result = await window.studio.portalWorkspaces();
      if (!result.selectedId) { get().stopWatching(); set(emptyWorkspaceView()); }
      set({ portalWorkspaces: result.workspaces, portalWorkspaceId: result.selectedId });
      if (result.selectedId) {
        await get().restore();
        await get().refreshAgents();
      }
    } catch (e) { set({ portalWorkspaceId: null, workspaceError: e instanceof Error ? e.message : String(e) }); }
    finally { set({ workspaceLoading: false }); }
  },
  switchPortalWorkspace: async (id) => {
    get().persist();
    get().stopWatching();
    set({ ...emptyWorkspaceView(), portalWorkspaceId: null, workspaceLoading: true });
    try { await window.studio.selectPortalWorkspace(id); await get().loadPortalWorkspaces(); }
    catch (e) { set({ workspaceLoading: false, workspaceError: e instanceof Error ? e.message : String(e) }); }
  },

  bootstrap: async () => {
    if (!window.studio) {
      // The bridge is missing. Do NOT quietly show fixtures — that renders a
      // fully populated app backed by nothing, which is indistinguishable from
      // a working one until the user tries to send a message.
      set({
        authState: "signed-out",
        authError:
          "The app bridge did not load, so Studio cannot reach the control plane. This is a packaging fault, not a sign-in problem.",
      });
      return;
    }
    try {
      const planes = await window.studio.controlPlanes();
      set({ issuer: planes.profiles.find((p) => p.id === planes.activeId)?.issuer ?? DEFAULT_ISSUER });
      const session = await window.studio.session();
      if (!session) {
        set({ authState: "signed-out" });
        return;
      }
      set({
        authState: "signed-in",
        account: { email: session.email, orgName: session.orgName },
      });

      // Restore before touching the network, so reopening shows the
      // conversation immediately rather than an empty window that fills in later.
      await get().loadPortalWorkspaces();
      startCrossDeviceRefresh(get);
    } catch (e) {
      set({ authState: "signed-out", authError: e instanceof Error ? e.message : String(e) });
    }
  },

  refreshAgents: async (opts) => {
    if (!window.studio || !get().portalWorkspaceId) return;
    const workspaceId = get().portalWorkspaceId;
    // Which control plane this actually is. Held as a constant, the account menu
    // went on naming ours after the app had been pointed somewhere else.

    try {
      const remote = await window.studio.listAgents(opts?.refreshSession ? { refreshSession: true } : undefined);
      if (get().portalWorkspaceId !== workspaceId) return;
      if (remote.length === 0) {
        // An honest empty state. Keeping the fixtures here would show a
        // customer three agents they do not have.
        set({
          agents: [], activeAgentId: "",
          authError:
            NO_AGENT_NOTE,
        });
        return;
      }
      set({ authError: null, rosterNotice: remote[0]?.rosterNotice ?? null });
      startRosterRefresh(get);
      // Keep local presentation (accent, pin) but let the control plane own the
      // set: an agent whose grant was revoked must disappear from the sidebar.
      const palette = ["var(--tb-tone-teal)", "var(--tb-tone-wood)", "var(--tb-tone-moss)", "var(--tb-tone-stone)", "var(--tb-tone-brick)"];
      const existing = new Map(get().agents.map((a) => [a.id, a]));
      set({
        agents: remote.map((r, i) => {
          const prior = existing.get(r.id);
          const chosen = get().prefs[r.id] ?? {};
          // The account's choice — picture, name, colour — wins over this
          // machine's, because it is the one the phone also sees. A null in
          // it means "cleared somewhere", and this machine follows. Only when
          // the account has never chosen do the local prefs apply.
          const profile = r.profile ?? null;
          return {
            id: r.id,
            registeredName: r.name,
            // The user's name for it, if they gave one. The control plane's
            // name is the default, not the authority.
            name: (profile ? profile.displayName : chosen.name) ?? r.name,
            url: r.url ?? "",
            peers: r.peers ?? [],
            accent:
              (profile ? profile.accent : chosen.accent) ??
              prior?.accent ??
              palette[i % palette.length] ??
              "var(--tb-tone-teal)",
            // Restored on every refresh, like the name and the accent. Left out,
            // a picture would survive a relaunch and then vanish the next time
            // the agent list synced — which reads as the app losing it at
            // random rather than as a missing line here.
            avatar: (profile ? profile.avatar : chosen.avatar ?? prior?.avatar) ?? undefined,
            pinned: (profile ? profile.pinned : chosen.pinned) ?? prior?.pinned ?? undefined,
            hidden: (profile ? profile.hidden : chosen.hidden) ?? prior?.hidden ?? undefined,
            unread: prior?.unread,
            notifications: chosen.notifications ?? prior?.notifications ?? true,
            // "unknown" until something asks the agent itself. Holding an
            // address is not being alive, and calling it "online" here is what
            // made a registration whose machine was long gone look healthy.
            // Workspace agents: the card's state is the status (paused shows as offline plus its label).
            status: r.workspace
              ? (r.workspace.state === "online" ? "online" : "offline")
              : (r.hasUrl ?? r.reachable) ? (prior?.status ?? "unknown") : "offline",
            workspace: r.workspace,
            title: prior?.title,
            description: r.workspace ? r.workspace.purpose : prior?.description,
            lastMessageAt: prior?.lastMessageAt,
            lastMessagePreview: r.workspace
              ? r.workspace.purpose
              : (r.hasUrl ?? r.reachable)
                ? prior?.lastMessagePreview
                : "Registered, but no URL on file in the control plane.",
          };
        }),
        // Stay where the person is. This used to be `remote[0]?.id ?? current`,
        // which ran on EVERY refresh — including the explicit "Refresh agents"
        // menu item — and threw you into the first agent in the control plane's
        // list, out of whatever conversation or room you were reading.
        activeAgentId: (() => {
          const current = get().activeAgentId;
          if (current && remote.some((r) => r.id === current)) return current;
          return remote[0]?.id ?? current;
        })(),
      });

      // Choices made on this machine before the account could hold them are
      // carried up once, so a picture chosen last month is on the phone today.
      for (const r of remote) {
        const chosen = get().prefs[r.id] ?? {};
        const carry: Parameters<NonNullable<typeof window.studio>["saveAgentProfile"]>[0] = { agent: r.name };
        let send = false;

        // An agent with no profile at all is seeded from this machine.
        if (!r.profile) {
          if (chosen.name) { carry.displayName = chosen.name; send = true; }
          if (chosen.accent) { carry.accent = chosen.accent; send = true; }
          if (chosen.avatar) { carry.avatar = chosen.avatar; send = true; }
          if (chosen.pinned != null) { carry.pinned = chosen.pinned; send = true; }
          if (chosen.hidden != null) { carry.hidden = chosen.hidden; send = true; }
        }

        if (send) void window.studio.saveAgentProfile(carry);
      }

      // Then ask the agents themselves. Deliberately after the list is already
      // on screen and deliberately not awaited into it: liveness is worth
      // showing, never worth making someone wait for, and one unreachable host
      // must not hold up the whole sidebar behind its timeout.
      void get().refreshLiveness();
      void get().checkAgentModel();
    } catch (e) {
      if (get().portalWorkspaceId !== workspaceId) return;
      get().stopWatching();
      set({ agents: [], activeAgentId: "", authError: e instanceof Error ? e.message : String(e) });
    }
  },

  /**
   * Ask every agent with an address whether it is answering.
   *
   * The control plane can only say whether it holds a URL, and this app used to
   * render that as "online" — so an agent whose machine had been deleted looked
   * exactly like a healthy one. Only a client sitting where the user sits can
   * tell the difference, so it asks.
   */
  refreshLiveness: async () => {
    if (!window.studio) return;
    const targets = get()
      .agents.filter((a) => a.url && !a.workspace)
      .map((a) => ({ id: a.id }));
    await Promise.all(
      targets.map(async ({ id }) => {
        const live = await window.studio!.agentHealth(id);
        set((s) => ({
          agents: s.agents.map((a) =>
            a.id === id ? { ...a, status: live ? "online" : "offline" } : a,
          ),
        }));
      }),
    );
  },

  loadAgentInfo: async (agentId) => {
    const agent = get().agents.find((a) => a.id === agentId);
    // A workspace agent's card is all TBD knows about it (C127): nothing to load, nothing failed.
    if (agent?.workspace) { if (get().activeAgentId === agentId) set({ infoError: null }); return; }
    if (!window.studio || !agent?.url) {
      if (get().activeAgentId === agentId) set({ infoError: "This agent has no desktop endpoint configured in the portal. Routines cannot be loaded until it is connected." });
      return;
    }
    const workspace = get().portalWorkspaceId;
    if(get().activeAgentId===agentId)set({infoError:null});
    const raw = await window.studio.agentInfo(agent.id).catch(()=>null);
    if(get().portalWorkspaceId!==workspace)return;
    if (!raw) { if(get().activeAgentId===agentId)set({infoError:"Could not reach this agent. It may be asleep or restarting. Retry once it is online."}); return; }
    const info = summarize(raw);
    // Publish primary info immediately; optional extensions cannot block it.
    set(s=>({details:{...s.details,[agentId]:info},models:info.model?{...s.models,[agentId]:info.model}:s.models}));
  },

  cancelSignIn: async () => {
    // Clears the error too: abandoning a wait is a choice, not a fault, and
    // leaving "sign-in cancelled" on screen reads as something going wrong.
    await window.studio?.cancelSignIn();
    set({ authError: null });
  },

  signIn: async (onCode) => {
    if (!window.studio) return false;
    set({ authError: null });
    try {
      const { userCode, verificationUri } = await window.studio.signIn();
      onCode(userCode, verificationUri);
      const session = await window.studio.awaitSignIn();
      set({
        authState: "signed-in",
        account: { email: session.email, orgName: session.orgName },
        authError: null,
      });
      await get().loadPortalWorkspaces();
      return true;
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      // A cancellation travels as an error because that is how an abandoned
      // await unwinds; it is not one, and reporting it would make starting
      // again look like a failure.
      set({ authError: /sign-in cancelled/i.test(message) ? null : message });
      return false;
    }
  },

  signOut: async () => {
    // Persist first, and keep the transcript. Signing out ends a SESSION, not a
    // history — the eve session ids are dropped because they will not resume,
    // but what was said stays and reappears on the next sign-in.
    get().persist();
    await window.studio?.signOut();
    get().stopWatching();
    set({ ...emptyWorkspaceView(), authState: "signed-out", authError: null, account: null, portalWorkspaceId: null, portalWorkspaces: [] });
  },
}));
