// A fake stdio MCP server for the LangChain agent tests. Usage: fake-mcp.ts <envFile> <toolName> [more args ignored].
// It records the environment it was started with (the dev.11 isolation check), answers the MCP handshake, lists one
// tool and answers every call with a text result that echoes the tool name and its arguments.
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [envFile, toolName, mode] = process.argv.slice(2);
writeFileSync(envFile, JSON.stringify(process.env));
const reply = (id: unknown, result: unknown) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
createInterface({ input: process.stdin }).on("line", (line) => {
  let m: { id?: unknown; method?: string; params?: { protocolVersion?: string; name?: string; arguments?: unknown } };
  try { m = JSON.parse(line); } catch { return; }
  if (m.method === "initialize") {
    reply(m.id, { protocolVersion: m.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake-mcp", version: "0" } });
  } else if (m.method === "tools/list") {
    reply(m.id, { tools: [{
      name: toolName, description: `Fake ${toolName}`,
      inputSchema: { type: "object", properties: { query: { type: "string" } }, additionalProperties: true },
      annotations: { readOnlyHint: true },
    }] });
  } else if (m.method === "tools/call") {
    if (mode === "die-on-call") process.exit(1); // the server dies in the middle of a call
    reply(m.id, { content: [{ type: "text", text: `${m.params?.name} result for ${JSON.stringify(m.params?.arguments ?? {})}` }] });
  } else if (m.id !== undefined && m.method) {
    reply(m.id, {});
  }
});
