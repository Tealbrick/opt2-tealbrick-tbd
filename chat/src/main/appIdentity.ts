import { homedir } from "node:os";
import { join } from "node:path";

/**
 * TBD v2's own identity (C280 C10, C284). Must equal TBDIdentity in
 * native/Sources/TBDModels/TBDAppIdentity.swift (checked by test/app-identity.test.ts).
 * The host passes the real folders (TBD_CHAT_DATA, TBD_AGENT_WORKSPACE); these are the live fallbacks.
 */
export const APP_BUNDLE_ID = "com.tealbrick.desktop";
/** `~/Library/Application Support/<APP_DATA_FOLDER>`. */
export const APP_DATA_FOLDER = APP_BUNDLE_ID;
/** The archived v1 app's folders: reference only, never read or written by TBD v2 or its agent. */
export const ARCHIVED_V1_FOLDERS = ["TBD", "TBD Agent", "Dayflow"] as const;
/** The v1-era development copy's folders ("TBD Dev" before C284). */
export const ARCHIVED_V1_DEV_FOLDERS = ["TBD-dev", "TBD-dev Agent", "Dayflow-dev", "TBD-dev-shots", "Dayflow-dev-shots"] as const;

/**
 * TBD's agent works next to the app's data, never inside it (the data folder stays fully denied to the agent).
 * "-agent", not " Agent": a shell command that names the data folder must not also match the workspace.
 */
export const agentFolder = (dataFolder: string): string => `${dataFolder}-agent`;

/** Every TBD v2 identity's folders (live and TBD Dev): a helper denies the ones that are not its own. */
export function identityFolders(): string[] {
  return [APP_DATA_FOLDER, `${APP_DATA_FOLDER}-dev`, `${APP_DATA_FOLDER}-dev-shots`].flatMap((f) => [f, agentFolder(f)]);
}

export function appSupport(): string {
  return join(homedir(), "Library", "Application Support");
}
