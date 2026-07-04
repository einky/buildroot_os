#!/bin/sh
# InkyOS: refresh the boot config.txt from board/inky/config.txt on every image
# build, BEFORE the rpi genimage post-image packs boot.vfat.
#
# Why this exists: BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE only copies config.txt
# during rpi-firmware's *install* step, and Buildroot does NOT rebuild
# rpi-firmware when that option -- or board/inky/config.txt itself -- changes. So
# a regenerated config.txt (e.g. from scripts/gen_hardware.py after a hardware
# contract edit) would silently ship stale until a manual `rpi-firmware-dirclean`.
# Copying it here, on every image build, makes the SD image always carry the
# current config.txt.
#
# ORDER MATTERS: this must run *before* board/raspberrypizero2w-64/post-image.sh,
# which reads `kernel=` out of this same config.txt to build its genimage config.
# List it first in BR2_ROOTFS_POST_IMAGE_SCRIPT.
#
# Buildroot exports BINARIES_DIR (and friends) into post-image scripts' env.
set -e
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
install -D -m 0644 "$HERE/config.txt" "$BINARIES_DIR/rpi-firmware/config.txt"
echo "sync-config-txt: refreshed $BINARIES_DIR/rpi-firmware/config.txt from board/inky/config.txt"
