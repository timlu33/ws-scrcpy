#!/usr/bin/env bash
# Start a headless Android emulator, wait until it is booted, then start ws-scrcpy.
#
# Usage:
#   scripts/start-headless.sh [options] <avd-name>
#
# Options:
#   --cold         cold boot (ignore quick-boot snapshot)
#   --no-server    only start the emulator, do not start ws-scrcpy
#   --keep         keep the emulator running after ws-scrcpy exits
#   --timeout N    seconds to wait for boot (default: 180)
#   -h, --help     show this help
#
# Environment:
#   AVD            AVD name (alternative to the positional argument)
#   EMULATOR_ARGS  extra flags for the SDK `emulator` binary (fallback mode only),
#                  e.g. EMULATOR_ARGS="-gpu swiftshader_indirect -memory 2048 -cores 2"
#
# Emulator launch order:
#   1. `android emulator start --headless` (Android CLI), if `android` is on PATH
#   2. `emulator -avd <name> -no-window ...` (SDK emulator), otherwise
set -euo pipefail

COLD=0
START_SERVER=1
KEEP=0
TIMEOUT=180
AVD_NAME="${AVD:-}"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cold) COLD=1 ;;
    --no-server) START_SERVER=0 ;;
    --keep) KEEP=1 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) AVD_NAME="$1" ;;
  esac
  shift
done

if [ -z "$AVD_NAME" ]; then
  echo "Error: AVD name required (argument or \$AVD)." >&2
  command -v android >/dev/null 2>&1 && echo "Available AVDs: run 'android emulator list'" >&2
  exit 2
fi

command -v adb >/dev/null 2>&1 || { echo "Error: adb not found in PATH (ws-scrcpy needs it too)." >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMU_PID=""
EMU_SERIAL=""
STARTED_BY_US=0

list_emulators() { adb devices | awk '/^emulator-[0-9]+[[:space:]]+(device|offline)/ {print $1}' | sort; }

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ "$STARTED_BY_US" = 1 ] && [ "$KEEP" = 0 ]; then
    if [ -n "$EMU_SERIAL" ]; then
      echo "Stopping emulator $EMU_SERIAL ..."
      adb -s "$EMU_SERIAL" emu kill >/dev/null 2>&1 || true
    fi
    [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup EXIT INT TERM

adb start-server >/dev/null

BEFORE="$(list_emulators || true)"

if command -v android >/dev/null 2>&1; then
  echo "Starting headless emulator '$AVD_NAME' via Android CLI ..."
  ARGS=(emulator start --headless)
  [ "$COLD" = 1 ] && ARGS+=(--cold)
  ARGS+=("$AVD_NAME")
  # Blocks until the device is booted and ready for adb.
  STARTED_BY_US=1
  timeout "$TIMEOUT" android "${ARGS[@]}"
elif command -v emulator >/dev/null 2>&1; then
  echo "Starting headless emulator '$AVD_NAME' via SDK emulator ..."
  # shellcheck disable=SC2206
  EXTRA=(${EMULATOR_ARGS:-})
  ARGS=(-avd "$AVD_NAME" -no-window -no-audio -no-boot-anim)
  [ "$COLD" = 1 ] && ARGS+=(-no-snapshot-load)
  emulator "${ARGS[@]}" "${EXTRA[@]}" >"${TMPDIR:-/tmp}/emulator-$AVD_NAME.log" 2>&1 &
  EMU_PID=$!
  STARTED_BY_US=1
else
  echo "Error: neither 'android' (Android CLI) nor 'emulator' (SDK) found in PATH." >&2
  exit 1
fi

# Find the serial of the emulator we just started (new entry vs. before).
deadline=$((SECONDS + TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  AFTER="$(list_emulators || true)"
  EMU_SERIAL="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -n1)"
  [ -n "$EMU_SERIAL" ] && break
  if [ -n "$EMU_PID" ] && ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "Error: emulator exited early. See ${TMPDIR:-/tmp}/emulator-$AVD_NAME.log" >&2
    exit 1
  fi
  sleep 2
done
[ -n "$EMU_SERIAL" ] || { echo "Error: emulator did not show up in 'adb devices' within ${TIMEOUT}s." >&2; exit 1; }

echo "Waiting for $EMU_SERIAL to finish booting ..."
while [ $SECONDS -lt $deadline ]; do
  if [ "$(adb -s "$EMU_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    echo "Emulator ready: $EMU_SERIAL"
    break
  fi
  sleep 2
done
[ "$(adb -s "$EMU_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
  || { echo "Error: boot did not complete within ${TIMEOUT}s." >&2; exit 1; }

if [ "$START_SERVER" = 0 ]; then
  STARTED_BY_US=0   # caller wants the emulator left running
  echo "Skipping ws-scrcpy (--no-server). Emulator left running: $EMU_SERIAL"
  exit 0
fi

echo "Starting ws-scrcpy (open http://localhost:8000 and pick $EMU_SERIAL) ..."
cd "$ROOT"
if [ -f dist/package.json ]; then
  # Already built: skip the rebuild that `npm start` in the repo root performs.
  (cd dist && npm start)
else
  npm start
fi
