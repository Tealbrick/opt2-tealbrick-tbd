import { build } from 'esbuild';
import { build as viteBuild } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync, chmodSync } from 'node:fs';
import { buildHelper } from './tbd-helper-build.ts';
import { licenceText, packageDirOf } from './third-party.ts';

// Third-party notices: the npm packages that end up in a bundle (the helper, the renderer, the preload, the Agent SDK
// agent, the LangChain agent, the relay) ship their licence texts beside the app (scripts/assemble.sh copies the file
// into Resources/Licenses). Packages without a licence file get the standard text for their SPDX id.
const bundled = new Set<string>();
function collectIds(ids: Iterable<string>): void {
  for (const id of ids) {
    const dir = packageDirOf(id);
    if (dir) bundled.add(dir);
  }
}
function collect(result: { metafile?: { inputs: Record<string, unknown> } }): void {
  collectIds(Object.keys(result.metafile?.inputs ?? {}));
}
/** A rollup plugin for the renderer: the module ids of every chunk. */
const collectModules = { name: 'tbd-collect-modules', generateBundle(_options: unknown, bundle: Record<string, { modules?: Record<string, unknown> }>) { for (const chunk of Object.values(bundle)) collectIds(Object.keys(chunk.modules ?? {})); } };
function writeNotices(file: string): number {
  const parts: string[] = [];
  for (const dir of [...bundled].sort()) {
    const { pkg, text } = licenceText(dir);
    parts.push(`${pkg.name} ${pkg.version}\n${'-'.repeat(60)}\n${text}\n`);
  }
  writeFileSync(file, `Third-party software bundled in TBD's Chat helper, renderer and agents\n\n${parts.join('\n')}`);
  return parts.length;
}
mkdirSync('out/tbd', { recursive: true });
await buildHelper(undefined, collect);
await viteBuild({ configFile: false, root: 'src/renderer', base: './', plugins: [react(), collectModules], resolve: { alias: { '@': resolve('src/renderer/src'), '@shared': resolve('src/shared') } }, build: { outDir: resolve('out/tbd/renderer'), emptyOutDir: true, rollupOptions: { output: { format: 'iife', inlineDynamicImports: true } } } });
await build({ entryPoints: ['src/preload/index.ts'], outfile: 'out/tbd/renderer/bridge.js', bundle: true, platform: 'browser', format: 'iife', metafile: true }).then(collect);
// Nunito comes from @opt2-tealbrick/ui (bundled by Vite from its tokens.css); its OFL licence ships beside the app.
mkdirSync('out/tbd/renderer/brand', { recursive: true });
copyFileSync('node_modules/@opt2-tealbrick/ui/dist/fonts/OFL.txt', 'out/tbd/renderer/brand/Nunito-OFL.txt');
const index = 'out/tbd/renderer/index.html'; writeFileSync(index, readFileSync(index, 'utf8').replace('<head>', '<head><script src="./bridge.js"></script>').replace('type="module" crossorigin', 'defer').replace('rel="stylesheet" crossorigin', 'rel="stylesheet"'));

// TBD's default agent (Claude Agent SDK) as one ESM bundle, plus the SDK's
// native Claude Code executable for this platform (signed by release.sh).
await build({
  entryPoints: ['src/agent/main.ts'], outfile: 'out/tbd/agent.mjs', bundle: true, platform: 'node', format: 'esm', target: 'node24',
  banner: { js: "import { createRequire as __tbdRequire } from 'node:module'; const require = __tbdRequire(import.meta.url);" },
  logLevel: 'error', metafile: true,
}).then(collect);
// TBD's LangChain agent (WP-HARNESS L1): same protocol, a small LangGraph graph; same esbuild options as agent.mjs.
await build({
  entryPoints: ['src/agent/harness/langchain.ts'], outfile: 'out/tbd/agent-langchain.mjs', bundle: true, platform: 'node', format: 'esm', target: 'node24',
  banner: { js: "import { createRequire as __tbdRequire } from 'node:module'; const require = __tbdRequire(import.meta.url);" },
  logLevel: 'error', metafile: true,
}).then(collect);
// The local relay (C5): the agent's `tealbrick` MCP server, from @opt2-tealbrick/bridge.
await build({
  entryPoints: ['src/agent/relay.ts'], outfile: 'out/tbd/relay.mjs', bundle: true, platform: 'node', format: 'esm', target: 'node24',
  banner: { js: "import { createRequire as __tbdRequire } from 'node:module'; const require = __tbdRequire(import.meta.url);" },
  logLevel: 'error', metafile: true,
}).then(collect);
console.log(`build-tbd: third-party notices for ${writeNotices('out/tbd/THIRD-PARTY-NOTICES.txt')} bundled packages`);
// The darwin-arm64 executable only installs on macOS. On the Linux CI host the bundles above are
// built and checked; the app itself is assembled and signed on the release Mac (scripts/release.sh).
if (process.platform === 'darwin') {
  copyFileSync('node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude', 'out/tbd/claude');
  chmodSync('out/tbd/claude', 0o755);
} else {
  console.log(`build-tbd: skipped the darwin-arm64 Claude executable on ${process.platform} (macOS app assembly only)`);
}
