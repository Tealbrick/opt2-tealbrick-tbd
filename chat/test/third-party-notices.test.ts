import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { copyrightLine, licenceText, packageDirOf } from "../scripts/third-party.ts";

// Review #10/#11: which package a bundled file belongs to, and the licence text each package ships.

test("packageDirOf: the LAST node_modules/ decides, so a nested install is its own package", () => {
  assert.equal(packageDirOf("node_modules/react/index.js"), "node_modules/react");
  assert.equal(packageDirOf("node_modules/@langchain/core/dist/x.js"), "node_modules/@langchain/core");
  assert.equal(packageDirOf("node_modules/@langchain/anthropic/node_modules/@anthropic-ai/sdk/index.mjs"), "node_modules/@langchain/anthropic/node_modules/@anthropic-ai/sdk");
  assert.equal(packageDirOf("node_modules/openai/node_modules/openai/index.js"), "node_modules/openai/node_modules/openai", "the same name nested twice");
  assert.equal(packageDirOf("/abs/chat/node_modules/p-queue/dist/index.js"), "/abs/chat/node_modules/p-queue");
  assert.equal(packageDirOf("\0/abs/chat/node_modules/scheduler/index.js?commonjs-module"), "/abs/chat/node_modules/scheduler", "rollup ids: marker and query removed");
  assert.equal(packageDirOf("src/agent/main.ts"), null);
  assert.equal(packageDirOf("node_modules/.bin/tsc"), null);
  assert.equal(packageDirOf("node_modules/@scope"), null);
});

test("copyrightLine: the author without e-mail or URL, else the package's contributors", () => {
  assert.equal(copyrightLine({ name: "a", author: "Jeremy Danyow <jdanyow@gmail.com>" }), "Copyright (c) Jeremy Danyow");
  assert.equal(copyrightLine({ name: "a", author: { name: "Standard Webhooks" } }), "Copyright (c) Standard Webhooks");
  assert.equal(copyrightLine({ name: "a", author: "LangChain (https://x.dev)" }), "Copyright (c) LangChain");
  assert.equal(copyrightLine({ name: "js-tiktoken" }), "Copyright (c) js-tiktoken contributors");
});

test("licenceText: the shipped file first; else the standard text for MIT/ISC/BSD with the copyright line; else a plain note", (t) => {
  const root = mkdtempSync(join(tmpdir(), "tbd-notices-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const pkg = (name: string, json: Record<string, unknown>, files: Record<string, string> = {}) => {
    const dir = join(root, name);
    mkdirSync(dir);
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name, version: "1.0.0", ...json }));
    for (const [f, text] of Object.entries(files)) writeFileSync(join(dir, f), text);
    return dir;
  };
  const shipped = licenceText(pkg("shipped", { license: "MIT" }, { LICENSE: "Own text\n" }));
  assert.deepEqual([shipped.source, shipped.text], ["file", "Own text"]);

  const mit = licenceText(pkg("mitpkg", { license: "MIT", author: "Ann <ann@example.com>" }));
  assert.equal(mit.source, "standard");
  assert.ok(mit.text.startsWith("MIT License\n\nCopyright (c) Ann\n\nPermission is hereby granted, free of charge"));
  assert.ok(mit.text.includes('THE SOFTWARE IS PROVIDED "AS IS"'));
  assert.ok(licenceText(pkg("nobody", { license: "MIT" })).text.includes("Copyright (c) nobody contributors"));

  assert.ok(licenceText(pkg("iscpkg", { license: "ISC" })).text.startsWith("ISC License"));
  assert.ok(licenceText(pkg("bsd2", { license: "BSD-2-Clause" })).text.startsWith("BSD 2-Clause License"));
  const bsd3 = licenceText(pkg("bsd3", { license: "BSD-3-Clause" })).text;
  assert.ok(bsd3.includes("3. Neither the name of the copyright holder"));

  const other = licenceText(pkg("apache", { license: "Apache-2.0" }));
  assert.equal(other.source, "note");
  assert.match(other.text, /Apache-2.0.*no licence file/);
});
