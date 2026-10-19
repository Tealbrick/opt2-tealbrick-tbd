/**
 * WP-HARNESS LangChain adapter: no telemetry. LangChain sends traces to LangSmith when LANGSMITH_* or
 * LANGCHAIN_* variables ask for it. TBD's agent never does: tracing is switched off explicitly and every
 * other LANGSMITH_* / LANGCHAIN_* variable is removed. The agent also attaches no callbacks or tracers.
 *
 * The entry (langchain.ts) imports this file FIRST, so the variables are set before any LangChain code loads.
 */

/** The only two LANGSMITH_* / LANGCHAIN_* names that stay, both fixed to "false". */
export const TRACING_OFF: Readonly<Record<string, string>> = {
  LANGSMITH_TRACING: "false",
  LANGCHAIN_TRACING_V2: "false",
};

/** Force tracing off in `env` (default: this process) and drop every other LangSmith / LangChain variable. */
export function disableTracing(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  for (const name of Object.keys(env)) {
    if (/^(LANGSMITH_|LANGCHAIN_)/i.test(name)) delete env[name];
  }
  Object.assign(env, TRACING_OFF);
  return env;
}

disableTracing();
