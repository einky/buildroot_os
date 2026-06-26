# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **InkyOS**: a Buildroot **`br2-external`** tree that builds a custom embedded Linux
image which boots a **Raspberry Pi Zero 2 W** straight into a single Ren'Py visual-novel
game. It is the OS component of the Einky e-ink handheld console. The image is a fixed
appliance — no package manager, no shell/desktop in the boot path, reproducible source build.

All project customization lives in this tree; **Buildroot itself is a pinned git submodule
(`buildroot/`, currently `2026.05`) and is never edited in place.**

> Note: `README.md` describes the *target* architecture in full. The repo is early-stage —
> see [Current state](#current-state-vs-readme) for what actually exists versus what is planned.

## Builds run in Docker via `./br.sh`

Never invoke `make` against Buildroot directly. `./br.sh` builds the Debian Bookworm builder
image (once), then runs Buildroot inside it as your host UID, with caches mounted from the
repo so they persist across `--rm` runs. The repo is mounted at `/work` in the container.

```sh
./br.sh make inky_defconfig          # load a defconfig (from configs/)
./br.sh make -j"$(nproc)"            # full build
./br.sh make menuconfig              # configure interactively
./br.sh make linux-rebuild          # rebuild a single package (pkg-rebuild)
./br.sh make renpy-rebuild          # (once the renpy package exists)
./br.sh make savedefconfig BR2_DEFCONFIG=/work/configs/inky_defconfig  # persist .config back to a defconfig
./br.sh bash                         # interactive shell inside the build container
```

`br.sh` sets `HOME=/work/.home`, `BR2_DL_DIR=/work/.dl`, `BR2_CCACHE_DIR=/work/.ccache`, and
passes `BR2_EXTERNAL=/work O=/work/output`. Build output lands in `./output/` on the host
(images in `./output/images/`). The `.dl/`, `.ccache/`, `.home/`, `output/` dirs are
gitignored. Rebuild the builder image manually with `docker build -t inky-buildroot:bookworm docker`.

> **QEMU runs on the host, not in the container.** Build inside Docker, then boot the
> resulting image with `qemu-system-aarch64` directly on the host (see README → Testing).

## br2-external mechanics

How Buildroot discovers this tree (these wire the `INKY` external into Buildroot's menus):

- `external.desc` — declares the tree: `name: INKY`. This name becomes the
  `BR2_EXTERNAL_INKY_PATH` make variable used everywhere else.
- `external.mk` — `include $(sort $(wildcard $(BR2_EXTERNAL_INKY_PATH)/package/*/*.mk))`,
  so every `package/*/*.mk` is picked up automatically.
- `Config.in` — sources package menus (currently empty; package `Config.in` files get added here).
- `configs/*_defconfig` — the seeded configurations. Loaded by name with `./br.sh make <name>`.

To add a custom package: create `package/<name>/{Config.in,<name>.mk}`, source its `Config.in`
from the top-level `Config.in`, and enable it in a defconfig. The `.mk` is auto-included.

## Build targets (design)

Two configs are planned, producing **different, non-interchangeable images**:

- `inky_defconfig` — **hardware** target (Pi Zero 2 W). The actual shipping SD image.
  Boots reliably only on the board; GPIO/SPI/e-ink can only be validated here.
- `inky_qemu_defconfig` — **emulator** target (`qemu-system-aarch64 -M virt`), for fast,
  reliable day-to-day development of the OS and software stack. **Not yet created.**

Workflow intent: *develop against the emulator, validate against hardware.* The Pi's `raspi`
QEMU machine is unreliable, which is why the separate `virt` target exists.

## Architecture of the appliance (target design)

The hard problem this OS solves is running Ren'Py (a desktop-OpenGL engine) on a GPU-less,
screen-less e-ink device. The key decisions:

- **Software OpenGL via Mesa `llvmpipe`, not the Pi's VideoCore.** Ren'Py needs desktop
  GL/GLX; VideoCore exposes only GL **ES**, the source of the `Couldn't find matching GLX
  visual` failure. `llvmpipe` gives a real desktop-GL context and behaves identically in QEMU
  and on hardware. e-ink refresh is the real bottleneck, so software rendering costs nothing.
- **Display = frame capture, not a screen.** Ren'Py renders into a virtual framebuffer
  (Xvfb); a capture step reads pixels, applies Floyd–Steinberg dithering to 1-bit, and pushes
  frames to the e-ink panel over SPI via a small C driver.
- **Input = GPIO → uinput → SDL2.** A daemon reads hardware buttons via `libgpiod`
  (`/dev/gpiochip0` char-device API) and injects them through kernel `uinput` as a virtual
  keyboard, so SDL2/Ren'Py see ordinary key events with no engine modifications.

Ren'Py and `pygame_sdl2` are built from source as Buildroot packages (planned under
`package/renpy/` and `package/pygame-sdl2/`).

## Current state vs README

The defconfig and board layout do **not** yet match the README's described `board/inky/` tree:

- `configs/inky_defconfig` currently builds a stock Pi Zero 2 W image and references
  Buildroot's **in-tree** board files (`board/raspberrypizero2w-64/post-build.sh`,
  `post-image.sh`, `config_zero2w_64bit.txt`, `board/raspberrypi/patches`) — *not* this
  external tree's `board/inky/`.
- `board/inky/` contains only `.gitkeep`; `package/` is empty; `Config.in` is a placeholder.
- Toolchain: external Bootlin AArch64 glibc. Kernel: custom rpi tarball, `bcm2711` defconfig,
  DTS `broadcom/bcm2710-rpi-zero-2-w`. Rootfs: ext4, 120M.

When adding the graphics/Ren'Py/input stack, expect to introduce `board/inky/` overlays,
custom packages under `package/`, and the `inky_qemu_defconfig`.

## Phased plan

Work is gated in checkpoints (see README → Project status): (1) minimal boot, (2) graphics
stack — the critical checkpoint is `glxinfo` reporting the `llvmpipe` renderer, (3) Ren'Py
from source rendering headless, (4) boot-to-game + GPIO→uinput input, (5) read-only root with
a writable data partition for save survival.
