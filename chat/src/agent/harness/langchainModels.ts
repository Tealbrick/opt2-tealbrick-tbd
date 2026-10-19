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

export function createChatModel(model: AgentModel, env: NodeJS.ProcessEnv): { model: ChatModelLike; provider: Provider } {
  const provider = providerOf(model);
  const name = PROVIDER_KEY_NAME[provider];
  const apiKey = env[name];
  if (!apiKey) throw new Error(`No model key is set for this agent (${name}).`);
  if (provider === "openai") {
    return {
      provider,
      model: new ChatOpenAI({
        model: model.model, apiKey, streaming: true, useResponsesApi: false, maxRetries: 2,
        ...(model.baseUrl ? { configuration: { baseURL: model.baseUrl } } : {}),
      }) as unknown as ChatModelLike,
    };
  }
  return {
    provider,
    model: new ChatAnthropic({
      model: model.model, apiKey, streaming: true, maxRetries: 2, maxTokens: 8192,
      ...(model.baseUrl ? { anthropicApiUrl: model.baseUrl } : {}),
    }) as unknown as ChatModelLike,
  };
}
