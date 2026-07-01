#!/usr/bin/env python3
"""Fail if InkyOS version pins diverge from meta/versions.env (ADR 0008).

``meta/versions.env`` is the single source of truth for the shared engine /
toolchain pins. buildroot_os mirrors them in its Buildroot packages and in the
pinned buildroot submodule; this check keeps the copies honest so a bump in
``meta`` can't silently desync. It verifies:

    RENPY_VERSION        <- package/renpy/renpy.mk
    PYGAME_SDL2_VERSION  <- package/pygame-sdl2/pygame-sdl2.mk
    BUILDROOT_VERSION    <- buildroot/Makefile (BR2_VERSION)
    TARGET_PYTHON_VERSION<- buildroot/package/python3/python3.mk
    HOST_CYTHON_VERSION  <- buildroot/package/python-cython/python-cython.mk

versions.env is located via --versions-env, $EINKY_VERSIONS_ENV,
$EINKY_META_DIR/versions.env, then ../meta/versions.env (sibling checkout). If it
is absent the check warns and exits 0 -- it can only enforce where meta is present.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BR = REPO_ROOT / "buildroot"


def find_versions_env(explicit: Path | None) -> Path | None:
    candidates = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("EINKY_VERSIONS_ENV"):
        candidates.append(Path(os.environ["EINKY_VERSIONS_ENV"]))
    if os.environ.get("EINKY_META_DIR"):
        candidates.append(Path(os.environ["EINKY_META_DIR"]) / "versions.env")
    candidates.append(REPO_ROOT.parent / "meta/versions.env")
    return next((c for c in candidates if c.exists()), None)


def parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        m = re.match(r"\s*([A-Z0-9_]+)=(.*)$", line)
        if m and not line.lstrip().startswith("#"):
            out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def grep1(path: Path, pattern: str) -> str | None:
    if not path.exists():
        return None
    m = re.search(pattern, path.read_text(), re.MULTILINE)
    return m.group(1).strip() if m else None


def buildroot_python_version() -> str | None:
    mk = BR / "package/python3/python3.mk"
    major = grep1(mk, r"^PYTHON3_VERSION_MAJOR\s*=\s*(.+)$")
    ver = grep1(mk, r"^PYTHON3_VERSION\s*=\s*(.+)$")
    if major is None or ver is None:
        return None
    return ver.replace("$(PYTHON3_VERSION_MAJOR)", major)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--versions-env", type=Path, default=None)
    args = ap.parse_args(argv)

    env_path = find_versions_env(args.versions_env)
    if env_path is None:
        print(
            "check_pins: versions.env not found (set $EINKY_META_DIR or check out "
            "../meta); skipping pin parity.",
            file=sys.stderr,
        )
        return 0

    env = parse_env(env_path)

    checks = {
        "RENPY_VERSION": grep1(
            REPO_ROOT / "package/renpy/renpy.mk", r"^RENPY_VERSION\s*=\s*(.+)$"
        ),
        "PYGAME_SDL2_VERSION": grep1(
            REPO_ROOT / "package/pygame-sdl2/pygame-sdl2.mk",
            r"^PYGAME_SDL2_VERSION\s*=\s*(.+)$",
        ),
        "BUILDROOT_VERSION": grep1(BR / "Makefile", r"^export BR2_VERSION\s*:?=\s*([^\s]+)"),
        "TARGET_PYTHON_VERSION": buildroot_python_version(),
        "HOST_CYTHON_VERSION": grep1(
            BR / "package/python-cython/python-cython.mk",
            r"^PYTHON_CYTHON_VERSION\s*=\s*(.+)$",
        ),
    }

    failures = []
    for key, actual in checks.items():
        want = env.get(key)
        # BR2_VERSION can carry a "-git"/date suffix; compare on the pin prefix.
        ok = actual is not None and want is not None and (
            actual == want or actual.split("-")[0] == want
        )
        status = "OK " if ok else "FAIL"
        print(f"{status} {key}: meta={want!r} buildroot_os={actual!r}")
        if not ok:
            failures.append(key)

    if failures:
        print(
            f"\n{len(failures)} pin(s) diverge from {env_path}. "
            "Update the buildroot_os copy (or bump meta) so they match.",
            file=sys.stderr,
        )
        return 1
    print(f"\nversion pin parity OK ({env_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
