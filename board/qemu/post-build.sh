#!/bin/sh
# InkyOS post-build finalization (emulator target).
#
# Disable Buildroot's stock Xorg autostart. The appliance renders into Xvfb
# (started by the inky-session service), so a VT-bound Xorg on display :0 is
# unwanted and would otherwise contend for :0 / spew errors on a machine with
# no real display device.
#
# $1 is TARGET_DIR (Buildroot convention); further args come from
# BR2_ROOTFS_POST_SCRIPT_ARGS and are ignored here.
set -e
TARGET_DIR="$1"
rm -f "$TARGET_DIR/etc/init.d/S40xorg"
