import { ChatAnthropic } from "@langchain/anthropic";
import { ChatOpenAI } from "@langchain/openai";
import type { AgentModel } from "../protocol";
import type { ChatModelLike, Provider } from "./langchainGraph";

/**
 * Chat models of TBD's LangChain agent (WP-HARNESS L1).
 *
 * - "anthropic" (default): ChatAnthropic with the person's key (ANTHROPIC_API_KEY). A base URL covers the Anthropic-
 *   compatible endpoints, and Ollama on this Mac, exactly as TBD's route does for the Agent SDK.
 * - "openai": ChatOpenAI with the person's key (OPENAI_API_KEY) and an optional base URL.
 *
 * The key comes from this process's environment under the one name the route declared; it never travels in the
 * init message. Nothing else is read from the environment.
 */

export const PROVIDER_KEY_NAME: Record<Provider, string> = { anthropic: "ANTHROPIC_API_KEY", openai: "OPENAI_API_KEY" };

export function providerOf(model: AgentModel): Provider {
  return model.provider === "openai" ? "openai" : "anthropic";
}

/**
 * LangChain counts tokens with js-tiktoken, which downloads its encoding from tiktoken.pages.dev on first use. That is
 * a request to a host that is not the model server (review #12). Both models count by an estimate instead
 * (about four characters a token) and never touch the network for it.
 */
function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

function offline<T extends object>(model: T): T {
  const m = model as unknown as {
    getNumTokens?: (content: unknown) => Promise<number>;
    getNumTokensFromMessages?: (messages: { content?: unknown }[]) => Promise<{ totalCount: number; countPerMessage: number[] }>;
  };
  m.getNumTokens = async (content) => estimateTokens(typeof content === "string" ? content : JSON.stringify(content ?? ""));
  m.getNumTokensFromMessages = async (messages) => {
    const countPerMessage = messages.map((x) => estimateTokens(typeof x.content === "string" ? x.content : JSON.stringify(x.content ?? "")) + 3);
    return { totalCount: countPerMessage.reduce((a, b) => a + b, 0) + 3, countPerMessage };
  };
  return model;
}

export function createChatModel(model: AgentModel, env: NodeJS.ProcessEnv): { model: ChatModelLike; provider: Provider } {
  const provider = providerOf(model);
  const name = PROVIDER_KEY_NAME[provider];
  const apiKey = env[name];
  if (!apiKey) throw new Error(`No model key is set for this agent (${name}).`);
  if (provider === "openai") {
    return {
      provider,
      model: offline(new ChatOpenAI({
        model: model.model, apiKey, streaming: true, useResponsesApi: false, maxRetries: 2,
        ...(model.baseUrl ? { configuration: { baseURL: model.baseUrl } } : {}),
      })) as unknown as ChatModelLike,
    };
  }
  return {
    provider,
    model: offline(new ChatAnthropic({
      model: model.model, apiKey, streaming: true, maxRetries: 2, maxTokens: 8192,
      ...(model.baseUrl ? { anthropicApiUrl: model.baseUrl } : {}),
    })) as unknown as ChatModelLike,
  };
}
