#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ClipDeck"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_PATH="/Applications/$APP_NAME.app"

"$ROOT_DIR/script/terminate_running_clipdeck.sh"
"$ROOT_DIR/script/package_app.sh" release "$INSTALL_PATH"

# Do not force a new process. The Info.plist also prohibits multiple instances.
/usr/bin/open "$INSTALL_PATH"

echo "Installed release build at $INSTALL_PATH"
echo "ClipDeck manages login launch through macOS Login Items; any validated legacy LaunchAgent is migrated by the installed app."
