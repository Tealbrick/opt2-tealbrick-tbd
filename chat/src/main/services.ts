import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { APP_DATA_FOLDER, ARCHIVED_V1_DEV_FOLDERS, ARCHIVED_V1_FOLDERS, agentFolder, appSupport, identityFolders } from "./appIdentity";
import { saveAttachmentIn } from "./attachmentFile";
import { app, nativeCall } from "../tbd/host";
import { decide, realPath, sandboxSettings, type PolicyContext } from "./filePolicy";
import { currentControlPlane } from "./controlPlanes";
import { createPortal, parsePersonSession, type PersonSession, type Portal } from "./portal";
import { createEntitlements, type Entitlements } from "./entitlements";
import { createAgentIdentity, type AgentConnection, type AgentIdentity, type AgentSigner, type Ed25519Jwk } from "./agentIdentity";
import { createDefaultAgent, type DefaultAgent } from "./defaultAgent";
import { askPerson } from "./asks";
import { startSignerSocket } from "./signerSocket";
import { relayLaunch, type RelayLaunch } from "./relayLaunch";
import type { Server } from "node:net";

/**
 * The helper's composition root: one Portal client (person, K3), one agent
 * identity (K4 in the Keychain via the host), one default agent process.
 * Built once per control plane; the person token never leaves `portal`.
 */

function dataDir(): string {
  const dir = app.getPath("userData");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

/**
 * Person session (K3) in the Keychain item `com.tealbrick.desktop.person` (CREDENTIALS §12 name under TBD v2's prefix), one account per
 * Portal origin. Loaded once into memory (`loadPersonSession`, may ask for user presence) and
 * written through to the Keychain by the native host. Never on disk in a file.
 */
let personCache: PersonSession | null = null;
let personReady: Promise<void> | null = null;
/** Load the person session once, on first use (the Keychain may ask for user presence). */
export function ensurePerson(): Promise<void> {
  personReady ??= loadPersonSession();
  return personReady;
}
export async function loadPersonSession(): Promise<void> {
  try {
    const raw = (await nativeCall("personLoad", currentControlPlane().issuer)) as string | null;
    personCache = parsePersonSession(raw);
  } catch { personCache = null; }
}
function personStore() {
  return {
    load: (): PersonSession | null => personCache,
    save(s: PersonSession | null): void {
      personCache = s;
      const origin = currentControlPlane().issuer;
      void (s ? nativeCall("personSave", origin, JSON.stringify(s)) : nativeCall("personClear", origin))
        .catch((e) => console.error(`[person] keychain write failed: ${e instanceof Error ? e.message : String(e)}`));
    },
  };
}

/** The approved connection record: ids and URLs only, no secret. */
function connectionStore() {
  const file = () => join(dataDir(), "agent-connection.json");
  return {
    load(): AgentConnection | null {
      try { return existsSync(file()) ? (JSON.parse(readFileSync(file(), "utf8")) as AgentConnection) : null; } catch { return null; }
    },
    save(c: AgentConnection | null): void {
      if (!c) rmSync(file(), { force: true });
      else writeFileSync(file(), JSON.stringify(c, null, 2), { mode: 0o600 });
    },
  };
}

/** K4 lives in the Keychain; the native host signs. */
export const keychainSigner: AgentSigner = {
  create: (label) => nativeCall("agentKeyCreate", label) as Promise<Ed25519Jwk>,
  publicJwk: (label) => nativeCall("agentKeyPublic", label) as Promise<Ed25519Jwk>,
  sign: (label, input) => nativeCall("agentKeySign", label, input) as Promise<string>,
  rename: async (from, to) => { await nativeCall("agentKeyRename", from, to); },
  remove: async (label) => { await nativeCall("agentKeyDelete", label); },
};

/** The agent's own working folder (SEC-04): TBD-owned, outside TBD's data, created 0700. */
export function agentWorkspace(): string {
  // TBD_AGENT_WORKSPACE is set only by the DEBUG dev host (TBD Dev); the live app never sets it.
  // The host sets TBD_AGENT_WORKSPACE (<app data> Agent/Workspace, next to the data; C284); the fallback is the live one.
  const dir = process.env.TBD_AGENT_WORKSPACE || join(appSupport(), agentFolder(APP_DATA_FOLDER), "Workspace");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return realPath(dir);
}

/** Attached files the model cannot read inline go to the agent's own working folder (attachmentFile.ts). */
export function saveAttachment(file: { name: string; bytes: Uint8Array }): string {
  return saveAttachmentIn(join(agentWorkspace(), "Attachments"), file);
}

/** Folders the person allowed the agent to read (managed in TBD's agent settings). */
function foldersFile(): string { return join(dataDir(), "agent-folders.json"); }
export function agentFolders(): string[] {
  try { const v = JSON.parse(readFileSync(foldersFile(), "utf8")); return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []; } catch { return []; }
}
function saveFolders(list: string[]): void {
  writeFileSync(foldersFile(), JSON.stringify([...new Set(list)].sort(), null, 2), { mode: 0o600 });
}
export function policyContext(): PolicyContext {
  const home = realPath(homedir());
  // TBD's own data = the parent of TBD_CHAT_DATA (<app data>/Chat). Always denied too (C284): the archived v1 folders,
  // the other TBD v2 identity's folders (live vs TBD Dev) and the signer socket's folder.
  const data = process.env.TBD_CHAT_DATA ? dirname(process.env.TBD_CHAT_DATA) : join(appSupport(), APP_DATA_FOLDER);
  const own = new Set([basename(data), agentFolder(basename(data))]);
  const others = [...ARCHIVED_V1_FOLDERS, ...ARCHIVED_V1_DEV_FOLDERS, ...identityFolders().filter((f) => !own.has(f))];
  return {
    home,
    workspace: agentWorkspace(),
    allowed: agentFolders().map((f) => realPath(f)),
    tbdData: realPath(data),
    alwaysDenied: [...others.map((f) => realPath(join(appSupport(), f))), realPath(signerSocketDir())],
  };
}
/** Grant a folder; refuses the home folder itself, the root, and protected locations. */
export function addAgentFolder(path: string): string[] {
  const ctx = policyContext();
  const p = realPath(resolve(path));
  if (p === ctx.home || p === "/" || !p.startsWith("/")) throw new Error("Choose a specific folder, not your whole home folder.");
  const verdict = decide("Read", { file_path: join(p, "x") }, { ...ctx, allowed: [p] });
  if (verdict.kind === "deny") throw new Error(verdict.reason);
  saveFolders([...agentFolders(), p]);
  services?.agent.stop(); // the shell sandbox picks up the new list on the next turn
  return agentFolders();
}
export function removeAgentFolder(path: string): string[] {
  saveFolders(agentFolders().filter((f) => f !== path));
  services?.agent.stop();
  return agentFolders();
}

/** One tool call: policy first, the person only when needed (SEC-04). */
async function permission(req: { tool: string; detail: string; input: Record<string, unknown> }): Promise<{ allow: boolean; message?: string }> {
  const ctx = policyContext();
  const verdict = decide(req.tool, req.input, ctx);
  if (verdict.kind === "allow") return { allow: true };
  if (verdict.kind === "deny") return { allow: false, message: verdict.reason };
  const answer = await askPerson({ id: `ask-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, agent: "TBD's agent", action: "run-command", label: req.tool, detail: req.detail, folder: verdict.folder });
  if (answer.allow && answer.remember && verdict.folder) {
    try { addAgentFolder(verdict.folder); } catch { /* refused folder: still allowed once */ }
  }
  return answer.allow ? { allow: true } : { allow: false, message: "The person declined this action." };
}

export function machineLabel(): string {
  const host = hostname().replace(/\.local$/, "").slice(0, 40);
  return `TBD on ${host || "this Mac"}`;
}

/**
 * The relay launch for TBD's agent (K4 via the signer socket, started once). Used by the default
 * agent and by Listening's "Save to Knowledge" (knowledgeSave.ts): the same identity, the same path.
 */
export async function agentRelay(c: AgentConnection): Promise<RelayLaunch> {
  // K4 handle for the relay: signs agent assertions only (signerSocket.ts).
  const socketPath = signerSocketPath();
  if (!signerServer) signerServer = await startSignerSocket(socketPath, () => getServices().agentIdentity.connection(), keychainSigner);
  return relayLaunch(c, { node: process.execPath, entry: join(resourcesDir(), "relay.mjs"), socketPath, home: process.env.HOME ?? "" });
}

/**
 * The K4 signer socket lives in a short private folder under the per-user TMPDIR: a Unix socket path must fit in
 * 104 bytes, and <Application Support>/com.tealbrick.desktop/Chat/profiles/plane-…/agent-signer.sock is ~116.
 * One folder per data folder (hash), mode 0700; the agent's file policy denies it.
 */
export function signerSocketDir(): string {
  const id = createHash("sha256").update(dataDir()).digest("hex").slice(0, 12);
  return join(tmpdir(), `tbd-${id}`);
}
export function signerSocketPath(): string {
  const dir = signerSocketDir();
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Never use a folder someone else made (TMPDIR can fall back to the shared /tmp): ours, a real folder, private.
  const st = lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink() || (typeof process.getuid === "function" && st.uid !== process.getuid())) {
    throw new Error(`The signer socket folder is not TBD's own: ${dir}`);
  }
  chmodSync(dir, 0o700);
  const path = join(dir, "signer.sock");
  if (Buffer.byteLength(path) > 103) throw new Error(`The signer socket path is too long for macOS (${Buffer.byteLength(path)} bytes): ${path}`);
  return path;
}

function resourcesDir(): string { return process.env.TBD_RESOURCES ?? join(process.execPath, ".."); }

export interface Services {
  portal: Portal;
  entitlements: Entitlements;
  agentIdentity: AgentIdentity;
  agent: DefaultAgent;
}

let services: Services | null = null;
let signerServer: Server | null = null;

export function getServices(): Services {
  if (services) return services;
  const origin = currentControlPlane().issuer;
  const portal = createPortal({ origin, store: personStore(), machineLabel: machineLabel() });
  const agentIdentity = createAgentIdentity({
    origin,
    machineLabel: machineLabel(),
    signer: keychainSigner,
    store: connectionStore(),
    // C26: until DeviceAgentTokenResult carries bridge_id, read it with the person session.
    bridgeIdFor: async (ws) => {
      const list = await portal.workspaces();
      const id = list.items.find((w) => w.id === ws)?.bridge.id;
      if (!id) throw new Error("The workspace has no bridge yet. Set up the workspace infrastructure in Portal first.");
      return id;
    },
  });
  const resources = resourcesDir();
  const agent = createDefaultAgent({
    node: process.execPath,
    entry: join(resources, "agent.mjs"),
    model: async () => (await nativeCall("agentModel")) as { model: string; baseUrl?: string; apiKey: string },
    config: async () => {
      const c = agentIdentity.connection();
      const relay = c ? await agentRelay(c) : undefined;
      return {
        cwd: agentWorkspace(),
        stateDir: join(dataDir(), "agent"),
        claudeExecutable: join(resources, "claude"),
        companionCli: process.env.TBD_COMPANION_CLI,
        listeningCli: process.env.TBD_LISTENING_CLI,
        relay,
        sandbox: sandboxSettings(policyContext()),
        systemAppend: `Your working folder is ${agentWorkspace()}. Other folders need the person's consent; some locations (keys, credentials, browser data) are never available.`,
      };
    },
    permission,
  });
  // C282: what the workspace paid for; TBD_SHAPE_LOG=1 logs the reads' field names and counts only (no values).
  const entitlements = createEntitlements({
    licences: () => portal.licences(),
    instances: (ws) => portal.instances(ws),
    log: process.env.TBD_SHAPE_LOG === "1" ? (line) => process.stderr.write(`[helper:shape] ${line}\n`) : undefined,
  });
  services = { portal, agentIdentity, agent, entitlements };
  return services;
}

/** Workspace or account change: stop the agent, drop cached clients. */
export function resetServices(): void {
  personReady = null;
  personCache = null;
  services?.agent.stop();
  services = null;
  signerServer?.close();
  signerServer = null;
}
