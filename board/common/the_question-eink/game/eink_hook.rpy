# Ships one PNG per stable frame to an external receiver over a unix socket.
# Pairs with eink_receiver.py at the repo root.

## Device memory budget (Pi Zero 2 W: 512 MB RAM, no disk swap). Ren'Py's stock
## image cache is 400 MB -- larger than half the box's RAM -- which OOM-kills the
## game on this hardware. An 800x480 1-bit panel needs only a small cache. Set
## in the e-ink hook so it applies to every game the launcher runs on-device.
## Tunable: raise if images visibly re-decode (thrash), lower if memory is tight.
define config.image_cache_size_mb = 64

init python:
    import socket
    import struct
    import io
    import time
    import os

    _eink_sock_path = os.environ.get("RENPY_EINK_SOCKET", "/tmp/renpy-eink.sock")
    _eink = {"sock": None, "next_retry": 0.0, "last_png": None}

    def _eink_connect():
        if _eink["sock"] is not None:
            return _eink["sock"]
        now = time.time()
        if now < _eink["next_retry"]:
            return None
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(_eink_sock_path)
            _eink["sock"] = s
            return s
        except (socket.error, OSError):
            _eink["next_retry"] = now + 2.0
            return None

    def _eink_drop():
        if _eink["sock"] is not None:
            try:
                _eink["sock"].close()
            except Exception:
                pass
        _eink["sock"] = None
        _eink["next_retry"] = time.time() + 2.0

    def _eink_send(data):
        s = _eink_connect()
        if s is None:
            return
        try:
            s.sendall(struct.pack("!I", len(data)) + data)
        except (socket.error, OSError, BrokenPipeError):
            _eink_drop()

    def _eink_push(surftree):
        # Encode even when disconnected: a prewarmed game (launcher hasn't
        # bound the receiver yet) keeps its latest stable frame cached so
        # adoption can display the current screen without waiting for the
        # next interaction.
        try:
            surf = renpy.display.draw.screenshot(surftree)
            buf = io.BytesIO()
            renpy.display.module.save_png(surf, buf, 0)
            data = buf.getvalue()
        except Exception:
            return
        _eink["last_png"] = data
        _eink_send(data)

    def _eink_resend_on_reconnect():
        # Runs ~20 Hz (PERIODIC): a no-op unless we are disconnected with a
        # frame cached — the idle-prewarmed case, where no new interaction
        # fires the push callback. _eink_connect rate-limits reconnection to
        # one attempt per 2 s, so this stays cheap.
        if _eink["sock"] is not None or _eink["last_png"] is None:
            return
        if _eink_connect() is not None:
            _eink_send(_eink["last_png"])

    config.periodic_callbacks.append(_eink_resend_on_reconnect)
    config.eink_push_callback = _eink_push
