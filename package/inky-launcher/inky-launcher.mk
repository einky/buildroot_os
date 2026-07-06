################################################################################
#
# inky-launcher
#
# The einky first-boot launcher / dashboard (ADR 0009): the game library and
# system-settings UI. A pure-Python app that renders 1-bit frames with Pillow
# and drives the panel + buttons through the shared `runtime` package. Consumed
# by inky-session as the process the appliance boots into.
#
# Source: the launcher repo, pinned to a commit. For local development the repo
# is usually a sibling checkout that the build container can't fetch (private /
# offline), so ./br.sh mounts ../launcher at /launcher and passes
# INKY_LAUNCHER_OVERRIDE_SRCDIR=/launcher -- Buildroot then rsyncs the local tree
# and skips the download entirely (the standard OVERRIDE_SRCDIR workflow).
#
################################################################################

# Pinned for provenance / CI-with-credentials; bypassed by OVERRIDE_SRCDIR.
INKY_LAUNCHER_VERSION = 0.1.0
INKY_LAUNCHER_SITE = $(call github,einky,launcher,v$(INKY_LAUNCHER_VERSION))
INKY_LAUNCHER_SITE_METHOD = git
INKY_LAUNCHER_LICENSE = MIT
INKY_LAUNCHER_LICENSE_FILES = LICENSE

# pyproject.toml with the setuptools.build_meta backend -> PEP 517 build.
INKY_LAUNCHER_SETUP_TYPE = pep517

# When built from a local checkout (./br.sh sets OVERRIDE_SRCDIR), keep the rsync
# lean: the venv, test/lint caches, and prebuilt host artifacts are not build
# inputs. .git is already excluded by Buildroot.
INKY_LAUNCHER_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude .venv --exclude .mypy_cache --exclude .pytest_cache \
	--exclude .ruff_cache --exclude __pycache__ --exclude '*.egg-info' \
	--exclude .state --exclude build --exclude '*.so' --exclude '*.o'

# Pillow backs the frame compositing; inky-runtime supplies frame_processor /
# input / spi_driver at runtime (a Buildroot dependency, not resolved from the
# wheel's metadata). host-python-setuptools/wheel are the PEP 517 backend.
INKY_LAUNCHER_DEPENDENCIES = \
	python3 \
	python-pillow \
	inky-runtime \
	host-python-setuptools \
	host-python-wheel

$(eval $(python-package))
