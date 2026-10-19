import type { PreToolHookInput } from "./connectHook";

/**
 * The local-action check of the Claude Agent SDK agent (C13 local part), as a PreToolUse hook over two seams so a test can load
 * it directly (no relative value imports, per the node-test import rule).
 *
 * Why a hook: the SDK lets read-only shell commands (`ls`, `pwd`, `git status`) run without asking `canUseTool`, so a
 * "Never allow" the person chose for such a command, or a protected location in it, would never be looked at. The hook asks the
 * helper for every local call whether it is refused (a protected location, a stored Never). It never allows: a call that is not
 * refused goes on to the SDK's normal flow, where `canUseTool` shows the card.
 *
 * Fail closed: any error inside the hook (a closed pipe, a reply that does not come) is a DENY.
 */

export const LOCAL_HOOK_FAILED_MESSAGE = "TBD could not check this action, so it did not run.";

export interface LocalHookSeams {
  /** Whether the tool is one the person's local choices cover (Bash, Write, Edit, MultiEdit, NotebookEdit, WebFetch, WebSearch). */
  isLocal(tool: string): boolean;
  /** The helper's check: does a protected location or a stored Never refuse this call? May throw. */
  check(tool: string, input: Record<string, unknown>, signal: AbortSignal): Promise<{ allow: boolean; message?: string }>;
  /** TEST ONLY: true switches the check off (the negative control of the injection fixture). */
  disabled?: () => boolean;
}

type HookOutput = Record<string, never> | { hookSpecificOutput: { hookEventName: "PreToolUse"; permissionDecision: "deny"; permissionDecisionReason: string } };

const deny = (reason: string): HookOutput => ({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } });

export function localPreToolUse(seams: LocalHookSeams) {
  return async (hook: PreToolHookInput, _toolUseId: string | undefined, options: { signal: AbortSignal }): Promise<HookOutput> => {
    if (hook.hook_event_name !== "PreToolUse") return {};
    try {
      const tool = String(hook.tool_name ?? "");
      if (!seams.isLocal(tool) || seams.disabled?.() === true) return {};
      const input = (hook.tool_input && typeof hook.tool_input === "object" ? hook.tool_input : {}) as Record<string, unknown>;
      const verdict = await seams.check(tool, input, options.signal);
      return verdict.allow ? {} : deny(verdict.message ?? "The person declined this action.");
    } catch {
      return deny(LOCAL_HOOK_FAILED_MESSAGE);
    }
  };
}

// ---------------------------------------------------------------- the plan tool (flow_plan_add)

export interface FlowPlanHookSeams {
  /** Whether this call writes to the person's plan and so needs the person: `needsPermission` for the Companion plan tool. */
  needsAsk(tool: string, input: Record<string, unknown>): boolean;
  /** The helper's decision: the person's Always/Never for `flow:add`, else the card. May throw. */
  request(tool: string, input: Record<string, unknown>, signal: AbortSignal): Promise<{ allow: boolean; message?: string }>;
  /** TEST ONLY: true switches the ask off (the negative control of the injection fixture). */
  disabled?: () => boolean;
}

type FlowHookOutput = Record<string, never> | { hookSpecificOutput: { hookEventName: "PreToolUse"; permissionDecision: "allow" | "deny"; permissionDecisionReason?: string } };

/**
 * `flow_plan_add` in the Claude Agent SDK. The Companion tools are on the SDK's allow list, so the SDK never calls canUseTool for
 * them: a "save" is decided here, in a PreToolUse hook, like a Connect call. A "preview" and `flow_plan_today` pass at once.
 * "deny" is final, and so is any error inside the hook. The explicit "allow" after the person agreed keeps the SDK from asking again.
 */
export function flowPlanPreToolUse(seams: FlowPlanHookSeams) {
  return async (hook: PreToolHookInput, _toolUseId: string | undefined, options: { signal: AbortSignal }): Promise<FlowHookOutput> => {
    if (hook.hook_event_name !== "PreToolUse") return {};
    try {
      const tool = String(hook.tool_name ?? "");
      const input = (hook.tool_input && typeof hook.tool_input === "object" ? hook.tool_input : {}) as Record<string, unknown>;
      if (seams.disabled?.() === true || !seams.needsAsk(tool, input)) return {};
      const decision = await seams.request(tool, input, options.signal);
      return decision.allow
        ? { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } }
        : deny(decision.message ?? "The person declined this action.");
    } catch {
      return deny(LOCAL_HOOK_FAILED_MESSAGE);
    }
  };
}
