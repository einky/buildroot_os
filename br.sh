#!/usr/bin/env bash
# Run Buildroot inside the container. Drop this at the root of your `os` repo.
#
#   ./br make raspberrypizero2w_64_defconfig
#   ./br make menuconfig
#   ./br make savedefconfig BR2_DEFCONFIG=/work/configs/inky_defconfig
#   ./br make -j"$(nproc)"
#   ./br make renpy-rebuild
#   ./br bash                       # interactive shell in the container
#
# The Buildroot output directory is selectable via INKY_OUT (default "output"),
# so multiple targets can coexist without clobbering each other, e.g.:
#
#   ./br make inky_defconfig && ./br make -j"$(nproc)"                 # Pi -> output/
#   INKY_OUT=output-qemu ./br make inky_qemu_defconfig                 # emulator -> output-qemu/
#   INKY_OUT=output-qemu ./br make -j"$(nproc)"
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
IMAGE="inky-buildroot:bookworm"

# Output dir (relative to the repo root / container /work). Override with INKY_OUT.
INKY_OUT="${INKY_OUT:-output}"

# Build the image once (rebuild manually with: docker build -t "$IMAGE" docker)
if [ -z "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
  docker build -t "$IMAGE" "$REPO/docker"
fi

# Caches + output live in the repo (gitignored) so they persist across --rm runs.
mkdir -p "$REPO/.dl" "$REPO/.ccache" "$REPO/.home" "$REPO/$INKY_OUT"

# Allocate an interactive TTY only when attached to one (menuconfig, bash); omit
# it for non-interactive/CI use (piped builds) so `docker run` doesn't error out.
TTY_FLAGS=(-i)
[ -t 0 ] && TTY_FLAGS=(-it)

DOCKER_RUN=(docker run --rm "${TTY_FLAGS[@]}"
  --user "$(id -u):$(id -g)"
  -e HOME=/work/.home
  -e BR2_DL_DIR=/work/.dl
  -e BR2_CCACHE_DIR=/work/.ccache
  -v "$REPO":/work
  -w /work
  "$IMAGE")

if [ "${1:-}" = "make" ]; then
  shift
  exec "${DOCKER_RUN[@]}" make -C buildroot BR2_EXTERNAL=/work O="/work/$INKY_OUT" "$@"
else
  exec "${DOCKER_RUN[@]}" "$@"
fi

