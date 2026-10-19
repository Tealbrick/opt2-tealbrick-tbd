import { randomBytes } from "node:crypto";

/**
 * Request ids of one agent process: `<nonce>:p3` (permission) and `<nonce>:q4` (question). The nonce is random per process.
 * The helper sends a decision or an answer back by id; a process that replaced this one never matches an id meant for this
 * one, even if both count from 1. (The helper also drops replies for a replaced or stopped process: main/defaultAgent.ts.)
 */
export function createRequestIds(nonce: string = randomBytes(6).toString("hex")) {
  let next = 0;
  return {
    nonce,
    permission: (): string => `${nonce}:p${++next}`,
    question: (): string => `${nonce}:q${++next}`,
  };
}
