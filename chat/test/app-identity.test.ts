import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APP_BUNDLE_ID, APP_DATA_FOLDER, ARCHIVED_V1_DEV_FOLDERS, ARCHIVED_V1_FOLDERS, agentFolder, identityFolders } from "../src/main/appIdentity.ts";
import { decide, sandboxSettings, type PolicyContext } from "../src/main/filePolicy.ts";

const swift = readFileSync(new URL("../../native/Sources/TBDModels/TBDAppIdentity.swift", import.meta.url), "utf8");
const cli = readFileSync(new URL("../../companion/tools/dayflow-cli/Sources/dayflow/AppIdentity.swift", import.meta.url), "utf8");

test("the helper's app identity equals the native one (C284: own bundle id and data)", () => {
  assert.equal(APP_BUNDLE_ID, "com.tealbrick.desktop");
  assert.match(swift, new RegExp(`liveBundleID = "${APP_BUNDLE_ID.replaceAll(".", "\\.")}"`));
  assert.match(swift, /liveDataFolder = liveBundleID/);
  assert.equal(APP_DATA_FOLDER, APP_BUNDLE_ID);
  assert.match(cli, new RegExp(`tbdAppDefaultsDomain = "${APP_BUNDLE_ID}"`));
  assert.match(cli, new RegExp(`tbdAppDataFolder = "${APP_DATA_FOLDER}"`));
  assert.deepEqual([...ARCHIVED_V1_FOLDERS], ["TBD", "TBD Agent", "Dayflow"]);
  assert.match(swift, /archivedV1Folders = \["TBD", "TBD Agent", "Dayflow"\]/);
  // The native host names the agent workspace the same way (agentFolder).
  const host = readFileSync(new URL("../../companion/Dayflow/Dayflow/App/TBDChatView.swift", import.meta.url), "utf8");
  assert.equal(agentFolder("x"), "x-agent");
  assert.match(host, /TBDIdentity\.dataFolder \+ "-agent\/Workspace"/);
});

test("the agent never reads or lists the archived v1 TBD folders or the other identity's folders", () => {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "tbd-home-")));
  try {
    const support = join(home, "Library/Application Support");
    const data = join(support, APP_DATA_FOLDER);
    const workspace = join(support, agentFolder(APP_DATA_FOLDER), "Workspace");   // next to the data, not inside
    const denied = [...ARCHIVED_V1_FOLDERS, ...ARCHIVED_V1_DEV_FOLDERS, ...identityFolders().filter((f) => f !== APP_DATA_FOLDER && f !== agentFolder(APP_DATA_FOLDER))]
      .map((f) => join(support, f));
    for (const d of [workspace, data, ...denied]) mkdirSync(d, { recursive: true });
    const c: PolicyContext = { home, workspace, tbdData: data, allowed: [support], alwaysDenied: denied };
    assert.ok(denied.some((d) => d.endsWith(`${APP_DATA_FOLDER}-dev`)), "a live helper denies TBD Dev's folder");
    for (const a of [data, ...denied]) {
      assert.equal(decide("Read", { file_path: join(a, "Companion/chunks.sqlite") }, c).kind, "deny", a);
      assert.equal(decide("Bash", { command: `ls '${a}'` }, c).kind, "deny", a);
    }
    for (const a of denied) assert.ok(sandboxSettings(c).filesystem.denyRead.includes(a), a);
    if (process.platform === "darwin") {
      // Case-insensitive file system: other spellings of the archived folders are the same folders.
      assert.equal(decide("Read", { file_path: join(support, "tbd/Companion/chunks.sqlite") }, c).kind, "deny");
      assert.equal(decide("Read", { file_path: join(support, "TBD AGENT/Workspace/notes.md") }, c).kind, "deny");
      assert.equal(decide("Bash", { command: `cat "${join(support, "dayflow")}/x"` }, c).kind, "deny");
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("the agent's workspace stays usable: Read, shell and the sandbox (review WP1 S1)", () => {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "tbd-home-")));
  try {
    const support = join(home, "Library/Application Support");
    const data = join(support, APP_DATA_FOLDER);
    const workspace = join(support, agentFolder(APP_DATA_FOLDER), "Workspace");
    for (const d of [workspace, data]) mkdirSync(d, { recursive: true });
    const c: PolicyContext = { home, workspace, tbdData: data, allowed: [], alwaysDenied: ARCHIVED_V1_FOLDERS.map((f) => join(support, f)) };
    assert.equal(decide("Read", { file_path: join(workspace, "notes.md") }, c).kind, "allow");
    assert.notEqual(decide("Bash", { command: `ls '${workspace}'` }, c).kind, "deny");
    const deny = sandboxSettings(c).filesystem.denyRead;
    for (const d of deny) assert.ok(!(workspace === d || workspace.startsWith(d + "/")), `the sandbox must not deny the workspace via ${d}`);
  } finally { rmSync(home, { recursive: true, force: true }); }
});
