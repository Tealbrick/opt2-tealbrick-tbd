// A scripted fake Anthropic server for the Connect tests (both agent harnesses talk to it on 127.0.0.1).
// Stateless: the next step is the number of tool calls the conversation already holds, so the side requests the Claude
// executable makes (title, token count) never use up a step. A request is a "main" one when it streams and offers the
// Connect tools. Steps: a tool call each, then the final text.
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

export interface ModelStep { name: string; input: Record<string, unknown> }
export interface SeenRequest { body: Record<string, any> }
export interface FakeModel { port: number; seen: SeenRequest[]; close(): Promise<void> }

const ev = (e: unknown) => `event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`;

function stream(res: ServerResponse, step: ModelStep | null, index: number, final: string): void {
  const events = [ev({ type: "message_start", message: { id: `msg_${index}`, type: "message", role: "assistant", model: "claude-fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } })];
  if (step) {
    events.push(
      ev({ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: `toolu_${index}`, name: step.name, input: {} } }),
      ev({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(step.input) } }),
      ev({ type: "content_block_stop", index: 0 }),
    );
  } else {
    events.push(
      ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: final } }),
      ev({ type: "content_block_stop", index: 0 }),
    );
  }
  events.push(ev({ type: "message_delta", delta: { stop_reason: step ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } }), ev({ type: "message_stop" }));
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const e of events) res.write(e);
  res.end();
}

/** How many tool calls the conversation holds so far (assistant tool_use blocks). */
export function toolCallsIn(body: Record<string, any>): number {
  let n = 0;
  for (const m of body.messages ?? []) {
    if (m.role === "assistant" && Array.isArray(m.content)) n += m.content.filter((b: { type: string }) => b.type === "tool_use").length;
  }
  return n;
}

/** The text of the tool_result blocks of a request body, in order. */
export function toolResultTexts(body: Record<string, any>): string[] {
  const out: string[] = [];
  for (const m of body.messages ?? []) {
    if (!Array.isArray(m.content)) continue;
    for (const b of m.content) {
      if (b.type === "tool_result") out.push(typeof b.content === "string" ? b.content : (b.content ?? []).map((c: { text?: string }) => c.text ?? "").join(""));
    }
  }
  return out;
}

export async function fakeConnectModel(steps: ModelStep[], final = "Done."): Promise<FakeModel> {
  const seen: SeenRequest[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      if (!req.url?.startsWith("/v1/messages") || req.url.includes("count_tokens")) { res.writeHead(404).end("{}"); return; }
      const body = JSON.parse(raw || "{}") as Record<string, any>;
      const main = body.stream === true && (body.tools ?? []).some((t: { name: string }) => t.name.endsWith("connect__tools_call"));
      if (!main) {
        if (body.stream) { stream(res, null, 0, "ok"); return; }
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: "m", type: "message", role: "assistant", model: "claude-fake", content: [{ type: "text", text: "ok" }], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } }));
        return;
      }
      seen.push({ body });
      const k = toolCallsIn(body);
      stream(res, k < steps.length ? steps[k] : null, k, final);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return {
    port: (server.address() as { port: number }).port, seen,
    close: () => new Promise<void>((r) => { server.close(() => r()); server.closeAllConnections(); }),
  };
}
