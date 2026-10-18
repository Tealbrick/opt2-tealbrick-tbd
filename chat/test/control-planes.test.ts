import test from "node:test";
import assert from "node:assert/strict";
import {
  BUILT_IN_CONTROL_PLANES, COMPANY_CONTROL_PLANE, DEV_CONTROL_PLANE, profileIdForIssuer, profileUserData, sanitizeControlPlaneRegistry,
} from "../src/main/controlPlaneProfiles.ts";
import { DEFAULT_ISSUER } from "../src/shared/controlPlanes.ts";
import { parsePersonSession } from "../src/main/portal.ts";

const custom = { name: "Acme Portal", issuer: "https://portal.acme.example" };

test("C257: the hosted Portal is the built-in default; dev is built in but not the default", () => {
  assert.deepEqual({ ...COMPANY_CONTROL_PLANE }, { id: "tealbrick", name: "Teal Brick Portal", issuer: "https://portal.tealbrick.com", builtIn: true });
  assert.equal(DEFAULT_ISSUER, COMPANY_CONTROL_PLANE.issuer);
  assert.equal(DEV_CONTROL_PLANE.issuer, "https://dev.tealbrick.com");
  for (const empty of [null, undefined, {}, "garbage", 42, { profiles: "x" }]) {
    const state = sanitizeControlPlaneRegistry(empty);
    assert.equal(state.activeId, "tealbrick");
    assert.deepEqual(state.profiles.map((p) => p.id), ["tealbrick", "tealbrick-dev"]);
  }
});

test("a saved choice is kept: dev, a custom portal, or the v1 0.1.5 registry", () => {
  assert.equal(sanitizeControlPlaneRegistry({ version: 1, activeId: "tealbrick-dev", profiles: [] }).activeId, "tealbrick-dev");
  const withCustom = sanitizeControlPlaneRegistry({ version: 1, activeId: profileIdForIssuer(custom.issuer), profiles: [custom] });
  assert.equal(withCustom.activeId, profileIdForIssuer(custom.issuer));
  assert.equal(withCustom.profiles.length, 3);
  // v1 0.1.5 wrote the same file; its built-in "tealbrick" was already portal.tealbrick.com.
  assert.equal(sanitizeControlPlaneRegistry({ version: 1, activeId: "tealbrick", profiles: [custom] }).activeId, "tealbrick");
  // An unknown saved id falls back to the default instead of failing.
  assert.equal(sanitizeControlPlaneRegistry({ version: 1, activeId: "plane-gone", profiles: [] }).activeId, "tealbrick");
});

test("a custom entry for a built-in origin collapses into the built-in and keeps its data folder", () => {
  const dev = { name: "My dev", issuer: "https://dev.tealbrick.com/" };
  const state = sanitizeControlPlaneRegistry({ version: 1, activeId: profileIdForIssuer(dev.issuer), profiles: [dev] });
  assert.equal(state.activeId, "tealbrick-dev");
  assert.equal(state.profiles.length, BUILT_IN_CONTROL_PLANES.length);
  const portal = sanitizeControlPlaneRegistry({ activeId: profileIdForIssuer(DEFAULT_ISSUER), profiles: [{ name: "Hosted", issuer: DEFAULT_ISSUER }] });
  assert.equal(portal.activeId, "tealbrick");
});

test("the hosted Portal uses the v1 0.1.5 data folder; dev has its own", () => {
  // v1 0.1.5 stored Chat data under profiles/plane-05d0b7148e70b276 (sha256 of the Portal origin).
  assert.equal(profileUserData("/base", COMPANY_CONTROL_PLANE), "/base/profiles/plane-05d0b7148e70b276");
  assert.equal(profileUserData("/base", DEV_CONTROL_PLANE), "/base/profiles/plane-19abb5fc7f319742");
});

test("a v1 or damaged person session is ignored, so first start shows sign-in", () => {
  const good = { token: "tbo_x", sessionId: "s1", expiresAt: 1_900_000_000_000, email: null };
  assert.deepEqual(parsePersonSession(JSON.stringify(good)), good);
  assert.deepEqual(parsePersonSession(JSON.stringify({ ...good, email: "a@example.test", extra: 1 })), { ...good, email: "a@example.test" });
  for (const raw of [null, "", "not json", "null", "[]", "42",
    JSON.stringify({ accessToken: "v1", refreshToken: "v1", expiresAt: 1 }),
    JSON.stringify({ ...good, token: "" }), JSON.stringify({ ...good, sessionId: 7 }),
    JSON.stringify({ ...good, expiresAt: "soon" }), JSON.stringify({ ...good, email: 5 })]) {
    assert.equal(parsePersonSession(raw), null, String(raw));
  }
});

test("a saved custom profile named like a built-in is kept under a new name, with its choice", () => {
  const staging = { name: "Teal Brick Dev", issuer: "https://staging.example" };
  const state = sanitizeControlPlaneRegistry({ version: 1, activeId: profileIdForIssuer(staging.issuer), profiles: [staging] });
  const kept = state.profiles.find((p) => p.issuer === staging.issuer);
  assert.equal(kept?.name, "Teal Brick Dev (saved)");
  assert.equal(state.activeId, kept?.id);
  assert.equal(state.profiles.filter((p) => p.builtIn).length, 2);
});
