import type { LocalAsk } from "../shared/ipc";

/**
 * Ask the person, on this Mac, before an agent does something here.
 *
 * The one consent channel of TBD Chat: the main process sends the card to the
 * renderer (`studio:local-ask`), the person answers (`studio:localAnswer`), and
 * the caller gets the decision. No answer within two minutes is a refusal; no
 * window to ask in is a refusal. Standing answers ("always", "never") are the
 * caller's to store, scoped per agent (v2: the default agent's canUseTool).
 */

type Sender = { send(channel: string, payload: unknown): void; isDestroyed(): boolean };
type Decision = { allow: boolean; remember: boolean };

const TIMEOUT_MS = 120_000;
const pending = new Map<string, { resolve(decision: Decision): void; timer: ReturnType<typeof setTimeout> }>();
let sender: Sender | null = null;

export function setAskWindow(contents: Sender | null): void {
  sender = contents;
}

/**
 * Show the card and wait for the person. `signal` closes the card as denied when it aborts (the agent process that asked was
 * stopped or replaced: nobody is waiting for the answer any more, and an open card must not look answerable).
 */
export function askPerson(ask: LocalAsk, signal?: AbortSignal): Promise<Decision> {
  if (signal?.aborted || !sender || sender.isDestroyed()) return Promise.resolve({ allow: false, remember: false });
  sender.send("studio:local-ask", ask);
  return new Promise<Decision>((resolve) => {
    const close = (): void => {
      const entry = pending.get(ask.id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(ask.id);
      resolve({ allow: false, remember: false });
      if (sender && !sender.isDestroyed()) sender.send("studio:local-done", { id: ask.id });
    };
    const timer = setTimeout(close, TIMEOUT_MS);
    pending.set(ask.id, { resolve: (d) => { signal?.removeEventListener("abort", close); resolve(d); }, timer });
    signal?.addEventListener("abort", close, { once: true });
  });
}

export function answerAsk(id: string, allow: boolean, remember: boolean): void {
  const entry = pending.get(id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(id);
  entry.resolve({ allow, remember });
}

/** Refuse everything still waiting (window gone, workspace switched, shutdown). */
export function refuseAll(): void {
  for (const [id, entry] of pending) {
    clearTimeout(entry.timer);
    entry.resolve({ allow: false, remember: false });
    pending.delete(id);
  }
}
