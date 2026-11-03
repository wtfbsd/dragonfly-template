# scripts/lib-identity.sh -- shared helpers for the identity line.
# Sourced (not executed) by render.sh, identity-file.sh and identity-stamp.sh.
#
# The identity file is KEY=value lines, read here without sourcing it:
#   PRODUCT=ExampleBSD
#   VERSION=1.0
#   BASE=FreeBSD 16.0-CURRENT
#   VARIANT=Cyberpunk
#   ARCH=amd64
#   BUILD=2026-11-01        (test builds only; empty or absent on releases)

# Allowed value characters: letters, digits, space and . _ : + - ( ) /
IDENTITY_VALUE_RE='^[A-Za-z0-9 ._:+()/-]{0,64}$'
IDENTITY_KEYS='PRODUCT VERSION BASE VARIANT ARCH BUILD'
# Separator between fields: a middle dot (U+00B7) with spaces.
IDENTITY_SEP=' · '
# ASCII separator for text surfaces whose UTF-8 support is unconfirmed.
IDENTITY_SEP_ASCII=' | '

identity_valid() {
	# identity_valid VALUE : true if VALUE is a safe identity value
	[ -z "$1" ] || printf '%s' "$1" | grep -Eq -- "$IDENTITY_VALUE_RE"
}

identity_read() {
	# identity_read FILE : set ID_PRODUCT ID_VERSION ID_BASE ID_VARIANT
	# ID_ARCH ID_BUILD from FILE. Returns 1 (with a message) on a bad file.
	ID_PRODUCT='' ID_VERSION='' ID_BASE='' ID_VARIANT='' ID_ARCH='' ID_BUILD=''
	[ -f "$1" ] || { printf 'identity file not found: %s\n' "$1" >&2; return 1; }
	for _ik in $IDENTITY_KEYS; do
		_iv=$(tr -d '\r' < "$1" | sed -n "s/^$_ik=//p" | tail -n 1)
		_iv=${_iv#\"}
		_iv=${_iv%\"}
		identity_valid "$_iv" || { printf 'identity %s has characters outside [A-Za-z0-9 ._:+()/-]: %s\n' "$_ik" "$_iv" >&2; return 1; }
		eval "ID_$_ik=\$_iv"
	done
	for _ik in PRODUCT VERSION BASE VARIANT ARCH; do
		eval "_iv=\$ID_$_ik"
		[ -n "$_iv" ] || { printf 'identity file %s lacks %s\n' "$1" "$_ik" >&2; return 1; }
	done
	return 0
}

identity_line() {
	# identity_line SEP : print "<Product> <version>SEP<base>SEP<variant>SEP<arch>"
	# plus "SEPbuild <date>" when BUILD is set.
	_il="$ID_PRODUCT $ID_VERSION$1$ID_BASE$1$ID_VARIANT$1$ID_ARCH"
	[ -n "$ID_BUILD" ] && _il="$_il${1}build $ID_BUILD"
	printf '%s' "$_il"
}

palette_value() {
	# palette_value KEY FILE... : last value of KEY across the files (later
	# files override earlier ones); quotes stripped. Never sources a file.
	_pk=$1
	shift
	_pv=''
	for _pf in "$@"; do
		[ -f "$_pf" ] || continue
		_pn=$(tr -d '\r' < "$_pf" | sed -nE "s/^[[:space:]]*$_pk=\"?([^\"]*)\"?[[:space:]]*\$/\\1/p" | tail -n 1)
		[ -n "$_pn" ] && _pv=$_pn
	done
	printf '%s' "$_pv"
}
