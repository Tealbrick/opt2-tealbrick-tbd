import { app } from "../tbd/host";
import { loadState, saveState } from "./store";
import { getServices } from "./services";
import { currentControlPlane } from "./controlPlanes";
import { choosePortalWorkspace, workspaceAccountKey, workspaceStateName, type WorkspaceDirectory, type WorkspaceSelection } from "./workspaceSelection";

/**
 * Which Portal workspace TBD works in. The list comes from Portal with the
 * person session (K3 reads); the choice is remembered per account.
 */

let current: WorkspaceSelection | null = null;
let accountKey: string | null = null;

/** Remembered choices per account. A damaged or older file counts as none, never a crash. */
function savedChoices(): Record<string, string> {
  const saved = loadState<unknown>("portal-workspaces.json", {});
  return saved && typeof saved === "object" && !Array.isArray(saved) ? saved as Record<string, string> : {};
}

export function resetPortalWorkspace(): void { current = null; accountKey = null; }

export async function loadDirectory(): Promise<WorkspaceDirectory> {
  const { portal } = getServices();
  const [me, list] = await Promise.all([portal.me(), portal.workspaces()]);
  return { accountId: me.account.id, organizationId: me.account.id, workspaces: list.items.map((w) => ({ id: w.id, name: w.name })) };
}

export async function portalWorkspaces(directoryLoader: () => Promise<WorkspaceDirectory> = loadDirectory): Promise<WorkspaceSelection> {
  resetPortalWorkspace();
  const directory = await directoryLoader();
  accountKey = workspaceAccountKey(currentControlPlane().issuer, directory);
  const saved = savedChoices();
  const selectedId = choosePortalWorkspace(directory.workspaces, saved[accountKey]);
  if (selectedId && saved[accountKey] !== selectedId) saveState("portal-workspaces.json", { ...saved, [accountKey]: selectedId });
  current = { ...directory, selectedId };
  return current;
}

export function selectedPortalWorkspace(): string {
  if (!current?.selectedId) throw new Error("Select a workspace first.");
  return current.selectedId;
}

export function scopedStateName(name: string): string {
  if (!accountKey) throw new Error("Select a workspace first.");
  return workspaceStateName(accountKey, selectedPortalWorkspace(), name);
}

export async function selectPortalWorkspace(id: string, directoryLoader?: () => Promise<WorkspaceDirectory>): Promise<void> {
  // Revalidate against the server's list, including deletion since the chooser loaded.
  const directory = await portalWorkspaces(directoryLoader);
  if (!directory.workspaces.some((w) => w.id === id) || !accountKey) throw new Error("This workspace is no longer available.");
  const saved = savedChoices();
  saveState("portal-workspaces.json", { ...saved, [accountKey]: id });
  // End old streams and callbacks before another workspace can read/write state.
  app.emit("tbd:reset-session");
}
