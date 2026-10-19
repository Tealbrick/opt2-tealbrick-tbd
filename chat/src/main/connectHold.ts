/**
 * Hold links (C280 C4, DESIGN-CONNECTORS §4). A Connect call that the owner has to approve shows in the Chat as
 * "Waiting for owner approval" with an **Open approval** link. The link is a Portal launcher link
 * (`<portalUrl>/w/<ws>/open?product=…&path=…`): Portal does the launch session, TBD never does and never approves a
 * hold itself. It opens in the system browser through the Chat's `openExternal`.
 */

export const HOLD_WAITING = "Waiting for owner approval";

/**
 * The app a relay tool belongs to: `mcp__tealbrick__<product>__<op>` (or `<product>__<op>`) gives `<product>`, the product id
 * of the Portal launcher (`connect`, `knowledge`, `kanban`, …). Anything that does not look like a product id gives null.
 */
export function holdProduct(tool: string): string | null {
  const bare = tool.startsWith("mcp__tealbrick__") ? tool.slice("mcp__tealbrick__".length) : tool;
  const at = bare.indexOf("__");
  if (at <= 0) return null;
  const product = bare.slice(0, at);
  return /^[a-z][a-z0-9-]{0,39}$/.test(product) ? product : null;
}

/**
 * Operator Inbox unlocked → the Inbox holds overview (routing to one hold is design-only, C277 A3); otherwise the hold page
 * of the app that holds the call (`product`, default Connect). `issuer` is the active control plane profile's issuer (the
 * Portal URL).
 */
export function holdLink(o: { issuer: string; ws: string; holdId: string; inboxUnlocked: boolean; product?: string | null }): string {
  const base = `${o.issuer.replace(/\/+$/, "")}/w/${encodeURIComponent(o.ws)}/open`;
  return o.inboxUnlocked
    ? `${base}?product=inbox&path=/holds`
    : `${base}?product=${encodeURIComponent(o.product || "connect")}&path=/holds/${encodeURIComponent(o.holdId)}`;
}
