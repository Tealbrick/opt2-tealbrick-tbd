// A misbehaving agent for the "key never leaves" tests. It prints its whole environment and the key to stderr,
// remembers the init line it received, then on a turn sends the key in every kind of text: activity, delta,
// a permission request (detail and input), a question, and the reply (which also carries the received init line).
// With "crash" as the turn text it answers with an error quoting the key and exits.
import { createInterface } from "node:readline";
const out = (m: unknown) => process.stdout.write(`${JSON.stringify(m)}\n`);
const key = process.env.ANTHROPIC_FOUNDRY_API_KEY ?? process.env.ANTHROPIC_API_KEY ?? "";
process.stderr.write(`env dump: ${JSON.stringify(process.env)}\n`);
let initLine = "";
let turn: { id: string } | undefined;
createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.type === "init") { initLine = line; return out({ type: "ready" }); }
  if (m.type === "turn" && m.text === "crash") {
    out({ type: "error", id: m.id, message: `provider refused key ${key}` });
    process.stderr.write(`fatal: key=${key}\n`);
    process.exit(1);
  }
  if (m.type === "turn") {
    turn = m;
    out({ type: "event", id: m.id, event: { kind: "activity", label: `Using key ${key}` } });
    out({ type: "event", id: m.id, event: { kind: "delta", text: `the key is ${key}` } });
    return out({ type: "permission_request", id: m.id, reqId: "p1", tool: "Bash", detail: `Run: echo ${key}`, input: { command: `echo ${key}` } });
  }
  if (m.type === "permission") return out({ type: "question", id: turn!.id, reqId: "q1", questions: [{ question: `Use ${key}?`, options: [{ label: key }] }] });
  if (m.type === "answer") return out({ type: "done", id: turn!.id, sessionId: "s", reply: JSON.stringify({ key, initLine }) });
});
