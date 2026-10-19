import { build } from 'esbuild';
import { build as viteBuild } from 'vite';
import react from '@vitejs/plugin-react';
import { join, resolve } from 'node:path';
import { readFileSync, readdirSync, writeFileSync, mkdirSync, copyFileSync, chmodSync } from 'node:fs';
import { buildHelper } from './tbd-helper-build.ts';

// Third-party notices: the npm packages that esbuild puts into the agent bundles (Agent SDK agent, LangChain agent,
// relay) ship their licence texts beside the app (scripts/assemble.sh copies the file into Resources/Licenses).
const bundled = new Set<string>();
function collect(result: { metafile?: { inputs: Record<string, unknown> } }): void {
  for (const input of Object.keys(result.metafile?.inputs ?? {})) {
    const m = input.match(/^(?:.*\/)?node_modules\/((?:@[^/]+\/)?[^/]+)\//);
    if (m) bundled.add(input.slice(0, input.indexOf(m[1]) + m[1].length));
  }
}
function writeNotices(file: string): number {
  const parts: string[] = [];
  for (const dir of [...bundled].sort()) {
    const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as { name: string; version: string; license?: string };
    const licence = readdirSync(dir).find((f) => /^(licen[cs]e|copying)/i.test(f));
    const text = licence ? readFileSync(join(dir, licence), 'utf8').trim() : `License: ${pkg.license ?? 'see package'} (no licence file in the package)`;
    parts.push(`${pkg.name} ${pkg.version}\n${'-'.repeat(60)}\n${text}\n`);
  }
  writeFileSync(file, `Third-party software bundled in TBD's Chat helper agents\n\n${parts.join('\n')}`);
  return parts.length;
}
mkdirSync('out/tbd', { recursive: true });
await buildHelper();
await viteBuild({ configFile: false, root: 'src/renderer', base: './', plugins: [react()], resolve: { alias: { '@': resolve('src/renderer/src'), '@shared': resolve('src/shared') } }, build: { outDir: resolve('out/tbd/renderer'), emptyOutDir: true, rollupOptions: { output: { format: 'iife', inlineDynamicImports: true } } } });
await build({ entryPoints: ['src/preload/index.ts'], outfile: 'out/tbd/renderer/bridge.js', bundle: true, platform: 'browser', format: 'iife' });
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
