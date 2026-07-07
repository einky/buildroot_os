#!/bin/sh
# InkyOS session supervisor.
#
# On the appliance there is no shell/desktop in the boot path -- the LAUNCHER is
# the UI. This supervisor just keeps it running: the launcher owns the e-ink
# panel and the buttons for the whole uptime, renders the game library + settings
# itself, and spawns Ren'Py games as child processes when the player picks one
# (bringing up Xvfb on demand and forwarding frames/input over the engine-capture
# sockets). So there is nothing here to start besides the launcher.
#
# Per-target behaviour comes from /etc/default/inky-session (emulator vs Pi),
# which exports the EINKY_* backend selectors the launcher reads:
#   EINKY_DISPLAY_BACKEND   spi (panel) | tcp (emulator preview)
#   EINKY_INPUT_SOURCE      gpio (buttons) | tcp (emulator, host-forwarded)
#   EINKY_GAMES_DIR / EINKY_STATE_DIR / EINKY_SPI_DEV / ...
# The defaults compiled into the launcher are hardware-safe (spi/gpio); the
# emulator overlay flips them to tcp/tcp.

export HOME=/root

# Environment for Ren'Py games the launcher spawns (software GL under Xvfb, no
# audio, engine-capture socket paths). Harmless when no game is running.
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
export SDL_AUDIODRIVER=dummy
export RENPY_EINK_SOCKET=/tmp/renpy-eink.sock
export RENPY_INPUT_SOCKET=/tmp/renpy-input.sock

# Per-target backend selection (exports the EINKY_* variables).
[ -r /etc/default/inky-session ] && . /etc/default/inky-session

LOGDIR=/var/log
mkdir -p "$LOGDIR"

# Supervise the launcher: a crash must never wedge the box, so relaunch it.
while true; do
	inky-launcher >>"$LOGDIR/launcher.log" 2>&1
	echo "inky-session: launcher exited (rc=$?); restart in 3s" >>"$LOGDIR/inky-session.log"
	sleep 3
done
