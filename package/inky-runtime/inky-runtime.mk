################################################################################
#
# inky-runtime
#
# The einky `runtime` package: the single owner (ADR 0008) of the e-ink frame
# pipeline (capture -> Floyd-Steinberg dither -> 1-bit pack -> dispatch), the
# GDEM0397T81P SPI driver, and the GPIO/keymap input bridge. InkyOS consumes it
# instead of reimplementing any of that logic.
#
# Source: the runtime repo, pinned to a commit. For local development the repo
# is usually a sibling checkout that the build container can't fetch (private /
# offline), so ./br.sh mounts ../runtime at /runtime and passes
# INKY_RUNTIME_OVERRIDE_SRCDIR=/runtime -- Buildroot then rsyncs the local tree
# and skips the download entirely (the standard OVERRIDE_SRCDIR workflow).
#
################################################################################

# Pinned for provenance / CI-with-credentials; bypassed by OVERRIDE_SRCDIR.
INKY_RUNTIME_VERSION = 958f26f6107e759432f1a2f5472e41a5ee3d7824
INKY_RUNTIME_SITE = $(call github,einky,runtime,$(INKY_RUNTIME_VERSION))
INKY_RUNTIME_SITE_METHOD = git
INKY_RUNTIME_LICENSE = MIT
INKY_RUNTIME_LICENSE_FILES = LICENSE

# pyproject.toml with the setuptools.build_meta backend -> PEP 517 build.
INKY_RUNTIME_SETUP_TYPE = pep517

# When built from a local checkout (./br.sh sets OVERRIDE_SRCDIR), keep the rsync
# lean: the 240M+ venv, the test/lint caches, and prebuilt host artifacts are not
# build inputs (the CFFI extension is recompiled below). .git is already excluded.
INKY_RUNTIME_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude .venv --exclude .mypy_cache --exclude .pytest_cache \
	--exclude .ruff_cache --exclude __pycache__ --exclude '*.egg-info' \
	--exclude build --exclude '*.so' --exclude '*.o'

# numpy + Pillow are imported by the frame pipeline on every target (emulator
# and hardware). host-python-setuptools/wheel are the PEP 517 backend.
INKY_RUNTIME_DEPENDENCIES = \
	python3 \
	python-numpy \
	python-pillow \
	host-python-setuptools \
	host-python-wheel

ifeq ($(BR2_PACKAGE_INKY_RUNTIME_SPI),y)
# host-python-cffi: build.py uses `from cffi import FFI` on the HOST python.
# python-cffi: the compiled _spi_driver imports _cffi_backend on the target.
# libgpiod2: the C driver links -lgpiod (v2 API) for the DC/RST/BUSY control
# lines; its staging headers + lib are what the cross CFFI build compiles/links
# against (via the cross-compiler sysroot, same as package/renpy's native libs).
# python-gpiod (selected in Config.in) shares the same libgpiod2 at runtime.
INKY_RUNTIME_DEPENDENCIES += host-python-cffi python-cffi libgpiod2

# Cross-compile env for runtime's CFFI SPI extension, mirroring package/renpy:
# the host python emits an aarch64 object because _PYTHON_SYSCONFIGDATA_NAME
# points sysconfig (hence the compiler/flags) at the target. cffi reads CC from
# sysconfig, so we deliberately do not export CFLAGS/LDFLAGS.
INKY_RUNTIME_SPI_ENV = \
	_PYTHON_HOST_PLATFORM="$(PKG_PYTHON_HOST_PLATFORM)" \
	_PYTHON_PROJECT_BASE="$(PYTHON3_DIR)" \
	_PYTHON_SYSCONFIGDATA_NAME="$(PKG_PYTHON_SYSCONFIGDATA_NAME)" \
	PYTHONPATH="$(PYTHON3_PATH)" \
	PYTHONNOUSERSITE=1 \
	PATH="$(BR_PATH)"

# Build the CFFI _spi_driver into src/spi_driver/build/, then HARD-FAIL unless
# it is an aarch64 object (a mis-wired cross build would silently emit x86-64).
define INKY_RUNTIME_BUILD_SPI_EXT
	rm -rf $(@D)/src/spi_driver/build
	cd $(@D) && $(INKY_RUNTIME_SPI_ENV) $(HOST_DIR)/bin/python3 src/spi_driver/build.py
	$(Q)so=$$(ls $(@D)/src/spi_driver/build/_spi_driver*.so 2>/dev/null | head -1); \
	if [ -z "$$so" ]; then echo "inky-runtime: BUILD ERROR: no _spi_driver*.so produced"; exit 1; fi; \
	desc=$$(file -b "$$so"); echo "inky-runtime: built $$(basename $$so): $$desc"; \
	echo "$$desc" | grep -qE 'aarch64|ARM aarch64' || { \
		echo "inky-runtime: BUILD ERROR: $$so is not an aarch64 object (got: $$desc)"; \
		exit 1; }
endef
INKY_RUNTIME_POST_BUILD_HOOKS += INKY_RUNTIME_BUILD_SPI_EXT

# Install the compiled extension next to the runtime packages in site-packages;
# spi_driver/__init__.py does `from _spi_driver import ffi, lib`.
define INKY_RUNTIME_INSTALL_SPI_EXT
	$(Q)so=$$(ls $(@D)/src/spi_driver/build/_spi_driver*.so | head -1); \
	$(INSTALL) -D -m 0755 "$$so" \
		$(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages/$$(basename "$$so")
endef
INKY_RUNTIME_POST_INSTALL_TARGET_HOOKS += INKY_RUNTIME_INSTALL_SPI_EXT
endif

$(eval $(python-package))
