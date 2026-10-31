#!/bin/sh
#
# tools/post-customize.sh — the post-customize step of the DragonFly build.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# usage: tools/post-customize.sh ROOT RC_CONF_DIR RC_CONF_DIR2 ROOTSKELS \
#          GETTY CONSOLE REMOVE_ACCOUNT KEEP_ACCOUNT [RC_CONF_INSTALLED \
#          [SYSCTL_DIR]]
#
#   ROOT             the release root of the nrelease run (${ISOROOT})
#   RC_CONF_DIR      a directory of rc.conf(5) fragments (KEY="value" lines)
#   RC_CONF_DIR2     a second directory of fragments (the profile)
#   ROOTSKELS        the staged overlay: the /etc files of the product
#   GETTY            the tty whose getty is enabled (ttyd0)
#   CONSOLE          the console of the kernel (comconsole)
#   REMOVE_ACCOUNT   an account that is removed from the image, or - for none
#   KEEP_ACCOUNT     an account with uid 0 that is NOT locked on the live
#                    media (the installer account of the desktop ISO, which
#                    is the install path), or - for none
#   SYSCTL_DIR       a directory of sysctl.conf(5) fragments (name=value
#                    lines), or - for none: appended, in a block marked
#                    per fragment, to /etc/sysctl.conf of the live media
#                    AND of the installed system (etc.hdd); the stock
#                    lines stay, and a name already there is replaced
#   RC_CONF_INSTALLED a directory of fragments for the INSTALLED system
#                    only (etc.hdd/rc.conf), or - for none. They reach the
#                    rc.conf of the live tree too when the live tree is
#                    itself the system (no installer account left in it,
#                    the appliance image). The desktop puts LightDM here:
#                    the live media has no greeter, so the stock installer
#                    keeps ttyv0 and ttyd0.
#
# The step runs in the release root between the release of the media and
# the media that are built from the release root. It does what the release
# tooling of DragonFly cannot know about:
#
#   - it merges the rc.conf(5) variables of the overlay into the rc.conf
#     of the release root and into the rc.conf of the installed system:
#     the overlay owns the variables, the release tooling owns the files,
#   - it enables the getty of the serial console and points the console
#     of the kernel at it, so that the boot test of the CI sees a login
#     prompt on the serial line, in the live media and in the tree of
#     the installer,
#   - it locks every account with uid 0: the stock release leaves root,
#     toor and operator with an EMPTY password, and customizeiso creates
#     an "installer" account with uid 0 and an empty password (pw useradd
#     installer -o -u 0; chpass -p ''),
#   - it removes the installer account when the profile does not want it,
#   - it mirrors the /etc files of the overlay into /etc.hdd: the
#     installer copies <dir>.hdd in place of <dir>, and customizeiso
#     snapshots /etc into /etc.hdd BEFORE the rootskels are applied, so
#     the /etc of the overlay would never reach the installed system. The
#     fstab of the live media (which mounts /etc, /var, /tmp and /root on
#     a tmpfs) never reaches the installed system either,
#   - it does NOT create the sentinel of the first boot (/firstboot):
#     the mkimg target of the release tooling creates it in the disk
#     image itself, and the release root also becomes the read-only ISO,
#     where the stock /etc/rc fails to remove it ("rm: /firstboot:
#     Read-only file system").
#
# The files are parsed, never evaluated: the fragments are read line by
# line, and only the KEY="value" lines of rc.conf(5) are used.

set -eu

PROG=$(basename -- "$0")

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG ROOT RC_CONF_DIR RC_CONF_DIR2 ROOTSKELS GETTY CONSOLE REMOVE_ACCOUNT KEEP_ACCOUNT [RC_CONF_INSTALLED [SYSCTL_DIR]]" >&2
	exit 2
}

[ $# -ge 7 ] && [ $# -le 10 ] || usage
ROOT=$1
RC1=$2
RC2=${3:-}
ROOTSKELS=${4:-}
GETTY=${5:-}
CONSOLE=${6:-}
REMOVE=${7:--}
KEEP=${8:--}
RCI=${9:--}
SYSCTLD=${10:--}

[ -d "$ROOT" ] || die "no such release root: $ROOT"

# GETTY goes into grep patterns and sed scripts: it is checked before
# anything is changed. The names are the ones of the devices of
# DragonFly (ttyd0 the first serial port, ttyv0 the first virtual
# console); anything else is refused.
if [ -n "$GETTY" ] && ! printf '%s\n' "$GETTY" | grep -Eq '^tty[a-zA-Z]*[0-9]+$'; then
	die "GETTY must be a tty name such as ttyd0 (the first serial port) or ttyv0 (the first virtual console), matching ^tty[a-zA-Z]*[0-9]+\$ (got: $GETTY); nothing was changed"
fi

# --------------------------------------------------------------------------
# the helpers
# --------------------------------------------------------------------------

# merge_rc_conf <rc.conf> <fragment dir>... — the variables of the
# fragments replace the variables of the same name and are appended when
# they are new
merge_rc_conf() {
	_mc_conf=$1
	shift
	[ -f "$_mc_conf" ] || : > "$_mc_conf"
	for _mc_dir in "$@"; do
		[ -d "$_mc_dir" ] || continue
		for _mc_f in "$_mc_dir"/*; do
			[ -f "$_mc_f" ] || continue
			while IFS= read -r _mc_line || [ -n "$_mc_line" ]; do
				case $_mc_line in
				'' | '#'*) continue ;;
				esac
				case $_mc_line in
				[A-Za-z_]*=*) ;;
				*) continue ;;
				esac
				_mc_key=${_mc_line%%=*}
				if grep -q "^$_mc_key=" "$_mc_conf" 2>/dev/null; then
					awk -v k="$_mc_key" -v v="$_mc_line" '
						index($0, k "=") == 1 { print v; next }
						{ print }' "$_mc_conf" > "$_mc_conf.new"
					cat "$_mc_conf.new" > "$_mc_conf"
					rm -f "$_mc_conf.new"
				else
					printf '%s\n' "$_mc_line" >> "$_mc_conf"
				fi
			done < "$_mc_f"
		done
	done
}

# enable_getty <ttys> <tty> <keep|drop> — the getty of the tty is
# switched on. ONLY the status field of the line changes: the getty, the
# terminal type and the flags after the status stay as the release
# tooling wrote them. With drop, the ifconsole flag is removed from the
# line as well: that is the ttys of the installed system (etc.hdd), whose
# /boot/loader.conf the installer rewrites without the console line, so
# a getty that waits for the console to be the serial line never runs
# there. The live media keep ifconsole (keep).
enable_getty() {
	_eg_ttys=$1
	_eg_tty=$2
	_eg_ifc=${3:-keep}
	[ -n "$_eg_tty" ] || return 0
	[ -f "$_eg_ttys" ] || return 0
	if grep -q "^$_eg_tty[[:space:]]" "$_eg_ttys"; then
		# the sed expressions: the status is always switched on; the
		# ifconsole flag is removed only in drop mode
		set -- -e "s|^([[:space:]]*$_eg_tty[[:space:]]+\"[^\"]*\"[[:space:]]+[^[:space:]]+[[:space:]]+)[^[:space:]]+|\\1on|"
		if [ "$_eg_ifc" = drop ]; then
			set -- "$@" -e "/^$_eg_tty[[:space:]]/ s/[[:space:]]*ifconsole//g"
		fi
		sed -E "$@" "$_eg_ttys" > "$_eg_ttys.new"
		cat "$_eg_ttys.new" > "$_eg_ttys"
		rm -f "$_eg_ttys.new"
	else
		# the stock getty of DragonFly lives in /usr/libexec
		printf '%s\t"/usr/libexec/getty std.9600"\tdialup\ton\n' "$_eg_tty" >> "$_eg_ttys"
	fi
}

# set_console <loader.conf> <console> — the kernel writes on the console.
# The loader of DragonFly reads /boot/loader.conf, and the file of the
# release tooling is never replaced: the line of the console is added to
# it (or the console line of the file is changed).
set_console() {
	_sc_file=$1
	_sc_value=$2
	[ -n "$_sc_value" ] || return 0
	mkdir -p "$(dirname -- "$_sc_file")"
	if [ -f "$_sc_file" ] && grep -q '^console=' "$_sc_file" 2>/dev/null; then
		sed -E "s|^console=.*|console=\"$_sc_value\"|" "$_sc_file" > "$_sc_file.new"
		cat "$_sc_file.new" > "$_sc_file"
		rm -f "$_sc_file.new"
	else
		printf 'console="%s"\n' "$_sc_value" >> "$_sc_file"
	fi
}

# lock_uid0 <master.passwd> [keep] — every account with uid 0 is locked:
# the password field becomes the star, which no crypt(3) hash starts
# with. The account named in <keep> is left alone. The file is written
# with the mode of a password database (0600).
lock_uid0() {
	_lu_file=$1
	_lu_keep=${2:--}
	[ -f "$_lu_file" ] || return 0
	(
		umask 077
		awk -F: -v keep="$_lu_keep" 'BEGIN { OFS = ":" } $3 == 0 && $1 != keep { $2 = "*" } { print }' \
			"$_lu_file" > "$_lu_file.new"
	)
	mv "$_lu_file.new" "$_lu_file"
}

# remove_account <master.passwd> <passwd> <name> — the account is gone
# from the password database and from the passwd file
remove_account() {
	_ra_mpw=$1
	_ra_pw=$2
	_ra_name=$3
	[ -n "$_ra_name" ] || return 0
	[ "$_ra_name" = '-' ] && return 0
	for _ra_file in "$_ra_mpw" "$_ra_pw"; do
		[ -f "$_ra_file" ] || continue
		case $_ra_file in
		*master.passwd) _ra_umask=077 ;;
		*) _ra_umask=022 ;;
		esac
		(
			umask "$_ra_umask"
			awk -F: -v n="$_ra_name" 'BEGIN { OFS = ":" } $1 != n { print }' \
				"$_ra_file" > "$_ra_file.new"
		)
		mv "$_ra_file.new" "$_ra_file"
	done
}

# sysctl_fragments <fragment dir> — print the paths of the sysctl.conf(5)
# fragments, one per line, in the order they are checked and merged: the
# order of the directory listing, a subdirectory walked in place. The
# build stages base before profile (1-base/, 2-profile/), so the profile
# wins for a name both set. check_sysctl and merge_sysctl both use it.
sysctl_fragments() {
	[ -d "$1" ] || return 0
	for _sf_e in "$1"/*; do
		if [ -d "$_sf_e" ]; then
			( sysctl_fragments "$_sf_e" )
		elif [ -f "$_sf_e" ]; then
			printf '%s\n' "$_sf_e"
		fi
	done
}

# check_sysctl <fragment dir> — every line of every fragment is a comment,
# empty, or exactly name=value: a sysctl name, '=', and a value with no
# space and no backslash (a sysctl value never needs one, and a backslash
# could be read as an escape on the way into the file). Anything else
# stops the step before any file is changed.
check_sysctl() {
	_cs_list=$(sysctl_fragments "$1")
	[ -n "$_cs_list" ] || return 0
	while IFS= read -r _cs_f; do
		while IFS= read -r _cs_line || [ -n "$_cs_line" ]; do
			case $_cs_line in
			'' | '#'*) continue ;;
			esac
			printf '%s\n' "$_cs_line" | grep -Eq '^[a-z][a-z0-9_.]*=[^[:space:]\\]+$' ||
				die "not a sysctl.conf(5) line in $_cs_f: $_cs_line (expected name=value, e.g. kern.evdev.rcpt_mask=6; fix or remove the line)"
		done < "$_cs_f"
	done <<EOF_CS
$_cs_list
EOF_CS
}

# merge_sysctl <sysctl.conf> <fragment dir> — the name=value lines of the
# fragments (checked first by check_sysctl) are added to the file: a name
# that is already set (not commented out) gets the value of the fragment
# in place; a new name is appended after a marker line that names the
# fragment. Run twice, it changes nothing more. The name and the line
# reach awk through the environment (ENVIRON), never through awk -v,
# which would read backslash escapes in them.
merge_sysctl() {
	_ms_conf=$1
	_ms_list=$(sysctl_fragments "$2")
	[ -n "$_ms_list" ] || return 0
	[ -f "$_ms_conf" ] || : > "$_ms_conf"
	while IFS= read -r _ms_f; do
		_ms_mark="# from the overlay: sysctl.conf.d/${_ms_f##*/}"
		while IFS= read -r _ms_line || [ -n "$_ms_line" ]; do
			case $_ms_line in
			'' | '#'*) continue ;;
			esac
			_ms_key=${_ms_line%%=*}
			if MS_KEY=$_ms_key awk 'index($0, ENVIRON["MS_KEY"] "=") == 1 { f = 1 } END { exit !f }' "$_ms_conf"; then
				MS_KEY=$_ms_key MS_LINE=$_ms_line awk '
					index($0, ENVIRON["MS_KEY"] "=") == 1 { print ENVIRON["MS_LINE"]; next }
					{ print }' "$_ms_conf" > "$_ms_conf.new"
				cat "$_ms_conf.new" > "$_ms_conf"
				rm -f "$_ms_conf.new"
			else
				grep -qxF "$_ms_mark" "$_ms_conf" || printf '%s\n' "$_ms_mark" >> "$_ms_conf"
				printf '%s\n' "$_ms_line" >> "$_ms_conf"
			fi
		done < "$_ms_f"
	done <<EOF_MS
$_ms_list
EOF_MS
}

# mirror_etc_hdd <root> <rootskels> — the /etc files of the overlay are
# mirrored into the tree of the installer. The release tooling snapshots
# /etc into /etc.hdd BEFORE the rootskels are applied, so the /etc of the
# product would never reach the installed system without this. The fstab
# of the live media is removed from the tree: it mounts /etc, /var, /tmp
# and /root on a tmpfs and belongs to the live media alone.
mirror_etc_hdd() {
	_mh_root=$1
	_mh_sk=$2
	[ -d "$_mh_root" ] || return 0
	mkdir -p "$_mh_root/etc.hdd"
	rm -f "$_mh_root/etc.hdd/fstab"
	[ -d "$_mh_sk/etc" ] || return 0
	( cd "$_mh_sk/etc" && find . -type f ) | while IFS= read -r _mh_rel; do
		_mh_rel=${_mh_rel#./}
		[ -n "$_mh_rel" ] || continue
		_mh_dst="$_mh_root/etc.hdd/$_mh_rel"
		mkdir -p "$(dirname -- "$_mh_dst")"
		cp "$_mh_sk/etc/$_mh_rel" "$_mh_dst"
	done
}

# --------------------------------------------------------------------------
# the step
# --------------------------------------------------------------------------

log "post-customize: the release root $ROOT"

# the sysctl fragments are checked before anything is changed
if [ "$SYSCTLD" != - ]; then
	check_sysctl "$SYSCTLD"
fi

# the /etc of the product reaches the image AND the installed system
mirror_etc_hdd "$ROOT" "$ROOTSKELS"

# the variables of the overlay reach the rc.conf of the live media and
# the rc.conf of the installed system (the installer copies etc.hdd in
# place of etc)
merge_rc_conf "$ROOT/etc/rc.conf" "$RC1" $RC2
merge_rc_conf "$ROOT/etc.hdd/rc.conf" "$RC1" $RC2

# the sysctl lines of the overlay reach the sysctl.conf of the live media
# and of the installed system; the stock file of each stays and is
# appended to (an overlay etc/sysctl.conf would replace it)
if [ "$SYSCTLD" != - ]; then
	merge_sysctl "$ROOT/etc/sysctl.conf" "$SYSCTLD"
	merge_sysctl "$ROOT/etc.hdd/sysctl.conf" "$SYSCTLD"
fi

# the serial console: the getty of the tty is on and the kernel writes
# on the console. The tree of the installer has a ttys of its own (the
# installer copies etc.hdd in place of etc), so the getty of the serial
# console is switched on there as well, and only there the ifconsole
# flag is dropped (the installer writes a loader.conf without the
# console line).
enable_getty "$ROOT/etc/ttys" "$GETTY" keep
if [ -f "$ROOT/etc.hdd/ttys" ]; then
	enable_getty "$ROOT/etc.hdd/ttys" "$GETTY" drop
fi
set_console "$ROOT/boot/loader.conf" "$CONSOLE"

# the accounts with uid 0: the installer account of the desktop ISO is
# the install path and keeps its empty password there
remove_account "$ROOT/etc/master.passwd" "$ROOT/etc/passwd" "$REMOVE"
lock_uid0 "$ROOT/etc/master.passwd" "$KEEP"
# the installed system has no account that can be typed into
lock_uid0 "$ROOT/etc.hdd/master.passwd"

# the fragments of the installed system only: always into etc.hdd, and
# into the live tree only when it carries no installer account (then the
# image is booted as the system itself, like the appliance image)
# This runs after REMOVE_ACCOUNT: an appliance image has lost its installer
# account by now, so it also gets the installed-only fragments (test L2a).
if [ "$RCI" != - ]; then
	merge_rc_conf "$ROOT/etc.hdd/rc.conf" "$RCI"
	if [ -f "$ROOT/etc/master.passwd" ] && ! grep -q '^installer:' "$ROOT/etc/master.passwd"; then
		merge_rc_conf "$ROOT/etc/rc.conf" "$RCI"
	fi
fi

log 'post-customize: done'
exit 0
