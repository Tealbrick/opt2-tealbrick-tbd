import type { AgentQuestion } from "../agent/protocol";
import type { ContentBlock } from "../shared/message";
import type { DefaultAgent } from "./defaultAgent";

/**
 * Turns and question cards between the Chat window and TBD's agent (v1 parity: input.requested).
 *
 * v1's agent parked a turn on a question: the send came back with `askedQuestion: true`, the window
 * showed a card, and the answer went out as a new send carrying `inputResponses`; that send then
 * received the rest of the turn. The default agent asks through the SDK's AskUserQuestion tool,
 * which waits inside the turn, so this router keeps the turn running and hands its stream to
 * whichever send is current: the original one until a question, the answering one after it.
 *
 * One card per question (the tool asks 1–4 at a time); the agent gets the answers once every
 * card of that call is answered. A question nobody answers is refused after `questionTimeoutMs`
 * (L23: nothing waits forever); Stop refuses it at once.
 */

export interface SendResult {
  reply: string;
  sessionId?: string;
  streamIndex: number;
  askedQuestion: boolean;
}

export interface QuestionCard {
  requestId: string;
  prompt: string;
  options: { id: string; label: string; description?: string }[];
  allowFreeform: boolean;
}

export interface InputResponse {
  requestId: string;
  optionId?: string;
  text?: string;
}

type Emit = (streamId: string, channel: string, payload: Record<string, unknown>) => void;

interface Waiter {
  resolve(result: SendResult): void;
  reject(error: Error): void;
}

interface Run {
  streamId: string;
  sessionId: string;
  waiter: Waiter | null;
}

interface Group {
  reqId: string;
  run: Run;
  questions: AgentQuestion[];
  answers: Map<number, string>;
  timer: ReturnType<typeof setTimeout>;
}

export interface TurnRouterDeps {
  agent(): Pick<DefaultAgent, "sendTurn" | "answer">;
  emit: Emit;
  /** The "Open approval" link for a held Connect call, or null when none can be built (not connected). */
  holdUrl?(held: { tool: string; holdId: string; expiresAt: string }): string | null;
  /** Default: one hour. */
  questionTimeoutMs?: number;
}

/** The cards for one AskUserQuestion call; `requestId` = `<reqId>.<question index>`, option ids = indexes. */
export function questionCards(reqId: string, questions: AgentQuestion[]): QuestionCard[] {
  return questions.map((q, i) => ({
    requestId: `${reqId}.${i}`,
    prompt: q.question,
    options: (q.options ?? []).map((o, j) => ({ id: String(j), label: o.label, ...(o.description ? { description: o.description } : {}) })),
    allowFreeform: true,
  }));
}

export function createTurnRouter(deps: TurnRouterDeps) {
  const timeoutMs = deps.questionTimeoutMs ?? 60 * 60 * 1000;
  const groups = new Map<string, Group>();

  function waitFor(run: Run): Promise<SendResult> {
    return new Promise<SendResult>((resolve, reject) => { run.waiter = { resolve, reject }; });
  }

  function settle(run: Run, result: SendResult): void {
    const w = run.waiter;
    run.waiter = null;
    w?.resolve(result);
  }

  function close(group: Group, answers: Record<string, string> | null): void {
    clearTimeout(group.timer);
    groups.delete(group.reqId);
    deps.agent().answer(group.reqId, answers);
  }

  return {
    /** A new message from the person. Resolves at the end of the turn, or at its first question. */
    start(input: { text: string; content?: ContentBlock[]; sessionId?: string; streamId: string }): Promise<SendResult> {
      const run: Run = { streamId: input.streamId, sessionId: input.sessionId ?? "", waiter: null };
      const first = waitFor(run);
      const emit = (channel: string, payload: Record<string, unknown>) => deps.emit(run.streamId, channel, payload);
      deps.agent().sendTurn({
        text: input.text,
        content: input.content,
        sessionId: input.sessionId,
        onDelta: (text) => emit("studio:delta", { text }),
        onReset: () => emit("studio:reset", {}),
        onActivity: (label) => emit("studio:activity", { label }),
        onHeld: (held) => emit("studio:held", { label: "Waiting for owner approval", holdId: held.holdId, url: deps.holdUrl?.(held) ?? null }),
        onTurn: (turn) => { run.sessionId = turn.sessionId; emit("studio:turn", turn); },
        onQuestion: ({ reqId, questions }) => {
          const group: Group = {
            reqId, run, questions, answers: new Map(),
            timer: setTimeout(() => { if (groups.get(reqId) === group) close(group, null); }, timeoutMs),
          };
          groups.set(reqId, group);
          for (const request of questionCards(reqId, questions)) emit("studio:question", { request });
          settle(run, { reply: "", sessionId: run.sessionId, streamIndex: 0, askedQuestion: true });
        },
      }).then(
        (result) => {
          run.sessionId = result.sessionId;
          for (const g of groups.values()) if (g.run === run) { clearTimeout(g.timer); groups.delete(g.reqId); }
          settle(run, { reply: result.reply, sessionId: result.sessionId, streamIndex: 0, askedQuestion: false });
        },
        (error: unknown) => {
          for (const g of groups.values()) if (g.run === run) { clearTimeout(g.timer); groups.delete(g.reqId); }
          const w = run.waiter;
          run.waiter = null;
          w?.reject(error instanceof Error ? error : new Error(String(error)));
        },
      );
      return first;
    },

    /**
     * The person answered one or more cards. When that completes the agent's question, this send
     * takes over the turn's stream and resolves at its end (or next question); otherwise it
     * resolves at once with `askedQuestion: true` (more cards still open).
     */
    answer(input: { streamId: string; responses: InputResponse[] }): Promise<SendResult> {
      let completed: Group | null = null;
      for (const r of input.responses) {
        const [reqId, index] = splitRequestId(r.requestId);
        const group = reqId ? groups.get(reqId) : undefined;
        const question = group?.questions[index];
        if (!group || !question) throw new Error("This question is no longer open.");
        const label = r.text?.trim() || question.options?.[Number(r.optionId)]?.label || "";
        if (!label) throw new Error("Choose an answer first.");
        group.answers.set(index, label);
        if (group.answers.size === group.questions.length) completed = group;
      }
      if (!completed) return Promise.resolve({ reply: "", streamIndex: 0, askedQuestion: true });
      const group = completed;
      const answers: Record<string, string> = {};
      group.questions.forEach((q, i) => { answers[q.question] = group.answers.get(i) ?? ""; });
      group.run.streamId = input.streamId;
      const next = waitFor(group.run);
      close(group, answers);
      return next;
    },

    /** Open question ids (for tests and diagnostics). */
    openQuestions: (): string[] => [...groups.keys()],
  };
}

function splitRequestId(requestId: string): [string, number] {
  const dot = requestId.lastIndexOf(".");
  if (dot <= 0) return ["", -1];
  const index = Number(requestId.slice(dot + 1));
  return [requestId.slice(0, dot), Number.isInteger(index) ? index : -1];
}

export type TurnRouter = ReturnType<typeof createTurnRouter>;
