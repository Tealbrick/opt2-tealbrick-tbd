import type { AgentModel } from "./protocol";

/**
 * Environment for the Claude Agent SDK's model connection. Anthropic itself needs only the base URL
 * (when set). Any other Anthropic-compatible server (local Ollama, a gateway) gets the settings the
 * Claude Code gateway rules ask for: no experimental beta fields (a non-Anthropic server may answer
 * 400), every model alias pinned to the one model the server has, and a stable system prompt so a
 * local KV cache is reused. Source: code.claude.com/docs/en/llm-gateway-protocol and model-config.
 */
export function isAnthropicHost(baseUrl: string): boolean {
  try { return new URL(baseUrl).hostname.toLowerCase() === "api.anthropic.com"; } catch { return false; }
}

/** Provider settings a model route may carry (code.claude.com docs: Bedrock, Vertex AI, Foundry; model pins).
 *  Same list as the helper's (main/defaultAgent.ts); a test keeps them equal. */
export const MODEL_PLAIN_NAMES: ReadonlySet<string> = new Set([
  "CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE",
  "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
  "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE",
  "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
]);

/** The person's own model credential: one of these names only (K3: never the person token). */
export const MODEL_SECRET_NAMES: ReadonlySet<string> = new Set(["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_FOUNDRY_API_KEY"]);

/** The gateway settings derived from the base URL (registry route: Anthropic, Anthropic-compatible, local Ollama). */
function gatewayEnv(model: AgentModel): Record<string, string> {
  if (!model.baseUrl) return {};
  if (isAnthropicHost(model.baseUrl)) return { ANTHROPIC_BASE_URL: model.baseUrl };
  return {
    ANTHROPIC_BASE_URL: model.baseUrl,
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: model.model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: model.model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model.model,
    CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
  };
}

/**
 * The model part of the agent's environment: the gateway settings from the base URL first (unchanged for every
 * registry route, review dev.10 #1), then a cloud provider's declared settings, then the person's own credential
 * from this process's environment under the names the route declared. Both lists are fixed (above); anything else
 * is dropped.
 */
export function modelEnv(model: AgentModel, own: NodeJS.ProcessEnv = {}): Record<string, string> {
  const out = gatewayEnv(model);
  for (const [name, value] of Object.entries(model.env ?? {})) if (MODEL_PLAIN_NAMES.has(name)) out[name] = value;
  for (const name of model.secretNames ?? []) if (MODEL_SECRET_NAMES.has(name) && own[name]) out[name] = own[name] as string;
  return out;
}
