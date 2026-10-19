import { execFile } from "node:child_process";
import { z } from "zod";

/**
 * Listening (transcripts, meetings, dictations) as harness-local tools of TBD's agents (C5): read-only calls to the
 * bundled `tbd-listen` CLI, run without a shell. Not Teal Brick app operations; they never pass the bridge.
 *
 * The tool definitions and `runCli` live here once, with no harness code in the file. The Agent SDK harness wraps
 * them in an in-process MCP server (listeningTools.ts); the LangChain harness wraps them in LangChain tools
 * (harness/langchainTools.ts). Names, descriptions and schemas are the same for both.
 */

const MAX_OUTPUT = 200_000;

export function runCli(cli: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(cli, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024, env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "" } }, (error, stdout, stderr) => {
      if (error) reject(new Error((stderr || error.message).trim().slice(0, 500)));
      else resolve(stdout.length > MAX_OUTPUT ? `${stdout.slice(0, MAX_OUTPUT)}\n…(truncated)` : stdout);
    });
  });
}

export interface ListeningToolDef {
  /** Tool name inside the "listening" server; the full name is mcp__listening__<name>. */
  name: string;
  description: string;
  /** zod raw shape of the arguments. */
  shape: z.ZodRawShape;
  /** The CLI call; rejects with the CLI's own message. */
  run(args: Record<string, unknown>, cli: string, exec?: (cli: string, args: string[]) => Promise<string>): Promise<string>;
}

export const LISTENING_INSTRUCTIONS = "Local transcripts, meetings and dictations recorded by TBD on this Mac. Read-only.";

export const LISTENING_TOOLS: ListeningToolDef[] = [
  {
    name: "search_transcripts",
    description: "Full-text search over the person's local transcripts and meetings. Returns matches as JSON.",
    shape: { query: z.string().min(1).max(200) },
    run: (a, cli, exec = runCli) => exec(cli, ["search", "--json", "--", String(a.query)]),
  },
  {
    name: "show_transcript",
    description: "The full transcript of one recording by id, with timestamps and speakers, as JSON.",
    shape: { id: z.string().min(1).max(100) },
    run: (a, cli, exec = runCli) => exec(cli, ["show", "--format", "json", "--", String(a.id)]),
  },
  {
    name: "list_meetings",
    description: "Recent meeting recordings (id, title, date, duration) as JSON.",
    shape: {},
    run: (_a, cli, exec = runCli) => exec(cli, ["meetings", "--json"]),
  },
  {
    name: "recent_dictations",
    description: "Recent dictations and voice notes.",
    shape: { limit: z.number().int().min(1).max(100).optional() },
    run: (a, cli, exec = runCli) => exec(cli, ["history", "--json", "--limit", String((a.limit as number | undefined) ?? 20)]),
  },
];

/** The text a tool returns when the CLI fails. */
export const listeningFailure = (e: unknown): string => `Listening error: ${e instanceof Error ? e.message : String(e)}`;
