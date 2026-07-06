# InkyOS

A custom embedded Linux image, built with **Buildroot**, that boots a **Raspberry Pi
Zero 2 W** directly into a single Ren'Py visual-novel game. InkyOS is the operating-system
component of the Einky e-ink handheld console (Crab-Ink-Gaming).

The image is a **fixed appliance**: no runtime package manager, a reproducible build, and a
boot path that goes straight to the game with no shell or desktop in between.

---

## Design goals & key decisions

Every choice here is deliberate; the rationale matters as much as the choice.

**Buildroot, not pi-gen or a desktop distro.** InkyOS is a purpose-built appliance, so a
minimal, reproducible, source-built image is the right shape — not a general-purpose Debian
that we strip back. Buildroot also makes the QEMU development loop first-class: the same
artifact we flash is the one we can boot in emulation.

**Software OpenGL via Mesa llvmpipe — not the VideoCore GPU.** Ren'Py needs a desktop
OpenGL / GLX context. The Pi's VideoCore exposes only OpenGL **ES**, which is the root of
the well-known `Couldn't find matching GLX visual` failure when running Ren'Py on a Pi.
Routing GL through Mesa's `llvmpipe` software rasterizer provides a real desktop-GL context,
sidesteps that failure entirely, and behaves **identically in QEMU and on hardware** because
it never depends on a GPU. The e-ink refresh is the real performance bottleneck, so software
rendering costs us nothing in practice.

**Display = frame capture, not a screen.** Ren'Py renders into a virtual framebuffer
(Xvfb); a capture step reads pixels, applies Floyd–Steinberg dithering to 1-bit, and pushes
frames to the e-ink panel over SPI via a small C driver.

**Input = GPIO → uinput → SDL2.** A daemon reads the hardware buttons via `libgpiod`
(`/dev/gpiochip0`, the modern character-device API) and injects them through the kernel
`uinput` device as a virtual keyboard. SDL2 — and therefore Ren'Py — sees ordinary key
events with no engine modifications.

**Two build targets.** See [Build targets](#build-targets). One image for real hardware,
one for fast, reliable emulation.

---

## Repository structure

This is a Buildroot **`br2-external`** tree: all customization lives here, and Buildroot
itself is a pinned git submodule that is never edited in place.

```
buildroot_os/
├── br.sh                     # containerized Buildroot wrapper (build inside Docker)
├── build.sh                  # dispatcher: ./build.sh {qemu|pi} -> output-qemu/ | output/
├── run-qemu.sh               # boot the emulator image on the host (headless serial)
├── docker/
│   └── Dockerfile            # pinned Debian Bookworm build environment
├── buildroot/                # Buildroot, as a git submodule (pinned to an LTS tag)
├── external.desc             # declares this external tree (name: INKY)
├── external.mk               # includes package/*/*.mk
├── Config.in                 # sources package/*/Config.in
├── configs/
│   ├── inky_defconfig         # HARDWARE target (Pi Zero 2 W)
│   └── inky_qemu_defconfig    # EMULATOR target (QEMU virt)   [see Build targets]
├── board/inky/
│   ├── config.txt            # Pi firmware config (SPI, 64-bit) — added in build phases
│   ├── linux.fragment        # extra kernel options (uinput, evdev, spi)
│   ├── genimage.cfg          # SD image partition layout
│   └── rootfs-overlay/       # files copied verbatim into the rootfs
├── package/
│   ├── pygame-sdl2/          # Buildroot recipe for pygame_sdl2 (Ren'Py dependency)
│   └── renpy/                # Buildroot recipe for the Ren'Py engine
├── .dl/                      # download cache (gitignored, persists across builds)
├── .ccache/                  # compiler cache (gitignored)
├── output/                   # HARDWARE build output (gitignored)
└── output-qemu/              # EMULATOR build output (gitignored)
```

---

## Prerequisites

- **Docker** (the build runs in a container, so the host distro doesn't matter).
- **QEMU** for emulation, on the host — `qemu-system-aarch64` (plus `qemu-img`, or just use
  `truncate`).
- **git**, and a working internet connection for the first build.

No cross-toolchain, Python, or build libraries are needed on the host — the container
provides everything. This is the point of the containerized setup: a reproducible,
host-agnostic build.

---

## Quick start

```bash
# 1. Clone with the Buildroot submodule
git clone <repo-url> buildroot_os
cd buildroot_os
git submodule update --init --recursive

# 2. (first run only) build the build-environment image, then build the emulator target
./build.sh qemu          # -> output-qemu/  (wraps ./br.sh, see below)

# 3. Boot it (see Testing)
./run-qemu.sh
```

`build.sh` and `run-qemu.sh` are thin convenience wrappers; everything still goes through
`./br.sh`, which runs Buildroot inside the container as your own user with persistent
download/compiler caches. The output directory is selected by `INKY_OUT` (default `output`),
so the two targets never clobber each other.

```bash
./build.sh qemu                          # EMULATOR target -> output-qemu/
./build.sh pi                            # HARDWARE target -> output/
./build.sh qemu menuconfig               # extra args pass through to ./br.sh make
./build.sh pi linux-rebuild              # rebuild one package for the Pi target

# ...or drive ./br.sh directly (INKY_OUT picks the output dir):
INKY_OUT=output-qemu ./br.sh make inky_qemu_defconfig
INKY_OUT=output-qemu ./br.sh make -j"$(nproc)"
./br.sh make savedefconfig BR2_DEFCONFIG=/work/configs/inky_qemu_defconfig
./br.sh bash                             # shell inside the build container
```

> **QEMU runs on the host, not in the container.** The build artifacts land in the output
> directory on your machine via the mounted volume; you invoke QEMU directly on the host.

---

## Build targets

InkyOS builds in two configurations, for two different purposes. **They produce different
images and are not interchangeable.**

| | `inky_defconfig` (hardware) | `inky_qemu_defconfig` (emulator) |
|---|---|---|
| Base | `raspberrypizero2w_64_defconfig` | `qemu_aarch64_virt_defconfig` |
| Machine | real Pi Zero 2 W | `qemu-system-aarch64 -M virt` |
| Output dir | `output/` | `output-qemu/` |
| Build | `./build.sh pi` | `./build.sh qemu` |
| Boot/flash | `dd` the SD image (see Testing) | `./run-qemu.sh` |
| Boots on the Pi | **yes** — this is the SD image | no |
| Boots in QEMU | unreliable (raspi machine fidelity) | **yes** — clean every time |
| Use for | final validation, hardware I/O (GPIO, SPI, e-ink) | day-to-day development of the OS + software stack |

The **emulator target** validates everything in software — init, the graphics stack, Ren'Py,
the session flow — fast and reliably, because QEMU's `virt` machine has clean, well-supported
virtio devices and a generated device tree. It does **not** validate the Pi's kernel, boot
chain, or peripherals.

The **hardware target** is the actual shipping image. GPIO, SPI, and the e-ink panel can only
be validated here, on the board.

Develop against the emulator; validate against hardware.

### Pinned versions

The Ren'Py engine is built from source as Buildroot packages, so its toolchain dependencies
must line up with Buildroot's bundled Python and Cython. These are pinned in lockstep — bumping
one means re-checking the others.

| Component | Version | Where it's pinned |
|---|---|---|
| Buildroot | `2026.05` (submodule) | `buildroot/` git submodule |
| Target Python 3 | `3.14.5` | Buildroot `package/python3` (`make python3-show-info`) |
| Host Cython | `3.1.3` | Buildroot `package/python-cython` (pulled via `host-python-cython`) |
| Ren'Py | `8.5.2` | `package/renpy/renpy.mk` (renpy.org source tarball) |
| pygame_sdl2 | `renpy-8.5.2.26010301` | `package/pygame-sdl2/pygame-sdl2.mk` |

Notes:

- **Ren'Py 8.5.2 vendors its own pygame as `renpy.pygame`** (the engine does `import
  renpy.pygame as pygame`; the standalone `pygame_sdl2` name survives only as a back-compat
  alias pointing at it). So the `renpy` package does **not** depend on the external
  `pygame-sdl2` package, and `inky_qemu_defconfig` no longer enables it. `package/pygame-sdl2/`
  is kept (and still builds/imports) but is currently unused by the engine.
- The `renpy` build is driven by the engine's own `setup.py` (pkg-config based; `RENPY_CYTHON`
  names the cross host Cython). Its native modules are built in-place and installed to
  `/opt/renpy`, made importable via a `renpy.pth`. A build-time `file(1)` guard fails the build
  unless the compiled `_renpy*.so` is an aarch64 object, catching any host-arch mis-build.
- **Runtime deps not obvious from the tarball** (all pulled in by `package/renpy/Config.in`):
  the source release does **not** bundle the pure-Python libs the SDK ships, so the engine
  needs `python-ecdsa` (imported at startup by `renpy.savetoken`; pulls `python-six`). It also
  needs Python stdlib C modules `zlib` + `unicodedata` (imported in `renpy.loader`). And SDL2
  must be built with **`BR2_PACKAGE_SDL2_X11` + `BR2_PACKAGE_SDL2_OPENGL`** — without the X11
  video backend + GL context support, `renpy.pygame.display.init()` dies with *"No available
  video device"* even with Xvfb up. (SDL2's default Buildroot config has only the `dummy`
  driver, which is why an `SDL_VIDEODRIVER=dummy` import test passes but real rendering fails.)
- **Engine carries one InkyOS patch:** `package/renpy/0001-add-eink-push-callback.patch` adds
  `config.eink_push_callback` and a single call site in the interact loop, so a game can
  capture one stable frame per advance for the e-ink display. The bundled `the_question`'s
  `game/eink_hook.rpy` sets that callback; without the patch the game aborts at init with
  *"config.eink_push_callback is not a known configuration variable."*
- **Under the gl2 renderer, Ren'Py first tries `gles2` and fails** (`Could not initialize
  OpenGL / GLES library`) — expected, because llvmpipe exposes desktop GL, not GLES — then
  succeeds on `gl2`/llvmpipe. The gles2 failure line in `log.txt` is benign.
- pygame_sdl2's `setuplib.py` imports `setuptools` (not the removed `distutils`) and Cython
  regenerates the C with `--3str`, so the 8.5.x line builds cleanly against Python 3.14 /
  Cython 3.1. Older Ren'Py releases need Cython 0.29 and throw `noexcept` Cython errors — do
  not pin those.
- The pin matches the Ren'Py **8.5.2** SDK studied alongside this repo. `8.5.3` is the latest
  upstream tag; bump both packages together if moving to it.

---

## Testing

### Emulator target (recommended for development)

**See and drive the UI on your laptop — one command:**

```bash
./run-emulator.sh          # boots QEMU *and* opens the e-ink preview window
```

This boots the image and opens a Tk window that is the stand-in for the e-ink panel, plus a
gamepad in the same window: **arrows / wasd** move, **j** = A, **k** = B, **Enter** = Start,
**h** = hold-Start (the exit-a-game combo). The terminal remains the guest serial console
(login: `root`, no password); quit everything with **Ctrl-A** then **X**.

> **Why a window and not `-vga`/`-display gtk`?** The device has no VGA/GPU screen — the UI is
> an **800×480 1-bit e-ink panel** driven over SPI. QEMU's `virt` machine has no such panel, so
> a VGA display would show nothing. Instead the launcher auto-starts at boot with
> `EINKY_DISPLAY_BACKEND=tcp` and streams frames over guest TCP **:5333** (input on **:5334**);
> `run-qemu.sh` forwards both to `localhost`, and `run-emulator.sh` points the preview client
> (`launcher/tools/dev_preview.py`, Tk + Pillow) at them. The window may stay blank for a few
> seconds until the guest launcher comes up (`--wait` retries), and it reconnects when the
> launcher restarts after a game exits.

Preview prerequisites (host, once): python3 **tkinter** + **Pillow**.

```bash
# Arch      : sudo pacman -S --needed tk python-pillow
# Debian/Ubuntu: sudo apt install python3-tk python3-pil.imagetk
# Fedora    : sudo dnf install python3-tkinter python3-pillow-tk
```

**Headless boot (no window):** the underlying wrapper auto-detects the kernel and rootfs under
`output-qemu/images/` and boots a single muxed serial console, no graphics:

```bash
./run-qemu.sh              # or:  NO_PREVIEW=1 ./run-emulator.sh
```

It runs the exact verified command for the `virt` machine (the `hostfwd` rules expose the
launcher's frame/input ports so a preview client can attach):

```bash
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 512 -smp 4 \
  -kernel output-qemu/images/Image \
  -append "rootwait root=/dev/vda console=ttyAMA0" \
  -drive file=output-qemu/images/rootfs.ext4,if=none,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=eth0,hostfwd=tcp::5333-:5333,hostfwd=tcp::5334-:5334 \
  -device virtio-net-device,netdev=eth0 \
  -serial mon:stdio -display none
```

Log in as `root` (no password). Exit QEMU with **Ctrl-A** then **X**. To attach the preview and
input tools to a running `./run-qemu.sh` by hand:

```bash
python3 ../launcher/tools/dev_preview.py --wait --scale 2 --input-port 5334   # screen + gamepad
python3 ../launcher/tools/send_input.py --port 5334                           # or a separate input sender
```

> Buildroot's `start-qemu.sh` is **not** generated here: its post-image step only emits that
> script when the defconfig name matches a `# <name>` tag in Buildroot's `readme.txt`, and our
> renamed `inky_qemu_defconfig` doesn't match. Use `./run-qemu.sh` instead.

### Hardware target — flashing to SD

```bash
lsblk                                    # identify the card carefully
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync
```

Use a USB-TTL serial adapter on the Pi's UART pins for the boot console.

### Changing a hardware pin

`meta/shared/hardware.toml` is the single source of truth for pins, **but the build
does not read it.** The image bakes in *committed, pre-generated* files; the contract is
only their upstream source, wired up by a manual `gen` step you must run in **each**
consumer repo. Editing `hardware.toml` alone changes nothing in the image.

To actually move a signal:

1. Edit `../meta/shared/hardware.toml`.
2. Regenerate in **both** repos — neither is optional:
   - `python3 scripts/gen_hardware.py` → `board/inky/config.txt` (SPI bus on + button
     boot-time pull-ups) and `board/common/…/input_hook.rpy` (in-engine button map).
   - `cd ../runtime && make gen` → `src/spi_driver/contract.h` (the DC/RST/BUSY/CS pins
     the panel driver actually toggles) and `src/input/keymap.py` (the button GPIOs the
     input daemon reads). **`config.txt` does not set these** — regenerating buildroot_os
     alone leaves the panel/button logic on the old pins.
3. `./build.sh pi`, then re-flash.

`./br.sh` runs `gen_hardware.py --check` before each build and fails on drift — but only
for **buildroot_os's own** files, not `runtime`'s (that's `runtime`'s own `make gen-check`),
and it skips entirely if `../meta` is absent. Full walkthrough + the fixed-SPI0-pins caveat:
`docs/docs/hardware/wiring.md` → *Changing a pin* (published at `docs.einky.fr`).

Note: hardware SPI0 (`mosi`/`sclk`/`cs`) is fixed to the Pi's ALT0 pins — changing those
numbers in the contract only relabels docs, it does not rewire SPI0.

---

## Environment variables

Set automatically by `br.sh`; documented here for reference and CI:

| Variable | Purpose |
|---|---|
| `BR2_DL_DIR` | download cache location (`.dl/`), persisted across builds |
| `BR2_CCACHE_DIR` | compiler cache location (`.ccache/`) |
| `HOME` | set to a writable in-tree path inside the container |

Enable `BR2_CCACHE=y` in the defconfig for the compiler cache to take effect (strongly
recommended — the Mesa/LLVM build is the long pole).

---

## Project status

Built in verifiable phases, each gated by a checkpoint.

- [ ] **Phase 1 — Minimal boot.** Boots to a login prompt in the emulator and on hardware.
- [ ] **Phase 2 — Graphics stack.** Mesa llvmpipe + Xvfb + SDL2; `glxinfo` reports the
      `llvmpipe` renderer (the critical GLX checkpoint).
- [x] **Phase 3 — Ren'Py from source.** `renpy` builds as a Buildroot package and
      `the_question` renders headless on the emulator: Ren'Py's `gl2` renderer comes up on
      Mesa **llvmpipe** (desktop GL 4.6) under Xvfb and draws the main menu, zero tracebacks.
      `./br.sh make renpy-rebuild` recompiles the engine. (`pygame-sdl2` is packaged but
      unused — 8.5.2 vendors its own `renpy.pygame`; see Pinned versions.) Verified by
      capturing the Xvfb framebuffer; see the captured frame in the session notes.
- [~] **Phase 4 — Boot-to-game + input.** *Session launcher done* (emulator): the
      `inky-session` package installs a BusyBox-init service (`S95inky-session`) that brings up
      Xvfb and supervises Ren'Py, so a clean boot lands on the_question's main menu with no
      manual launch (verified by capturing the framebuffer post-boot). Buildroot's stock
      `S40xorg` is removed by `board/common/post-build.sh` (the appliance uses Xvfb, not a
      VT-bound Xorg). *Remaining:* the GPIO→uinput input bridge — hardware-only, can't be
      exercised on the GPIO-less `virt` machine; on the emulator input is driven over
      `input_hook.rpy`'s socket via `input_sender.py`. The Pi defconfig now carries the same
      boot-to-game stack (`board/inky/` + `board/common/`), pending hardware validation.
- [ ] **Phase 5 — Hardening.** Read-only root + writable data partition for save survival.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `unable to prepare context: path ".../docker" not found` | `Dockerfile` must be at `docker/Dockerfile` |
| `buildroot/Makefile` missing | submodule not initialized — `git submodule update --init` |
| `<defconfig>: No such file` | Buildroot pin too old — use a 2024.08+ / LTS tag |
| `linux custom Downloading` hangs | `codeload.github.com` throttling — pre-fetch the kernel tarball into `.dl/linux/` (filename from `./br.sh make linux-show-info`); add a `.wgetrc` with `timeout`/`tries` under the container `HOME` |
| `Couldn't open dtb file …rpi-3-b.dtb` | wrong DTB name — `ls output/images/*.dtb` and use the actual one (`bcm2710-rpi-zero-2-w.dtb`) |
| `-serial stdio: cannot use stdio by multiple character devices` | drop `-serial stdio` when using `-nographic`, or use `-serial mon:stdio -display none` |
| raspi target silent in QEMU (CPU pegged, no output) | known raspi-machine console fidelity issue — **use the emulator (`virt`) target instead** |
| Ren'Py: `No available video device` | SDL2 built without the X11 backend — enable `BR2_PACKAGE_SDL2_X11` + `BR2_PACKAGE_SDL2_OPENGL`, then `sdl2-dirclean` and rebuild (config-only changes don't auto-rebuild a package) |
| Ren'Py: `config.X is not a known configuration variable` | game sets a config var the engine doesn't define — carry an engine patch under `package/renpy/*.patch` (see the eink callback patch) |
| Python `ModuleNotFoundError` for `zlib`/`unicodedata` after enabling the option | python3 was built before the sub-option — `python3-dirclean` + rebuild |
| Output files owned by root | should not happen with `br.sh`'s `--user`; confirm it's present |

---

## Build environment

- **Host:** any Linux with Docker (developed on Arch via WSL2).
- **Container:** Debian Bookworm (pinned), matching Buildroot's own CI base.
- **Buildroot:** pinned to an LTS release tag (2024.08+ required for the Zero 2 W defconfig).

## License

To be finalized. Engine and dependency components retain their own upstream licenses
(Ren'Py: MIT; pygame_sdl2: zlib/LGPL; Buildroot packages: various).