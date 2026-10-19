import test from "node:test";
import assert from "node:assert/strict";
import type { Instance, Licence } from "@opt2-tealbrick/spec/routes";
import { availabilityText, checkShape, computeEntitlements, createEntitlements, shapeOf } from "../src/main/entitlements.ts";

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
  // A different workspace with a failed read: nothing is unlocked, and nothing is locked either (fail-safe: unknown).
  const other = await ent.refresh("ws_2");
  assert.equal(other.ws, "ws_2");
  assert.equal(other.apps.rules.access, "unknown");
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

// Fail-safe (Coordinator, dev.12): an unreadable or unexpected plan never locks a function.
test("fail-safe: a read error with no good read gives unknown (never locked); unknown shows no lock text", async () => {
  const ent = createEntitlements({ licences: async () => { throw new Error("502"); }, instances: async () => ({ items: [] }), now: () => 9 });
  const s = await ent.refresh(WS);
  for (const app of Object.values(s.apps)) assert.equal(app.access, "unknown");
  assert.equal(s.error, "502");
  assert.equal(availabilityText("knowledge", "unknown"), null);
});

test("fail-safe: an unexpected shape is unknown, not locked; the last good read for the workspace is kept", async () => {
  let shape: "good" | "bad" = "bad";
  const ent = createEntitlements({
    licences: async () => (shape === "good" ? [licence("knowledge")] : ([{ product: 7 }] as unknown as Licence[])),
    instances: async () => ({ items: [instance("knowledge")] }), now: () => 1,
  });
  assert.equal((await ent.refresh(WS)).apps.knowledge.access, "unknown");
  shape = "good";
  assert.equal((await ent.refresh(WS)).apps.knowledge.access, "unlocked");
  shape = "bad";
  const kept = await ent.refresh(WS);
  assert.equal(kept.apps.knowledge.access, "unlocked", "the last good read stays");
  assert.match(kept.error ?? "", /unexpected licences shape/);
});

test("fail-safe: checkShape accepts the contract's rows and refuses others", () => {
  checkShape([licence("rules"), licence("inbox", { assignment: null })], [instance("rules")]);
  assert.throws(() => checkShape({ items: [] }, []), /licences/);
  assert.throws(() => checkShape([], [{ product: "rules", ws: WS, state: "running" }]), /instances/);
});

test("fail-safe: no workspace selected is unknown, not locked (review dev.12 #2)", async () => {
  const ent = createEntitlements({ licences: async () => [], instances: async () => ({ items: [] }) });
  const s = await ent.refresh(null);
  assert.equal(s.ws, null);
  for (const app of Object.values(s.apps)) assert.equal(app.access, "unknown");
  assert.equal(availabilityText("knowledge", s.apps.knowledge.access), null);
  // Before any read the cache is unknown too.
  assert.equal(createEntitlements({ licences: async () => [], instances: async () => ({ items: [] }) }).current().apps.knowledge.access, "unknown");
});

test("a failed read is retried after 1 min, a good one after 10 min, a new workspace at once (review dev.12 #7)", async () => {
  let t = 1_000_000;
  let fail = true;
  const ent = createEntitlements({
    licences: async () => { if (fail) throw new Error("503"); return [licence("rules")]; },
    instances: async () => ({ items: [instance("rules")] }), now: () => t,
  });
  await ent.refresh(WS);
  assert.equal(ent.isStale(WS, t + 30_000), false, "no retry storm during an outage");
  assert.equal(ent.isStale(WS, t + 61_000), true);
  fail = false;
  t += 61_000;
  await ent.refresh(WS);
  assert.equal(ent.isStale(WS, t + 5 * 60_000), false);
  assert.equal(ent.isStale(WS, t + 11 * 60_000), true);
  assert.equal(ent.isStale("ws_2", t + 1), true, "a workspace switch reads at once");
});

test("a late answer for a workspace the person left never overwrites the newer one (review dev.12 #8)", async () => {
  let releaseA: () => void = () => {};
  const ent = createEntitlements({
    licences: async () => [licence("rules")],
    instances: async (ws) => {
      if (ws === WS) await new Promise<void>((r) => { releaseA = r; });
      return { items: ws === WS ? [instance("rules")] : [] };
    },
  });
  const a = ent.refresh(WS);
  await new Promise((r) => setTimeout(r, 5));
  await ent.refresh("ws_2");
  releaseA();
  await a;
  assert.equal(ent.current().ws, "ws_2");
});
