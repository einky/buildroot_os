#!/usr/bin/env bash
# Thin dispatcher over ./br.sh to build either InkyOS target into its own output dir.
#
#   ./build.sh qemu     # EMULATOR target  (inky_qemu_defconfig)  -> output-qemu/
#   ./build.sh pi       # HARDWARE target  (inky_defconfig)       -> output/
#
# Both load the defconfig then run a parallel build through the container. Extra
# args are passed straight to the final `./br.sh make`, e.g.:
#   ./build.sh qemu menuconfig
#   ./build.sh pi linux-rebuild
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BR="$REPO/br.sh"

target="${1:-}"
shift || true

case "$target" in
  qemu)
    out="output-qemu"
    defconfig="inky_qemu_defconfig"
    ;;
  pi)
    out="output"
    defconfig="inky_defconfig"
    ;;
  *)
    echo "usage: $0 {qemu|pi} [extra ./br.sh make args]" >&2
    exit 1
    ;;
esac

# INKY_OUT selects the output dir; br.sh maps it to O=/work/$INKY_OUT in the container.
# Load the defconfig, then build with all cores. Any extra args (menuconfig,
# pkg-rebuild, ...) run instead of the default build.
if [ "$#" -gt 0 ]; then
  exec env INKY_OUT="$out" "$BR" make "$@"
fi

INKY_OUT="$out" "$BR" make "$defconfig"
exec env INKY_OUT="$out" "$BR" make -j"$(nproc)"
