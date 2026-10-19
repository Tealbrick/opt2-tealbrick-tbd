// A misbehaving agent for the "key never in logs" test: it prints its whole environment and the key to stderr,
// answers the init with an error event that quotes the key, then crashes.
import { createInterface } from "node:readline";
const key = process.env.ANTHROPIC_FOUNDRY_API_KEY ?? process.env.ANTHROPIC_API_KEY ?? "";
process.stderr.write(`env dump: ${JSON.stringify(process.env)}\n`);
process.stderr.write(`Error: auth failed with key ${key}\n`);
createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.type === "init") process.stdout.write(`${JSON.stringify({ type: "ready" })}\n`);
  if (m.type === "turn") {
    process.stdout.write(`${JSON.stringify({ type: "error", id: m.id, message: `provider refused key ${key}` })}\n`);
    process.stderr.write(`fatal: key=${key}\n`);
    process.exit(1);
  }
});
