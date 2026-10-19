// Fake default agent for tests: speaks the helper<->agent protocol.
import { createInterface } from "node:readline";
const out = (m: unknown) => process.stdout.write(`${JSON.stringify(m)}\n`);
const env = { hasKey: process.env.ANTHROPIC_API_KEY === "sk-test", leaked: Object.keys(process.env).filter((k) => /TOKEN|TBO|PORTAL|SECRET/i.test(k)) };
createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.type === "init") return out({ type: "ready" });
  // Like the real agents: leave 300 ms after "shutdown".
  if (m.type === "shutdown") return void setTimeout(() => process.exit(0), 300);
  if (m.type === "turn" && m.text === "quick") return out({ type: "done", id: m.id, sessionId: "sess-q", reply: "quick" });
  if (m.type === "turn" && m.text === "slow") return void setTimeout(() => out({ type: "done", id: m.id, sessionId: "sess-s", reply: "slow done" }), 900);
  if (m.type === "turn" && m.text === "ask") {
    (globalThis as any).asking = m;
    return out({ type: "question", id: m.id, reqId: "q1", questions: [{ question: "Which day?", options: [{ label: "Today" }, { label: "Yesterday" }] }] });
  }
  if (m.type === "answer") {
    const t = (globalThis as any).asking;
    return out({ type: "done", id: t.id, sessionId: "sess-1", reply: JSON.stringify({ reqId: m.reqId, answers: m.answers }) });
  }
  if (m.type === "turn" && m.content) {
    return out({ type: "done", id: m.id, sessionId: "sess-1", reply: JSON.stringify(m.content) });
  }
  if (m.type === "turn") {
    out({ type: "event", id: m.id, event: { kind: "session", sessionId: "sess-1" } });
    out({ type: "event", id: m.id, event: { kind: "activity", label: "Thinking" } });
    out({ type: "event", id: m.id, event: { kind: "delta", text: "Hello " } });
    out({ type: "permission_request", id: m.id, reqId: "p1", tool: "Bash", detail: "Run: ls", input: { command: "ls" } });
    (globalThis as any).pending = m;
  }
  if (m.type === "permission") {
    const t = (globalThis as any).pending;
    out({ type: "event", id: t.id, event: { kind: "delta", text: m.allow ? "allowed" : "denied" } });
    out({ type: "done", id: t.id, sessionId: "sess-1", reply: `${t.text}|${m.allow}|${JSON.stringify(env)}` });
  }
});
