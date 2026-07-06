#!/bin/sh
# InkyOS post-build finalization -- shared by every target (emulator + Pi).
#
# Two jobs, identical on all boards:
#
# 1. Disable Buildroot's stock Xorg autostart. The appliance renders into Xvfb
#    (started by the inky-session service), so a VT-bound Xorg on display :0 is
#    unwanted and would contend for :0 / spew errors on a box with no real
#    display device. (rm -f is a no-op if the target has no S40xorg.)
#
# 2. Assemble /opt/games/the_question from the *stock* the_question that ships in
#    the renpy source tarball (built by the renpy package), then layer the InkyOS
#    game deltas on top: the two in-engine hooks (eink_hook.rpy / input_hook.rpy,
#    the latter generated from the hardware contract) plus the e-ink gui/options
#    overrides. All four live in board/common/the_question-eink/game/ so both the
#    emulator and the Pi assemble an identical game -- we do NOT vendor a second
#    copy of the game in git. Games live under /opt/games/<slug>/ so the launcher
#    can scan them (EINKY_GAMES_DIR=/opt/games); the two hooks are what every game
#    needs to feed frames/input to/from the launcher (ADR 0008/0009).
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
GAME_DST="$TARGET_DIR/opt/games/the_question"

# Stock the_question from the renpy source tree (renpy is built before finalize).
GAME_SRC="$(ls -d "$BUILD_DIR"/renpy-*/the_question 2>/dev/null | head -1)"
if [ -z "$GAME_SRC" ]; then
	echo "post-build: ERROR: stock the_question not found under $BUILD_DIR/renpy-*/" >&2
	exit 1
fi

# Stock game first, then the InkyOS deltas over game/ (the e-ink gui/options
# override the stock files; the two hooks are new files the stock tree lacks).
mkdir -p "$GAME_DST"
cp -a "$GAME_SRC/." "$GAME_DST/"
cp -a "$HERE/the_question-eink/game/." "$GAME_DST/game/"

# Presentation metadata for the launcher library (title/author). Optional --
# a bare game dir still shows up with its dirname as the title.
cat > "$GAME_DST/inky-manifest.toml" <<'EOF'
title = "The Question"
author = "Tom Rothamel"
sort_key = "010"
EOF

echo "post-build: assembled $GAME_DST from $GAME_SRC + InkyOS hooks/overrides"
