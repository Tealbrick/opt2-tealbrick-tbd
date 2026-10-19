import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { LocalCard } from "../shared/ipc";

/**
 * Standing "Always allow" / "Never allow" for TBD's agent's LOCAL actions (C280 C13 local part, V1-PARITY C15/C16): file
 * writes and edits, shell commands and web requests. The same card as dev.16's Connect consent, the same four answers.
 * (The LangChain harness has no local tools: this is the Agent SDK path, decided in the helper, services.ts `permission`.)
 *
 *   Order  secret or protected location (filePolicy.decide, always first) -> stored Never -> stored Always (only where the
 *          call still allows Always) -> the existing policy -> the card.
 *   Keys   write:<real folder of the target>   shell:<exact command, trimmed>   web:<host>   websearch   flow:add
 *          (flow:add = the Companion MCP tool flow_plan_add with mode "save": TBD's agent adds lines to the person's plan on
 *          this Mac. Preview and flow_plan_today write nothing and are free.)
 *   Store  local-consent.json in the helper state folder: Mac-wide (not keyed by workspace), 0600, atomic, corrupt copies kept.
 *
 * Kept free of relative value imports (type imports only) so node tests can load it directly under type stripping; the
 * path helpers of filePolicy.ts come in as `writeScope` and `policy`.
 */

// ---------------------------------------------------------------- the shell classifier

/** Why a command does not get "Always allow" (a plain sentence for the card), or that it may. */
export type ShellVerdict = { always: true } | { always: false; reason: string };

const R_DESTRUCTIVE = "This command can delete, move or change things.";
const R_OPAQUE = "TBD cannot check in full what this command will run.";
const R_WRITES = "This command writes to a file.";
const R_SYSTEM = "This command changes settings of this Mac or runs as an administrator.";
const R_HIDDEN = "This command has characters that the card cannot show.";
const R_LONG = "This command is too long to check.";

/** Command words that delete, move or change things, or raise rights: no "Always allow" when one is any word of the command. */
const DESTRUCTIVE_ANYWHERE = new Set([
  "rm", "rmdir", "mv", "dd", "shred", "unlink", "trash", "srm", "rimraf", "truncate", "chown", "chgrp",
  "kill", "pkill", "killall", "launchctl", "osascript", "sudo", "doas", "diskutil",
]);
const isMkfs = (name: string): boolean => /^(mkfs|newfs)(\..*)?$/.test(name);
/** Commands that write or change files or this Mac when they are the command word. */
const WRITERS = new Set(["tee", "cp", "ln", "install", "rsync", "patch", "ditto", "hdiutil", "tmutil", "pmset", "scutil", "systemsetup", "networksetup", "csrutil", "spctl", "dscl", "sysadminctl", "crontab", "at", "batch", "nvram", "softwareupdate", "security"]);
/** Commands that run text they are given (a shell inside, another machine, a container): no "Always allow". */
const RUNNERS = new Set(["eval", "exec", "source", ".", "xargs", "ssh", "su", "watch", "parallel", "script", "expect", "tmux", "screen", "docker", "podman", "kubectl"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]);
/** Words that run another command; the command after them is looked at as well. */
const WRAPPERS = new Set(["env", "command", "builtin", "nice", "nohup", "time", "caffeinate", "stdbuf", "unbuffer", "noglob", "timeout", "gtimeout", "arch", "ionice", "setsid"]);
/** Shell words that start a group or a clause; the command that follows is looked at. */
const CLAUSE_STARTS = new Set(["!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "time"]);
const HEADER_STARTS = new Set(["for", "case", "select", "function", "coproc"]);
/** An interpreter, and the flags that make it run text from the command line. */
const INTERPRETERS: Readonly<Record<string, RegExp>> = {
  python: /^-[A-Za-z]*c[A-Za-z]*$/, python2: /^-[A-Za-z]*c[A-Za-z]*$/, python3: /^-[A-Za-z]*c[A-Za-z]*$/,
  ruby: /^-[A-Za-z]*e[A-Za-z]*$/i, perl: /^-[A-Za-z]*e[A-Za-z]*$/i, node: /^(-[A-Za-z]*[ep][A-Za-z]*|--eval|--print|--input-type.*)$/, nodejs: /^(-[A-Za-z]*[ep][A-Za-z]*|--eval|--print)$/,
  deno: /^(eval|-e|--eval)$/, bun: /^(-e|--eval|-p|--print)$/, php: /^-[A-Za-z]*r[A-Za-z]*$/, lua: /^-[A-Za-z]*e[A-Za-z]*$/,
};
const AWKS = new Set(["awk", "gawk", "mawk", "nawk"]);
const DANGEROUS_ENV = /^(PATH|IFS|ENV|BASH_ENV|SHELLOPTS|PROMPT_COMMAND|PS4|NODE_OPTIONS|PYTHONSTARTUP|PYTHONPATH|PERL5OPT|PERL5LIB|RUBYOPT|RUBYLIB|GIT_SSH_COMMAND|GIT_ASKPASS|GIT_EXTERNAL_DIFF|GIT_PAGER|PAGER|EDITOR|VISUAL|LD_[A-Z_]+|DYLD_[A-Z_]+)$/;
export const SHELL_COMMAND_MAX = 2000;

interface Word { text: string; expands: boolean; globs: boolean }
interface Segment { words: Word[]; afterPipe: boolean }
interface Parsed { segments: Segment[]; problems: string[] }

/** Bidirectional controls and control characters (the line feed and the tab stay): the card must show what runs. */
function hasHiddenCharacters(text: string): boolean {
  for (const ch of text) {
    const c = ch.codePointAt(0) ?? 0;
    const bidi = (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) || c === 0x200e || c === 0x200f || c === 0x061c;
    const control = (c < 0x20 && c !== 0x0a && c !== 0x09) || (c >= 0x7f && c <= 0x9f);
    if (bidi || control) return true;
  }
  return false;
}

/**
 * A small reader of shell text, not a shell. It splits the command into words and simple commands (`;` `&&` `||` `|` `&`,
 * lines, groups), understands quotes and backslashes, and records what it cannot judge: command substitution, process
 * substitution, here-documents, redirection to a file, brace expansion, ANSI-C quotes, a quote that never ends.
 * Anything it cannot judge becomes a "problem": no "Always allow".
 */
function parseShell(command: string): Parsed {
  const problems: string[] = [];
  const segments: Segment[] = [];
  let seg: Segment = { words: [], afterPipe: false };
  let cur: Word | null = null;
  let skipNextWord = false;
  const flush = (): void => {
    if (!cur) return;
    if (skipNextWord) skipNextWord = false; else seg.words.push(cur);
    cur = null;
  };
  const end = (pipe: boolean): void => {
    flush();
    if (seg.words.length > 0) { segments.push(seg); seg = { words: [], afterPipe: pipe }; } else if (pipe) seg.afterPipe = true;
  };
  const word = (): Word => (cur ??= { text: "", expands: false, globs: false });
  const s = command;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === " " || ch === "\t" || ch === "\r") { flush(); continue; }
    if (ch === "\n") { end(false); continue; }
    if (ch === "\\") {
      const next = s[i + 1];
      if (next === undefined) continue;
      i++;
      if (next !== "\n") word().text += next;
      continue;
    }
    if (ch === "'") {
      const close = s.indexOf("'", i + 1);
      if (close < 0) { problems.push(R_OPAQUE); break; }
      word().text += s.slice(i + 1, close);
      i = close;
      continue;
    }
    if (ch === '"') {
      const w = word();
      let j = i + 1;
      let closed = false;
      for (; j < s.length; j++) {
        const c = s[j];
        if (c === "\\") {
          const n = s[j + 1];
          if (n !== undefined && "$`\"\\\n".includes(n)) { if (n !== "\n") w.text += n; j++; } else w.text += c;
          continue;
        }
        if (c === '"') { closed = true; break; }
        if (c === "`") { problems.push(R_OPAQUE); w.text += c; continue; }
        if (c === "$") {
          const n = s[j + 1] ?? "";
          if (n === "(") problems.push(R_OPAQUE);
          else if (/[A-Za-z_{0-9@*#?!$-]/.test(n)) w.expands = true;
        }
        w.text += c;
      }
      if (!closed) { problems.push(R_OPAQUE); break; }
      i = j;
      continue;
    }
    if (ch === "`") { problems.push(R_OPAQUE); continue; }
    if (ch === "$") {
      const n = s[i + 1] ?? "";
      if (n === "(") { problems.push(R_OPAQUE); i++; continue; }
      if (n === "'" || n === '"') { problems.push(R_OPAQUE); continue; }
      if (/[A-Za-z_{0-9@*#?!$-]/.test(n)) word().expands = true;
      word().text += ch;
      continue;
    }
    if (ch === "<") {
      if (s[i + 1] === "(") { problems.push(R_OPAQUE); i++; continue; }
      if (s[i + 1] === "<") { problems.push(R_OPAQUE); i++; if (s[i + 1] === "<") i++; flush(); continue; }
      // An input redirection: the word that follows is a file name, not a command word.
      if (cur && /^[0-9]+$/.test((cur as Word).text)) cur = null;
      flush();
      skipNextWord = true;
      continue;
    }
    if (ch === ">") {
      const next = s[i + 1];
      if (next === "(") { problems.push(R_WRITES); i++; continue; }
      // A file descriptor copy such as 2>&1 or >&2 writes to no file.
      const dup = /^&([0-9]+|-)/.exec(s.slice(i + 1));
      if (dup && (!cur || /^[0-9]+$/.test((cur as Word).text))) { cur = null; i += dup[0].length; continue; }
      problems.push(R_WRITES);
      if (next === ">" || next === "|" || next === "&") i++;
      cur = null;
      continue;
    }
    if (ch === "&") {
      if (s[i + 1] === ">") { problems.push(R_WRITES); i++; if (s[i + 1] === ">") i++; continue; }
      if (s[i + 1] === "&") i++;
      end(false);
      continue;
    }
    if (ch === "|") {
      if (s[i + 1] === "|") { i++; end(false); continue; }
      if (s[i + 1] === "&") i++;
      end(true);
      continue;
    }
    if (ch === ";" || ch === "(" || ch === ")") { end(false); continue; }
    if (ch === "#" && !cur) { while (i + 1 < s.length && s[i + 1] !== "\n") i++; continue; }
    if (ch === "{") {
      const rest = /^[^\s;&|()<>]*/.exec(s.slice(i))?.[0] ?? "";
      if (/\}/.test(rest) && (rest.includes(",") || rest.includes(".."))) problems.push(R_OPAQUE);
    }
    if (ch === "*" || ch === "?" || ch === "[") word().globs = true;
    word().text += ch;
  }
  end(false);
  return { segments, problems };
}

const nameOf = (w: Word): string => basename(w.text).toLowerCase();

function gitVerdict(args: string[]): string | null {
  // Global options first: -C <path>, -c <k=v> (can define commands: refused), --git-dir, --work-tree, --no-pager.
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i];
    if (a === "-C") { i++; continue; }
    if (a === "-c" || a === "--config-env" || a.startsWith("--config-env=") || (a.startsWith("-c") && !a.startsWith("--"))) return R_OPAQUE;
    if (a.startsWith("-")) continue;
    break;
  }
  const sub = args[i]?.toLowerCase();
  const rest = args.slice(i + 1);
  const has = (re: RegExp): boolean => rest.some((a) => re.test(a));
  switch (sub) {
    case "push": case "clean": case "restore": case "filter-branch": case "update-ref": case "gc": case "prune": case "reflog": case "replace":
      return R_DESTRUCTIVE;
    case "reset": return has(/^--(hard|merge|keep)$/) ? R_DESTRUCTIVE : null;
    case "checkout": case "switch": return has(/^(--|-f|--force|-B|--discard-changes|\.)$/) ? R_DESTRUCTIVE : null;
    case "branch": return has(/^(-[A-Za-z]*[dD][A-Za-z]*|--delete|-m|-M|--move|-f|--force)$/) ? R_DESTRUCTIVE : null;
    case "tag": return has(/^(-d|--delete|-f|--force)$/) ? R_DESTRUCTIVE : null;
    case "stash": return has(/^(drop|clear|pop)$/) ? R_DESTRUCTIVE : null;
    case "worktree": return has(/^(remove|prune|move)$/) ? R_DESTRUCTIVE : null;
    case "rebase": return has(/^(--exec|-x|--onto)$/) ? R_OPAQUE : null;
    default: return null;
  }
}

/** The verdict for one command word at `c` of a segment (its arguments are the words after it). */
function commandVerdict(words: Word[], c: number, afterPipe: boolean, first: boolean): string | null {
  const w = words[c];
  if (first && (w.expands || w.globs)) return R_OPAQUE;
  const name = nameOf(w);
  const args = words.slice(c + 1).map((x) => x.text);
  const lowered = args.map((a) => a.toLowerCase());
  const fileArgs = args.filter((a) => !a.startsWith("-"));
  if (SHELLS.has(name)) {
    if (afterPipe) return R_OPAQUE;
    if (fileArgs.length === 0 || args.includes("-") || args.some((a) => /^-[A-Za-z]*[cs][A-Za-z]*$/.test(a) || a === "--command")) return R_OPAQUE;
    return null;
  }
  if (RUNNERS.has(name)) return R_OPAQUE;
  const interpreter = INTERPRETERS[name];
  if (interpreter) {
    if (args.some((a) => interpreter.test(a))) return R_OPAQUE;
    if (afterPipe && fileArgs.length === 0) return R_OPAQUE;
    if (args.includes("-")) return R_OPAQUE;
    return null;
  }
  if (AWKS.has(name) && args.some((a) => /system\s*\(|\|&|\|\s*"|\bgetline\b/.test(a))) return R_OPAQUE;
  if (WRITERS.has(name)) return R_WRITES;
  switch (name) {
    case "git": return gitVerdict(args);
    case "find": return lowered.some((a) => /^-(delete|exec|execdir|ok|okdir|fprint0?|fprintf|fls)$/.test(a)) ? R_DESTRUCTIVE : null;
    case "sed": case "gsed": return args.some((a) => a === "--in-place" || a.startsWith("--in-place=") || /^-[A-Za-z]*i/.test(a)) ? R_WRITES : null;
    case "chmod": return args.some((a) => a === "--recursive" || /^-[A-Za-z]*R[A-Za-z]*$/.test(a)) ? R_DESTRUCTIVE : null;
    case "defaults": return lowered.some((a) => /^(write|delete|import|rename|remove)$/.test(a)) ? R_SYSTEM : null;
    case "env": return args.some((a) => a === "-S" || a.startsWith("--split-string") || /^-[A-Za-z]*S/.test(a)) ? R_OPAQUE : null;
    default: return null;
  }
}

/**
 * Whether a shell command may get "Always allow". Pure. No when the command can delete, move or change things, runs as an
 * administrator, changes settings of this Mac, writes to a file by redirection, runs text it builds or fetches at run time
 * (command substitution, a variable, `eval`, a shell fed by a pipe or by `-c`, an interpreter with inline code, `xargs`, `ssh`), contains
 * characters the card cannot show, or is too long. Otherwise yes: the rule is the exact command text, nothing else.
 */
export function shellAlways(command: string): ShellVerdict {
  const text = command.trim();
  if (text.length > SHELL_COMMAND_MAX) return { always: false, reason: R_LONG };
  if (hasHiddenCharacters(text)) return { always: false, reason: R_HIDDEN };
  const parsed = parseShell(text);
  if (parsed.problems.length > 0) return { always: false, reason: parsed.problems[0] };
  for (const seg of parsed.segments) {
    const words = seg.words;
    let k = 0;
    while (k < words.length && CLAUSE_STARTS.has(words[k].text)) k++;
    const header = k < words.length && HEADER_STARTS.has(words[k].text);
    // Every word is looked at for the words that delete, move or change things, whatever its place ("find . -exec rm {} +").
    for (const w of words) {
      // A variable's value is not known when the card shows: "X=push; git $X" must not look like a harmless command.
      if (w.expands) return { always: false, reason: R_OPAQUE };
      const name = nameOf(w);
      if (DESTRUCTIVE_ANYWHERE.has(name) || isMkfs(name)) return { always: false, reason: name === "sudo" || name === "doas" || name === "launchctl" || name === "osascript" ? R_SYSTEM : R_DESTRUCTIVE };
    }
    if (header) continue;
    // Variable assignments in front of the command.
    while (k < words.length && /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(words[k].text)) {
      if (DANGEROUS_ENV.test(/^[A-Za-z_][A-Za-z0-9_]*/.exec(words[k].text)?.[0] ?? "")) return { always: false, reason: R_OPAQUE };
      k++;
    }
    if (k >= words.length) continue;
    const first = nameOf(words[k]);
    // After a wrapper ("nice -n 10 git push", "timeout 5 bash -c …") every later word could be the command: look at each.
    const candidates = WRAPPERS.has(first) ? Array.from({ length: words.length - k - 1 }, (_, n) => k + 1 + n) : [];
    const verdict = commandVerdict(words, k, seg.afterPipe, true) ?? candidates.map((c) => commandVerdict(words, c, seg.afterPipe, false)).find((v) => v !== null) ?? null;
    if (verdict) return { always: false, reason: verdict };
  }
  return { always: true };
}

// ---------------------------------------------------------------- keys and targets

export type LocalKind = "shell" | "write" | "web" | "websearch" | "plan";

export interface LocalTarget {
  kind: LocalKind;
  /** The rule key: `write:<folder>`, `shell:<command>`, `web:<host>`, `websearch`, `flow:add`. */
  key: string;
  /** Whether the card offers "Always allow" (the call still allows it now, whatever an older rule says). */
  alwaysOk: boolean;
  /** Why not, in a plain sentence. */
  why?: string;
  /** The exact thing: the command, the file, the address or the search words (as received; the card cleans them). */
  text: string;
  /** write: the real folder and the verb; web: the host. */
  folder?: string;
  host?: string;
  verb?: "Write" | "Edit";
  /** web: false when the address is on this Mac itself (the request does not leave it). Default: it leaves. */
  leavesMac?: boolean;
  /** plan: the day the lines are for (`yyyy-MM-dd`) and how many lines the plan has. */
  day?: string;
  lines?: number;
  /** write: the path the agent named when it differs from the real one (a link, `~`, a relative path). */
  via?: string;
}

export interface WriteScope { file: string; folder: string; alwaysOk: boolean; via: string | null }

/** The tools that go to the Always/Never rules. Reads (Read, Glob, Grep) keep their folder grant (filePolicy.decide). */
export function isLocalConsentTool(tool: string): boolean {
  return tool === "Bash" || tool === "WebFetch" || tool === "WebSearch" || tool === "Write" || tool === "Edit" || tool === "MultiEdit" || tool === "NotebookEdit";
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");

// ---------------------------------------------------------------- the plan tool (flow_plan_add)

/** The rule key of "add lines to the plan on this Mac". */
export const FLOW_ADD_KEY = "flow:add";
/** The Companion MCP tool, under both harnesses' names (the Agent SDK and LangChain name MCP tools `mcp__<server>__<tool>`). */
export const FLOW_ADD_TOOLS: readonly string[] = ["mcp__companion__flow_plan_add", "companion__flow_plan_add"];
/** The card shows this many lines of the plan; the rest is counted. */
export const FLOW_CARD_LINES = 12;

export function isFlowPlanAdd(tool: string): boolean {
  return FLOW_ADD_TOOLS.includes(tool);
}

const pad2 = (n: number): string => String(n).padStart(2, "0");
/** Today as `yyyy-MM-dd` on this Mac's clock (the CLI's default day too). */
export function localToday(now: Date = new Date()): string {
  return `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`;
}

function validDay(day: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  return y >= 1 && date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d;
}

function planTarget(input: Record<string, unknown>, today: () => string): LocalTarget | { refuse: string } {
  const text = str(input.text);
  if (!text.trim()) return { refuse: "TBD could not see which lines to add to your plan, so it did not add anything." };
  let day = today();
  if (input.day !== undefined && input.day !== null) {
    if (typeof input.day !== "string" || !validDay(input.day)) return { refuse: "TBD could not read the day of this plan, so it did not add anything." };
    day = input.day;
  }
  const all = text.split(/\r\n|\n|\r/).filter((line) => line.trim() !== "");
  const shown = all.slice(0, FLOW_CARD_LINES).join("\n");
  return { kind: "plan", key: FLOW_ADD_KEY, alwaysOk: true, text: shown, day, lines: all.length };
}

// ---------------------------------------------------------------- web: which addresses never get Always

const R_WEB_MAC = "This address is on this Mac.";
const R_WEB_LAN = "This address is on your own network.";
const R_WEB_IP = "This address is a number, so TBD cannot tell what is behind it.";
const R_WEB_USER = "This address has a user name or password in it.";
const R_WEB_PORT = "This address uses a special port.";

type WebVerdict = { always: true } | { always: false; reason: string; onThisMac: boolean };

function ipv4Parts(host: string): number[] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  return parts.every((n) => n <= 255) ? parts : null;
}

/** 127/8 on this Mac; 10/8, 172.16/12, 192.168/16, 169.254/16 (and the carrier-grade 100.64/10, and 0/8) on the network. */
function ipv4Kind(p: number[]): "mac" | "lan" | "public" {
  const [a, b] = p;
  if (a === 127) return "mac";
  if (a === 10 || a === 0 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127)) return "lan";
  return "public";
}

/** `[...]` as the URL parser writes an IPv6 host (compressed, lower case). ::1 on this Mac; fc00::/7 and fe80::/10 on the network; ::ffff:a.b.c.d by its IPv4 part. */
function ipv6Kind(bracketed: string): "mac" | "lan" | "public" {
  const h = bracketed.slice(1, -1);
  if (h === "::1" || h === "::") return "mac";
  const mapped = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(h);
  if (mapped) {
    const hi = parseInt(mapped[1], 16), lo = parseInt(mapped[2], 16);
    return ipv4Kind([hi >> 8, hi & 255, lo >> 8, lo & 255]);
  }
  const first = parseInt(h.split(":")[0] || "0", 16);
  if (first >= 0xfc00 && first <= 0xfdff) return "lan"; // fc00::/7
  if (first >= 0xfe80 && first <= 0xfebf) return "lan"; // fe80::/10
  return "public";
}

/**
 * No "Always allow" (ask every time) for a web address that is on this Mac or the person's own network, is a bare IP number, has a
 * user name or password in it, or uses a port other than the default. An "Always" for a host name would otherwise carry over to
 * a request that reaches something else: a local service, a router, an admin page, or one that sees a login.
 */
export function webAlwaysVerdict(url: URL): WebVerdict {
  const host = url.hostname.toLowerCase().replace(/\.+$/, "");
  const mac = (reason: string): WebVerdict => ({ always: false, reason, onThisMac: true });
  const lan = (reason: string): WebVerdict => ({ always: false, reason, onThisMac: false });
  if (host === "localhost" || host.endsWith(".localhost")) return mac(R_WEB_MAC);
  if (host.startsWith("[")) {
    const kind = ipv6Kind(host);
    return kind === "mac" ? mac(R_WEB_MAC) : lan(kind === "lan" ? R_WEB_LAN : R_WEB_IP);
  }
  const v4 = ipv4Parts(host);
  if (v4) {
    const kind = ipv4Kind(v4);
    return kind === "mac" ? mac(R_WEB_MAC) : lan(kind === "lan" ? R_WEB_LAN : R_WEB_IP);
  }
  if (host.endsWith(".local") || !host.includes(".")) return lan(R_WEB_LAN); // Bonjour names and one-word names (a router, a NAS)
  if (url.username !== "" || url.password !== "") return lan(R_WEB_USER);
  if (url.port !== "") return lan(R_WEB_PORT);
  return { always: true };
}

/**
 * What a local call is, from the call itself. `null`: not a tool of the rules (the caller's own policy stays). `{ refuse }`: a
 * call TBD cannot name (no command, no file, no address) is refused, because no rule can describe it.
 */
export function localTarget(tool: string, input: Record<string, unknown>, writeScope: (tool: string, input: Record<string, unknown>) => WriteScope | null, today: () => string = localToday): LocalTarget | { refuse: string } | null {
  if (isFlowPlanAdd(tool)) return planTarget(input, today);
  if (!isLocalConsentTool(tool)) return null;
  if (tool === "Bash") {
    const command = str(input.command).trim();
    if (!command) return { refuse: "TBD could not see which command to run, so it did not run anything." };
    const verdict = shellAlways(command);
    return { kind: "shell", key: `shell:${command}`, alwaysOk: verdict.always, ...(verdict.always ? {} : { why: verdict.reason }), text: command };
  }
  if (tool === "WebSearch") {
    return { kind: "websearch", key: "websearch", alwaysOk: true, text: str(input.query) };
  }
  if (tool === "WebFetch") {
    const raw = str(input.url).trim();
    let url: URL | null = null;
    try { url = new URL(raw); } catch { url = null; }
    if (!url || (url.protocol !== "http:" && url.protocol !== "https:") || !url.hostname) return { refuse: "TBD could not read that web address, so it did not fetch it." };
    // Userinfo and a special port: `url.hostname` is only the host, so the key is the host; Always is not offered for them (above).
    const verdict = webAlwaysVerdict(url);
    return {
      kind: "web", key: `web:${url.hostname.toLowerCase()}`, alwaysOk: verdict.always, text: raw, host: url.hostname.toLowerCase(),
      ...(verdict.always ? {} : { why: verdict.reason, leavesMac: !verdict.onThisMac }),
    };
  }
  const scope = writeScope(tool, input);
  if (!scope) return { refuse: "TBD could not see which file this changes, so it did not change anything." };
  return {
    kind: "write", key: `write:${scope.folder}`, alwaysOk: scope.alwaysOk,
    ...(scope.alwaysOk ? {} : { why: "This file is outside the agent's folders." }),
    text: scope.file, folder: scope.folder, verb: tool === "Write" ? "Write" : "Edit", ...(scope.via ? { via: scope.via } : {}),
  };
}

/** The key as rules compare it: macOS paths without regard to case, hosts in lower case, commands exactly. */
export function normaliseKey(key: string): string {
  if (key.startsWith("write:")) return `write:${process.platform === "darwin" ? key.slice(6).toLowerCase() : key.slice(6)}`;
  if (key.startsWith("web:")) return key.toLowerCase();
  return key;
}

const VALID_KEY = /^(shell:[\s\S]+|write:\/[\s\S]+|web:[^\s]+|websearch|flow:add)$/;

// ---------------------------------------------------------------- the card

export const ALWAYS_HINT = "Always allow is TBD's own permission on this Mac. It is not a Rules rule (that needs Rules).";
/** The line on a card that has no "Always allow". */
export const EVERY_TIME_LINE = "TBD asks every time for this kind of action.";
export const LOCAL_TEXT_MAX = 2000;

/** Text for the card without the characters that change what a line looks like (bidi controls, control characters; the line feed stays). */
export function cleanLocalText(text: string): string {
  let out = "";
  for (const ch of text) {
    const c = ch.codePointAt(0) ?? 0;
    const bidi = (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) || c === 0x200e || c === 0x200f || c === 0x061c;
    const control = (c < 0x20 && c !== 0x0a && c !== 0x09) || (c >= 0x7f && c <= 0x9f);
    if (!bidi && !control) out += ch;
  }
  return out;
}

/** At most `max` characters of the text, and "…" when it was longer: a cut is always marked. */
function clipMarked(text: string, max: number): string {
  const chars = [...text];
  return chars.length > max ? `${chars.slice(0, max).join("")}…` : text;
}

export function buildLocalCard(target: LocalTarget): LocalCard {
  const full = cleanLocalText(target.text);
  const text = clipMarked(full, LOCAL_TEXT_MAX);
  const cut = [...full].length > LOCAL_TEXT_MAX ? `Only the first ${LOCAL_TEXT_MAX} characters are shown. The text is ${[...full].length} characters long.` : undefined;
  const offered = target.alwaysOk;
  const base = { alwaysOffered: offered, hint: offered ? ALWAYS_HINT : EVERY_TIME_LINE };
  if (target.kind === "shell") {
    return {
      title: "Allow TBD's agent to run this command?", label: "Command", text, ...(cut ? { cut } : {}), leavesMac: false,
      ...(offered ? { scope: "Always allow covers this exact command only." } : { note: target.why }), ...base,
    };
  }
  if (target.kind === "write") {
    const folder = clipMarked(cleanLocalText(target.folder ?? ""), LOCAL_TEXT_MAX);
    return {
      title: target.verb === "Edit" ? "Allow TBD's agent to change this file?" : "Allow TBD's agent to write this file?", label: "File", text, ...(cut ? { cut } : {}), leavesMac: false,
      ...(target.via ? { via: `Named as: ${clipMarked(cleanLocalText(target.via), 600)}` } : {}),
      folderLine: `Folder: ${folder}`,
      ...(offered ? { scope: `Always allow covers writing files in this folder only: ${folder}` } : { note: target.why }), ...base,
    };
  }
  if (target.kind === "web") {
    const host = cleanLocalText(target.host ?? "");
    const leaves = target.leavesMac !== false;
    const leaveLine = "This sends a request over the internet. It leaves this Mac.";
    return {
      title: `Allow TBD's agent to fetch from ${host}?`, label: "Address", text, ...(cut ? { cut } : {}), leavesMac: leaves,
      // No Always: say why (this address is on this Mac or your network, has a login in it, ...); the every-time line is the hint.
      note: offered ? leaveLine : `${target.why ?? ""}${leaves ? ` ${leaveLine}` : ""}`.trim(),
      ...(offered ? { scope: `Always allow covers fetching from ${host} only.` } : {}), ...base,
    };
  }
  if (target.kind === "plan") {
    const total = target.lines ?? 0;
    const shownLines = text === "" ? 0 : text.split("\n").length;
    return {
      title: `Allow TBD's agent to add lines to your plan for ${target.day ?? ""}?`, label: "Plan", text,
      dayLine: `Day: ${target.day ?? ""}`,
      ...(total > shownLines ? { cut: `Only the first ${shownLines} of ${total} lines are shown.` } : cut ? { cut } : {}), leavesMac: false,
      note: "The lines are saved on this Mac only. They are not sent to Task Board.",
      ...(offered ? { scope: "Always allow covers adding lines to your plan on this Mac." } : {}), ...base,
    };
  }
  return {
    title: "Allow TBD's agent to search the web?", label: "Search", text, ...(cut ? { cut } : {}), leavesMac: true,
    note: "The search words go over the internet. They leave this Mac.", scope: "Always allow covers every web search.", ...base,
  };
}

// ---------------------------------------------------------------- remembered rules

export type LocalDecision = "always" | "never";

export interface LocalRule { key: string; decision: LocalDecision; /** ISO time the person chose it. */ at: string }

interface LocalFile { version: 1; rules: LocalRule[] }

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const validRule = (r: unknown): r is LocalRule =>
  isRecord(r) && typeof r.key === "string" && VALID_KEY.test(r.key) && (r.decision === "always" || r.decision === "never") && typeof r.at === "string";

/** At most this many `.corrupt-*` copies are made; after that a bad file stays and the next save replaces it. */
export const MAX_CORRUPT_COPIES = 3;

export interface LocalIo {
  /** Test seam: the rename that puts the new file in place. */
  rename(from: string, to: string): void;
}

/**
 * `local-consent.json` in the helper's state folder: mode 0600, atomic (temp file, then rename; the temp file is removed when
 * the write fails). Not keyed by workspace: these are choices about this Mac. A file that cannot be read or has the wrong shape
 * is moved aside (`.corrupt-<time>`, at most three copies, never deleted by TBD) and the rules start empty; `unreadable()` says
 * so until the person's next choice is saved. It holds keys the person chose (a command, a folder, a host) and nothing else.
 */
export function createLocalConsentStore(file: string, now: () => number = Date.now, io: LocalIo = { rename: renameSync }) {
  const folder = dirname(file);
  const copyName = new RegExp(`^${basename(file).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\.corrupt-\\d+$`);
  const copies = (): string[] => {
    try { return readdirSync(folder).filter((n) => copyName.test(n)).map((n) => join(folder, n)); } catch { return []; }
  };
  const mtime = (path: string): number => { try { return statSync(path).mtimeMs; } catch { return 0; } };

  /** Two rules for the same key become one: Never wins, else the newer. */
  function merged(rules: LocalRule[]): LocalRule[] {
    const byKey = new Map<string, LocalRule>();
    for (const r of rules) {
      const k = normaliseKey(r.key);
      const old = byKey.get(k);
      if (!old || (old.decision !== "never" && (r.decision === "never" || r.at >= old.at))) byKey.set(k, r);
    }
    return [...byKey.values()];
  }
  function load(): LocalFile {
    if (!existsSync(file)) return { version: 1, rules: [] };
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      if (!isRecord(parsed) || parsed.version !== 1 || !Array.isArray(parsed.rules) || !parsed.rules.every(validRule)) throw new Error("unexpected shape");
      return { version: 1, rules: merged(parsed.rules.map((r) => ({ key: r.key, decision: r.decision, at: r.at }))) };
    } catch {
      if (copies().length < MAX_CORRUPT_COPIES) {
        try { renameSync(file, `${file}.corrupt-${now()}`); } catch { /* cannot move it: start empty anyway */ }
      }
      return { version: 1, rules: [] };
    }
  }
  function save(data: LocalFile): void {
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    const temp = `${file}.${process.pid}.tmp`;
    try {
      writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
      chmodSync(temp, 0o600);
      io.rename(temp, file);
    } catch (error) {
      try { unlinkSync(temp); } catch { /* it was never made */ }
      throw error;
    }
  }
  return {
    decision(key: string): LocalDecision | null {
      const k = normaliseKey(key);
      return load().rules.find((r) => normaliseKey(r.key) === k)?.decision ?? null;
    },
    remember(key: string, decision: LocalDecision): void {
      if (!VALID_KEY.test(key)) throw new Error("TBD cannot keep a choice for that action.");
      const k = normaliseKey(key);
      const data = load();
      data.rules = data.rules.filter((r) => normaliseKey(r.key) !== k);
      data.rules.push({ key, decision, at: new Date(now()).toISOString() });
      save(data);
    },
    /** Newest first. */
    list(): LocalRule[] {
      return [...load().rules].sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
    },
    /** True when a rule was removed. */
    revoke(key: string): boolean {
      const k = normaliseKey(key);
      const data = load();
      const after = data.rules.filter((r) => normaliseKey(r.key) !== k);
      if (after.length === data.rules.length) return false;
      data.rules = after;
      save(data);
      return true;
    },
    /** True when the file could not be read and TBD kept a copy (until the next choice is saved). Settings says so. */
    unreadable(): boolean {
      const kept = copies();
      if (existsSync(file)) {
        try {
          const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
          if (!isRecord(parsed) || parsed.version !== 1 || !Array.isArray(parsed.rules) || !parsed.rules.every(validRule)) return true;
        } catch { return true; }
        return kept.some((c) => mtime(c) > mtime(file));
      }
      return kept.length > 0;
    },
  };
}

export type LocalConsentStore = ReturnType<typeof createLocalConsentStore>;

/** What Settings › Access reads: the rules of this Mac and whether the file was unreadable (a copy was kept). */
export function localConsentListing(store: LocalConsentStore): { choices: LocalRule[]; unreadable: boolean } {
  return { choices: store.list(), unreadable: store.unreadable() };
}

// ---------------------------------------------------------------- the helper's decision

export type PolicyVerdict = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "ask"; folder: string | null };

export interface LocalPermissionDeps {
  store: LocalConsentStore;
  /** filePolicy.decide for this call: secrets and protected locations deny first. */
  policy(tool: string, input: Record<string, unknown>): PolicyVerdict;
  /** filePolicy.writeScope: the real folder of a write target and whether it may get "Always allow". */
  writeScope(tool: string, input: Record<string, unknown>): WriteScope | null;
  /** Today as `yyyy-MM-dd` (the default day of a plan); tests set it. Default: this Mac's date. */
  today?(): string;
  /** Show the card. `remember` with `allow` = Always allow; `remember` without `allow` = Never allow. */
  askPerson(card: LocalCard, target: LocalTarget): Promise<{ allow: boolean; remember: boolean }>;
  /**
   * Only look for a refusal (a protected location, a stored Never): no card, no Always. The agent asks this for every local
   * call in a PreToolUse hook, because the Claude Agent SDK lets read-only shell commands (`ls`, `pwd`, `git status`) run
   * without asking `canUseTool`; a Never must still stop them. Not a decision to run: the normal flow follows.
   */
  checkOnly?: boolean;
}

export interface LocalPermissionResult {
  allow: boolean;
  message?: string;
  /** Set when a remembered rule decided, or the person chose Always/Never on the card. */
  remember?: LocalDecision;
}

export const localNeverMessage = (target: LocalTarget): string => {
  const what = target.kind === "shell" ? "running this command" : target.kind === "write" ? "writing in this folder" : target.kind === "web" ? `fetching from ${target.host}` : target.kind === "plan" ? "adding lines to the plan" : "web searches";
  return `The person told TBD never to allow ${what}.`;
};

/**
 * Decide one local call (the Agent SDK's Bash, Write, Edit, MultiEdit, NotebookEdit, WebFetch, WebSearch, and the Companion plan
 * tool `flow_plan_add` in both harnesses). `null` for any other
 * tool: the caller's own policy (reads in granted folders, the folder grant) decides it.
 *
 * Order: a secret or protected location denies first, whatever a rule says. Then a stored `never` denies. Then a stored
 * `always` allows, but only while the call still allows "Always" (`alwaysOk`: a destructive or opaque command, a folder outside
 * the agent's folders, the home folder or `/` never do, whatever an older rule says). Then the card. An "Always allow" answer to
 * a card that did not offer it counts once.
 */
export async function decideLocalCall(req: { tool: string; input: Record<string, unknown> }, deps: LocalPermissionDeps): Promise<LocalPermissionResult | null> {
  // The plan tool: only mode "save" writes. "preview" is free (nothing is written, nothing leaves this Mac), so no card and no rule.
  const flow = isFlowPlanAdd(req.tool);
  if (flow && req.input.mode === "preview") return { allow: true };
  const target = localTarget(req.tool, req.input, deps.writeScope, deps.today);
  if (target === null) return null;
  // The plan tool names no file or command: no protected location can be in it.
  const verdict: PolicyVerdict = flow ? { kind: "ask", folder: null } : deps.policy(req.tool, req.input);
  if (verdict.kind === "deny") return { allow: false, message: verdict.reason };
  if ("refuse" in target) return deps.checkOnly ? { allow: true } : { allow: false, message: target.refuse };
  const rule = deps.store.decision(target.key);
  if (rule === "never") return { allow: false, message: localNeverMessage(target), remember: "never" };
  if (deps.checkOnly) return { allow: true };
  if (rule === "always" && target.alwaysOk) return { allow: true, remember: "always" };
  if (verdict.kind === "allow") return { allow: true };
  const answer = await deps.askPerson(buildLocalCard(target), target);
  let choice: LocalDecision | undefined = answer.remember ? (answer.allow ? (target.alwaysOk ? "always" : undefined) : "never") : undefined;
  if (choice) {
    // A choice that cannot be saved counts once; it never turns an answer around.
    try { deps.store.remember(target.key, choice); } catch { choice = undefined; }
  }
  if (answer.allow) return { allow: true, ...(choice ? { remember: choice } : {}) };
  return { allow: false, message: choice === "never" ? localNeverMessage(target) : "The person declined this action.", ...(choice ? { remember: choice } : {}) };
}
