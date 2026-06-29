################################################################################
#
# renpy
#
# The Ren'Py visual-novel engine. Built from the renpy.org source release (the
# git repo does not tag 8.x releases). The native modules are Cython + C/C++ and
# build via the engine's own setup.py, which:
#   * runs `cython` named by $RENPY_CYTHON to (re)generate the C, and
#   * discovers all dependency cflags/libs via pkg-config (only when CFLAGS /
#     LDFLAGS are UNSET) -- so this recipe deliberately does not export them and
#     instead points pkg-config at the staging sysroot.
# Extensions are built in-place (build_ext --inplace): renpy.* land inside the
# renpy/ tree, the top-level _renpy lands at the source root.
#
################################################################################

RENPY_VERSION = 8.5.2
RENPY_SOURCE = renpy-$(RENPY_VERSION)-source.tar.bz2
RENPY_SITE = https://www.renpy.org/dl/$(RENPY_VERSION)
RENPY_LICENSE = MIT
RENPY_LICENSE_FILES = LICENSE.txt

# Native-module build deps. jpeg is the virtual package name. NOTE: Ren'Py 8.5.2
# vendors its own pygame as `renpy.pygame` (engine does `import renpy.pygame as
# pygame`; the only `pygame_sdl2` symbols are back-compat aliases pointing AT
# renpy.pygame). The external pygame-sdl2 package is therefore NOT a build or
# runtime dep of the engine and is deliberately absent here.
RENPY_DEPENDENCIES = \
	python3 \
	ffmpeg harfbuzz freetype libfribidi assimp \
	sdl2 sdl2_image libpng jpeg zlib \
	host-python-cython

# Cross-build env for setup.py. The _PYTHON_* / PYTHONPATH vars are what make the
# host python3 emit aarch64 extensions with the target's sysconfig (same machinery
# Buildroot's python-package infra uses). setup.py's setuplib.env() invokes the
# bare string "pkg-config" (not $PKG_CONFIG), so what matters is that BR_PATH puts
# Buildroot's sysroot-aware host/bin/pkg-config FIRST -- verified that resolves
# sdl2/freetype2/etc. to $(STAGING_DIR), not host /usr. The PKG_CONFIG_* vars below
# pin the staging .pc search path (both lib/ and share/) and sysroot belt-and-braces.
# CFLAGS / LDFLAGS are intentionally absent so setup.py runs pkg-config itself.
RENPY_PYTHON_ENV = \
	_PYTHON_HOST_PLATFORM="$(PKG_PYTHON_HOST_PLATFORM)" \
	_PYTHON_PROJECT_BASE="$(PYTHON3_DIR)" \
	_PYTHON_SYSCONFIGDATA_NAME="$(PKG_PYTHON_SYSCONFIGDATA_NAME)" \
	PYTHONPATH="$(PYTHON3_PATH)" \
	PYTHONNOUSERSITE=1 \
	PATH="$(BR_PATH)" \
	PKG_CONFIG="$(HOST_DIR)/bin/pkg-config" \
	PKG_CONFIG_SYSROOT_DIR="$(STAGING_DIR)" \
	PKG_CONFIG_LIBDIR="$(STAGING_DIR)/usr/lib/pkgconfig:$(STAGING_DIR)/usr/share/pkgconfig" \
	RENPY_CYTHON="$(HOST_DIR)/bin/cython"

# Cap the extension compile at -j4: this box OOMs at high parallelism (see the
# Mesa/LLVM build), and Ren'Py has ~70 C/C++ modules.
#
# Architecture guard: build_ext driven by the host python3 will silently emit
# *host* (x86-64) objects if the cross sysconfig/pkg-config wiring is wrong. Run
# `file` on the freshly built top-level _renpy module and HARD-FAIL the build
# unless it is an aarch64 object, so a mis-build surfaces in seconds rather than
# after a long compile + a failed on-target import.
define RENPY_BUILD_CMDS
	cd $(@D) && $(RENPY_PYTHON_ENV) $(HOST_DIR)/bin/python3 setup.py build_ext --inplace -j4
	$(Q)so=$$(ls $(@D)/_renpy*.so 2>/dev/null | head -1); \
	if [ -z "$$so" ]; then echo "renpy: BUILD ERROR: no _renpy*.so produced"; exit 1; fi; \
	desc=$$(file -b "$$so"); echo "renpy: built $$(basename $$so): $$desc"; \
	echo "$$desc" | grep -qE 'aarch64|ARM aarch64' || { \
		echo "renpy: BUILD ERROR: $$so is not an aarch64 object (got: $$desc)"; \
		exit 1; }
endef

# Ship the engine tree under /opt/renpy (renpy.py appends its own dir to sys.path
# at launch). A .pth makes `import renpy` / `import _renpy` work from the stock
# python3 too -- _renpy.so sits at /opt/renpy, the renpy.* extensions in the tree.
define RENPY_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/opt/renpy
	cp -a $(@D)/renpy $(TARGET_DIR)/opt/renpy/
	cp -a $(@D)/renpy.py $(TARGET_DIR)/opt/renpy/
	cp -a $(@D)/_renpy*.so $(TARGET_DIR)/opt/renpy/
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages
	echo "/opt/renpy" > \
		$(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages/renpy.pth
endef

$(eval $(generic-package))
