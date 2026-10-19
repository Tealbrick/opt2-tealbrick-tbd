/**
 * The answers on the Connect consent card, from what the helper put in the card. Approve and Deny count once. Never allow is
 * always there. Always allow is there only when the card offers it (`alwaysOffered`: effect write or outward, not a first-contact
 * tool); destructive, money and unknown effects ask every time. The Chat sends `{ allow, remember }` for the chosen answer.
 */
export interface ConnectAnswer {
  label: "Approve" | "Deny" | "Always allow" | "Never allow";
  allow: boolean;
  remember: boolean;
  primary?: boolean;
}

export function connectAnswers(card: { alwaysOffered: boolean }): ConnectAnswer[] {
  return [
    { label: "Approve", allow: true, remember: false, primary: true },
    { label: "Deny", allow: false, remember: false },
    ...(card.alwaysOffered ? [{ label: "Always allow" as const, allow: true, remember: true }] : []),
    { label: "Never allow", allow: false, remember: true },
  ];
}
