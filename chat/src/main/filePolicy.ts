import { existsSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";

/**
 * Where TBD's default agent may touch this Mac (SEC-04).
 *
 * - The agent works in a TBD-owned folder (its workspace). Reads there are free.
 * - Any other folder needs the person's consent: once (the card) or always
 *   (a folder on the allow-list the person manages in TBD).
 * - Secrets are refused even inside allowed folders: SSH/cloud/GPG keys,
 *   keychains, browser profiles, .env files, private keys, and TBD's own data
 *   (sessions, sockets, Companion and Listening stores — the agent reads those
 *   only through its tools).
 * - Writes and edits always ask; shell commands always ask and run in the
 *   OS sandbox (sandboxSettings).
 */

export type Decision = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "ask"; folder: string | null };

export interface PolicyContext {
  home: string;
  workspace: string;
  /** Folders the person granted (absolute, real paths). */
  allowed: readonly string[];
  /** TBD's own data folder (denied except the workspace inside it). */
  tbdData: string;
  /** The archived v1 TBD folders (C284: reference only): always denied, no exception. */
  archived?: readonly string[];
}

const SECRET_DIRS = [
  ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure", ".config/gh", ".config/gcloud", ".config/op",
  ".password-store", ".local/share/keyrings",
  "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages",
  "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox", "Library/Safari",
  "Library/Application Support/1Password", "Library/Group Containers",
];
const SECRET_FILES = [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".bash_history", ".zsh_history", ".claude.json"];
const SECRET_NAMES = [/^\.env(\..+)?$/i, /\.(pem|key|p12|pfx|keychain|keychain-db|kdbx|ovpn)$/i, /^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$/i, /^credentials(\.json)?$/i, /^secrets?\.(json|ya?ml|toml)$/i];

export function expandHome(p: string, home: string): string {
  return p === "~" ? home : p.startsWith("~/") ? join(home, p.slice(2)) : p;
}

/** Resolve symlinks of the longest existing prefix, so a link cannot smuggle a secret path in. */
export function realPath(p: string): string {
  let cur = p;
  const rest: string[] = [];
  while (!existsSync(cur)) {
    const parent = dirname(cur);
    if (parent === cur) return p;
    rest.unshift(basename(cur));
    cur = parent;
  }
  try { return join(realpathSync(cur), ...rest); } catch { return p; }
}

export const within = (p: string, root: string): boolean => p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);

export function isSecret(path: string, ctx: PolicyContext): string | null {
  if (within(path, ctx.tbdData) && !within(path, ctx.workspace)) return "TBD's own data";
  for (const a of ctx.archived ?? []) if (within(path, a)) return "the archived v1 TBD data";
  for (const d of SECRET_DIRS) if (within(path, join(ctx.home, d))) return d;
  for (const f of SECRET_FILES) if (path === join(ctx.home, f)) return f;
  for (const part of path.split(sep)) for (const re of SECRET_NAMES) if (re.test(part)) return part;
  return null;
}

/** Absolute, real target paths a tool call touches (empty = none we can name). */
export function targetPaths(tool: string, input: Record<string, unknown>, ctx: PolicyContext): string[] {
  const s = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const abs = (p: string) => realPath(resolve(ctx.workspace, expandHome(p, ctx.home)));
  const out: string[] = [];
  if (tool === "Read" || tool === "Write" || tool === "Edit" || tool === "NotebookEdit") {
    const p = s(input.file_path) ?? s(input.notebook_path); if (p) out.push(abs(p));
  } else if (tool === "Glob" || tool === "Grep") {
    out.push(abs(s(input.path) ?? "."));
    const pattern = s(input.pattern);
    if (tool === "Glob" && pattern && (isAbsolute(pattern) || pattern.startsWith("~"))) {
      const fixed = expandHome(pattern, ctx.home).split(sep).filter((seg) => !/[*?[{]/.test(seg)).join(sep);
      out.push(abs(fixed || sep));
    }
  }
  return out;
}

/** Paths a shell command names (best effort, for the deny list only). */
export function commandMentionsSecret(command: string, ctx: PolicyContext): string | null {
  // Whole protected paths, also when they contain spaces (quoted or escaped).
  const flat = command.replace(/\\ /g, " ");
  for (const d of [ctx.tbdData, ...(ctx.archived ?? []), ...SECRET_DIRS.map((x) => join(ctx.home, x)), ...SECRET_FILES.map((x) => join(ctx.home, x))]) {
    if (flat.includes(d) || flat.includes(d.replace(ctx.home, "~")) || flat.includes(d.replace(ctx.home, "$HOME"))) return d.replace(ctx.home, "~");
  }
  for (const token of command.split(/[\s'"=;|&<>()]+/)) {
    if (!token || !(token.startsWith("/") || token.startsWith("~") || token.includes("/") || token.startsWith("."))) continue;
    const hit = isSecret(realPath(resolve(ctx.workspace, expandHome(token, ctx.home))), ctx);
    if (hit) return hit;
  }
  return null;
}

export function decide(tool: string, input: Record<string, unknown>, ctx: PolicyContext): Decision {
  if (tool === "Bash") {
    const hit = commandMentionsSecret(String(input.command ?? ""), ctx);
    return hit ? { kind: "deny", reason: `The command touches a protected location (${hit}).` } : { kind: "ask", folder: null };
  }
  if (tool === "WebFetch" || tool === "WebSearch") return { kind: "ask", folder: null };
  const paths = targetPaths(tool, input, ctx);
  if (paths.length === 0) return { kind: "ask", folder: null };
  for (const p of paths) {
    const hit = isSecret(p, ctx);
    if (hit) return { kind: "deny", reason: `TBD does not let its agent open protected files (${hit}).` };
  }
  const reading = tool === "Read" || tool === "Glob" || tool === "Grep";
  const inside = paths.every((p) => within(p, ctx.workspace) || ctx.allowed.some((a) => within(p, a)));
  if (reading && inside) return { kind: "allow" };
  // Writes always ask; reads outside ask with the folder that "always allow" would grant.
  const first = paths[0];
  const folder = tool === "Glob" || tool === "Grep" ? first : dirname(first);
  return { kind: "ask", folder: reading && folder !== ctx.home && folder !== sep ? folder : null };
}

/** OS sandbox for the shell tool: writes only to granted folders, never read secrets, no unsandboxed fallback. */
export function sandboxSettings(ctx: PolicyContext): Record<string, unknown> {
  return {
    enabled: true,
    failIfUnavailable: true,
    autoAllowBashIfSandboxed: false,
    allowUnsandboxedCommands: false,
    filesystem: {
      allowWrite: [ctx.workspace, ...ctx.allowed],
      denyRead: [...SECRET_DIRS.map((d) => join(ctx.home, d)), ...SECRET_FILES.map((f) => join(ctx.home, f)), ctx.tbdData, ...(ctx.archived ?? [])],
    },
  };
}
