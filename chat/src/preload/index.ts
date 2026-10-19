import { ipcRenderer } from "../tbd/webview";
import type { StudioApi } from "../shared/ipc";
import { toWire } from "../shared/message";

/**
 * The only bridge. Tokens live in the main process and never reach the
 * renderer — web content gets answers, not credentials.
 */
const studio: StudioApi = {
  portalWorkspaces: () => ipcRenderer.invoke("studio:portalWorkspaces"),
  selectPortalWorkspace: (id) => ipcRenderer.invoke("studio:selectPortalWorkspace", id),
  controlPlanes: () => ipcRenderer.invoke("studio:controlPlanes"),
  activateControlPlane: (id) => ipcRenderer.invoke("studio:activateControlPlane", id),
  addControlPlane: (input) => ipcRenderer.invoke("studio:addControlPlane", input),
  removeControlPlane: (id) => ipcRenderer.invoke("studio:removeControlPlane", id),
  session: () => ipcRenderer.invoke("studio:session"),
  signIn: () => ipcRenderer.invoke("studio:signIn"),
  cancelSignIn: () => ipcRenderer.invoke("studio:cancelSignIn"),
  awaitSignIn: () => ipcRenderer.invoke("studio:awaitSignIn"),
  signOut: () => ipcRenderer.invoke("studio:signOut"),
  listAgents: (opts?: { refreshSession?: boolean }) => ipcRenderer.invoke("studio:listAgents", opts),
  saveAgentProfile: (input) => ipcRenderer.invoke("studio:saveAgentProfile", input),
  // Attachments cross the bridge as base64 (shared/message.ts toWire).
  send: (input) => ipcRenderer.invoke("studio:send", { ...input, attachments: input.attachments?.map(toWire) }),
  fileExists: (path) => ipcRenderer.invoke("studio:fileExists", path),
  openLocalFile: (path) => ipcRenderer.invoke("studio:openLocalFile", path),
  revealLocalFile: (path) => ipcRenderer.invoke("studio:revealLocalFile", path),
  saveRemoteFile: (input) => ipcRenderer.invoke("studio:saveRemoteFile", input),
  openRemoteFile: (input) => ipcRenderer.invoke("studio:openRemoteFile", input),
  agentInfo: (agentId) => ipcRenderer.invoke("studio:agentInfo", agentId),
  agentHealth: (agentId) => ipcRenderer.invoke("studio:agentHealth", agentId),
  restartAgent: (agentId) => ipcRenderer.invoke("studio:restartAgent", agentId),
  localAnswer: (input) => ipcRenderer.invoke("studio:localAnswer", input),
  replaySession: (input) => ipcRenderer.invoke("studio:replaySession", input),
  loadState: (name) => ipcRenderer.invoke("studio:loadState", name),
  saveState: (input) => ipcRenderer.invoke("studio:saveState", input),
  pickFolder: () => ipcRenderer.invoke("studio:pickFolder"),
  onLocalAsk: (handler) => {
    const listener = (_e: unknown, ask: Parameters<typeof handler>[0]): void => handler(ask);
    ipcRenderer.on("studio:local-ask", listener);
    return () => ipcRenderer.off("studio:local-ask", listener);
  },
  onLocalDone: (handler) => {
    const listener = (_e: unknown, p: { id: string }): void => handler(p);
    ipcRenderer.on("studio:local-done", listener);
    return () => ipcRenderer.off("studio:local-done", listener);
  },
  onHeld: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:held", listener);
    return () => ipcRenderer.off("studio:held", listener);
  },
  onCursor: (handler) => {
    const listener = (_e: unknown, payload: { streamId: string; index: number }): void => handler(payload);
    ipcRenderer.on("studio:cursor", listener);
    return () => ipcRenderer.off("studio:cursor", listener);
  },
  cancelTurn: (input) => ipcRenderer.invoke("studio:cancelTurn", input),
  resetSession: (input) => ipcRenderer.invoke("studio:resetSession", input),
  onTurn: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:turn", listener);
    return () => ipcRenderer.off("studio:turn", listener);
  },
  firstRun: () => ipcRenderer.invoke("studio:firstRun"),
  openSettings: (section) => ipcRenderer.invoke("studio:openSettings", section),
  agentConnection: () => ipcRenderer.invoke("studio:agentConnection"),
  agentConnect: () => ipcRenderer.invoke("studio:agentConnect"),
  awaitAgentConnect: () => ipcRenderer.invoke("studio:awaitAgentConnect"),
  cancelAgentConnect: () => ipcRenderer.invoke("studio:cancelAgentConnect"),
  agentDisconnect: () => ipcRenderer.invoke("studio:agentDisconnect"),
  pendingHolds: () => ipcRenderer.invoke("studio:pendingHolds"),
  agentFolders: () => ipcRenderer.invoke("studio:agentFolders"),
  addAgentFolder: () => ipcRenderer.invoke("studio:addAgentFolder"),
  removeAgentFolder: (path) => ipcRenderer.invoke("studio:removeAgentFolder", path),
  openAgentWorkspace: () => ipcRenderer.invoke("studio:openAgentWorkspace"),
  openExternal: (url) => ipcRenderer.invoke("studio:openExternal", url),
  onAuthorization: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:authorization", listener);
    return () => ipcRenderer.off("studio:authorization", listener);
  },
  onPeer: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on('studio:peer', listener);
    return () => ipcRenderer.off('studio:peer', listener);
  },
  notify: (input) => ipcRenderer.invoke("studio:notify", input),
  onOpenAgent: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:open-agent", listener);
    return () => ipcRenderer.off("studio:open-agent", listener);
  },
  watch: (input) => ipcRenderer.invoke("studio:watch", input),
  unwatch: (streamId) => ipcRenderer.invoke("studio:unwatch", streamId),
  onLive: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:live", listener);
    return () => ipcRenderer.off("studio:live", listener);
  },
  onQuestion: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:question", listener);
    return () => ipcRenderer.off("studio:question", listener);
  },
  onReset: (handler) => {
    const listener = (_e: unknown, payload: Parameters<typeof handler>[0]): void => handler(payload);
    ipcRenderer.on("studio:reset", listener);
    return () => ipcRenderer.off("studio:reset", listener);
  },
  onActivity: (handler) => {
    const listener = (_e: unknown, payload: { streamId: string; label: string | null }): void =>
      handler(payload);
    ipcRenderer.on("studio:activity", listener);
    return () => ipcRenderer.off("studio:activity", listener);
  },
  onDelta: (handler) => {
    const listener = (_e: unknown, payload: { streamId: string; text: string }): void =>
      handler(payload);
    ipcRenderer.on("studio:delta", listener);
    return () => ipcRenderer.off("studio:delta", listener);
  },
};

(window as unknown as { studio: StudioApi }).studio = studio;
