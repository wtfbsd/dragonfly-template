#!/bin/sh
#
# tools/brand-stage.sh — brand the release root of the DragonFly desktop from
# the artwork template.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# usage: tools/brand-stage.sh ART VARIANT ROOT WORKDIR SLUG NAME VERSION ARCH [COMMIT]
#
#   ART      the artwork: a pre-rendered pack of the artwork template
#            (scripts/pack.sh: PACK, out/, branding/spots.tsv, the palettes
#            and the identity scripts), unpacked; or a source checkout of
#            the template (scripts/render.sh), rendered here
#   VARIANT  the artwork variant (ARTWORK_VARIANT): default, cyberpunk, ...
#   ROOT     the release root of the build (the built system: its kernel
#            names the DragonFly release, BASE of the identity)
#   WORKDIR  a scratch directory of the build (emptied first)
#   SLUG, NAME  the product (DISTRO_SLUG, DISTRO_NAME)
#   VERSION, ARCH  PRODUCT_VERSION and the architecture
#   COMMIT   the commit the pack must have been made from (ARTWORK_REF), or
#            empty
#
# What it does:
#
#   1. Checks the pack: its PACK names the slug of the product, the variant
#      and (when COMMIT is given) the commit.
#   2. Writes the identity of the image, /usr/local/share/<slug>/identity,
#      with the template's scripts/identity-file.sh: PRODUCT, VERSION, BASE
#      (read from the built kernel: "DragonFly 6.4.2", never typed in),
#      VARIANT (the label of the variant), ARCH and BUILD (the build date
#      when the version is not numbers and dots, a test build).
#   3. Stamps the identity line, lower left, on the greeter background and
#      on every wallpaper (the pack's scripts/identity-stamp.sh, ImageMagick;
#      a source checkout is rendered with render.sh --identity instead).
#   4. Installs every branding spot that branding/spots.tsv of the template
#      marks supported on DragonFly (its "dragonfly" column is not "n/a: ..."
#      and not "check: ..."), each by the DragonFly action below. A spot the
#      list marks supported that this script has no action for, or whose
#      rendered file is missing, stops the build: no spot is left at the
#      DragonFly default. The columns are read by their header names; a
#      missing column stops the build.
#   5. Installs the wallpaper session helper of the artwork and its XDG
#      autostart entry (see step 5 below).

set -eu

PROG=${0##*/}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

[ $# -eq 8 ] || [ $# -eq 9 ] || die "usage: $PROG ART VARIANT ROOT WORKDIR SLUG NAME VERSION ARCH [COMMIT]"
ART=$1 VARIANT=$2 ROOT=$3 WORK=$4 SLUG=$5 NAME=$6 VERSION=$7 ARCH=$8 COMMIT=${9:-}

printf '%s\n' "$VARIANT" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' || die "ARTWORK_VARIANT must match ^[a-z][a-z0-9-]{0,31}\$ (got: $VARIANT)"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$' || die "PRODUCT_VERSION must match ^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}\$ (got: $VERSION)"
[ -d "$ROOT" ] || die "no such release root: $ROOT"
[ -f "$ART/branding/spots.tsv" ] || die "the artwork has no branding/spots.tsv: $ART"
case $WORK in /*) ;; *) die "WORKDIR must be absolute: $WORK" ;; esac
rm -rf "${WORK:?}/out" "$WORK/src"
mkdir -p "$WORK"

# palval <file> <KEY> — the value of a key of a palette file (parsed)
palval() {
	[ -f "$1" ] || return 0
	sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$1" | tail -n 1
}
VPAL="$ART/variants/$VARIANT/palette.env"
LABEL=$(palval "$VPAL" VARIANT_LABEL)
[ -n "$LABEL" ] || LABEL=$(printf '%s' "$VARIANT" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')

# 1. the pack, or the source of the template
if [ -f "$ART/PACK" ]; then
	MODE=pack
	_pn=$(sed -n 's/^name=//p' "$ART/PACK")
	_pv=$(sed -n 's/^variant=//p' "$ART/PACK")
	_pc=$(sed -n 's/^commit=//p' "$ART/PACK")
	[ "$_pn" = "$SLUG" ] || die "the artwork pack was made for $_pn, not for $SLUG: render a pack with the palette of the product (scripts/rebrand.sh, then scripts/pack.sh)"
	[ "$_pv" = "$VARIANT" ] || die "the artwork pack holds the variant $_pv, not $VARIANT (ARTWORK_VARIANT)"
	if [ -n "$COMMIT" ]; then
		# the pack names its commit by 12 or more hex digits: one of the two
		# must be a prefix of the other (at least 7 digits)
		case $_pc in
		"$COMMIT"*) ;;
		*)
			case $COMMIT in
			"$_pc"*) [ "${#_pc}" -ge 7 ] || die "the artwork pack names no commit" ;;
			*) die "the artwork pack was made from $_pc, not from ARTWORK_REF $COMMIT" ;;
			esac
			;;
		esac
	fi
	[ -d "$ART/out" ] || die "the artwork pack has no out/"
	[ -f "$VPAL" ] || [ "$VARIANT" = default ] || die "the artwork pack has no palette of the variant $VARIANT"
	cp -R "$ART/out" "$WORK/out"
else
	MODE=source
	[ -f "$ART/scripts/render.sh" ] || die "neither an artwork pack (PACK) nor a source checkout (scripts/render.sh): $ART"
	[ -d "$ART/variants/$VARIANT" ] || die "the artwork template has no variant $VARIANT; variants: $(ls "$ART/variants" 2> /dev/null | tr '\n' ' ')"
fi

# 2. the identity of the image: the base system from its own kernel
_kv=$(grep -a -o 'DragonFly v[0-9][0-9]*\.[0-9][0-9.]*' "$ROOT/boot/kernel/kernel" 2> /dev/null | head -n 1)
[ -n "$_kv" ] || die "cannot read the DragonFly release from the kernel of the release root ($ROOT/boot/kernel/kernel)"
BASE="DragonFly ${_kv#DragonFly v}"
BUILD_DATE=${WTFBSD_BUILD_DATE:-$(date -u +%Y-%m-%d)}
set -- --product "$NAME" --version "$VERSION" --base "$BASE" --variant "$LABEL" --arch "$ARCH"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || set -- "$@" --build "$BUILD_DATE"
IDF="$ROOT/usr/local/share/$SLUG/identity"
mkdir -p "$ROOT/usr/local/share/$SLUG"
[ -f "$ART/scripts/identity-file.sh" ] || die "the artwork has no scripts/identity-file.sh"
sh "$ART/scripts/identity-file.sh" "$@" > "$IDF" || die "scripts/identity-file.sh of the artwork refused the identity ($*)"
chmod 644 "$IDF"

# 3. the identity line, lower left, on the greeter and the wallpapers
if [ "$MODE" = pack ]; then
	[ -f "$ART/scripts/identity-stamp.sh" ] || die "the artwork pack has no scripts/identity-stamp.sh"
	command -v magick > /dev/null 2>&1 || command -v convert > /dev/null 2>&1 ||
		die "stamping the identity line needs ImageMagick (magick or convert) on the build host (pkg install ImageMagick7-nox11)"
	_st=0
	for _png in "$WORK/out/lightdm/greeter-1920x1080.png" "$WORK/out/wallpapers"/wallpaper-*.png; do
		[ -f "$_png" ] || continue
		_bottom=0
		case $_png in */wallpapers/*) _bottom=30 ;; esac # the panel of the desktop
		sh "$ART/scripts/identity-stamp.sh" --palette "$ART/palette.env" --variant "$VARIANT" --bottom "$_bottom" \
			"$IDF" "$_png" "$_png.stamped" > "$WORK/stamp.log" 2>&1 ||
			{ cat "$WORK/stamp.log" >&2; die "the identity line could not be stamped on $_png"; }
		mv "$_png.stamped" "$_png"
		_st=$((_st + 1))
	done
	[ "$_st" -gt 0 ] || die "the artwork pack has no greeter background or wallpaper to stamp"
else
	sh "$ART/scripts/render.sh" --variant "$VARIANT" --identity "$IDF" "$ART/palette.env" "$WORK/out" > "$WORK/render.log" 2>&1 ||
		die "the render of the artwork failed (see $WORK/render.log; it needs rsvg-convert, inkscape or cairosvg, and ImageMagick)"
fi
cp "$IDF" "$WORK/identity"

# 4. the branding spots of DragonFly
OUTD="$WORK/out"
need() { # need <spot> <rendered file>... — the files must be in the render
	_ns=$1
	shift
	for _nf in "$@"; do
		[ -f "$OUTD/$_nf" ] || die "spot $_ns is supported on DragonFly but the artwork has no $_nf"
	done
}
put() { # put <rendered file> <path in the image> [mode]
	mkdir -p "$ROOT$(dirname -- "$2")"
	cp "$OUTD/$1" "$ROOT$2"
	chmod "${3:-644}" "$ROOT$2"
}
icons() { # icons <name> — every size of an icon of the product
	_found=0
	for _f in "$OUTD"/icons/hicolor/*/apps/"$SLUG-$1".*; do
		[ -f "$_f" ] || continue
		_rel=${_f#"$OUTD"/}
		put "$_rel" "/usr/local/share/$_rel"
		_found=1
	done
	[ "$_found" -eq 1 ] || die "spot icon-$1 is supported on DragonFly but the artwork has no icons/hicolor/*/apps/$SLUG-$1.*"
}
gettytab_im() { # gettytab_im <gettytab> — the im= of the default entry from the fragment
	[ -f "$1" ] || return 0
	_im=$(sed -n 's/^[[:space:]]*:im=\(.*\):[[:space:]]*$/\1/p' "$OUTD/console/gettytab.fragment" | head -n 1)
	[ -n "$_im" ] || die "spot login-issue: console/gettytab.fragment has no :im=...: line"
	# the capability is replaced in place, in the lines of the default
	# entry (im= sits among other capabilities: ":cb:ce:...:im=...:sp#1200:\")
	IM=$_im awk '
		/^default:/ { indef = 1 }
		indef && !done && (p = index($0, ":im=")) > 0 {
			rest = substr($0, p + 4)
			q = index(rest, ":")
			if (q > 0) { $0 = substr($0, 1, p + 3) ENVIRON["IM"] substr(rest, q); done = 1 }
		}
		{ print }
		indef && !/\\$/ { indef = 0 }
		END { if (!done) exit 1 }' "$1" > "$1.new" || die "spot login-issue: no im= in the default entry of $1"
	cat "$1.new" > "$1"
	rm -f "$1.new"
}
dloader_menu() { # the stock menu of the release with the titles of the artwork
	_def="$ROOT/boot/defaults/dloader.menu"
	[ -f "$_def" ] || die "spot loader-menu-title: the release root has no $_def"
	awk '
		FNR == NR { if ($1 == "menuitem") t[$2] = $0; next }
		$1 == "menuitem" && ($2 in t) { print t[$2]; next }
		{ print }' "$OUTD/boot/dragonfly/dloader.menu" "$_def" > "$ROOT/boot/dloader.menu" ||
		die "cannot write $ROOT/boot/dloader.menu"
	chmod 644 "$ROOT/boot/dloader.menu"
	# the ASCII mascot compiled into dloader is hidden (spot loader-logo)
	grep -q '^fred_disable=' "$ROOT/boot/loader.conf" 2> /dev/null ||
		printf 'fred_disable="YES"\n' >> "$ROOT/boot/loader.conf"
}
XFCONF=/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml

install_spot() { # install_spot <spot>
	case $1 in
	loader-menu-title)
		need "$1" boot/dragonfly/dloader.menu
		dloader_menu
		;;
	motd)
		need "$1" console/motd.template
		for _e in etc etc.hdd; do
			[ -d "$ROOT/$_e" ] || continue
			{
				cat "$OUTD/console/motd.template"
				[ -f "$ROOT/$_e/motd" ] && cat "$ROOT/$_e/motd"
			} > "$WORK/motd.$_e"
			cp "$WORK/motd.$_e" "$ROOT/$_e/motd"
			chmod 644 "$ROOT/$_e/motd"
		done
		;;
	login-issue)
		need "$1" console/gettytab.fragment console/issue
		for _e in etc etc.hdd; do
			[ -d "$ROOT/$_e" ] || continue
			gettytab_im "$ROOT/$_e/gettytab"
			put console/issue "/$_e/issue"
		done
		;;
	lightdm-background)
		need "$1" lightdm/greeter-1920x1080.png
		put lightdm/greeter-1920x1080.png "/usr/local/share/$SLUG/lightdm/greeter-1920x1080.png"
		;;
	lightdm-theme)
		need "$1" lightdm/lightdm-gtk-greeter.conf lightdm/greeter-gtk.css
		put lightdm/lightdm-gtk-greeter.conf /usr/local/etc/lightdm/lightdm-gtk-greeter.conf
		put lightdm/greeter-gtk.css "/usr/local/share/themes/$SLUG-greeter/gtk-3.0/gtk.css"
		;;
	xdm-logo)
		need "$1" "dm/pixmaps/$SLUG-color.xpm" "dm/pixmaps/$SLUG-8bpp.xpm" "dm/pixmaps/$SLUG-1bpp.xpm"
		for _x in color 8bpp 1bpp; do
			put "dm/pixmaps/$SLUG-$_x.xpm" "/usr/local/share/$SLUG/dm/pixmaps/$SLUG-$_x.xpm"
		done
		;;
	xdm-colours)
		need "$1" dm/xdm/Xresources dm/xdm/Xsetup_0
		put dm/xdm/Xresources /usr/local/etc/X11/xdm/Xresources
		put dm/xdm/Xsetup_0 /usr/local/etc/X11/xdm/Xsetup_0 755
		;;
	installer-header)
		need "$1" installer/header.png
		put installer/header.png "/usr/local/share/$SLUG/installer/header.png"
		;;
	installer-sidebar)
		need "$1" installer/sidebar.png
		put installer/sidebar.png "/usr/local/share/$SLUG/installer/sidebar.png"
		;;
	installer-palette)
		need "$1" xfce/gtk-colors.css
		put xfce/gtk-colors.css "/usr/local/share/$SLUG/xfce/gtk-colors.css"
		;;
	wallpapers)
		need "$1" wallpapers/wallpaper-1-1920x1080.png xfce/xfconf/xfce4-desktop.xml
		for _w in "$OUTD"/wallpapers/wallpaper-*.png; do
			put "wallpapers/${_w##*/}" "/usr/local/share/$SLUG/wallpapers/${_w##*/}"
		done
		put xfce/xfconf/xfce4-desktop.xml "$XFCONF/xfce4-desktop.xml"
		;;
	icon-distributor) icons logo ;;
	icon-menu) icons menu ;;
	icon-installer) icons installer ;;
	xfce-theme)
		need "$1" xfce/xfconf/xfce4-panel.xml xfce/xfconf/xsettings.xml xfce/xfwm4-themerc
		put xfce/xfconf/xfce4-panel.xml "$XFCONF/xfce4-panel.xml"
		put xfce/xfconf/xsettings.xml "$XFCONF/xsettings.xml"
		put xfce/xfwm4-themerc "/usr/local/share/themes/$NAME/xfwm4/themerc"
		;;
	identity-file)
		[ -s "$IDF" ] || die "spot identity-file: $IDF was not written"
		;;
	identity-line)
		# stamped in step 3 onto the greeter background and the wallpapers
		[ -f "$OUTD/lightdm/greeter-1920x1080.png" ] || die "spot identity-line: no greeter background was stamped"
		;;
	*)
		return 1
		;;
	esac
	return 0
}

awk -F '\t' '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
	!hdr { for (i = 1; i <= NF; i++) col[$i] = i; hdr = 1
		if (!("spot" in col) || !("dragonfly" in col) || !("rendered" in col)) { print "BAD"; exit 1 }
		next }
	{ print $col["spot"] "\t" $col["dragonfly"] }' "$ART/branding/spots.tsv" > "$WORK/spots" ||
	die "branding/spots.tsv has no spot, dragonfly or rendered column (they are read by their header names)"
: > "$WORK/installed-spots"
: > "$WORK/unsupported-spots"
_n=0
while IFS="$(printf '\t')" read -r _spot _cell; do
	case $_cell in
	n/a* | 'check:'* | - | '')
		printf '%s\t%s\n' "$_spot" "$_cell" >> "$WORK/unsupported-spots"
		continue
		;;
	esac
	install_spot "$_spot" ||
		die "spot $_spot is supported on DragonFly in branding/spots.tsv ($_cell), but this template has no way to install it"
	printf '%s\t%s\n' "$_spot" "$_cell" >> "$WORK/installed-spots"
	_n=$((_n + 1))
done < "$WORK/spots"
[ "$_n" -gt 0 ] || die "branding/spots.tsv marks no spot supported on DragonFly"

# 5. the wallpaper on every display output: the artwork's session helper
#    (xfce/session/<name>-wallpaper.sh) and its XDG autostart entry
#    (xfce/autostart/<name>-wallpaper.desktop, <name> the slug the artwork
#    was rendered for) are installed at fixed paths of the product:
#    the helper root-owned 0755 as /usr/local/share/<slug>/xfce/session/
#    <slug>-wallpaper.sh, the entry 0644 as /etc/xdg/autostart/
#    <slug>-wallpaper.desktop (in etc and etc.hdd: the live media and the
#    installed system), its Exec= line written here to name that helper (the
#    artwork's own Exec= is not used). An artwork without the entry (an
#    older pack) installs neither; an entry without its helper, two entries,
#    a name that is not a slug, or a link instead of a file stops the build.
WPN=''
for _f in "$OUTD"/xfce/autostart/*-wallpaper.desktop; do
	[ -e "$_f" ] || [ -L "$_f" ] || continue
	[ -z "$WPN" ] || die "the artwork has more than one xfce/autostart/*-wallpaper.desktop"
	WPN=${_f##*/}
	WPN=${WPN%-wallpaper.desktop}
done
if [ -n "$WPN" ]; then
	printf '%s\n' "$WPN" | grep -Eq '^[a-z0-9][a-z0-9-]*$' ||
		die "the artwork's wallpaper entry is not named <slug>-wallpaper.desktop: $WPN-wallpaper.desktop"
	printf '%s\n' "$SLUG" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || die "not a slug: $SLUG"
	WPD="xfce/autostart/$WPN-wallpaper.desktop"
	WPS="xfce/session/$WPN-wallpaper.sh"
	for _f in "$WPD" "$WPS"; do
		[ ! -L "$OUTD/$_f" ] || die "the artwork's $_f is a symbolic link, not a file"
	done
	[ -f "$OUTD/$WPD" ] || die "the artwork's $WPD is not a file"
	[ -f "$OUTD/$WPS" ] || die "the artwork has no $WPS for its $WPD"
	_helper="/usr/local/share/$SLUG/xfce/session/$SLUG-wallpaper.sh"
	grep -q '^Exec=' "$OUTD/$WPD" || die "the artwork's $WPD has no Exec= line"
	put "$WPS" "$_helper" 755
	chown root:wheel "$ROOT$_helper"
	EXECLINE="Exec=/bin/sh \"$_helper\"" awk '
		/^Exec=/ { if (!done) print ENVIRON["EXECLINE"]; done = 1; next }
		{ print }' "$OUTD/$WPD" > "$WORK/wallpaper.desktop"
	for _e in etc etc.hdd; do
		[ -d "$ROOT/$_e" ] || continue
		_ent="/$_e/xdg/autostart/$SLUG-wallpaper.desktop"
		mkdir -p "$ROOT/$_e/xdg/autostart"
		cp "$WORK/wallpaper.desktop" "$ROOT$_ent"
		chmod 644 "$ROOT$_ent"
		chown root:wheel "$ROOT$_ent"
	done
fi
printf '%s: %d branding spots installed from the %s (variant %s, %s)\n' "$PROG" "$_n" "$MODE" "$VARIANT" "$BASE"
