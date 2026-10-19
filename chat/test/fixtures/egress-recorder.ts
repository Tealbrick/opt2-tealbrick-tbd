// Preloaded into an agent process with `node --import <this file>?log=<path>` (langchain-e2e.test.ts).
// Records every network target the process opens, one JSON line each, so a test can assert which hosts it contacted:
//   {"kind":"connect","host":"127.0.0.1","port":1234}   (every net.Socket.connect, which is also what fetch/undici and tls use)
//   {"kind":"lookup","host":"example.com"}                (every dns.lookup / dns.promises.lookup)
import dns from "node:dns";
import net from "node:net";
import { appendFileSync } from "node:fs";

const log = new URL(import.meta.url).searchParams.get("log") ?? "";
const record = (entry: Record<string, unknown>) => { if (log) appendFileSync(log, `${JSON.stringify(entry)}\n`); };

const connect = net.Socket.prototype.connect as (this: net.Socket, ...args: unknown[]) => net.Socket;
net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]): net.Socket {
  // net.connect() hands over already normalized arguments: [options, callback].
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  if (typeof first === "object" && first !== null) {
    const o = first as { host?: string; port?: number; path?: string };
    record(o.path ? { kind: "connect", path: o.path } : { kind: "connect", host: o.host ?? "localhost", port: Number(o.port) });
  } else if (typeof first === "string" && Number.isNaN(Number(first))) {
    record({ kind: "connect", path: first });
  } else {
    record({ kind: "connect", host: typeof args[1] === "string" ? args[1] : "localhost", port: Number(first) });
  }
  return connect.apply(this, args);
} as typeof net.Socket.prototype.connect;

const lookup = dns.lookup as (...args: unknown[]) => unknown;
(dns as { lookup: unknown }).lookup = (...args: unknown[]) => { record({ kind: "lookup", host: args[0] }); return lookup.apply(dns, args); };
const lookupP = dns.promises.lookup as (...args: unknown[]) => unknown;
(dns.promises as { lookup: unknown }).lookup = (...args: unknown[]) => { record({ kind: "lookup", host: args[0] }); return lookupP.apply(dns.promises, args); };
