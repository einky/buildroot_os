#!/usr/bin/env bash
# Run the InkyOS emulator end-to-end acceptance test on the HOST.
#
# It boots the emulator image (the exact run-qemu.sh command), drives a full
# unattended session over the host-forwarded frame/input ports, and asserts the
# boot golden, the game handoff, an in-game session, and a reboot recovery. See
# tests/e2e_emulator.py and docs/docs/software/inkyos-build.md.
#
# Build the image first:
#   ./build.sh qemu
#
# Usage:
#   ./run-e2e.sh                 # run the acceptance test
#   ./run-e2e.sh --bless         # regenerate the committed golden frame(s)
#   ./run-e2e.sh --auto-ports    # unique host ports (parallel runs)
# Any extra args pass straight through to tests/e2e_emulator.py.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"

# Prefer the launcher venv (Pillow + the shared frame_stream client are already
# installed there); fall back to the system python3.
PY="$REPO/../launcher/.venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "error: no python3 found (need Pillow for the e2e test)" >&2
  exit 1
fi

exec "$PY" "$REPO/tests/e2e_emulator.py" "$@"
