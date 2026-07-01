# InkyOS in-engine input hook.
#
# Serves $RENPY_INPUT_SOCKET ([protocol.engine_capture] input_socket) and turns
# each incoming button NAME into the Ren'Py keymap event(s) it maps to. The wire
# format is the shared `ascii-lines` encoding (one button name per line); the
# names and their renpy_events come straight from meta/shared/hardware.toml.
#
# The runtime side that feeds this socket is started by inky-session
# (emulator: `python -m input.net_sender`; hardware uses the GPIO->xdotool path
# instead). See ADR 0008.
#
# Socket path is overridable via RENPY_INPUT_SOCKET.

init python:
    import socket
    import os

    _input_sock_path = os.environ.get("RENPY_INPUT_SOCKET", "/tmp/renpy-input.sock")

    _input_state = {
        "server": None,
        "conn":   None,
        "buf":    b"",
    }

    # Button NAME -> renpy_events, derived from meta/shared/hardware.toml.
    # >>> GENERATED button-map (scripts/gen_hardware.py --check enforces parity) >>>
    _INPUT_COMMAND_MAP = {
        "up": ["focus_up"],
        "down": ["focus_down"],
        "left": ["focus_left"],
        "right": ["focus_right"],
        "a": ["dismiss"],
        "b": ["game_menu"],
        "start": ["dismiss", "button_select", "bar_activate", "bar_deactivate"],
    }
    # <<< GENERATED button-map <<<

    def _input_init():
        if os.path.exists(_input_sock_path):
            try:
                os.unlink(_input_sock_path)
            except OSError:
                pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(_input_sock_path)
        server.listen(1)
        server.setblocking(False)
        try:
            os.chmod(_input_sock_path, 0o600)
        except OSError:
            pass
        _input_state["server"] = server

    def _input_dispatch(name):
        # hardware.toml values are lists; renpy.queue_event takes one event name
        # at a time, so queue each in order.
        events = _INPUT_COMMAND_MAP.get(name)
        if not events:
            return
        for event_name in events:
            renpy.queue_event(event_name)

    def _input_periodic():
        state = _input_state
        server = state["server"]
        if server is None:
            return

        # Accept a new connection if none is active
        if state["conn"] is None:
            try:
                conn, _ = server.accept()
                conn.setblocking(False)
                state["conn"] = conn
                state["buf"] = b""
            except (BlockingIOError, OSError):
                return

        # Read whatever data is available (non-blocking)
        try:
            data = state["conn"].recv(256)
            if not data:
                # Sender disconnected cleanly — ready for next connection
                state["conn"].close()
                state["conn"] = None
                return
            state["buf"] += data
        except BlockingIOError:
            pass
        except OSError:
            state["conn"] = None
            return

        # Process every complete line in the buffer
        while b"\n" in state["buf"]:
            line, state["buf"] = state["buf"].split(b"\n", 1)
            name = line.strip().decode("ascii", errors="ignore").lower()
            _input_dispatch(name)

    _input_init()
    config.periodic_callbacks.append(_input_periodic)
