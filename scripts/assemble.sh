#!/bin/bash
# Shared build steps for build.sh (development) and release.sh (Developer ID).
# Usage: source scripts/assemble.sh; tbd_assemble <Debug|Release> <derivedDataPath> <logDir>
# Result: $TBD_APP is a complete, unsigned TBD.app.
tbd_assemble() {
  local config="$1" derived="$2" logs="$3"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$logs"
  local node_bin="${TBD_NODE_SOURCE:-$("$root/scripts/fetch-node.sh")}"
  [ -x "$node_bin" ] || { echo "assemble: node binary missing: $node_bin" >&2; return 1; }

  (cd "$root/chat" && npm ci --no-audit --no-fund >/dev/null && npm run typecheck >/dev/null && node scripts/build-tbd.ts >"$logs/chat-build.log" 2>&1) \
    || { echo "assemble: chat build failed (see $logs)" >&2; return 1; }

  xcodebuild -project "$root/companion/Dayflow/Dayflow.xcodeproj" -scheme Dayflow -configuration "$config" \
    -derivedDataPath "$derived" -skipMacroValidation -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build >"$logs/app-build.log" 2>&1 \
    || { tail -40 "$logs/app-build.log"; echo "assemble: app build failed" >&2; return 1; }

  swift build -c release --package-path "$root/native" --scratch-path "$derived/native" --product tbd-listen >"$logs/listen-build.log" 2>&1 \
    || { tail -40 "$logs/listen-build.log"; echo "assemble: tbd-listen build failed" >&2; return 1; }

  TBD_APP="$derived/Build/Products/$config/TBD.app"
  [ -d "$TBD_APP" ] || { echo "assemble: expected $TBD_APP" >&2; return 1; }
  mkdir -p "$TBD_APP/Contents/Resources/Chat" "$TBD_APP/Contents/Helpers" "$TBD_APP/Contents/Resources/Licenses"
  rsync -a --delete "$root/chat/out/tbd/" "$TBD_APP/Contents/Resources/Chat/"
  ditto "$node_bin" "$TBD_APP/Contents/Resources/Chat/node"
  chmod +x "$TBD_APP/Contents/Resources/Chat/node"
  cp "$derived/native/release/tbd-listen" "$TBD_APP/Contents/Helpers/tbd-listen"
  cp "$root/companion/LICENSE" "$TBD_APP/Contents/Resources/Licenses/Companion-MIT.txt"
  cp "$root/chat/LICENSE" "$TBD_APP/Contents/Resources/Licenses/Chat-MIT.txt"
  # npm packages bundled into the Chat agents (written by chat/scripts/build-tbd.ts from esbuild's metafile).
  cp "$root/chat/out/tbd/THIRD-PARTY-NOTICES.txt" "$TBD_APP/Contents/Resources/Licenses/Chat-third-party.txt"
  cp "$root/native/LICENSE-Listening-GPL-3.0.txt" "$TBD_APP/Contents/Resources/Licenses/Listening-GPL-3.0.txt"
  cp "$root/native/NOTICE.md" "$TBD_APP/Contents/Resources/Licenses/Listening-NOTICE.md"
  # Third-party Swift package licences (FluidAudio, WhisperKit, GRDB, ...).
  local dir name
  for dir in "$derived/native/checkouts"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    for f in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING*; do
      if [ -f "$f" ]; then cp -f "$f" "$TBD_APP/Contents/Resources/Licenses/$name.txt"; break; fi
    done
  done
  local node_license; node_license="$(dirname "$(dirname "$node_bin")")/LICENSE"
  [ -f "$node_license" ] && cp -f "$node_license" "$TBD_APP/Contents/Resources/Licenses/Node.txt"
  export TBD_APP
}
