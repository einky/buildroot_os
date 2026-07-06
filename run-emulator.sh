#!/usr/bin/env bash
# Boot the InkyOS EMULATOR image AND open a preview window on the host, so you
# see and drive the e-ink UI on your laptop.
#
# The device has no VGA/GPU screen: the UI is an 800x480 1-bit e-ink panel. In
# emulation the launcher (auto-started at boot with EINKY_DISPLAY_BACKEND=tcp)
# streams frames over guest TCP :5333 and takes button input on :5334, both
# forwarded to localhost by run-qemu.sh. This script starts the Tk preview
# client (launcher/tools/dev_preview.py) against those ports, then boots QEMU in
# the foreground.
#
#   Preview window : the e-ink screen, and the gamepad — arrows/wasd move,
#                    j=A, k=B, Enter=Start, h=hold-Start (exit a game).
#   Terminal       : the guest serial console + QEMU monitor (login: root, no
#                    password). Quit everything with Ctrl-A then X.
#
# Build the image first:  ./build.sh qemu
#
# Usage:
#   ./run-emulator.sh                    # scale 2x preview
#   PREVIEW_SCALE=3 ./run-emulator.sh    # bigger window
#   INKY_OUT=output-qemu2 ./run-emulator.sh
#   NO_PREVIEW=1 ./run-emulator.sh       # boot QEMU only (same as ./run-qemu.sh)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
INKY_OUT="${INKY_OUT:-output-qemu}"
IMAGES="$REPO/$INKY_OUT/images"
PREVIEW_SCALE="${PREVIEW_SCALE:-2}"
PREVIEW="$REPO/../launcher/tools/dev_preview.py"

# Ports the launcher's tcp backend/source use, forwarded to localhost by run-qemu.sh.
FRAME_PORT=5333
INPUT_PORT=5334

if [ ! -f "$IMAGES/Image" ] || [ ! -e "$IMAGES/rootfs.ext4" ]; then
  echo "error: emulator image not found under $IMAGES/" >&2
  echo "       build it first:  ./build.sh qemu" >&2
  exit 1
fi

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  echo "error: qemu-system-aarch64 not found on the host — install QEMU." >&2
  exit 1
fi

preview_pid=""
if [ "${NO_PREVIEW:-0}" != "1" ]; then
  if [ ! -f "$PREVIEW" ]; then
    echo "warn: preview tool not found at $PREVIEW — booting QEMU only." >&2
  elif ! python3 -c "import tkinter, PIL" >/dev/null 2>&1; then
    echo "warn: python3 tkinter + Pillow are required for the preview window." >&2
    case "$(. /etc/os-release 2>/dev/null && echo "${ID:-}")" in
      arch|manjaro) echo "      install:  sudo pacman -S --needed tk python-pillow" >&2 ;;
      debian|ubuntu) echo "      install:  sudo apt install python3-tk python3-pil.imagetk" >&2 ;;
      fedora)       echo "      install:  sudo dnf install python3-tkinter python3-pillow-tk" >&2 ;;
      *)            echo "      install your distro's python3 tkinter + Pillow packages." >&2 ;;
    esac
    echo "      booting QEMU only; attach later with:" >&2
    echo "        python3 $PREVIEW --wait --scale $PREVIEW_SCALE --input-port $INPUT_PORT" >&2
  else
    echo ">>> Opening preview window (scale ${PREVIEW_SCALE}x) on localhost:$FRAME_PORT"
    python3 "$PREVIEW" --wait --scale "$PREVIEW_SCALE" \
      --port "$FRAME_PORT" --input-port "$INPUT_PORT" &
    preview_pid=$!
  fi
fi

# Make sure the preview window dies with QEMU.
cleanup() {
  if [ -n "$preview_pid" ] && kill -0 "$preview_pid" 2>/dev/null; then
    kill "$preview_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo ">>> Booting $INKY_OUT  (login: root, no password).  Quit: Ctrl-A then X"
echo
# Run in the foreground (not exec) so the cleanup trap fires and closes the
# preview window when QEMU exits.
INKY_OUT="$INKY_OUT" "$REPO/run-qemu.sh"
