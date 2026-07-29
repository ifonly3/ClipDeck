#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/ClipDeck.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ClipDeck is not installed at $APP_PATH. Run ./script/install_release.sh first." >&2
  exit 1
fi

# Registration is intentionally performed by the signed installed app through
# SMAppService.mainApp. This script never writes a LaunchAgent plist.
/usr/bin/open "$APP_PATH"
echo "ClipDeck now manages login launch with macOS Login Items. Use ClipDeck Settings to change it."
