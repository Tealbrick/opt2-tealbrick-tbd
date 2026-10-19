import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCli } from "../src/agent/listeningDefs.ts";

// Review #9: Listening's CLI is started with PATH and HOME only (listeningDefs.ts runCli), whatever the agent's own
// environment holds. A script that prints its environment stands in for tbd-listen.

const KEY = `fake-key-${"LISTENENV".repeat(4)}`;
const names = (printed: string) => printed.split("\n").filter(Boolean).map((l) => l.slice(0, l.indexOf("=")));

test("runCli: the CLI sees PATH and HOME and nothing else of the agent's environment", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "tbd-listen-env-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const cli = join(dir, "tbd-listen");
  writeFileSync(cli, "#!/bin/sh\n/usr/bin/env\n");
  chmodSync(cli, 0o755);
  const saved = { ...process.env };
  process.env.ANTHROPIC_API_KEY = KEY;
  process.env.OPENAI_API_KEY = KEY;
  process.env.TB_AGENT_ID = "agt_x";
  process.env.TMPDIR = "/tmp/agent";
  t.after(() => { for (const name of ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "TB_AGENT_ID"]) delete process.env[name]; process.env.TMPDIR = saved.TMPDIR; });

  const printed = await runCli(cli, []);
  const seen = names(printed);
  assert.equal(printed.includes(KEY), false, "no key value");
  // /bin/sh adds PWD, SHLVL and _ to what it starts; macOS adds __CF_USER_TEXT_ENCODING.
  const allowed = new Set(["PATH", "HOME", "PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]);
  for (const name of seen) assert.ok(allowed.has(name), `${name} reached the CLI`);
  assert.ok(seen.includes("PATH") && seen.includes("HOME"));
  assert.match(printed, /^PATH=\/usr\/bin:\/bin$/m);

  // Negative control: the same script started with the agent's own environment prints the key.
  const inherited = await new Promise<string>((resolve, reject) => execFile(cli, [], { env: process.env }, (e, out) => (e ? reject(e) : resolve(out))));
  assert.ok(inherited.includes(KEY), "the control shows the script would print a key it was given");
});
