# Receives key commands from an external sender over a unix socket and
# injects them into Ren'Py's event system.
# Pairs with input_sender.py at the repo root.
#
# Wire protocol: one ASCII command per line (LF-terminated).
# Commands: up  down  left  right  enter  escape
#
# Socket path is overridable via RENPY_INPUT_SOCKET env var.

init python:
    import socket
    import os

    _input_sock_path = os.environ.get("RENPY_INPUT_SOCKET", "/tmp/renpy-input.sock")

    _input_state = {
        "server": None,
        "conn":   None,
        "buf":    b"",
    }

    # Simple name → Ren'Py keymap event name(s).
    # Values may be a string or a list — queue_event accepts both.
    _INPUT_COMMAND_MAP = {
        "up":         "focus_up",
        "down":       "focus_down",
        "left":       "focus_left",
        "right":      "focus_right",
        # K_RETURN fires dismiss + button_select + bar_activate/deactivate
        "enter":      ["dismiss", "button_select", "bar_activate", "bar_deactivate"],
        # K_SPACE fires only dismiss (advances dialog, does NOT click buttons)
        "space":      "dismiss",
        "escape":     "game_menu",
        # Allow raw keymap names through as well
        "dismiss":    "dismiss",
        "game_menu":  "game_menu",
        "focus_up":   "focus_up",
        "focus_down": "focus_down",
        "focus_left": "focus_left",
        "focus_right":"focus_right",
    }

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
            cmd = line.strip().decode("utf-8", errors="ignore").lower()
            event_name = _INPUT_COMMAND_MAP.get(cmd)
            if event_name:
                renpy.queue_event(event_name)

    _input_init()
    config.periodic_callbacks.append(_input_periodic)
