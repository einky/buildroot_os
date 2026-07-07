# InkyOS host-side helper targets.
#
# The Buildroot IMAGE build does NOT go through this Makefile -- it runs inside
# the pinned container via ./build.sh (which drives ./br.sh -> Buildroot's own
# Makefile). This file is only host tooling that runs directly on your machine,
# chiefly the emulator end-to-end acceptance test.

.DEFAULT_GOAL := help

.PHONY: help e2e e2e-bless

help:
	@echo "InkyOS host targets (run on the host, not in the build container):"
	@echo "  make e2e         end-to-end emulator acceptance test (build first: ./build.sh qemu)"
	@echo "  make e2e-bless   regenerate the committed golden frame(s) from a fresh run"
	@echo
	@echo "Build the OS image with ./build.sh qemu (emulator) or ./build.sh pi (hardware)."

# End-to-end acceptance test: boot the emulator, drive a full session, assert the
# boot golden + game handoff + in-game session + reboot recovery. Prints one
# E2E_METRICS line and fails loudly with artifacts under tests/.artifacts/.
e2e:
	./run-e2e.sh

# Regenerate goldens (eyeball the printed diff summary before committing).
e2e-bless:
	./run-e2e.sh --bless
