import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APP_BUNDLE_ID, APP_DATA_FOLDER, ARCHIVED_V1_FOLDERS } from "../src/main/appIdentity.ts";
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
});

test("the agent never reads or lists the archived v1 TBD folders", () => {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "tbd-home-")));
  try {
    const support = join(home, "Library/Application Support");
    const data = join(support, APP_DATA_FOLDER);
    const workspace = join(data, "Agent/Workspace");
    const archived = ARCHIVED_V1_FOLDERS.map((f) => join(support, f));
    for (const d of [workspace, ...archived]) mkdirSync(d, { recursive: true });
    const c: PolicyContext = { home, workspace, tbdData: data, allowed: [support], archived };
    for (const a of archived) {
      assert.equal(decide("Read", { file_path: join(a, "Companion/chunks.sqlite") }, c).kind, "deny", a);
      assert.equal(decide("Bash", { command: `ls '${a}'` }, c).kind, "deny", a);
      assert.ok(sandboxSettings(c).filesystem.denyRead.includes(a), a);
    }
    // The workspace inside the app's own folder stays usable.
    assert.equal(decide("Read", { file_path: join(workspace, "notes.md") }, c).kind, "allow");
  } finally { rmSync(home, { recursive: true, force: true }); }
});
