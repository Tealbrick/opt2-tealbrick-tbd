/**
 * The environment of the Companion MCP server (the bundled `dayflow` CLI) in both harnesses: the home folder and, when the host
 * said which app this is, `TBD_APP_SUPPORT_DIR` = the app's data folder (dev.17 review S8). The CLI uses it instead of its
 * compiled default, so TBD Dev's agent reads and writes the `-dev` folder and the live app's agent the live one. Nothing else
 * of the agent's environment (no model key) goes to the server.
 * (No relative value imports: node tests import this file directly.)
 */
export const APP_SUPPORT_ENV = "TBD_APP_SUPPORT_DIR";

export function companionEnv(config: { companionDataDir?: string }, env: NodeJS.ProcessEnv = process.env): Record<string, string> {
  const out: Record<string, string> = { HOME: env.HOME ?? "" };
  // An absolute path only: the CLI ignores any other value.
  if (config.companionDataDir?.startsWith("/")) out[APP_SUPPORT_ENV] = config.companionDataDir;
  return out;
}
