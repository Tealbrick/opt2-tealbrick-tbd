// Fresh-identity UX baseline: how many clicks, places and relaunches does a person need, from a FRESH identity,
// to reach a fully working TBD? Drives a TBD Dev app (bundle id com.tealbrick.desktop.dev) ONLY through macOS
// Accessibility (osascript -l JavaScript, AXUIElement by pid) and writes JSON + a markdown table.
//
//   node scripts/ux/fresh-run.ts --app "<path>/TBD.app" --out <dir> [--path dev8|dev9] [--reset-identity] [--identity <a-z0-9>] [--keep-running]
//   node scripts/ux/fresh-run.ts --restore-from <backupDir>     (puts a backed-up dev identity back)
//
// A PATH (see PATHS below) is an ordered list of steps. Each step is performed for real through AX, or MODELLED
// (counted with a fixed, stated cost but not done), because it is outside TBD (browser approval, System Settings,
// macOS prompts, quit and reopen) or unsafe/costly to do (secrets, large downloads, paid or CLI-login tests).
// Add a new version by adding an entry to PATHS (for example dev9) and run with --path dev9.
//
// Safety: the app must be a Debug build with bundle id com.tealbrick.desktop.dev. The script drives the process it
// launched (checked by pid and by executable path), never the live app. It never types secrets, never answers macOS
// prompts, never changes privacy settings. Nothing is deleted: identity data is MOVED aside.

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// ---------------------------------------------------------------- types

type Act =
  | { kind: "launch" }
  | { kind: "click"; label: string; nth?: number; after?: string }
  | { kind: "choose"; label: string; option: string } // open a pop-up, pick an item (2 clicks)
  | { kind: "type"; target: string; what: string; secret: boolean } // 2 clicks (focus + type/paste), modelled when secret
  | { kind: "external"; what: string }
  | { kind: "relaunch" };

interface Step {
  place: string;
  act: Act;
  /** Clicks this step costs. Default: click 1, launch 1, choose 2, type 2, relaunch 2 (quit + open); external: required. */
  clicks?: number;
  /** Set to a reason to MODEL this step (count it, do not do it). `external` and `relaunch` are always modelled. */
  model?: string;
  /** After this step, wait until the on-screen text matches this regular expression (source). */
  expect?: string;
  /** After this step, record the screen: "looks broken" signals and a screenshot attempt. */
  observe?: boolean;
  /** Not part of the person's path: navigation or cleanup the script needs (never counted). */
  harness?: boolean;
  /** Free tag, for sub-totals (for example "daily-recap"). */
  tag?: string;
  note?: string;
}

interface PathDef {
  id: string;
  version: string;
  goal: string;
  steps: Step[];
  /** Regular expressions over on-screen text (labels and values), each naming one "looks broken" state. */
  signals: { name: string; pattern: string }[];
  /** Findings read from the code, not seen on screen in this run. */
  fromCode: string[];
}

// ---------------------------------------------------------------- fixed costs (state them in the report)

const COST = {
  browserApprove: 2, // click Approve in the browser, confirm
  systemSettingsToggle: 2, // switch on TBD in System Settings and confirm with Touch ID or password
  macPrompt: 1, // one click on a macOS permission prompt
  quitAndOpen: 2, // Cmd-Q (1) and open again (1)
  anthropicKey: 4, // open the console, create a key, name it, copy it
  secretEntry: 2, // click the field, paste
};

// ---------------------------------------------------------------- path definitions

const DEV8_SIGNALS = [
  { name: "Capture is off", pattern: "isn't recording|Start Tealbrick to continue" },
  { name: "Screen recording not granted", pattern: "Screen access not granted|^Not granted$" },
  { name: "Daily asks for a model", pattern: "Choose a model for Daily|Daily needs a model" },
  { name: "Chat tab hidden until sign-in", pattern: "Connect to Portal to use Chat" },
  { name: "Signed out", pattern: "^Signed out$" },
  { name: "Chat cannot answer until the agent model is set (copy in Models)", pattern: "Chat cannot answer until this is set" },
  { name: "Agent model: Ollama is the default provider and is not running", pattern: "Ollama is not running" },
  { name: "Speech model not downloaded (dictation cannot start)", pattern: "not downloaded|Download the speech model to start" },
  { name: "Dictation key needs hotkey (Accessibility) access", pattern: "Needs hotkey access" },
  { name: "Screen analysis provider needs attention (default OpenAI-compatible, no key)", pattern: "NEEDS ATTENTION" },
  { name: "Permission not requested", pattern: "^Not requested$" },
];

const PATHS: Record<string, PathDef> = {
  dev8: {
    id: "dev8",
    version: "dev.8 (origin/main 0cf72bb)",
    goal:
      "Signed in + workspace chosen; TBD's agent model set up and tested; agent paired with the workspace; Screen recording, " +
      "Microphone, Accessibility and Notifications granted; Companion analysis model chosen; speech model downloaded.",
    signals: DEV8_SIGNALS,
    fromCode: [
      "Chat with no agent model: the first-run flow \"Set up TBD's agent\" opens, the composer says \"No model set\" and Send becomes \"Set up a model\" (chat/src/renderer/src/lib/agentModel.ts, components/Conversation.tsx:304, lib/store.ts:872). Chat is hidden until sign-in, so it was not reachable in this run.",
      "Setup without the Screen recording grant: Open Companion leaves capture off WITHOUT saving it, and posts a macOS notice (TBDCompanionSetup.finishSetup).",
      "After allowing Screen recording, macOS needs TBD quit with Cmd-Q and opened again (copy under Settings > Access > Screen recording).",
      "Chat first-run lists three steps (Signed in, Model, Connect); Connect is optional and starts a second browser approval (ConnectAgentFlow).",
    ],
    steps: [
      { place: "macOS (Dock or Finder)", act: { kind: "launch" }, expect: "Companion setup", observe: true, note: "First launch from a fresh identity opens the Companion setup screen." },

      // ---- Companion setup
      { place: "Setup screen", act: { kind: "click", label: "Screen recording settings" }, model: "opens System Settings (not performed: no System Settings changes)", note: "Setup step 1 of 2." },
      { place: "System Settings", act: { kind: "external", what: "Privacy > Screen & System Audio Recording: switch on TBD, confirm with Touch ID or password" }, clicks: COST.systemSettingsToggle },
      { place: "macOS (Dock or Finder)", act: { kind: "relaunch" }, note: "macOS asks to quit and reopen TBD after the Screen recording grant." },
      { place: "Setup screen", act: { kind: "click", label: "Next" }, expect: "Open Companion", note: "Performed with Screen recording NOT granted (same clicks)." },
      { place: "Setup screen", act: { kind: "click", label: "Open Companion" }, expect: "Timeline|Daily", observe: true },
      { place: "Listen", act: { kind: "click", label: "Listen" }, harness: true, expect: "Download the speech model|Transcribe", observe: true, note: "Look at Listen: observation only." },
      { place: "Companion > Daily", act: { kind: "click", label: "Companion" }, harness: true },
      { place: "Companion > Daily", act: { kind: "click", label: "Daily" }, harness: true, expect: "Daily recap provider|Choose a model for Daily|Standup", observe: true, note: "Look at Daily: observation only." },

      // ---- Portal sign-in and workspace
      { place: "Settings > Account", act: { kind: "click", label: "Settings" }, observe: true, expect: "Your Teal Brick Portal sign-in", note: "The banner button \"Sign in\" would reach Account in 1 click as well; the gear is used here." },
      { place: "Settings > Account", act: { kind: "click", label: "Sign in" }, expect: "Cancel sign-in", observe: true, note: "Starts the device flow: a code shows and TBD opens the browser by itself." },
      { place: "Browser (Portal)", act: { kind: "external", what: "Approve the device code on the Portal page, confirm" }, clicks: COST.browserApprove },
      { place: "Settings > Account", act: { kind: "click", label: "Cancel sign-in" }, harness: true, note: "Script cleanup: the sign-in is never completed." },
      { place: "Settings > Account", act: { kind: "choose", label: "Workspace", option: "<workspace>" }, model: "needs a signed-in session (not allowed in this run)", note: "Skipped by Portal when the person has one workspace." },

      // ---- TBD's agent model (Settings > Models > Tasks)
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Models" }, expect: "TBD agent model", observe: true },
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Anthropic" }, note: "Provider step. Default provider is Ollama (needs Ollama installed, a 13 GB pull)." },
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Next" }, expect: "API key", observe: true },
      { place: "Browser (Anthropic console)", act: { kind: "external", what: "Open the Anthropic console, create an API key, name it, copy it (assumes an existing console login)" }, clicks: COST.anthropicKey },
      { place: "Settings > Models > Tasks", act: { kind: "type", target: "API key", what: "paste the API key", secret: true } },
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Next" }, model: "needs the key step filled (no secrets typed)", note: "Key step to Model step." },
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Test connection" }, model: "needs the key (a real call to the provider)", note: "\"TBD agent model set up and tested\"." },
      { place: "Settings > Models > Tasks", act: { kind: "click", label: "Save" }, model: "needs the key" },

      // ---- Chat: pair TBD's agent with the workspace
      { place: "Chat", act: { kind: "click", label: "Chat" }, model: "Chat tab exists only after sign-in" },
      { place: "Chat", act: { kind: "click", label: "Connect…" }, model: "Chat needs sign-in", note: "Chat first-run flow, step Connect." },
      { place: "Chat", act: { kind: "click", label: "Connect" }, model: "Chat needs sign-in", note: "Agent card, opens the Connect flow." },
      { place: "Chat", act: { kind: "click", label: "Connect" }, model: "Chat needs sign-in", note: "Connect flow, step 1: starts the device flow." },
      { place: "Browser (agent approval)", act: { kind: "external", what: "Approve TBD's agent in the browser, confirm" }, clicks: COST.browserApprove },
      { place: "Chat", act: { kind: "click", label: "Done" }, model: "Chat needs sign-in" },

      // ---- Speech model (Settings > Models > Transcription)
      { place: "Settings > Models > Transcription", act: { kind: "click", label: "Settings" }, model: "re-opens Settings after Chat (the run never left Settings)", note: "Settings opens on Account again." },
      { place: "Settings > Models > Transcription", act: { kind: "click", label: "Models" } },
      { place: "Settings > Models > Transcription", act: { kind: "click", label: "Transcription" }, expect: "Parakeet v3", observe: true },
      { place: "Settings > Models > Transcription", act: { kind: "click", label: "Download", after: "Parakeet v3 · live and final" }, model: "downloads ~465 MB from Hugging Face" },

      // ---- Companion analysis model (Settings > Models > Advanced > Screen analysis providers)
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Advanced" }, expect: "Screen analysis providers", observe: true },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Screen analysis providers" }, expect: "Failover routing", observe: true },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Setup", nth: 0 }, expect: "Connect Claude|Before you begin", note: "Claude (Claude Code CLI). Assumes Claude Code is installed and signed in." },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Next" }, expect: "installation|Check", note: "Before you begin to Check installations." },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Previous" }, harness: true, note: "Script cleanup: step back, then close the connect sheet." },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Back" }, harness: true, expect: "Failover routing" },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Claude, Ready to use" }, model: "the sheet was closed; the rest of the flow is estimated from its step names (choose provider, Next, Test connection, Next, Done)", note: "Check installations: choose Claude." },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Next" }, model: "estimated flow step" },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Test connection" }, model: "runs the Claude CLI on the person's plan (not run)" },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Next" }, model: "estimated flow step" },
      { place: "Settings > Models > Advanced", act: { kind: "click", label: "Done" }, model: "estimated flow step" },

      // ---- Daily recap provider (a second, separate model choice)
      { place: "Companion > Daily", act: { kind: "click", label: "Companion" }, tag: "daily-recap" },
      { place: "Companion > Daily", act: { kind: "click", label: "Daily" }, tag: "daily-recap", expect: "Choose a model for Daily|Standup" },
      { place: "Companion > Daily", act: { kind: "click", label: "Choose daily recap provider" }, tag: "daily-recap", expect: "Daily recap provider", observe: true },
      { place: "Companion > Daily", act: { kind: "click", label: "TBD agent model, Set up in Settings → Models" }, model: "disabled until the agent model is saved", tag: "daily-recap", note: "Daily recap provider is separate from the screen analysis provider." },

      // ---- macOS permissions (Settings > Access)
      { place: "Settings > Access", act: { kind: "click", label: "Settings" }, expect: "Your Teal Brick Portal sign-in" },
      { place: "Settings > Access", act: { kind: "click", label: "Access" }, expect: "The macOS permissions TBD needs", observe: true },
      { place: "Settings > Access", act: { kind: "click", label: "Allow…", after: "Microphone" }, model: "opens a macOS permission prompt that stays on screen after the app quits (seen in exploration; not repeated)", observe: true },
      { place: "macOS prompt", act: { kind: "external", what: "Microphone prompt: Allow" }, clicks: COST.macPrompt },
      { place: "Settings > Access", act: { kind: "click", label: "Allow…", after: "Accessibility" }, model: "opens a macOS permission prompt (see Microphone)" },
      { place: "macOS prompt", act: { kind: "external", what: "Accessibility prompt: Open System Settings" }, clicks: COST.macPrompt },
      { place: "System Settings", act: { kind: "external", what: "Privacy > Accessibility: switch on TBD, confirm with Touch ID or password" }, clicks: COST.systemSettingsToggle },
      { place: "Settings > Access", act: { kind: "click", label: "Allow…", after: "Notifications" }, model: "opens a macOS permission prompt (see Microphone)" },
      { place: "macOS prompt", act: { kind: "external", what: "Notifications prompt: Allow" }, clicks: COST.macPrompt },
    ],
  },
  dev9: {
    id: "dev9",
    version: "dev.9 (wp-onb/onboarding: first-launch setup flow)",
    goal:
      "Signed in + workspace chosen; TBD's agent model set up and tested; agent paired with the workspace; Screen recording, " +
      "Microphone, Accessibility and Notifications granted; Companion analysis model chosen; speech model downloaded.",
    signals: [
      { name: "Capture is off", pattern: "isn't recording|Start Tealbrick to continue" },
      { name: "Daily asks for a model", pattern: "Choose a model for Daily|Daily needs a model" },
      { name: "Chat tab hidden until sign-in", pattern: "Connect to Portal to use Chat" },
      { name: "Speech model not downloaded (dictation cannot start)", pattern: "Download the speech model to start" },
    ],
    fromCode: [
      "The flow replaces the whole window until \"Open TBD\": no app screen shows before the prerequisites (C285).",
      "Screen recording: \"Quit and reopen TBD\" quits and opens TBD by itself and resumes at Permissions (one click, no Dock/Finder).",
      "Daily uses TBD's agent model when no recap provider is chosen (C137), so no separate Daily choice is needed.",
      "The speech model download continues in the background; Next is allowed while it runs (C286 F3).",
    ],
    steps: [
      { place: "macOS (Dock or Finder)", act: { kind: "launch" }, expect: "Welcome to TBD", observe: true, note: "First launch from a fresh identity opens the setup flow." },
      { place: "Setup flow", act: { kind: "click", label: "Start" }, expect: "Use TBD with your Teal Brick workspace" },

      // ---- 1 Workspace
      { place: "Setup flow", act: { kind: "click", label: "Yes, sign in" }, expect: "Sign in" },
      { place: "Setup flow", act: { kind: "click", label: "Sign in" }, expect: "Waiting for you|Approve", observe: true, note: "Starts the device flow: a code shows and TBD opens the browser by itself." },
      { place: "Browser (Portal)", act: { kind: "external", what: "Approve the device code on the Portal page, confirm" }, clicks: COST.browserApprove },
      { place: "Setup flow", act: { kind: "click", label: "Cancel" }, harness: true, note: "Script cleanup: the sign-in is never completed." },
      { place: "Setup flow", act: { kind: "click", label: "<workspace>" }, model: "needs a signed-in session (not allowed in this run)", note: "Skipped by Portal when the person has one workspace." },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "Next needs the signed-in session; the script uses \"No, not now\" to go on (not counted)" },
      { place: "Setup flow", act: { kind: "click", label: "No, not now" }, harness: true, expect: "Run TBD's own agent" },

      // ---- 2 TBD's agent (same choice as the dev.8 path: Anthropic API key)
      { place: "Setup flow", act: { kind: "click", label: "Yes" }, expect: "Runs on" },
      { place: "Setup flow", act: { kind: "click", label: "API key" }, expect: "Anthropic API key", observe: true },
      { place: "Browser (Anthropic console)", act: { kind: "external", what: "Open the Anthropic console, create an API key, name it, copy it (assumes an existing console login)" }, clicks: COST.anthropicKey },
      { place: "Setup flow", act: { kind: "type", target: "Anthropic API key", what: "paste the API key", secret: true } },
      { place: "Setup flow", act: { kind: "click", label: "Test and save" }, model: "needs the key (a real call to the provider)" },
      { place: "Setup flow", act: { kind: "click", label: "Pair with the workspace" }, model: "needs sign-in", note: "Pairing is in the same step (no Chat visit)." },
      { place: "Browser (agent approval)", act: { kind: "external", what: "Approve TBD's agent in the browser, confirm" }, clicks: COST.browserApprove },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "needs the tested model; the script uses \"No, not now\" (not counted)" },
      { place: "Setup flow", act: { kind: "click", label: "No, not now" }, harness: true, expect: "Allow what TBD needs" },

      // ---- 3 Permissions
      { place: "Setup flow", act: { kind: "click", label: "Allow", after: "Screen recording" }, model: "opens the macOS prompt / System Settings (no System Settings changes)", observe: true },
      { place: "macOS prompt", act: { kind: "external", what: "Screen recording prompt: Open System Settings" }, clicks: COST.macPrompt },
      { place: "System Settings", act: { kind: "external", what: "Privacy > Screen & System Audio Recording: switch on TBD, confirm with Touch ID or password" }, clicks: COST.systemSettingsToggle },
      { place: "Setup flow", act: { kind: "relaunch" }, clicks: 1, note: "\"Quit and reopen TBD\": one click; TBD quits, opens itself and resumes at Permissions." },
      { place: "Setup flow", act: { kind: "click", label: "Allow", after: "Microphone" }, model: "opens a macOS permission prompt (not answered by the script)" },
      { place: "macOS prompt", act: { kind: "external", what: "Microphone prompt: Allow" }, clicks: COST.macPrompt },
      { place: "Setup flow", act: { kind: "click", label: "Allow", after: "Accessibility" }, model: "opens a macOS permission prompt" },
      { place: "macOS prompt", act: { kind: "external", what: "Accessibility prompt: Open System Settings" }, clicks: COST.macPrompt },
      { place: "System Settings", act: { kind: "external", what: "Privacy > Accessibility: switch on TBD, confirm with Touch ID or password" }, clicks: COST.systemSettingsToggle },
      { place: "Setup flow", act: { kind: "click", label: "Allow", after: "Notifications" }, model: "opens a macOS permission prompt" },
      { place: "macOS prompt", act: { kind: "external", what: "Notifications prompt: Allow" }, clicks: COST.macPrompt },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "needs the grants; the script uses \"Not now\" (not counted)" },
      { place: "Setup flow", act: { kind: "click", label: "Not now", after: "Previous" }, harness: true, expect: "Analyse your screen activity", note: "Footer \"Not now\" (the one after \"Previous\"), not a row's." },

      // ---- 4 Models (same Companion choice as the dev.8 path: the person's own Claude Code CLI)
      { place: "Setup flow", act: { kind: "click", label: "Use your Claude Code CLI" }, expect: "Connect Claude|Before you begin", observe: true, note: "Opens the same provider setup sheet as Settings (no Settings navigation)." },
      { place: "Setup flow", act: { kind: "click", label: "Next", after: "Back" }, expect: "installation|Check", note: "The sheet's Next (after the sheet's Back), not the flow footer's." },
      { place: "Setup flow", act: { kind: "click", label: "Previous", after: "Choose which provider Tealbrick should use" }, harness: true, note: "The sheet's Previous (after the sheet's provider list), not the flow footer's." },
      { place: "Setup flow", act: { kind: "click", label: "Back" }, harness: true, expect: "Analyse your screen activity" },
      { place: "Setup flow", act: { kind: "click", label: "Claude, Ready to use" }, model: "same estimated sheet steps as the dev.8 path" },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "estimated flow step" },
      { place: "Setup flow", act: { kind: "click", label: "Test connection" }, model: "runs the Claude CLI on the person's plan (not run)" },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "estimated flow step" },
      { place: "Setup flow", act: { kind: "click", label: "Done" }, model: "estimated flow step" },
      { place: "Setup flow", act: { kind: "click", label: "Download", after: "Parakeet v3" }, model: "downloads ~465 MB (not run)" },
      { place: "Setup flow", act: { kind: "click", label: "Next" }, model: "needs the model; the script uses \"Skip for now\" (not counted)" },
      { place: "Setup flow", act: { kind: "click", label: "Skip for now" }, harness: true, expect: "things are off|Everything is ready", observe: true },

      // ---- 5 Summary
      { place: "Setup flow", act: { kind: "click", label: "Open TBD" }, expect: "Timeline|Daily|Chat", observe: true },
    ],
  },
};

// ---------------------------------------------------------------- AX driver (osascript -l JavaScript, by pid)

const AX_DRIVER = String.raw`
ObjC.import('ApplicationServices'); ObjC.import('Foundation');
function attr(el, name) { const out = Ref(); const err = $.AXUIElementCopyAttributeValue(el, $(name), out); return err === 0 ? out[0] : undefined; }
function str(v) { if (v === undefined || v === null) return ''; try { const o = ObjC.deepUnwrap(ObjC.castRefToObject(v)); return (o === null || o === undefined || typeof o === 'object') ? '' : String(o); } catch (e) { return ''; } }
function kids(el) { const c = attr(el, 'AXChildren'); if (c === undefined) return []; const arr = ObjC.castRefToObject(c); const res = []; for (let i = 0; i < arr.count; i++) res.push(arr.objectAtIndex(i)); return res; }
function walk(el, depth, out) {
  const role = str(attr(el, 'AXRole'));
  const rec = { role: role.replace('AX', ''), title: str(attr(el, 'AXTitle')), desc: str(attr(el, 'AXDescription')), value: str(attr(el, 'AXValue')).slice(0, 700), id: str(attr(el, 'AXIdentifier')), help: str(attr(el, 'AXHelp')), enabled: str(attr(el, 'AXEnabled')) !== 'false', depth: depth, el: el };
  rec.label = rec.desc || rec.title || rec.value || '';
  out.push(rec);
  for (const k of kids(el)) walk(k, depth + 1, out);
}
function tree(pid) { const app = $.AXUIElementCreateApplication(pid); const out = []; for (const w of kids(app)) { if (str(attr(w, 'AXRole')) === 'AXWindow') walk(w, 0, out); } return out; }
const PRESSABLE = ['Button', 'RadioButton', 'CheckBox', 'PopUpButton', 'MenuButton', 'MenuItem', 'DisclosureTriangle', 'Link', 'Tab'];
function cmd(a) {
  const els = tree(a.pid);
  if (a.cmd === 'dump') return JSON.stringify(els.map(r => ({ role: r.role, label: r.label, id: r.id, help: r.help, enabled: r.enabled, depth: r.depth })));
  if (a.cmd === 'press') {
    let pool = els;
    if (a.after) { const i = els.findIndex(r => r.label === a.after || r.value === a.after); if (i < 0) return JSON.stringify({ ok: false, why: 'anchor not found: ' + a.after }); pool = els.slice(i + 1); }
    const m = pool.filter(r => PRESSABLE.indexOf(r.role) >= 0 && r.label === a.label);
    const nth = a.nth || 0;
    if (m.length <= nth) return JSON.stringify({ ok: false, why: 'no pressable element labelled "' + a.label + '"' + (a.after ? ' after "' + a.after + '"' : '') + ' (matches=' + m.length + ')' });
    if (!m[nth].enabled) return JSON.stringify({ ok: false, why: 'element is disabled: ' + a.label });
    const err = $.AXUIElementPerformAction(m[nth].el, $('AXPress'));
    return JSON.stringify({ ok: err === 0 || err === -25200, err: err, matches: m.length });
  }
  if (a.cmd === 'set') {
    const m = els.filter(r => ['TextField', 'TextArea', 'ComboBox'].indexOf(r.role) >= 0 && (r.label === a.target || r.id === a.target || r.help === a.target));
    if (!m.length) return JSON.stringify({ ok: false, why: 'no text field ' + a.target });
    const err = $.AXUIElementSetAttributeValue(m[0].el, $('AXValue'), $(a.value));
    return JSON.stringify({ ok: err === 0, err: err });
  }
  return JSON.stringify({ ok: false, why: 'unknown cmd' });
}
`;

interface AxEl { role: string; label: string; id: string; help: string; enabled: boolean; depth: number }

function ax(pid: number, args: Record<string, unknown>): string {
  const src = `${AX_DRIVER}\ncmd(${JSON.stringify({ pid, ...args })});`;
  const r = spawnSync("osascript", ["-l", "JavaScript", "-e", src], { encoding: "utf8", timeout: 60_000 });
  if (r.status !== 0) throw new Error(`osascript failed: ${(r.stderr || "").trim().slice(0, 300)}`);
  return r.stdout.trim();
}
const axDump = (pid: number): AxEl[] => JSON.parse(ax(pid, { cmd: "dump" }));
const axPress = (pid: number, a: { label: string; nth?: number; after?: string }): { ok: boolean; why?: string; err?: number } =>
  JSON.parse(ax(pid, { cmd: "press", ...a }));

// ---------------------------------------------------------------- app, identity

const DEV_BUNDLE = "com.tealbrick.desktop.dev";
const HOME = os.homedir();
/** The dev identity's per-user locations (see native/Sources/TBDModels/TBDAppIdentity.swift). Dev names only. */
const DEV_FOLDERS = [
  path.join(HOME, "Library/Application Support/com.tealbrick.desktop-dev"),
  path.join(HOME, "Library/Application Support/com.tealbrick.desktop-dev-agent"),
  path.join(HOME, "Library/Logs/com.tealbrick.desktop-dev"),
  path.join(HOME, "Documents/TBD Desktop-dev"),
];

function sleep(ms: number): void { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function assertDevApp(app: string): void {
  const plist = path.join(app, "Contents/Info.plist");
  if (!fs.existsSync(plist)) throw new Error(`not an app bundle: ${app}`);
  const id = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", plist], { encoding: "utf8" }).trim();
  if (id !== DEV_BUNDLE) throw new Error(`refusing: bundle id is ${id}, expected ${DEV_BUNDLE}`);
  if (path.resolve(app).startsWith(path.join(HOME, "Applications") + "/")) throw new Error("refusing: app is under ~/Applications");
}

function findPids(app: string): number[] {
  const prefix = path.resolve(app) + "/Contents/MacOS/";
  return execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" })
    .split("\n").map((l) => l.trim()).filter((l) => l.slice(l.indexOf(" ") + 1).trim().startsWith(prefix))
    .map((l) => parseInt(l, 10));
}

function isMine(pid: number, app: string): boolean {
  const cmd = spawnSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" }).stdout.trim();
  return cmd.startsWith(path.resolve(app) + "/Contents/MacOS/");
}

/** Moves the dev identity aside (never deletes) and clears its defaults domain. Returns what was moved. */
function resetIdentity(into: string): string[] {
  fs.mkdirSync(into, { recursive: true });
  const moved: string[] = [];
  for (const dir of DEV_FOLDERS) {
    if (!/(-dev|-dev-agent)$|Desktop-dev$/.test(dir)) throw new Error(`refusing to move ${dir}`);
    if (fs.existsSync(dir)) { fs.renameSync(dir, path.join(into, path.basename(dir))); moved.push(dir); }
  }
  const plist = path.join(into, "defaults.plist");
  const exp = spawnSync("defaults", ["export", DEV_BUNDLE, plist], { encoding: "utf8" });
  if (exp.status === 0) { spawnSync("defaults", ["delete", DEV_BUNDLE]); moved.push(`defaults:${DEV_BUNDLE}`); }
  return moved;
}

function restoreIdentity(from: string): void {
  for (const dir of DEV_FOLDERS) {
    const src = path.join(from, path.basename(dir));
    if (!fs.existsSync(src)) continue;
    if (fs.existsSync(dir)) throw new Error(`${dir} exists: move the run's data aside first`);
    fs.renameSync(src, dir);
  }
  const plist = path.join(from, "defaults.plist");
  if (fs.existsSync(plist)) execFileSync("defaults", ["import", DEV_BUNDLE, plist]);
}

// ---------------------------------------------------------------- run

interface Observed { signals: string[]; shot?: string }
interface StepResult {
  n: number; place: string; action: string; mode: "performed" | "modelled"; clicks: number; relaunch: boolean;
  harness: boolean; tag?: string; reason?: string; note?: string; observed?: Observed; failed?: string;
}

function actionText(a: Act): string {
  switch (a.kind) {
    case "launch": return "open TBD";
    case "click": return `click "${a.label}"${a.after ? ` (after "${a.after}")` : ""}`;
    case "choose": return `choose "${a.option}" in "${a.label}"`;
    case "type": return `type: ${a.what}${a.secret ? " (secret, never typed)" : ""}`;
    case "external": return `external: ${a.what}`;
    case "relaunch": return "quit (Cmd-Q) and open TBD again";
  }
}

function defaultClicks(s: Step): number {
  if (s.clicks !== undefined) return s.clicks;
  switch (s.act.kind) {
    case "click": case "launch": return 1;
    case "choose": case "type": case "relaunch": return 2;
    case "external": throw new Error(`external step needs clicks: ${s.act.what}`);
  }
}

const DENY = /sign out|delete|erase|remove|uninstall|reset|clear|quit completely/i;

function main(): void {
  const argv = process.argv.slice(2);
  const opt = (k: string): string | undefined => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
  const has = (k: string): boolean => argv.includes(k);
  if (opt("--restore-from")) { restoreIdentity(opt("--restore-from")!); console.log("identity restored"); return; }

  const app = opt("--app"); const out = opt("--out"); const pathId = opt("--path") ?? "dev8";
  if (!app || !out) throw new Error("usage: fresh-run.ts --app <TBD.app> --out <dir> [--path dev8|dev9] [--reset-identity] [--identity <a-z0-9>] [--keep-running]");
  const def = PATHS[pathId]; if (!def) throw new Error(`unknown path ${pathId}; known: ${Object.keys(PATHS).join(", ")}`);
  assertDevApp(app);
  fs.mkdirSync(out, { recursive: true });
  const shots = path.join(out, `shots-${pathId}`); fs.mkdirSync(shots, { recursive: true });
  const ui = spawnSync("osascript", ["-e", 'tell application "System Events" to UI elements enabled'], { encoding: "utf8" }).stdout.trim();
  if (ui !== "true") throw new Error("UI scripting is not enabled for this shell");
  if (findPids(app).length) throw new Error("this app copy is already running; quit it first");

  let moved: string[] = [];
  if (has("--reset-identity")) moved = resetIdentity(path.join(out, "fresh-run-data", `pre-${Date.now()}`));

  const results: StepResult[] = [];
  const broken: { place: string; step: number; signal: string; detail: string }[] = [];
  let pid = 0;
  let shotsOk: boolean | null = null; let shotsWhy = "";
  const started = new Date().toISOString();

  const launch = (): void => {
    // --identity <x>: TBD_DEV_IDENTITY gives TBD Dev its own folders and Keychain services (DEBUG builds that have it).
    const identity = opt("--identity");
    spawnSync("open", identity ? ["-n", "--env", `TBD_DEV_IDENTITY=${identity}`, path.resolve(app)] : ["-n", path.resolve(app)]);
    for (let i = 0; i < 40 && !findPids(app).length; i++) sleep(500);
    const pids = findPids(app); if (!pids.length) throw new Error("app did not start");
    pid = pids[0];
    let ready = false;
    for (let i = 0; i < 50 && !ready; i++) { try { ready = axDump(pid).length > 5; } catch { /* not ready */ } if (!ready) sleep(500); }
    if (!ready) {
      spawnSync("kill", ["-TERM", String(pid)]);
      throw new Error("the app shows no window after 25 s. Its main thread may wait on a Keychain or macOS dialog (look for a SecurityAgent or UserNotificationCenter window): answer or dismiss it, then run again.");
    }
  };
  const waitFor = (re: string, ms = 10_000): boolean => {
    const rx = new RegExp(re, "i"); const end = Date.now() + ms;
    while (Date.now() < end) {
      try { if (axDump(pid).some((e) => rx.test(e.label))) return true; } catch { /* retry */ }
      sleep(600);
    }
    return false;
  };
  const screenshot = (n: number): string | undefined => {
    if (shotsOk === false) return undefined;
    const js = `ObjC.import('CoreGraphics');const a=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0,0)));a.filter(w=>w.kCGWindowOwnerPID===${pid}&&w.kCGWindowLayer===0&&w.kCGWindowBounds.Width>300).map(w=>w.kCGWindowNumber).join(',')`;
    const ids = spawnSync("osascript", ["-l", "JavaScript", "-e", js], { encoding: "utf8" }).stdout.trim().split(",").filter(Boolean);
    const file = path.join(shots, `step-${String(n).padStart(2, "0")}.png`);
    for (const id of ids) {
      const r = spawnSync("screencapture", ["-x", "-o", "-l", id, file], { encoding: "utf8" });
      if (r.status === 0 && fs.existsSync(file)) { shotsOk = true; return file; }
      shotsWhy = (r.stderr || "").trim();
    }
    if (shotsOk === null) shotsOk = false;
    if (!shotsWhy) shotsWhy = "no window of the app is on screen to capture";
    return undefined;
  };
  const observe = (n: number, place: string): Observed => {
    const els = axDump(pid); const found: string[] = [];
    for (const sig of def.signals) {
      const rx = new RegExp(sig.pattern, "i");
      const hit = els.find((e) => rx.test(e.label));
      if (hit) { found.push(sig.name); broken.push({ place, step: n, signal: sig.name, detail: hit.label.slice(0, 140) }); }
    }
    return { signals: found, shot: screenshot(n) };
  };

  def.steps.forEach((s, i) => {
    const n = i + 1;
    const res: StepResult = {
      n, place: s.place, action: actionText(s.act), mode: "modelled", clicks: s.harness ? 0 : defaultClicks(s),
      relaunch: s.act.kind === "relaunch", harness: !!s.harness, tag: s.tag, note: s.note,
    };
    const alwaysModelled = s.act.kind === "external" || s.act.kind === "relaunch";
    if (alwaysModelled) res.reason = "outside TBD, fixed cost, not done";
    else if (s.model) res.reason = s.model;
    else if (s.act.kind === "type" || s.act.kind === "choose") res.reason = "needs a value TBD must not get in this run";

    if (!alwaysModelled && !s.model && s.act.kind !== "type" && s.act.kind !== "choose") {
      try {
        if (s.act.kind === "launch") { launch(); }
        else if (s.act.kind === "click") {
          if (DENY.test(s.act.label)) throw new Error(`label "${s.act.label}" is on the deny list`);
          if (!isMine(pid, app)) throw new Error("target pid is not the launched dev app");
          const r = axPress(pid, { label: s.act.label, nth: s.act.nth, after: s.act.after });
          if (!r.ok) throw new Error(r.why ?? `AX error ${r.err}`);
        }
        res.mode = "performed";
        if (s.expect && !waitFor(s.expect)) res.note = `${res.note ? res.note + " " : ""}(expected text /${s.expect}/ did not show within 10 s)`;
      } catch (e) {
        res.failed = e instanceof Error ? e.message : String(e);
        res.reason = `could not perform: ${res.failed}`;
        res.mode = "modelled";
      }
    }
    if (s.observe && pid && res.mode === "performed") { try { res.observed = observe(n, s.place); } catch { /* keep going */ } }
    results.push(res);
    console.log(`${String(n).padStart(2)} ${res.mode.padEnd(9)} ${String(res.clicks).padStart(2)}  ${s.place} | ${res.action}${res.failed ? "  !! " + res.failed : ""}`);
  });

  if (pid && !has("--keep-running")) {
    if (isMine(pid, app)) { spawnSync("kill", ["-TERM", String(pid)]); for (let i = 0; i < 20 && isMine(pid, app); i++) sleep(500); if (isMine(pid, app)) spawnSync("kill", ["-KILL", String(pid)]); }
  }

  const counted = results.filter((r) => !r.harness);
  const sum = (f: (r: StepResult) => boolean): number => counted.filter(f).reduce((a, r) => a + r.clicks, 0);
  const placeList = [...new Set(counted.map((r) => r.place))];
  const totals = {
    clicksPerformed: sum((r) => r.mode === "performed"),
    clicksModelled: sum((r) => r.mode === "modelled"),
    clicksTotal: sum(() => true),
    places: placeList.length,
    placesList: placeList,
    relaunches: counted.filter((r) => r.relaunch).length,
    byTag: Object.fromEntries([...new Set(counted.map((r) => r.tag).filter(Boolean))].map((t) => [t, sum((r) => r.tag === t)])),
  };
  const uniqueBroken = [...new Map(broken.map((b) => [b.signal, b])).values()];
  const report = {
    path: def.id, version: def.version, goal: def.goal, app: path.resolve(app), startedAt: started, finishedAt: new Date().toISOString(),
    identityMovedAside: moved, fixedCosts: COST, totals, steps: results, looksBroken: uniqueBroken, looksBrokenAllSightings: broken,
    fromCode: def.fromCode,
    screenshots: shotsOk ? { ok: true, dir: shots } : { ok: false, why: shotsWhy || "not attempted" },
  };
  fs.writeFileSync(path.join(out, `baseline-${def.id}.json`), JSON.stringify(report, null, 2));
  fs.writeFileSync(path.join(out, `baseline-${def.id}.md`), markdown(report));
  console.log(JSON.stringify(totals, null, 2));
}

function markdown(r: { path: string; version: string; goal: string; totals: { clicksPerformed: number; clicksModelled: number; clicksTotal: number; places: number; placesList: string[]; relaunches: number; byTag: Record<string, number> }; steps: StepResult[]; looksBroken: { place: string; signal: string; detail: string }[]; fromCode: string[]; fixedCosts: Record<string, number>; screenshots: { ok: boolean; why?: string } }): string {
  const t = r.totals; const L: string[] = [];
  L.push(`# Fresh-identity baseline: ${r.version}`, "", `Goal: ${r.goal}`, "");
  L.push("| Measure | Value |", "|---|---|");
  L.push(`| Clicks performed (real, through Accessibility) | ${t.clicksPerformed} |`, `| Clicks modelled (fixed cost, not done) | ${t.clicksModelled} |`, `| **Clicks total** | **${t.clicksTotal}** |`, `| Places | ${t.places} |`, `| App relaunches | ${t.relaunches} |`, "");
  if (Object.keys(t.byTag).length) L.push(`Sub-totals by tag (already inside the total): ${Object.entries(t.byTag).map(([k, v]) => `${k} = ${v}`).join(", ")}`, "");
  L.push("Places: " + t.placesList.join("; "), "");
  L.push("Fixed costs used: " + Object.entries(r.fixedCosts).map(([k, v]) => `${k} = ${v}`).join(", "), "");
  L.push("## Steps", "", "| # | Place | Action | Mode | Clicks | Why modelled / note |", "|---|---|---|---|---|---|");
  for (const s of r.steps) {
    const why = [s.reason, s.note].filter(Boolean).join(" | ").replace(/\|/g, "/");
    L.push(`| ${s.n} | ${s.place} | ${s.action.replace(/\|/g, "/")}${s.harness ? " (script only)" : ""} | ${s.harness ? "harness" : s.mode} | ${s.harness ? 0 : s.clicks}${s.relaunch ? " (relaunch)" : ""} | ${why} |`);
  }
  L.push("", "## Looks broken before setup is complete (seen on screen)", "", "| State | Where | On-screen text |", "|---|---|---|");
  for (const b of r.looksBroken) L.push(`| ${b.signal} | ${b.place} | ${b.detail.replace(/\|/g, "/")} |`);
  L.push("", "## From the code (not seen on screen in this run)", "", ...r.fromCode.map((x) => `- ${x}`));
  L.push("", `Screenshots: ${r.screenshots.ok ? "captured" : "not captured (" + (r.screenshots.why ?? "") + ")"}`, "");
  return L.join("\n");
}

main();
