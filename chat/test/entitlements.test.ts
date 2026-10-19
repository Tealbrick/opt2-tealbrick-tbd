import test from "node:test";
import assert from "node:assert/strict";
import type { Instance, Licence } from "@opt2-tealbrick/spec/routes";
import { availabilityText, computeEntitlements, createEntitlements, shapeOf } from "../src/main/entitlements.ts";

const WS = "ws_1";
function licence(product: string, over: Partial<Licence> = {}): Licence {
  return {
    id: `lic_${product}`, product, major: 0, status: "active", offerId: "ofr_1", orderId: "ord_1", fromBundle: false,
    assignment: { ws: WS, workspaceName: "Mine", assignedAt: "2026-10-19T00:00:00Z" }, livemode: true, createdAt: "2026-10-19T00:00:00Z",
    ...over,
  } as Licence;
}
function instance(product: string, over: Partial<Instance> = {}): Instance {
  return { id: `ins_${product}`, ws: WS, product, state: "running", licensed: true, pendingHolds: 0, ...over } as Instance;
}

test("C282: paid + installed + running unlocks; paid only asks to install; not paid is locked", () => {
  const s = computeEntitlements(WS, [licence("rules"), licence("kanban")], [instance("rules"), instance("connect", { licensed: false })], 5);
  assert.equal(s.apps.rules.access, "unlocked");
  assert.equal(s.apps.kanban.access, "install", "paid, not installed");
  assert.equal(s.apps.connect.access, "locked", "deployed but not paid stays locked");
  assert.equal(s.apps.knowledge.access, "locked");
  assert.equal(s.fetchedAt, 5);
});

test("C282: only an active licence assigned to THIS workspace counts (Core's isEntitled rule)", () => {
  const other = { ws: "ws_2", workspaceName: "Other", assignedAt: "2026-10-19T00:00:00Z" };
  const s = computeEntitlements(WS, [
    licence("rules", { assignment: other }),
    licence("inbox", { status: "refunded" }),
    licence("knowledge", { assignment: null }),
  ], [instance("rules"), instance("inbox"), instance("knowledge")], 1);
  assert.equal(s.apps.rules.access, "locked");
  assert.equal(s.apps.inbox.access, "locked");
  assert.equal(s.apps.knowledge.access, "locked");
});

test("C282: an installed app that is not running (deploying, failed, unlicensed instance) is 'install', not unlocked", () => {
  const s = computeEntitlements(WS, [licence("rules"), licence("inbox"), licence("connect")],
    [instance("rules", { state: "deploying" }), instance("inbox", { state: "failed" }), instance("connect", { licensed: false })], 1);
  assert.deepEqual([s.apps.rules.access, s.apps.inbox.access, s.apps.connect.access], ["install", "install", "install"]);
  assert.equal(availabilityText("rules", "install"), "Install Rules & Approvals in Portal to use this.");
  assert.equal(availabilityText("kanban", "locked"), "Available with Task Board.");
  assert.equal(availabilityText("rules", "unlocked"), null);
});

test("C282: a failed read keeps the last good snapshot (a Portal outage never locks paid functions) and never unlocks", async () => {
  let fail = false;
  const ent = createEntitlements({
    licences: async () => { if (fail) throw new Error("Portal answered 503"); return [licence("rules")]; },
    instances: async () => ({ items: [instance("rules")] }),
    now: () => 10,
  });
  assert.equal((await ent.refresh(WS)).apps.rules.access, "unlocked");
  fail = true;
  const kept = await ent.refresh(WS);
  assert.equal(kept.apps.rules.access, "unlocked");
  assert.equal(kept.error, "Portal answered 503");
  // A different workspace with a failed read: nothing is unlocked.
  const other = await ent.refresh("ws_2");
  assert.equal(other.ws, "ws_2");
  assert.equal(other.apps.rules.access, "locked");
  assert.equal((await ent.refresh(null)).ws, null);
});

test("C282 proof log: field names and counts only, never values", async () => {
  const lines: string[] = [];
  const ent = createEntitlements({
    licences: async () => [licence("rules", { id: "lic_SECRETVALUE" as Licence["id"] })],
    instances: async () => ({ items: [instance("rules")] }),
    log: (l) => lines.push(l),
  });
  await ent.refresh(WS);
  assert.equal(lines.length, 1);
  assert.match(lines[0]!, /licences \[1\]\{assignment\{assignedAt,workspaceName,ws\},createdAt,fromBundle,id,/);
  assert.ok(!lines[0]!.includes("SECRETVALUE") && !lines[0]!.includes(WS) && !lines[0]!.includes("rules"), lines[0]);
  assert.equal(shapeOf([]), "[0]");
});
