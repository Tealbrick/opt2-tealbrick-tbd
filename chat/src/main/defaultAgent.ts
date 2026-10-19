import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import type { AgentConfig, AgentEvent, AgentModel, AgentQuestion, AgentToHelper, ConnectAsk, HelperToAgent, SelfTestTools } from "../agent/protocol";
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
 * Agent SDK and LangChain (L1) exist today; Claude Code CLI, Codex and Eve come later (PLAN-WP-HARNESS.md).
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
export const MODEL_SECRET_NAMES: ReadonlySet<string> = new Set(["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_FOUNDRY_API_KEY"]);

/** What the native side resolves for TBD's agent ("agentModel"). */
export interface AgentRoute {
  /** Harness adapter id; absent = the Claude Agent SDK (earlier native builds). */
  harness?: string;
  model: string;
  /** Model provider for harnesses that offer more than one (LangChain); absent = "anthropic". */
  provider?: "anthropic" | "openai";
  /** Anthropic or Anthropic-compatible base URL (the registry route); OpenAI-compatible for provider "openai". */
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
  /** The agent entry for this harness, given the folder of the default entry (the app's resources); absent = the default entry. */
  entry?(resourcesDir: string): string;
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

/** The LangChain agent uses these two keys only (no cloud providers); any other secret name in its route is refused. */
export const LANGCHAIN_SECRET_NAMES: ReadonlySet<string> = new Set(["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]);

/**
 * The LangChain agent (WP-HARNESS L1): a small LangGraph graph in the bundled agent-langchain.mjs. The process gets
 * PATH/HOME/TMPDIR and the person's declared model credential(s) only (Anthropic or OpenAI key). The route's provider,
 * model and base URL go in the init message; the key never does.
 */
export const langchain: HarnessAdapter = {
  id: "langchain",
  title: "LangChain agent",
  processEnv(route, host) {
    const secrets = checked(route.secretEnv, LANGCHAIN_SECRET_NAMES, "secret");
    if (!secrets.ANTHROPIC_API_KEY && route.apiKey && route.provider !== "openai") secrets.ANTHROPIC_API_KEY = route.apiKey;
    return { PATH: "/usr/bin:/bin", HOME: host.HOME ?? "", TMPDIR: host.TMPDIR ?? "/tmp", ...secrets };
  },
  initModel(route) {
    const env = checked(route.env, MODEL_PLAIN_NAMES, "provider");
    const secretNames = Object.keys(checked(route.secretEnv, LANGCHAIN_SECRET_NAMES, "secret"));
    return {
      model: route.model, ...(route.provider ? { provider: route.provider } : {}), baseUrl: route.baseUrl,
      ...(Object.keys(env).length ? { env } : {}), ...(secretNames.length ? { secretNames } : {}),
    };
  },
  entry: (resourcesDir) => join(resourcesDir, "agent-langchain.mjs"),
};

export const HARNESSES: Record<string, HarnessAdapter> = { [claudeAgentSdk.id]: claudeAgentSdk, [langchain.id]: langchain };

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
  /** A Connect call of this turn is waiting for the owner's approval (the Chat shows a link). */
  onHeld?(held: { tool: string; holdId: string; expiresAt: string }): void;
}

export interface DefaultAgentDeps {
  /** Node binary and bundled agent entry. */
  node: string;
  entry: string;
  /** Model route + the person's own key, resolved when the agent starts (Settings → Models / setup; WP-HARNESS). */
  model(): Promise<AgentRoute>;
  /** Everything else the agent needs; no credentials. */
  config(): Promise<Omit<AgentConfig, "model">>;
  /**
   * Decide one tool call (file policy + person consent, SEC-04); message is shown to the agent on deny.
   * `connect` is set for a Connect call (C11): the person's Always/Never rules or the Connect card decide it.
   * `remember` tells the agent which standing choice decided ("always" / "never").
   */
  permission(req: { tool: string; detail: string; input: Record<string, unknown>; connect?: ConnectAsk }): Promise<{ allow: boolean; message?: string; remember?: "always" | "never" }>;
  /** For tests: spawn replacement. */
  spawnProcess?: typeof spawn;
}

interface PendingTurn extends TurnCallbacks {
  resolve(result: { sessionId: string; reply: string; selfTest?: SelfTestTools }): void;
  reject(error: Error): void;
  sessionId: string;
}

export function createDefaultAgent(deps: DefaultAgentDeps) {
  let child: ChildProcessWithoutNullStreams | null = null;
  let starting: Promise<void> | null = null;
  const turns = new Map<string, PendingTurn>();

  const send = (m: HelperToAgent) => child?.stdin.write(`${JSON.stringify(m)}\n`);
  /** The person's model credential values of the running agent: scrubbed from every text that comes back. A key
   *  split across two streamed deltas is not caught; the model never receives the key, so only whole provider
   *  error texts are expected to quote it. */
  let secretValues: string[] = [];
  const scrub = (text: string): string => secretValues.reduce((t, v) => (v.length >= 8 ? t.split(v).join("[redacted key]") : t), text);

  function failAll(message: string): void {
    for (const [id, t] of turns) { t.reject(new Error(message)); turns.delete(id); }
  }

  /** Bumped by stop(): a start still awaiting its route or config must not spawn afterwards (orphan agent). */
  let generation = 0;

  async function start(): Promise<void> {
    const gen = generation;
    const route = await deps.model();
    // WP-HARNESS seam: the adapter builds the agent's environment and init model; refuses unknown harnesses/names.
    const harness = harnessFor(route);
    const rest = await deps.config();
    const env = harness.processEnv(route, process.env);
    // A stopped start must not touch any state of the agent that replaced it (secretValues included).
    if (gen !== generation) throw new Error("The agent was stopped.");
    // A provider error can quote the key; nothing the agent sends back may carry it into Chat or the helper log.
    secretValues = Object.entries(env).filter(([name]) => MODEL_SECRET_NAMES.has(name)).map(([, value]) => value);
    const proc = (deps.spawnProcess ?? spawn)(deps.node, [harness.entry?.(dirname(deps.entry)) ?? deps.entry], { env, stdio: ["pipe", "pipe", "pipe"] }) as ChildProcessWithoutNullStreams;
    child = proc;
    proc.stderr.on("data", () => { /* agent logs stay local; never forwarded with content */ });
    const ready = new Promise<void>((resolve, reject) => {
      const lines = createInterface({ input: proc.stdout });
      lines.on("line", (line) => {
        // A process that stop() or restart() replaced may still talk for a moment: its lines are not for the new one.
        if (proc !== child) return;
        let m: AgentToHelper;
        try { m = JSON.parse(line) as AgentToHelper; } catch { return; }
        if (m.type === "ready") { resolve(); return; }
        handle(m);
      });
      proc.once("exit", (code) => {
        // Only the current process may fail the open turns. An old one that exits after restart() must not
        // end a turn of the new one (stop() already ended the turns of the old one).
        if (child !== proc) { reject(new Error("The agent was stopped.")); return; }
        child = null;
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
      else if (e.kind === "held" && typeof e.holdId === "string" && typeof e.expiresAt === "string") t.onHeld?.({ tool: String(e.tool), holdId: e.holdId, expiresAt: e.expiresAt });
    } else if (m.type === "permission_request") {
      // The consent card shows detail and input: scrubbed like every other text from the agent.
      const input = JSON.parse(scrub(JSON.stringify(m.input ?? {}))) as Record<string, unknown>;
      void deps.permission({ tool: m.tool, detail: scrub(m.detail), input, ...(m.connect ? { connect: m.connect } : {}) })
        .then((d) => send({ type: "permission", reqId: m.reqId, allow: d.allow, message: d.message, ...(d.remember ? { remember: d.remember } : {}) }))
        .catch(() => send({ type: "permission", reqId: m.reqId, allow: false }));
    } else if (m.type === "question") {
      const t = turns.get(m.id);
      if (t?.onQuestion) t.onQuestion({ reqId: m.reqId, questions: JSON.parse(scrub(JSON.stringify(m.questions ?? []))) as AgentQuestion[] });
      else send({ type: "answer", reqId: m.reqId, answers: null });
    } else if (m.type === "done") {
      const t = turns.get(m.id);
      if (t) {
        turns.delete(m.id);
        // Probe errors can quote the key like any provider error: scrubbed with the rest.
        const selfTest = m.selfTest ? (JSON.parse(scrub(JSON.stringify(m.selfTest))) as SelfTestTools) : undefined;
        t.resolve({ sessionId: m.sessionId, reply: scrub(m.reply), ...(selfTest ? { selfTest } : {}) });
      }
    } else if (m.type === "error") {
      if (!m.id) return;
      const t = turns.get(m.id);
      if (t) { turns.delete(m.id); t.reject(new Error(scrub(m.message))); }
    }
  }

  async function ensure(): Promise<void> {
    if (child) return;
    if (!starting) {
      const run: Promise<void> = start().finally(() => { if (starting === run) starting = null; });
      starting = run;
    }
    await starting;
  }

  return {
    async sendTurn(input: { text: string; content?: ContentBlock[]; sessionId?: string; selfTest?: boolean; onStart?(turnId: string): void } & TurnCallbacks): Promise<{ sessionId: string; reply: string; turnId: string; selfTest?: SelfTestTools }> {
      await ensure();
      const id = randomUUID();
      input.onStart?.(id);
      const result = await new Promise<{ sessionId: string; reply: string; selfTest?: SelfTestTools }>((resolve, reject) => {
        turns.set(id, { ...input, resolve, reject, sessionId: input.sessionId ?? "" });
        send({ type: "turn", id, text: input.text, content: input.content, sessionId: input.sessionId, ...(input.selfTest ? { selfTest: true } : {}) });
      });
      return { ...result, turnId: id };
    },
    /**
     * The setup's check of the running harness (WP-HARNESS L3, the 4 checks): the agent process starts (1), its model
     * answers (2) one round trip (3); a harness that reports them lists its tool families, each probed (4). Never
     * throws. On a timeout the turn is cancelled. Run it on a TEMPORARY agent, never on the one Chat is using.
     */
    async selfTest(timeoutMs = 90_000): Promise<{ ok: boolean; reply?: string; tools?: SelfTestTools; error?: string }> {
      let timer: ReturnType<typeof setTimeout> | undefined;
      let turnId = "";
      try {
        const run = this.sendTurn({ text: "Reply with the single word OK.", selfTest: true, onStart: (id) => { turnId = id; }, onDelta: () => {}, onActivity: () => {} });
        run.catch(() => {}); // after a timeout the cancelled turn ends with an error nobody awaits
        const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`The agent did not answer within ${Math.round(timeoutMs / 1000)} seconds.`)), timeoutMs); });
        const { reply, selfTest } = await Promise.race([run, timeout]);
        return { ok: true, reply, ...(selfTest ? { tools: selfTest } : {}) };
      } catch (error) {
        if (turnId) this.cancel(turnId);
        return { ok: false, error: error instanceof Error ? error.message : String(error) };
      } finally {
        if (timer) clearTimeout(timer);
      }
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
      generation++;
      starting = null; // a start in flight refuses to spawn (generation); the next ensure() starts afresh
      if (!child) { failAll("The agent was stopped."); return; }
      send({ type: "shutdown" });
      const c = child;
      child = null;
      setTimeout(() => c.kill("SIGTERM"), 1000).unref();
      failAll("The agent was stopped.");
    },
    /** Stop the agent process (open turns end with an error) and start it again with the current model route. */
    async restart(): Promise<void> {
      this.stop();
      try {
        await ensure();
      } catch (error) {
        // Another stop() ended this start before it spawned: the restart is still wanted; try once more.
        if (!(error instanceof Error) || error.message !== "The agent was stopped.") throw error;
        await ensure();
      }
    },
    running: () => child !== null,
  };
}

export type DefaultAgent = ReturnType<typeof createDefaultAgent>;
