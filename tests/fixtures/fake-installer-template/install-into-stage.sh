#!/bin/sh
#
# tests/fixtures/fake-installer-template/install-into-stage.sh — a stand-in
# for install-into-stage.sh of installer-template, for the test suite.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# usage: install-into-stage.sh DESTDIR [--conf FILE] [--metalog FILE] [--artwork DIR]
#
# It installs the paths the contract of installer-template names (with
# placeholder contents) and the MANIFEST that lists them, so that the
# suite can check what build.sh, the live session and the install command
# do with them. It logs its arguments to $STUB_LOG. Like the real one
# (installer-template ceda104) it refuses to run without root and without
# --metalog, and refuses an --artwork directory without palette.env.

set -eu
[ $# -ge 1 ] || { echo "usage: $0 DESTDIR [--conf FILE] [--metalog FILE] [--artwork DIR]" >&2; exit 2; }
[ -z "${STUB_LOG:-}" ] || printf 'INSTALL-INTO-STAGE-ARGS %s\n' "$*" >> "$STUB_LOG"
D=$1
shift
conf=''
metalog=''
artwork=''
while [ $# -gt 0 ]; do
	case $1 in
	--conf) conf=$2; shift 2 ;;
	--metalog) metalog=$2; : >> "$2"; shift 2 ;;
	--artwork) artwork=$2; shift 2 ;;
	*) echo "$0: unknown argument $1" >&2; exit 2 ;;
	esac
done
[ -d "$D" ] || { echo "$0: no such directory: $D" >&2; exit 2; }
if [ "$(id -u)" != 0 ] && [ -z "$metalog" ]; then
	echo "$0: not root and no --metalog: the installed files would not belong to root" >&2
	exit 1
fi
if [ -n "$artwork" ] && [ ! -f "$artwork/palette.env" ]; then
	echo "$0: the artwork has no palette.env: $artwork" >&2
	exit 1
fi
[ -z "${STUB_LOG:-}" ] || printf 'INSTALL-INTO-STAGE %s\n' "$D" >> "$STUB_LOG"
L=/usr/local/libexec/wtfbsd-installer
S=/usr/local/share/wtfbsd-installer
mkdir -p "$D$L/bin" "$D$S/autostart" "$D$S/desktop" "$D/usr/local/bin" "$D/usr/local/share/applications"
printf '#!/bin/sh\nexit 0\n' > "$D/usr/local/bin/wtfbsd-installer"
printf '#!/bin/sh\nexit 0\n' > "$D$L/installer-apply"
printf '#!/bin/sh\nexit 0\n' > "$D$L/bin/installer-gui"
if [ -n "$conf" ]; then cp "$conf" "$D$L/installer.conf"; else : > "$D$L/installer.conf"; fi
printf '[Desktop Entry]\nType=Application\nName=Installer\nExec=%s/bin/installer-session\n' "$L" > "$D$S/autostart/wtfbsd-installer.desktop"
printf '[Desktop Entry]\nType=Application\nName=Install\nExec=/usr/local/bin/wtfbsd-installer --graphical\n' > "$D/usr/local/share/applications/wtfbsd-installer.desktop"
cp "$D/usr/local/share/applications/wtfbsd-installer.desktop" "$D$S/desktop/wtfbsd-installer.desktop"
chmod 755 "$D/usr/local/bin/wtfbsd-installer" "$D$L/bin/installer-gui"
chmod 555 "$D$L/installer-apply"
{
	printf '%s\n' "$L/bin/installer-gui" "$L/installer-apply" "$L/installer.conf" \
		/usr/local/bin/wtfbsd-installer /usr/local/share/applications/wtfbsd-installer.desktop \
		"$S/desktop/wtfbsd-installer.desktop" "$S/autostart/wtfbsd-installer.desktop" "$S/MANIFEST" \
		"$L/bin/" "$S/autostart/" "$S/desktop/" "$L/" "$S/"
} > "$D$S/MANIFEST"
