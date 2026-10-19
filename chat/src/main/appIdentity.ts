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

export function appSupport(): string {
  return join(homedir(), "Library", "Application Support");
}
