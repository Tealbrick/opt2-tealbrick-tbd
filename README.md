# TBD (Tealbrick desktop)

The free Tealbrick desktop app for macOS 14 and later on Apple silicon. It is one native app with three parts:

- **Chat** (`chat/`): React UI in a WKWebView, with a bundled Node 24 helper over private stdio. Chat with the agents of your workspace.
- **Companion** (`companion/`): the native host (Xcode project). Screen timeline, daily and weekly review.
- **Listen** (`native/`): local, offline speech-to-text, dictation, transcription and meetings, written as a Tealbrick Swift package.

In Tealbrick, TBD is registered as an **agent card**. The person signs in to Portal; TBD's default agent has its own agent identity (harness `tbd-default`). The person's credential never reaches an agent.

- Repository: `Tealbrick/opt2-tealbrick-tbd` (GitHub organisation `Tealbrick`)
- Visibility target: PRIVATE. The repo is PUBLIC for now (checked 2026-10-17). It must keep building without GitHub authentication.
- Licence: Proprietary app. There is no `LICENSE` or `NOTICE` file at the repo root; licence texts sit in the subtrees (`chat/LICENSE`, `companion/LICENSE`, `native/LICENSE-Listening-GPL-3.0.txt`, `native/NOTICE.md`). It contains MIT code (Chat upstream, Dayflow fork) and a Tealbrick rewrite of the features of a GPL-3.0 speech-to-text app, with the GPL-3.0 text bundled. See "Donor code and licences" below.
- Status: pre-release `v0.1.0-dev.4` (notarized). Chat package 0.7.0, app version 0.1.0. CI template ci-v9.9. No stable release: a stable release needs QA evidence and an owner decision.

Do not put secrets, tokens, keys, customer data or personal data in this repository, its issues or its pull requests. This repository is public for now and must stay clean either way: no API keys, tokens, passwords, private keys, `.env` files, connection strings, personal names, private agent configurations or customer data. Every CI run starts with a secret scan (gitleaks, a step in `.woodpecker/ci.yaml`). GitHub secret scanning and push protection are NOT enabled on this repository; the CI scan is the guard. An optional local guard is `pre-commit install` (`.pre-commit-config.yaml` runs gitleaks). If a secret is committed, rotate it first, then remove it from history.

## What this repo is and is not

TBD is NOT a Portal client for owner actions beyond reads and drafts, and it does not edit other apps' configuration files. It has no vendor telemetry.

## Donor code and licences

- `chat/` started from an MIT-licensed upstream chat client (see `chat/LICENSE`).
- `companion/` is a fork of Dayflow (MIT, see `companion/LICENSE`; the upstream version at fork time is not recorded in the repo).
- Listening (`native/`) is a Tealbrick rewrite of the features of MacParakeet (GPL-3.0); see `native/NOTICE.md` and `native/LICENSE-Listening-GPL-3.0.txt`.

## Quick start

Chat (Linux-capable, what CI covers):

```sh
cd chat && npm ci
npm run typecheck && npm test && npm run lint
npm run build     # vite renderer + Node helper + agent and relay bundles (esbuild)
```

Native (macOS only): `scripts/assemble.sh` and `scripts/build.sh` (Release config, production identity, local signing identity). Debug builds use a separate identity ("TBD Dev", bundle `com.tealbrick.desktop.dev`, own folders and keychain services). The live app is `com.tealbrick.desktop` (TBD v2's own identity; the archived v1 app `com.tealbrick.tbd` is never touched). Do not run development builds against live user data.

## Layout

| Path | Purpose |
|---|---|
| `chat/` | `tbd-chat`: React renderer in a WKWebView, bundled Node 24 helper over stdio, default agent (`src/agent/main.ts`) and relay (`src/agent/relay.ts`) |
| `companion/Dayflow/` | Xcode project (scheme `Dayflow`, product `TBD`): fork of Dayflow (screen timeline, review), `dayflow` CLI helper, agent write channel |
| `native/` | SwiftPM `TBDNative`: Listening (speech, library, dictation, meetings, vocabulary, transforms, "Save to Knowledge"), design, models, `tbd-listen` CLI |
| `design/` | Guard baseline |
| `scripts/` | `assemble.sh`, `build.sh`, `release.sh`, `fetch-node.sh`, `tbd` launcher, entitlements |
| `tests/` | Swift tests of the app host (more Swift tests: `native/Tests`, `companion/Dayflow/DayflowTests`; Chat tests: `chat/test`) |
| `tealbrick-ci.json` | CI settings (kind `desktop`, path `chat/`) |
| `AGENTS.md` | Rules for agents and contributors on this repo |

## Configuration

Release Mac only: `TBD_RELEASE_IDENTITY`, `TBD_RELEASE_TEAM`, `TBD_NOTARY_PROFILE`, `TBD_PUBLISH`, `TBD_RELEASE_TAG`, `TBD_BUILD_NUMBER`, `TBD_SIGN_IDENTITY`. Runtime: the person chooses model providers (local Ollama or Anthropic) in Settings.

## CI and release

Woodpecker with the shared opt2 template ci-v9.9 (`.woodpecker/ci.yaml`, kind `desktop`, `tealbrick-ci.json` points at `chat/`): secret scan, install, typecheck, lint (biome, design tokens check, design guard), tests and build on Linux. Library pins come from the dist host.

The macOS part is not in CI: the native app, `native/` Swift tests, signing, notarization and publishing run on the release Mac with `scripts/release.sh` (one assembly path with `scripts/build.sh`, via `scripts/assemble.sh`). A tag containing `-` is published as a GitHub pre-release; a stable release needs QA evidence and an owner decision. The release Mac then adds the desktop entry to the signed index (`registry-add-desktop`). The app's updater reads the signed index.

## Language

New code is TypeScript (Node 24+). Swift for the native macOS host and speech-to-text.

## Documentation

- `ARCHITECTURE.md` explains the design.
- `CONTRIBUTING.md` explains how to change it.
- `AGENTS.md` holds the working rules for this repo.
- Today TBD pins the pre-split `@opt2-tealbrick/bridge` and `harness-claude` tarballs from the dist host (`Tealbrick/opt2-tealbrick-dist`). The relay and harness packages of `Tealbrick/opt2-tealbrick-cli` are the planned replacement; no relay release is on the dist host yet.
- System documentation (overview, environments, runbooks) lives in the private repo Tealbrick/opt2-tealbrick-docs.
