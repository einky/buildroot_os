#!/usr/bin/env bash
# Boot the InkyOS EMULATOR image on the host with the exact working QEMU command.
#
# QEMU runs on the HOST, not in the build container (unlike ./br.sh). Build the
# image first with:  ./build.sh qemu
#
# Usage:
#   ./run-qemu.sh                 # boot output-qemu/images
#   INKY_OUT=output-qemu2 ./run-qemu.sh   # boot a different output dir
#   INKY_FRAME_HOSTPORT=15333 INKY_INPUT_HOSTPORT=15334 ./run-qemu.sh  # unique host ports
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

# Emulator output dir (matches build.sh / br.sh's INKY_OUT). Default: output-qemu.
INKY_OUT="${INKY_OUT:-output-qemu}"
IMAGES="$REPO/$INKY_OUT/images"

# Host-side forwarded ports. The GUEST always listens on 5333 (frames) / 5334
# (input); only the localhost side of the forward is overridable, so the e2e
# harness (tests/e2e_emulator.py) can run parallel VMs without port collisions.
FRAME_HOSTPORT="${INKY_FRAME_HOSTPORT:-5333}"
INPUT_HOSTPORT="${INKY_INPUT_HOSTPORT:-5334}"

# Auto-detect kernel + rootfs produced by the qemu_aarch64_virt build.
KERNEL="$IMAGES/Image"
ROOTFS="$IMAGES/rootfs.ext4"        # symlink -> rootfs.ext2

if [ ! -f "$KERNEL" ] || [ ! -e "$ROOTFS" ]; then
  echo "error: emulator image not found under $IMAGES/" >&2
  echo "       expected $KERNEL and $ROOTFS" >&2
  echo "       build it first:  ./build.sh qemu" >&2
  exit 1
fi

echo ">>> Booting $INKY_OUT  (login: root, no password)"
echo ">>> Exit QEMU with: Ctrl-A then X"
echo

# Headless serial console (-serial mon:stdio -display none): the kernel console and
# the QEMU monitor are muxed onto this terminal. rootwait waits for the virtio-blk
# device; root is on /dev/vda. This is the exact command verified to reach a login prompt.
# hostfwd tcp::$FRAME_HOSTPORT exposes the guest e-ink frame preview (the
# launcher's TcpBackend on guest :5333) to a host preview tool; tcp::$INPUT_HOSTPORT
# exposes the launcher's TcpSource (guest :5334) so a host key sender (launcher
# tools/send_input.py) can drive the buttons.
exec qemu-system-aarch64 -M virt -cpu cortex-a53 -m 512 -smp 4 \
  -kernel "$KERNEL" \
  -append "rootwait root=/dev/vda console=ttyAMA0" \
  -drive "file=$ROOTFS,if=none,format=raw,id=hd0" \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=eth0,hostfwd=tcp::${FRAME_HOSTPORT}-:5333,hostfwd=tcp::${INPUT_HOSTPORT}-:5334 -device virtio-net-device,netdev=eth0 \
  -serial mon:stdio -display none
