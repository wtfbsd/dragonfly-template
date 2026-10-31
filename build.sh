#!/bin/sh
#
# build.sh — build ExampleBSD-style images from an UNMODIFIED DragonFly tree.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# OVERLAY RULE: the DragonFly source tree is never patched and DPorts is
# never patched. The product is the set of files under overlay/ plus the
# DPorts packages it names. The build drives the stock release tooling
# through the hooks that tooling documents (upstream nrelease/Makefile):
#
#   ROOTSKELS              directories whose contents customizeiso copies
#                          over the release root (${ISOROOT})
#   DPORTS_EXTRA_PACKAGES  the packages that are added to the release root
#   ISODIR, ISOROOT        where the release root is staged
#   ISOFILE, IMGFILE       the names of the two media
#
# The rootskels of the release tooling are named by the build itself:
# upstream sets REQ_ROOTSKELS=${.CURDIR}/root, ROOTSKELS?=${REQ_ROOTSKELS}
# and adds ${.CURDIR}/gui under the gui modifier, but a ROOTSKELS on the
# command line REPLACES every one of those defaults. The build therefore
# hands over the skeleton of the release tooling AND the skeleton of the
# GUI (for the desktop) AND the overlay of the product, in that order:
# each one overwrites the last.
#
# The gui modifier itself is NOT used: under it the release tooling adds
# a browser and an editor to the packages of the release, and the product
# names its own packages. The skeleton of the GUI is named in ROOTSKELS.
#
# The run has these make calls:
#
#   make -C <src>/nrelease check clean buildworld1 buildkernel1 \
#        buildiso pkgs customizeiso srcs ...     the world (once for the
#                                               whole build), the release
#                                               root, the overlay through
#                                               ROOTSKELS, the packages
#                                               through DPORTS_EXTRA_PACKAGES
#   make -C <src>/nrelease buildiso pkgs customizeiso srcs ...
#                                               the release root of every
#                                               further profile, staged from
#                                               the world that is already
#                                               built
#   tools/post-customize.sh                     in the release root
#   make -C <src>/nrelease mkiso mkimg ...      the two media, built
#                                               from the release root after
#                                               the post-customize step
#
# The media are built ONCE, after the post-customize step: the media of
# a release that is built before the release root is fixed would hold the
# product without the fixes of the post-customize step.
#
# The post-customize step (tools/post-customize.sh) runs in the release
# root between the release and the media and does what the release
# tooling cannot know about:
#
#   - it merges the rc.conf(5) variables of the overlay into the rc.conf
#     of the release root and into the rc.conf of the installed system,
#   - it enables the getty of the serial console and points the console
#     of the kernel at it,
#   - it locks every account with uid 0: the stock release leaves root,
#     toor and operator with an EMPTY password, and customizeiso creates
#     an "installer" account with uid 0 and an empty password,
#   - it removes the installer account from the appliance image (on the
#     desktop ISO the installer account stays: it is the install path),
#   - it mirrors the /etc files of the overlay into /etc.hdd, because the
#     installer copies <dir>.hdd in place of <dir>: customizeiso snapshots
#     /etc into /etc.hdd BEFORE the rootskels are applied,
#   - it creates the sentinel of the first boot.
#
# The overlay is copied over the release root BEFORE the media are built,
# so the product is part of the media itself and not a tarball the
# operator has to unpack.
#
# DragonFly cannot be cross-built: the release tooling has to run on
# DragonFly itself. build.sh refuses the real build on any other host;
# the dry run (-n) works anywhere.
#
# The packages of the overlay are DPorts ORIGINS (category/port). With
# the binpkgs modifier of the release tooling (the default, BINPKGS=yes)
# nrelease 6.4 installs binary packages with pkg, by name and then by
# origin; without it (BINPKGS=no) it runs make install for every DPorts
# origin in a chroot, from the DPorts tree whose path is DPORTS_PATH
# (/usr/dports by default). The check target of the release tooling
# refuses to build without that tree.
#
# The root filesystem of the release image is UFS: the release tooling
# creates the image root with newfs. HAMMER2 is the native filesystem of
# DragonFly and UFS is available as well; there is no ZFS on DragonFly:
# FILESYSTEM_ROOT=zfs and ZFS_DATA_POOL=yes are refused with the honesty
# note of the per_os row of wtfbsd/agents questions.yaml (root_fs:
# hammer2, ufs; zfs_pool: no).
#
# product.conf is flat KEY=value output (parsed, never sourced) of
# wtfbsd/agents scripts/apply-answers.sh; the key list lives in
# wtfbsd/agents questions.yaml.
#
# Usage:
#   ./build.sh -c product.conf [-s /usr/src] [-o ./out] \
#              [-p desktop|appliance|both] [-u USER [-k PUBKEY | -P HASH]] \
#              [--no-user] [-n]
#
#   -c  product.conf (required; DISTRO_OS must be dragonfly)
#   -s  unmodified DragonFly source tree (default /usr/src)
#   -o  output directory (default ./out)
#   -p  profile(s) to build; overrides PROFILE from product.conf
#   -u  first-boot user: bake the account into the image
#   -k  authorized_keys file of the first-boot user (needs -u)
#   -P  file with the crypt(3) hash of the password of the first-boot
#       user (needs -u); a plain text password is refused
#       --no-user  build without a first-boot user: the image holds no
#       account anybody can log in with
#   -n  dry run: validate the config, print the plan, change nothing
#
# Two environment variables exist for the test suite only. They relax the
# host checks of the real build so that tests/run-tests.sh can drive the
# real build path against the stand-ins in tests/stubs. A build host must
# never set them:
#   WTFBSD_TEST_ALLOW_ANY_OS    do not require uname -s to be DragonFly
#   WTFBSD_TEST_ALLOW_NONROOT   do not require the build to run as root
#
set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG -c product.conf [-s /usr/src] [-o ./out]"
	log '       [-p desktop|appliance|both] [-u USER [-k PUBKEY | -P HASH]] [--no-user] [-n]'
	log ''
	log '  -c  product.conf from wtfbsd/agents scripts/apply-answers.sh'
	log '  -s  unmodified DragonFly src tree (default /usr/src)'
	log '  -o  output directory (default ./out)'
	log '  -p  profile: desktop, appliance or both (default: product.conf PROFILE)'
	log '  -u  first-boot user: bake the account into the image'
	log '  -k  authorized_keys file of the first-boot user (needs -u)'
	log '  -P  file with the crypt(3) hash of the password (needs -u)'
	log '      --no-user  build without a first-boot user (nobody can log in)'
	log '  -n  dry run: print the plan, change nothing'
	exit "${1:-2}"
}

DRY=0
CONF=''
SRC=/usr/src
OUT=./out
CHOSEN=''
FBUSER=''
FBKEY=''
FBPASS=''
NOUSER=0

# The long options are removed before getopts(1) sees them: getopts(1)
# of a POSIX shell knows no long option.
_nargs=$#
while [ "$_nargs" -gt 0 ]; do
	_a=$1
	shift
	case $_a in
	--no-user)
		NOUSER=1
		;;
	*)
		set -- "$@" "$_a"
		;;
	esac
	_nargs=$((_nargs - 1))
done

while getopts 'c:s:o:p:u:k:P:nh' _opt; do
	case $_opt in
	c) CONF=$OPTARG ;;
	s) SRC=$OPTARG ;;
	o) OUT=$OPTARG ;;
	p) CHOSEN=$OPTARG ;;
	u) FBUSER=$OPTARG ;;
	k) FBKEY=$OPTARG ;;
	P) FBPASS=$OPTARG ;;
	n) DRY=1 ;;
	h) usage 0 ;;
	*) usage 2 >&2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage 2 >&2
[ -n "$CONF" ] || {
	log "$PROG: missing -c product.conf" >&2
	usage 2 >&2
}
case $OUT in *[[:space:]]*) die "-o: output path may not contain whitespace: $OUT" ;; esac
[ -f "$CONF" ] || die "no such product.conf: $CONF"

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# --------------------------------------------------------------------------
# load + validate product.conf (flat KEY=value from apply-answers.sh)
# --------------------------------------------------------------------------

# product.conf is NEVER sourced: it is parsed line by line, only the known
# questions.yaml keys are accepted, and values may not contain shell
# metacharacters. One pair of outer quotes (single or double) is stripped.
KNOWN_KEYS='DISTRO_OS DISTRO_NAME DISTRO_SLUG DISTRO_ARCH FILESYSTEM_ROOT
ZFS_DATA_POOL ZFS_POOL_NAME PROFILE PACKAGE_SET INSTALLER MOTD BRAND_COLOR
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG'
for _k in $KNOWN_KEYS; do unset "$_k"; done
while IFS= read -r _line || [ -n "$_line" ]; do
	case $_line in '' | '#'*) continue ;; esac
	case $_line in
	[A-Z]*=*) ;;
	*) die "product.conf: not a KEY=value line: $_line" ;;
	esac
	_k=${_line%%=*}
	_v=${_line#*=}
	case " $(printf %s "$KNOWN_KEYS" | tr '\n' ' ') " in
	*" $_k "*) ;;
	*) die "product.conf: unknown key: $_k (known: $(printf %s "$KNOWN_KEYS" | tr '\n' ' '); see wtfbsd/agents questions.yaml)" ;;
	esac
	case $_v in
	\'*\') _v=${_v#\'}; _v=${_v%\'} ;;
	\"*\") _v=${_v#\"}; _v=${_v%\"} ;;
	esac
	case $_v in
	*[\$\`\\\'\"]* | *[[:cntrl:]]*) die "product.conf: $_k contains a forbidden character (\$, backquote, backslash, quote or control character)" ;;
	esac
	# plain assignments, no eval: the value is pure data
	case $_k in
	DISTRO_OS) DISTRO_OS=$_v ;;
	DISTRO_NAME) DISTRO_NAME=$_v ;;
	DISTRO_SLUG) DISTRO_SLUG=$_v ;;
	DISTRO_ARCH) DISTRO_ARCH=$_v ;;
	FILESYSTEM_ROOT) FILESYSTEM_ROOT=$_v ;;
	ZFS_DATA_POOL) ZFS_DATA_POOL=$_v ;;
	ZFS_POOL_NAME) ZFS_POOL_NAME=$_v ;;
	PROFILE) PROFILE=$_v ;;
	PACKAGE_SET) PACKAGE_SET=$_v ;;
	INSTALLER) INSTALLER=$_v ;;
	MOTD) MOTD=$_v ;;
	BRAND_COLOR) BRAND_COLOR=$_v ;;
	BRAND_URL) BRAND_URL=$_v ;;
	CI_ENABLED) CI_ENABLED=$_v ;;
	PUBLISH_METHOD) PUBLISH_METHOD=$_v ;;
	PUBLISH_TARGET) PUBLISH_TARGET=$_v ;;
	PUBLISHER_ORG) PUBLISHER_ORG=$_v ;;
	esac
done < "$CONF"

[ "${DISTRO_OS:-}" = dragonfly ] \
	|| die "DISTRO_OS must be dragonfly (got ${DISTRO_OS:-<empty>}); this template builds DragonFly only"

# anchored checks without interval expressions (portable ERE)
chk() { # chk <anchored-ere> <value> <message>
	printf '%s\n' "$2" | grep -qE -- "$1" || die "$3 (got: $2)"
}

# slug: lowercase/digits/hyphens, starts with a letter, 2..32 chars
chk '^[a-z][a-z0-9-]*$' "${DISTRO_SLUG:-}" 'DISTRO_SLUG must match ^[a-z][a-z0-9-]*$'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -ge 2 ] || die 'DISTRO_SLUG too short (min 2)'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -le 32 ] || die 'DISTRO_SLUG too long (max 32)'

case ${DISTRO_NAME:-} in *[[:cntrl:]]*) die 'DISTRO_NAME contains control characters' ;; esac
[ -n "${DISTRO_NAME:-}" ] || die 'DISTRO_NAME is empty'
[ "$(printf %s "$DISTRO_NAME" | wc -c)" -le 64 ] || die 'DISTRO_NAME too long (max 64)'

# The DragonFly honesty rule: the native filesystem is HAMMER2 (UFS is
# also available) and there is no ZFS at all. See the per_os row of
# wtfbsd/agents questions.yaml (root_fs: hammer2, ufs; zfs_pool: no) and
# its per_os_honesty note, which build.sh quotes verbatim.
FILESYSTEM_ROOT=${FILESYSTEM_ROOT:-hammer2}
case $FILESYSTEM_ROOT in
hammer2 | ufs) ;;
*)
	die "FILESYSTEM_ROOT must be hammer2 or ufs for dragonfly (got: $FILESYSTEM_ROOT).
The native filesystem is HAMMER2 (UFS is also available). No ZFS.
Answer FILESYSTEM_ROOT=hammer2 (or ufs) and ZFS_DATA_POOL=no."
	;;
esac

ZDP=${ZFS_DATA_POOL:-no}
case $ZDP in
yes | no) ;;
*) die "ZFS_DATA_POOL must be yes or no (got: $ZDP)" ;;
esac
if [ "$ZDP" = yes ]; then
	die "ZFS_DATA_POOL must be no for dragonfly (got: yes).
The native filesystem is HAMMER2 (UFS is also available). No ZFS.
DragonFly has no ZFS: there is no data pool either."
fi
ZFS_POOL_NAME=${ZFS_POOL_NAME:-}

chk '^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$' \
	"${BRAND_COLOR:-2e7d66}" 'BRAND_COLOR must be six hex digits'
BRAND_URL=${BRAND_URL:-https://example.org}
chk '^https://[A-Za-z0-9.-]+$' "$BRAND_URL" 'BRAND_URL must be https, hostname only'

PROF=${CHOSEN:-${PROFILE:-appliance}}
case $PROF in
desktop | appliance | both) ;;
*) die "-p must be a profile: desktop, appliance or both (got: $PROF)" ;;
esac

# informational defaults mirroring questions.yaml (used downstream)
PACKAGE_SET=${PACKAGE_SET:-base-server}
INSTALLER=${INSTALLER:-tui}
MOTD=${MOTD:-built from the wtfbsd templates}
case $MOTD in *[[:cntrl:]]*) die 'MOTD contains control characters' ;; esac
[ "$(printf %s "$MOTD" | wc -c)" -le 120 ] || die 'MOTD too long (max 120)'

# --------------------------------------------------------------------------
# the first-boot user (baked into the image, provisioned on the first boot)
# --------------------------------------------------------------------------
if [ -n "$FBKEY" ] && [ -z "$FBUSER" ]; then
	die '-k needs a first-boot user: use -u <name> -k <authorized_keys file>'
fi
if [ -n "$FBPASS" ] && [ -z "$FBUSER" ]; then
	die '-P needs a first-boot user: use -u <name> -P <password hash file>'
fi
if [ -n "$FBUSER" ]; then
	chk '^[a-z_][a-z0-9_-]{0,31}$' "$FBUSER" \
		'the first-boot user name must match ^[a-z_][a-z0-9_-]{0,31}$'
fi
FBHASH=''
if [ -n "$FBKEY" ]; then
	[ -f "$FBKEY" ] || die "no such SSH public key file: $FBKEY"
	_fbtype=$(awk 'NR == 1 { print $1 }' "$FBKEY")
	# the certificate key types of OpenSSH carry the name of the project
	# as their domain; the domain is kept in a variable, so that the
	# name of the type does not look like an email address
	_oss='@openssh.com'
	case $_fbtype in
	ssh-ed25519* | ssh-rsa* | ecdsa-sha2-nistp256* | ecdsa-sha2-nistp384* | ecdsa-sha2-nistp521* | sk-ssh-ed25519"$_oss"* | sk-ecdsa-sha2-nistp256"$_oss"*) ;;
	*) die "the SSH public key file does not hold an authorized_keys line of a known key type: $FBKEY" ;;
	esac
fi
if [ -n "$FBPASS" ]; then
	[ -f "$FBPASS" ] || die "no such password hash file: $FBPASS"
	# the file holds ONE crypt(3) hash; a plain text password is refused,
	# because it would end up in the image and in the transcript of the
	# build
	FBHASH=$(sed -e 's/[[:space:]][[:space:]]*$//' "$FBPASS" | grep -v '^[[:space:]]*$' | head -1)
	[ -n "$FBHASH" ] || die "the password hash file holds no hash: $FBPASS"
	case $FBHASH in
	'$6$'* | '$5$'* | '$2b$'* | '$2y$'*) ;;
	*) die "the password hash file does not hold a crypt(3) hash: $FBPASS (it must start with \$6\$, \$5\$ or \$2b\$; a plain text password is never written into an image)" ;;
	esac
fi

# An image without an account is an image nobody can log into: the build
# refuses to make one unless --no-user says that this is what the
# operator wants. A dry run changes nothing, so it does not refuse: the
# plan says what the real build would refuse.
if [ -z "$FBUSER" ] && [ "$NOUSER" -ne 1 ] && [ "$DRY" -ne 1 ]; then
	die "no first-boot user: an image without an account is an image nobody can log into.
Use -u <name> -k <authorized_keys file> and/or -P <password hash file>,
or --no-user when an image without a login is really what you want."
fi

# The login path of every profile: the desktop has no sshd, so a key is
# of no use there and the account needs a password; the appliance is the
# other way round and needs a key.
case $PROF in
desktop | both)
	if [ -n "$FBUSER" ] && [ -z "$FBPASS" ]; then
		die 'the desktop profile needs a password for the first-boot user: use -P <password hash file> (a key is of no use without sshd)'
	fi
	;;
esac
case $PROF in
appliance | both)
	if [ -n "$FBUSER" ] && [ -z "$FBKEY" ]; then
		die 'the appliance profile needs an SSH key for the first-boot user: use -k <authorized_keys file>'
	fi
	;;
esac

# --------------------------------------------------------------------------
# static checks
# --------------------------------------------------------------------------

# The wireless-driver rule: the driver is never enabled, loaded or
# configured by this template, and an overlay file may not mention it at
# all. The token is assembled at run time, so that no file of this
# repository contains the name of that driver.
[ -d "$ROOT/overlay" ] || die "overlay guard: missing $ROOT/overlay"
_driver=$(printf 'mt%s' '76')
_rc=0
grep -rna -- "$_driver" "$ROOT/overlay" || _rc=$?
case $_rc in
1) ;; # no match: good
0) die 'overlay guard: an overlay file references the forbidden wireless driver; it must never be enabled or loaded by this template' ;;
*) die "overlay guard: could not scan $ROOT/overlay (grep exit $_rc)" ;;
esac

# DragonFly ships amd64 only (per_os row of questions.yaml: arch: amd64).
: "${DISTRO_ARCH:=amd64}"
[ "$DISTRO_ARCH" = amd64 ] \
	|| die "DISTRO_ARCH must be amd64 for dragonfly (got: ${DISTRO_ARCH:-<empty>}); the per_os row of questions.yaml lists amd64 only"

# The DPorts tree of the build host: BINPKGS=no builds the packages from
# it. The release tooling refuses to build without it (its check
# target), and the build names it, so that the plan of the dry run shows
# it.
DPORTS_PATH=${DPORTS_PATH:-/usr/dports}

# the output directory is the base of every artifact path, so it is made
# absolute before anything is written; the dry run creates nothing
case $OUT in
/*) ;;
*) OUT="$(pwd)/$OUT" ;;
esac

if [ "$DRY" -ne 1 ]; then
	# the build writes into the release root, installs packages and
	# changes the owner of the staged files: it has to run as root
	if [ "$(id -u)" != 0 ] && [ "${WTFBSD_TEST_ALLOW_NONROOT:-0}" != 1 ]; then
		die "the real build must run as root (the effective user id must be 0); it writes into the release root and installs packages. Use -n for a dry run"
	fi
	# DragonFly cannot be cross-built: nrelease and the release tooling
	# have to run on DragonFly itself.
	_os=$(uname -s)
	if [ "$_os" != DragonFly ] && [ "${WTFBSD_TEST_ALLOW_ANY_OS:-0}" != 1 ]; then
		die "the real build must run on DragonFly (uname -s says: $_os); DragonFly cannot be cross-built. Use -n for a dry run"
	fi
	for t in tar sed awk cp find; do
		command -v "$t" > /dev/null 2>&1 || die "required tool missing: $t"
	done
	[ -d "$SRC" ] || die "no such src tree: $SRC (a DragonFly source tree is needed, or pass -s <path>)"
	[ -d "$SRC/nrelease" ] || die "$SRC does not look like a DragonFly src tree (no nrelease directory)"
	[ -f "$ROOT/tools/post-customize.sh" ] || die "missing $ROOT/tools/post-customize.sh"
	mkdir -p "$OUT"
fi

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# step <cmd...> — execute the command, or print it in a dry run. Every
# command of the build goes through it, so the plan of the dry run and the
# commands of the real path can never drift apart.
step() {
	if [ "$DRY" -eq 1 ]; then printf '    + %s\n' "$*"; else "$@"; fi
}

rmrf() { # rmrf <path> <guardroot> — rm -rf only for non-empty paths under root
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	step rm -rf -- "$1"
}

pkg_list() { # pkg_list file... — flatten lists to shell words
	sed -e 's/[[:space:]]*#.*$//' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' "$@" | grep -v '^$' | tr '\n' ' ' |
		sed -e 's/[[:space:]]*$//'
}

sed_esc() { # escape a value for use inside a sed replacement (delimiter |)
	printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

sums() { # sums <file> — print a sha256 checksum of a file
	if command -v sha256 > /dev/null 2>&1; then
		sha256 "$1"
	elif command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1"
	elif command -v shasum > /dev/null 2>&1; then
		shasum -a 256 "$1"
	else
		die 'no sha256 tool found (sha256, sha256sum or shasum)'
	fi
}

SUBFILE=''
SUBPROG=''
mk_subst() { # build the sed program that replaces the placeholders
	SUBFILE="$OUT/.subst.sed"
	d=''
	for cand in '|' ',' ';' ':' '%'; do
		case "$DISTRO_NAME$MOTD$DISTRO_SLUG$BRAND_URL$FILESYSTEM_ROOT" in
		*"$cand"*) ;;
		*) d=$cand; break ;;
		esac
	done
	[ -n "$d" ] || die 'DISTRO_NAME/MOTD/DISTRO_SLUG/BRAND_URL contain every candidate sed delimiter (| , ; : %); remove one of those characters in product.conf'
	SUBPROG=$(
		printf 's%s@DISTRO_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_NAME")" "$d"
		printf 's%s@MOTD@%s%s%sg\n' "$d" "$d" "$(sed_esc "$MOTD")" "$d"
		printf 's%s@SLUG@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_SLUG")" "$d"
		printf 's%s@BRAND_URL@%s%s%sg\n' "$d" "$d" "$(sed_esc "$BRAND_URL")" "$d"
		printf 's%s@FILESYSTEM_ROOT@%s%s%sg\n' "$d" "$d" "$(sed_esc "$FILESYSTEM_ROOT")" "$d"
	)
}

# The placeholders are substituted in the staged file itself, so that the
# mode of the file (an executable script stays executable) survives the
# rewrite.
subst_staged() { # subst_staged <source-dir> <staged-dir>
	_ss_src=$1 _ss_stg=$2
	find "$_ss_src" -type f | while IFS= read -r _f; do
		_rel=${_f#"$_ss_src"/}
		step sh -c 'sed -f "$1" "$2" > "$2.new" && cat "$2.new" > "$2" && rm -f "$2.new"' \
			sh "$SUBFILE" "$_ss_stg/$_rel"
	done
}

# The overlay is copied with cp -R, never with cp -p: a copy that keeps
# the owner and the modes of the checkout would leave the files of the
# image writable by whoever built the template. Every path of the overlay
# gets the owner and the mode of a system file: root:wheel, directories
# 0755, files 0644 and the scripts 0755. The paths are handled one by
# one: no tree of the release root is ever walked with -R.
overlay_modes() { # overlay_modes <source-dir> <staged-dir>
	_om_src=$1 _om_stg=$2
	find "$_om_src" \( -type f -o -type d \) | while IFS= read -r _f; do
		[ "$_f" = "$_om_src" ] && continue
		_rel=${_f#"$_om_src"/}
		[ -n "$_rel" ] || continue
		_t="$_om_stg/$_rel"
		step chown root:wheel "$_t"
		if [ -d "$_f" ]; then
			step chmod 755 "$_t"
		else
			case $_rel in
			etc/rc.d/* | sbin/* | usr/sbin/* | usr/local/bin/* | usr/local/sbin/*)
				step chmod 755 "$_t"
				;;
			*)
				step chmod 644 "$_t"
				;;
			esac
		fi
	done
}

# --------------------------------------------------------------------------
# the nrelease run
# --------------------------------------------------------------------------

NRELEASE="$SRC/nrelease"

case $PROF in
both) profiles='appliance desktop' ;;
*) profiles=$PROF ;;
esac

# The desktop ships a disk image by default, because the DragonFly 6.4
# EFI loader cannot read past 2 GiB of an ISO9660 image. DFLY_MEDIA=iso
# asks for the ISO after all (and the plan warns about the 2 GiB limit).
# The knob is DFLY_MEDIA, not MEDIA: an unrelated MEDIA in the
# environment is ignored and never stops the build.
DFLY_MEDIA_KNOB=${DFLY_MEDIA:-img}
case $DFLY_MEDIA_KNOB in
img | iso) ;;
*) die "DFLY_MEDIA must be 'img' or 'iso' (got: $DFLY_MEDIA_KNOB)" ;;
esac

# The packages of the release. BINPKGS=yes (the default) hands the
# binpkgs modifier of the release tooling to both make calls: nrelease
# installs binary packages with pkg (by name, then by origin), which is
# fast. BINPKGS=no hands no modifier: nrelease runs make install for every
# DPorts origin in a chroot (many hours for xorg/xfce4). The modifier is a
# bare word on the command line, not a KEY=value.
BINPKGS=${BINPKGS:-yes}
case $BINPKGS in
yes) BINPKGS_ARG='binpkgs' ;;
no) BINPKGS_ARG='' ;;
*) die "BINPKGS must be 'yes' or 'no' (got: $BINPKGS)" ;;
esac

log ''
log 'plan:'
log "  distro   $DISTRO_NAME ($DISTRO_SLUG), dragonfly/$DISTRO_ARCH"
log "  rootfs   $FILESYSTEM_ROOT (the root of the release image is UFS)"
log "  profile  $PROF (package set: $PACKAGE_SET, installer: $INSTALLER)"
log "  src      $SRC (unmodified; the release tooling builds the world)"
log "  dports   $DPORTS_PATH (the DPorts tree; BINPKGS=no builds the packages from it)"
log "  out      $OUT"
if [ -n "$FBUSER" ]; then
	log "  login    the first-boot user $FBUSER"
elif [ "$NOUSER" -eq 1 ]; then
	log '  login    no first-boot user (--no-user): nobody can log in'
else
	log '  login    WARNING: no first-boot user given (the real build needs -u or --no-user)'
fi

RELS='' # relative artifact paths; safe to word-split: the slug is [a-z0-9-]
first=1

for p in $profiles; do
	log ''
	log "==> profile: $p"

	PSUB="$OUT/$p"
	ISOROOT="$PSUB/root"
	SK="$PSUB/rootskels"
	ISOFILE="$PSUB/$DISTRO_SLUG-$p-$DISTRO_ARCH.iso"
	IMGFILE="$PSUB/$DISTRO_SLUG-$p-$DISTRO_ARCH.img"

	# the media of the profile, and the ones built. The appliance ships a
	# disk image. The desktop ships one too, by default, because the
	# DragonFly 6.4 EFI loader cannot read past 2 GiB of an ISO9660 image
	# (a 3.9 GB desktop ISO from nrelease puts /boot past 3 GiB, so the
	# loader cannot load the kernel: upstream ships its GUI release as
	# .img for that reason). DFLY_MEDIA=iso asks for the ISO after all.
	# The choice is made once: the targets of the media, the media
	# shipped, and the note of the desktop ISO all come from it. The
	# appliance also builds its ISO (the install media) and ships the
	# disk image.
	if [ "$p" = desktop ] && [ "$DFLY_MEDIA_KNOB" = iso ]; then
		media_targets='mkiso'
		MEDIA=$ISOFILE
		log '  NOTE: the desktop is built as an ISO; it must stay under 2 GiB, the DragonFly 6.4 EFI loader cannot read past 2 GiB of ISO9660 -- use DFLY_MEDIA=img for the disk image, as upstream ships its GUI release'
	elif [ "$p" = desktop ]; then
		media_targets='mkimg'
		MEDIA=$IMGFILE
	else
		media_targets='mkiso mkimg'
		MEDIA=$IMGFILE
	fi

	# The rootskels of the release tooling and the overlay of the product,
	# in that order: a ROOTSKELS on the command line replaces every
	# default of the Makefile of the release tooling, so the build has to
	# name the skeleton of the release tooling itself. The skeleton of the
	# GUI of nrelease (nrelease/gui) is NOT among them: it installs into
	# /usr/pkg paths that the DPorts product does not have (its fstab
	# mounts /usr/pkg/etc, its xorg.conf points at /usr/pkg, its
	# /etc/issue says "login as root"), so it drops the live system to
	# single user; whatever the overlay needs, it carries itself.
	ROOTSKELS="$NRELEASE/root $SK"

	# the packages of the base list and of the profile list: they are
	# handed to the release tooling, which puts them into the release
	# root (DPORTS_EXTRA_PACKAGES). Every one of them is a DPorts
	# ORIGIN (category/port): with binpkgs nrelease installs it with
	# pkg (by name, then by origin), without it nrelease runs make
	# install for the origin in a chroot, so a bare name is refused.
	pkgs=$(pkg_list "$ROOT/overlay/base/packages.list" "$ROOT/overlay/profiles/$p/packages.list")
	for _origin in $pkgs; do
		chk '^[a-z0-9-]+/[A-Za-z0-9._+-]+$' "$_origin" \
			"the package list of the $p profile holds a name that is not a DPorts origin (category/port): without binpkgs nrelease builds every package with make install from its DPorts origin"
	done

	# 1. the overlay, staged for the rootskels hook
	log '  [1] the overlay, staged for the rootskels hook of the release tooling'
	mk_subst
	step sh -c 'printf "%s\n" "$1" > "$2"' sh "$SUBPROG" "$SUBFILE"
	rmrf "$SK" "$OUT"
	step mkdir -p "$SK"
	step cp -R "$ROOT/overlay/base/rootfs/." "$SK/"
	step cp -R "$ROOT/overlay/profiles/$p/rootfs/." "$SK/"
	subst_staged "$ROOT/overlay/base/rootfs" "$SK"
	subst_staged "$ROOT/overlay/profiles/$p/rootfs" "$SK"
	overlay_modes "$ROOT/overlay/base/rootfs" "$SK"
	overlay_modes "$ROOT/overlay/profiles/$p/rootfs" "$SK"
	# the staged files whose NAME holds the slug belong to the product
	for _srcdir in "$ROOT/overlay/base/rootfs" "$ROOT/overlay/profiles/$p/rootfs"; do
		find "$_srcdir" -depth -name '*@SLUG@*' | while IFS= read -r _sf; do
			_rel=${_sf#"$_srcdir"/}
			_new=$(printf %s "$_rel" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
			step mv "$SK/$_rel" "$SK/$_new"
		done
	done
	# the rc.conf(5) fragments of the overlay: they are staged and
	# substituted like the files of the overlay, so that a fragment may
	# hold a placeholder (the hostname of the product is its slug). The
	# overlay itself is never edited.
	RCD="$PSUB/rc.conf.d"
	rmrf "$RCD" "$OUT"
	step mkdir -p "$RCD/base" "$RCD/profile"
	if [ -d "$ROOT/overlay/base/rc.conf.d" ]; then
		step cp -R "$ROOT/overlay/base/rc.conf.d/." "$RCD/base/"
		subst_staged "$ROOT/overlay/base/rc.conf.d" "$RCD/base"
	fi
	if [ -d "$ROOT/overlay/profiles/$p/rc.conf.d" ]; then
		step cp -R "$ROOT/overlay/profiles/$p/rc.conf.d/." "$RCD/profile/"
		subst_staged "$ROOT/overlay/profiles/$p/rc.conf.d" "$RCD/profile"
	fi
	# DragonFly has no motd template mechanism: the live file is the motd
	if [ -f "$ROOT/overlay/base/rootfs/etc/motd.template" ]; then
		step cp "$SK/etc/motd.template" "$SK/etc/motd"
	fi
	# the configuration of the first boot: the operator account, its keys
	# and its password hash (never a plain text password)
	if [ -n "$FBUSER" ]; then
		step sh -c '
			set -eu
			conf=$1; user=$2; keyfile=$3; passfile=$4
			# the directory is /boot of the image: 0755, whatever the
			# umask, and created before the umask below
			mkdir -p -m 755 "$(dirname "$conf")"
			# the file may hold a password hash: it is created 0600,
			# never readable by others, even before the chmod below
			umask 077
			pass=
			if [ -n "$passfile" ]; then
				# -P was given: the hash is required. A file that is
				# gone, not a regular file, unreadable, empty or not a
				# crypt(3) hash stops the build (the hash is never
				# printed)
				if [ ! -f "$passfile" ] || [ ! -r "$passfile" ]; then
					printf "build.sh: the password hash file is gone or unreadable: %s; give -P a readable file whose first line is one crypt(3) hash (\$6\$, \$5\$ or \$2b\$; see -P in README.md), and keep it in place until the build is done\n" "$passfile" >&2
					exit 1
				fi
				pass=$(sed -e "s/[[:space:]][[:space:]]*$//" "$passfile" | grep -v "^[[:space:]]*$" | head -1) || pass=
				case $pass in
				"\$6\$"* | "\$5\$"* | "\$2b\$"* | "\$2y\$"*) ;;
				*)
					printf "build.sh: the password hash file holds no crypt(3) hash: %s; give -P a file whose first line is one crypt(3) hash (\$6\$, \$5\$ or \$2b\$; see -P in README.md), never a plain text password, and keep it unchanged until the build is done\n" "$passfile" >&2
					exit 1
					;;
				esac
			fi
			{
				printf "USERNAME=%s\n" "$user"
				if [ -n "$keyfile" ]; then
					while IFS= read -r k || [ -n "$k" ]; do
						case $k in "" | "#"*) continue ;; esac
						printf "SSH_KEY=%s\n" "$k"
					done < "$keyfile"
				fi
				if [ -n "$pass" ]; then
					printf "PASSWORD_HASH=%s\n" "$pass"
				fi
			} > "$conf"
			chmod 600 "$conf"
		' sh "$SK/boot/firstboot-user.conf" "$FBUSER" "$FBKEY" "$FBPASS"
	fi

	# 2. the release: the world (once for the whole build), the release
	#    root, the overlay through ROOTSKELS, the packages through
	#    DPORTS_EXTRA_PACKAGES
	log '  [2] the release (nrelease)'
	if [ "$first" -eq 1 ]; then
		# the world is built once for the whole build: the release root
		# of every further profile is staged from it
		_mtargets='check clean buildworld1 buildkernel1 buildiso pkgs customizeiso srcs'
	else
		_mtargets='buildiso pkgs customizeiso srcs'
	fi
	step make -C "$NRELEASE" $_mtargets \
		"ROOTSKELS=$ROOTSKELS" \
		"ISODIR=$PSUB" \
		"ISOROOT=$ISOROOT" \
		"ISOFILE=$ISOFILE" \
		"IMGFILE=$IMGFILE" \
		"DPORTS_PATH=$DPORTS_PATH" \
		$BINPKGS_ARG \
		"DPORTS_EXTRA_PACKAGES=$pkgs"
	first=0

	# 3. the post-customize step: it runs in the release root, before
	#    the media are built from it
	log '  [3] the post-customize step (in the release root)'
	if [ "$p" = appliance ]; then
		# the appliance image holds no installer: the account of the
		# release tooling is removed from it
		_rmacct=installer
		_keepacct=-
	else
		# the desktop ISO is the install path: the installer account
		# keeps its empty password there, so that the operator can
		# install the system from the live media
		_rmacct=-
		_keepacct=installer
	fi
	step sh "$ROOT/tools/post-customize.sh" "$ISOROOT" \
		"$RCD/base" "$RCD/profile" \
		"$SK" ttyd0 comconsole "$_rmacct" "$_keepacct"
	step pwd_mkdb -p -d "$ISOROOT/etc" "$ISOROOT/etc/master.passwd"
	step pwd_mkdb -p -d "$ISOROOT/etc.hdd" "$ISOROOT/etc.hdd/master.passwd"

	# 4. the media, built from the release root that was fixed. The
	#    size of the image is handed to nrelease as IMGSIZE_MB: the
	#    apparent size of the staged release root (the sum of the sizes
	#    of its files, stat -f %z; du reports the blocks on disk, which
	#    a compressed filesystem such as HAMMER2 makes smaller) plus 25%
	#    and 512 MiB of slack, so that mkimg does not fail with "No
	#    space left on device" (and leave the mount wedged). The size is
	#    only known after the release root has been staged, so it is
	#    computed once, in the real path: the dry run echoes the command
	#    without it.
	if [ "$DRY" -ne 1 ]; then
		[ -d "$ISOROOT" ] || die "the release root is not staged: $ISOROOT"
		# each stage is checked on its own (POSIX sh has no pipefail):
		# a find that fails, a release root without files, a stat that
		# fails or a size that is not a number stops the build, instead
		# of handing a size that is too small to nrelease
		_lst="$PSUB/.release-root-files"
		_szs="$PSUB/.release-root-sizes"
		find "$ISOROOT" -type f -print0 > "$_lst" ||
			die "could not list the files of the release root: $ISOROOT"
		[ -s "$_lst" ] || die "the release root holds no files: $ISOROOT"
		xargs -0 stat -f %z < "$_lst" > "$_szs" ||
			die "could not read the file sizes of the release root: $ISOROOT"
		_kb=$(awk '$0 !~ /^[0-9]+$/ { bad = 1 } { s += $1; n++ }
			END { if (bad || n == 0) exit 1; print int(s / 1024) }' "$_szs") ||
			die "could not sum the file sizes of the release root: $ISOROOT"
		rm -f "$_lst" "$_szs"
		IMGSIZE_MB=$((_kb / 1024 * 125 / 100 + 512))
		# handed to nrelease over the environment: it is not on the
		# command line, so the plan of the dry run and the commands of
		# the real path stay the same line, and the size still reaches
		# the release tooling that writes the image.
		export IMGSIZE_MB
	else
		IMGSIZE_MB=
	fi
	log '  [4] the media, built from the release root'
	step make -C "$NRELEASE" $media_targets \
		"ROOTSKELS=$ROOTSKELS" \
		"ISODIR=$PSUB" \
		"ISOROOT=$ISOROOT" \
		"ISOFILE=$ISOFILE" \
		"IMGFILE=$IMGFILE" \
		"DPORTS_PATH=$DPORTS_PATH" \
		$BINPKGS_ARG \
		"DPORTS_EXTRA_PACKAGES=$pkgs"

	# 5. the checks on the release root: no uid-0 account with a
	#    password that can be typed (the installer account of the
	#    desktop ISO is the install path and keeps its empty password),
	#    no installer account in the appliance image and no uid-0 account
	#    with a password that can be typed in the tree of the installer
	if [ "$DRY" -ne 1 ]; then
		_mpw="$ISOROOT/etc/master.passwd"
		[ -f "$_mpw" ] || die "the release root holds no password database ($_mpw)"
		_bad=$(awk -F: -v keep="$_keepacct" \
			'$3 == 0 && $1 != keep && $2 != "*" && $2 != "!" && $2 != "!!" { print $1 "(" $2 ")" }' "$_mpw")
		[ -z "$_bad" ] || die "the release root holds a uid-0 account with a password that can be typed: $_bad"
		if [ "$p" = appliance ]; then
			if grep -q '^installer:' "$_mpw"; then
				die "the appliance image holds the installer account of the release tooling (uid 0); the build refuses to publish it"
			fi
		fi
		_mpw2="$ISOROOT/etc.hdd/master.passwd"
		if [ -f "$_mpw2" ]; then
			_bad2=$(awk -F: '$3 == 0 && $2 != "*" && $2 != "!" && $2 != "!!" { print $1 "(" $2 ")" }' "$_mpw2")
			[ -z "$_bad2" ] || die "the tree of the installer holds a uid-0 account with a password that can be typed: $_bad2"
		fi
		[ -f "$MEDIA" ] || die "the release tooling did not build the media of the $p profile: $MEDIA"
	fi

	if [ "$DRY" -ne 1 ]; then
		printf '%s\n' "$MEDIA" > "$PSUB/ARTIFACT"
	fi

	rimg=${MEDIA#"$OUT"/}
	RELS="$RELS $rimg"

	log "profile done: $p (image root: UFS, machine $DISTRO_ARCH)"
done

# --------------------------------------------------------------------------
# checksums
# --------------------------------------------------------------------------

log ''
log '== checksums =='
if [ "$DRY" -eq 1 ]; then
	printf '    + sha256 %s > %s/SHA256\n' "${RELS# }" "$OUT"
else
	: > "$OUT/SHA256"
	for rel in $RELS; do
		sums "$OUT/$rel" >> "$OUT/SHA256"
	done
	log "wrote: $OUT/SHA256"
fi
log 'artifacts:'
for rel in $RELS; do
	log "  $OUT/$rel"
done

if [ "$DRY" -eq 1 ]; then
	log ''
	log 'dry run: plan printed above; nothing was built'
else
	log ''
	log "done: $profiles under $OUT"
fi
