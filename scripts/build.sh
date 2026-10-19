#!/bin/bash
# The owner's own TBD.app (C150): the Release configuration with the production identity (com.tealbrick.desktop, the
# person's real data), assembled like release.sh and signed with a local identity (or ad hoc with TBD_SIGN_IDENTITY=-).
# The Debug configuration is "TBD Dev" (com.tealbrick.desktop.dev, its own data) for development and screenshots only;
# build it from Xcode or xcodebuild, never with this script. Build output is deleted with --clean.
set -euo pipefail
TBD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$TBD_ROOT/companion/build.noindex"
if [ "${1:-}" = "--clean" ]; then rm -rf "$DERIVED" "$TBD_ROOT/chat/out"; echo "Removed build output."; exit 0; fi
for config in Release Debug; do   # Debug: an app built by an earlier version of this script
  if ps -axo comm | /usr/bin/grep -Fqx "$DERIVED/Build/Products/$config/TBD.app/Contents/MacOS/TBD"; then
    echo 'Quit the running TBD app (built by this script) before rebuilding it.' >&2; exit 1
  fi
done
source "$TBD_ROOT/scripts/assemble.sh"
tbd_assemble Release "$DERIVED" "$DERIVED/logs"
IDENTITY="${TBD_SIGN_IDENTITY:?set TBD_SIGN_IDENTITY to a local codesigning identity (name, SHA-1, or - for ad hoc)}"
for helper in "$TBD_APP"/Contents/Helpers/*; do codesign --force --sign "$IDENTITY" --timestamp=none "$helper"; done
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP/Contents/Resources/Chat/node"
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP/Contents/Resources/Chat/claude"
codesign --force --sign "$IDENTITY" --timestamp=none "$TBD_APP"
codesign --verify --strict "$TBD_APP"
printf 'Built: %s\n' "$TBD_APP"
if [ -d "$DERIVED/Build/Products/Debug/TBD.app" ]; then
  printf 'Note: the app is now built at Build/Products/Release; the copy under Build/Products/Debug is an older build (open the Release one).\n'
fi
