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
  /**
   * Always denied, no exception (C284): the archived v1 TBD folders, the other identity's folders (live vs TBD Dev)
   * and the signer socket's folder.
   */
  alwaysDenied?: readonly string[];
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

/** macOS file systems are case-insensitive by default: "…/tbd" is "…/TBD". Compare folded there. */
const fold = (p: string): string => (process.platform === "darwin" ? p.toLowerCase() : p);
export const within = (p: string, root: string): boolean => {
  const a = fold(p), r = fold(root);
  return a === r || a.startsWith(r.endsWith(sep) ? r : r + sep);
};

export function isSecret(path: string, ctx: PolicyContext): string | null {
  if (within(path, ctx.tbdData) && !within(path, ctx.workspace)) return "TBD's own data";
  for (const a of ctx.alwaysDenied ?? []) if (within(path, a)) return "data TBD's agent must not use";
  for (const d of SECRET_DIRS) if (within(path, join(ctx.home, d))) return d;
  for (const f of SECRET_FILES) if (fold(path) === fold(join(ctx.home, f))) return f;
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

/**
 * True when `text` names `path`, something inside it, or a glob over it. Only a following NAME character means a
 * different folder: ".../com.tealbrick.desktop" does not match ".../com.tealbrick.desktop-agent/...", but
 * ".../TBD/", ".../TBD*", ".../TB[D]", ".../TBD{,}" and a quoted ".../TBD" all match.
 */
function mentionsPath(text: string, path: string): boolean {
  for (let i = text.indexOf(path); i >= 0; i = text.indexOf(path, i + 1)) {
    const next = text[i + path.length];
    if (next === undefined || !/[A-Za-z0-9_.-]/.test(next)) return true;
  }
  return false;
}

/**
 * True when `text` has a glob in the last segment that can name `path`: ".../TB[D]/x", ".../T*", ".../TB?" reach
 * ".../TBD" without spelling it. Only the segment right after the protected folder's parent is checked.
 */
function globReaches(text: string, path: string): boolean {
  const parent = path.slice(0, path.lastIndexOf("/") + 1);
  const name = path.slice(parent.length);
  if (!parent || !name) return false;
  for (let i = text.indexOf(parent); i >= 0; i = text.indexOf(parent, i + 1)) {
    const segment = /^[^/'"`;|&()<>\s]*/.exec(text.slice(i + parent.length))?.[0] ?? "";
    if (!/[*?[{]/.test(segment)) continue;
    try {
      if (globToRegExp(segment).test(name)) return true;
    } catch {
      return true;   // an odd glob next to a protected folder: deny rather than guess
    }
  }
  return false;
}

/** A shell glob segment as an anchored RegExp: * ? [..] [!..] {a,b}. */
function globToRegExp(glob: string): RegExp {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i]!;
    if (ch === "*") re += "[^/]*";
    else if (ch === "?") re += "[^/]";
    else if (ch === "[") {
      const end = glob.indexOf("]", i + 1);
      if (end < 0) { re += "\\["; continue; }
      const body = glob.slice(i + 1, end).replace(/^!/, "^").replace(/\\/g, "\\\\");
      re += `[${body}]`;
      i = end;
    } else if (ch === "{") {
      const end = glob.indexOf("}", i + 1);
      if (end < 0) { re += "\\{"; continue; }
      re += `(?:${glob.slice(i + 1, end).split(",").map((alt) => alt.replace(/[.+^$()|\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]")).join("|")})`;
      i = end;
    } else re += ch.replace(/[.+^$()|\\\]}]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

/** Paths a shell command names (best effort, for the deny list only). */
export function commandMentionsSecret(command: string, ctx: PolicyContext): string | null {
  // Whole protected paths, also when they contain spaces (quoted or escaped).
  const flat = fold(command.replace(/\\ /g, " "));
  for (const d of [ctx.tbdData, ...(ctx.alwaysDenied ?? []), ...SECRET_DIRS.map((x) => join(ctx.home, x)), ...SECRET_FILES.map((x) => join(ctx.home, x))]) {
    const forms = [d, d.replace(ctx.home, "~"), d.replace(ctx.home, "$HOME"), d.replace(ctx.home, "${HOME}")];
    if (forms.some((form) => mentionsPath(flat, fold(form)) || globReaches(flat, fold(form)))) return d.replace(ctx.home, "~");
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
      denyRead: [...SECRET_DIRS.map((d) => join(ctx.home, d)), ...SECRET_FILES.map((f) => join(ctx.home, f)), ctx.tbdData, ...(ctx.alwaysDenied ?? [])],
    },
  };
}
