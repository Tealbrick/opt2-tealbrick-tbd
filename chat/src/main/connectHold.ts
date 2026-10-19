/**
 * Hold links (C280 C4, DESIGN-CONNECTORS §4). A Connect call that the owner has to approve shows in the Chat as
 * "Waiting for owner approval" with an **Open approval** link. The link is a Portal launcher link
 * (`<portalUrl>/w/<ws>/open?product=…&path=…`): Portal does the launch session, TBD never does and never approves a
 * hold itself. It opens in the system browser through the Chat's `openExternal`.
 */

export const HOLD_WAITING = "Waiting for owner approval";

/**
 * Operator Inbox unlocked → the Inbox holds overview (routing to one hold is design-only, C277 A3); otherwise Connect's own
 * hold page for this hold. `issuer` is the active control plane profile's issuer (the Portal URL).
 */
export function holdLink(o: { issuer: string; ws: string; holdId: string; inboxUnlocked: boolean }): string {
  const base = `${o.issuer.replace(/\/+$/, "")}/w/${encodeURIComponent(o.ws)}/open`;
  return o.inboxUnlocked
    ? `${base}?product=inbox&path=/holds`
    : `${base}?product=connect&path=/holds/${encodeURIComponent(o.holdId)}`;
}
