import { Fragment, type ReactNode, useEffect, useRef, useState } from "react";
import {
  filesFromClipboard,
  formatSize,
  readFiles,
  type PendingAttachment,
} from "../lib/attachments";
import type { Block, PeerEvent } from "@shared/types";
import { peerSummaryLabel, summarizePeerEvents } from "@shared/types";
import { approvalLine } from "@shared/hold";
import { useStore } from "@/lib/store";
import * as composerDom from "@/lib/composerDom";
import { Autocomplete, type Suggestion } from "./Autocomplete";
import { LocalAskCard } from "./LocalAsk";
import { FirstRunChecks } from "./FirstRun";
import { NO_MODEL_TITLE, SET_UP_MODEL, modelGate } from "@/lib/agentModel";
import { Markdown } from "./Markdown";
import { record, type Recorder } from "../lib/dictation";
import { DeliveredFiles } from "./DeliveredFiles";
import { deliveredFiles } from "../../../shared/deliveredFiles";
import { Spinner } from "./Spinner";
import { Avatar, Icon, RichText, timeLabel } from "./primitives";

/**
 * Agent-to-agent traffic, collapsed.
 *
 * When agents talk to each other the transcript can drown the human's own
 * conversation, so a run of hops collapses to one line the user can open. The
 * summary distinguishes a single hop from a broadcast from a back-and-forth,
 * because those read very differently and a generic "3 events" tells you
 * nothing about who is talking to whom.
 */
/**
 * When a message was sent, shown only where it tells you something.
 *
 * A timestamp on every message is noise: in a live exchange you already know
 * when it happened, because you were there. What carries information is the
 * SEAM — the point where a conversation was picked up again after a gap. So one
 * marker per sitting, and the same wording a messages app uses, because that is
 * the reading people already have.
 */
function whenLabel(at: number, previous?: number): string | null {
  const GAP_MS = 60 * 60_000;
  if (previous !== undefined && at - previous < GAP_MS) return null;

  const date = new Date(at);
  const now = new Date();
  const time = date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return time;

  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;

  const within7 = now.getTime() - at < 7 * 24 * 60 * 60_000;
  const day = date.toLocaleDateString([], within7 ? { weekday: "long" } : { month: "short", day: "numeric" });
  return `${day} ${time}`;
}

/**
 * One line saying two agents talked, with the other agent as a chip you can
 * follow into the exchange.
 *
 * Deliberately not an accordion. The exchange is a conversation between two
 * agents; unfolding it inside this thread makes the user's own conversation the
 * container for someone else's, and the two read as one jumbled transcript.
 */
function PeerActivity({
  events,
  agentId,
  blockId,
}: {
  events: PeerEvent[];
  agentId: string;
  blockId: string;
}): ReactNode {
  const openExchange = useStore((s) => s.openExchange);
  const summary = summarizePeerEvents(events);
  if (!summary) return null;
  const { text, peers } = peerSummaryLabel(summary);

  return (
    <div className="sysline">
      <span>{text}</span>
      {peers.slice(0, 3).map((peer) => (
        <button
          key={peer.id}
          className="agent-chip"
          title={`Open the exchange with ${peer.name}`}
          onClick={() => openExchange(agentId, blockId)}
        >
          {/* Same markup as a mention chip, so both read as one design. */}
          <span className="mention__icon">
            {peer.name.trim().charAt(0).toUpperCase()}
          </span>
          {peer.name}
        </button>
      ))}
    </div>
  );
}

/**
 * The exchange itself, read as its own conversation.
 *
 * Attribution is by DIRECTION, which is the bug this replaces: every row used
 * to be captioned with the peer's name, so a thread where this agent asked and
 * the peer answered read as the peer asking itself. Outbound is this agent
 * speaking; inbound is the peer.
 */
function ExchangeView(): ReactNode {
  const exchange = useStore((s) => s.exchange);
  const closeExchange = useStore((s) => s.closeExchange);
  const conversations = useStore((s) => s.conversations);
  const agents = useStore((s) => s.agents);
  if (!exchange) return null;

  const self = agents.find((a) => a.id === exchange.agentId);
  const block = (conversations[exchange.agentId] ?? []).find((b) => b.id === exchange.blockId);
  if (!self || !block || block.kind !== "peer-activity") return null;

  const peer = block.events[0]?.peer;

  return (
    <div className="exchange">
      <div className="exchange__head">
        <Avatar name={self.name} accent={self.accent} size={20} />
        <span>{self.name}</span>
        <span className="exchange__arrow">⇄</span>
        {peer ? <Avatar name={peer.name} accent={peer.accent} size={20} /> : null}
        <span>{peer?.name}</span>
      </div>

      <div className="exchange__body">
        {block.events.map((e) => {
          const speaker = e.direction === "outbound" ? self : e.peer;
          return (
            <div className="exchange__turn" key={e.id}>
              <Avatar name={speaker.name} accent={speaker.accent} size={22} />
              <div style={{ minWidth: 0 }}>
                <div className="exchange__who">
                  {speaker.name} · {timeLabel(e.at)}
                </div>
                <div className="exchange__bubble">{e.text}</div>
              </div>
            </div>
          );
        })}
      </div>

      <div className="exchange__foot">
        <Icon name="lock" size={12} />
        <span>This exchange is view-only</span>
        <button className="btn" onClick={closeExchange}>
          Close
        </button>
      </div>
    </div>
  );
}

/**
 * A question the agent asked, with its answer kept beside it.
 *
 * eve parks a turn on input.requested and waits. Studio used to drop the event,
 * so the agent looked like it had returned nothing when it was in fact waiting
 * on the user — the most confusing possible failure, because the conversation
 * had simply stopped.
 */
function QuestionCard({
  block,
  onAnswer,
}: {
  block: Extract<Block, { kind: "question" }>;
  onAnswer(answer: { optionId?: string; text?: string }): void;
}): ReactNode {
  const [text, setText] = useState("");

  if (block.answered) {
    return (
      <div className="ask ask--done">
        <div className="ask__title">{block.prompt}</div>
        <div className="ask__answered">
          <Icon name="check" size={13} /> {block.answered}
        </div>
      </div>
    );
  }

  return (
    <div className="ask">
      <div className="ask__title" style={{ marginBottom: 10 }}>{block.prompt}</div>
      {block.options?.length ? (
        <div className="ask__options">
          {block.options.map((o) => (
            <button
              key={o.id}
              className={`btn${o.style === "primary" ? " btn--primary" : ""}`}
              title={o.description}
              onClick={() => onAnswer({ optionId: o.id })}
            >
              {o.label}
            </button>
          ))}
        </div>
      ) : null}
      {block.allowFreeform !== false ? (
        <div className="ask__freeform">
          <input
            className="input"
            value={text}
            placeholder="Or type an answer"
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && text.trim()) onAnswer({ text: text.trim() });
            }}
          />
          <button className="btn" disabled={!text.trim()} onClick={() => onAnswer({ text: text.trim() })}>
            Send
          </button>
        </div>
      ) : null}
    </div>
  );
}

/**
 * A connection asking the user to sign in, mid-conversation.
 *
 * eve parks the turn and resumes it after the callback, so this card is the
 * whole interaction: the turn is not failing, it is waiting on a browser tab.
 * Rendering it is what turns "the agent stopped" into "Gmail wants you to sign
 * in", and it is the same card whatever brokered the connection.
 *
 * The link opens in the real browser, never in an app window. A window that
 * asks for a Google password while pretending to be Chrome is indistinguishable
 * from the thing security training tells people never to trust.
 */
function AuthorizationCard({
  block,
}: {
  block: Extract<Block, { kind: "authorization" }>;
}): ReactNode {
  const settled = block.outcome && block.outcome !== "pending";
  const good = block.outcome === "authorized";

  if (settled) {
    return (
      <div className="ask ask--done">
        <div className="ask__title">
          {good ? `${block.name} connected` : `${block.name} was not connected`}
        </div>
        {!good ? <div className="muted">{block.outcome}</div> : null}
      </div>
    );
  }

  return (
    <div className="ask">
      <div className="ask__title" style={{ marginBottom: 4 }}>
        Sign in to {block.name}
      </div>
      <div className="muted" style={{ marginBottom: 10 }}>
        {block.instructions ?? block.description ?? "The agent needs access before it can continue."}
      </div>
      <div className="ask__options">
        <button
          className="btn btn--primary"
          disabled={!block.url}
          onClick={() => block.url && void window.studio?.openExternal(block.url)}
        >
          Open sign-in
        </button>
        {block.userCode ? <span className="ask__code">{block.userCode}</span> : null}
      </div>
    </div>
  );
}


/** A Connect call is waiting for the owner (C4). The approval opens in the system browser; TBD never approves a hold itself. */
function HoldNotice({ block }: { block: Extract<Block, { kind: "hold" }> }): ReactNode {
  return (
    <div className="ask">
      <div className="ask__title" style={{ marginBottom: 4 }}>{block.label}</div>
      <div className="muted" style={{ marginBottom: 4 }}>{approvalLine(block.holdId)}</div>
      <div className="muted" style={{ marginBottom: 10 }}>The owner decides this in the app. TBD&apos;s agent repeats the call after the owner approves it.</div>
      <div className="ask__options">
        <button type="button" className="btn btn--primary" disabled={!block.url} onClick={() => block.url && void window.studio?.openExternal(block.url)}>
          Open approval
        </button>
      </div>
    </div>
  );
}

export function Conversation(): ReactNode {
  const {
    agents,
    activeAgentId,
    conversations,
    send,
    panel,
    setPanel,
    details,
    answerQuestion,
    inflight,
    queued,
    stopTurn,
    activity,
    models,
    loadAgentInfo,
    workspaces,
    chooseWorkspace,
    setWorkspace,
    agentModel,
    rosterNotice,
  } = useStore();
  const agent = agents.find((a) => a.id === activeAgentId);
  // No model for TBD's agent: Send becomes "Set up a model" and the draft stays.
  const gate = modelGate(activeAgentId, agentModel);
  const openModelSetup = (): void => { void window.studio?.openSettings("engine"); };
  const checkAgentModel = useStore((s) => s.checkAgentModel);
  // Settings opens in the same window, so a focus event may never come: re-check while blocked.
  useEffect(() => {
    if (!gate.blocked) return;
    const timer = setInterval(() => { void checkAgentModel(); }, 5000);
    return () => clearInterval(timer);
  }, [gate.blocked, checkAgentModel]);
  const sessions = useStore((s) => s.sessions);
  // Who this agent can be asked to talk to — the control plane's list, reused
  // for both the @ menu and for drawing mentions in what was sent.
  const mentionable = (agent?.peers ?? []).map((peer) => ({
    name: peer.name,
    accent: agents.find((a) => a.id === peer.id || a.name === peer.name)?.accent,
  }));
  const blocks = conversations[activeAgentId] ?? [];
  const [draft, setDraft] = useState("");
  const [acCursor, setAcCursor] = useState(0);
  const [folderMenu, setFolderMenu] = useState(false);
  /** Files chosen for the next message, not yet sent. */
  const [pending, setPending] = useState<PendingAttachment[]>([]);
  /** Why the last attempt to attach did not fully work. */
  const [attachError, setAttachError] = useState<string | null>(null);
  /** Whether files are being dragged over the composer right now. */
  const [dragging, setDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  /** The live recorder while the user holds the mic; null when not recording. */
  const recorderRef = useRef<Recorder | null>(null);
  const dictationEpoch = useRef(0);
  useEffect(() => () => {
    dictationEpoch.current += 1;
    recorderRef.current?.cancel();
    recorderRef.current = null;
  }, [activeAgentId]);
  /** "idle" | "recording" | "transcribing" — what the mic control is doing. */
  const [voice, setVoice] = useState<"idle" | "recording" | "transcribing">("idle");
  /** Input level while recording, so a muted microphone is visible as one. */
  const [level, setLevel] = useState(0);
  const [voiceError, setVoiceError] = useState<string | null>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const innerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLDivElement>(null);
  /**
   * Whether the view is following the tail of the conversation.
   *
   * Scrolling on new blocks alone is not enough: a reply arrives as one block
   * whose text keeps growing, and the activity line and tool calls appear
   * underneath it. None of that changes the block COUNT, so the window sat
   * still while the answer wrote itself just out of sight — the agent looked
   * idle when it was working.
   *
   * Following is a mode the user controls by scrolling. Scroll up to read
   * something and the view stops chasing; return to the bottom and it resumes.
   * Yanking someone back mid-read would be worse than not scrolling at all.
   */
  const following = useRef(true);

  useEffect(() => {
    const thread = threadRef.current;
    const inner = innerRef.current;
    if (!thread || !inner) return;

    const toBottom = (): void => {
      // Assigning scrollTop rather than scrollIntoView: this scrolls exactly
      // one container, and stays smooth under rapid streaming updates.
      thread.scrollTop = thread.scrollHeight;
    };

    // Any change in rendered height — a delta, a tool call, a card expanding.
    const observer = new ResizeObserver(() => {
      if (following.current) toBottom();
    });
    observer.observe(inner);
    toBottom();
    return () => observer.disconnect();
  }, [activeAgentId]);

  // Switching conversations always lands at the newest message.
  useEffect(() => {
    following.current = true;
  }, [activeAgentId]);

  useEffect(() => {
    void loadAgentInfo(activeAgentId);
  }, [activeAgentId, loadAgentInfo]);

  // Landing on an agent means you are about to talk to it: the composer takes
  // the caret without a click. After paint, so the switch has rendered the
  // input this effect is focusing.
  useEffect(() => {
    const id = window.requestAnimationFrame(() => {
      const el = inputRef.current;
      if (el) composerDom.focusAtEnd(el);
    });
    return () => window.cancelAnimationFrame(id);
  }, [activeAgentId]);

  const busy = activity[activeAgentId] ?? null;
  const model = models[activeAgentId];
  // A turn in flight, which is a stronger fact than an activity label: the
  // label goes quiet between steps, but the session is still not accepting.
  const running = Boolean(inflight[activeAgentId]);
  const waiting = queued[activeAgentId]?.length ?? 0;


  /**
   * What the caret is sitting in, not what the message ends with.
   *
   * With a textarea those were the same thing. In a contenteditable the caret
   * can be anywhere — including before an existing chip — so reading the end of
   * the serialized text would open the menu for a word the user is not typing.
   */
  const [caretTrigger, setCaretTrigger] = useState<{ char: string; term: string } | null>(null);
  const triggerChar = caretTrigger?.char ?? null;
  const triggerTerm = caretTrigger?.term ?? "";

  const suggestions: Suggestion[] = (() => {
    if (!triggerChar) return [];
    const match = (t: string): boolean => !triggerTerm || t.toLowerCase().includes(triggerTerm);

    const info = details[activeAgentId];

    if (triggerChar === "/") {
      // What the agent can DO — its real skills, as it reports them.
      const fromSkills: Suggestion[] = (info?.skills ?? [])
        .filter((k) => match(k.name))
        .map((k) => ({ id: `skill:${k.name}`, title: k.name, detail: k.description, type: "Skill" }));
      const actions: Suggestion[] = [
        { id: "act:settings", title: "Chat Settings", detail: "Current chat", type: "Action" },
        { id: "act:channels", title: "Channels", detail: "Current agent", type: "Action" },
      ].filter((a) => match(a.title)) as Suggestion[];
      return [...fromSkills, ...actions].slice(0, 8);
    }

    /**
     * Agents first, because @ is for addressing someone.
     *
     * These are the peers the CONTROL PLANE says this agent may call, not a
     * list the agent asserts about itself — so an edge revoked in the admin
     * stops being suggested here, and tagging someone it cannot reach is not
     * offered in the first place.
     */
    const fromPeers: Suggestion[] = (agent?.peers ?? [])
          .filter((peer) => match(peer.name))
          .map((peer) => ({
            id: `agent:${peer.id}`,
            title: peer.name,
            detail: peer.purpose,
            type: "Agent" as const,
            accent: agents.find((a) => a.id === peer.id || a.name === peer.name)?.accent,
          }));

    // What the agent can REACH — its real connections, tools, and schedules.
    const fromRoutines: Suggestion[] = (info?.schedules ?? [])
      .filter((r) => match(r.name))
      .map((r) => ({ id: `routine:${r.name}`, title: r.name, detail: r.cron, type: "Routine" }));
    const fromConnections: Suggestion[] = (info?.connections ?? [])
      .filter((c) => match(c.name))
      .map((c) => ({
        id: `conn:${c.name}`,
        title: c.name,
        detail: c.description,
        type: "Plugin",
      }));
    const fromTools: Suggestion[] = (info?.tools ?? [])
      .filter((t) => match(t.name))
      .map((t) => ({ id: `tool:${t.name}`, title: t.name, detail: t.description, type: "Plugin" }));
    return [...fromPeers, ...fromRoutines, ...fromConnections, ...fromTools].slice(0, 8);
  })();

  const applySuggestion = (s: Suggestion): void => {
    const el = inputRef.current;
    if (!el) return;

    if (s.type === "Action") {
      composerDom.removeTrigger(el);
      setDraft(composerDom.serialize(el));
      setCaretTrigger(null);
      if (s.id === "act:channels") setPanel("overview");
      else setPanel("settings");
      return;
    }

    // An agent becomes a chip; everything else stays text, because a skill or a
    // tool is not someone you are addressing.
    if (s.type === "Agent") {
      composerDom.replaceTriggerWithChip(el, { name: s.title, accent: s.accent });
    } else {
      composerDom.replaceTriggerWithText(el, `${triggerChar ?? ""}${s.title} `);
    }
    setDraft(composerDom.serialize(el));
    setCaretTrigger(null);
    setAcCursor(0);
    el.focus();
  };

  if (!agent) return <div className="main" />;

  /**
   * Attaching a file is the user handing something over deliberately.
   *
   * @remarks
   * Distinct from the agent reaching into the filesystem, which is what local
   * access governs and asks about separately. That distinction is the whole
   * reason the bytes travel with the message instead of a path: what is shared
   * is this file, chosen at this moment, and nothing else on the disk.
   */
  const attach = async (files: readonly File[]): Promise<void> => {
    if (files.length === 0) return;
    const { accepted, rejected } = await readFiles(files, pending);
    if (accepted.length > 0) setPending((current) => [...current, ...accepted]);
    // Refusals replace rather than accumulate: the second attempt's problem is
    // the one being solved, and a stack of stale complaints obscures it.
    setAttachError(rejected.length > 0 ? rejected.join(" ") : null);
  };

  /**
   * Click to start, click again to stop and transcribe.
   *
   * The microphone opens only between those two clicks; it is not listening
   * before the first or after the second. Holding a button down for the length
   * of a sentence is fine for a two-word command and tiring for anything real,
   * and it makes the button impossible to use while reading something else on
   * screen — which is most of what dictation is for.
   */
  const startDictation = async (): Promise<void> => {
    if (voice !== "idle") return;
    setVoiceError(null);
    try {
      const epoch = dictationEpoch.current;
      const recorder = await record();
      if (dictationEpoch.current !== epoch) { recorder.cancel(); return; }
      recorderRef.current = recorder;
      setVoice("recording");
      const tick = (): void => {
        if (recorderRef.current !== recorder) return;
        setLevel(recorder.level());
        requestAnimationFrame(tick);
      };
      tick();
    } catch {
      // Refused permission, or no input device. Either way the honest answer is
      // that the microphone is unavailable, not that dictation is broken.
      setVoiceError("No microphone available. Check the system permission for TBD.");
      setVoice("idle");
    }
  };

  const finishDictation = async (): Promise<void> => {
    const recorder = recorderRef.current;
    if (!recorder || voice !== "recording") return;
    recorderRef.current = null;
    setVoice("transcribing");
    setLevel(0);
    const epoch = dictationEpoch.current;
    const result: { text?: string; error?: string } = await recorder.finishText();
    if (dictationEpoch.current !== epoch) return;
    setVoice("idle");
    if (result.error) {
      setVoiceError(result.error);
      return;
    }
    const el = inputRef.current;
    if (!el || !result.text) return;
    // Inserted at the caret rather than replacing the draft: dictation is
    // another way to type, so it must compose with what is already written.
    el.focus();
    document.execCommand("insertText", false, (draft.trim() ? " " : "") + result.text);
    setDraft(composerDom.serialize(el));
  };

  const cancelDictation = (): void => {
    recorderRef.current?.cancel();
    recorderRef.current = null;
    setLevel(0);
    setVoice("idle");
  };

  const submit = (): void => {
    const text = draft.trim();
    // A file with no words is still a message — dragging a document in and
    // pressing enter means "look at this", and refusing it as empty is wrong.
    if (!text && pending.length === 0) return;
    if (gate.blocked) { openModelSetup(); return; }
    if (agent) send(agent.id, text, false, pending.length > 0 ? pending : undefined);
    setDraft("");
    setPending([]);
    setAttachError(null);
    if (inputRef.current) composerDom.clear(inputRef.current);
  };

  return (
    <div className="main" style={{ position: "relative" }}>
      <ExchangeView />
      <div className="topbar">
        <Avatar name={agent!.name} accent={agent!.accent} src={agent!.avatar} size={22} />
        <span className="topbar__title">{agent!.name}</span>
        <div className="topbar__spacer" />
        {workspaces[activeAgentId] ? (
          <div className="workspace-wrap">
            <button
              className="workspace"
              title={workspaces[activeAgentId]}
              onClick={() => setFolderMenu((v) => !v)}
            >
              <Icon name="folder" size={13} />
              {workspaces[activeAgentId]!.split("/").pop()}
            </button>
            {folderMenu ? (
              <div className="menu workspace-menu">
                <button
                  className="menu__item"
                  onClick={() => {
                    setFolderMenu(false);
                    void chooseWorkspace(activeAgentId);
                  }}
                >
                  <Icon name="folder" /> Change folder…
                </button>
                <button
                  className="menu__item"
                  onClick={() => {
                    setFolderMenu(false);
                    setWorkspace(activeAgentId, null);
                  }}
                >
                  <Icon name="close" /> Clear working folder
                </button>
              </div>
            ) : null}
          </div>
        ) : (
          <button
            className="workspace workspace--empty"
            title="Set a default working folder on this machine (optional)"
            onClick={() => void chooseWorkspace(activeAgentId)}
          >
            <Icon name="folder" size={13} />
            Folder
          </button>
        )}
        <button
          className={`topbar__btn${panel !== "none" ? " topbar__btn--on" : ""}`}
          title="Agent panel"
          onClick={() => setPanel(panel === "none" ? "overview" : "none")}
        >
          <Icon name="sidePanel" />
        </button>
      </div>

      <div
        className="thread"
        ref={threadRef}
        onScroll={(e) => {
          const el = e.currentTarget;
          // A small tolerance: sub-pixel layout and the last delta both leave
          // you a few pixels short of the true bottom.
          following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
        }}
      >
        <div className="thread__inner" ref={innerRef}>
          <FirstRunChecks conversationEmpty={blocks.length === 0} />
          {blocks.map((b, i) => {
            const when = whenLabel(b.at, i > 0 ? blocks[i - 1].at : undefined);
            const marker = when ? (
              <div className="thread__when" key={`w${b.id}`}>
                {when}
              </div>
            ) : null;
            const body = ((): ReactNode => {
            if (b.kind === "peer-activity")
              return (
                <PeerActivity key={b.id} events={b.events} agentId={activeAgentId} blockId={b.id} />
              );
            if (b.kind === "authorization") return <AuthorizationCard key={b.id} block={b} />;
            if (b.kind === "hold") return <HoldNotice key={b.id} block={b} />;
            if (b.kind === "question")
              return (
                <QuestionCard
                  key={b.id}
                  block={b}
                  onAnswer={(answer) => answerQuestion(activeAgentId, b.id, answer)}
                />
              );
              // Who said it, above what they said, when the turn names a speaker.
              return b.speaker ? (
                <div key={b.id} className="said">
                  <div className="said__who">{b.speaker.name}</div>
                  <div className="said__row">
                    <Avatar name={b.speaker.name} accent={b.speaker.accent} size={22} />
                    <div className="bubble bubble--agent">
                      <Markdown text={b.text} />
                      <DeliveredFiles files={deliveredFiles(b.text)} />
                    </div>
                  </div>
                </div>
              ) : (
                <div key={b.id} className={`bubble bubble--${b.role}`}>
                  {b.role === "agent" ? (
                    <>
                      <Markdown text={b.text} />
                      {/* Under the words, never instead of them: the sentence
                          explaining what the file is stays exactly as written. */}
                      <DeliveredFiles files={deliveredFiles(b.text)} />
                    </>
                  ) : (
                    <RichText text={b.text} mentions={mentionable} />
                  )}
                </div>
              );
            })();

            // A marker and its block travel together, so the label always sits
            // directly above the message that opened the sitting.
            return marker ? (
              <Fragment key={b.id}>
                {marker}
                {body}
              </Fragment>
            ) : (
              body
            );
          })}
          {blocks.length === 0 ? (
            <div className="empty">
              {`No messages yet. Say hello to ${agent?.name}.`}
            </div>
          ) : null}
          {busy ? (
            <div className="activity">
              <Spinner />
              <span className="activity__label">{busy}</span>
            </div>
          ) : null}
        </div>
      </div>

      {rosterNotice ? <div className="composer__attach-error" role="status" style={{ margin: "0 16px" }}>{rosterNotice}</div> : null}
      <div className="composer">
        <LocalAskCard />
        {suggestions.length > 0 ? (
          <div className="composer__ac">
            <Autocomplete
              items={suggestions}
              cursor={acCursor}
              onPick={applySuggestion}
              onHover={setAcCursor}
            />
          </div>
        ) : null}
        {pending.length > 0 ? (
          <div className="composer__files">
            {pending.map((file) => (
              <span key={file.id} className="chip-file" title={`${file.name} · ${file.mediaType}`}>
                <Icon name="paperclip" size={11} />
                <span className="chip-file__name">{file.name}</span>
                <span className="chip-file__size">{formatSize(file.size)}</span>
                <button
                  className="chip-file__x"
                  title="Remove"
                  aria-label={`Remove ${file.name}`}
                  onClick={() => setPending((c) => c.filter((f) => f.id !== file.id))}
                >
                  ×
                </button>
              </span>
            ))}
          </div>
        ) : null}
        {gate.blocked ? (
          <div className="composer__attach-error" role="status">
            <strong>{NO_MODEL_TITLE}.</strong> {gate.note}
          </div>
        ) : null}
        {attachError ? <div className="composer__attach-error">{attachError}</div> : null}
        {voiceError ? <div className="composer__attach-error">{voiceError}</div> : null}
        {voice === "recording" ? (
          <div className="composer__voice">
            <span className="composer__voice-dot" />
            <span>Listening — click again to transcribe, Esc to discard</span>
            {/* The level is what tells someone the microphone is actually
                hearing them. Without it a muted input looks like silence. */}
            <span className="composer__voice-level">
              <span style={{ width: `${Math.min(100, Math.round(level * 140))}%` }} />
            </span>
          </div>
        ) : null}
        <div
          className={`composer__inner${dragging ? " composer__inner--drop" : ""}`}
          onDragOver={(e) => {
            // Only for actual files: a drag of selected text inside the
            // composer must keep behaving like text.
            if (!Array.from(e.dataTransfer.types).includes("Files")) return;
            e.preventDefault();
            setDragging(true);
          }}
          onDragLeave={(e) => {
            // Fires when crossing onto a child element too, which would flicker
            // the highlight off while the pointer is still over the composer.
            if (e.currentTarget.contains(e.relatedTarget as Node | null)) return;
            setDragging(false);
          }}
          onDrop={(e) => {
            if (!Array.from(e.dataTransfer.types).includes("Files")) return;
            e.preventDefault();
            setDragging(false);
            void attach(Array.from(e.dataTransfer.files));
          }}
        >
          <input
            ref={fileInputRef}
            type="file"
            multiple
            style={{ display: "none" }}
            onChange={(e) => {
              void attach(Array.from(e.target.files ?? []));
              // Cleared so choosing the same file twice in a row still fires a
              // change event.
              e.target.value = "";
            }}
          />
          <button
            className="icon-btn"
            title="Attach a file"
            aria-label="Attach a file"
            onClick={() => fileInputRef.current?.click()}
          >
            <Icon name="plus" />
          </button>
          <div
            ref={inputRef}
            className="composer__input"
            contentEditable
            role="textbox"
            aria-multiline="true"
            suppressContentEditableWarning
            data-placeholder={`Message ${agent?.name}`}
            onInput={() => {
              const el = inputRef.current;
              if (!el) return;
              setDraft(composerDom.serialize(el));
              setCaretTrigger(composerDom.triggerBeforeCaret(el));
            }}
            onKeyUp={() => {
              const el = inputRef.current;
              if (el) setCaretTrigger(composerDom.triggerBeforeCaret(el));
            }}
            onMouseUp={() => {
              const el = inputRef.current;
              if (el) setCaretTrigger(composerDom.triggerBeforeCaret(el));
            }}
            onPaste={(e) => {
              // A pasted screenshot is the fastest way anyone attaches
              // anything, and it arrives as a clipboard file rather than text.
              const files = filesFromClipboard(e.clipboardData);
              if (files.length > 0) {
                e.preventDefault();
                void attach(files);
                return;
              }
              // Plain text only. Pasted markup would bring styles, and worse,
              // spans that serialize into the message as invisible junk.
              e.preventDefault();
              const text = e.clipboardData.getData("text/plain");
              document.execCommand("insertText", false, text);
            }}
            onKeyDown={(e) => {
              // The banner promises Esc discards the recording, so Esc must
              // mean that before anything else claims the key.
              if (e.key === "Escape" && voice === "recording") {
                e.preventDefault();
                cancelDictation();
                return;
              }
              if (suggestions.length > 0) {
                if (e.key === "ArrowDown") {
                  e.preventDefault();
                  setAcCursor((c) => Math.min(c + 1, suggestions.length - 1));
                  return;
                }
                if (e.key === "ArrowUp") {
                  e.preventDefault();
                  setAcCursor((c) => Math.max(c - 1, 0));
                  return;
                }
                if (e.key === "Enter" || e.key === "Tab") {
                  const picked = suggestions[acCursor];
                  if (picked) {
                    e.preventDefault();
                    applySuggestion(picked);
                    return;
                  }
                }
                if (e.key === "Escape") {
                  e.preventDefault();
                  const el = inputRef.current;
                  if (el) {
                    composerDom.removeTrigger(el);
                    setDraft(composerDom.serialize(el));
                  }
                  setCaretTrigger(null);
                  return;
                }
              }
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submit();
              }
            }}
          />
          {gate.blocked && !running ? (
            <button type="button" className="btn btn--primary" onClick={openModelSetup}>{SET_UP_MODEL}</button>
          ) : (
          <button
            className={`icon-btn${running || draft.trim() ? " icon-btn--filled" : ""}`}
            title={running ? "Stop" : draft.trim() ? "Send" : "Dictate"}
            onClick={() => {
              // While a turn runs, this is a stop button. A user watching a turn
              // that has gone nowhere for two minutes needs a way out that does
              // not involve quitting the app.
              if (running) stopTurn(activeAgentId);
              // Recording: this click ends it and transcribes.
              else if (voice === "recording") void finishDictation();
              else if (draft.trim() || pending.length > 0) submit();
              // Empty composer and idle: this click starts recording.
              else if (voice === "idle") void startDictation();
            }}
          >
            {running ? (
              <Icon name="stop" />
            ) : voice === "transcribing" ? (
              <Spinner />
            ) : voice === "recording" ? (
              // A square, not a microphone: mid-recording the button's job is
              // to stop, and showing a mic there invites a second start.
              <Icon name="stop" />
            ) : (
              <Icon name={draft.trim() || pending.length > 0 ? "arrowUp" : "mic"} />
            )}
          </button>
          )}
        </div>
        {model || busy ? (
          <div className="composer__meta">
            {model ? (
              <span className="composer__model" title={`Model this agent runs on: ${model}`}>
                {model}
              </span>
            ) : null}
            {busy ? <span className="composer__status">{busy}…</span> : null}
            {waiting ? (
              <span className="composer__status" title="Sent in order once this turn settles">
                {waiting} queued
              </span>
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}
