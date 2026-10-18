import { createHash } from "node:crypto";
import { join } from "node:path";
import type { ControlPlaneProfile, ControlPlaneState } from "../shared/controlPlanes";

/** The hosted Teal Brick Portal: the default control plane (C257). Same origin as shared DEFAULT_ISSUER. */
export const COMPANY_CONTROL_PLANE: ControlPlaneProfile = Object.freeze({
  id: "tealbrick", name: "Teal Brick Portal",
  issuer: "https://portal.tealbrick.com", builtIn: true,
});

/** The opt2 development Portal: built in and selectable, never the default. */
export const DEV_CONTROL_PLANE: ControlPlaneProfile = Object.freeze({
  id: "tealbrick-dev", name: "Teal Brick Dev",
  issuer: "https://dev.tealbrick.com", builtIn: true,
});

export const BUILT_IN_CONTROL_PLANES: readonly ControlPlaneProfile[] = Object.freeze([COMPANY_CONTROL_PLANE, DEV_CONTROL_PLANE]);

export function normalizeIssuer(value: string): string {
  let url: URL;
  try { url = new URL(value.trim()); }
  catch { throw new Error("Enter a complete control-plane URL, including https://."); }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(local && url.protocol === "http:")) {
    throw new Error("Use HTTPS (HTTP is allowed only for localhost).");
  }
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("Use the origin only, without credentials, a path, query, or fragment.");
  }
  return url.origin;
}

export function profileIdForIssuer(issuer: string): string {
  return `plane-${createHash("sha256").update(normalizeIssuer(issuer)).digest("hex").slice(0, 16)}`;
}

export function createControlPlaneProfile(
  state: ControlPlaneState, input: { name: string; issuer: string },
): ControlPlaneProfile {
  const name = input.name.trim();
  if (!name || name.length > 64) throw new Error("Use a name between 1 and 64 characters.");
  const issuer = normalizeIssuer(input.issuer);
  if (state.profiles.some((p) => p.issuer === issuer)) throw new Error("That control plane is already available.");
  if (state.profiles.some((p) => p.name.toLowerCase() === name.toLowerCase())) {
    throw new Error("That control-plane name is already in use.");
  }
  return { id: profileIdForIssuer(issuer), name, issuer, builtIn: false };
}

export function sanitizeControlPlaneRegistry(input: unknown): ControlPlaneState {
  const raw = input && typeof input === "object" ? input as Record<string, unknown> : {};
  const state: ControlPlaneState = { activeId: COMPANY_CONTROL_PLANE.id, profiles: [...BUILT_IN_CONTROL_PLANES] };
  if (Array.isArray(raw.profiles)) {
    for (const candidate of raw.profiles) {
      if (!candidate || typeof candidate.name !== "string" || typeof candidate.issuer !== "string") continue;
      try { state.profiles.push(createControlPlaneProfile(state, candidate)); } catch { /* Ignore invalid entries. */ }
    }
  }
  // Keep the saved choice. "tealbrick" means the hosted Portal, as in v1 0.1.5 (same file).
  // A custom entry for a built-in origin collapses into that built-in (same data folder).
  let activeId = raw.activeId;
  const builtIn = BUILT_IN_CONTROL_PLANES.find((p) => activeId === profileIdForIssuer(p.issuer));
  if (builtIn) activeId = builtIn.id;
  if (typeof activeId === "string" && state.profiles.some((p) => p.id === activeId)) state.activeId = activeId;
  return state;
}

export function profileUserData(base: string, profile: ControlPlaneProfile): string {
  return join(base, "profiles", profileIdForIssuer(profile.issuer));
}

export function assertPlaneSwitchAllowed(signedIn: boolean, signingIn: boolean): void {
  if (signedIn) throw new Error("Sign out before changing control planes.");
  if (signingIn) throw new Error("Cancel the current sign-in before changing control planes.");
}
