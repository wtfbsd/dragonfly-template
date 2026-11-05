#!/bin/sh
# make-out.sh OUTDIR SLUG NAME VARIANT — placeholders for the files the render
# of the artwork template makes, as the DragonFly template installs them.
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
set -eu
o=$1 s=$2 n=$3 v=$4
w() { mkdir -p "$o/$(dirname "$1")"; printf 'variant=%s name=%s file=%s\n' "$v" "$n" "$1" > "$o/$1"; }
for f in lightdm/greeter-1920x1080.png lightdm/greeter-gtk.css dm/xdm/Xresources dm/xdm/Xsetup_0 \
	installer/header.png installer/sidebar.png xfce/gtk-colors.css \
	wallpapers/wallpaper-1-1920x1080.png wallpapers/wallpaper-2-1920x1080.png wallpapers/wallpaper-3-1920x1080.png \
	wallpapers/wallpaper-1-3840x2160.png xfce/xfconf/xfce4-panel.xml xfce/xfconf/xsettings.xml xfce/xfwm4-themerc \
	"dm/pixmaps/$s-color.xpm" "dm/pixmaps/$s-8bpp.xpm" "dm/pixmaps/$s-1bpp.xpm"; do
	w "$f"
done
for i in logo menu installer; do
	w "icons/hicolor/48x48/apps/$s-$i.png"
	w "icons/hicolor/scalable/apps/$s-$i.svg"
done
mkdir -p "$o/lightdm" "$o/xfce/xfconf" "$o/boot/dragonfly" "$o/console"
printf '[greeter]\nbackground=/usr/local/share/%s/lightdm/greeter-1920x1080.png\ntheme-name=%s-greeter\n' "$s" "$s" > "$o/lightdm/lightdm-gtk-greeter.conf"
printf '<channel name="xfce4-desktop"><property name="last-image" type="string" value="/usr/local/share/%s/wallpapers/wallpaper-1-1920x1080.png"/></channel>\n' "$s" > "$o/xfce/xfconf/xfce4-desktop.xml"
printf '# %s menu entries for the DragonFly loader\nmenuitem 1 "Boot %s [${default_kernel}]"\nmenuitem s "Boot %s in single user mode"\n' "$n" "$n" "$n" > "$o/boot/dragonfly/dloader.menu"
printf '\n%s - variant %s\n' "$n" "$v" > "$o/console/motd.template"
printf '# %s login banner\n\t:im=\\r\\n%s (%%h) (%%t)\\r\\n\\r\\n:\n' "$n" "$n" > "$o/console/gettytab.fragment"
printf '\n%s\n\n' "$n" > "$o/console/issue"
# the session helper of the wallpaper and its autostart entry (the pack's
# xfce/autostart and xfce/session), named for FAKE_ART_SESSION_NAME (default
# the slug); FAKE_ART_SESSION_EXEC names another path in Exec=;
# FAKE_ART_SESSION=none|desktop-only|link drops both, drops the helper, or
# makes the helper a symbolic link
if [ "${FAKE_ART_SESSION:-}" != none ]; then
	sn=${FAKE_ART_SESSION_NAME:-$s}
	mkdir -p "$o/xfce/autostart" "$o/xfce/session"
	printf '[Desktop Entry]\nType=Application\nName=%s wallpaper\nExec=/bin/sh "%s"\nOnlyShowIn=XFCE;\nNoDisplay=true\nTerminal=false\n' \
		"$n" "${FAKE_ART_SESSION_EXEC:-/usr/local/share/$sn/xfce/session/$sn-wallpaper.sh}" > "$o/xfce/autostart/$sn-wallpaper.desktop"
	case ${FAKE_ART_SESSION:-} in
	desktop-only) ;;
	link) ln -s /etc/master.passwd "$o/xfce/session/$sn-wallpaper.sh" ;;
	*) printf '#!/bin/sh\n# the wallpaper of %s on every output\nexit 0\n' "$n" > "$o/xfce/session/$sn-wallpaper.sh" ;;
	esac
fi
