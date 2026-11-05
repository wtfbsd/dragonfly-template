#!/bin/sh
# scripts/identity-file.sh -- write the identity file a product image carries
# at /usr/local/share/<slug>/identity.
#
# Usage: sh scripts/identity-file.sh --product NAME --version V --base BASE
#            --variant LABEL --arch ARCH [--build DATE] > identity
#
#   --base auto    take the base OS from `uname -sr` of the running system
#                  (use this only when running inside the built system; a
#                  cross build passes the target's name and release).
#   --arch auto    take the architecture from `uname -p`.
#   --build today  today's date (UTC, YYYY-MM-DD); omit --build on releases.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib-identity.sh"

die() { printf 'identity-file.sh: error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,13s/^# \{0,1\}//p' "$0"; }

PRODUCT='' VERSION='' BASE='' VARIANT='' ARCH='' BUILD=''
while [ $# -gt 0 ]; do
	case $1 in
	--product) PRODUCT=${2-}; shift 2 ;;
	--version) VERSION=${2-}; shift 2 ;;
	--base) BASE=${2-}; shift 2 ;;
	--variant) VARIANT=${2-}; shift 2 ;;
	--arch) ARCH=${2-}; shift 2 ;;
	--build) BUILD=${2-}; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

[ "$BASE" = auto ] && BASE=$(uname -sr)
[ "$ARCH" = auto ] && ARCH=$(uname -p)
[ "$BUILD" = today ] && BUILD=$(date -u +%Y-%m-%d)

for _k in PRODUCT VERSION BASE VARIANT ARCH; do
	eval "_v=\$$_k"
	[ -n "$_v" ] || die "--$(printf '%s' "$_k" | tr '[:upper:]' '[:lower:]') is required"
done
for _k in $IDENTITY_KEYS; do
	eval "_v=\$$_k"
	identity_valid "$_v" || die "$_k has characters outside [A-Za-z0-9 ._:+()/-]: $_v"
done

printf 'PRODUCT=%s\nVERSION=%s\nBASE=%s\nVARIANT=%s\nARCH=%s\nBUILD=%s\n' \
	"$PRODUCT" "$VERSION" "$BASE" "$VARIANT" "$ARCH" "$BUILD"
