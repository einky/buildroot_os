################################################################################
#
# pygame-sdl2
#
# Ren'Py's SDL2 binding. Built from source with host Cython. The version is
# pinned in lockstep with the Ren'Py release (see README "Pinned versions");
# pygame_sdl2 tags mirror the renpy tags exactly.
#
################################################################################

PYGAME_SDL2_VERSION = renpy-8.5.2.26010301
PYGAME_SDL2_SITE = $(call github,renpy,pygame_sdl2,$(PYGAME_SDL2_VERSION))
PYGAME_SDL2_SETUP_TYPE = setuptools
PYGAME_SDL2_LICENSE = Zlib, LGPL-2.1
PYGAME_SDL2_LICENSE_FILES = COPYING.ZLIB COPYING.LGPL21

PYGAME_SDL2_DEPENDENCIES = \
	sdl2 sdl2_image sdl2_ttf sdl2_mixer sdl2_gfx \
	jpeg libpng \
	host-python-cython

# setup.py shells out to `sdl2-config` to discover SDL2 cflags/libs. Putting
# the STAGING bindir first makes it resolve the *target* sdl2-config (so we
# cross-compile against the target SDL2), while host Cython still resolves from
# BR_PATH. PYGAME_SDL2_{CC,LD,CXX} are read by setup.py's setup_env() as a
# fallback (only used if CC/LD/CXX aren't already set by the python infra).
PYGAME_SDL2_ENV = \
	PYGAME_SDL2_CC="$(TARGET_CC)" \
	PYGAME_SDL2_LD="$(TARGET_LD)" \
	PYGAME_SDL2_CXX="$(TARGET_CXX)" \
	PATH="$(STAGING_DIR)/usr/bin:$(BR_PATH)"

# pygame_sdl2 ships an install_headers.py that copies the public C headers
# (pygame_sdl2.h plus the Cython-generated *_api.h files in gen3/) into
# <prefix>/include/pygame_sdl2 and <prefix>/include/pythonX.Y/pygame_sdl2.
# The renpy package #includes these, so they must land in STAGING. Run it with
# the host python after the build, from the build tree where gen3/ now exists.
define PYGAME_SDL2_INSTALL_STAGING_HEADERS
	cd $(@D) && $(HOST_DIR)/bin/python3 install_headers.py $(STAGING_DIR)/usr
endef
PYGAME_SDL2_POST_INSTALL_TARGET_HOOKS += PYGAME_SDL2_INSTALL_STAGING_HEADERS

$(eval $(python-package))
