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
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
IMAGE="inky-buildroot:bookworm"

# Build the image once (rebuild manually with: docker build -t "$IMAGE" docker)
if [ -z "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
  docker build -t "$IMAGE" "$REPO/docker"
fi

# Caches + output live in the repo (gitignored) so they persist across --rm runs.
mkdir -p "$REPO/.dl" "$REPO/.ccache" "$REPO/.home" "$REPO/output"

DOCKER_RUN=(docker run --rm -it
  --user "$(id -u):$(id -g)"
  -e HOME=/work/.home
  -e BR2_DL_DIR=/work/.dl
  -e BR2_CCACHE_DIR=/work/.ccache
  -v "$REPO":/work
  -w /work
  "$IMAGE")

if [ "${1:-}" = "make" ]; then
  shift
  exec "${DOCKER_RUN[@]}" make -C buildroot BR2_EXTERNAL=/work O=/work/output "$@"
else
  exec "${DOCKER_RUN[@]}" "$@"
fi

