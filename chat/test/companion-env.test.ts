import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { APP_SUPPORT_ENV, companionEnv } from "../src/agent/companionEnv.ts";

// dev.17 review S8: the agent tells the Companion MCP server which app's data folder to use (TBD_APP_SUPPORT_DIR), so TBD Dev's
// agent writes into the "-dev" folder. The CLI side (env -> path) is tested in the Swift tests (TBDAppSupportEnvTests).

test("the Companion server gets HOME and the app's data folder, nothing else", () => {
  const env = companionEnv({ companionDataDir: "/Users/x/Library/Application Support/com.tealbrick.desktop-dev" }, { HOME: "/Users/x", ANTHROPIC_API_KEY: "sk-test-not-real", PATH: "/usr/bin" });
  assert.deepEqual(env, { HOME: "/Users/x", TBD_APP_SUPPORT_DIR: "/Users/x/Library/Application Support/com.tealbrick.desktop-dev" });
  assert.equal(APP_SUPPORT_ENV, "TBD_APP_SUPPORT_DIR");
});

test("the live app's data folder is passed as it is (live and dev are different values)", () => {
  const live = companionEnv({ companionDataDir: "/Users/x/Library/Application Support/com.tealbrick.desktop" }, { HOME: "/Users/x" });
  const dev = companionEnv({ companionDataDir: "/Users/x/Library/Application Support/com.tealbrick.desktop-dev" }, { HOME: "/Users/x" });
  assert.notEqual(live.TBD_APP_SUPPORT_DIR, dev.TBD_APP_SUPPORT_DIR);
  assert.match(dev.TBD_APP_SUPPORT_DIR, /com\.tealbrick\.desktop-dev$/);
});

test("no folder, or a relative one: HOME only (the CLI would ignore a relative path anyway)", () => {
  assert.deepEqual(companionEnv({}, { HOME: "/h" }), { HOME: "/h" });
  assert.deepEqual(companionEnv({ companionDataDir: "relative/dir" }, { HOME: "/h" }), { HOME: "/h" });
  assert.deepEqual(companionEnv({ companionDataDir: "" }, {}), { HOME: "" });
});

test("both harnesses build the Companion server's environment with companionEnv, and the helper sets the data folder", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const read = (p: string) => readFileSync(join(here, "..", p), "utf8");
  assert.match(read("src/agent/main.ts"), /name: "companion"|servers\.companion = \{[^}]*env: companionEnv\(c\)/);
  assert.match(read("src/agent/main.ts"), /env: companionEnv\(c\)/);
  assert.match(read("src/agent/harness/langchain.ts"), /name: "companion"[^;]*env: companionEnv\(c\)/);
  const services = read("src/main/services.ts");
  assert.match(services, /companionDataDir: appDataDir\(\)/);
  assert.match(services, /process\.env\.TBD_CHAT_DATA \? dirname\(process\.env\.TBD_CHAT_DATA\)/, "the data folder is the parent of the Chat data folder, which the app sets for its own identity");
});
