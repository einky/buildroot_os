#!/bin/sh
# InkyOS session supervisor.
#
# On the appliance there is no shell/desktop in the boot path -- this IS the UI.
# It brings up the Xvfb virtual display (Ren'Py needs a desktop-GL X server; the
# real e-ink panel is fed from captured frames, not a physical screen), starts
# the einky `runtime` consumers that turn Ren'Py output into e-ink frames and
# button presses into Ren'Py events, then keeps the game running.
#
# The dangling in-engine hooks are wired here (ADR 0008):
#   * eink_hook.rpy  ships one PNG per stable frame to $RENPY_EINK_SOCKET;
#     `inky-eink-receiver` (runtime) consumes that socket, dithers + dispatches.
#   * input_hook.rpy serves $RENPY_INPUT_SOCKET and queues renpy_events for each
#     button NAME; the input bridge below feeds button names into that socket.
#
# Per-target behaviour comes from /etc/default/inky-session (emulator vs Pi):
#   EINK_BACKEND   spi (panel) | tcp/socket (emulator preview)   default: tcp
#   INPUT_MODE     gpio (runtime GPIO->xdotool) | net_sender     default: net_sender
# The defaults below are emulator-safe so the box boots even without that file.

export HOME=/root
export DISPLAY=:0
export LIBGL_ALWAYS_SOFTWARE=1
export SDL_AUDIODRIVER=dummy
# Contract socket paths ([protocol.engine_capture]); the engine hooks default to
# these and the runtime consumers use the same constants, so keep them in lockstep.
export RENPY_EINK_SOCKET=/tmp/renpy-eink.sock
export RENPY_INPUT_SOCKET=/tmp/renpy-input.sock

# ---- target configuration (overridable via /etc/default/inky-session) --------
EINK_BACKEND=tcp                 # emulator preview; set to "spi" on hardware
EINK_TCP_HOST=0.0.0.0            # TcpFrameSink bind (host preview connects here)
EINK_TCP_PORT=5333               # [protocol.frame] frame_tcp_port
EINK_SPI_DEV=/dev/spidev0.0      # [spi] dev (EINK_BACKEND=spi only)
INPUT_MODE=net_sender            # emulator in-engine socket; "gpio" on hardware
INPUT_FIFO=/run/inky-input       # name source for net_sender (one button name/line)
[ -r /etc/default/inky-session ] && . /etc/default/inky-session

GAME=/opt/the_question
RENPY=/opt/renpy/renpy.py
LOGDIR=/var/log
mkdir -p "$LOGDIR"

# Run a command in a background restart loop so a crash never wedges the UI.
supervise() {
	name="$1"; shift
	(
		while true; do
			"$@" >>"$LOGDIR/$name.log" 2>&1
			echo "inky-session: $name exited (rc=$?); restart in 3s" \
				>>"$LOGDIR/inky-session.log"
			sleep 3
		done
	) &
}

# Virtual framebuffer X server. -fbdir mmaps the current screen to an XWD file
# under /run, which the frame-capture path (and emulator verification) reads.
if [ ! -e /tmp/.X11-unix/X0 ]; then
	Xvfb :0 -screen 0 1280x720x24 -fbdir /run >"$LOGDIR/xvfb.log" 2>&1 &
fi
i=0
while [ ! -e /tmp/.X11-unix/X0 ] && [ "$i" -lt 100 ]; do
	i=$((i + 1)); sleep 0.1
done

# ---- frame consumer: in-engine PNG socket -> dither -> backend ---------------
# Same dither/dispatch as the X-capture path; only the *capture* differs (PNGs
# pushed by Ren'Py's eink_push_callback over RENPY_EINK_SOCKET).
case "$EINK_BACKEND" in
	spi)
		supervise eink-receiver env \
			EINKY_BACKEND=spi \
			EINKY_SPI_DEV="$EINK_SPI_DEV" \
			EINKY_EINK_SOCKET="$RENPY_EINK_SOCKET" \
			inky-eink-receiver
		;;
	*)
		# tcp/socket preview (emulator). tcp binds + drops frames when no client
		# is attached, so the receiver never crashes on a headless box.
		supervise eink-receiver env \
			EINKY_BACKEND="$EINK_BACKEND" \
			EINKY_TCP_HOST="$EINK_TCP_HOST" \
			EINKY_TCP_PORT="$EINK_TCP_PORT" \
			EINKY_EINK_SOCKET="$RENPY_EINK_SOCKET" \
			inky-eink-receiver
		;;
esac

# ---- input bridge: button names -> Ren'Py ------------------------------------
case "$INPUT_MODE" in
	gpio)
		# Hardware: runtime's GPIO handler reads the buttons (libgpiod via
		# gpiozero) and injects the mapped keysyms into the focused X window.
		supervise input-bridge env EINKY_INPUT_BACKEND=gpio inky-input
		;;
	*)
		# Emulator: feed button names into the in-engine input socket via
		# runtime's net_sender. The names come from $INPUT_FIFO (a test or a
		# host-forwarded channel writes one button name per line); net_sender
		# maps each to its renpy_events through input_hook.rpy.
		[ -p "$INPUT_FIFO" ] || { rm -f "$INPUT_FIFO"; mkfifo "$INPUT_FIFO"; }
		supervise input-bridge sh -c \
			'exec python3 -m input.net_sender < "$1"' inky-net-sender "$INPUT_FIFO"
		;;
esac

# Supervise the game. The appliance never drops out of it: on exit/crash, relaunch.
while true; do
	python3 "$RENPY" "$GAME" >>"$LOGDIR/renpy.log" 2>&1
	echo "inky-session: renpy exited (rc=$?); restarting in 3s" >>"$LOGDIR/inky-session.log"
	sleep 3
done
