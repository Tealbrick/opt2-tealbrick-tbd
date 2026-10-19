import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import type { AgentConfig, AgentEvent, AgentModel, AgentQuestion, AgentToHelper, HelperToAgent } from "../agent/protocol";
import type { ContentBlock } from "../shared/message";

/**
 * Supervisor for TBD's default agent process (C24: TBD Chat talks only to it).
 *
 * The helper (person side) starts the agent with an allow-listed environment:
 * the user's model key and nothing else that matters. The person token never
 * crosses this boundary (CREDENTIALS §12). Tool calls that change this Mac
 * come back here as permission requests and go to the person's consent card.
 */

// ---------------------------------------------------------------- harness seam (WP-HARNESS step 1)

/**
 * WP-HARNESS step 1: the seam between the Chat helper and the harness that runs TBD's agent.
 *
 * Every harness is one adapter that turns the route the native app resolved (Settings → Models, or the setup flow)
 * into (a) the environment of the agent process and (b) the model part of its init message. The supervisor
 * (defaultAgent.ts) and the stdio protocol (agent/protocol.ts) stay the same for every harness. Only the Claude
 * Agent SDK exists today; Claude Code CLI, Codex, LangChain and Eve come later (PLAN-WP-HARNESS.md).
 *
 * Rules (CREDENTIALS §12, K3, C287): the agent process gets PATH/HOME/TMPDIR and the person's OWN model credential
 * only, under a name from MODEL_SECRET_NAMES; provider settings only under names from MODEL_PLAIN_NAMES. Anything else in a
 * route is refused, so a wrong or hostile route can never smuggle the person token or another variable in.
 */

/** Provider settings and secret names a route may carry. Same lists as the agent's (agent/modelEnv.ts). */
export const MODEL_PLAIN_NAMES: ReadonlySet<string> = new Set([
  "CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE",
  "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
  "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE",
  "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
]);
export const MODEL_SECRET_NAMES: ReadonlySet<string> = new Set(["ANTHROPIC_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_FOUNDRY_API_KEY"]);

/** What the native side resolves for TBD's agent ("agentModel"). */
export interface AgentRoute {
  /** Harness adapter id; absent = the Claude Agent SDK (earlier native builds). */
  harness?: string;
  model: string;
  /** Anthropic or Anthropic-compatible base URL (the registry route). */
  baseUrl?: string;
  /** The person's Anthropic key (registry route); kept for the earlier shape. */
  apiKey?: string;
  /** Provider settings (cloud route), plain. */
  env?: Record<string, string>;
  /** The person's own model credential by variable name. */
  secretEnv?: Record<string, string>;
  /** For the UI ("Anthropic", "Amazon Bedrock"…). */
  source?: string;
}

export interface HarnessAdapter {
  id: string;
  title: string;
  /** The agent process environment (secrets included); nothing else is inherited. */
  processEnv(route: AgentRoute, host: NodeJS.ProcessEnv): Record<string, string>;
  /** The model part of the init message (plain only). */
  initModel(route: AgentRoute): AgentModel;
}

function checked(values: Record<string, string> | undefined, allowed: ReadonlySet<string>, kind: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(values ?? {})) {
    if (!allowed.has(name)) throw new Error(`TBD's agent route has an unsupported ${kind} setting (${name}).`);
    if (typeof value !== "string") throw new Error(`TBD's agent route setting ${name} is not text.`);
    if (value !== "") out[name] = value;
  }
  return out;
}

/** The Claude Agent SDK (the bundled agent.mjs with the bundled Claude executable). */
export const claudeAgentSdk: HarnessAdapter = {
  id: "claude-agent-sdk",
  title: "TBD's agent",
  processEnv(route, host) {
    const secrets = checked(route.secretEnv, MODEL_SECRET_NAMES, "secret");
    // Earlier native builds send the Anthropic key as apiKey only.
    if (!secrets.ANTHROPIC_API_KEY && route.apiKey) secrets.ANTHROPIC_API_KEY = route.apiKey;
    return { PATH: "/usr/bin:/bin", HOME: host.HOME ?? "", TMPDIR: host.TMPDIR ?? "/tmp", ...secrets };
  },
  initModel(route) {
    const env = checked(route.env, MODEL_PLAIN_NAMES, "provider");
    const secretNames = Object.keys(checked(route.secretEnv, MODEL_SECRET_NAMES, "secret"));
    return { model: route.model, baseUrl: route.baseUrl, ...(Object.keys(env).length ? { env } : {}), ...(secretNames.length ? { secretNames } : {}) };
  },
};

export const HARNESSES: Record<string, HarnessAdapter> = { [claudeAgentSdk.id]: claudeAgentSdk };

/** The adapter for a route; a harness that is not built yet is a plain sentence for Chat. */
export function harnessFor(route: AgentRoute): HarnessAdapter {
  const id = route.harness ?? claudeAgentSdk.id;
  const adapter = HARNESSES[id];
  if (!adapter) throw new Error(`This agent type is not available in this TBD version yet (${id}).`);
  return adapter;
}

export const DEFAULT_AGENT_ID = "tbd-default";

export interface TurnCallbacks {
  onDelta(text: string): void;
  onReset?(): void;
  onActivity(label: string | null): void;
  onTurn?(turn: { sessionId: string; turnId?: string }): void;
  /** The agent asks the person (AskUserQuestion); answer with `answer(reqId, …)`. */
  onQuestion?(question: { reqId: string; questions: AgentQuestion[] }): void;
}

export interface DefaultAgentDeps {
  /** Node binary and bundled agent entry. */
  node: string;
  entry: string;
  /** Model route + the person's own key, resolved when the agent starts (Settings → Models / setup; WP-HARNESS). */
  model(): Promise<AgentRoute>;
  /** Everything else the agent needs; no credentials. */
  config(): Promise<Omit<AgentConfig, "model">>;
  /** Decide one tool call (file policy + person consent, SEC-04); message is shown to the agent on deny. */
  permission(req: { tool: string; detail: string; input: Record<string, unknown> }): Promise<{ allow: boolean; message?: string }>;
  /** For tests: spawn replacement. */
  spawnProcess?: typeof spawn;
}

interface PendingTurn extends TurnCallbacks {
  resolve(result: { sessionId: string; reply: string }): void;
  reject(error: Error): void;
  sessionId: string;
}

export function createDefaultAgent(deps: DefaultAgentDeps) {
  let child: ChildProcessWithoutNullStreams | null = null;
  let starting: Promise<void> | null = null;
  const turns = new Map<string, PendingTurn>();

  const send = (m: HelperToAgent) => child?.stdin.write(`${JSON.stringify(m)}\n`);
  /** The person's model credential values of the running agent: scrubbed from every text that comes back. */
  let secretValues: string[] = [];
  const scrub = (text: string): string => secretValues.reduce((t, v) => (v.length >= 8 ? t.split(v).join("[redacted key]") : t), text);

  function failAll(message: string): void {
    for (const [id, t] of turns) { t.reject(new Error(message)); turns.delete(id); }
  }

  async function start(): Promise<void> {
    const route = await deps.model();
    // WP-HARNESS seam: the adapter builds the agent's environment and init model; refuses unknown harnesses/names.
    const harness = harnessFor(route);
    const rest = await deps.config();
    const env = harness.processEnv(route, process.env);
    // A provider error can quote the key; nothing the agent sends back may carry it into Chat or the helper log.
    secretValues = Object.entries(env).filter(([name]) => MODEL_SECRET_NAMES.has(name)).map(([, value]) => value);
    const proc = (deps.spawnProcess ?? spawn)(deps.node, [deps.entry], { env, stdio: ["pipe", "pipe", "pipe"] }) as ChildProcessWithoutNullStreams;
    child = proc;
    proc.stderr.on("data", () => { /* agent logs stay local; never forwarded with content */ });
    const ready = new Promise<void>((resolve, reject) => {
      const lines = createInterface({ input: proc.stdout });
      lines.on("line", (line) => {
        let m: AgentToHelper;
        try { m = JSON.parse(line) as AgentToHelper; } catch { return; }
        if (m.type === "ready") { resolve(); return; }
        handle(m);
      });
      proc.once("exit", (code) => {
        if (child === proc) child = null;
        reject(new Error(`The agent stopped (exit ${code ?? "signal"}).`));
        failAll("The agent stopped. Send your message again.");
      });
      proc.once("error", (e) => reject(e));
    });
    send({ type: "init", config: { ...rest, model: harness.initModel(route) } });
    await ready;
  }

  function handle(m: AgentToHelper): void {
    if (m.type === "event") {
      const t = turns.get(m.id);
      if (!t) return;
      const e: AgentEvent = m.event;
      if (e.kind === "delta") t.onDelta(scrub(e.text));
      else if (e.kind === "reset") t.onReset?.();
      else if (e.kind === "activity") t.onActivity(e.label === null ? null : scrub(e.label));
      else if (e.kind === "session") { t.sessionId = e.sessionId; t.onTurn?.({ sessionId: e.sessionId, turnId: m.id }); }
    } else if (m.type === "permission_request") {
      void deps.permission({ tool: m.tool, detail: m.detail, input: m.input ?? {} })
        .then((d) => send({ type: "permission", reqId: m.reqId, allow: d.allow, message: d.message }))
        .catch(() => send({ type: "permission", reqId: m.reqId, allow: false }));
    } else if (m.type === "question") {
      const t = turns.get(m.id);
      if (t?.onQuestion) t.onQuestion({ reqId: m.reqId, questions: m.questions ?? [] });
      else send({ type: "answer", reqId: m.reqId, answers: null });
    } else if (m.type === "done") {
      const t = turns.get(m.id);
      if (t) { turns.delete(m.id); t.resolve({ sessionId: m.sessionId, reply: scrub(m.reply) }); }
    } else if (m.type === "error") {
      if (!m.id) return;
      const t = turns.get(m.id);
      if (t) { turns.delete(m.id); t.reject(new Error(scrub(m.message))); }
    }
  }

  async function ensure(): Promise<void> {
    if (child) return;
    if (!starting) starting = start().finally(() => { starting = null; });
    await starting;
  }

  return {
    async sendTurn(input: { text: string; content?: ContentBlock[]; sessionId?: string } & TurnCallbacks): Promise<{ sessionId: string; reply: string; turnId: string }> {
      await ensure();
      const id = randomUUID();
      const result = await new Promise<{ sessionId: string; reply: string }>((resolve, reject) => {
        turns.set(id, { ...input, resolve, reject, sessionId: input.sessionId ?? "" });
        send({ type: "turn", id, text: input.text, content: input.content, sessionId: input.sessionId });
      });
      return { ...result, turnId: id };
    },
    /** The person's answers to a question (null: not answered). */
    answer(reqId: string, answers: Record<string, string> | null): void {
      send({ type: "answer", reqId, answers });
    },
    cancel(turnId?: string): void {
      if (turnId) send({ type: "cancel", id: turnId });
      else for (const id of turns.keys()) send({ type: "cancel", id });
    },
    stop(): void {
      if (!child) return;
      send({ type: "shutdown" });
      const c = child;
      child = null;
      setTimeout(() => c.kill("SIGTERM"), 1000).unref();
      failAll("The agent was stopped.");
    },
    /** Stop the agent process (open turns end with an error) and start it again with the current model route. */
    async restart(): Promise<void> {
      this.stop();
      await ensure();
    },
    running: () => child !== null,
  };
}

export type DefaultAgent = ReturnType<typeof createDefaultAgent>;
