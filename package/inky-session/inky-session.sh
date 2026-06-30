#!/bin/sh
# InkyOS session supervisor.
#
# On the appliance there is no shell/desktop in the boot path -- this IS the UI.
# It brings up the Xvfb virtual display (Ren'Py needs a desktop-GL X server; the
# real e-ink panel is fed from captured frames, not a physical screen) and then
# keeps the game running, restarting it if it ever exits.
export HOME=/root
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
export SDL_AUDIODRIVER=dummy
# Socket paths the game's eink_hook.rpy / input_hook.rpy use. On hardware the
# e-ink SPI driver and the GPIO->uinput bridge attach here; harmless if absent.
export RENPY_EINK_SOCKET=/tmp/renpy-eink.sock
export RENPY_INPUT_SOCKET=/tmp/renpy-input.sock

GAME=/opt/the_question
RENPY=/opt/renpy/renpy.py
LOGDIR=/var/log
mkdir -p "$LOGDIR"

# Virtual framebuffer X server. -fbdir mmaps the current screen to an XWD file
# under /run, which the frame-capture path (and emulator verification) reads.
if [ ! -e /tmp/.X11-unix/X0 ]; then
	Xvfb :0 -screen 0 1280x720x24 -fbdir /run >"$LOGDIR/xvfb.log" 2>&1 &
fi
i=0
while [ ! -e /tmp/.X11-unix/X0 ] && [ "$i" -lt 100 ]; do
	i=$((i + 1)); sleep 0.1
done

# Supervise the game. The appliance never drops out of it: on exit/crash, relaunch.
while true; do
	python3 "$RENPY" "$GAME" >>"$LOGDIR/renpy.log" 2>&1
	echo "inky-session: renpy exited (rc=$?); restarting in 3s" >>"$LOGDIR/inky-session.log"
	sleep 3
done
