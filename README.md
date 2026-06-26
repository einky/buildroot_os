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

---

## Testing

### Emulator target (recommended for development)

Boot the emulator image on the host with the provided wrapper, which auto-detects the kernel
and rootfs under `output-qemu/images/`:

```bash
./run-qemu.sh
```

It runs the exact verified command for the `virt` machine — a single muxed serial console to
your terminal, no graphics:

```bash
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 512 -smp 4 \
  -kernel output-qemu/images/Image \
  -append "rootwait root=/dev/vda console=ttyAMA0" \
  -drive file=output-qemu/images/rootfs.ext4,if=none,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 \
  -serial mon:stdio -display none
```

Log in as `root` (no password). Exit QEMU with **Ctrl-A** then **X**.

> Buildroot's `start-qemu.sh` is **not** generated here: its post-image step only emits that
> script when the defconfig name matches a `# <name>` tag in Buildroot's `readme.txt`, and our
> renamed `inky_qemu_defconfig` doesn't match. Use `./run-qemu.sh` instead.

### Hardware target — flashing to SD

```bash
lsblk                                    # identify the card carefully
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync
```

Use a USB-TTL serial adapter on the Pi's UART pins for the boot console.

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
- [ ] **Phase 3 — Ren'Py from source.** `pygame-sdl2` and `renpy` build as Buildroot
      packages; a trivial game renders headless. `./br.sh make renpy-rebuild` recompiles the
      engine.
- [ ] **Phase 4 — Boot-to-game + input.** Session launcher + GPIO→uinput bridge; power-on →
      game → buttons navigate.
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
| Output files owned by root | should not happen with `br.sh`'s `--user`; confirm it's present |

---

## Build environment

- **Host:** any Linux with Docker (developed on Arch via WSL2).
- **Container:** Debian Bookworm (pinned), matching Buildroot's own CI base.
- **Buildroot:** pinned to an LTS release tag (2024.08+ required for the Zero 2 W defconfig).

## License

To be finalized. Engine and dependency components retain their own upstream licenses
(Ren'Py: MIT; pygame_sdl2: zlib/LGPL; Buildroot packages: various).