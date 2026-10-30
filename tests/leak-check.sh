#!/bin/sh
#
# tests/leak-check.sh — the leak check of this repository.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It looks for GENERIC shapes in every file of the tree: an address, an
# email address of another domain, an internal top level domain, a
# credential shape, a token prefix. It holds NO list of names: a list of
# names is itself a list of names, and this repository ships to anyone.
#
# A site that wants to check for its own names points WTFBSD_DENYLIST at
# a file OUTSIDE this repository: every non-comment line of that file is
# a case-insensitive extended regular expression that is matched against
# every file of the tree.
#
# usage: sh tests/leak-check.sh
# exit status: 0 when nothing was found, 1 otherwise.
#
# The patterns are assembled at run time, so that this file does not
# hold the strings it forbids.

set -u

PROG=$(basename -- "$0")
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/.." && pwd)

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# --------------------------------------------------------------------------
# the patterns (assembled at run time)
# --------------------------------------------------------------------------
# The fragments of the patterns are kept apart, so that this file does
# not hold the strings it forbids.
t_ghp='gh'
t_ghp2='p_'
t_gho='gh'
t_gho2='o_'
t_gpat='github'
t_gpat2='_pat_'
n_api='api'
n_Key='Key'
n_api_='api_'
n_key='key'
n_base='base'
n_URL='URL'
n_Bear='Bear'
n_er='er'
h_begin='BEGIN '
h_priv='PRIVATE KEY'
k_ssh='ssh-(ed25519|rsa)'
t_sk='sk'

P_IPV4='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
P_IPV6C='[0-9A-Fa-f]*(:[0-9A-Fa-f]*)+'
P_MAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
P_TLD='\.(lan|corp|internal|local|lab|localdomain|home\.arpa)([^0-9A-Za-z]|$)'
P_TOKENS="(${t_ghp}${t_ghp2}|${t_gho}${t_gho2}|${t_gpat}${t_gpat2}|AKIA[0-9A-Z]{16}|xox[abp]-|${t_sk}-[A-Za-z0-9_-]{20,})"
P_NAMES="${n_api}${n_Key}|${n_api_}${n_key}|${n_base}${n_URL}|${n_Bear}${n_er}"
P_PRIV="${h_begin}.*${h_priv}"
P_SSHKEY="${k_ssh} AAAA"

# --------------------------------------------------------------------------
# the helpers
# --------------------------------------------------------------------------

# an IPv4 address that may stay in the tree: the loopback address and
# the three documentation ranges of RFC 5737
ipv4_allowed() {
	case $1 in
	127.0.0.1) return 0 ;;
	192.0.2.* | 198.51.100.* | 203.0.113.*) return 0 ;;
	esac
	return 1
}

# an IPv6 address that may stay in the tree: the loopback address and
# the documentation range of RFC 3849
ipv6_allowed() {
	case $1 in
	::1) return 0 ;;
	2001:db8:*) return 0 ;;
	esac
	return 1
}

# an email address that may stay in the tree: the example domains and the
# domain of the certificate key types of OpenSSH (sk-ssh-ed25519@openssh.com
# and the like): those are the names of a key type, not an address
mail_allowed() {
	case $1 in
	*@example.org | *@example.com) return 0 ;;
	*@openssh.com) return 0 ;;
	esac
	return 1
}

# the groups of a half of a compressed address: every group holds one
# to four hex digits, and no group is empty
_groups_ok() {
	if [ -z "$1" ]; then
		return 0
	fi
	_bad=$(printf '%s\n' "$1" | tr ':' '\n' |
		grep -Evc '^([0-9A-Fa-f]{1,4})$')
	[ "$_bad" -eq 0 ]
}

# the number of the groups of a half
_count_groups() {
	if [ -z "$1" ]; then
		printf '0\n'
		return 0
	fi
	printf '%s\n' "$1" | tr ':' '\n' | grep -c .
}

# is the token an IPv6 address? Eight groups, or a compressed address
# with a single "::". A MAC address has six groups and is not one.
ipv6_is_address() {
	_tok=$1
	_n=$(printf '%s' "$_tok" | awk '{ n = gsub(/::/, ""); print n }')
	[ "$_n" -le 1 ] || return 1
	if [ "$_n" -eq 1 ]; then
		_l=${_tok%%::*}
		_r=${_tok#*::}
		_groups_ok "$_l" || return 1
		_groups_ok "$_r" || return 1
		_count=$(( $(_count_groups "$_l") + $(_count_groups "$_r") ))
		[ "$_count" -ge 1 ] || return 1
		[ "$_count" -le 7 ] || return 1
		return 0
	fi
	[ "$(_count_groups "$_tok")" -eq 8 ] || return 1
	return 0
}

HITS=''
report() { # report <file> <what>
	HITS="$HITS$1: $2
"
}

# scan_file <file>
scan_file() {
	_f=$1
	[ -f "$_f" ] || return 0
	[ -r "$_f" ] || return 0

	# the addresses
	grep -a -oE "$P_IPV4" "$_f" 2>/dev/null | while IFS= read -r _a; do
		ipv4_allowed "$_a" || printf '%s\n' "$_f: address $_a" >> "$HITFILE"
	done
	grep -a -oE "$P_IPV6C" "$_f" 2>/dev/null | while IFS= read -r _a; do
		ipv6_is_address "$_a" || continue
		ipv6_allowed "$_a" || printf '%s\n' "$_f: address $_a" >> "$HITFILE"
	done

	# the email addresses
	grep -a -oE "$P_MAIL" "$_f" 2>/dev/null | while IFS= read -r _a; do
		mail_allowed "$_a" || printf '%s\n' "$_f: email address $_a" >> "$HITFILE"
	done

	# the internal top level domains
	grep -a -oiE "$P_TLD" "$_f" 2>/dev/null | while IFS= read -r _a; do
		printf '%s\n' "$_f: internal top level domain $_a" >> "$HITFILE"
	done

	# the credential shapes
	grep -a -oiE "$P_PRIV" "$_f" 2>/dev/null | while IFS= read -r _a; do
		printf '%s\n' "$_f: private key header" >> "$HITFILE"
	done
	grep -a -oiE "$P_SSHKEY" "$_f" 2>/dev/null | while IFS= read -r _a; do
		printf '%s\n' "$_f: public key header" >> "$HITFILE"
	done
	grep -a -oiE "$P_TOKENS" "$_f" 2>/dev/null | while IFS= read -r _a; do
		printf '%s\n' "$_f: token $_a" >> "$HITFILE"
	done
	grep -a -oiE "$P_NAMES" "$_f" 2>/dev/null | while IFS= read -r _a; do
		printf '%s\n' "$_f: credential name $_a" >> "$HITFILE"
	done

	# the private deny-list of the site (optional)
	if [ -n "${DENYLIST:-}" ] && [ -r "$DENYLIST" ]; then
		while IFS= read -r _p || [ -n "$_p" ]; do
			case $_p in
			'' | '#'*) continue ;;
			esac
			if grep -qiE -- "$_p" "$_f" 2>/dev/null; then
				printf '%s\n' "$_f: denied by the private list" >> "$HITFILE"
			fi
		done < "$DENYLIST"
	fi
}

# --------------------------------------------------------------------------
# the scan mode: every file of the tree is given on the command line
# --------------------------------------------------------------------------
if [ "${1:-}" = "--scan" ]; then
	shift
	for _f in "$@"; do
		scan_file "$_f"
	done
	exit 0
fi

cd "$root" || die "cannot enter $root"

HITFILE=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-leak.XXXXXX") || die 'cannot create a temporary file'
trap 'rm -f "$HITFILE"' EXIT HUP INT TERM
: > "$HITFILE"

DENYLIST=${WTFBSD_DENYLIST:-}
export DENYLIST HITFILE

if command -v git > /dev/null 2>&1 && git rev-parse --git-dir > /dev/null 2>&1; then
	git ls-files -z --cached --others --exclude-standard |
		xargs -0 sh "$here/$(basename -- "$0")" --scan
else
	find . -type f -not -path './.git/*' -print0 |
		xargs -0 sh "$here/$(basename -- "$0")" --scan
fi

if [ -s "$HITFILE" ]; then
	log "$PROG: the tree holds things that may not be in it:"
	sed 's/^/  | /' "$HITFILE"
	exit 1
fi

log "$PROG: the tree holds no address, no foreign email address, no internal domain, no credential shape and no token"
exit 0
