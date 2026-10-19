/**
 * The line a hold notice shows: "Approval <short id>". The link of the notice may be the Inbox overview (several holds) or the
 * Portal home, so the notice names the hold itself. Ids are cut for the eye only (the link keeps the whole id). Control and
 * bidirectional characters are dropped: an id comes from a tool result.
 */
export function approvalLine(holdId: string): string {
  const shown = Array.from(holdId).filter((ch) => {
    const c = ch.codePointAt(0) ?? 0;
    const bidi = (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) || c === 0x200e || c === 0x200f || c === 0x061c;
    return !bidi && c >= 0x20 && !(c >= 0x7f && c <= 0x9f);
  }).join("").trim();
  const short = shown.length > 16 ? `${shown.slice(0, 16)}…` : shown;
  return short ? `Approval ${short}` : "Approval";
}
