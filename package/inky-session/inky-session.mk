################################################################################
#
# inky-session
#
# Boot-to-game session for InkyOS: a BusyBox-init service that brings up the
# Xvfb virtual display and supervises the Ren'Py game (restarting it on exit).
# Local files only -- there is no upstream source to download.
#
################################################################################

INKY_SESSION_VERSION = 1.0
INKY_SESSION_LICENSE = MIT
# Local files only: empty SOURCE tells Buildroot there is nothing to download
# (a non-empty VERSION otherwise derives a tarball name and demands a SITE).
INKY_SESSION_SOURCE =

define INKY_SESSION_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(INKY_SESSION_PKGDIR)/inky-session.sh \
		$(TARGET_DIR)/usr/bin/inky-session
endef

define INKY_SESSION_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(INKY_SESSION_PKGDIR)/S95inky-session \
		$(TARGET_DIR)/etc/init.d/S95inky-session
endef

$(eval $(generic-package))
