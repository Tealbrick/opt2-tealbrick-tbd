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

import type { AgentModel } from "./protocol";

/** Provider settings a model route may carry (code.claude.com docs: Bedrock, Vertex AI, Foundry; model pins).
 *  Same list as the helper's (main/defaultAgent.ts); a test keeps them equal. */
export const MODEL_PLAIN_NAMES: ReadonlySet<string> = new Set([
  "CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE",
  "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
  "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE",
  "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
]);

/** The person's own model credential: one of these names only (K3: never the person token). */
export const MODEL_SECRET_NAMES: ReadonlySet<string> = new Set(["ANTHROPIC_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_FOUNDRY_API_KEY"]);

export function modelEnv(model: AgentModel, own: NodeJS.ProcessEnv = {}): Record<string, string> {
  // A cloud provider (WP-HARNESS step 1): its plain settings, then the person's own credential from this process's
  // environment under the names the route declared. Both lists are fixed (above); anything else is dropped.
  if (model.env || model.secretNames) {
    const out: Record<string, string> = {};
    for (const [name, value] of Object.entries(model.env ?? {})) if (MODEL_PLAIN_NAMES.has(name)) out[name] = value;
    for (const name of model.secretNames ?? []) if (MODEL_SECRET_NAMES.has(name) && own[name]) out[name] = own[name] as string;
    if (model.baseUrl) out.ANTHROPIC_BASE_URL = model.baseUrl;
    return out;
  }
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
