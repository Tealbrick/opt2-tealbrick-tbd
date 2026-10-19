import { randomUUID } from "node:crypto";
import { AIMessage, HumanMessage, SystemMessage, type BaseMessage, type MessageContent as LcContent } from "@langchain/core/messages";
import type { RunnableConfig } from "@langchain/core/runnables";
import { Annotation, END, messagesStateReducer, START, StateGraph } from "@langchain/langgraph";
import type { ContentBlock } from "../../shared/message";
import type { SessionStore } from "./langchainSessions";

/**
 * The graph of TBD's LangChain agent (WP-HARNESS L1). A small explicit LangGraph StateGraph, not a prebuilt agent:
 *
 *   START → model → (tool calls and a tool seam? → tools → model) → END
 *
 * L1 has the model node only. L2 adds TBD's own MCP tools and `ask_person` through the `ToolSeam` below. The graph
 * does no I/O of its own: the model, the session store and the output hooks are all passed in, so a test can run it
 * with a fake model. It attaches no callbacks or tracers (see tracingOff.ts).
 *
 * Kept free of relative value imports (type imports only) so the tests can load it directly under Node's type stripping.
 */

export type Provider = "anthropic" | "openai";

/** What the graph needs from a chat model: a ChatAnthropic, a ChatOpenAI or a fake one. */
export interface ChatModelLike {
  invoke(input: BaseMessage[], options?: RunnableConfig): Promise<BaseMessage>;
}

export interface GraphState {
  messages: BaseMessage[];
}

/**
 * The seam for L2. `bind` returns the model with the tools bound (for example `model.bindTools(tools)`);
 * `run` executes the tool calls of the last AI message and returns the tool messages. L1 passes none.
 */
export interface ToolSeam {
  bind(model: ChatModelLike): ChatModelLike;
  run(state: GraphState, config: RunnableConfig): Promise<{ messages: BaseMessage[] }>;
  /** The line shown to the person while a tool runs ("Reading your timeline"). */
  label?(tool: string): string;
}

const State = Annotation.Root({
  messages: Annotation<BaseMessage[]>({ reducer: messagesStateReducer, default: () => [] }),
});

function hasToolCalls(message: BaseMessage | undefined): boolean {
  return AIMessage.isInstance(message) && (message.tool_calls?.length ?? 0) > 0;
}

export function buildGraph(options: { model: ChatModelLike; system?: string; tools?: ToolSeam }) {
  const { model, system, tools } = options;
  const runnable = tools ? tools.bind(model) : model;
  const modelNode = async (state: GraphState, config: RunnableConfig) => {
    const input = system ? [new SystemMessage(system), ...state.messages] : state.messages;
    // The config carries the abort signal and the stream-events handler into the model call.
    const reply = await runnable.invoke(input, config);
    // The history is merged by message id. A server that repeats an id (a fixed or reused response id) must not
    // overwrite an earlier answer, so a repeated id gets a new one.
    if (reply.id && state.messages.some((m) => m.id === reply.id)) reply.id = randomUUID();
    return { messages: [reply] };
  };
  if (!tools) {
    return new StateGraph(State).addNode("model", modelNode).addEdge(START, "model").addEdge("model", END).compile();
  }
  return new StateGraph(State)
    .addNode("model", modelNode)
    .addNode("tools", (state: GraphState, config: RunnableConfig) => tools.run(state, config))
    .addEdge(START, "model")
    .addConditionalEdges("model", (state: GraphState) => (hasToolCalls(state.messages.at(-1)) ? "tools" : END), ["tools", END])
    .addEdge("tools", "model")
    .compile();
}

// ---------------------------------------------------------------- text of messages

/** The visible text of message content: a string, or the `text` blocks of a content array (never thinking or tool blocks). */
export function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let out = "";
  for (const block of content as { type?: string; text?: unknown }[]) {
    if (block && (block.type === "text" || block.type === "text_delta") && typeof block.text === "string") out += block.text;
  }
  return out;
}

/** The user message of a turn. Anthropic takes the Chat's content blocks unchanged; OpenAI gets its own shapes. */
export function humanContent(text: string, content: ContentBlock[] | undefined, provider: Provider): LcContent {
  if (!content?.length) return text;
  if (provider === "anthropic") return content as unknown as LcContent;
  const parts: Record<string, unknown>[] = [];
  for (const block of content) {
    if (block.type === "text") parts.push({ type: "text", text: block.text });
    else if (block.type === "image") parts.push({ type: "image_url", image_url: { url: `data:${block.source.media_type};base64,${block.source.data}` } });
    else if (block.source.type === "text") parts.push({ type: "text", text: `${block.title ? `${block.title}\n\n` : ""}${block.source.data}` });
    else parts.push({ type: "text", text: `[The attached PDF${block.title ? ` "${block.title}"` : ""} cannot be read by this model.]` });
  }
  return parts as unknown as LcContent;
}

// ---------------------------------------------------------------- one turn

/** Where a turn reports to; the entry maps these to the stdio protocol's events. */
export interface TurnHooks {
  onSession(sessionId: string): void;
  onDelta(text: string): void;
  onReset(): void;
  onActivity(label: string | null): void;
}

export interface TurnInput {
  model: ChatModelLike;
  provider: Provider;
  system?: string;
  tools?: ToolSeam;
  store: SessionStore;
  /** Resume this session; absent (or not saved yet) starts one. */
  sessionId?: string;
  text: string;
  content?: ContentBlock[];
  /** One controller per turn: aborts the graph and the model call. */
  signal: AbortSignal;
  hooks: TurnHooks;
  newSessionId?: () => string;
}

function stopped(): Error {
  const error = new Error("Stopped.");
  error.name = "AbortError";
  return error;
}

/**
 * Run one turn: load the history, stream the graph (`streamEvents` v2), map model tokens to deltas, save the history.
 * The history is saved only when the turn ends with an answer; a stopped or failed turn leaves the session as it was.
 */
export async function runTurn(input: TurnInput): Promise<{ sessionId: string; reply: string }> {
  const { signal, hooks } = input;
  const sessionId = input.sessionId ?? (input.newSessionId ?? randomUUID)();
  const history = input.sessionId ? (input.store.load(sessionId) ?? []) : [];
  hooks.onSession(sessionId);
  if (signal.aborted) throw stopped();

  const graph = buildGraph({ model: input.model, system: input.system, tools: input.tools });
  const user = new HumanMessage({ content: humanContent(input.text, input.content, input.provider) });
  const events = graph.streamEvents({ messages: [...history, user] }, { version: "v2", signal, recursionLimit: 25 });

  // A model that does not honour the signal must not keep the turn open: the stop wins the race.
  let onAbort: () => void = () => {};
  const aborted = new Promise<never>((_, reject) => {
    onAbort = () => reject(stopped());
    signal.addEventListener("abort", onAbort, { once: true });
  });
  aborted.catch(() => {});

  let text = "";
  let emitted = false;
  let finalMessages: BaseMessage[] | null = null;
  let rootRunId: string | undefined;
  const iterator = events[Symbol.asyncIterator]();
  try {
    for (;;) {
      const next = await Promise.race([iterator.next(), aborted]);
      if (next.done) break;
      const event = next.value;
      if (signal.aborted) throw stopped();
      rootRunId ??= event.run_id;
      if (event.event === "on_chain_start" && event.name === "model") {
        hooks.onActivity("Thinking");
      } else if (event.event === "on_chat_model_stream") {
        const piece = contentText((event.data as { chunk?: { content?: unknown } }).chunk?.content);
        if (piece) {
          text += piece;
          emitted = true;
          hooks.onDelta(piece);
        }
      } else if (event.event === "on_chain_end" && event.name === "model") {
        // The model node ended: tool calls in its message mean the text before them was narration, not the answer.
        const message = (event.data as { output?: GraphState }).output?.messages?.at(-1);
        if (hasToolCalls(message)) {
          if (text) { text = ""; hooks.onReset(); }
          for (const call of (message as AIMessage).tool_calls ?? []) hooks.onActivity(input.tools?.label?.(call.name) ?? `Using ${call.name}`);
        }
      } else if (event.event === "on_chain_end" && event.run_id === rootRunId) {
        finalMessages = (event.data as { output?: GraphState }).output?.messages ?? null;
      }
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
    // Stop the graph if we left early (stop or error); a no-op when it finished.
    void iterator.return?.()?.catch?.(() => {});
  }
  if (signal.aborted) throw stopped();
  if (!finalMessages) throw new Error("The agent ended without an answer.");

  const last = finalMessages.at(-1);
  const reply = contentText(last?.content) || text;
  // A provider that did not stream still shows its answer.
  if (!emitted && reply) hooks.onDelta(reply);
  hooks.onActivity(null);
  input.store.save(sessionId, finalMessages);
  return { sessionId, reply };
}
