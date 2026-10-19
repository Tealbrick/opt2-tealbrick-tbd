import type { ConnectAsk } from "./protocol";

/**
 * The Connect consent hook of the Claude Agent SDK agent (C280 C11), as a function over two seams so a test can load it
 * directly (no relative value imports, per the node-test import rule): `route` is main/connectConsent.ts `routeOf`,
 * `request` is the agent's permission round trip to the helper.
 *
 * Fail closed: any error inside the hook (a classifier that throws, arguments too deep to read or to send, a closed pipe)
 * is a DENY. A hook that throws is not a refusal for the SDK, so the call would run without the card.
 */

export const HOOK_FAILED_MESSAGE = "TBD could not check this action with you, so it did not run.";

export interface PreToolHookInput {
  hook_event_name: string;
  tool_name?: string;
  tool_input?: unknown;
}

export interface ConnectHookSeams {
  /** The ask for any Connect call (free or not), or undefined for a call that is not a Connect call. May throw. */
  route(tool: string, input: Record<string, unknown>): ConnectAsk | undefined;
  /** The helper's decision (rules or card). May throw. */
  request(tool: string, input: Record<string, unknown>, signal: AbortSignal, ask: ConnectAsk): Promise<{ allow: boolean; message?: string }>;
}

type HookOutput = Record<string, never> | { hookSpecificOutput: { hookEventName: "PreToolUse"; permissionDecision: "allow" | "deny"; permissionDecisionReason?: string } };

const deny = (reason: string): HookOutput => ({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } });

export function connectPreToolUse(seams: ConnectHookSeams) {
  return async (hook: PreToolHookInput, _toolUseId: string | undefined, options: { signal: AbortSignal }): Promise<HookOutput> => {
    if (hook.hook_event_name !== "PreToolUse") return {};
    try {
      const tool = String(hook.tool_name ?? "");
      const input = (hook.tool_input && typeof hook.tool_input === "object" ? hook.tool_input : {}) as Record<string, unknown>;
      const ask = seams.route(tool, input);
      if (!ask) return {};
      const decision = await seams.request(tool, input, options.signal, ask);
      return decision.allow
        ? { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } }
        : deny(decision.message ?? "The person declined this action.");
    } catch {
      return deny(HOOK_FAILED_MESSAGE);
    }
  };
}
