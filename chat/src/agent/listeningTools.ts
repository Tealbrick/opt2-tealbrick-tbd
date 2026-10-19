import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { LISTENING_INSTRUCTIONS, LISTENING_TOOLS, listeningFailure, runCli } from "./listeningDefs";

/**
 * Listening as an in-process MCP server of the Agent SDK harness (C5). The tool definitions and `runCli` are shared
 * with the LangChain harness (listeningDefs.ts); behaviour here is unchanged.
 */
export { runCli };

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
const failure = (e: unknown) => ({ content: [{ type: "text" as const, text: listeningFailure(e) }], isError: true });

export function listeningServer(cli: string) {
  return createSdkMcpServer({
    name: "listening",
    version: "1.0.0",
    instructions: LISTENING_INSTRUCTIONS,
    tools: LISTENING_TOOLS.map((def) =>
      tool(def.name, def.description, def.shape, async (args: Record<string, unknown>) => { try { return text(await def.run(args, cli)); } catch (e) { return failure(e); } },
        { annotations: { readOnlyHint: true } })),
  });
}
