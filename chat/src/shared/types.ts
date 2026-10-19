/**
 * The TBD Chat domain model.
 *
 * Studio is the customer's console for agents that already exist. Agents run
 * where they were deployed — Vercel, exe.dev, a client VM — and Studio is a
 * door onto them alongside Slack and iMessage, not a replacement for either.
 *
 * Chat is the front door, but the app is not read-only: connections, channels,
 * routines, instructions, and agent identity are all managed here, because a
 * customer who lives in this app should never be told to go open a terminal to
 * connect Gmail or add Slack. What it deliberately does NOT do is scaffold and
 * deploy a new agent from nothing — that stays with `kyb init` and the FDE.
 */

/** A remote agent the user has a control-plane grant for. */
export interface Agent {
  /** Agents this one may call, as granted in the control plane. */
  peers?: { id: string; name: string; purpose?: string }[];
  id: string;
  /** Display name in the sidebar and header. */
  name: string;
  /** The control plane's name for it, which the account-wide profile is keyed by. */
  registeredName?: string;
  /** One-line role, shown under the name in Settings. */
  title?: string;
  description?: string;
  /** Base URL of the agent's eve deployment. Display only: IPC names agents by id. */
  url: string;
  /** Hex color for the generated avatar mark, used when there is no picture. */
  accent: string;
  /**
   * A picture for this agent, as a data URL.
   *
   * @remarks
   * Stored inline rather than as a path, deliberately. A path breaks the moment
   * someone moves the file, empties a Downloads folder, or signs in on a second
   * machine — and it breaks silently, leaving a blank where a face was. The
   * image is resized to a small square before it gets here, so carrying the
   * bytes costs a few kilobytes and never has to be resolved again.
   */
  avatar?: string;
  /** Sidebar organization. */
  pinned?: boolean;
  hidden?: boolean;
  unread?: boolean;
  notifications?: boolean;
  /** Populated from the transport; never assumed. */
  status?: "online" | "offline" | "unknown";
  /** Another agent of the Portal workspace (C127): its card. Listed only; no chat yet. */
  workspace?: import("./ipc").WorkspaceAgentInfo;
  lastMessageAt?: number;
  lastMessagePreview?: string;
}

export type MessageRole = "user" | "agent";

/** One rendered block in a conversation. */
export type Block =
  | {
      kind: "text";
      id: string;
      role: MessageRole;
      text: string;
      at: number;
      /**
       * Who said it, when that is not obvious.
       *
       * A one-to-one conversation has exactly one agent, so the role says
       * everything. A room has several, and an unattributed run of replies is
       * unreadable — you cannot tell which agent answered, or that two of them
       * disagreed with each other.
       */
      speaker?: { id: string; name: string; accent: string };
    }
  | { kind: "peer-activity"; id: string; at: number; events: PeerEvent[] }
  /** A Connect call waits for the owner's approval (C4): "Waiting for owner approval" with an "Open approval" link. */
  | { kind: "hold"; id: string; at: number; label: string; holdId: string; url?: string }
  | {
      kind: "authorization";
      id: string;
      at: number;
      /** The connection asking, e.g. "gmail". */
      name: string;
      description?: string;
      /** Where the user signs in. Opened in their real browser, never in-app. */
      url?: string;
      userCode?: string;
      instructions?: string;
      expiresAt?: string;
      /** Set when the flow resolves, so the card stops asking. */
      outcome?: string;
    }
  | {
      kind: "question";
      id: string;
      at: number;
      /** eve's requestId, which the answer must carry back. */
      requestId: string;
      prompt: string;
      options?: { id: string; label: string; description?: string; style?: string }[];
      allowFreeform?: boolean;
      /** Set once answered, so the transcript keeps what was chosen. */
      answered?: string;
    };

/** One agent-to-agent hop, as reported by the dispatch layer. */
export interface PeerEvent {
  id: string;
  direction: "inbound" | "outbound";
  peer: { id: string; name: string; accent: string };
  text: string;
  at: number;
}

/**
 * Collapsed summary of a run of agent-to-agent events.
 *
 * Three shapes, because they read very differently in a transcript: one hop is
 * a sentence, a broadcast is a count of recipients, and a back-and-forth is a
 * count of messages. Anything else would either bury the peer names or lie
 * about the direction of the conversation.
 */
export type PeerSummary =
  | { kind: "single"; direction: "inbound" | "outbound"; peer: PeerEvent["peer"] }
  | { kind: "fanout"; peers: PeerEvent["peer"][] }
  | { kind: "thread"; messageCount: number; peers: PeerEvent["peer"][] };

export function summarizePeerEvents(events: PeerEvent[]): PeerSummary | null {
  if (events.length === 0) return null;
  const peers = new Map<string, PeerEvent["peer"]>();
  for (const e of events) peers.set(e.peer.id, e.peer);
  const unique = [...peers.values()];
  const first = events[0];
  if (events.length === 1 && first) {
    return { kind: "single", direction: first.direction, peer: first.peer };
  }
  if (events.every((e) => e.direction === "outbound") && unique.length >= 2) {
    return { kind: "fanout", peers: unique };
  }
  return { kind: "thread", messageCount: events.length, peers: unique };
}

export function peerSummaryLabel(
  s: PeerSummary,
): { text: string; peers: PeerEvent["peer"][] } {
  // Text and chips, not one string. The agents in a summary are things you can
  // click — naming them inside a sentence makes them read like prose and look
  // unclickable, which is the difference between "2 messages with 1 agents" and
  // a line you can actually follow into the exchange.
  switch (s.kind) {
    case "single":
      return {
        text: s.direction === "inbound" ? "Message from" : "Messaged",
        peers: [s.peer],
      };
    case "fanout":
      return { text: "Messaged", peers: s.peers };
    case "thread":
      return { text: `${s.messageCount} messages with`, peers: s.peers };
  }
}

/** A recurring instruction the agent runs on a schedule. */
export interface Routine {
  id: string;
  agentId: string;
  name: string;
  instruction: string;
  active: boolean;
  /** Human-readable for now; the agent's own scheduler owns the cron. */
  schedules: string[];
  runHistory: { at: number; ok: boolean }[];
}

/** A capability offered in the Plugins marketplace. */
export interface Plugin {
  id: string;
  name: string;
  description: string;
  category: string;
  icon?: string;
  added?: boolean;
}


/**
 * A capability the agent can be told to run, offered by the composer's `/` menu.
 * Skills come from the agent's own deployment — Studio lists what the agent
 * reports rather than a hardcoded set, so a skill added by the FDE shows up
 * here without an app release.
 */
export interface Skill {
  id: string;
  name: string;
  description: string;
}
