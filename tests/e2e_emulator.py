#!/usr/bin/env python3
"""End-to-end acceptance test for the InkyOS QEMU emulator image.

Boots the emulator image with the *exact* QEMU command from ``run-qemu.sh``
(virt / -m 512 / host-forwarded frame+input ports), then drives a full
unattended session over the two TCP ports and asserts, in order:

  1. boot   -- the launcher's first frame arrives and matches a committed
               golden 1-bit frame (the library home screen);
  2. input  -- a button press round-trips (Settings opens and closes);
  3. game   -- launching ``the_question`` hands the panel to the game: frames
               start flowing and differ from the library (game frames are
               dithered photos, asserted by invariants, not a brittle golden);
  4. session-- dialogue advances (a), the in-game menu opens/closes (b), and
               the hold-Start exit combo returns to the library golden;
  5. reboot -- Settings > Power > Restart really reboots the VM and the
               launcher comes back with the same library golden.

Every wait is a poll against a deadline (no fixed sleeps): Ren'Py's cold start
takes tens of seconds to a couple of minutes under llvmpipe on -m 512, and the
frame connection drops and reconnects across the game handoff and the reboot, so
the frame client retries transparently. Timing metrics are printed on stdout as
one stable ``E2E_METRICS`` line for CI to track (step B3).

On failure: exit nonzero, and save the offending frame (PNG, plus a side-by-side
diff for golden mismatches) and the last of the guest serial console under
``tests/.artifacts/``.

Usage::

    ./build.sh qemu && make e2e          # build the image, then run this
    python3 tests/e2e_emulator.py        # run against output-qemu/
    python3 tests/e2e_emulator.py --bless   # regenerate the golden(s)

Timeouts are env-overridable -- see ``Timeouts.from_env`` -- for slower or
faster hosts. Run two copies at once with ``--frame-port/--input-port`` (unique
host ports) or rely on the per-port lockfile to refuse a colliding run.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path

# The reusable frame/input protocol clients live in the launcher checkout; import
# the single implementation rather than re-deriving the wire format here.
_REPO = Path(__file__).resolve().parents[1]  # buildroot_os/
_WORKSPACE = _REPO.parent  # einky/
sys.path.insert(0, str(_WORKSPACE / "launcher" / "tools"))

from frame_stream import Frame, FrameClient, InputClient  # noqa: E402

GOLDENS = _REPO / "tests" / "goldens"
ARTIFACTS = _REPO / "tests" / ".artifacts"
LIBRARY_GOLDEN = "library_first_frame"

# A launcher frame is sparse black-on-white line art; a game frame is a dithered
# photo. This cleanly separates the two on the wire without a game golden.
GAME_BLACK_MIN = 0.25  # game frames run ~45-65% black; launcher screens < ~13%.
# the_question's main-menu background is ~63% black; its story scenes are ~49%.
# Used to tell "we left the menu into the story" from a mere focus highlight.
GAME_STORY_MAX_BLACK = 0.58


class E2EFailure(Exception):
    """A checked acceptance failure. Carries the frame to dump as an artifact."""

    def __init__(self, stage: str, message: str, frame: Frame | None = None) -> None:
        super().__init__(message)
        self.stage = stage
        self.frame = frame


@dataclass(frozen=True)
class Timeouts:
    """All deadlines, in seconds. Generous by default; override via env for CI."""

    boot: float  # qemu start -> first launcher frame
    interact: float  # a launcher button press -> next frame
    game_boot: float  # launch press -> first game frame (llvmpipe cold start)
    game_input: float  # a button -> the game re-renders (JIT/GC lag under -m 512)
    exit: float  # hold:start -> library returns
    reboot: float  # confirm reboot -> launcher's first frame after the reboot
    supervisor: float  # kill launcher -> supervisor relaunches it -> frame returns

    @staticmethod
    def _f(name: str, default: float) -> float:
        return float(os.environ.get(name, default))

    @classmethod
    def from_env(cls) -> Timeouts:
        # E2E_TIMEOUT_MULT scales every deadline at once -- CI runs qemu under TCG
        # (no KVM for aarch64-on-x86), where the guest is several times slower, so
        # CI sets e.g. E2E_TIMEOUT_MULT=3. Per-wait overrides still apply, scaled.
        mult = float(os.environ.get("E2E_TIMEOUT_MULT", "1"))
        return cls(
            boot=cls._f("EINKY_E2E_BOOT_TIMEOUT", 240) * mult,
            interact=cls._f("EINKY_E2E_INTERACT_TIMEOUT", 30) * mult,
            game_boot=cls._f("EINKY_E2E_GAME_BOOT_TIMEOUT", 300) * mult,
            game_input=cls._f("EINKY_E2E_GAME_INPUT_TIMEOUT", 120) * mult,
            exit=cls._f("EINKY_E2E_EXIT_TIMEOUT", 90) * mult,
            reboot=cls._f("EINKY_E2E_REBOOT_TIMEOUT", 240) * mult,
            supervisor=cls._f("EINKY_E2E_SUPERVISOR_TIMEOUT", 90) * mult,
        )


def log(msg: str) -> None:
    print(f"[e2e] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Golden helpers
# ---------------------------------------------------------------------------
def _changed_pixels(a: bytes, b: bytes) -> int:
    """Number of differing pixels between two equal-length packed 1-bit frames."""
    n = min(len(a), len(b))
    diff = int.from_bytes(a[:n], "big") ^ int.from_bytes(b[:n], "big")
    return diff.bit_count() + abs(len(a) - len(b)) * 8


def _side_by_side(golden: bytes | None, actual: Frame, path: Path) -> None:
    """Save ``actual`` as a PNG, plus a labelled golden|actual|diff strip if a
    golden is supplied (so a human can eyeball a mismatch or a --bless change)."""
    from PIL import Image, ImageChops, ImageDraw

    w, h = actual.width, actual.height
    act_img = actual.to_image().convert("L")
    if golden is None or len(golden) != len(actual.data):
        act_img.save(path)
        return
    gold_img = Image.frombytes("1", (w, h), golden).convert("L")
    xor = ImageChops.logical_xor(
        Image.frombytes("1", (w, h), golden), actual.to_image()
    )  # white where they differ
    diff_img = ImageChops.invert(xor.convert("L"))  # differences -> black on white

    gap, top = 12, 22
    strip = Image.new("L", (w * 3 + gap * 2, h + top), 255)
    for i, (label, img) in enumerate(
        (("golden", gold_img), ("actual", act_img), ("diff", diff_img))
    ):
        x = i * (w + gap)
        strip.paste(img, (x, top))
        ImageDraw.Draw(strip).text((x + 4, 4), label, fill=0)
    strip.save(path)


def check_or_bless_golden(frame: Frame, name: str, bless: bool, stage: str) -> None:
    """Compare ``frame`` against the committed golden, or (re)write it under --bless."""
    bin_path = GOLDENS / f"{name}.bin"
    png_path = GOLDENS / f"{name}.png"
    prior = bin_path.read_bytes() if bin_path.exists() else None

    if bless:
        GOLDENS.mkdir(parents=True, exist_ok=True)
        bin_path.write_bytes(frame.data)
        frame.save_png(str(png_path))
        if prior is None:
            log(f"blessed new golden {name} ({len(frame.data)} bytes) -> {bin_path}")
        elif prior == frame.data:
            log(f"golden {name} unchanged")
        else:
            ARTIFACTS.mkdir(parents=True, exist_ok=True)
            diff_png = ARTIFACTS / f"bless_{name}_diff.png"
            _side_by_side(prior, frame, diff_png)
            log(
                f"golden {name} CHANGED: {_changed_pixels(prior, frame.data)} px differ; "
                f"eyeball {diff_png} before committing"
            )
        return

    if prior is None:
        raise E2EFailure(stage, f"no golden {bin_path} (run with --bless to create it)", frame)
    if frame.data == prior:
        log(f"golden {name} matched exactly")
        return
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    diff_png = ARTIFACTS / f"FAIL_{name}_diff.png"
    _side_by_side(prior, frame, diff_png)
    changed = _changed_pixels(prior, frame.data)
    raise E2EFailure(
        stage,
        f"golden {name} mismatch: {changed} px differ; see {diff_png}",
        frame,
    )


# ---------------------------------------------------------------------------
# QEMU harness
# ---------------------------------------------------------------------------
class QemuHarness:
    """Boot the emulator via run-qemu.sh, capturing serial, and always tear down.

    ``run-qemu.sh`` ``exec``s qemu, so the child process *is* qemu; we start it in
    its own session and kill the whole group on exit so nothing leaks. A per-port
    lockfile refuses a second run on the same host ports.
    """

    def __init__(self, frame_port: int, input_port: int, out_dir: str = "output-qemu") -> None:
        self.frame_port = frame_port
        self.input_port = input_port
        self.out_dir = out_dir
        self._proc: subprocess.Popen[bytes] | None = None
        self._serial: deque[str] = deque(maxlen=4000)
        self._reader: threading.Thread | None = None
        self._lock_fp = None
        self.serial_path = ARTIFACTS / "serial.log"

    def __enter__(self) -> QemuHarness:
        self._acquire_lock()
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        env = {
            **os.environ,
            "INKY_OUT": self.out_dir,
            "INKY_FRAME_HOSTPORT": str(self.frame_port),
            "INKY_INPUT_HOSTPORT": str(self.input_port),
        }
        log(f"booting QEMU ({self.out_dir}) frame:{self.frame_port} input:{self.input_port}")
        # stdin is a held-open pipe: run-qemu.sh uses `-serial mon:stdio`, and
        # closing stdin would EOF the muxed monitor and can stop the guest.
        self._proc = subprocess.Popen(
            ["bash", str(_REPO / "run-qemu.sh")],
            cwd=str(_REPO),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self._reader = threading.Thread(target=self._pump_serial, name="serial", daemon=True)
        self._reader.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._kill()
        self._release_lock()

    # --- serial capture ------------------------------------------------------
    def _pump_serial(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        with open(self.serial_path, "wb") as fh:
            for raw in self._proc.stdout:
                fh.write(raw)
                fh.flush()
                self._serial.append(raw.decode("utf-8", "replace").rstrip("\n"))

    def serial_tail(self, n: int = 100) -> list[str]:
        return list(self._serial)[-n:]

    def serial_send(self, text: str) -> None:
        """Type ``text`` on the guest serial console (the muxed mon:stdio input)."""
        proc = self._proc
        if proc is None or proc.stdin is None:
            raise E2EFailure("supervisor", "no serial stdin to write to")
        proc.stdin.write(text.encode())
        proc.stdin.flush()

    def wait_serial(self, pattern: str, timeout: float) -> bool:
        """Poll the captured serial for ``pattern`` (a substring of any line)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(pattern in line for line in list(self._serial)):
                return True
            time.sleep(0.1)
        return False

    def serial_root_run(self, command: str, timeout: float) -> None:
        """Log in as root on the console (no password) and run ``command``.

        Robust to whether a login prompt or a shell is already showing: it retries
        the login and a probe until a *shell* proves itself, then sends the
        command. The probe ``echo INKY''E2ESHELL`` prints ``INKYE2ESHELL`` (the
        shell strips the quotes) -- a marker the echoed *input* line can never
        contain, so it can't be faked by the tty echoing our keystrokes at a
        login prompt.
        """
        marker = "INKYE2ESHELL"
        probe = "echo INKY''E2ESHELL"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.serial_send("\n")
            self.serial_send("root\n")  # username at a login prompt (harmless at a shell)
            self.serial_send("\n")  # empty password if prompted; else a blank command
            self.serial_send(probe + "\n")
            if self.wait_serial(marker, timeout=min(10.0, deadline - time.monotonic())):
                self.serial_send(command + "\n")
                return
        raise E2EFailure("supervisor", "could not get a root shell on the serial console")

    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    # --- teardown ------------------------------------------------------------
    def _kill(self) -> None:
        proc = self._proc
        if proc is None:
            return
        if proc.poll() is None:
            with contextlib.suppress(ProcessLookupError, OSError):
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=8)
        if proc.poll() is None:
            with contextlib.suppress(ProcessLookupError, OSError):
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
        if proc.stdin is not None:
            with contextlib.suppress(OSError):
                proc.stdin.close()
        if self._reader is not None:
            self._reader.join(timeout=3)

    # --- single-run lock -----------------------------------------------------
    def _acquire_lock(self) -> None:
        path = Path(tempfile.gettempdir()) / f"einky-e2e-{self.frame_port}.lock"
        self._lock_fp = open(path, "w")
        try:
            fcntl.flock(self._lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            self._lock_fp.close()
            self._lock_fp = None
            raise E2EFailure(
                "boot",
                f"another e2e run holds {path} (use --frame-port/--input-port for a parallel run)",
            ) from e

    def _release_lock(self) -> None:
        if self._lock_fp is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(self._lock_fp, fcntl.LOCK_UN)
            self._lock_fp.close()
            self._lock_fp = None


def free_port() -> int:
    """Ask the OS for an unused TCP port (for --auto-ports parallel runs)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


# ---------------------------------------------------------------------------
# Session driver
# ---------------------------------------------------------------------------
class Session:
    """Drives the launcher/game over the two clients and records timing metrics."""

    def __init__(
        self,
        fc: FrameClient,
        ic: InputClient,
        tmo: Timeouts,
        bless: bool,
        harness: QemuHarness,
    ) -> None:
        self.fc = fc
        self.ic = ic
        self.tmo = tmo
        self.bless = bless
        self.harness = harness
        self.t0 = time.monotonic()
        self.metrics: dict[str, float] = {}
        self.current: Frame | None = None

    def _since_boot(self) -> float:
        return time.monotonic() - self.t0

    def _press_then_change(self, name: str, ref: Frame, timeout: float, stage: str) -> Frame:
        """Send one button and return the next frame that differs from ``ref``."""
        self.ic.send(name)
        try:
            frame = self.fc.wait_for_change(ref.data, timeout=timeout)
        except TimeoutError as e:
            raise E2EFailure(
                stage, f"no frame change {timeout:.0f}s after pressing {name!r}", ref
            ) from e
        self.current = frame
        return frame

    def _await_library(self, library: Frame, timeout: float, stage: str, what: str) -> Frame:
        """Wait for the library GOLDEN to (re)appear, skipping any lingering frame.

        Matching on the exact golden -- not merely "a launcher-ish frame" -- is
        what makes the recovery deterministic: a stale in-flight frame (the Power
        dialog after a reboot press, a bright game frame just before exit) is not
        the golden, so it is skipped instead of being mistaken for the return.
        """
        try:
            frame = self.fc.wait_for_match(library.data, timeout=timeout)
        except TimeoutError as e:
            raise E2EFailure(stage, f"library golden did not return ({what})", self.current) from e
        self.current = frame
        return frame

    # --- stage 1: boot + golden ---------------------------------------------
    def boot(self, bless: bool) -> Frame:
        log(f"waiting for first launcher frame (boot deadline {self.tmo.boot:.0f}s)")
        frame = self.fc.read_frame(timeout=self.tmo.boot)
        self.current = frame
        self.metrics["boot_to_first_frame_s"] = round(self._since_boot(), 2)
        log(f"first frame at {self.metrics['boot_to_first_frame_s']}s ({frame.black_ratio()*100:.1f}% black)")
        check_or_bless_golden(frame, LIBRARY_GOLDEN, bless, "boot")
        return frame

    # --- stage 2: interactivity round-trip ----------------------------------
    def prove_interactive(self, library: Frame) -> None:
        log("interactivity: Start -> Settings")
        settings = self._press_then_change("start", library, self.tmo.interact, "interact")
        self.metrics["boot_to_interactive_s"] = round(self._since_boot(), 2)
        log(f"interactive at {self.metrics['boot_to_interactive_s']}s")
        log("interactivity: B -> back to library")
        back = self._press_then_change("b", settings, self.tmo.interact, "interact")
        if back.data != library.data:
            raise E2EFailure(
                "interact", "Settings->B did not return to the library golden", back
            )

    # --- stage 3+4: game handoff + in-game session --------------------------
    def play_game(self, library: Frame) -> None:
        log("launch: A -> Starting screen")
        starting = self._press_then_change("a", library, self.tmo.interact, "game")
        log(f"waiting for game frames (deadline {self.tmo.game_boot:.0f}s)")
        try:
            menu = self.fc.wait_for(
                lambda f: f.black_ratio() > GAME_BLACK_MIN and f.data != library.data,
                timeout=self.tmo.game_boot,
            )
        except TimeoutError as e:
            raise E2EFailure("game", "no game frame after launch (Ren'Py boot)", starting) from e
        self.current = menu
        self.metrics["game_first_frame_s"] = round(self._since_boot(), 2)
        log(f"game frames flowing at {self.metrics['game_first_frame_s']}s ({menu.black_ratio()*100:.1f}% black)")
        if menu.data in (library.data, starting.data):
            raise E2EFailure("game", "game frame equals a launcher frame", menu)

        story = self._enter_story(menu)
        self._drive_dialogue_and_menu(story)

        log("exit: hold:start -> library")
        self.ic.send("hold:start")
        self._await_library(library, self.tmo.exit, "game", "exit back to the library")
        log("returned to library after exit")

    def _enter_story(self, menu: Frame) -> Frame:
        """From the game's main menu, focus and activate "Start" to begin the story.

        ``down`` (focus Start) and ``start`` (button_select) are sent back-to-back
        so the engine processes both in one interaction and jumps straight to the
        story, skipping any intermediate focus-highlight frame. We wait for a frame
        that has left the dark main-menu background (its story scenes are lighter).
        """
        log("game: down+start -> begin the story")
        self.ic.send("down")
        self.ic.send("start")
        try:
            story = self.fc.wait_for(
                lambda f: f.data != menu.data and f.black_ratio() < GAME_STORY_MAX_BLACK,
                timeout=self.tmo.game_input,
            )
        except TimeoutError as e:
            raise E2EFailure("game", "could not start the story from the main menu", menu) from e
        self.current = story
        log(f"story started ({story.black_ratio()*100:.1f}% black)")
        return story

    def _drive_dialogue_and_menu(self, story: Frame) -> None:
        """Prove input reaches the running game: advance dialogue, toggle the menu."""
        log("game: a -> advance dialogue")
        advanced = self._press_then_change("a", story, self.tmo.game_input, "game")
        log("game: b -> open in-game menu")
        menu_open = self._press_then_change("b", advanced, self.tmo.game_input, "game")
        log("game: b -> close in-game menu")
        self._press_then_change("b", menu_open, self.tmo.game_input, "game")

    # --- stage 5: reboot -----------------------------------------------------
    def reboot(self, library: Frame) -> None:
        log("reboot: Settings > Power > Restart > Confirm")
        cur = library
        # library -> Settings; focus Power (Display, Wi-Fi, Power); open it
        cur = self._press_then_change("start", cur, self.tmo.interact, "reboot")
        cur = self._press_then_change("down", cur, self.tmo.interact, "reboot")  # Wi-Fi
        cur = self._press_then_change("down", cur, self.tmo.interact, "reboot")  # Power
        cur = self._press_then_change("a", cur, self.tmo.interact, "reboot")  # Power screen
        cur = self._press_then_change("down", cur, self.tmo.interact, "reboot")  # Restart
        cur = self._press_then_change("a", cur, self.tmo.interact, "reboot")  # Restart? dialog
        cur = self._press_then_change("right", cur, self.tmo.interact, "reboot")  # focus Confirm
        # Confirm reboots the VM: the backend closes (our connection drops) and
        # the guest resets. Do not wait for a frame here -- just fire it.
        self.ic.send("a")
        log(f"confirmed reboot; waiting for launcher to return (deadline {self.tmo.reboot:.0f}s)")
        t_reboot = time.monotonic()
        self._await_library(library, self.tmo.reboot, "reboot", "after reboot")
        self.metrics["reboot_to_first_frame_s"] = round(time.monotonic() - t_reboot, 2)
        log(f"launcher back {self.metrics['reboot_to_first_frame_s']}s after reboot")

    # --- stage 6: supervisor restart (kill the launcher over serial) ---------
    def supervisor_restart(self, library: Frame) -> None:
        log("supervisor: kill -9 the launcher over serial; expect it to come back")
        # Kill the launcher (not the inky-session supervisor); the supervisor's
        # relaunch loop must bring the UI back on its own. BusyBox on the image has
        # no pkill/pgrep, so match the launcher by its /proc cmdline (its comm is
        # "python3"); the '[i]nky-launcher' pattern keeps the grep from self-matching.
        kill_cmd = (
            "for c in /proc/[0-9]*/cmdline; do "
            "grep -q '[i]nky-launcher' \"$c\" 2>/dev/null && "
            'kill -9 "$(echo $c | cut -d/ -f3)"; '
            "done"
        )
        self.harness.serial_root_run(kill_cmd, timeout=self.tmo.supervisor)
        t_kill = time.monotonic()
        self._await_library(library, self.tmo.supervisor, "supervisor", "after kill")
        self.metrics["supervisor_restart_s"] = round(time.monotonic() - t_kill, 2)
        log(f"supervisor relaunched the UI {self.metrics['supervisor_restart_s']}s after kill")

    def run(self) -> None:
        library = self.boot(self.bless)
        self.prove_interactive(library)
        self.play_game(library)
        self.reboot(library)
        self.supervisor_restart(library)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def _emit_metrics(result: str, metrics: dict[str, float], stage: str | None = None) -> None:
    parts = [f"result={result}"]
    if stage:
        parts.append(f"stage={stage}")
    parts += [f"{k}={v}" for k, v in metrics.items()]
    print("E2E_METRICS " + " ".join(parts), flush=True)


def _save_failure_frame(frame: Frame | None) -> None:
    if frame is None:
        return
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    path = ARTIFACTS / "FAIL_frame.png"
    frame.save_png(str(path))
    log(f"saved offending frame -> {path}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="InkyOS emulator end-to-end acceptance test")
    ap.add_argument("--bless", action="store_true", help="(re)write goldens from this run")
    ap.add_argument("--frame-port", type=int, default=int(os.environ.get("EINKY_E2E_FRAME_PORT", 5333)))
    ap.add_argument("--input-port", type=int, default=int(os.environ.get("EINKY_E2E_INPUT_PORT", 5334)))
    ap.add_argument("--auto-ports", action="store_true", help="pick free host ports (parallel runs)")
    ap.add_argument("--out-dir", default=os.environ.get("INKY_OUT", "output-qemu"))
    args = ap.parse_args(argv)

    frame_port = free_port() if args.auto_ports else args.frame_port
    input_port = free_port() if args.auto_ports else args.input_port
    tmo = Timeouts.from_env()
    metrics: dict[str, float] = {}
    stage = "boot"

    try:
        with QemuHarness(frame_port, input_port, args.out_dir) as qemu:
            fc = FrameClient("127.0.0.1", frame_port)
            ic = InputClient("127.0.0.1", input_port)
            session = Session(fc, ic, tmo, args.bless, qemu)
            try:
                session.run()
            finally:
                metrics = session.metrics
                fc.close()
                ic.close()
            if not qemu.alive():
                raise E2EFailure(stage, "QEMU exited before the test completed")
    except E2EFailure as f:
        stage = f.stage
        log(f"FAILURE [{f.stage}]: {f}")
        _save_failure_frame(f.frame)
        log("--- last guest serial ---")
        for line in _last_serial():
            print("    " + line, flush=True)
        _emit_metrics("FAIL", metrics, stage=f.stage)
        return 1
    except Exception as e:  # noqa: BLE001 - report anything, never leak qemu
        log(f"ERROR: {e!r}")
        log("--- last guest serial ---")
        for line in _last_serial():
            print("    " + line, flush=True)
        _emit_metrics("ERROR", metrics, stage=stage)
        return 2

    _emit_metrics("PASS", metrics)
    log("PASS: boot + input + game + session + reboot + supervisor-restart all verified")
    return 0


def _last_serial(n: int = 100) -> list[str]:
    """Best-effort tail of the serial log file (written by the harness thread)."""
    path = ARTIFACTS / "serial.log"
    if not path.exists():
        return []
    with contextlib.suppress(OSError):
        with open(path, "rb") as fh:
            try:
                fh.seek(-16000, os.SEEK_END)
            except OSError:
                fh.seek(0)
            tail = fh.read().decode("utf-8", "replace").splitlines()
        return tail[-n:]
    return []


if __name__ == "__main__":
    raise SystemExit(main())
