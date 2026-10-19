import { randomUUID } from "node:crypto";
import { AIMessage, ToolMessage, type BaseMessage } from "@langchain/core/messages";
import type { RunnableConfig } from "@langchain/core/runnables";
import { tool, type StructuredToolInterface } from "@langchain/core/tools";
import { MultiServerMCPClient } from "@langchain/mcp-adapters";
import { z } from "zod";
import type { ListeningToolDef } from "../listeningDefs";
import type { AgentQuestion, AgentToHelper } from "../protocol";
import type { ChatModelLike, GraphState, ToolSeam } from "./langchainGraph";

/**
 * Tools of TBD's LangChain agent (WP-HARNESS L2): the same families, with the same names, as the Agent SDK agent,
 * so `needsPermission` and the consent rules apply unchanged.
 *
 *   mcp__companion__*   Companion timeline: stdio MCP server `<companionCli> mcp`, env { HOME } only
 *   mcp__listening__*   Listening: native LangChain tools over the shared definitions (listeningDefs.ts)
 *   mcp__tealbrick__*   Teal Brick relay: stdio MCP server, exactly config.relay.env, only when connected
 *   ask_person          asks the person on a question card (protocol `question` / `answer`)
 *
 * No shell, file or web tools. Every call goes through `gate` (permission_request / permission) before it runs.
 *
 * The MCP client always adds HOME, LOGNAME, PATH, SHELL, TERM and USER from THIS process's environment under the
 * explicit env of a server. This process's environment is PATH, HOME, TMPDIR and the model key (see the adapter in
 * main/defaultAgent.ts), so the model key can never reach a child; test/langchain-tools-env.test.ts proves it.
 *
 * Kept free of relative value imports (type imports only) so the tests can load it directly under Node's type stripping.
 */

export const ASK_PERSON = "ask_person";

/** The line shown to the person while a tool runs (same wording as the SDK agent). */
export function toolLabel(name: string): string {
  if (name === ASK_PERSON) return "Asking you a question";
  if (name.startsWith("mcp__companion__")) return "Reading your timeline";
  if (name.startsWith("mcp__listening__")) return "Reading your transcripts";
  if (name.startsWith("mcp__tealbrick__")) return "Using a Teal Brick app";
  return `Using ${name}`;
}

// ---------------------------------------------------------------- permission and question round trips

export interface PermissionPolicy {
  /** protocol.needsPermission: whether TBD's helper must decide this call. */
  needsPermission(tool: string): boolean;
  /** protocol.describeToolCall: one line for the consent card. */
  describe(tool: string, input: Record<string, unknown>): string;
}

export interface Decision { allow: boolean; message?: string }

/**
 * The agent's side of `permission_request` / `permission` and `question` / `answer`: sends the request for a turn and
 * waits for the helper's reply. A stopped turn answers "no" / "not answered". Replies come in through `onPermission`
 * and `onAnswer`.
 */
export function createInteractions(send: (m: AgentToHelper) => void, policy: PermissionPolicy) {
  let next = 0;
  const permissions = new Map<string, (d: Decision) => void>();
  const answers = new Map<string, (a: Record<string, string> | null) => void>();
  const wait = <T>(map: Map<string, (v: T) => void>, reqId: string, signal: AbortSignal | undefined, onAbort: T): Promise<T> =>
    new Promise<T>((resolve) => {
      if (signal?.aborted) { resolve(onAbort); return; }
      map.set(reqId, resolve);
      signal?.addEventListener("abort", () => resolve(onAbort), { once: true });
    }).finally(() => { map.delete(reqId); });
  return {
    /** Decide one tool call: free when `needsPermission` says so, else the person decides on the consent card. */
    async gate(turnId: string, name: string, input: Record<string, unknown>, signal?: AbortSignal): Promise<Decision> {
      if (!policy.needsPermission(name)) return { allow: true };
      const reqId = `p${++next}`;
      send({ type: "permission_request", id: turnId, reqId, tool: name, detail: policy.describe(name, input), input });
      return wait(permissions, reqId, signal, { allow: false, message: "Turn stopped." });
    },
    /** Ask the person; `null` = not answered (declined, stopped, timed out). */
    async ask(turnId: string, questions: AgentQuestion[], signal?: AbortSignal): Promise<Record<string, string> | null> {
      const reqId = `q${++next}`;
      send({ type: "question", id: turnId, reqId, questions });
      return wait(answers, reqId, signal, null);
    },
    onPermission(m: { reqId: string; allow: boolean; message?: string }): void { permissions.get(m.reqId)?.({ allow: m.allow, message: m.message }); },
    onAnswer(m: { reqId: string; answers: Record<string, string> | null }): void { answers.get(m.reqId)?.(m.answers); },
  };
}

// ---------------------------------------------------------------- the tool seam

export interface SeamOptions {
  tools: StructuredToolInterface[];
  /** Decides each call before it runs (see createInteractions.gate). */
  gate(name: string, input: Record<string, unknown>, signal?: AbortSignal): Promise<Decision>;
  /** Tools that ask the person themselves and so skip the gate (ask_person). */
  ungated?: ReadonlySet<string>;
}

const failed = (id: string, name: string, text: string) => new ToolMessage({ tool_call_id: id, name, content: text, status: "error" });

/** The L1 `ToolSeam` filled in: bind the tools to the model, run the calls of the last AI message one by one. */
export function createToolSeam(options: SeamOptions): ToolSeam {
  const byName = new Map(options.tools.map((t) => [t.name, t]));
  return {
    label: toolLabel,
    bind(model: ChatModelLike): ChatModelLike {
      const bindable = model as unknown as { bindTools?: (tools: StructuredToolInterface[]) => ChatModelLike };
      if (!bindable.bindTools) throw new Error("This model cannot use tools.");
      return options.tools.length > 0 ? bindable.bindTools(options.tools) : model;
    },
    async run(state: GraphState, config: RunnableConfig): Promise<{ messages: BaseMessage[] }> {
      const last = state.messages.at(-1);
      const messages: BaseMessage[] = [];
      for (const call of AIMessage.isInstance(last) ? (last.tool_calls ?? []) : []) {
        const id = call.id ?? randomUUID();
        if (config.signal?.aborted) break;
        const found = byName.get(call.name);
        if (!found) { messages.push(failed(id, call.name, `There is no tool named ${call.name}.`)); continue; }
        const args = (call.args ?? {}) as Record<string, unknown>;
        if (!options.ungated?.has(call.name)) {
          const decision = await options.gate(call.name, args, config.signal);
          if (!decision.allow) { messages.push(failed(id, call.name, decision.message ?? "The person declined this action.")); continue; }
        }
        try {
          const result = await found.invoke({ id, name: call.name, args, type: "tool_call" }, config);
          messages.push(ToolMessage.isInstance(result) ? result : new ToolMessage({ tool_call_id: id, name: call.name, content: typeof result === "string" ? result : JSON.stringify(result) }));
        } catch (error) {
          if (config.signal?.aborted) break; // the turn was stopped; the graph ends it
          messages.push(failed(id, call.name, `Tool error: ${error instanceof Error ? error.message : String(error)}`));
        }
      }
      return { messages };
    },
  };
}

// ---------------------------------------------------------------- tools

const QUESTIONS = z.object({
  questions: z.array(z.object({
    question: z.string().min(1).describe("The full question, ending with a question mark."),
    header: z.string().max(12).optional().describe("A very short label for the question card."),
    options: z.array(z.object({ label: z.string().min(1), description: z.string().optional() })).min(2).max(4).describe("The choices. The person can always answer in their own words."),
    multiSelect: z.boolean().optional(),
  })).min(1).max(4),
});

/** `ask_person`: put 1 to 4 questions to the person on TBD's question cards; the answers come back keyed by question. */
export function askPersonTool(ask: (questions: AgentQuestion[], signal?: AbortSignal) => Promise<Record<string, string> | null>): StructuredToolInterface {
  return tool(
    async (input, config) => {
      const answers = await ask(input.questions as AgentQuestion[], config?.signal);
      return answers ? JSON.stringify(answers) : "The person did not answer.";
    },
    {
      name: ASK_PERSON,
      description: "Ask the person one to four questions when you need a choice or a fact only they can give. Each question has two to four options; they can also answer in their own words.",
      schema: QUESTIONS,
    },
  ) as unknown as StructuredToolInterface;
}

/** Listening as native LangChain tools: the shared definitions, the same CLI call, names mcp__listening__<name>. */
export function listeningTools(defs: ListeningToolDef[], cli: string, failure: (e: unknown) => string, exec?: (cli: string, args: string[]) => Promise<string>): StructuredToolInterface[] {
  return defs.map((def) =>
    tool(
      async (input) => {
        try { return await def.run(input as Record<string, unknown>, cli, exec); } catch (e) { return failure(e); }
      },
      { name: `mcp__listening__${def.name}`, description: def.description, schema: z.object(def.shape) },
    ) as unknown as StructuredToolInterface);
}

// ---------------------------------------------------------------- MCP servers

export interface McpServerSpec {
  /** "companion" or "tealbrick"; tools are named mcp__<name>__<tool>. */
  name: string;
  command: string;
  args: string[];
  /** The explicit environment of the server process. */
  env: Record<string, string>;
}

export interface LoadedTools { tools: StructuredToolInterface[]; close(): Promise<void> }

/**
 * Start one stdio MCP server and list its tools. A server that does not start, does not answer in time or has no tools
 * is simply absent (`null`, with a note through `log`): it never stops the agent. One client per server, so one failure
 * leaves the other families alone.
 */
export async function loadMcpServer(spec: McpServerSpec, log: (note: string) => void, timeoutMs = 20_000): Promise<LoadedTools | null> {
  const client = new MultiServerMCPClient({
    servers: { [spec.name]: { transport: "stdio", command: spec.command, args: spec.args, env: spec.env, stderr: "inherit" } },
    prefixToolNameWithServerName: true,
    additionalToolNamePrefix: "mcp",
    onConnectionError: "ignore",
    throwOnLoadError: false,
  });
  const close = () => client.close().catch(() => {});
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const tools = await Promise.race([
      client.listTools(),
      new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("no answer in time")), timeoutMs); }),
    ]);
    if (tools.length === 0) { log(`tools of ${spec.name} are not available (the server did not start or has no tools)`); void close(); return null; }
    return { tools: tools as unknown as StructuredToolInterface[], close };
  } catch (error) {
    log(`tools of ${spec.name} are not available (${error instanceof Error ? error.message : String(error)})`);
    // Not awaited: closing a connection that never answered can take as long as the client's own request timeout.
    void close();
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}
