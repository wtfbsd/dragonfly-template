#!/bin/sh
#
# tests/boot-test.sh — boot an image in a VM and wait until it is usable.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# usage: tests/boot-test.sh IMAGE PROFILE [NAME]
#
#   IMAGE    the disk image to boot
#   PROFILE  appliance or desktop
#   NAME     the name of the VM (default: boot-<profile>-<pid>)
#
# The VM is handled through ci/vm.sh only, so the same script works with
# any provider. The test waits for a login prompt on the serial console
# and, for the appliance profile, for sshd to answer on port 22. It exits
# non-zero on a timeout and always destroys the VM.
#
# The name of the VM can also be given in the environment
# (WTFBSD_VM_NAME), so that a pipeline can name the VM after the build
# and destroy it again when the build is over.
#
# Knobs (environment):
#   WTFBSD_BOOT_TIMEOUT    seconds to wait for each step (default 600)
#   WTFBSD_BOOT_SSH_PORT   port the sshd probe uses (default 22)
#   WTFBSD_VM_NAME         name of the VM (default: boot-<profile>-<pid>)

set -eu

PROG=$(basename -- "$0")
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
vmsh="$repo/ci/vm.sh"

log() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	printf 'usage: %s IMAGE PROFILE [NAME]\n' "$PROG" >&2
	exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
IMAGE=$1
PROFILE=$2
VM_NAME=${3:-${WTFBSD_VM_NAME:-}}

case $PROFILE in
desktop | appliance) ;;
*) die "PROFILE must be desktop or appliance (got: $PROFILE)" ;;
esac
if [ -z "$VM_NAME" ]; then
	VM_NAME="boot-$PROFILE-$$"
fi

TIMEOUT=${WTFBSD_BOOT_TIMEOUT:-600}
SSH_PORT=${WTFBSD_BOOT_SSH_PORT:-22}

[ -f "$IMAGE" ] || die "no such image: $IMAGE"
[ -f "$vmsh" ] || die "no such VM front end: $vmsh"

cleaned=0
cleanup() {
	if [ "$cleaned" -eq 1 ]; then
		return 0
	fi
	cleaned=1
	# a VM that cannot be destroyed is a failure of the test, not
	# something to hide: the message goes to stderr
	_err=$(sh "$vmsh" destroy "$VM_NAME" 2>&1) || {
		printf '%s: the VM %s could not be destroyed: %s\n' "$PROG" "$VM_NAME" "$_err" >&2
		return 0
	}
}
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

log "booting $IMAGE as $VM_NAME (profile $PROFILE)"
sh "$vmsh" create "$VM_NAME" "$IMAGE" > /dev/null

LOG=$(sh "$vmsh" console "$VM_NAME")
[ -n "$LOG" ] || die 'the provider printed no serial console log path'

log "waiting up to ${TIMEOUT}s for a login prompt on the serial console"
deadline=$(( $(date +%s) + TIMEOUT ))
seen=0
while [ "$(date +%s)" -lt "$deadline" ]; do
	if [ -f "$LOG" ] && grep -q 'login:' "$LOG" 2> /dev/null; then
		seen=1
		break
	fi
	sleep 2
done
[ "$seen" -eq 1 ] || die "timed out after ${TIMEOUT}s waiting for 'login:' on the serial console"

if [ "$PROFILE" = appliance ]; then
	ADDR=$(sh "$vmsh" addr "$VM_NAME")
	[ -n "$ADDR" ] || die 'the provider printed no guest address'
	log "waiting up to ${TIMEOUT}s for sshd on $ADDR port $SSH_PORT"
	deadline=$(( $(date +%s) + TIMEOUT ))
	up=0
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if nc -z -w 2 "$ADDR" "$SSH_PORT" 2> /dev/null; then
			up=1
			break
		fi
		sleep 2
	done
	[ "$up" -eq 1 ] || die "timed out after ${TIMEOUT}s waiting for sshd on $ADDR port $SSH_PORT"
fi

log "boot test passed: $IMAGE ($PROFILE)"
exit 0
