#!/bin/sh
# tests/fixtures/fake-provider.sh — a ci/vm.sh provider for the tests.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It implements the provider contract of ci/vm.sh:
#
#   create NAME IMAGE   publish a canned serial log for the VM
#   console NAME        print the path of the serial log
#   addr NAME           print the guest address
#   destroy NAME        stop the fake VM and its listener
#
# The serial log it publishes is a real console transcript (the fixture in
# tests/fixtures/serial-login.log); the "no login prompt" case is derived
# from that same file by cutting it before the prompt.
#
# Knobs (environment):
#   WTFBSD_FAKE_STATE       file the provider appends its calls to
#   WTFBSD_FAKE_LOG         serial log file the VM "writes"
#   WTFBSD_FAKE_SOURCE_LOG  canned serial log to publish (may be empty)
#   WTFBSD_FAKE_ADDR        address printed by the addr subcommand
#   WTFBSD_FAKE_SSH_PORT    port the fake guest listens on (optional)
#   WTFBSD_FAKE_DESTROY_FAIL set to 1 to make the destroy subcommand fail

set -eu

STATE=${WTFBSD_FAKE_STATE:-/tmp/fake-provider.state}
LOG=${WTFBSD_FAKE_LOG:-/tmp/fake-provider.serial}
ADDR=${WTFBSD_FAKE_ADDR:-127.0.0.1}

# a VM name may only hold these characters and may not be longer than
# 64 characters; the check is a case pattern and a length check, never a
# line based grep: a name with a newline in it would pass a line based
# check
valid_name() {
	case $1 in
	'' | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	[ "${#1}" -le 64 ] || return 1
	return 0
}

check_name() {
	if ! valid_name "$1"; then
		printf 'fake-provider: invalid VM name: %s\n' "$1" >&2
		exit 2
	fi
}

cmd=${1:-}
[ -n "$cmd" ] || {
	printf 'fake-provider: missing subcommand\n' >&2
	exit 2
}
shift

# the name of the VM is checked before the call is recorded: a name that
# is not allowed never reaches the provider at all
case $cmd in
create) check_name "${1:-}" ;;
console | addr | destroy) check_name "${1:-}" ;;
esac

printf '%s %s\n' "$cmd" "$*" >> "$STATE"

listener_pid() {
	printf '%s.listener.pid\n' "$LOG"
}

listener_nc_pid() {
	printf '%s.listener.nc.pid\n' "$LOG"
}

stop_listener() {
	_pidfile=$(listener_pid)
	_ncpidfile=$(listener_nc_pid)
	# the nc of the listener is a child of the loop of the listener:
	# killing the loop alone leaves the nc behind as an orphan that
	# keeps the port, so the nc is stopped as well
	_nc=$(cat "$_ncpidfile" 2>/dev/null || true)
	if [ -f "$_pidfile" ]; then
		_kill=$(cat "$_pidfile" 2>/dev/null || true)
		if [ -n "$_kill" ]; then
			kill "$_kill" 2>/dev/null || true
		fi
		rm -f "$_pidfile"
	fi
	if [ -n "$_nc" ]; then
		kill "$_nc" 2>/dev/null || true
	fi
	rm -f "$_ncpidfile"
}

case $cmd in
create)
	_name=${1:-}
	[ -n "$_name" ] || {
		printf 'fake-provider: create needs a VM name\n' >&2
		exit 2
	}
	check_name "$_name"
	if [ -n "${WTFBSD_FAKE_SOURCE_LOG:-}" ] && [ -f "$WTFBSD_FAKE_SOURCE_LOG" ]; then
		cp "$WTFBSD_FAKE_SOURCE_LOG" "$LOG"
	else
		: > "$LOG"
	fi
	# the fake guest answers on the ssh port, like the appliance image
	if [ -n "${WTFBSD_FAKE_SSH_PORT:-}" ] && command -v nc > /dev/null 2>&1; then
		(
			_ncpid=''
			# the nc is a child of this loop: it is stopped when
			# the loop is stopped, so that no listener is left
			# behind
			stop_nc() {
				if [ -n "$_ncpid" ]; then
					kill "$_ncpid" 2>/dev/null || true
				fi
			}
			trap 'stop_nc; exit 0' TERM INT HUP
			while :; do
				nc -l 127.0.0.1 "$WTFBSD_FAKE_SSH_PORT" < /dev/null > /dev/null 2>&1 &
				_ncpid=$!
				printf '%s\n' "$_ncpid" > "$(listener_nc_pid)"
				wait "$_ncpid" 2>/dev/null || true
				_ncpid=''
				sleep 1
			done
		) &
		printf '%s\n' "$!" > "$(listener_pid)"
	fi
	;;
console)
	check_name "${1:-}"
	printf '%s\n' "$LOG"
	;;
addr)
	check_name "${1:-}"
	printf '%s\n' "$ADDR"
	;;
destroy)
	check_name "${1:-}"
	stop_listener
	if [ "${WTFBSD_FAKE_DESTROY_FAIL:-0}" = 1 ]; then
		printf 'fake-provider: the VM could not be destroyed\n' >&2
		exit 1
	fi
	;;
*)
	printf 'fake-provider: unknown subcommand: %s\n' "$cmd" >&2
	exit 2
	;;
esac

exit 0
