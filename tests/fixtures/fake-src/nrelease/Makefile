# Makefile of the fake nrelease directory used by the test suite.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The variables and the targets are the ones of the upstream nrelease
# directory of DragonFly (upstream nrelease/Makefile):
#
#   REQ_ROOTSKELS   the skeleton of the release root
#   ROOTSKELS?=     the rootskels that customizeiso copies over the
#                   release root; the default is REQ_ROOTSKELS
#   ROOTSKELS+=     the skeleton of the GUI, under the gui modifier
#   ISOROOT         the release root (${ISODIR}/root by default)
#   DPORTS_EXTRA_PACKAGES  the packages that are added to the release root
#   ISOFILE, IMGFILE  the names of the two media
#
# A ROOTSKELS on the command line REPLACES every default of this file:
# the caller that wants the skeleton of the release tooling has to name
# it itself. The stand-in for make(1) in tests/stubs models that
# (?=, += and the command line), so that a build.sh that forgets the
# skeleton of the release tooling loses it.
#
# "gui", "nopkgs" and "binpkgs" modify the release (make binpkgs
# release): upstream declares them as targets with no commands
# (gui nopkgs binpkgs:) and tests them with make(...). gui adds the
# skeleton of the GUI to ROOTSKELS; with binpkgs the packages are
# installed with pkg (by name, then by origin); without it every DPorts
# origin is built with make install in a chroot.

REQ_ROOTSKELS=	${.CURDIR}/root
ROOTSKELS?=	${REQ_ROOTSKELS}

.if make(gui)
ROOTSKELS+=		${.CURDIR}/gui
.endif  # make(gui)

check:
	@echo "check"

clean:
	@echo "clean"

buildworld1:
	@echo "buildworld1"

buildkernel1:
	@echo "buildkernel1"

buildiso:
	@echo "buildiso"

pkgs:
	@echo "pkgs"

customizeiso:
	@echo "customizeiso"

srcs:
	@echo "srcs"

mkiso:
	@echo "mkiso"

mkimg:
	@echo "mkimg"

release:
	@echo "release"

gui nopkgs binpkgs:
