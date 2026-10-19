import { APP_DATA_FOLDER } from "./appIdentity";
import { app } from "../tbd/host";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ControlPlaneState } from "../shared/controlPlanes";
import { COMPANY_CONTROL_PLANE, createControlPlaneProfile, normalizeIssuer, profileIdForIssuer, profileUserData, sanitizeControlPlaneRegistry } from "./controlPlaneProfiles";

// Import before any store initializes. Each control plane gets its own
// credentials, device ID and history. The host passes TBD_CHAT_DATA.
const baseUserData = app.commandLine.getSwitchValue("user-data-dir") || join(app.getPath("appData"), APP_DATA_FOLDER, "Chat");
const registryPath = join(baseUserData, "control-planes.json");
let state: ControlPlaneState;
try {
  state = sanitizeControlPlaneRegistry(existsSync(registryPath) ? JSON.parse(readFileSync(registryPath, "utf8")) : null);
} catch { state = sanitizeControlPlaneRegistry(null); }

// Developer override, isolated: its own profile, never the hosted tokens.
if (process.env.TBD_PORTAL_URL) {
  const issuer = normalizeIssuer(process.env.TBD_PORTAL_URL);
  const existing = state.profiles.find((p) => p.issuer === issuer);
  const profile = existing ?? { id: profileIdForIssuer(issuer), name: "Environment control plane", issuer, builtIn: false };
  if (!existing) state.profiles.push(profile);
  state.activeId = profile.id;
}

export function currentControlPlane() {
  return state.profiles.find((p) => p.id === state.activeId) ?? COMPANY_CONTROL_PLANE;
}

export function controlPlanes(): ControlPlaneState {
  return { activeId: state.activeId, profiles: state.profiles.map((p) => ({ ...p })) };
}

function saveRegistry(next: ControlPlaneState): void {
  mkdirSync(baseUserData, { recursive: true });
  const temp = `${registryPath}.tmp`;
  writeFileSync(temp, JSON.stringify({ version: 1, activeId: next.activeId, profiles: next.profiles.filter((p) => !p.builtIn) }, null, 2) + "\n", { mode: 0o600 });
  renameSync(temp, registryPath);
  state = next;
}

function relaunchInto(next: ControlPlaneState): void {
  if (process.env.TBD_PORTAL_URL) throw new Error("Remove the TBD_PORTAL_URL environment override before switching planes.");
  saveRegistry(next);
  app.emit("tbd:reset-session");
}

export function activateControlPlane(id: string): void {
  if (!state.profiles.some((p) => p.id === id)) throw new Error("Unknown control plane.");
  if (id !== state.activeId) relaunchInto({ ...state, activeId: id });
}

export function addControlPlane(input: { name: string; issuer: string }): void {
  const profile = createControlPlaneProfile(state, input);
  relaunchInto({ activeId: profile.id, profiles: [...state.profiles, profile] });
}

export function removeControlPlane(id: string): ControlPlaneState {
  const profile = state.profiles.find((p) => p.id === id);
  if (!profile) throw new Error("Unknown control plane.");
  if (profile.builtIn || id === state.activeId) throw new Error("Only inactive custom control planes can be removed.");
  // Removing a selector entry must never delete a person's data.
  saveRegistry({ ...state, profiles: state.profiles.filter((p) => p.id !== id) });
  return controlPlanes();
}

const dataPath = profileUserData(baseUserData, currentControlPlane());
mkdirSync(dataPath, { recursive: true });
app.setPath("userData", dataPath);
