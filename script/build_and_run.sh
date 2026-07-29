#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClipDeck"
BUNDLE_ID="com.qiaoni.clipdeck"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

"$ROOT_DIR/script/terminate_running_clipdeck.sh"
"$ROOT_DIR/script/package_app.sh" debug "$APP_BUNDLE"

open_app() {
  # A normal LaunchServices open reuses the bundle instance. Never use `open -n`:
  # it can stack a debug copy behind the installed app with the same bundle ID.
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    /usr/bin/pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
