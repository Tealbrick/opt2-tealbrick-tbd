# Contributing to TBD (Tealbrick desktop)

This file is the short version. The full engineering practice is in the Tealbrick engineering handbook (`practice/ENGINEERING-HANDBOOK.md` in the private repo `Tealbrick/opt2-tealbrick-docs`). If the two disagree, the handbook wins.

## Rules that apply to every Tealbrick repo

1. **No secrets, ever.** No keys, tokens, passwords, `.env` files with values, connection strings, webhook URLs or customer data in code, tests, fixtures, logs, issues or commit messages. Use `.env.example` with placeholders. The CI `secret-scan` step (gitleaks) fails the build. If you commit a secret, rotate it before anything else.
2. **TypeScript only.** New code is `.ts` or `.tsx`. Node 24 runs `.ts` directly (type stripping): no enums, no parameter properties, `.ts` import extensions. Do not add `.js`, `.mjs` or `.cjs` source files, scripts or tests. Allowed JavaScript: generated build output (`dist/`), files a tool requires as JS, vendored third-party code.
3. **The CI file is generated.** `.woodpecker/ci.yaml` is a byte-identical copy of the platform template (a releasing repo also carries `.github/workflows/opt2-release.yml`; this repo has none, because releases are made on the release Mac). The `setup` step fails on drift. Change `tealbrick-ci.json`, or change the template in the platform repo. Never edit the copies. Adopt or upgrade with `node ci/tb-ci.ts adopt <repo dir> --kind <kind>` from the platform repo.
3a. **Supply chain.** Install with `--frozen-lockfile --ignore-scripts` (pnpm repos) or `npm ci --ignore-scripts` (this repo, which uses npm). Every GitHub-release tarball dependency carries `integrity` in the lockfile (`node ci/tb-ci.ts pin-tarballs <repo dir>` from the platform repo, after each dependency change). In pnpm repos the package manager version is hash-pinned (`packageManager`); this npm repo has no `packageManager` field. A Dockerfile never uses `VOLUME` (Railway refuses it).
4. **Changes go through a pull request.** `main` is the only long-lived branch. Work on short branches named `<type>/<id>-<slug>` (types: feat, fix, chore, docs, ci, sec, hotfix). PR title `<area>: <summary>`, body with a `Refs:` line, green required checks, no unrelated changes. Squash merge only; linear history; delete the branch after merge. CODEOWNERS routes reviews; while there is one human maintainer the review is an agent review recorded in the PR. Branch protection and CODEOWNERS are not set yet (GitHub Team, decision D1): until then the rule holds by convention. No force push, no history rewrite (C39).
5. **Traceability.** Every commit carries an id in a `Refs:` trailer or the subject: a decision (`C202`), an item (`BRG-13`, `SEC-01`, `QA R-1`) or an incident. Every release has notes (a `CHANGELOG.md` section per version is the target, enforced later).
6. **Tags are immutable and CI-only.** Tag only on a green pipeline. Never move or delete a tag. If a tag is wrong, cut the next version (L38). Release assets are uploaded only by the CI release Action, never by hand (L10, C76). Build before pack: a package whose `exports` target is missing fails the pack (C75).
7. **One mechanism per concern.** Shared vocabularies, constants, version thresholds and crypto come from `@opt2-tealbrick/spec` and `@opt2-tealbrick/manifest`. Never write a second copy (L1). A version threshold names the release that contains the rule (L26).
8. **Test the real path.** Every cross-component path needs one real-to-real test (L2). A fake comes from the shared rule, never from the side under test (L1). Silent failure is a bug: surface it as an error, a health signal or a monitor report (L3). Never change a product surface to make a test pass (L4). Assert the exact outcome, not the absence of the bad one (L27).
9. **Readers tolerate, writers stay strict.** A verifier ignores unknown values that cannot widen access. It refuses unknown values only where it would act on them (L24).
10. **Interfaces change through the spec.** If a contract is wrong or missing, change `specs` first (additive within a minor, breaking only in a major with a deprecation window). Do not fix it locally.
11. **Disk hygiene.** Delete your own clones, build output, `node_modules` and test copies when the work lands. `rm -rf` only on absolute paths inside your own scratch folder, with a guarded variable (`${VAR:?}`). Never `pkill` or kill by name on a shared machine (L16, L20, L37).
12. **UI work.** Render it in a real browser and check contrast before anyone reviews it (L35). Use the design kit (`@opt2-tealbrick/ui`) tokens only. The design guard (`check-system`) fails raw colours, fonts, radii and shadows.
13. **Docs.** Update this repo's `README.md` and `ARCHITECTURE.md` when behaviour changes. Canonical long-lived docs live in Forge (`projects/tealbrick`).

## Rules specific to this repo

- Read `AGENTS.md` first.
- No vendor telemetry. No editing of other apps' configuration files. Keep the person credential away from the agent.
- Do not launch a development build against live user data or sockets.

## Checks before you push

```sh
cd chat
npm run typecheck && npm test && npm run lint
```

Swift tests need macOS + Xcode. The Woodpecker pipeline is Linux only, so they are not in CI. Run them on a Mac:

```sh
cd native && swift test
xcodebuild test -project companion/Dayflow/Dayflow.xcodeproj -scheme Dayflow -derivedDataPath companion/build.noindex \
  -only-testing:DayflowTests ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

`scripts/release.sh` runs DayflowTests first and stops on a failure.

## Releasing

1. Run on the release Mac, from a clean tree at a pushed commit.
2. `TBD_RELEASE_TAG=v<x.y.z[-pre.N]> TBD_NOTARY_PROFILE=<profile> TBD_PUBLISH=1 scripts/release.sh`. Every pre-release bumps `CFBundleVersion`.
3. Add the index entry: `node ci/tb-ci.ts registry-add-desktop --product tbd --version <semver> --url <asset url> [--repo <repo>] --sha256 <hex> [--min-os 14.0]` from the platform repo. It downloads and checks the sha256. `--repo` is needed only with a dist host URL. Then `registry-sync`.
4. A stable release needs QA evidence and the owner's go. Delete DerivedData and build output after the build.
