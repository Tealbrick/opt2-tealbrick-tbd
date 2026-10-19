import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HumanMessage, mapChatMessagesToStoredMessages, mapStoredMessagesToChatMessages, type BaseMessage, type StoredMessage } from "@langchain/core/messages";

/**
 * Sessions of the LangChain agent (WP-HARNESS L1). The session id is the LangGraph thread id. The message history
 * is one JSON file per session under `<stateDir>/langchain/sessions/<id>.json` (files 0600, folders 0700).
 * No native module (no SQLite): the agent is bundled into a signed app.
 *
 * The history is kept small (review #4): attachments of earlier turns become a text placeholder, and the oldest
 * exchanges are dropped when the saved size passes a budget. The last turn is always kept whole (the system prompt
 * is not part of the history; it is added on every model call).
 */

export interface SessionStore {
  /** The saved history of a session; `null` when there is none. */
  load(id: string): BaseMessage[] | null;
  /** Save the whole history of a session. */
  save(id: string, messages: BaseMessage[]): void;
}

interface SessionFile {
  version: 1;
  id: string;
  updatedAt: string;
  messages: StoredMessage[];
}

/** Ids we create are UUIDs; anything with a path part is refused (the id comes from the helper, not from a person). */
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;

export function isSessionId(id: string): boolean {
  return SESSION_ID.test(id);
}

export function sessionsDir(stateDir: string): string {
  return join(stateDir, "langchain", "sessions");
}

/** Saved history size budget in characters of JSON (about 100k tokens). */
export const HISTORY_BUDGET_CHARS = 400_000;

function omitted(block: unknown): unknown {
  const b = block as { type?: string; source?: { type?: string; media_type?: string }; title?: string; image_url?: { url?: string } | string };
  if (b?.type === "image" && b.source?.type === "base64") return { type: "text", text: `[attachment omitted: ${b.source.media_type ?? "image"}]` };
  if (b?.type === "document" && b.source?.type === "base64") return { type: "text", text: `[attachment omitted: ${b.title ? `${b.title}, ` : ""}${b.source.media_type ?? "document"}]` };
  const url = typeof b?.image_url === "string" ? b.image_url : b?.image_url?.url;
  if (b?.type === "image_url" && typeof url === "string" && url.startsWith("data:")) return { type: "text", text: `[attachment omitted: ${url.slice(5, url.indexOf(";")) || "image"}]` };
  return block;
}

/** The message with its binary attachments (base64 images and PDFs) replaced by a text placeholder. */
function withoutAttachments(message: BaseMessage): BaseMessage {
  if (message.getType() !== "human" || !Array.isArray(message.content)) return message;
  const content = message.content.map(omitted);
  if (content.every((block, i) => block === (message.content as unknown[])[i])) return message;
  return new HumanMessage({ content: content as HumanMessage["content"], id: message.id, additional_kwargs: message.additional_kwargs });
}

const sizeOf = (messages: BaseMessage[]): number => mapChatMessagesToStoredMessages(messages).reduce((n, m) => n + JSON.stringify(m).length, 0);

/**
 * What is saved of a history: attachments of earlier turns become a placeholder, then the oldest exchanges go until
 * the size is within `budget`. An exchange runs from a user message to the next one, so tool calls and their results
 * are never separated. The last turn stays whole even when it alone is over the budget.
 */
export function compactHistory(messages: BaseMessage[], budget = HISTORY_BUDGET_CHARS): BaseMessage[] {
  const starts = messages.flatMap((m, i) => (m.getType() === "human" ? [i] : []));
  const lastStart = starts.at(-1) ?? 0;
  let out = messages.map((m, i) => (i < lastStart ? withoutAttachments(m) : m));
  let size = sizeOf(out);
  let dropFrom = 0;
  for (const next of starts.slice(1)) {
    if (size <= budget || next > lastStart) break;
    size -= sizeOf(out.slice(dropFrom, next));
    dropFrom = next;
  }
  if (dropFrom > 0) out = out.slice(dropFrom);
  return out;
}

export function fileSessionStore(stateDir: string, log: (note: string) => void = (note) => console.error(`[agent-langchain] ${note}`)): SessionStore {
  const dir = sessionsDir(stateDir);
  const fileOf = (id: string): string => {
    if (!isSessionId(id)) throw new Error("This session id is not valid.");
    return join(dir, `${id}.json`);
  };
  return {
    load(id) {
      const file = fileOf(id);
      if (!existsSync(file)) return null;
      try {
        const saved = JSON.parse(readFileSync(file, "utf8")) as Partial<SessionFile>;
        if (saved.version !== 1 || !Array.isArray(saved.messages)) throw new Error("not a session file");
        return mapStoredMessagesToChatMessages(saved.messages);
      } catch (error) {
        // A damaged history starts a new one under the same id. The damaged file is kept beside it, not deleted.
        const aside = `${file}.damaged-${Date.now()}`;
        try { renameSync(file, aside); } catch { /* the next save replaces it */ }
        log(`session ${id} could not be read (${error instanceof Error ? error.message : String(error)}); starting a new history`);
        return null;
      }
    },
    save(id, messages) {
      const file = fileOf(id);
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      // mkdir applies the mode only to new folders, and the umask can narrow it; make the chain private.
      chmodSync(join(stateDir, "langchain"), 0o700);
      chmodSync(dir, 0o700);
      const body: SessionFile = { version: 1, id, updatedAt: new Date().toISOString(), messages: mapChatMessagesToStoredMessages(compactHistory(messages)) };
      // Write beside the target, then rename: a stop in the middle never leaves a half-written history.
      const temp = `${file}.${process.pid}.tmp`;
      writeFileSync(temp, JSON.stringify(body), { mode: 0o600 });
      chmodSync(temp, 0o600);
      renameSync(temp, file);
    },
  };
}
