# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **InkyOS**: a Buildroot **`br2-external`** tree that builds a custom embedded Linux
image which boots a **Raspberry Pi Zero 2 W** straight into a single Ren'Py visual-novel
game. It is the OS component of the Einky e-ink handheld console. The image is a fixed
appliance — no package manager, no shell/desktop in the boot path, reproducible source build.

All project customization lives in this tree; **Buildroot itself is a pinned git submodule
(`buildroot/`, currently `2026.05`) and is never edited in place.**

> Note: `README.md` describes the *target* architecture in full. The graphics/Ren'Py/runtime
> stack is built and exercised on the **emulator** target today; the Pi hardware target is
> still WIP — see [Current state](#current-state-vs-readme) for what exists versus what is planned.

## Builds run in Docker via `./br.sh`

Never invoke `make` against Buildroot directly. `./br.sh` builds the Debian Bookworm builder
image (once), then runs Buildroot inside it as your host UID, with caches mounted from the
repo so they persist across `--rm` runs. The repo is mounted at `/work` in the container.
`./build.sh {qemu|pi}` is the usual entry point: it loads the right defconfig and builds into a
per-target output dir (`output-qemu/` vs `output/`) via `INKY_OUT`.

```sh
./build.sh qemu                      # load inky_qemu_defconfig + full build -> output-qemu/
./build.sh pi                        # load inky_defconfig + full build       -> output/
./br.sh make inky_qemu_defconfig     # load a defconfig by hand (from configs/)
./br.sh make -j"$(nproc)"            # full build
./br.sh make menuconfig              # configure interactively
./br.sh make linux-rebuild          # rebuild a single package (pkg-rebuild)
./br.sh make renpy-rebuild          # rebuild the Ren'Py engine package
./br.sh make inky-runtime-rebuild   # rebuild the consumed `runtime` package
./br.sh make savedefconfig BR2_DEFCONFIG=/work/configs/inky_qemu_defconfig  # persist .config back
./br.sh bash                         # interactive shell inside the build container
```

`br.sh` sets `HOME=/work/.home`, `BR2_DL_DIR=/work/.dl`, `BR2_CCACHE_DIR=/work/.ccache`, and
passes `BR2_EXTERNAL=/work O=/work/$INKY_OUT`. Output lands in `./$INKY_OUT/` on the host
(images in `./$INKY_OUT/images/`). The `.dl/`, `.ccache/`, `.home/`, `output*/` dirs are
gitignored. Rebuild the builder image manually with `docker build -t inky-buildroot:bookworm docker`.

Two extra things `br.sh` does on each `make`:

- **Pin/contract parity (ADR 0008).** Before building it runs `scripts/check_pins.py` (version
  pins vs `../meta/versions.env`) and `scripts/gen_hardware.py --check` (generated `board/inky/
  config.txt` + the `input_hook.rpy` button map vs `../meta/shared/hardware.toml`). Both skip
  gracefully if the sibling `meta` repo is absent; bypass with `INKY_SKIP_CHECKS=1`. Regenerate
  the hardware files with `python3 scripts/gen_hardware.py`.
- **Consume the sibling `runtime` checkout.** If `../runtime` exists it is mounted read-only at
  `/runtime` and the `inky-runtime` package is built from it via Buildroot `OVERRIDE_SRCDIR`
  (no network/credentials needed for the private repo). Otherwise inky-runtime falls back to its
  pinned git source.

> **QEMU runs on the host, not in the container.** Build inside Docker, then boot the
> resulting image with `./run-qemu.sh` (`qemu-system-aarch64 -M virt`) on the host.

## br2-external mechanics

How Buildroot discovers this tree (these wire the `INKY` external into Buildroot's menus):

- `external.desc` — declares the tree: `name: INKY`. This name becomes the
  `BR2_EXTERNAL_INKY_PATH` make variable used everywhere else.
- `external.mk` — `include $(sort $(wildcard $(BR2_EXTERNAL_INKY_PATH)/package/*/*.mk))`,
  so every `package/*/*.mk` is picked up automatically.
- `Config.in` — sources each package's menu. Currently wires `package/{pygame-sdl2,renpy,
  inky-runtime,inky-session}/Config.in`.
- `configs/*_defconfig` — the seeded configurations. Loaded by name with `./br.sh make <name>`.

To add a custom package: create `package/<name>/{Config.in,<name>.mk}`, source its `Config.in`
from the top-level `Config.in`, and enable it in a defconfig. The `.mk` is auto-included.

## Build targets

Two configs produce **different, non-interchangeable images**:

- `inky_qemu_defconfig` — **emulator** target (`qemu-system-aarch64 -M virt`, `./build.sh qemu`
  → `output-qemu/`). This is the working day-to-day target: full graphics + Ren'Py + runtime
  stack, boots to the game, frame pipeline previews over TCP.
- `inky_defconfig` — **hardware** target (Pi Zero 2 W, `./build.sh pi` → `output/`). Today this
  still builds a near-stock Pi Zero 2 W image; the python3/Ren'Py/Xvfb/runtime stack is not
  enabled here yet (the inky-runtime lines are present but inert until it is). GPIO/SPI/e-ink can
  only be validated on the board.

Workflow intent: *develop against the emulator, validate against hardware.* The Pi's `raspi`
QEMU machine is unreliable, which is why the separate `virt` target exists.

## Architecture of the appliance

The hard problem this OS solves is running Ren'Py (a desktop-OpenGL engine) on a GPU-less,
screen-less e-ink device. The key decisions:

- **Software OpenGL via Mesa `llvmpipe`, not the Pi's VideoCore.** Ren'Py needs desktop
  GL/GLX; VideoCore exposes only GL **ES**, the source of the `Couldn't find matching GLX
  visual` failure. `llvmpipe` gives a real desktop-GL context and behaves identically in QEMU
  and on hardware. e-ink refresh is the real bottleneck, so software rendering costs nothing.
- **Display = frame capture, not a screen.** Ren'Py renders into a virtual framebuffer
  (Xvfb). The in-engine `eink_hook.rpy` (via a patched `config.eink_push_callback`, see
  `package/renpy/0001-add-eink-push-callback.patch`) ships one PNG per stable frame over a Unix
  socket; the runtime's `inky-eink-receiver` decodes it, applies Floyd–Steinberg dithering to
  1-bit, and dispatches it (SPI panel on hardware; TCP/socket preview on the emulator).
- **Input = button names, two transports.** `input_hook.rpy` serves a Unix socket and queues
  the `renpy_events` for each button NAME. On the emulator the runtime's `net_sender` feeds
  names into that socket; on hardware the runtime's GPIO handler (gpiozero via `libgpiod`)
  injects the mapped keysyms with `xdotool`. No engine input modifications.

**Shared logic is consumed, not reimplemented (ADR 0008).** The capture → dither → pack →
dispatch pipeline, the SPI driver, and the keymap all live in the sibling **`runtime`** repo;
InkyOS builds it as the `package/inky-runtime` Buildroot package and runs its console scripts
(`inky-eink-receiver`, `inky-input`, `inky-frame`). The panel geometry, GPIO/SPI pins, button
bindings, and wire-protocol constants come from `../meta/shared/hardware.toml`; version pins
from `../meta/versions.env`. Do **not** hand-edit `board/inky/config.txt` or the `input_hook.rpy`
button map — regenerate them with `scripts/gen_hardware.py`. **The build never reads the
contract:** it bakes in the committed generated files, so a contract edit reaches the image only
after you regenerate. And regenerating buildroot_os is **not sufficient** — the pins the panel
driver and input daemon actually use live in `runtime` (`src/spi_driver/contract.h`,
`src/input/keymap.py`); `config.txt` only enables the SPI bus and sets boot-time button pull-ups.
Changing a pin means: edit the contract → `scripts/gen_hardware.py` **and** `runtime`'s `make gen`
→ rebuild. `br.sh`'s `gen_hardware.py --check` guards buildroot_os's files only, not runtime's.

Ren'Py and `pygame_sdl2` are built from source as Buildroot packages under `package/renpy/` and
`package/pygame-sdl2/` (Ren'Py 8.5.2 vendors its own pygame, so `pygame-sdl2` provides only the
C headers `renpy` builds against — see those packages' `.mk` headers).

## Current state vs README

What actually exists in the tree:

- **Packages** (`package/`): `renpy` (engine from source, with the e-ink callback patch),
  `pygame-sdl2` (SDL2 binding / headers), `inky-runtime` (consumes the `runtime` repo — frame
  pipeline + input bridge + optional SPI driver via the `BR2_PACKAGE_INKY_RUNTIME_SPI`
  sub-option), and `inky-session` (the boot-to-game supervisor service).
- **Shared board files** (`board/common/`): `post-build.sh` (used by *every* target) disables
  stock Xorg and assembles `/opt/the_question` at build time — stock the_question from the renpy
  package, then the InkyOS game deltas in `board/common/the_question-eink/game/` (the two hooks
  `eink_hook.rpy` / `input_hook.rpy` + the e-ink `gui`/`options` overrides) layered on top. The
  game is **not** vendored in git; both boards assemble an identical game. `input_hook.rpy`'s
  button map is generated from the contract by `scripts/gen_hardware.py`.
- **Emulator board** (`board/qemu/`): rootfs overlay carrying `/etc/default/inky-session`
  (tcp/socket preview + `net_sender` input) + qemu kernel config / post-image.
- **Hardware board** (`board/inky/`): `config.txt` (generated from the contract: SPI on, button
  pull-ups) + `overlay/etc/default/inky-session` (spi + gpio). Wired into `inky_defconfig`.
- **Defconfigs**: `inky_qemu_defconfig` (emulator stack) and `inky_defconfig` (Pi Zero 2 W:
  external Bootlin AArch64 glibc toolchain, custom rpi kernel tarball, `bcm2711` defconfig, DTS
  `broadcom/bcm2710-rpi-zero-2-w`). The Pi defconfig now carries the same boot-to-game stack as
  the emulator (Mesa llvmpipe + Xorg/Xvfb + python3 + renpy + inky-session + the SPI/GPIO runtime),
  points `BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE` + overlay + post-build at `board/inky/` /
  `board/common/`, and sizes the rootfs to 1.2G. It still uses Buildroot's in-tree
  `board/raspberrypizero2w-64/` **post-image** (SD-image build) + its post-build (serial getty),
  chained ahead of `board/common/post-build.sh`.

The Pi hardware target is now feature-complete on paper (parity with the emulator + the SPI/GPIO
backend); what remains is **hardware validation** on a wired board — a full Pi build has not yet
been booted on real hardware, and the C SPI driver's bring-up flip-points (frame inversion,
gpiochip index, BUSY polarity) are untested.

## Phased plan

Work is gated in checkpoints (see README → Project status): (1) minimal boot, (2) graphics
stack — the critical checkpoint is `glxinfo` reporting the `llvmpipe` renderer, (3) Ren'Py
from source rendering headless, (4) boot-to-game + input bridge (done on the emulator via
inky-session + inky-runtime), (5) read-only root with a writable data partition for save
survival.
