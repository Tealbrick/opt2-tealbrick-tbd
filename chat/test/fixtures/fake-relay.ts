// Stands in for the Teal Brick relay (a stdio MCP server): records the environment Claude Code gave it, then answers
// the MCP handshake with no tools (so the session does not wait for a connection timeout).
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
writeFileSync(process.argv[2], JSON.stringify(process.env));
const reply = (id: unknown, result: unknown) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
createInterface({ input: process.stdin }).on("line", (line) => {
  let m: { id?: unknown; method?: string; params?: { protocolVersion?: string } };
  try { m = JSON.parse(line); } catch { return; }
  if (m.method === "initialize") reply(m.id, { protocolVersion: m.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake-relay", version: "0" } });
  else if (m.method === "tools/list") reply(m.id, { tools: [] });
  else if (m.id !== undefined && m.method) reply(m.id, {});
});
