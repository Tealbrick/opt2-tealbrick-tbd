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
 * The Portal address a link may use: https only. Anything else (http, a missing host, text that is no address) gives null and
 * so no link; TBD does not send the person to a page that is not encrypted.
 */
function portalBase(issuer: string): string | null {
  try {
    const url = new URL(issuer.trim());
    return url.protocol === "https:" && url.host ? issuer.trim().replace(/\/+$/, "") : null;
  } catch { return null; }
}

/**
 * The link "Open approval" opens, or null when none can be built. `issuer` is the active control plane profile's issuer (the
 * Portal URL; https only) and `ws` the workspace TBD's agent is connected to (where its rules and relay apply).
 *
 * - Operator Inbox unlocked: the Inbox holds overview (routing to one hold is design-only, C277 A3).
 * - The hold is Connect's (`product` is `connect`): Connect's hold page for this hold.
 * - Any other app: the workspace home in Portal. TBD does not guess the hold route of an app (the Sidebar's approvals badge
 *   opens the Portal too, since only counts are known); Portal shows the waiting approvals.
 */
export function holdLink(o: { issuer: string; ws: string; holdId: string; inboxUnlocked: boolean; product?: string | null }): string | null {
  const root = portalBase(o.issuer);
  if (!root || !o.ws) return null;
  const home = `${root}/w/${encodeURIComponent(o.ws)}`;
  if (o.inboxUnlocked) return `${home}/open?product=inbox&path=/holds`;
  if (o.product === "connect") return `${home}/open?product=connect&path=/holds/${encodeURIComponent(o.holdId)}`;
  return home;
}
