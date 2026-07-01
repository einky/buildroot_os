#!/bin/sh
# InkyOS post-build finalization (emulator target).
#
# Two jobs:
#
# 1. Disable Buildroot's stock Xorg autostart. The appliance renders into Xvfb
#    (started by the inky-session service), so a VT-bound Xorg on display :0 is
#    unwanted and would otherwise contend for :0 / spew errors on a machine with
#    no real display device.
#
# 2. Assemble /opt/the_question from the *stock* the_question that ships in the
#    renpy source tarball (built by the renpy package), then layer the InkyOS
#    deltas on top. We do NOT vendor a second copy of the game in git: the rootfs
#    overlay carries only the two InkyOS hooks (eink_hook.rpy / input_hook.rpy),
#    and the e-ink gui/options tweaks live in board/qemu/the_question-eink/.
#
# Buildroot passes TARGET_DIR as $1 and exports BASE_DIR (and friends) into the
# environment; further args from BR2_ROOTFS_POST_SCRIPT_ARGS are ignored here.
# BUILD_DIR is NOT exported, so derive it from BASE_DIR ($(BASE_DIR)/build).
set -e
TARGET_DIR="$1"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/build}"

rm -f "$TARGET_DIR/etc/init.d/S40xorg"

# --- assemble the game --------------------------------------------------------
GAME_DST="$TARGET_DIR/opt/the_question"

# Stock the_question from the renpy source tree (renpy is built before finalize).
GAME_SRC="$(ls -d "$BUILD_DIR"/renpy-*/the_question 2>/dev/null | head -1)"
if [ -z "$GAME_SRC" ]; then
	echo "post-build: ERROR: stock the_question not found under $BUILD_DIR/renpy-*/" >&2
	exit 1
fi

# Copy stock game UNDER the overlay-placed hooks (the stock tree has no
# eink_hook/input_hook, so the merge preserves them), then apply the e-ink
# gui/options overrides on top.
mkdir -p "$GAME_DST"
cp -a "$GAME_SRC/." "$GAME_DST/"
cp -a "$HERE/the_question-eink/game/." "$GAME_DST/game/"

echo "post-build: assembled $GAME_DST from $GAME_SRC + InkyOS hooks/overrides"
