#!/bin/sh
#
# ci/providers/bhyve.sh — the reference VM provider for ci/vm.sh.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It boots a guest with stock FreeBSD bhyve(8) and logs the serial
# console through a nmdm(4) device, so the boot test can read the console
# transcript from a file.
#
# Contract (called by ci/vm.sh, never by hand):
#   create NAME IMAGE   boot IMAGE as a VM called NAME
#   console NAME        print the path of the serial console log
#   addr NAME           print the address of the guest
#   unit NAME           print the unit of the null-modem pair and of the
#                       tap of the VM
#   destroy NAME        stop the VM and remove its runtime state
#
# It needs root (bhyve(8), nmdm(4), tap(4)) on a FreeBSD host, and these
# tools on the host: bhyve, bhyvectl, ifconfig, arp.
#
# The serial console is a null-modem pair: /dev/nmdmNA is the side
# bhyve(8) writes to, /dev/nmdmNB is the side the reader reads from.
# The reader puts its end of the device in raw mode without echo: the
# device opens in canonical mode with echo, the prompt of getty has no
# newline, so a canonical read never returns it, and echo would feed the
# guest output back to the guest as input.
#
# The unit of the null-modem pair and of the tap follows the executor
# number and the slot of the VM in its job (WTFBSD_VM_SLOT): the unit is
# executor*3+slot and there is NO modulo, so two jobs of one host and two
# VMs of one job never share a device. The multiplier is the number of
# the slots of a job: the profile both uses the slots 0, 1 and 2.
#
# The image is attached as it is: an .iso artifact is a CD-ROM of the
# guest (ahci-cd), every other artifact is a disk of the guest
# (virtio-blk). The build of this template produces an ISO for the
# desktop profile and a disk image for the appliance profile.
#
# Knobs (environment):
#   WTFBSD_BHYVE_CPUS      vCPUs (default 2)
#   WTFBSD_BHYVE_MEM       memory (default 2G)
#   WTFBSD_BHYVE_FIRMWARE  UEFI firmware; an empty value means no boot ROM
#                          (default /usr/local/share/uefi-firmware/BHYVE_UEFI.fd)
#   WTFBSD_BHYVE_NMDM_BASE the null-modem pair of the serial console
#                          (default /dev/nmdm)
#   WTFBSD_BHYVE_TAP_BASE  the tap device of the guest (default tap)
#   WTFBSD_VM_SLOT         the slot of the VM in its job: the build VM
#                          has the slot 0 and the boot-test VMs the slot
#                          1, 2, ... so that two VMs of one job never
#                          share a device
#   WTFBSD_BHYVE_BRIDGE    bridge the tap device is attached to; without it
#                          the tap device stays alone, the guest has no
#                          network and "addr" finds no address
#   WTFBSD_BHYVE_STATE     directory for the runtime state of the VMs
#                          (default /var/tmp/wtfbsd-vm)
#   WTFBSD_BHYVE_CONSOLE   directory for the pid files of the console
#                          readers (default: the state directory)
#   WTFBSD_BHYVE_START_WAIT seconds to wait for the guest to start
#                          (default 10)
#   WTFBSD_BHYVE_NMDM_WAIT  seconds to wait for the serial device
#                          (default 20)
#   WTFBSD_BHYVE_DIRECT    set to 1 to boot the image in place instead of
#                          copying it (the artifact is then modified)
#
# Two knobs exist for the test suite only; a host that runs VMs never
# sets them:
#   WTFBSD_TEST_ALLOW_NONROOT  do not require root
#   WTFBSD_TEST_FAKE_NMDM      accept a plain file as the null-modem
#                              device (the suite has no device nodes)

set -eu

PROG=$(basename -- "$0")

CPUS=${WTFBSD_BHYVE_CPUS:-2}
MEM=${WTFBSD_BHYVE_MEM:-2G}
FIRMWARE=${WTFBSD_BHYVE_FIRMWARE-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
STATE=${WTFBSD_BHYVE_STATE:-/var/tmp/wtfbsd-vm}
CONSOLE_DIR=${WTFBSD_BHYVE_CONSOLE:-$STATE}
BRIDGE=${WTFBSD_BHYVE_BRIDGE:-}
NMDM_BASE=${WTFBSD_BHYVE_NMDM_BASE:-/dev/nmdm}
TAP_BASE=${WTFBSD_BHYVE_TAP_BASE:-tap}
START_WAIT=${WTFBSD_BHYVE_START_WAIT:-10}
NMDM_WAIT=${WTFBSD_BHYVE_NMDM_WAIT:-20}

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG create NAME IMAGE | console NAME | addr NAME | unit NAME | destroy NAME" >&2
	exit 2
}

# rm -rf only below the state directory, never the state directory itself
rmrf() {
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

# a VM name is one short word: it names a device, a file and an argument,
# and a newline in it would split a command in two
valid_name() { # valid_name <name>
	_v=${1:-}
	[ -n "$_v" ] || return 1
	[ "${#_v}" -le 64 ] || return 1
	case $_v in
	*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	case $_v in
	-* | .*) return 1 ;;
	esac
	return 0
}

# The unit of the null-modem pair and of the tap of one VM: it follows
# the executor number and the slot of the VM in its job. There is NO
# modulo here: a unit that is taken modulo a number is taken by two VMs
# of one host as soon as the host runs more VMs than the modulo has
# values. The unit of a job is executor*3+slot, so every VM of every
# job has a unit of its own. The multiplier is the number of the slots
# of a job: the profile both uses the slots 0, 1 and 2, and the slot 2
# of one job may not be the slot 0 of the next one.
executor=${EXECUTOR_NUMBER:-}
case $executor in
'' | *[!0-9]*) executor=0 ;;
esac
slot=${WTFBSD_VM_SLOT:-0}
case $slot in
'' | *[!0-9]*) slot=0 ;;
esac
unit=$(( executor * 3 + slot ))

# a stable MAC per VM name, so that "addr" can find the guest again
mac_of() {
	_crc=$(printf '%s' "$1" | cksum | awk '{print $1}')
	printf '52:54:00:%02x:%02x:%02x\n' \
		$(( (_crc / 65536) % 256 )) $(( (_crc / 256) % 256 )) $(( _crc % 256 ))
}

vmdir() {
	printf '%s/%s\n' "$STATE" "$1"
}

# a reader of an earlier run still holds the null-modem open, and the
# guest then writes nothing: it is killed before a new one is started
kill_reader() { # kill_reader <name>
	_pidfile="$CONSOLE_DIR/$1.reader.pid"
	[ -f "$_pidfile" ] || return 0
	_pid=$(cat "$_pidfile" 2> /dev/null || true)
	if [ -n "$_pid" ]; then
		kill "$_pid" 2> /dev/null || true
	fi
	rm -f "$_pidfile"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

# the provider runs with the privileges of the agent, and bhyve(8), the
# null-modem and the tap need root
if [ "$(id -u)" -ne 0 ] && [ "${WTFBSD_TEST_ALLOW_NONROOT:-0}" != 1 ]; then
	die 'the bhyve provider needs root (bhyve(8), nmdm(4) and tap(4))'
fi

case $cmd in
create)
	name=${1:-}
	image=${2:-}
	[ -n "$name" ] && [ -n "$image" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	[ -f "$image" ] || die "no such image: $image"
	# bhyve parses its options at commas, so a path with a comma in it
	# would be read as two options
	case $image in
	*,*) die "the image path must not hold a comma: $image" ;;
	esac
	dir=$(vmdir "$name")
	mkdir -p "$dir"
	mac=$(mac_of "$name")
	printf '%s\n' "$mac" > "$dir/mac"

	# the unit of this VM: the null-modem pair and the tap
	NMDM_A="${NMDM_BASE}${unit}A"
	NMDM_B="${NMDM_BASE}${unit}B"
	TAP="${TAP_BASE}${unit}"

	# the artifact of the guest: an ISO is a CD-ROM, everything else is a
	# disk. An ISO is never copied: it is read-only media anyway.
	case $image in
	*.iso)
		disk=$image
		diskdev=ahci-cd
		;;
	*)
		if [ "${WTFBSD_BHYVE_DIRECT:-0}" = 1 ]; then
			disk=$image
		else
			disk="$dir/disk.img"
			cp "$image" "$disk"
		fi
		diskdev=virtio-blk
		;;
	esac

	# the serial console: the null-modem pair of the unit
	kldload nmdm > /dev/null 2>&1 || true
	_i=0
	while [ ! -c "$NMDM_A" ] && [ "$_i" -lt "$NMDM_WAIT" ]; do
		sleep 1
		_i=$((_i + 1))
	done
	if [ ! -c "$NMDM_A" ]; then
		# the suite has no device nodes: it may pass a plain file
		if [ "${WTFBSD_TEST_FAKE_NMDM:-0}" != 1 ] || [ ! -e "$NMDM_A" ]; then
			die "no $NMDM_A: the nmdm module did not provide a serial device"
		fi
	fi
	kill_reader "$name"
	: > "$dir/console.log"
	mkdir -p "$CONSOLE_DIR"
	# the reader: stty and cat share the same open file, so the device is
	# in raw mode without echo while it is read
	( stty raw -echo; exec cat ) < "$NMDM_B" > "$dir/console.log" &
	printf '%s\n' "$!" > "$CONSOLE_DIR/$name.reader.pid"

	# the tap of the guest. The device is created and brought up whether
	# or not the host has a bridge, and every step that fails is fatal:
	# bhyve(8) always wants a tap device of its own, and a guest
	# without a network is of no use to the pipeline. The device is
	# attached to the bridge only when the host has one.
	if [ -n "$TAP" ]; then
		printf '%s\n' "$TAP" > "$dir/tap"
		command -v ifconfig > /dev/null 2>&1 || die 'ifconfig is required to create the tap device of the guest'
		if ifconfig "$TAP" > /dev/null 2>&1; then
			# the device is already there: it belongs to
			# somebody else, and the provider does not
			# destroy it
			:
		else
			ifconfig "$TAP" create
			printf '%s\n' yes > "$dir/tap.created"
		fi
		ifconfig "$TAP" up || die "cannot bring the tap device $TAP up"
		if [ -n "$BRIDGE" ]; then
			ifconfig "$BRIDGE" > /dev/null 2>&1 || die "no such bridge: $BRIDGE"
			ifconfig "$BRIDGE" addm "$TAP" ||
				die "cannot attach the tap device $TAP to the bridge $BRIDGE"
			ifconfig "$BRIDGE" up
		fi
	fi

	# the guest
	set -- -c "$CPUS" -m "$MEM" -A -H -P
	if [ -n "$FIRMWARE" ]; then
		[ -f "$FIRMWARE" ] || die "no UEFI firmware at $FIRMWARE (the edk2-bhyve package provides it)"
		set -- "$@" -l bootrom,"$FIRMWARE"
	fi
	set -- "$@" -s 0:0,hostbridge
	set -- "$@" -s 1:0,"$diskdev","$disk"
	if [ -n "$TAP" ]; then
		set -- "$@" -s 2:0,virtio-net,"$TAP","$mac"
	fi
	# the serial port of the guest hangs on the LPC device
	set -- "$@" -s 31,lpc
	set -- "$@" -l com1,"$NMDM_A"
	set -- "$@" "$name"
	bhyve "$@" > "$dir/bhyve.log" 2>&1 &
	printf '%s\n' "$!" > "$dir/bhyve.pid"

	# the guest has really started: bhyve(8) creates the device of the
	# VM under /dev/vmm
	_i=0
	while [ ! -e "/dev/vmm/$name" ] && [ "$_i" -lt "$START_WAIT" ]; do
		sleep 1
		_i=$((_i + 1))
	done
	if [ ! -e "/dev/vmm/$name" ]; then
		kill "$(cat "$dir/bhyve.pid" 2> /dev/null || true)" 2> /dev/null || true
		die "bhyve did not start the VM $name (there is no /dev/vmm/$name after ${START_WAIT}s)"
	fi
	log "$PROG: started $name (console $dir/console.log, mac $mac)"
	;;
console)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	[ -f "$dir/console.log" ] || die "no console log for $name (was it created?)"
	printf '%s\n' "$dir/console.log"
	;;
unit)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	printf '%s\n' "$unit"
	;;
addr)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	[ -f "$dir/mac" ] || die "no runtime state for $name (was it created?)"
	mac=$(cat "$dir/mac")
	ip=$(arp -an 2>/dev/null | grep -i -- "$mac" | head -1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	if [ -z "$ip" ]; then
		die "no address known yet for $name (mac $mac); the guest has to talk on the network first"
	fi
	printf '%s\n' "$ip"
	;;
destroy)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	kill_reader "$name"
	if [ -f "$dir/bhyve.pid" ]; then
		pid=$(cat "$dir/bhyve.pid" 2> /dev/null || true)
		if [ -n "$pid" ]; then
			kill "$pid" 2> /dev/null || true
		fi
	fi
	# a VM that is not there any more is gone already, and the tool that
	# removes it has to be there to remove it
	if [ -e "/dev/vmm/$name" ]; then
		command -v bhyvectl > /dev/null 2>&1 || die "bhyvectl is not installed: $name cannot be destroyed"
		bhyvectl --vm="$name" --kill > /dev/null 2>&1 || true
		bhyvectl --destroy --vm="$name" > /dev/null 2>&1 || die "bhyvectl could not destroy $name"
		log "$PROG: destroyed $name"
	else
		log "$PROG: $name is not running: nothing to destroy"
	fi
	# the tap of this VM, detached from the bridge again and destroyed
	# when the provider created it
	if [ -f "$dir/tap" ]; then
		tap=$(cat "$dir/tap")
		if [ -n "$BRIDGE" ] && [ -n "$tap" ]; then
			ifconfig "$BRIDGE" deletem "$tap" > /dev/null 2>&1 || true
		fi
		# a tap that the provider created is destroyed again; a tap
		# that was already there belongs to somebody else
		if [ -f "$dir/tap.created" ]; then
			ifconfig "$tap" destroy > /dev/null 2>&1 || true
		fi
	fi
	rmrf "$dir" "$STATE"
	;;
*)
	usage
	;;
esac

exit 0
