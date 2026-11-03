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
