#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ClipDeck"
PIDS=()

set +e
PGREP_OUTPUT="$(pgrep -x "$APP_NAME" 2>&1)"
PGREP_STATUS=$?
set -e

case "$PGREP_STATUS" in
  0)
    ;;
  1)
    exit 0
    ;;
  *)
    echo "Unable to inspect running ClipDeck processes: $PGREP_OUTPUT" >&2
    exit "$PGREP_STATUS"
    ;;
esac

while IFS= read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || {
    echo "Unexpected process identifier returned by pgrep: $pid" >&2
    exit 1
  }

  if ! command_path="$(ps -p "$pid" -o command= 2>/dev/null)"; then
    if kill -0 "$pid" 2>/dev/null; then
      echo "Unable to inspect ClipDeck process $pid; installation stopped." >&2
      exit 1
    fi
    continue
  fi

  case "$command_path" in
    */ClipDeck.app/Contents/MacOS/ClipDeck)
      PIDS+=("$pid")
      ;;
    *)
      echo "Process $pid is named ClipDeck but has an unexpected executable: $command_path" >&2
      exit 1
      ;;
  esac
done <<<"$PGREP_OUTPUT"

for pid in "${PIDS[@]}"; do
  if ! current_path="$(ps -p "$pid" -o command= 2>/dev/null)"; then
    continue
  fi
  case "$current_path" in
    */ClipDeck.app/Contents/MacOS/ClipDeck)
      ;;
    *)
      echo "Process $pid changed identity before termination; installation stopped." >&2
      exit 1
      ;;
  esac

  if ! kill -TERM "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    echo "Unable to terminate ClipDeck process $pid; installation stopped." >&2
    exit 1
  fi
done

for _ in {1..50}; do
  remaining=false
  for pid in "${PIDS[@]}"; do
    if ! current_path="$(ps -p "$pid" -o command= 2>/dev/null)"; then
      continue
    fi
    case "$current_path" in
      */ClipDeck.app/Contents/MacOS/ClipDeck)
        remaining=true
        break
        ;;
      *)
        # The original process exited and the PID was reused; never signal it.
        continue
        ;;
    esac
  done
  if [[ "$remaining" == false ]]; then
    exit 0
  fi
  sleep 0.1
done

echo "ClipDeck did not terminate cleanly; installation stopped to avoid a second instance." >&2
exit 1
