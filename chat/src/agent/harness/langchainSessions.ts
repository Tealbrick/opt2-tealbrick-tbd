import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mapChatMessagesToStoredMessages, mapStoredMessagesToChatMessages, type BaseMessage, type StoredMessage } from "@langchain/core/messages";

/**
 * Sessions of the LangChain agent (WP-HARNESS L1). The session id is the LangGraph thread id. The message history
 * is one JSON file per session under `<stateDir>/langchain/sessions/<id>.json` (files 0600, folders 0700).
 * No native module (no SQLite): the agent is bundled into a signed app.
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

export function fileSessionStore(stateDir: string): SessionStore {
  const dir = sessionsDir(stateDir);
  const fileOf = (id: string): string => {
    if (!isSessionId(id)) throw new Error("This session id is not valid.");
    return join(dir, `${id}.json`);
  };
  return {
    load(id) {
      const file = fileOf(id);
      if (!existsSync(file)) return null;
      const saved = JSON.parse(readFileSync(file, "utf8")) as Partial<SessionFile>;
      if (saved.version !== 1 || !Array.isArray(saved.messages)) throw new Error("This session file is not readable.");
      return mapStoredMessagesToChatMessages(saved.messages);
    },
    save(id, messages) {
      const file = fileOf(id);
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      // mkdir applies the mode only to new folders, and the umask can narrow it; make the chain private.
      chmodSync(join(stateDir, "langchain"), 0o700);
      chmodSync(dir, 0o700);
      const body: SessionFile = { version: 1, id, updatedAt: new Date().toISOString(), messages: mapChatMessagesToStoredMessages(messages) };
      // Write beside the target, then rename: a stop in the middle never leaves a half-written history.
      const temp = `${file}.${process.pid}.tmp`;
      writeFileSync(temp, JSON.stringify(body), { mode: 0o600 });
      chmodSync(temp, 0o600);
      renameSync(temp, file);
    },
  };
}
