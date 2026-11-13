#!/bin/sh
# tests/run-tests.sh — checks for the DragonFly template (POSIX sh).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Runs on any POSIX host: no root, no network, no VM, no build. Every case
# is a dry run (-n) of build.sh, a static check of the tree, or a run of
# tests/boot-test.sh against the fake provider in tests/fixtures.
#
# Usage: sh tests/run-tests.sh
# Exit status: 0 when every case passed, 1 otherwise.

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wtfbsd-dragonfly-tests.XXXXXX") || exit 1
probe="$repo/.leak-probe.tmp"
# the leak check scans the repository and names the files it finds by
# their path in the tree, so the probe file is looked for by its name
probe_name=$(basename -- "$probe")
trap 'rm -f "$probe"; rm -rf "$work"' EXIT HUP INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }

build="$repo/build.sh"
vmsh="$repo/ci/vm.sh"
boottest="$repo/tests/boot-test.sh"
fixture="$repo/tests/fixtures/examplebsd-dragonfly.product.conf"
# the desktop profile needs the installer of the live session: the suite
# uses the stand-in of tests/fixtures (a case below checks the refusal without)
INSTALLER_DIR="$repo/tests/fixtures/fake-installer-template"
export INSTALLER_DIR
unset INSTALLER_REF INSTALLER_REPO
# the branding of the desktop: packs of the stand-in artwork template, in
# the layout of scripts/pack.sh of the artwork template (PACK, out/, ...)
WTFBSD_BUILD_DATE=2026-11-01
ARTREF=5aaea01b082938f3c6816cd5b881699e62d3d9dd
mkpack() { # mkpack <variant> <dir> [slug] — a pack of the stand-in, and its .sha256; prints its path
	_mp_n="${3:-examplebsd}-$(printf '%.12s' "$ARTREF")-$1"
	rm -rf "$2/$_mp_n"
	mkdir -p "$2/$_mp_n"
	cp -R "$repo/tests/fixtures/fake-artwork/." "$2/$_mp_n/"
	sh "$repo/tests/fixtures/fake-artwork/scripts/make-out.sh" "$2/$_mp_n/out" "${3:-examplebsd}" ExampleBSD "$1"
	printf 'name=%s\ncommit=%s\nvariant=%s\n' "${3:-examplebsd}" "$(printf '%.12s' "$ARTREF")" "$1" > "$2/$_mp_n/PACK"
	(cd "$2" && tar -cf - "$_mp_n" | xz -1 > "$_mp_n.tar.xz")
	(cd "$2" && sha256sum "$_mp_n.tar.xz" > "$_mp_n.tar.xz.sha256" 2>/dev/null ||
		printf '%s  %s\n' "$(sha256 -q "$_mp_n.tar.xz")" "$_mp_n.tar.xz" > "$_mp_n.tar.xz.sha256")
	rm -rf "$2/$_mp_n"
	printf '%s\n' "$2/$_mp_n.tar.xz"
}
mkdir -p "$work/packs"
ARTWORK_PACK=$(mkpack default "$work/packs")
# the packs of the stand-in are not the published ones: the suite pins
# nothing by default (the cases about the pins name tools/artwork-packs.sha256)
: > "$work/no-pins.sha256"
ARTWORK_PACKS_SHA256="$work/no-pins.sha256"
export ARTWORK_PACK WTFBSD_BUILD_DATE ARTWORK_PACKS_SHA256
unset ARTWORK_REF ARTWORK_REPO ARTWORK_DIR

# --------------------------------------------------------------------------
# (a) the DragonFly example as product.conf
# --------------------------------------------------------------------------
cp "$fixture" "$work/dragonfly.conf"
sh "$build" -n -c "$work/dragonfly.conf" -o "$work/out" --no-user > "$work/log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "(a) the DragonFly example product.conf passes the dry run"
else
	no "(a) the DragonFly example product.conf passes the dry run (rc=$rc)"
	sed 's/^/      | /' "$work/log"
fi

plan_ok=0
[ "$rc" -eq 0 ] && plan_ok=1
for case_spec in 'buildworld1:the world is built by the release tooling of nrelease' \
	'nrelease:the media come from nrelease' \
	'rootskels:the overlay is copied over the release root' \
	'DPORTS_EXTRA_PACKAGES:the packages are handed to the release tooling'; do
	pat=${case_spec%%:*}
	what=${case_spec#*:}
	if [ "$plan_ok" -eq 1 ] && grep -q -- "$pat" "$work/log"; then
		ok "(a) the plan shows $what"
	else
		no "(a) the plan shows $what"
	fi
done
if [ "$plan_ok" -eq 1 ] && grep -qi 'zfs' "$work/log"; then
	no "(a) the plan never mentions ZFS"
	sed 's/^/      | /' "$work/log"
else
	ok "(a) the plan never mentions ZFS"
fi

# --------------------------------------------------------------------------
# (b) FILESYSTEM_ROOT=zfs is refused, with the honest explanation
# --------------------------------------------------------------------------
sed "s/^FILESYSTEM_ROOT=.*/FILESYSTEM_ROOT='zfs'/" "$fixture" > "$work/zfsroot.conf"
sh "$build" -n -c "$work/zfsroot.conf" -o "$work/out" > "$work/zfsroot.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'HAMMER2' "$work/zfsroot.log" && grep -qi 'No ZFS' "$work/zfsroot.log"; then
	ok "(b) FILESYSTEM_ROOT=zfs is refused with the DragonFly honesty text"
else
	no "(b) FILESYSTEM_ROOT=zfs is refused with the DragonFly honesty text (rc=$rc)"
	sed 's/^/      | /' "$work/zfsroot.log"
fi

# --------------------------------------------------------------------------
# (c) ZFS_DATA_POOL=yes is refused: DragonFly has no ZFS at all
# --------------------------------------------------------------------------
sed "s/^ZFS_DATA_POOL=.*/ZFS_DATA_POOL='yes'/" "$fixture" > "$work/zfsdp.conf"
sh "$build" -n -c "$work/zfsdp.conf" -o "$work/out" > "$work/zfsdp.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ZFS_DATA_POOL' "$work/zfsdp.log" && grep -qi 'No ZFS' "$work/zfsdp.log"; then
	ok "(c) ZFS_DATA_POOL=yes is refused with the DragonFly honesty text"
else
	no "(c) ZFS_DATA_POOL=yes is refused with the DragonFly honesty text (rc=$rc)"
	sed 's/^/      | /' "$work/zfsdp.log"
fi

# --------------------------------------------------------------------------
# (d) DISTRO_OS other than dragonfly is refused
# --------------------------------------------------------------------------
sed "s/^DISTRO_OS=.*/DISTRO_OS='netbsd'/" "$fixture" > "$work/os.conf"
sh "$build" -n -c "$work/os.conf" -o "$work/out" > "$work/os.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'DISTRO_OS' "$work/os.log" && grep -qi 'dragonfly' "$work/os.log"; then
	ok "(d) DISTRO_OS=netbsd is refused"
else
	no "(d) DISTRO_OS=netbsd is refused (rc=$rc)"
	sed 's/^/      | /' "$work/os.log"
fi

# --------------------------------------------------------------------------
# (e) a command substitution in MOTD is data, never code
# --------------------------------------------------------------------------
sed "s|^MOTD=.*|MOTD='x\$(touch $work/pwned)'|" "$fixture" > "$work/inj.conf"
sh "$build" -n -c "$work/inj.conf" -o "$work/out" > "$work/inj.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'MOTD' "$work/inj.log"; then
	ok "(e) a command substitution in MOTD is refused"
else
	no "(e) a command substitution in MOTD is refused (rc=$rc)"
	sed 's/^/      | /' "$work/inj.log"
fi
if [ "$rc" -ne 0 ] && grep -q 'MOTD' "$work/inj.log" && [ ! -e "$work/pwned" ]; then
	ok "(e) nothing was executed"
else
	no "(e) nothing was executed"
fi

# --------------------------------------------------------------------------
# (f) an unknown profile is refused
# --------------------------------------------------------------------------
sh "$build" -n -c "$fixture" -p server -o "$work/out" > "$work/prof.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'profile' "$work/prof.log"; then
	ok "(f) an unknown -p profile is refused"
else
	no "(f) an unknown -p profile is refused (rc=$rc)"
	sed 's/^/      | /' "$work/prof.log"
fi

# --------------------------------------------------------------------------
# (g) no file under overlay/ mentions the forbidden wireless driver
# --------------------------------------------------------------------------
# The token is assembled at run time so that this script does not contain
# the string it forbids.
driver=$(printf 'mt%s' '76')
if grep -rni -- "$driver" "$repo/overlay" > "$work/driver.log" 2>&1; then
	no "(g) no file under overlay/ mentions the forbidden driver"
	sed 's/^/      | /' "$work/driver.log"
else
	ok "(g) no file under overlay/ mentions the forbidden driver"
fi

# --------------------------------------------------------------------------
# (h) ci/vm.sh fails closed on an unknown or missing provider
# --------------------------------------------------------------------------
WTFBSD_VM_PROVIDER=nosuchprovider sh "$vmsh" create vm1 "$work/image.img" > "$work/vm.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'nosuchprovider' "$work/vm.log"; then
	ok "(h) ci/vm.sh fails closed on an unknown provider"
else
	no "(h) ci/vm.sh fails closed on an unknown provider (rc=$rc)"
	sed 's/^/      | /' "$work/vm.log"
fi
(
	unset WTFBSD_VM_PROVIDER
	unset WTFBSD_VM_PROVIDER_PATH
	sh "$vmsh" create vm1 "$work/image.img"
) > "$work/vmnone.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'WTFBSD_VM_PROVIDER' "$work/vmnone.log"; then
	ok "(h) ci/vm.sh fails closed when no provider is set"
else
	no "(h) ci/vm.sh fails closed when no provider is set (rc=$rc)"
	sed 's/^/      | /' "$work/vmnone.log"
fi

# --------------------------------------------------------------------------
# (i) tests/boot-test.sh against the fake provider
# --------------------------------------------------------------------------
: > "$work/image.img"
sshport=''
p=21000
while [ "$p" -lt 21200 ]; do
	if ! nc -z 127.0.0.1 "$p" > /dev/null 2>&1; then
		sshport=$p
		break
	fi
	p=$((p + 1))
done
if [ -z "$sshport" ]; then
	no "(i) a free loopback port for the ssh probe was found"
else
	WTFBSD_VM_PROVIDER=fake
	WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh"
	WTFBSD_FAKE_STATE="$work/state1"
	WTFBSD_FAKE_LOG="$work/serial1.log"
	WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log"
	WTFBSD_FAKE_ADDR=127.0.0.1
	WTFBSD_FAKE_SSH_PORT=$sshport
	WTFBSD_BOOT_TIMEOUT=20
	WTFBSD_BOOT_SSH_PORT=$sshport
	export WTFBSD_VM_PROVIDER WTFBSD_VM_PROVIDER_PATH WTFBSD_FAKE_STATE \
		WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_FAKE_ADDR \
		WTFBSD_FAKE_SSH_PORT WTFBSD_BOOT_TIMEOUT WTFBSD_BOOT_SSH_PORT

	sh "$boottest" "$work/image.img" appliance > "$work/boot.log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "(i) the boot test passes when the console shows a login prompt"
	else
		no "(i) the boot test passes when the console shows a login prompt (rc=$rc)"
		sed 's/^/      | /' "$work/boot.log"
	fi
	if grep -q '^destroy' "$work/state1" 2>/dev/null; then
		ok "(i) the VM is destroyed after a successful boot test"
	else
		no "(i) the VM is destroyed after a successful boot test"
	fi

	# the same transcript, cut before the login prompt: the boot test must
	# time out, fail, and still destroy the VM
	sed '/login:/,$d' "$repo/tests/fixtures/serial-login.log" > "$work/no-login.log"
	WTFBSD_FAKE_STATE="$work/state2"
	WTFBSD_FAKE_LOG="$work/serial2.log"
	WTFBSD_FAKE_SOURCE_LOG="$work/no-login.log"
	WTFBSD_BOOT_TIMEOUT=5
	export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_BOOT_TIMEOUT
	sh "$boottest" "$work/image.img" appliance > "$work/boot2.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		ok "(i) the boot test fails when the login prompt never appears"
	else
		no "(i) the boot test fails when the login prompt never appears (rc=0)"
		sed 's/^/      | /' "$work/boot2.log"
	fi
	if grep -q '^destroy' "$work/state2" 2>/dev/null; then
		ok "(i) the VM is destroyed after a failed boot test"
	else
		no "(i) the VM is destroyed after a failed boot test"
	fi
	# the listener of the fake guest is stopped with the VM: the nc of
	# the listener is a child of the loop of the listener, and it has to
	# be stopped as well, or it stays behind and keeps the port
	if ! command -v pgrep > /dev/null 2>&1; then
		skip "(i) the listener of the fake guest is stopped with the VM (no pgrep)"
	elif pgrep -f "nc -l 127.0.0.1 $sshport" > /dev/null 2>&1; then
		no "(i) the listener of the fake guest is stopped with the VM"
		pgrep -af "nc -l 127.0.0.1 $sshport" 2> /dev/null | sed 's/^/      | /'
	else
		ok "(i) the listener of the fake guest is stopped with the VM"
	fi
fi

# --------------------------------------------------------------------------
# the stand-ins for the tools of a FreeBSD host, for the bhyve provider
# --------------------------------------------------------------------------
# bhyve(8), bhyvectl(8), ifconfig(8) and arp(8) only log their arguments,
# so that the case can say what the provider really asked for.
fakehost() {
	mkdir -p "$work/fakehost/bin" "$work/fakehost/nmdm"
	cat > "$work/fakehost/bin/bhyve" <<'FAKEBHYVE'
#!/bin/sh
printf 'bhyve %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKEBHYVE
	cat > "$work/fakehost/bin/bhyvectl" <<'FAKEBHYVECTL'
#!/bin/sh
printf 'bhyvectl %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKEBHYVECTL
	cat > "$work/fakehost/bin/ifconfig" <<'FAKEIFCONFIG'
#!/bin/sh
printf 'ifconfig %s\n' "$*" >> "$FAKE_LOG"
# a bare "ifconfig <device>" asks whether the device is there: the fake
# host has no tap device, so the answer is no and the provider has to
# create one
if [ $# -eq 1 ]; then
	case $1 in
	*tap*) exit 1 ;;
	esac
fi
exit 0
FAKEIFCONFIG
	cat > "$work/fakehost/bin/arp" <<'FAKEARP'
#!/bin/sh
printf 'arp %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKEARP
	chmod 755 "$work/fakehost/bin/"*
	# the null-modem pair of every unit the provider may pick: the unit
	# follows the executor and the slot of the VM, and it starts at 0
	_u=0
	while [ "$_u" -le 90 ]; do
		: > "$work/fakehost/nmdm/${_u}A"
		: > "$work/fakehost/nmdm/${_u}B"
		_u=$((_u + 1))
	done
}

# --------------------------------------------------------------------------
# (A0) the real build path, driven through the stand-ins in tests/stubs
# --------------------------------------------------------------------------
# The dry run only prints a plan: it proves nothing about the build. This
# case runs build.sh for real against a fake source tree, with the
# stand-ins of tests/stubs in the PATH, and checks what the build did.
realout=''
realrc=0
realbuild() { # realbuild <workdir> [more build.sh arguments] — run the real
	# build; sets $realrc/$realout. The profile comes from $REAL_PROFILE
	# (default: appliance) and every path is absolute, so that the plan
	# of the dry run and the commands of the real run can be compared.
	# $REAL_SRC_EXTRA, when set, is a directory copied over the fake
	# source tree (a file added to the skeleton of the release root);
	# $REAL_XTRACE=1 runs build.sh under sh -x, so that the transcript
	# shows the argv of every command of the real path;
	# $REAL_PATH_PREFIX, when set, is put before the stand-ins on PATH.
	_rb_w=$1
	shift
	rm -rf "$_rb_w/src" "$_rb_w/out" "$_rb_w/release" "$_rb_w/dports"
	mkdir -p "$_rb_w/src" "$_rb_w/release" "$_rb_w/dports"
	cp -R "$repo/tests/fixtures/fake-src/." "$_rb_w/src/"
	if [ -n "${REAL_SRC_EXTRA:-}" ]; then
		cp -R "$REAL_SRC_EXTRA/." "$_rb_w/src/"
	fi
	_rb_x=+x
	[ "${REAL_XTRACE:-0}" = 1 ] && _rb_x=-x
	: > "$_rb_w/stub.log"
	_rb_args="$*"
	case " $_rb_args " in
	*' -u '*) ;;
	*) _rb_args="$_rb_args --no-user" ;;
	esac
	# shellcheck disable=SC2086
	(
		cd "$_rb_w" || exit 1
		[ "${REAL_NO_PACK:-0}" = 1 ] && unset ARTWORK_PACK
		PATH="${REAL_PATH_PREFIX:+$REAL_PATH_PREFIX:}$repo/tests/stubs:$PATH" \
		STUB_LOG="$_rb_w/stub.log" \
		WTFBSD_TEST_ALLOW_ANY_OS=1 \
		WTFBSD_TEST_ALLOW_NONROOT=1 \
		DPORTS_PATH="$_rb_w/dports" \
			sh "$_rb_x" "$build" -c "${REAL_CONF:-$fixture}" -s "$_rb_w/src" -o "$_rb_w/out" \
			-p "${REAL_PROFILE:-appliance}" $_rb_args
	) > "$_rb_w/build.log" 2>&1
	realrc=$?
	realout="$_rb_w/out"
}

realbuild "$work/real"
stublog="$work/real/stub.log"
if [ "$realrc" -eq 0 ]; then
	ok "(A0) the real build path runs end to end"
else
	no "(A0) the real build path runs end to end (rc=$realrc)"
	sed 's/^/      | /' "$work/real/build.log"
fi

if grep -q '^CMD make .*buildworld1' "$stublog" 2>/dev/null; then
	ok "(A0) the real build runs the world build of nrelease (the world is built by it)"
else
	no "(A0) the real build runs the world build of nrelease (the world is built by it)"
	sed 's/^/      | /' "$stublog"
fi

if grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*ca_root_nss' "$stublog" 2>/dev/null; then
	ok "(A0) the real build hands the DPorts packages of the overlay to nrelease"
else
	no "(A0) the real build hands the DPorts packages of the overlay to nrelease"
	sed 's/^/      | /' "$stublog"
fi

if grep -q '^CMD make .*mkiso' "$stublog" 2>/dev/null &&
	grep -q '^CMD make .*mkimg' "$stublog" 2>/dev/null; then
	ok "(A0) the real build runs the image step of nrelease"
else
	no "(A0) the real build runs the image step of nrelease"
	sed 's/^/      | /' "$stublog"
fi

stage="$realout/appliance/root"
if [ -f "$stage/etc/rc.conf" ] &&
	grep -q '^sshd_enable="YES"$' "$stage/etc/rc.conf" &&
	grep -q '^hostname="examplebsd"$' "$stage/etc/rc.conf"; then
	ok "(A0) the staged rc.conf holds the variables of the overlay"
else
	no "(A0) the staged rc.conf holds the variables of the overlay"
	sed 's/^/      | /' "$stage/etc/rc.conf" 2>/dev/null
fi

if [ -f "$stage/etc/motd" ] && grep -q 'ExampleBSD' "$stage/etc/motd"; then
	ok "(A0) the staged motd holds the substituted product name"
else
	no "(A0) the staged motd holds the substituted product name"
fi

if [ -f "$stage/usr/local/sbin/examplebsd-info" ]; then
	ok "(A0) the staged overlay file whose name holds the slug is renamed"
else
	no "(A0) the staged overlay file whose name holds the slug is renamed"
fi

if [ -f "$realout/appliance/examplebsd-appliance-amd64.img" ] &&
	[ -f "$realout/appliance/examplebsd-appliance-amd64.iso" ] &&
	[ -f "$realout/SHA256" ]; then
	ok "(A0) the real build produces the media and its checksum"
else
	no "(A0) the real build produces the media and its checksum"
	ls -R "$realout" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (A1) the output directory is absolute once the build runs
# --------------------------------------------------------------------------
art=$(cat "$realout/appliance/ARTIFACT" 2>/dev/null || true)
case $art in
/*) ok "(A1) the artifact path of the real build is absolute" ;;
*) no "(A1) the artifact path of the real build is absolute (got: ${art:-<none>})" ;;
esac
if grep -q "^  $realout/" "$work/real/build.log" 2>/dev/null; then
	ok "(A1) the real build prints the absolute artifact paths"
else
	no "(A1) the real build prints the absolute artifact paths"
	sed 's/^/      | /' "$work/real/build.log"
fi

# --------------------------------------------------------------------------
# (A2) root is locked in the staged master password file
# --------------------------------------------------------------------------
mpw="$stage/etc/master.passwd"
if [ -f "$mpw" ]; then
	mpwroot=$(awk -F: '$1 == "root" { print $2 }' "$mpw")
	if [ "$mpwroot" = '*' ]; then
		ok "(A2) the root password field of the staged master.passwd is locked"
	else
		no "(A2) the root password field of the staged master.passwd is locked (got: ${mpwroot:-<none>})"
	fi
	case $(ls -l "$mpw") in
	-rw-------*) ok "(A2) the staged master.passwd is readable by root only" ;;
	*) no "(A2) the staged master.passwd is readable by root only" ;;
	esac
	mpwother=$(awk -F: '$1 == "nobody" { print $2 }' "$mpw")
	if [ "$mpwother" = '*' ]; then
		ok "(A2) the other accounts of the staged master.passwd are untouched"
	else
		no "(A2) the other accounts of the staged master.passwd are untouched (got: ${mpwother:-<none>})"
	fi
else
	no "(A2) the staged release root holds a master.passwd"
fi
if grep -q "^CMD pwd_mkdb -p -d $stage/etc $stage/etc/master.passwd\$" "$stublog" 2>/dev/null; then
	ok "(A2) the build rebuilds the password database from the staged file"
else
	no "(A2) the build rebuilds the password database from the staged file"
	sed 's/^/      | /' "$stublog"
fi
if grep -q '^CMD passwd ' "$stublog" 2>/dev/null; then
	no "(A2) the build does not ask passwd(8) to lock the root account"
	sed 's/^/      | /' "$stublog"
else
	ok "(A2) the build does not ask passwd(8) to lock the root account"
fi

# --------------------------------------------------------------------------
# (A3) every path of the overlay gets the owner and the mode of a system
#      file, and no system tree is ever chowned recursively
# --------------------------------------------------------------------------
if grep -q 'cp -Rp' "$repo/build.sh"; then
	no "(A3) the overlay is copied without preserving the modes of the checkout"
else
	ok "(A3) the overlay is copied without preserving the modes of the checkout"
fi
a3bad=''
sk="$realout/appliance/rootskels"
for ovr in overlay/base/rootfs overlay/profiles/appliance/rootfs; do
	(cd "$repo/$ovr" && find . \( -type f -o -type d \)) | sed 's|^\./||' > "$work/a3.list"
	while IFS= read -r rel; do
		case $rel in '' | .) continue ;; esac
		t="$sk/$rel"
		grep -q "^CMD chown root:wheel $t\$" "$stublog" 2>/dev/null ||
			a3bad="$a3bad owner:$rel"
		grep -Eq "^CMD chmod (755|644) $t\$" "$stublog" 2>/dev/null ||
			a3bad="$a3bad mode:$rel"
	done < "$work/a3.list"
done
if [ -z "$a3bad" ]; then
	ok "(A3) every path of the overlay is owned by root:wheel with a system mode"
else
	no "(A3) every path of the overlay is owned by root:wheel with a system mode:$a3bad"
fi
case $(ls -l "$stage/etc/ssh/sshd_config" 2>/dev/null) in
-rw-r--r--*) ok "(A3) a staged configuration file is 0644" ;;
*) no "(A3) a staged configuration file is 0644" ;;
esac
if grep -q '^CMD chown -R ' "$stublog" 2>/dev/null; then
	no "(A3) no system tree is ever chowned recursively"
	grep '^CMD chown -R ' "$stublog" | sed 's/^/      | /'
else
	ok "(A3) no system tree is ever chowned recursively"
fi

# --------------------------------------------------------------------------
# (A4) the substitution keeps the exec bit of the file it rewrites
# --------------------------------------------------------------------------
case $(ls -l "$stage/usr/local/sbin/examplebsd-info" 2>/dev/null) in
-rwxr-xr-x*) ok "(A4) a substituted overlay script stays executable" ;;
*) no "(A4) a substituted overlay script stays executable" ;;
esac
if grep -q '@SLUG@' "$stage/usr/local/sbin/examplebsd-info" 2>/dev/null; then
	no "(A4) the substituted overlay script holds no placeholder any more"
else
	ok "(A4) the substituted overlay script holds no placeholder any more"
fi

# --------------------------------------------------------------------------
# (A5) the real build refuses to run as a user that is not root
# --------------------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
	skip "(A5) the real build refuses to run as a user that is not root (the suite runs as root)"
else
	rm -rf "$work/noroot/src" "$work/noroot/out" "$work/noroot/release"
	mkdir -p "$work/noroot/src" "$work/noroot/release"
	cp -R "$repo/tests/fixtures/fake-src/." "$work/noroot/src/"
	(
		cd "$work/noroot" || exit 1
		PATH="$repo/tests/stubs:$PATH" \
		STUB_LOG="$work/noroot/stub.log" \
		WTFBSD_DF_RELEASEDIR="$work/noroot/release" \
		WTFBSD_TEST_ALLOW_ANY_OS=1 \
			sh "$build" -c "$fixture" -s src -o out -p appliance --no-user
	) > "$work/noroot/build.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && grep -qi 'root' "$work/noroot/build.log"; then
		ok "(A5) the real build refuses to run as a user that is not root"
	else
		no "(A5) the real build refuses to run as a user that is not root (rc=$rc)"
		sed 's/^/      | /' "$work/noroot/build.log"
	fi
fi

# --------------------------------------------------------------------------
# (A6) the first-boot user: the account and its keys are baked into the
#      image and provisioned on the first boot
# --------------------------------------------------------------------------
printf '%s %s%s\n' 'ssh-ed25519' 'AAAA' \
	'C3NzaC1lZDI1NTE5AAAAITestKeyOfTheTestSuiteOnly testkey' > "$work/ci.pub"
realbuild "$work/fb" -u ciuser -k "$work/ci.pub"
fbconf="$work/fb/out/appliance/root/boot/firstboot-user.conf"
if [ "$realrc" -eq 0 ] && [ -f "$fbconf" ]; then
	ok "(A6) the build bakes the first-boot configuration into the image"
else
	no "(A6) the build bakes the first-boot configuration into the image (rc=$realrc)"
	sed 's/^/      | /' "$work/fb/build.log"
fi
if grep -q '^USERNAME=ciuser$' "$fbconf" 2>/dev/null &&
	grep -q '^SSH_KEY=ssh-ed25519 ' "$fbconf" 2>/dev/null; then
	ok "(A6) the first-boot configuration holds the user and the key"
else
	no "(A6) the first-boot configuration holds the user and the key"
	sed 's/^/      | /' "$fbconf" 2>/dev/null
fi
case $(ls -l "$fbconf" 2>/dev/null) in
-rw-------*) ok "(A6) the first-boot configuration is readable by root only" ;;
*) no "(A6) the first-boot configuration is readable by root only" ;;
esac
if [ -x "$stage/etc/rc.d/firstboot_user" ]; then
	ok "(A6) the first-boot script of the overlay is executable in the image"
else
	no "(A6) the first-boot script of the overlay is executable in the image"
fi
fbscript="$repo/overlay/base/rootfs/etc/rc.d/firstboot_user"
if grep -q '^# PROVIDE: firstboot_user$' "$fbscript" &&
	grep -q '^# BEFORE: LOGIN$' "$fbscript" &&
	grep -q '^# KEYWORD:.*nojail' "$fbscript"; then
	ok "(A6) the first-boot script declares its place in the boot order"
else
	no "(A6) the first-boot script declares its place in the boot order"
fi
sh "$build" -n -c "$fixture" -u 'Bad User' -o "$work/out" > "$work/fbuser.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(A6) an invalid first-boot user name is refused"
else
	no "(A6) an invalid first-boot user name is refused"
fi
sh "$build" -n -c "$fixture" -k "$work/ci.pub" -o "$work/out" > "$work/fbkey.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(A6) a key file without a user is refused"
else
	no "(A6) a key file without a user is refused"
fi

# --------------------------------------------------------------------------
# (A7) the free-text parameters of the pipeline are validated and quoted
# --------------------------------------------------------------------------
if AGENT_LABEL=builder VM_PROVIDER=bhyve BUILD_VM_NAME=build-1 \
	BUILD_VM_IMAGE=/srv/images/dfly.img BUILD_VM_WORKDIR=wtfbsd-template \
	PRODUCT_CONF=product.conf sh "$repo/ci/validate-params.sh" > "$work/params.log" 2>&1; then
	ok "(A7) the pipeline accepts valid parameters"
else
	no "(A7) the pipeline accepts valid parameters"
	sed 's/^/      | /' "$work/params.log"
fi
for p in 'BUILD_VM_NAME=bad name' 'BUILD_VM_NAME=x;id' 'BUILD_VM_WORKDIR=a b' \
	'PRODUCT_CONF=a$b' 'VM_PROVIDER=bhyve|id'; do
	k=${p%%=*}
	v=${p#*=}
	if (
		export AGENT_LABEL=builder VM_PROVIDER=bhyve BUILD_VM_NAME=build-1
		export BUILD_VM_IMAGE=/srv/images/dfly.img
		export BUILD_VM_WORKDIR=wtfbsd-template PRODUCT_CONF=product.conf
		export "$k=$v"
		sh "$repo/ci/validate-params.sh"
	) > "$work/params.log" 2>&1; then
		no "(A7) the pipeline refuses the parameter $k"
		sed 's/^/      | /' "$work/params.log"
	else
		ok "(A7) the pipeline refuses the parameter $k"
	fi
done
if AGENT_LABEL=builder VM_PROVIDER=bhyve BUILD_VM_NAME=build-1 \
	BUILD_VM_WORKDIR=wtfbsd-template PRODUCT_CONF=product.conf \
	sh "$repo/ci/validate-params.sh" > "$work/params.log" 2>&1; then
	no "(A7) the image of the build VM is required when the build runs in a VM"
else
	ok "(A7) the image of the build VM is required when the build runs in a VM"
fi
if grep -q 'ci/validate-params.sh' "$repo/Jenkinsfile"; then
	ok "(A7) the Validate stage of the pipeline checks the parameters"
else
	no "(A7) the Validate stage of the pipeline checks the parameters"
fi
if grep -q "'\$BUILD_VM_WORKDIR'" "$repo/Jenkinsfile" &&
	grep -q "'\$PROFILE'" "$repo/Jenkinsfile"; then
	ok "(A7) the remote commands of the pipeline quote their parameters"
else
	no "(A7) the remote commands of the pipeline quote their parameters"
fi

# --------------------------------------------------------------------------
# (B) the CI: the serial console, the VM names, the boot test, the
#     provider and the pipeline
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# (B1) the provider writes the serial console into a file the boot test
#      can read, and it records the reader of that file
# --------------------------------------------------------------------------
fakehost
: > "$work/media.iso"
: > "$work/fake.log"
FAKE_LOG="$work/fake.log" \
	PATH="$work/fakehost/bin:$PATH" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	WTFBSD_BHYVE_STATE="$work/fakehost/state" \
	WTFBSD_BHYVE_FIRMWARE='' \
	WTFBSD_BHYVE_NMDM_BASE="$work/fakehost/nmdm/" \
	WTFBSD_BHYVE_TAP_BASE="$work/fakehost/tap" \
	WTFBSD_BHYVE_BRIDGE=bridge0 \
	WTFBSD_TEST_FAKE_NMDM=1 \
	WTFBSD_BHYVE_START_WAIT=1 \
	WTFBSD_BHYVE_NMDM_WAIT=0 \
	sh "$repo/ci/providers/bhyve.sh" create vm-console "$work/media.iso" \
	> "$work/bhyve1.log" 2>&1
if [ -f "$work/fakehost/state/vm-console/console.log" ] &&
	[ -f "$work/fakehost/state/vm-console.reader.pid" ]; then
	ok "(B1) the provider writes the serial console into a file and records its reader"
else
	no "(B1) the provider writes the serial console into a file and records its reader)"
	ls -R "$work/fakehost/state" 2>/dev/null | sed 's/^/      | /'
	sed 's/^/      | /' "$work/bhyve1.log"
fi

# (B9) the provider runs as root and keeps the state of the VMs in a
#      directory. A fixed name in a shared temporary directory can be
#      made first by another user, or be a symbolic link that user
#      planted, and so can any directory above it: root would then write
#      and remove where that user says. The default is a directory of
#      root; a state directory that is a symbolic link, sits below a link
#      root does not own or below a directory others can write to, or is
#      writable by others itself, is refused; a new one is made 0700.
#      Every case runs the provider itself.
_sd="$work/statedir"
rm -rf "$_sd"
mkdir -p "$_sd/bin" "$_sd/target/victim" "$_sd/elsewhere/state/victim" "$_sd/openparent/state/victim" \
	"$_sd/openself/victim"
: > "$_sd/target/victim/keep"
: > "$_sd/elsewhere/state/victim/keep"
: > "$_sd/openparent/state/victim/keep"
: > "$_sd/openself/victim/keep"
: > "$_sd/image.img"
: > "$_sd/firmware.fd"
chmod 700 "$_sd/elsewhere/state" "$_sd/openparent/state"
chmod 777 "$_sd/openparent" "$_sd/openself"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$_sd/bin/id"
for _sdt in ifconfig sleep bhyve bhyvectl kldstat kldload; do
	printf '#!/bin/sh\nexit 0\n' > "$_sd/bin/$_sdt"
done
chmod 755 "$_sd/bin/"*
ln -s "$_sd/target" "$_sd/link"
ln -s "$_sd/elsewhere" "$_sd/plink"
_sdrun() { # _sdrun <log> <state dir> <command> <args...> — run the provider once
	_sdlog=$1 _sddir=$2
	shift 2
	WTFBSD_TEST_ALLOW_NONROOT=1 WTFBSD_BHYVE_NMDM_WAIT=0 WTFBSD_BHYVE_NMDM_BASE="$_sd/nonmdm/" PATH="$_sd/bin:$PATH" WTFBSD_BHYVE_STATE="$_sddir" WTFBSD_BHYVE_CONSOLE="$_sddir" \
		sh "$repo/ci/providers/bhyve.sh" "$@" > "$_sdlog" 2>&1
	_sdrc=$?
}
_sdrun "$_sd/link.log" "$_sd/link" destroy victim
if [ "$_sdrc" -ne 0 ] && [ -f "$_sd/target/victim/keep" ] && grep -q 'it is a symbolic link' "$_sd/link.log"; then
	ok "(B9) the provider refuses a state directory that is a symbolic link, and removes nothing through it"
else
	no "(B9) the provider refuses a state directory that is a symbolic link, and removes nothing through it (rc=$_sdrc)"
	sed 's/^/      | /' "$_sd/link.log"
fi
_sdrun "$_sd/plink.log" "$_sd/plink/state" destroy victim
if [ "$_sdrc" -ne 0 ] && [ -f "$_sd/elsewhere/state/victim/keep" ] &&
	grep -q 'plink is a symbolic link that root does not own' "$_sd/plink.log"; then
	ok "(B9) the provider refuses a state directory below a symbolic link root does not own, and removes nothing through it"
else
	no "(B9) the provider refuses a state directory below a symbolic link root does not own, and removes nothing through it (rc=$_sdrc)"
	sed 's/^/      | /' "$_sd/plink.log"
fi
_sdrun "$_sd/openparent.log" "$_sd/openparent/state" destroy victim
if [ "$_sdrc" -ne 0 ] && [ -f "$_sd/openparent/state/victim/keep" ] &&
	grep -q 'others can write to .*/openparent$' "$_sd/openparent.log"; then
	ok "(B9) the provider refuses a state directory below a directory others can write to"
else
	no "(B9) the provider refuses a state directory below a directory others can write to (rc=$_sdrc)"
	sed 's/^/      | /' "$_sd/openparent.log"
fi
_sdrun "$_sd/openself.log" "$_sd/openself" destroy victim
if [ "$_sdrc" -ne 0 ] && [ -f "$_sd/openself/victim/keep" ] && grep -q 'others can write to it' "$_sd/openself.log"; then
	ok "(B9) the provider refuses a state directory others can write to"
else
	no "(B9) the provider refuses a state directory others can write to (rc=$_sdrc)"
	sed 's/^/      | /' "$_sd/openself.log"
fi
# create makes a new state directory 0700 (the run stops later, at the
# serial device the test host does not have)
_sdrun "$_sd/new.log" "$_sd/new/state" create probe "$_sd/image.img"
_sdmode=$(ls -ld "$_sd/new/state" 2> /dev/null | cut -c1-10)
if [ "$_sdmode" = 'drwx------' ]; then
	ok "(B9) a new state directory of the provider is made 0700"
else
	no "(B9) a new state directory of the provider is made 0700 (got: $_sdmode)"
	sed 's/^/      | /' "$_sd/new.log"
fi
if grep -q '/var/db/wtfbsd-vm' "$repo/ci/providers/bhyve.sh" && ! grep -q '/var/tmp/wtfbsd-vm' "$repo/ci/providers/bhyve.sh"; then
	ok "(B9) the default state directory of the provider is a directory of root, not in /var/tmp"
else
	no "(B9) the default state directory of the provider is a directory of root, not in /var/tmp"
fi

# (B2) the boot test takes the name of the VM, the pipeline lists the VMs
#      and destroys every name of the list
WTFBSD_FAKE_STATE="$work/state6"
WTFBSD_FAKE_LOG="$work/serial6.log"
WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log"
export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG
sh "$boottest" "$work/image.img" desktop my-vm-name > "$work/boot6.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^create my-vm-name ' "$work/state6" 2>/dev/null; then
	ok "(B2) the boot test uses the name of the VM it is given"
else
	no "(B2) the boot test uses the name of the VM it is given (rc=$rc)"
	sed 's/^/      | /' "$work/boot6.log"
fi
if grep -q '\.vm/vmlist' "$repo/Jenkinsfile" &&
	grep -q "boot-\${p}-" "$repo/Jenkinsfile" &&
	grep -q 'sh tests/boot-test.sh' "$repo/Jenkinsfile"; then
	ok "(B2) the pipeline names the boot test VM and writes it into the list"
else
	no "(B2) the pipeline names the boot test VM and writes it into the list"
fi
if grep -q ': > .vm/vmlist' "$repo/Jenkinsfile" &&
	grep -q 'while IFS= read -r vm' "$repo/Jenkinsfile"; then
	ok "(B2) the pipeline empties the list at the start and destroys every name of it"
else
	no "(B2) the pipeline empties the list at the start and destroys every name of it"
fi

# (B3) the pipeline copies the product configuration to the build directory
#      of the guest and uses safe options for every ssh and scp
if grep -q 'scp .*product.conf "\$addr:\$BUILD_VM_WORKDIR/product.conf"' \
	"$repo/Jenkinsfile"; then
	ok "(B3) the pipeline copies the product configuration into the build VM"
else
	no "(B3) the pipeline copies the product configuration into the build VM"
fi
b3bad=''
nsh=$(grep -c 'ssh \$SSH_OPTS\|ssh "|" ' "$repo/Jenkinsfile" 2>/dev/null || true)
if grep -q 'SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
	"$repo/Jenkinsfile"; then
	ok "(B3) the pipeline uses BatchMode and a known hosts file for every ssh and scp"
else
	no "(B3) the pipeline uses BatchMode and a known hosts file for every ssh and scp"
fi
b3plain=$(grep -n 'ssh "\$addr"\|scp "\$addr' "$repo/Jenkinsfile" 2>/dev/null | wc -l)
if [ "$b3plain" -eq 0 ]; then
	ok "(B3) every ssh and scp of the pipeline carries the options"
else
	no "(B3) every ssh and scp of the pipeline carries the options"
	grep -n 'ssh "\$addr"\|scp "\$addr' "$repo/Jenkinsfile" | sed 's/^/      | /'
fi

# (B4) the appliance profile waits for sshd, and says so when it does not
#      come up
p=21500
sshport2=''
while [ "$p" -lt 21700 ]; do
	if ! nc -z 127.0.0.1 "$p" > /dev/null 2>&1; then
		sshport2=$p
		break
	fi
	p=$((p + 1))
done
if [ -z "$sshport2" ]; then
	no "(B4) a closed loopback port for the sshd probe was found"
else
	WTFBSD_FAKE_STATE="$work/state7"
	WTFBSD_FAKE_LOG="$work/serial7.log"
	WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log"
	unset WTFBSD_FAKE_SSH_PORT
	WTFBSD_BOOT_SSH_PORT=$sshport2
	WTFBSD_BOOT_TIMEOUT=3
	export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG
	export WTFBSD_BOOT_SSH_PORT WTFBSD_BOOT_TIMEOUT
	sh "$boottest" "$work/image.img" appliance > "$work/boot7.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && grep -qi 'sshd' "$work/boot7.log"; then
		ok "(B4) the boot test fails and names sshd when sshd does not answer"
	else
		no "(B4) the boot test fails and names sshd when sshd does not answer (rc=$rc)"
		sed 's/^/      | /' "$work/boot7.log"
	fi
fi

# (B5) a boot test that is killed destroys the VM and fails
sed '/login:/,$d' "$repo/tests/fixtures/serial-login.log" > "$work/no-login2.log"
WTFBSD_FAKE_STATE="$work/state8"
WTFBSD_FAKE_LOG="$work/serial8.log"
WTFBSD_FAKE_SOURCE_LOG="$work/no-login2.log"
WTFBSD_BOOT_TIMEOUT=60
export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_BOOT_TIMEOUT
rm -f "$work/state8"
sh "$boottest" "$work/image.img" appliance > "$work/boot8.log" 2>&1 &
bpid=$!
sleep 2
kill -TERM "$bpid" 2> /dev/null || true
wait "$bpid" 2> /dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(B5) the boot test fails when it is killed"
else
	no "(B5) the boot test fails when it is killed (rc=$rc)"
fi
if grep -q '^destroy' "$work/state8" 2>/dev/null; then
	ok "(B5) the boot test destroys the VM when it is killed"
else
	no "(B5) the boot test destroys the VM when it is killed"
	sed 's/^/      | /' "$work/state8" 2>/dev/null
fi

# (B6) ci/vm.sh refuses a bad name before the provider is called
badname=$(printf 'ok\nx')
rm -f "$work/badname.state"
WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
	WTFBSD_FAKE_STATE="$work/badname.state" \
	sh "$vmsh" create "$badname" "$work/image.img" > "$work/badname.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/badname.state" ]; then
	ok "(B6) ci/vm.sh refuses a bad VM name before the provider is called"
else
	no "(B6) ci/vm.sh refuses a bad VM name before the provider is called (rc=$rc)"
	sed 's/^/      | /' "$work/badname.log"
fi

# (B7) a name with a newline in it is refused everywhere
rm -f "$work/badname2.state"
WTFBSD_FAKE_STATE="$work/badname2.state" \
	sh "$repo/tests/fixtures/fake-provider.sh" create "$badname" "$work/image.img" \
	> "$work/badname2.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/badname2.state" ]; then
	ok "(B7) the provider refuses a VM name with a newline in it"
else
	no "(B7) the provider refuses a VM name with a newline in it (rc=$rc)"
fi
if grep -q 'valid_name' "$repo/ci/providers/bhyve.sh"; then
	ok "(B7) the bhyve provider checks the name of the VM as well"
else
	no "(B7) the bhyve provider checks the name of the VM as well"
fi
# the bhyve provider refuses the name as well, not only the fake one
WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" create "$badname" "$work/image.img" \
	> "$work/badname3.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q 'started' "$work/badname3.log" 2>/dev/null; then
	ok "(B7) the bhyve provider refuses a VM name with a newline in it"
else
	no "(B7) the bhyve provider refuses a VM name with a newline in it (rc=$rc)"
	sed 's/^/      | /' "$work/badname3.log"
fi

# (B8) the destroy of a VM that is not there is not a failure, and the
#      boot test reports a VM it cannot destroy
WTFBSD_BHYVE_STATE="$work/vmstate" \
	WTFBSD_BHYVE_CONSOLE_DIR="$work/vmconsole" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" destroy ghostvm > "$work/destroy.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'is not running' "$work/destroy.log" 2>/dev/null &&
	! grep -q 'destroyed' "$work/destroy.log"; then
	ok "(B8) the destroy of a VM that is not there is not a failure"
else
	no "(B8) the destroy of a VM that is not there is not a failure (rc=$rc)"
	sed 's/^/      | /' "$work/destroy.log"
fi
WTFBSD_FAKE_STATE="$work/state9"
WTFBSD_FAKE_LOG="$work/serial9.log"
WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log"
WTFBSD_FAKE_DESTROY_FAIL=1
export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_FAKE_DESTROY_FAIL
sh "$boottest" "$work/image.img" desktop > "$work/boot9.log" 2>&1
if grep -q 'could not be destroyed' "$work/boot9.log" 2>/dev/null; then
	ok "(B8) the boot test reports a VM it cannot destroy"
else
	no "(B8) the boot test reports a VM it cannot destroy"
	sed 's/^/      | /' "$work/boot9.log"
fi
unset WTFBSD_FAKE_DESTROY_FAIL

# (B9) the provider stops the reader of the console again, and (B10) it
#      detaches the tap device from the bridge when the VM is destroyed
: > "$work/fake.log"
FAKE_LOG="$work/fake.log" \
	PATH="$work/fakehost/bin:$PATH" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	WTFBSD_BHYVE_STATE="$work/fakehost/state" \
	WTFBSD_BHYVE_FIRMWARE='' \
	WTFBSD_BHYVE_NMDM_BASE="$work/fakehost/nmdm/" \
	WTFBSD_BHYVE_TAP_BASE="$work/fakehost/tap" \
	WTFBSD_BHYVE_BRIDGE=bridge0 \
	WTFBSD_TEST_FAKE_NMDM=1 \
	WTFBSD_BHYVE_START_WAIT=1 \
	WTFBSD_BHYVE_NMDM_WAIT=0 \
	sh "$repo/ci/providers/bhyve.sh" destroy vm-console > "$work/bhyve3.log" 2>&1
if [ ! -f "$work/fakehost/state/vm-console.reader.pid" ]; then
	ok "(B9) the provider stops the reader of the console and forgets it"
else
	no "(B9) the provider stops the reader of the console and forgets it"
	ls -R "$work/fakehost/state" 2>/dev/null | sed 's/^/      | /'
fi
if grep -q 'ifconfig bridge0 deletem ' "$work/fake.log" 2>/dev/null; then
	ok "(B10) the provider detaches the tap device from the bridge again"
else
	no "(B10) the provider detaches the tap device from the bridge again"
	sed 's/^/      | /' "$work/fake.log" 2>/dev/null
fi
if grep -q 'addm tap0' "$repo/README.md"; then
	no "(B10) the README holds no invalid ifconfig instruction"
	grep -n 'addm tap0' "$repo/README.md" | sed 's/^/      | /'
else
	ok "(B10) the README holds no invalid ifconfig instruction"
fi
if grep -q 'edk2-bhyve' "$repo/README.md"; then
	ok "(B10) the README names the package that holds the firmware"
else
	no "(B10) the README names the package that holds the firmware"
fi

# (B11) the README documents the plugin the file parameter needs
if grep -qi 'File Parameter' "$repo/README.md"; then
	ok "(B11) the README documents the plugin the file parameter needs"
else
	no "(B11) the README documents the plugin the file parameter needs"
fi

# (B12) the provider script of a site runs with the rights of the agent
if grep -q 'id -u' "$repo/ci/providers/bhyve.sh" &&
	grep -q 'needs root' "$repo/ci/providers/bhyve.sh"; then
	ok "(B12) the bhyve provider refuses to run without root"
else
	no "(B12) the bhyve provider refuses to run without root"
fi
if grep -qi 'root-owned' "$repo/README.md" &&
	grep -qi 'writable' "$repo/README.md"; then
	ok "(B12) the README says how the provider script of a site has to be protected"
else
	no "(B12) the README says how the provider script of a site has to be protected"
fi

# (B13) the sshd probe is bounded, and the image path may not hold a comma
if grep -q 'nc -z -w 2' "$repo/tests/boot-test.sh"; then
	ok "(B13) the sshd probe of the boot test is bounded"
else
	no "(B13) the sshd probe of the boot test is bounded"
fi
: > "$work/a,b.img"
WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" create vm1 "$work/a,b.img" > "$work/comma.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'comma' "$work/comma.log"; then
	ok "(B13) the provider refuses an image path that holds a comma"
else
	no "(B13) the provider refuses an image path that holds a comma (rc=$rc)"
	sed 's/^/      | /' "$work/comma.log"
fi

# (B15) no round report is tracked
if grep -q 'ROUND-REPORT' "$repo/.gitignore"; then
	ok "(B15) the round reports are ignored by git"
else
	no "(B15) the round reports are ignored by git"
fi
if command -v git > /dev/null 2>&1 && git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
	if git -C "$repo" ls-files | grep -q '^ROUND-REPORT'; then
		no "(B15) no round report is tracked by git"
		git -C "$repo" ls-files | grep '^ROUND-REPORT' | sed 's/^/      | /'
	else
		ok "(B15) no round report is tracked by git"
	fi
else
	skip "(B15) no round report is tracked by git (no git repository here)"
fi

# --------------------------------------------------------------------------
# (j) no_internal_refs: the leak check of the tree
# --------------------------------------------------------------------------
# The check looks for generic shapes only: the repository ships no list
# of names, because a list of names is itself a list of names. A site
# that wants to check for its own names points WTFBSD_DENYLIST at a file
# outside the repository.
if sh "$repo/tests/leak-check.sh" > "$work/leak.log" 2>&1; then
	ok "no_internal_refs: the tree holds no address, no foreign email address, no internal domain and no credential shape"
else
	no "no_internal_refs: the tree holds no address, no foreign email address, no internal domain and no credential shape"
	sed 's/^/      | /' "$work/leak.log"
fi

# a probe per generic shape: a file that holds the shape has to be
# found, and it has to be found as long as it is there. The shapes are
# written in pieces, so that this file does not hold them itself.
probe_case() { # probe_case <what> <content>
	_what=$1
	printf '%s\n' "$2" > "$probe"
	if sh "$repo/tests/leak-check.sh" > "$work/probe.log" 2>&1; then
		no "(j) the leak check finds a $_what"
		sed 's/^/      | /' "$work/probe.log"
	elif grep -q "$probe_name" "$work/probe.log"; then
		ok "(j) the leak check finds a $_what"
	else
		no "(j) the leak check finds a $_what (the file was not named)"
		sed 's/^/      | /' "$work/probe.log"
	fi
	rm -f "$probe"
}
probe_case 'dotted-quad address' "$(printf '10.1.%s.3' 2)"
probe_case 'IPv6 address' "$(printf 'fe80%s1' '::')"
probe_case 'email address' "$(printf 'someone@example%s' '.net')"
probe_case 'internal top level domain' "$(printf 'host.%s' 'lan')"
probe_case 'private key header' "$(printf -- '%s %s %s' \
	'-----BEGIN' 'RSA' \
	'PRIVATE KEY-----')"
probe_case 'public key header' "$(printf 'ssh-ed25519 %s' 'AAAA' 'C3NzaC1lZDI1NTE5')"
probe_case 'token prefix' "$(printf '%s%s' 'gh' 'p_0123456789abcdefghij')"
probe_case 'credential name' "$(printf '%s%s' 'api' 'Key=secret')"

# the private list of the site
printf '%s\n' 'zzq-made-up-token' > "$work/denylist"
printf '%s\n' "$(printf '%s-%s' 'zzq-made-up' 'token')" > "$probe"
if WTFBSD_DENYLIST="$work/denylist" sh "$repo/tests/leak-check.sh" > "$work/probe.log" 2>&1; then
	no "(j) the leak check finds what the private list of the site denies"
	sed 's/^/      | /' "$work/probe.log"
elif grep -q "$probe_name" "$work/probe.log"; then
	ok "(j) the leak check finds what the private list of the site denies"
else
	no "(j) the leak check finds what the private list of the site denies (the file was not named)"
	sed 's/^/      | /' "$work/probe.log"
fi
rm -f "$probe"

# --------------------------------------------------------------------------
# (k) opencode.json is valid JSON and names no provider, model or key
# --------------------------------------------------------------------------
if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/opencode.json" > "$work/json.log" 2>&1; then
	ok "(k) opencode.json is valid JSON"
else
	no "(k) opencode.json is valid JSON"
	sed 's/^/      | /' "$work/json.log"
fi
# The sensitive tokens are assembled at run time, so that this file does
# not contain the strings the scanner forbids.
kpat=$(printf '%s|%s|%s|%s|%s|%s|%s' \
	'provider' 'model' \
	"$(printf 'api%s' 'Key')" "$(printf 'api_%s' 'key')" \
	"$(printf 'base%s' 'URL')" "$(printf 'Bear%s' 'er')" \
	'mcp')
if grep -iE -- "$kpat" "$repo/opencode.json" > "$work/jsonkeys.log" 2>&1; then
	no "(k) opencode.json names no provider, model, key, base URL or MCP server"
	sed 's/^/      | /' "$work/jsonkeys.log"
else
	ok "(k) opencode.json names no provider, model, key, base URL or MCP server"
fi

# --------------------------------------------------------------------------
# extra checks
# --------------------------------------------------------------------------
# every shell script parses
snbad=''
for f in $(find "$repo" -name '*.sh' -not -path '*/.git/*'); do
	sh -n "$f" 2>/dev/null || snbad="$snbad $f"
done
for f in $(find "$repo/overlay" -type f -not -name '*.list'); do
	case $f in
	*.sh) ;;
	*)
		head -1 "$f" 2>/dev/null | grep -q '^#!.*sh' || continue
		sh -n "$f" 2>/dev/null || snbad="$snbad $f"
		;;
	esac
done
if [ -z "$snbad" ]; then
	ok "every shell script parses (sh -n)"
else
	no "every shell script parses (sh -n) fails on:$snbad"
fi

# rc.conf fragments are named after the service that reads them
misnamed=''
for f in $(find "$repo/overlay" -type f \( -path '*rc.conf.d/*' -o -path '*rc.conf.installed.d/*' \)); do
	base=${f##*/}
	case $base in
	appliance | desktop | examplebsd | dragonfly) misnamed="$misnamed $base" ;;
	esac
done
if [ -z "$misnamed" ]; then
	ok "every rc.conf.d fragment is named after its service"
else
	no "every rc.conf.d fragment is named after its service:$misnamed"
fi

for svc in hostname sshd dbus lightdm; do
	if [ -n "$(find "$repo/overlay" -type f \( -path "*rc.conf.d/$svc" -o -path "*rc.conf.installed.d/$svc" \) 2>/dev/null)" ]; then
		ok "rc.conf.d/$svc (or rc.conf.installed.d/$svc) exists"
	else
		no "rc.conf.d/$svc (or rc.conf.installed.d/$svc) exists"
	fi
done

# build.sh insists on a product.conf
sh "$build" -n -o "$work/out" > "$work/noconf.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'product.conf' "$work/noconf.log"; then
	ok "build.sh refuses to run without -c product.conf"
else
	no "build.sh refuses to run without -c product.conf (rc=$rc)"
	sed 's/^/      | /' "$work/noconf.log"
fi

# an unknown key in product.conf is refused
sed "s/^DISTRO_NAME=.*/PATH='\/tmp'/" "$fixture" > "$work/key.conf"
sh "$build" -n -c "$work/key.conf" -o "$work/out" > "$work/key.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'PATH' "$work/key.log"; then
	ok "an unknown product.conf key is refused"
else
	no "an unknown product.conf key is refused (rc=$rc)"
	sed 's/^/      | /' "$work/key.log"
fi

# the dry run writes nothing
sh "$build" -n -c "$fixture" -o "$work/out" --no-user > "$work/dry.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$work/out" ]; then
	ok "the dry run writes nothing"
else
	no "the dry run writes nothing"
	sed 's/^/      | /' "$work/dry.log"
fi

# the real build is refused on a host that cannot build DragonFly
case $(uname -s) in
DragonFly)
	sh "$build" -c "$fixture" -o "$work/out" --no-user > "$work/host.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && grep -q 'src' "$work/host.log"; then
		ok "the real build needs a DragonFly source tree"
	else
		no "the real build needs a DragonFly source tree (rc=$rc)"
		sed 's/^/      | /' "$work/host.log"
	fi
	;;
*)
	sh "$build" -c "$fixture" -o "$work/out" --no-user > "$work/host.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] &&
		{ grep -qi 'DragonFly' "$work/host.log" || grep -qi 'root' "$work/host.log"; }; then
		ok "the real build is refused on a host that cannot build DragonFly"
	else
		no "the real build is refused on a host that cannot build DragonFly (rc=$rc)"
		sed 's/^/      | /' "$work/host.log"
	fi
	;;
esac

# --------------------------------------------------------------------------
# (C1) nrelease is driven through the hooks of the release tooling
# --------------------------------------------------------------------------
# The build of this section is the reference build of the cases that
# follow: the appliance profile, without a first-boot user.
realbuild "$work/c1"
stublog="$work/c1/stub.log"
realout="$work/c1/out"
stage="$realout/appliance/root"

# The release tooling of DragonFly takes the overlay through ROOTSKELS
# and the packages through DPORTS_EXTRA_PACKAGES, and it names the
# media through ISOFILE and IMGFILE. The build has to hand all of them
# over, and it has to name the release root (ISODIR, ISOROOT).
c1bad=''
for v in "ISODIR=$realout/appliance" \
	"ISOROOT=$realout/appliance/root" \
	"ISOFILE=$realout/appliance/examplebsd-appliance-amd64.iso" \
	"IMGFILE=$realout/appliance/examplebsd-appliance-amd64.img"; do
	grep -q "^VAR $v\$" "$stublog" 2>/dev/null || c1bad="$c1bad $v"
done
if [ -z "$c1bad" ]; then
	ok "(C1) the overlay, the release root and the names of the media reach make(1)"
else
	no "(C1) the overlay, the release root and the names of the media reach make(1):$c1bad"
	sed 's/^/      | /' "$stublog"
fi
if grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*security/ca_root_nss' "$stublog" 2>/dev/null &&
	grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*security/doas' "$stublog" 2>/dev/null; then
	ok "(C1) the packages of the overlay reach make(1) as DPORTS_EXTRA_PACKAGES"
else
	no "(C1) the packages of the overlay reach make(1) as DPORTS_EXTRA_PACKAGES"
	sed 's/^/      | /' "$stublog"
fi
if grep -q '^CMD make .*buildworld1' "$stublog" 2>/dev/null &&
	! grep -q '^CMD make .*buildworld ' "$stublog" 2>/dev/null; then
	ok "(C1) the world is built by the release tooling of nrelease"
else
	no "(C1) the world is built by the release tooling of nrelease"
	sed 's/^/      | /' "$stublog"
fi
if PATH="$repo/tests/stubs:$PATH" STUB_LOG=/dev/null \
	sh "$repo/tests/stubs/make" -C "$repo/tests/fixtures/fake-src/nrelease" \
	nosuchtarget > "$work/mt.log" 2>&1; then
	no "(C1) the stand-in for make(1) refuses a target the Makefile does not define"
	sed 's/^/      | /' "$work/mt.log"
else
	ok "(C1) the stand-in for make(1) refuses a target the Makefile does not define"
fi

# the desktop and both, through the real path
printf '%s\n' '$6$wtfsbsd$0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuv' \
	> "$work/pass.hash"
REAL_PROFILE=desktop realbuild "$work/desk" -u ciuser -P "$work/pass.hash"
# the desktop does not use the release tooling's GUI skeleton (its
# nrelease/gui skeleton mounts /usr/pkg paths that the product does not
# have, which drops the live system to single user): whatever the overlay
# needs it carries itself, so ROOTSKELS is the release root skeleton and
# the overlay only. The desktop ships a disk image by default, because the
# DragonFly 6.4 EFI loader cannot read past 2 GiB of an ISO9660 image.
if [ "$realrc" -eq 0 ] &&
	! grep -q '^VAR ROOTSKELS=.*/nrelease/gui ' "$work/desk/stub.log" 2>/dev/null &&
	[ -f "$work/desk/out/desktop/examplebsd-desktop-amd64.img" ]; then
	ok "(C1) the desktop is built without the release tooling's GUI skeleton and ships a disk image"
else
	no "(C1) the desktop is built without the release tooling's GUI skeleton and ships a disk image (rc=$realrc)"
	grep '^VAR ROOTSKELS=' "$work/desk/stub.log" 2>/dev/null | sed 's/^/      | /'
fi
REAL_PROFILE=both realbuild "$work/both" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] &&
	! grep -q '^VAR ROOTSKELS=.*/nrelease/gui ' "$work/both/stub.log" 2>/dev/null &&
	[ -f "$work/both/out/appliance/examplebsd-appliance-amd64.img" ] &&
	[ -f "$work/both/out/desktop/examplebsd-desktop-amd64.img" ]; then
	ok "(C1) the profile both ships the appliance image and the desktop disk image through the real path"
else
	no "(C1) the profile both ships the appliance image and the desktop disk image through the real path (rc=$realrc)"
	grep '^VAR ROOTSKELS=' "$work/both/stub.log" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (C2) the /etc of the overlay reaches the image AND the installed system
# --------------------------------------------------------------------------
# The release tooling snapshots /etc into /etc.hdd before the rootskels
# are applied, and the installer copies <dir>.hdd in place of <dir>: the
# /etc of the overlay therefore has to be in both trees.
if [ -f "$stage/etc/motd" ] && [ -f "$stage/etc.hdd/motd" ] &&
	grep -q 'ExampleBSD' "$stage/etc/motd" 2>/dev/null &&
	grep -q 'ExampleBSD' "$stage/etc.hdd/motd" 2>/dev/null; then
	ok "(C2) the /etc of the overlay is in the image and in the tree of the installer"
else
	no "(C2) the /etc of the overlay is in the image and in the tree of the installer"
	ls -R "$stage/etc.hdd" 2>/dev/null | sed 's/^/      | /'
fi
if grep -q '^sshd_enable="YES"$' "$stage/etc.hdd/rc.conf" 2>/dev/null &&
	grep -q '^hostname="examplebsd"$' "$stage/etc.hdd/rc.conf" 2>/dev/null; then
	ok "(C2) the rc.conf of the installed system holds the variables of the overlay"
else
	no "(C2) the rc.conf of the installed system holds the variables of the overlay"
	sed 's/^/      | /' "$stage/etc.hdd/rc.conf" 2>/dev/null
fi

# --------------------------------------------------------------------------
# (C3) the login path: doas, the first-boot user, the password hash
# --------------------------------------------------------------------------
if [ -f "$stage/usr/local/etc/doas.conf" ] &&
	grep -q '^permit persist :wheel$' "$stage/usr/local/etc/doas.conf" 2>/dev/null; then
	ok "(C3) the image ships a doas.conf that lets the wheel group become root"
else
	no "(C3) the image ships a doas.conf that lets the wheel group become root"
	sed 's/^/      | /' "$stage/usr/local/etc/doas.conf" 2>/dev/null
fi
if grep -v '^[[:space:]]*#' "$repo/overlay/base/packages.list" \
	"$repo/overlay/profiles/appliance/packages.list" \
	"$repo/overlay/profiles/desktop/packages.list" 2>/dev/null |
	grep -q '^sudo$'; then
	no "(C3) no package of the overlay asks for sudo"
	grep -rn '^sudo$' "$repo/overlay" | sed 's/^/      | /'
else
	ok "(C3) no package of the overlay asks for sudo"
fi

# the first-boot script really runs: a stand-in for rc.subr dispatches it
mkdir -p "$work/fbroot/etc/rc.d" "$work/fbroot/boot" "$work/fbroot/usr/local/etc" \
	"$work/fbroot/home" "$work/fakebin"
cat > "$work/fbroot/etc/rc.subr" <<'RCSUBR'
#!/bin/sh
# a stand-in for /etc/rc.subr: it dispatches, so that the script runs
load_rc_config() { :; }
run_rc_command() {
	case ${1:-} in
	start) "$start_cmd" ;;
	*) : ;;
	esac
}
RCSUBR
cat > "$work/fakebin/pw" <<'FAKEPW'
#!/bin/sh
printf 'pw %s\n' "$*" >> "$PW_LOG"
case ${1:-} in
usershow) exit 1 ;;
esac
exit 0
FAKEPW
cat > "$work/fakebin/logger" <<'FAKELOG'
#!/bin/sh
printf 'logger %s\n' "$*" >> "${LOGGER_LOG:-/dev/null}"
exit 0
FAKELOG
cat > "$work/fakebin/chown" <<'FAKECHOWN'
#!/bin/sh
printf 'chown %s\n' "$*" >> "${CHOWN_LOG:-/dev/null}"
exit 0
FAKECHOWN
chmod 755 "$work/fakebin/pw" "$work/fakebin/logger" "$work/fakebin/chown"
sed -e 's#/etc/rc\.subr#@R@/etc/rc.subr#g' \
	-e 's#/etc/master\.passwd#@R@/etc/master.passwd#g' \
	-e 's#/etc/passwd#@R@/etc/passwd#g' \
	-e 's#/boot/firstboot-user\.conf#@R@/boot/firstboot-user.conf#g' \
	-e 's#/usr/local/etc/doas\.conf#@R@/usr/local/etc/doas.conf#g' \
	-e 's#/home#@R@/home#g' \
	-e 's#/firstboot\([^a-z-]\)#@R@/firstboot\1#g' \
	-e 's#/firstboot$#@R@/firstboot#g' \
	"$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" |
	sed "s#@R@#$work/fbroot#g" > "$work/fbroot/etc/rc.d/firstboot_user"
chmod 755 "$work/fbroot/etc/rc.d/firstboot_user"
printf 'ciuser:x:1001:1001:Ci User:%s/home/ciuser:/bin/sh\n' "$work/fbroot" \
	> "$work/fbroot/etc/passwd"
printf 'USERNAME=ciuser\nFULLNAME=Ada Lovelace\nSSH_KEY=%s %s testkey\n' \
	'ssh-ed25519' 'AAAAtest' > "$work/fbroot/boot/firstboot-user.conf"
printf 'permit persist :wheel\n' > "$work/fbroot/usr/local/etc/doas.conf"
: > "$work/pw.log"
PATH="$work/fakebin:$PATH" PW_LOG="$work/pw.log" LOGGER_LOG="$work/logger.log" \
	sh "$work/fbroot/etc/rc.d/firstboot_user" start > "$work/fb.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'useradd' "$work/pw.log" 2>/dev/null &&
	grep -q -- '-G wheel' "$work/pw.log" 2>/dev/null; then
	ok "(C3) the first-boot script runs and puts the user into the wheel group"
else
	no "(C3) the first-boot script runs and puts the user into the wheel group (rc=$rc)"
	sed 's/^/      | /' "$work/fb.log"
	sed 's/^/      | /' "$work/pw.log" 2>/dev/null
fi
if [ -f "$work/fbroot/boot/firstboot-user.conf.done" ] &&
	[ ! -f "$work/fbroot/boot/firstboot-user.conf" ]; then
	ok "(C3) the first-boot script moves its configuration out of the way"
else
	no "(C3) the first-boot script moves its configuration out of the way"
fi
# the guard: without a configuration the script does nothing at all
rm -f "$work/fbroot/boot/firstboot-user.conf.done"
: > "$work/pw.log"
PATH="$work/fakebin:$PATH" PW_LOG="$work/pw.log" LOGGER_LOG="$work/logger.log" \
	sh "$work/fbroot/etc/rc.d/firstboot_user" start > "$work/fb2.log" 2>&1
if [ ! -s "$work/pw.log" ]; then
	ok "(C3) the first-boot script does nothing while its configuration is absent"
else
	no "(C3) the first-boot script does nothing while its configuration is absent"
	sed 's/^/      | /' "$work/pw.log"
fi
# the keyword of the script: the installer of DragonFly copies only the
# paths of share/installer/sources.conf, and /firstboot is not among
# them, so a script that is guarded by the firstboot keyword never runs
# on an installed system. The guard of the script is its configuration
# file, not the keyword.
fbscript="$repo/overlay/base/rootfs/etc/rc.d/firstboot_user"
fbkw=$(grep '^# KEYWORD:' "$fbscript" 2>/dev/null || true)
if [ -n "$fbkw" ] && ! printf '%s' "$fbkw" | grep -q 'firstboot' &&
	grep -q 'firstboot_user_conf:="/boot/firstboot-user.conf"' "$fbscript" 2>/dev/null &&
	grep -q 'if \[ ! -f "$_conf" \]; then' "$fbscript" 2>/dev/null; then
	ok "(C3) the first-boot script is not guarded by the firstboot keyword"
else
	no "(C3) the first-boot script is not guarded by the firstboot keyword (got: $fbkw)"
fi

# the SSH keys go into a home that may already exist. Whoever owns that
# home can plant symbolic links in it; root must not write, chmod or
# chown through them. A .ssh that is a link to a directory of root, and
# an authorized_keys that is a link to a password file, are refused and
# said, and the targets are left as they were. A configuration path with
# a space in it works.
fbl="$work/fblink"
mkdir -p "$fbl/rootdir" "$fbl/conf dir"
printf 'root:*:0:0:the master password file stand-in:/root:/bin/sh\n' > "$fbl/master.passwd"
cp "$fbl/master.passwd" "$fbl/master.passwd.orig"
fblrun() { # fblrun <name> <user> <conf> — run the script for one user
	printf '%s:x:1001:1001:Fb User:%s/home/%s:/bin/sh\n' "$2" "$work/fbroot" "$2" \
		> "$work/fbroot/etc/passwd"
	printf 'USERNAME=%s\nWHEEL=no\nSSH_KEY=%s %s fbl\n' "$2" 'ssh-ed25519' 'fbldata' > "$3"
	: > "$fbl/$1.chown"
	PATH="$work/fakebin:$PATH" PW_LOG="$fbl/$1.pw" LOGGER_LOG="$fbl/$1.logger" \
		CHOWN_LOG="$fbl/$1.chown" firstboot_user_conf="$3" \
		sh "$work/fbroot/etc/rc.d/firstboot_user" start > "$fbl/$1.out" 2>&1
	fblrc=$?
}
mkdir -p "$work/fbroot/home/fbla"
ln -s "$fbl/rootdir" "$work/fbroot/home/fbla/.ssh"
fblrun a fbla "$fbl/a.conf"
if [ "$fblrc" -ne 0 ] && grep -q 'refused.*fbla/.ssh is a symbolic link' "$fbl/a.out" &&
	[ -z "$(ls -A "$fbl/rootdir")" ] && [ ! -s "$fbl/a.chown" ]; then
	ok "(C3) a .ssh that is a symbolic link is refused, and its target is untouched"
else
	no "(C3) a .ssh that is a symbolic link is refused, and its target is untouched (rc=$fblrc)"
	sed 's/^/      | /' "$fbl/a.out"
fi
mkdir -p "$work/fbroot/home/fblb/.ssh"
ln -s "$fbl/master.passwd" "$work/fbroot/home/fblb/.ssh/authorized_keys"
fblrun b fblb "$fbl/b.conf"
if [ "$fblrc" -ne 0 ] && grep -q 'refused.*authorized_keys is a symbolic link' "$fbl/b.out" &&
	cmp -s "$fbl/master.passwd" "$fbl/master.passwd.orig" && [ ! -s "$fbl/b.chown" ]; then
	ok "(C3) an authorized_keys that is a symbolic link is refused, and the file it names is untouched"
else
	no "(C3) an authorized_keys that is a symbolic link is refused, and the file it names is untouched (rc=$fblrc)"
	sed 's/^/      | /' "$fbl/b.out"
fi
# the home sits below a symbolic link nobody but its maker trusts
mkdir -p "$fbl/elsewhere/fblp"
ln -s "$fbl/elsewhere" "$work/fbroot/home/plink"
printf 'USERNAME=fblp\nWHEEL=no\nSSH_KEY=%s %s fbl\n' 'ssh-ed25519' 'fbldata' > "$fbl/p.conf"
printf 'fblp:x:1001:1001:Fb User:%s/home/plink/fblp:/bin/sh\n' "$work/fbroot" > "$work/fbroot/etc/passwd"
: > "$fbl/p.chown"
PATH="$work/fakebin:$PATH" PW_LOG="$fbl/p.pw" LOGGER_LOG="$fbl/p.logger" \
	CHOWN_LOG="$fbl/p.chown" firstboot_user_conf="$fbl/p.conf" \
	sh "$work/fbroot/etc/rc.d/firstboot_user" start > "$fbl/p.out" 2>&1
fblrc=$?
rm -f "$work/fbroot/home/plink"
if [ "$fblrc" -ne 0 ] && grep -q 'refused.*plink is a symbolic link that root does not own' "$fbl/p.out" &&
	[ ! -e "$fbl/elsewhere/fblp/.ssh" ] && [ ! -s "$fbl/p.chown" ]; then
	ok "(C3) a home below a symbolic link root does not own is refused, and nothing is written through it"
else
	no "(C3) a home below a symbolic link root does not own is refused, and nothing is written through it (rc=$fblrc)"
	sed 's/^/      | /' "$fbl/p.out"
fi
mkdir -p "$work/fbroot/home/fblc"
fblrun c fblc "$fbl/conf dir/firstboot-user.conf"
fblak="$work/fbroot/home/fblc/.ssh/authorized_keys"
fblmode=$(ls -ld "$fblak" 2>/dev/null | cut -c1-10)
if [ "$fblrc" -eq 0 ] && grep -qx 'ssh-ed25519 fbldata fbl' "$fblak" 2>/dev/null &&
	[ "$fblmode" = '-rw-------' ] && [ ! -L "$fblak" ] &&
	[ -f "$fbl/conf dir/firstboot-user.conf.done" ] &&
	grep -qx 'chown -h fblc authorized_keys .' "$fbl/c.chown"; then
	ok "(C3) the keys are installed 0600 and given to the user (a configuration path with a space)"
else
	no "(C3) the keys are installed 0600 and given to the user (a configuration path with a space) (rc=$fblrc mode=$fblmode)"
	sed 's/^/      | /' "$fbl/c.out"
fi
# the path of the configuration is quoted where it is read: some sh split
# the unquoted word of local
if grep -q '^	local _conf="\$firstboot_user_conf"$' "$fbscript"; then
	ok "(C3) the configuration path is quoted in local"
else
	no "(C3) the configuration path is quoted in local"
fi

# the password hash of the first-boot user
realbuild "$work/fbhash" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
fbhashconf="$work/fbhash/out/appliance/root/boot/firstboot-user.conf"
# the reference build of the cases that follow is not changed by it
stublog="$work/c1/stub.log"
realout="$work/c1/out"
stage="$realout/appliance/root"
if [ "$realrc" -eq 0 ] &&
	grep -q '^PASSWORD_HASH=\$6\$' "$fbhashconf" 2>/dev/null; then
	ok "(C3) the build bakes the password hash of the first-boot user into the image"
else
	no "(C3) the build bakes the password hash of the first-boot user into the image (rc=$realrc)"
	sed 's/^/      | /' "$work/fbhash/build.log"
fi
printf 'a plain text password\n' > "$work/plain.hash"
sh "$build" -n -c "$fixture" -u ciuser -k "$work/ci.pub" -P "$work/plain.hash" \
	-o "$work/out" > "$work/plain.log" 2>&1
if [ $? -ne 0 ] && grep -qi 'crypt' "$work/plain.log"; then
	ok "(C3) a plain text password is refused"
else
	no "(C3) a plain text password is refused"
	sed 's/^/      | /' "$work/plain.log"
fi
sh "$build" -n -c "$fixture" -p desktop -u ciuser -o "$work/out" > "$work/dnop.log" 2>&1
if [ $? -ne 0 ]; then
	ok "(C3) the desktop profile asks for a password (a key is of no use without sshd)"
else
	no "(C3) the desktop profile asks for a password (a key is of no use without sshd)"
fi
sh "$build" -n -c "$fixture" -p appliance -u ciuser -o "$work/out" > "$work/anok.log" 2>&1
if [ $? -ne 0 ]; then
	ok "(C3) the appliance profile asks for a key"
else
	no "(C3) the appliance profile asks for a key"
fi
# the release root also becomes the read-only ISO, where the stock
# /etc/rc cannot remove /firstboot: the tree carries no sentinel (mkimg
# creates it in the disk image, see D7)
if [ ! -e "$stage/firstboot" ]; then
	ok "(C3) the release root holds no sentinel of the first boot (it becomes the read-only ISO)"
else
	no "(C3) the release root holds no sentinel of the first boot (it becomes the read-only ISO)"
fi

# --------------------------------------------------------------------------
# (C4) every uid-0 account is locked, and the installer is gone
# --------------------------------------------------------------------------
c4bad=''
while IFS=: read -r cu _cp _cuid _cgid _cgecos _chome _csh; do
	[ -n "$cu" ] || continue
	[ "$_cuid" = 0 ] || continue
	case $_cp in
	'*' | '!' | '!!') ;;
	*) c4bad="$c4bad $cu($_cp)" ;;
	esac
done < "$stage/etc/master.passwd"
if [ -z "$c4bad" ]; then
	ok "(C4) no uid-0 account of the image has an empty or a usable password"
else
	no "(C4) no uid-0 account of the image has an empty or a usable password:$c4bad"
	sed 's/^/      | /' "$stage/etc/master.passwd" 2>/dev/null
fi
if grep -q '^installer:' "$stage/etc/master.passwd" 2>/dev/null; then
	no "(C4) the appliance image holds no installer account"
	sed 's/^/      | /' "$stage/etc/master.passwd" 2>/dev/null
else
	ok "(C4) the appliance image holds no installer account"
fi
if grep -q '^installer:.*:0:0:' "$repo/tests/fixtures/master.passwd" 2>/dev/null; then
	ok "(C4) the password file of the release root holds the installer account"
else
	no "(C4) the password file of the release root holds the installer account"
fi

# --------------------------------------------------------------------------
# (C5) no system tree is ever chowned recursively
# --------------------------------------------------------------------------
if grep -qE '^CMD chown -R .*(/etc|/usr|/usr/local)( |$)' "$stublog" 2>/dev/null; then
	no "(C5) no system tree of the release root is chowned recursively"
	grep '^CMD chown -R ' "$stublog" | sed 's/^/      | /'
else
	ok "(C5) no system tree of the release root is chowned recursively"
fi
if grep -qE '^CMD (chmod|chown) -R ' "$stublog" 2>/dev/null; then
	no "(C5) the build never walks a tree on its own"
	grep -E '^CMD (chmod|chown) -R ' "$stublog" | sed 's/^/      | /'
else
	ok "(C5) the build never walks a tree on its own"
fi

# --------------------------------------------------------------------------
# (C6) the bhyve provider: the tap, the media, the start of the guest
# --------------------------------------------------------------------------
# The provider is driven with the stand-ins of the fake host: bhyve(8),
# bhyvectl(8), ifconfig(8) and arp(8) only log their arguments.
fakehost
: > "$work/iso.img"
: > "$work/disk.img"
cp "$work/iso.img" "$work/media.iso"
FAKE_LOG="$work/fake1.log" \
	PATH="$work/fakehost/bin:$PATH" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	WTFBSD_BHYVE_STATE="$work/fakehost/state" \
	WTFBSD_BHYVE_FIRMWARE='' \
	WTFBSD_BHYVE_NMDM_BASE="$work/fakehost/nmdm/" \
	WTFBSD_BHYVE_TAP_BASE="$work/fakehost/tap" \
	WTFBSD_BHYVE_BRIDGE=bridge0 \
	WTFBSD_TEST_FAKE_NMDM=1 \
	WTFBSD_BHYVE_START_WAIT=1 \
	WTFBSD_BHYVE_NMDM_WAIT=0 \
	sh "$repo/ci/providers/bhyve.sh" create vm-one "$work/media.iso" \
	> "$work/bhyve.log" 2>&1
rc=$?
if grep -q 'ifconfig .*create' "$work/fake1.log" 2>/dev/null &&
	grep -q 'ifconfig .* up' "$work/fake1.log" 2>/dev/null &&
	grep -q 'ifconfig bridge0 addm ' "$work/fake1.log" 2>/dev/null; then
	ok "(C6) the provider creates the tap device and brings it up before it attaches it"
else
	no "(C6) the provider creates the tap device and brings it up before it attaches it (rc=$rc)"
	sed 's/^/      | /' "$work/fake1.log" 2>/dev/null
	sed 's/^/      | /' "$work/bhyve.log"
fi
if grep -q 'ahci-cd' "$work/fake1.log" 2>/dev/null; then
	ok "(C6) the provider attaches an .iso artifact as an ahci-cd device"
else
	no "(C6) the provider attaches an .iso artifact as an ahci-cd device"
	sed 's/^/      | /' "$work/fake1.log" 2>/dev/null
fi
FAKE_LOG="$work/fake2.log" \
	PATH="$work/fakehost/bin:$PATH" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	WTFBSD_BHYVE_STATE="$work/fakehost/state" \
	WTFBSD_BHYVE_FIRMWARE='' \
	WTFBSD_BHYVE_NMDM_BASE="$work/fakehost/nmdm/" \
	WTFBSD_BHYVE_TAP_BASE="$work/fakehost/tap" \
	WTFBSD_BHYVE_BRIDGE=bridge0 \
	WTFBSD_TEST_FAKE_NMDM=1 \
	WTFBSD_BHYVE_START_WAIT=1 \
	WTFBSD_BHYVE_NMDM_WAIT=0 \
	WTFBSD_VM_SLOT=1 \
	sh "$repo/ci/providers/bhyve.sh" create vm-two "$work/disk.img" \
	> "$work/bhyve2.log" 2>&1
if grep -q 'virtio-blk' "$work/fake2.log" 2>/dev/null &&
	! grep -q 'ahci-cd' "$work/fake2.log" 2>/dev/null; then
	ok "(C6) the provider attaches an .img artifact as a virtio-blk device"
else
	no "(C6) the provider attaches an .img artifact as a virtio-blk device)"
	sed 's/^/      | /' "$work/fake2.log" 2>/dev/null
fi
c6units=$(cat "$work/fake1.log" "$work/fake2.log" 2>/dev/null |
	grep -o 'nmdm/[0-9]*A' | sort -u | wc -l)
if [ "$c6units" -ge 2 ]; then
	ok "(C6) every VM of a host gets its own unit of the null-modem pair"
else
	no "(C6) every VM of a host gets its own unit of the null-modem pair (got $c6units)"
	sed 's/^/      | /' "$work/fake1.log" 2>/dev/null
	sed 's/^/      | /' "$work/fake2.log" 2>/dev/null
fi
if [ "$rc" -ne 0 ] && grep -qi 'bhyve' "$work/bhyve.log" 2>/dev/null; then
	ok "(C6) the provider reports a guest that does not start"
else
	no "(C6) the provider reports a guest that does not start (rc=$rc)"
	sed 's/^/      | /' "$work/bhyve.log"
fi
# The tap of the guest is created and brought up even when the host has
# no bridge: the device is attached to a bridge only when there is one,
# and bhyve(8) always wants a tap device of its own.
FAKE_LOG="$work/fake4.log" \
	PATH="$work/fakehost/bin:$PATH" \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	WTFBSD_BHYVE_STATE="$work/fakehost/state" \
	WTFBSD_BHYVE_FIRMWARE='' \
	WTFBSD_BHYVE_NMDM_BASE="$work/fakehost/nmdm/" \
	WTFBSD_BHYVE_TAP_BASE="$work/fakehost/tap" \
	WTFBSD_TEST_FAKE_NMDM=1 \
	WTFBSD_BHYVE_START_WAIT=1 \
	WTFBSD_BHYVE_NMDM_WAIT=0 \
	WTFBSD_VM_SLOT=2 \
	sh "$repo/ci/providers/bhyve.sh" create vm-four "$work/disk.img" \
	> "$work/bhyve4.log" 2>&1
rc=$?
if grep -q 'ifconfig .*create' "$work/fake4.log" 2>/dev/null &&
	grep -q 'ifconfig .* up' "$work/fake4.log" 2>/dev/null &&
	grep -q 'virtio-net' "$work/fake4.log" 2>/dev/null &&
	! grep -q 'addm' "$work/fake4.log" 2>/dev/null; then
	ok "(C6) the provider creates the tap device of the guest when the host has no bridge"
else
	no "(C6) the provider creates the tap device of the guest when the host has no bridge (rc=$rc)"
	sed 's/^/      | /' "$work/fake4.log" 2>/dev/null
	sed 's/^/      | /' "$work/bhyve4.log"
fi
# The provider names no knob that it does not use: the size of a disk is
# no knob of the provider, the disk of the guest is the artifact itself.
if grep -q 'WTFBSD_BHYVE_DISK' "$repo/ci/providers/bhyve.sh" "$repo/README.md" 2>/dev/null; then
	no "(C6) the provider names no knob that it does not use"
	grep -n 'WTFBSD_BHYVE_DISK' "$repo/ci/providers/bhyve.sh" "$repo/README.md" 2> /dev/null |
		sed 's/^/      | /'
else
	ok "(C6) the provider names no knob that it does not use"
fi

# --------------------------------------------------------------------------
# (C7) the pipeline
# --------------------------------------------------------------------------
# The words of the pipeline are read out of the file with its comments
# removed: a word in a comment must never make a case pass.
jenkins_code() { # jenkins_code — the pipeline without its Groovy comments
	_q="'''"
	q="$_q" awk 'BEGIN { q = ENVIRON["q"] }
		{
			line = $0
			sub(/\/\/.*/, "", line)
			print line
		}
	' "$repo/Jenkinsfile"
}
jenkins_groovy() { # jenkins_groovy — the pipeline without its shell strings
	_q="'''"
	_d="\"\"\""
	q="$_q" d="$_d" awk 'BEGIN { q = ENVIRON["q"]; d = ENVIRON["d"] }
		BEGIN { insh = 0 }
		index($0, q) { insh = ! insh; print "SH"; next }
		index($0, d) { insh = ! insh; print "SH"; next }
		insh == 1 { next }
		{ print }
	' "$repo/Jenkinsfile"
}
jenkins_code > "$work/jenkins.code"
jenkins_groovy > "$work/jenkins.groovy"
awk '/parameters \{/ { inparams = 1 } inparams { print } inparams && /^\t\}/ { exit }' \
	"$repo/Jenkinsfile" > "$work/jenkins.params"
if grep -q "stashedFile(" "$work/jenkins.params" 2>/dev/null &&
	! grep -qE '^[[:space:]]*file\(' "$work/jenkins.params" 2>/dev/null; then
	ok "(C7) the product configuration is a stashed file parameter"
else
	no "(C7) the product configuration is a stashed file parameter"
	sed 's/^/      | /' "$work/jenkins.params" 2>/dev/null
fi
if grep -q "unstash 'PRODUCT_CONF'" "$work/jenkins.code" 2>/dev/null &&
	grep -q 'cp PRODUCT_CONF product.conf' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the pipeline unstashes the product configuration and copies it to product.conf"
else
	no "(C7) the pipeline unstashes the product configuration and copies it to product.conf"
fi
if grep -q 'tar -cf - --exclude=.git .' "$work/jenkins.code" 2>/dev/null &&
	grep -q 'tar -xf -' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the pipeline copies the tree with tar and unpacks it with tar"
else
	no "(C7) the pipeline copies the tree with tar and unpacks it with tar"
fi
if grep -q 'build.sh -c product.conf' "$work/jenkins.code" 2>/dev/null &&
	! grep -q 'build.sh -c .\$PRODUCT_CONF' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the build uses the product configuration the pipeline copied"
else
	no "(C7) the build uses the product configuration the pipeline copied"
fi
if grep -q 'rm -f .ssh/known_hosts' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the pipeline empties the known hosts file of the workspace for every build"
else
	no "(C7) the pipeline empties the known hosts file of the workspace for every build"
fi
if grep -q 'out/SHA256' "$work/jenkins.code" 2>/dev/null &&
	! grep -q 'scp .*-r .*\$addr:.*/out .' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the pipeline brings back the artifacts and the checksum, not the release root"
else
	no "(C7) the pipeline brings back the artifacts and the checksum, not the release root"
fi
# The build in the build VM runs as root: build.sh refuses to build
# anything else. The account of the CI is root, or it has a doas rule
# that needs no password.
if grep -q 'doas sh build.sh' "$work/jenkins.code" 2>/dev/null &&
	grep -q 'id -u' "$work/jenkins.code" 2>/dev/null; then
	ok "(C7) the build in the build VM runs as root"
else
	no "(C7) the build in the build VM runs as root"
	grep -n 'build.sh' "$work/jenkins.code" 2> /dev/null | sed 's/^/      | /'
fi
if grep -q '#' "$work/jenkins.groovy" 2>/dev/null; then
	no "(C7) the pipeline holds no comment outside of a shell string"
	grep -n '#' "$work/jenkins.groovy" | sed 's/^/      | /'
else
	ok "(C7) the pipeline holds no comment outside of a shell string"
fi

# --------------------------------------------------------------------------
# (C8) the package set of the desktop and the configuration of LightDM
# --------------------------------------------------------------------------
c8bad=''
for p in x11/xorg x11/lightdm x11/lightdm-gtk-greeter x11-wm/xfce4 x11-fm/thunar; do
	grep -q "^$p\$" "$repo/overlay/profiles/desktop/packages.list" 2>/dev/null ||
		c8bad="$c8bad $p"
done
if [ -z "$c8bad" ]; then
	ok "(C8) the desktop names the X11 server, the greeter and the session"
else
	no "(C8) the desktop names the X11 server, the greeter and the session:$c8bad"
fi
lightdm="$repo/overlay/profiles/desktop/rootfs/usr/local/etc/lightdm/lightdm.conf.d/50-examplebsd.conf"
if grep -q '^\[Seat:\*\]$' "$lightdm" 2>/dev/null &&
	grep -q '^greeter-session=lightdm-gtk-greeter$' "$lightdm" 2>/dev/null &&
	grep -q '^user-session=xfce$' "$lightdm" 2>/dev/null; then
	ok "(C8) the configuration of LightDM names the greeter and the session of the seat"
else
	no "(C8) the configuration of LightDM names the greeter and the session of the seat"
	sed 's/^/      | /' "$lightdm"
fi
if grep -qE '^(Directory|sessions-directory)=' "$lightdm" 2>/dev/null; then
	no "(C8) the configuration of LightDM holds no key that LightDM does not know"
	grep -nE '^(Directory|sessions-directory)=' "$lightdm" | sed 's/^/      | /'
else
	ok "(C8) the configuration of LightDM holds no key that LightDM does not know"
fi

# --------------------------------------------------------------------------
# (C9) the rc.conf of DragonFly
# --------------------------------------------------------------------------
if [ -f "$repo/overlay/base/rc.conf.d/ntpd" ]; then
	no "(C9) the overlay names no ntpd: DragonFly uses dntpd, and it is on by default"
else
	ok "(C9) the overlay names no ntpd: DragonFly uses dntpd, and it is on by default"
fi
rc_conf=$(printf 'rc_%s' 'configured')
if grep -rn -- "$rc_conf" "$repo" --exclude-dir=.git > "$work/rcconf.log" 2>&1; then
	no "(C9) nothing of the tree asks for rc_configured"
	sed 's/^/      | /' "$work/rcconf.log"
else
	ok "(C9) nothing of the tree asks for rc_configured"
fi
if grep -q '^console="comconsole"$' "$stage/boot/loader.conf" 2>/dev/null &&
	grep -q '^kernel_options="-C"' "$stage/boot/loader.conf" 2>/dev/null; then
	ok "(C9) the console of the appliance is the serial console, and the loader.conf of the release tooling is kept"
else
	no "(C9) the console of the appliance is the serial console, and the loader.conf of the release tooling is kept"
	sed 's/^/      | /' "$stage/boot/loader.conf" 2>/dev/null
fi
if grep -qE '^ttyd0[[:space:]].*[[:space:]]on([[:space:]]|$)' "$stage/etc/ttys" 2>/dev/null &&
	grep -qE '^ttyd0[[:space:]].*[[:space:]]on([[:space:]]|$)' "$stage/etc.hdd/ttys" 2>/dev/null; then
	ok "(C9) the getty of the serial console is on, in the image and in the installer"
else
	no "(C9) the getty of the serial console is on, in the image and in the installer"
	grep -n 'ttyd0' "$stage/etc/ttys" 2>/dev/null | sed 's/^/      | /'
fi
if grep -qi 'hammer2' "$stage/etc/motd" 2>/dev/null; then
	no "(C9) the motd does not claim that the root of the image is HAMMER2"
	sed 's/^/      | /' "$stage/etc/motd" 2>/dev/null
elif grep -qi 'ufs' "$stage/etc/motd" 2>/dev/null; then
	ok "(C9) the motd does not claim that the root of the image is HAMMER2"
else
	no "(C9) the motd does not claim that the root of the image is HAMMER2"
	sed 's/^/      | /' "$stage/etc/motd" 2>/dev/null
fi

# --------------------------------------------------------------------------
# (C10) the dry run prints the commands the real path runs
# --------------------------------------------------------------------------
# The dry run and the real path are the same code: the plan of the dry
# run and the commands of the real run have to be the same lines.
rm -rf "$work/cmp/src" "$work/cmp/out" "$work/cmp/dports"
mkdir -p "$work/cmp/src" "$work/cmp/dports"
cp -R "$repo/tests/fixtures/fake-src/." "$work/cmp/src/"
DPORTS_PATH="$work/cmp/dports" \
	sh "$build" -n -c "$fixture" -s "$work/cmp/src" -o "$work/cmp/out" \
	-p appliance --no-user > "$work/cmp/dry.log" 2>&1
sed -n 's/^    + //p' "$work/cmp/dry.log" |
	grep -E '^(make|pwd_mkdb|chown|chmod) ' > "$work/cmp/plan.cmds"
(
	cd "$work/cmp" || exit 1
	PATH="$repo/tests/stubs:$PATH" \
	STUB_LOG="$work/cmp/stub.log" \
	WTFBSD_TEST_ALLOW_ANY_OS=1 \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	DPORTS_PATH="$work/cmp/dports" \
		sh "$build" -c "$fixture" -s "$work/cmp/src" -o "$work/cmp/out" \
		-p appliance --no-user
) > "$work/cmp/real.log" 2>&1
grep -E '^CMD (make|pwd_mkdb|chown|chmod) ' "$work/cmp/stub.log" 2>/dev/null |
	sed 's/^CMD //' > "$work/cmp/real.cmds"
if [ -s "$work/cmp/plan.cmds" ] &&
	diff -u "$work/cmp/plan.cmds" "$work/cmp/real.cmds" > "$work/cmp/diff" 2>&1; then
	ok "(C10) the dry run prints the commands the real path runs"
else
	no "(C10) the dry run prints the commands the real path runs"
	sed 's/^/      | /' "$work/cmp/diff" 2>/dev/null
fi

# --------------------------------------------------------------------------
# (C11) the leak check
# --------------------------------------------------------------------------
probe_case 'a token of the sk- shape' "$(printf '%s%s' 'sk' '-proj-0123456789abcdefghij')"
# the same token in a binary file: the leak check has to read the binary
# files as well
printf '%s-%s\000binary\n' 'sk' 'proj-0123456789abcdefghij' > "$probe"
if sh "$repo/tests/leak-check.sh" > "$work/probe.log" 2>&1; then
	no "(C11) the leak check scans the binary files as well"
	sed 's/^/      | /' "$work/probe.log"
elif grep -q "$probe_name" "$work/probe.log"; then
	ok "(C11) the leak check scans the binary files as well"
else
	no "(C11) the leak check scans the binary files as well (the file was not named)"
	sed 's/^/      | /' "$work/probe.log"
fi
rm -f "$probe"
probe_case 'an internal domain of the home.arpa shape' \
	"$(printf 'host.%s' 'home.arpa')"
printf '%s\n' "$(printf 'sk-ssh-ed25519@%s' 'openssh.com')" > "$probe"
if sh "$repo/tests/leak-check.sh" > "$work/probe.log" 2>&1; then
	ok "(C11) the leak check does not read the domain of an SSH key type as an address"
else
	no "(C11) the leak check does not read the domain of an SSH key type as an address"
	sed 's/^/      | /' "$work/probe.log"
fi
rm -f "$probe"
if grep -q 'tests/run-tests.sh' "$work/jenkins.code" 2>/dev/null; then
	ok "(C11) the pipeline runs the test suite before it builds"
else
	no "(C11) the pipeline runs the test suite before it builds"
fi

# --------------------------------------------------------------------------
# (C12) the stand-ins refuse the options that are not in the man page
# --------------------------------------------------------------------------
for s in chmod chown pkg pwd_mkdb make; do
	if sh "$repo/tests/stubs/$s" -Zz > "$work/stub.log" 2>&1; then
		no "(C12) the stand-in for $s refuses an option that the man page does not know"
		sed 's/^/      | /' "$work/stub.log"
	elif grep -qi 'option' "$work/stub.log"; then
		ok "(C12) the stand-in for $s refuses an option that the man page does not know"
	else
		no "(C12) the stand-in for $s refuses an option that the man page does not know"
		sed 's/^/      | /' "$work/stub.log"
	fi
done

# --------------------------------------------------------------------------
# (D1) the skeleton of the release tooling is kept: the rootskels of the
#      build hold the skeleton of the release root and the overlay of the
#      product, in that order. The GUI skeleton of nrelease is NOT among
#      them (the overlay carries whatever it needs).
# --------------------------------------------------------------------------
d1log="$work/c1/stub.log"
if grep -q '^VAR ROOTSKELS=.*/nrelease/root .*/rootskels$' "$d1log" 2>/dev/null; then
	ok "(D1) the build hands the skeleton of the release tooling and the overlay to make(1)"
else
	no "(D1) the build hands the skeleton of the release tooling and the overlay to make(1)"
	grep '^VAR ROOTSKELS=' "$d1log" 2>/dev/null | sed 's/^/      | /'
fi
if grep -q '^VAR ROOTSKELS=.*/nrelease/gui .*/rootskels$' "$work/desk/stub.log" 2>/dev/null; then
	no "(D1) the desktop does NOT hand the release tooling's GUI skeleton to make(1)"
	grep '^VAR ROOTSKELS=' "$work/desk/stub.log" 2>/dev/null | sed 's/^/      | /'
else
	ok "(D1) the desktop does NOT hand the release tooling's GUI skeleton to make(1)"
fi
if [ -f "$stage/boot/loader.conf" ] &&
	grep -q '^kernel_options="-C"' "$stage/boot/loader.conf" 2>/dev/null &&
	grep -q '^#vfs.root.mountfrom="ROOT"' "$stage/boot/loader.conf" 2>/dev/null; then
	ok "(D1) the release root holds the loader.conf of the release tooling"
else
	no "(D1) the release root holds the loader.conf of the release tooling"
	sed 's/^/      | /' "$stage/boot/loader.conf" 2>/dev/null
fi
if [ -f "$stage/etc/fstab" ] &&
	grep -qE 'dummy[[:space:]]+/etc[[:space:]]+tmpfs' "$stage/etc/fstab" 2>/dev/null &&
	grep -q '^root_rw_mount="NO"' "$stage/etc/rc.conf" 2>/dev/null; then
	ok "(D1) the release root holds the fstab and the rc.conf of the release tooling"
else
	no "(D1) the release root holds the fstab and the rc.conf of the release tooling"
	sed 's/^/      | /' "$stage/etc/fstab" 2>/dev/null
fi
if [ -f "$stage/etc/motd" ] && grep -q 'ExampleBSD' "$stage/etc/motd" 2>/dev/null &&
	[ -f "$stage/usr/local/etc/doas.conf" ]; then
	ok "(D1) the overlay is in the release root next to the skeleton of the release tooling"
else
	no "(D1) the overlay is in the release root next to the skeleton of the release tooling"
fi

# the stand-in for make(1) models the semantics of the Makefile of the
# release tooling: REQ_ROOTSKELS, ROOTSKELS?= and ROOTSKELS+= under the
# gui modifier, and a ROOTSKELS on the command line replaces all of them
d1mk="$work/mk"
rm -rf "$d1mk"
mkdir -p "$d1mk/root/etc" "$d1mk/gui/etc" "$d1mk/sk/etc"
printf 'from the root skeleton\n' > "$d1mk/root/etc/marker"
printf 'from the gui skeleton\n' > "$d1mk/gui/etc/marker"
printf 'from the overlay\n' > "$d1mk/sk/etc/marker"
cat > "$d1mk/Makefile" <<'MKEOF'
REQ_ROOTSKELS=	${.CURDIR}/root
ROOTSKELS?=	${REQ_ROOTSKELS}
.if make(gui)
ROOTSKELS+=		${.CURDIR}/gui
.endif  # make(gui)

customizeiso:
	@echo "customizeiso"
MKEOF
d1run() { # d1run <out> [make arguments...]
	_d1_out=$1
	shift
	rm -rf "$_d1_out"
	PATH="$repo/tests/stubs:$PATH" STUB_LOG=/dev/null \
		sh "$repo/tests/stubs/make" -C "$d1mk" customizeiso \
		"ISOROOT=$_d1_out" "$@" > "$d1mk/log" 2>&1
}
d1run "$d1mk/out-default"
if [ -f "$d1mk/out-default/etc/marker" ] &&
	grep -q 'from the root skeleton' "$d1mk/out-default/etc/marker" 2>/dev/null; then
	ok "(D1) the stand-in for make(1) uses the skeleton of the Makefile by itself"
else
	no "(D1) the stand-in for make(1) uses the skeleton of the Makefile by itself"
	sed 's/^/      | /' "$d1mk/log" 2>/dev/null
fi
d1run "$d1mk/out-gui" gui
if [ -f "$d1mk/out-gui/etc/marker" ] &&
	grep -q 'from the gui skeleton' "$d1mk/out-gui/etc/marker" 2>/dev/null; then
	ok "(D1) the stand-in for make(1) adds the skeleton of the GUI under the gui modifier"
else
	no "(D1) the stand-in for make(1) adds the skeleton of the GUI under the gui modifier"
	sed 's/^/      | /' "$d1mk/log" 2>/dev/null
fi
d1run "$d1mk/out-cmdline" "ROOTSKELS=$d1mk/sk"
if [ -f "$d1mk/out-cmdline/etc/marker" ] &&
	grep -q 'from the overlay' "$d1mk/out-cmdline/etc/marker" 2>/dev/null &&
	[ ! -f "$d1mk/out-cmdline/etc/other" ]; then
	ok "(D1) a ROOTSKELS on the command line replaces every default of the Makefile"
else
	no "(D1) a ROOTSKELS on the command line replaces every default of the Makefile"
	sed 's/^/      | /' "$d1mk/log" 2>/dev/null
fi

# --------------------------------------------------------------------------
# (D2) the packages are DPorts origins: pkg_add takes category/port only
# --------------------------------------------------------------------------
d2bad=''
for d2list in "$repo/overlay/base/packages.list" \
	"$repo/overlay/profiles/appliance/packages.list" \
	"$repo/overlay/profiles/desktop/packages.list"; do
	while IFS= read -r d2line; do
		case $d2line in '' | '#'*) continue ;; esac
		printf '%s\n' "$d2line" | grep -qE '^[a-z0-9-]+/[A-Za-z0-9._+-]+$' ||
			d2bad="$d2bad $d2line"
	done < "$d2list"
done
if [ -z "$d2bad" ]; then
	ok "(D2) every package of the overlay is a DPorts origin (category/port)"
else
	no "(D2) every package of the overlay is a DPorts origin (category/port):$d2bad"
fi
if grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*security/doas' "$d1log" 2>/dev/null &&
	grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*security/ca_root_nss' "$d1log" 2>/dev/null; then
	ok "(D2) the origins of the base list reach the release tooling"
else
	no "(D2) the origins of the base list reach the release tooling"
	grep '^VAR DPORTS_EXTRA_PACKAGES=' "$d1log" 2>/dev/null | sed 's/^/      | /'
fi
# a list with a bare name is refused: pkg_add would not take it
rm -rf "$work/badrepo"
mkdir -p "$work/badrepo"
( cd "$repo" && tar -cf - --exclude=.git . ) | ( cd "$work/badrepo" && tar -xf - )
printf 'doas\n' >> "$work/badrepo/overlay/base/packages.list"
sh "$work/badrepo/build.sh" -n -c "$fixture" --no-user -o "$work/out" > "$work/d2.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'origin' "$work/d2.log" 2>/dev/null; then
	ok "(D2) the build refuses a package that is not a DPorts origin"
else
	no "(D2) the build refuses a package that is not a DPorts origin (rc=$rc)"
	sed 's/^/      | /' "$work/d2.log" 2>/dev/null
fi
if grep -q '/usr/dports' "$repo/README.md" 2>/dev/null &&
	grep -q 'DPORTS_PATH' "$repo/README.md" 2>/dev/null; then
	ok "(D2) the README names the DPorts tree the packages are built from"
else
	no "(D2) the README names the DPorts tree the packages are built from"
fi

# --------------------------------------------------------------------------
# (D3) the login path: a first-boot user, the installer account of the
#      desktop ISO and the live media with a read-only home directory
# --------------------------------------------------------------------------
# A dry run changes nothing, so it does not refuse to plan an image
# without an account: it says what the real build would refuse and goes
# on.
sh "$build" -n -c "$fixture" -o "$work/out" > "$work/d3-nouser.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q 'login    WARNING: no first-boot user given (the real build needs -u or --no-user)' \
		"$work/d3-nouser.log" 2>/dev/null; then
	ok "(D3) the dry run without a first-boot user warns and goes on"
else
	no "(D3) the dry run without a first-boot user warns and goes on (rc=$rc)"
	sed 's/^/      | /' "$work/d3-nouser.log" 2>/dev/null
fi
# The real build refuses: an image without an account is an image nobody
# can log into.
rm -rf "$work/d3real/src" "$work/d3real/out" "$work/d3real/dports"
mkdir -p "$work/d3real/src" "$work/d3real/dports"
cp -R "$repo/tests/fixtures/fake-src/." "$work/d3real/src/"
PATH="$repo/tests/stubs:$PATH" \
	STUB_LOG="$work/d3real/stub.log" \
	WTFBSD_TEST_ALLOW_ANY_OS=1 \
	WTFBSD_TEST_ALLOW_NONROOT=1 \
	DPORTS_PATH="$work/d3real/dports" \
	sh "$build" -c "$fixture" -s "$work/d3real/src" -o "$work/d3real/out" -p appliance \
	> "$work/d3-nouser-real.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'no first-boot user' "$work/d3-nouser-real.log" 2>/dev/null; then
	ok "(D3) the real build refuses to make an image without a first-boot user"
else
	no "(D3) the real build refuses to make an image without a first-boot user (rc=$rc)"
	sed 's/^/      | /' "$work/d3-nouser-real.log" 2>/dev/null
fi
sh "$build" -n -c "$fixture" --no-user -o "$work/out" > "$work/d3-nouser2.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -qi 'nobody can log in' "$work/d3-nouser2.log" 2>/dev/null; then
	ok "(D3) --no-user builds an image and says that nobody can log in"
else
	no "(D3) --no-user builds an image and says that nobody can log in (rc=$rc)"
	sed 's/^/      | /' "$work/d3-nouser2.log" 2>/dev/null
fi
deskstage="$work/desk/out/desktop/root"
# The desktop has no sshd: the skeleton of the GUI of the release
# tooling enables it, the overlay of the desktop says no, and the
# overlay owns the variable.
if [ -f "$repo/overlay/profiles/desktop/rc.conf.d/sshd" ] &&
	grep -q '^sshd_enable="NO"$' "$repo/overlay/profiles/desktop/rc.conf.d/sshd" 2>/dev/null &&
	grep -q '^sshd_enable="NO"$' "$deskstage/etc/rc.conf" 2>/dev/null &&
	grep -q '^sshd_enable="NO"$' "$deskstage/etc.hdd/rc.conf" 2>/dev/null; then
	ok "(D3) the desktop has no sshd, in the live media and in the installed system"
else
	no "(D3) the desktop has no sshd, in the live media and in the installed system"
	sed 's/^/      | /' "$deskstage/etc/rc.conf" 2>/dev/null
	sed 's/^/      | /' "$deskstage/etc.hdd/rc.conf" 2>/dev/null
fi
if grep -q '^installer::0:0:' "$deskstage/etc/master.passwd" 2>/dev/null; then
	ok "(D3) the desktop ISO keeps the installer account of the release tooling"
else
	no "(D3) the desktop ISO keeps the installer account of the release tooling"
	sed 's/^/      | /' "$deskstage/etc/master.passwd" 2>/dev/null
fi
d3uid0=''
if [ -f "$deskstage/etc.hdd/master.passwd" ]; then
	while IFS=: read -r d3u _d3p _d3id _d3g _d3c _d3h _d3s; do
		[ -n "$d3u" ] || continue
		[ "$_d3id" = 0 ] || continue
		case $_d3p in
		'*' | '!' | '!!') ;;
		*) d3uid0="$d3uid0 $d3u($_d3p)" ;;
		esac
	done < "$deskstage/etc.hdd/master.passwd"
fi
if [ -z "$d3uid0" ]; then
	ok "(D3) no uid-0 account of the tree of the installer has a password that can be typed"
else
	no "(D3) no uid-0 account of the tree of the installer has a password that can be typed:$d3uid0"
fi
if grep -q "wtfbsd-ci-ssh-pubkey" "$repo/Jenkinsfile" 2>/dev/null &&
	grep -q "wtfbsd-ci-password-hash" "$repo/Jenkinsfile" 2>/dev/null &&
	grep -q 'CI_SSH_PUBKEY' "$repo/Jenkinsfile" 2>/dev/null &&
	grep -q 'CI_PASSWORD_HASH' "$repo/Jenkinsfile" 2>/dev/null; then
	ok "(D3) the pipeline hands the key and the password hash of the CI to the build"
else
	no "(D3) the pipeline hands the key and the password hash of the CI to the build"
fi

# the live media has a read-only home directory: the first-boot script
# creates nothing there and says so
if [ "$(id -u)" = 0 ]; then
	skip "(D3) the first-boot script creates nothing when the home directory is read-only (the suite runs as root)"
else
	rm -rf "$work/fbro"
	mkdir -p "$work/fbro/etc/rc.d" "$work/fbro/boot" "$work/fbro/usr/local/etc" "$work/fbro/home"
	cp "$work/fbroot/etc/rc.subr" "$work/fbro/etc/rc.subr"
	sed -e 's#/etc/rc\.subr#@R@/etc/rc.subr#g' \
		-e 's#/etc/master\.passwd#@R@/etc/master.passwd#g' \
		-e 's#/etc/passwd#@R@/etc/passwd#g' \
		-e 's#/boot/firstboot-user\.conf#@R@/boot/firstboot-user.conf#g' \
		-e 's#/usr/local/etc/doas\.conf#@R@/usr/local/etc/doas.conf#g' \
		-e 's#/home#@R@/home#g' \
		-e 's#/firstboot\([^a-z-]\)#@R@/firstboot\1#g' \
		-e 's#/firstboot$#@R@/firstboot#g' \
		"$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" |
		sed "s#@R@#$work/fbro#g" > "$work/fbro/etc/rc.d/firstboot_user"
	chmod 755 "$work/fbro/etc/rc.d/firstboot_user"
	printf 'ciuser:x:1001:1001:Ci User:%s/home/ciuser:/bin/sh\n' "$work/fbro" \
		> "$work/fbro/etc/passwd"
	printf 'USERNAME=ciuser\nSSH_KEY=%s %s testkey\n' 'ssh-ed25519' 'AAAAtest' \
		> "$work/fbro/boot/firstboot-user.conf"
	printf 'permit persist :wheel\n' > "$work/fbro/usr/local/etc/doas.conf"
	chmod 555 "$work/fbro/home"
	: > "$work/pwro.log"
	PATH="$work/fakebin:$PATH" PW_LOG="$work/pwro.log" LOGGER_LOG="$work/loggerro.log" \
		sh "$work/fbro/etc/rc.d/firstboot_user" start > "$work/fbro.log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ] && [ ! -s "$work/pwro.log" ] &&
		grep -qi 'not writable' "$work/fbro.log" 2>/dev/null; then
		ok "(D3) the first-boot script creates nothing when the home directory is read-only"
	else
		no "(D3) the first-boot script creates nothing when the home directory is read-only (rc=$rc)"
		sed 's/^/      | /' "$work/fbro.log" 2>/dev/null
	fi
	chmod 755 "$work/fbro/home"
fi

# --------------------------------------------------------------------------
# (D4) the serial console: the console of the kernel is set in
#      /boot/loader.conf and only the status of the getty changes
# --------------------------------------------------------------------------
if grep -q '^console="comconsole"$' "$stage/boot/loader.conf" 2>/dev/null &&
	grep -q '^kernel_options="-C"' "$stage/boot/loader.conf" 2>/dev/null; then
	ok "(D4) the console of the kernel is set in the loader.conf of the release root, and the file of the release tooling is kept"
else
	no "(D4) the console of the kernel is set in the loader.conf of the release root, and the file of the release tooling is kept"
	sed 's/^/      | /' "$stage/boot/loader.conf" 2>/dev/null
fi
if [ -f "$stage/etc/loader.conf" ]; then
	no "(D4) the release root holds no loader.conf in /etc: the loader reads /boot/loader.conf"
	sed 's/^/      | /' "$stage/etc/loader.conf" 2>/dev/null
else
	ok "(D4) the release root holds no loader.conf in /etc: the loader reads /boot/loader.conf"
fi
# the post-customize step on a release root of its own: the status of the
# getty changes, the terminal type stays
d4root="$work/d4root"
rm -rf "$d4root"
mkdir -p "$d4root/etc" "$d4root/boot" "$d4root/etc.hdd" "$d4root/sk/etc"
printf 'ttyd0\t"/usr/libexec/getty std.9600"\tdialup\toff secure\n' > "$d4root/etc/ttys"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$d4root/etc/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$d4root/etc/passwd"
printf '# stock rc.conf\nhostname="localhost"\n' > "$d4root/etc/rc.conf"
printf '# stock rc.conf of the installed system\n' > "$d4root/etc.hdd/rc.conf"
sh "$repo/tools/post-customize.sh" "$d4root" "$work/norc" "$work/norc" \
	"$d4root/sk" ttyd0 comconsole - - > "$d4root/log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -qE '^ttyd0[[:space:]]+"/usr/libexec/getty std.9600"[[:space:]]+dialup[[:space:]]+on([[:space:]]|$)' \
		"$d4root/etc/ttys" 2>/dev/null; then
	ok "(D4) the getty of the serial console is switched on and the terminal type is kept"
else
	no "(D4) the getty of the serial console is switched on and the terminal type is kept (rc=$rc)"
	sed 's/^/      | /' "$d4root/etc/ttys" 2>/dev/null
	sed 's/^/      | /' "$d4root/log" 2>/dev/null
fi
if grep -q '^console="comconsole"$' "$d4root/boot/loader.conf" 2>/dev/null; then
	ok "(D4) the console of the kernel is written into /boot/loader.conf"
else
	no "(D4) the console of the kernel is written into /boot/loader.conf"
	sed 's/^/      | /' "$d4root/boot/loader.conf" 2>/dev/null
fi
if grep -qE '^ttyd0[[:space:]]+"/usr/libexec/getty std.9600"[[:space:]]+dialup[[:space:]]+on([[:space:]]|$)' \
	"$repo/tests/fixtures/fake-src/nrelease/root/etc/ttys" 2>/dev/null; then
	ok "(D4) the skeleton of the release tooling holds the line of the serial console in the shape of the upstream file"
else
	no "(D4) the skeleton of the release tooling holds the line of the serial console in the shape of the upstream file"
	sed 's/^/      | /' "$repo/tests/fixtures/fake-src/nrelease/root/etc/ttys" 2>/dev/null
fi

# --------------------------------------------------------------------------
# (D5) the pipeline: the stashed file parameter is not unstashed twice
# --------------------------------------------------------------------------
if grep -q "stashedFile(name:" "$work/jenkins.code" 2>/dev/null; then
	no "(D5) the pipeline does not call the stashedFile() step again"
	grep -n "stashedFile(name:" "$work/jenkins.code" 2>/dev/null | sed 's/^/      | /'
else
	ok "(D5) the pipeline does not call the stashedFile() step again"
fi
if grep -q "stashedFile(" "$work/jenkins.code" 2>/dev/null &&
	grep -q "unstash 'PRODUCT_CONF'" "$work/jenkins.code" 2>/dev/null &&
	grep -q 'cp PRODUCT_CONF product.conf' "$work/jenkins.code" 2>/dev/null; then
	ok "(D5) the product configuration is a stashed file parameter that the pipeline unstashes"
else
	no "(D5) the product configuration is a stashed file parameter that the pipeline unstashes"
fi

# --------------------------------------------------------------------------
# (D6) the tree of the installer: the /etc of the overlay, a locked root
#      and no fstab of the live media
# --------------------------------------------------------------------------
if [ -f "$stage/etc.hdd/motd" ] && grep -q 'ExampleBSD' "$stage/etc.hdd/motd" 2>/dev/null &&
	[ -f "$stage/etc.hdd/rc.d/firstboot_user" ]; then
	ok "(D6) the /etc of the overlay is in the tree of the installer"
else
	no "(D6) the /etc of the overlay is in the tree of the installer"
	ls -R "$stage/etc.hdd" 2>/dev/null | sed 's/^/      | /'
fi
if [ -f "$stage/etc.hdd/master.passwd" ] &&
	[ "$(awk -F: '$1 == "root" { print $2 }' "$stage/etc.hdd/master.passwd")" = '*' ]; then
	ok "(D6) the root account of the tree of the installer is locked"
else
	no "(D6) the root account of the tree of the installer is locked"
	sed 's/^/      | /' "$stage/etc.hdd/master.passwd" 2>/dev/null
fi
if [ -f "$stage/etc.hdd/fstab" ]; then
	no "(D6) the fstab of the live media is not in the tree of the installer"
	sed 's/^/      | /' "$stage/etc.hdd/fstab" 2>/dev/null
else
	ok "(D6) the fstab of the live media is not in the tree of the installer"
fi
if grep -q "^CMD pwd_mkdb -p -d $stage/etc.hdd $stage/etc.hdd/master.passwd\$" "$d1log" 2>/dev/null; then
	ok "(D6) the build rebuilds the password database of the tree of the installer"
else
	no "(D6) the build rebuilds the password database of the tree of the installer"
	grep '^CMD pwd_mkdb ' "$d1log" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (D7) the world is built once and the media are built after the
#      post-customize step
# --------------------------------------------------------------------------
REAL_PROFILE=both realbuild "$work/both2" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
d7world=$(grep -c '^TARGET buildworld1$' "$work/both2/stub.log" 2>/dev/null || true)
case $d7world in
'' | *[!0-9]*) d7world=0 ;;
esac
if [ "$d7world" = 1 ]; then
	ok "(D7) the world is built once for a build of both profiles"
else
	no "(D7) the world is built once for a build of both profiles (got $d7world)"
	grep '^TARGET ' "$work/both2/stub.log" 2>/dev/null | sed 's/^/      | /'
fi
d7media="$work/c1/out/appliance/examplebsd-appliance-amd64.img"
if grep -q '^media call 1$' "$d7media" 2>/dev/null; then
	ok "(D7) the media are built once"
else
	no "(D7) the media are built once"
	sed 's/^/      | /' "$d7media" 2>/dev/null
fi
if grep -q 'console="comconsole"' "$d7media" 2>/dev/null; then
	ok "(D7) the media are built after the post-customize step"
else
	no "(D7) the media are built after the post-customize step"
	sed 's/^/      | /' "$d7media" 2>/dev/null
fi
if [ -f "$work/c1/out/appliance/mnt/firstboot" ]; then
	ok "(D7) the image root holds the sentinel of the first boot"
else
	no "(D7) the image root holds the sentinel of the first boot"
	ls -R "$work/c1/out/appliance/mnt" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (D8) the devices of the CI, the stand-ins and the leak check
# --------------------------------------------------------------------------
d8u1=$(EXECUTOR_NUMBER=3 WTFBSD_VM_SLOT=0 WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" unit vm1 2>&1 || true)
d8u2=$(EXECUTOR_NUMBER=3 WTFBSD_VM_SLOT=1 WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" unit vm2 2>&1 || true)
d8u3=$(EXECUTOR_NUMBER=4 WTFBSD_VM_SLOT=0 WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" unit vm1 2>&1 || true)
# the profile both uses the slots 0, 1 and 2 of a job: the unit of the
# slot 2 of one job may not be the unit of the slot 0 of the next one
d8u4=$(EXECUTOR_NUMBER=3 WTFBSD_VM_SLOT=2 WTFBSD_TEST_ALLOW_NONROOT=1 \
	sh "$repo/ci/providers/bhyve.sh" unit vm3 2>&1 || true)
if [ "$d8u1" = 9 ] && [ "$d8u2" = 10 ] && [ "$d8u3" = 12 ] && [ "$d8u4" = 11 ]; then
	ok "(D8) the unit of a VM follows the executor and the slot of the VM, without a modulo"
else
	no "(D8) the unit of a VM follows the executor and the slot of the VM, without a modulo (got: $d8u1 $d8u2 $d8u3 $d8u4)"
fi
if grep -qE 'tap[0-9]+ destroy' "$work/fake.log" 2>/dev/null; then
	ok "(D8) the provider destroys the tap device that it created"
else
	no "(D8) the provider destroys the tap device that it created"
	sed 's/^/      | /' "$work/fake.log" 2>/dev/null
fi
d8stub=0
for d8s in chown chmod; do
	if sh "$repo/tests/stubs/$d8s" -c 755 "$work" > "$work/d8-stub.log" 2>&1; then
		d8stub=1
	fi
done
if [ "$d8stub" = 0 ]; then
	ok "(D8) the stand-ins for chown and chmod refuse an option that the BSD man page does not know"
else
	no "(D8) the stand-ins for chown and chmod refuse an option that the BSD man page does not know"
	sed 's/^/      | /' "$work/d8-stub.log" 2>/dev/null
fi
if [ -f "$stage/etc/pwd.db" ] && [ -f "$stage/etc/spwd.db" ] &&
	[ -f "$stage/etc.hdd/pwd.db" ] && [ -f "$stage/etc.hdd/spwd.db" ]; then
	ok "(D8) the build writes the password databases of the image and of the tree of the installer"
else
	no "(D8) the build writes the password databases of the image and of the tree of the installer"
	ls "$stage/etc" "$stage/etc.hdd" 2>/dev/null | sed 's/^/      | /'
fi
# the guarded rmrf refuses a path outside the output directory
{
	sed -n '/^die() {/,/^}/p' "$repo/build.sh"
	sed -n '/^rmrf() {/,/^}/p' "$repo/build.sh"
} > "$work/rmrf.sh"
mkdir -p "$work/outside"
( . "$work/rmrf.sh"; rmrf "$work/outside" "$work/out" ) > "$work/d8-rmrf.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ -d "$work/outside" ]; then
	ok "(D8) the guarded rmrf refuses a path outside the output directory"
else
	no "(D8) the guarded rmrf refuses a path outside the output directory (rc=$rc)"
	sed 's/^/      | /' "$work/d8-rmrf.log" 2>/dev/null
fi
if grep -q 'rmrf "\$SK" "\$OUT"' "$repo/build.sh" 2>/dev/null; then
	ok "(D8) the build removes the staged overlay through the guarded rmrf"
else
	no "(D8) the build removes the staged overlay through the guarded rmrf"
fi
probe_case 'a name of the localdomain shape' "$(printf 'host.lo%s' 'caldomain')"

# the probe of the leak check keeps its path: a loop variable of the
# plan check must not overwrite it, or the leak check writes its probe
# file into the working directory
if [ "$probe" = "$repo/.leak-probe.tmp" ]; then
	ok "(D8) the probe of the leak check keeps its path"
else
	no "(D8) the probe of the leak check keeps its path (got: $probe)"
fi
# the probe file lives inside the repository, so that the leak check
# (which scans the repository) finds the shape that is probed: the case
# holds whatever the working directory of the suite is
mkdir -p "$work/probecwd"
probecwd=$( cd "$work/probecwd" &&
	probe_case 'dotted-quad address' "$(printf '10.1.%s.3' 2)" )
if printf '%s' "$probecwd" | grep -q '^PASS'; then
	ok "(D8) the leak check finds a shape that is probed outside the repository"
else
	no "(D8) the leak check finds a shape that is probed outside the repository"
	printf '%s\n' "$probecwd" | sed 's/^/      | /'
fi
# the working directory holds no file of the shape of a probe case
stray=$(find . -maxdepth 1 -type f -name '*: *' 2>/dev/null | head -5)
if [ -z "$stray" ]; then
	ok "(D8) the working directory holds no file of the shape of a probe case"
else
	no "(D8) the working directory holds no file of the shape of a probe case"
	printf '%s\n' "$stray" | sed 's/^/      | /'
fi
if [ -z "$(ls -A "$work/probecwd" 2>/dev/null)" ]; then
	ok "(D8) the working directory of a probe case holds no file"
else
	no "(D8) the working directory of a probe case holds no file"
	ls -A "$work/probecwd" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (E) the placeholders of the fragments and the getty of the installer
# --------------------------------------------------------------------------
# The rc.conf(5) fragments of the overlay hold the placeholders of the
# product: the hostname of the product is its slug. The fragments are
# staged and substituted like the files of the overlay, and the overlay
# itself is never edited.
sed "s/^DISTRO_SLUG=.*/DISTRO_SLUG=otherbsd/" "$fixture" > "$work/other.conf"
REAL_CONF="$work/other.conf"
export REAL_CONF
REAL_PROFILE=appliance realbuild "$work/other"
unset REAL_CONF
ostage="$work/other/out/appliance/root"
if [ "$realrc" -eq 0 ] &&
	grep -q '^hostname="otherbsd"$' "$ostage/etc/rc.conf" 2>/dev/null &&
	grep -q '^hostname="otherbsd"$' "$ostage/etc.hdd/rc.conf" 2>/dev/null &&
	! grep -q '@SLUG@' "$ostage/etc/rc.conf" 2>/dev/null &&
	! grep -q '@SLUG@' "$ostage/etc.hdd/rc.conf" 2>/dev/null; then
	ok "(E) the hostname of the merged rc.conf is the slug of the product"
else
	no "(E) the hostname of the merged rc.conf is the slug of the product (rc=$realrc)"
	sed 's/^/      | /' "$ostage/etc/rc.conf" 2>/dev/null
	sed 's/^/      | /' "$ostage/etc.hdd/rc.conf" 2>/dev/null
fi
if grep -q '^hostname="@SLUG@"$' "$repo/overlay/base/rc.conf.d/hostname" 2>/dev/null; then
	ok "(E) the fragment of the hostname holds the placeholder of the slug"
else
	no "(E) the fragment of the hostname holds the placeholder of the slug"
	sed 's/^/      | /' "$repo/overlay/base/rc.conf.d/hostname" 2>/dev/null
fi
# The tree of the installer has a ttys of its own: the serial console of
# the installed system is switched on there as well.
if grep -qE '^ttyd0[[:space:]].*[[:space:]]off([[:space:]]|$)' \
	"$repo/tests/fixtures/fake-src/nrelease/root/etc.hdd/ttys" 2>/dev/null &&
	grep -qE '^ttyd0[[:space:]].*[[:space:]]on([[:space:]]|$)' "$stage/etc/ttys" 2>/dev/null &&
	grep -qE '^ttyd0[[:space:]].*[[:space:]]on([[:space:]]|$)' "$stage/etc.hdd/ttys" 2>/dev/null; then
	ok "(E) the getty of the serial console is on, in the image and in the installer"
else
	no "(E) the getty of the serial console is on, in the image and in the installer"
	grep -n 'ttyd0' "$stage/etc.hdd/ttys" 2>/dev/null | sed 's/^/      | /'
fi

# (C13) the desktop ships every X video and input driver DPorts has and the
#      GPU userland (x11/xorg alone brings only the xorg-drivers defaults)
c9bad=''
for p in x11-drivers/xf86-video-amdgpu x11-drivers/xf86-video-ast \
	x11-drivers/xf86-video-ati x11-drivers/xf86-video-dummy \
	x11-drivers/xf86-video-intel x11-drivers/xf86-video-mga \
	x11-drivers/xf86-video-nv x11-drivers/xf86-video-scfb \
	x11-drivers/xf86-video-vesa x11-drivers/xf86-input-egalax \
	x11-drivers/xf86-input-elographics x11-drivers/xf86-input-evdev \
	x11-drivers/xf86-input-joystick x11-drivers/xf86-input-keyboard \
	x11-drivers/xf86-input-libinput x11-drivers/xf86-input-mouse \
	x11-drivers/xf86-input-synaptics x11-drivers/xf86-input-void \
	x11-drivers/xf86-input-wacom graphics/mesa-dri graphics/mesa-libs \
	multimedia/libva-intel-driver multimedia/libva-intel-media-driver; do
	grep -q "^$p\$" "$repo/overlay/profiles/desktop/packages.list" 2>/dev/null ||
		c9bad="$c9bad $p"
done
if [ -z "$c9bad" ]; then
	ok "(C13) the desktop ships every X driver of DPorts and the GPU userland"
else
	no "(C13) the desktop ships every X driver of DPorts and the GPU userland:$c9bad"
fi

# --------------------------------------------------------------------------
# the eight defects the first real 6.4.2 build found: one red/green test
# each, proving the behaviour that the fix introduced (each would be red
# without the fix)
# --------------------------------------------------------------------------

PASS='$6$wtfsbsd$0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuv'

# (1) media vs ISO: the desktop ships a disk image by default (the 6.4 EFI
#      loader cannot read past 2 GiB of an ISO), not an ISO
REAL_PROFILE=desktop realbuild "$work/f6" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] &&
	[ -f "$realout/desktop/examplebsd-desktop-amd64.img" ] &&
	! [ -f "$realout/desktop/examplebsd-desktop-amd64.iso" ]; then
	ok "(F6) the desktop ships a disk image by default, no ISO"
else
	no "(F6) the desktop ships a disk image by default, no ISO (rc=$realrc)"
	sed 's/^/      | /' "$work/f6/build.log" 2>/dev/null
fi

# (3) IMGSIZE_MB: the size is the APPARENT size of the staged root (the
#      sum of the sizes of its files) plus 25% and 512 MiB, handed to
#      nrelease over the environment, so the image carries it; the dry
#      run echoes the command without the size. The release root gets a
#      sparse file of 3 MiB and du(1) reports a compressed size (a
#      HAMMER2 build host): a stand-in du prints 8 KiB for every path, in
#      the format of du(1) ("<KiB><TAB><path>"), so a size taken from du
#      is not the apparent size and the test tells them apart.
mkdir -p "$work/f1extra/nrelease/root/usr/share/f1" "$work/f1du"
dd if=/dev/zero of="$work/f1extra/nrelease/root/usr/share/f1/sparse.bin" \
	bs=1024 count=1 seek=3071 2>/dev/null
cat > "$work/f1du/du" <<'FAKEDU'
#!/bin/sh
# a du(1) of a compressed filesystem: every path takes 8 KiB on disk
for _a in "$@"; do
	case $_a in
	-*) ;;
	*) printf '8\t%s\n' "$_a" ;;
	esac
done
exit 0
FAKEDU
chmod 755 "$work/f1du/du"
f1path=$PATH
PATH="$work/f1du:$PATH"
REAL_SRC_EXTRA="$work/f1extra" realbuild "$work/f1" -u ciuser -k "$work/ci.pub"
PATH=$f1path
f1got=$(sed -n 's/^image-size: //p' "$realout/appliance/examplebsd-appliance-amd64.img" 2>/dev/null | head -1)
f1kb=$(find "$realout/appliance/root" -type f | while IFS= read -r _f; do wc -c < "$_f"; done |
	awk '{ s += $1 } END { print int(s / 1024) }')
f1want=$((f1kb / 1024 * 125 / 100 + 512))
if [ "$realrc" -eq 0 ] && [ -n "$f1got" ] && [ "$f1got" = "$f1want" ] && [ "$f1want" -gt 512 ]; then
	ok "(F1) the real build hands the apparent size of the release root (+25% +512 MiB) to nrelease as IMGSIZE_MB ($f1got MiB)"
else
	no "(F1) the real build hands the apparent size of the release root (+25% +512 MiB) to nrelease as IMGSIZE_MB (rc=$realrc, got ${f1got:-none}, want $f1want)"
	sed 's/^/      | /' "$work/f1/build.log" 2>/dev/null | tail -20
fi
# the code lines of build.sh (the comments left out)
f1code=$(grep -v '^[[:space:]]*#' "$build")
if [ "$(printf '%s\n' "$f1code" | grep -c 'stat -f %z')" -eq 1 ] &&
	! printf '%s\n' "$f1code" | grep -qE '(^|[^a-z])du[[:space:]]'; then
	ok "(F1) the apparent size is computed once, with stat -f %z (no du)"
else
	no "(F1) the apparent size is computed once, with stat -f %z (no du)"
	grep -n 'stat -f\|du -' "$build" | sed 's/^/      | /'
fi
sh "$build" -n -c "$fixture" -s "$work/f1/src" -o "$work/f1/dry" -p appliance --no-user > "$work/f1/dry.log" 2>&1
if ! grep -q 'IMGSIZE_MB' "$work/f1/dry.log"; then
	ok "(F1) the dry run echoes the command without the image size"
else
	no "(F1) the dry run echoes the command without the image size"
	sed 's/^/      | /' "$work/f1/dry.log" 2>/dev/null
fi

# (5) password-hash leak: the hash is baked into the image, but it is read
#      from the file inside the command that writes the configuration, so
#      it never reaches the transcript, nor the argv of step() on the
#      real path: the real build runs under sh -x, which prints the argv
#      of every command (an argv that holds the script of sh -c spans
#      several lines of the trace). The hash may appear in the trace only
#      where build.sh validates the file (the assignment of FBHASH and
#      its test [ -n ... ]); any other line that holds it is a leak.
REAL_XTRACE=1 realbuild "$work/f5x" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
f5x=$(grep -F "$PASS" "$work/f5x/build.log" 2>/dev/null |
	grep -vE "^[+]+ (FBHASH=|'?\\['? -n )" | grep -c . || true)
if [ "$realrc" -eq 0 ] && [ "$f5x" -eq 0 ] &&
	grep -qF "PASSWORD_HASH=$PASS" "$work/f5x/out/appliance/root/boot/firstboot-user.conf" 2>/dev/null; then
	ok "(F5) on the real path the password hash is never on the argv of step()"
else
	no "(F5) on the real path the password hash is never on the argv of step() (rc=$realrc, $f5x traced lines carry it)"
	grep -F "$PASS" "$work/f5x/build.log" 2>/dev/null | grep -vE "^[+]+ (FBHASH=|'?\\['? -n )" |
		cut -c1-160 | sed 's/^/      | /'
fi
# the configuration may hold a hash: it is mode 0600 in the staged tree
f5mode=$(ls -l "$work/f5x/out/appliance/rootskels/boot/firstboot-user.conf" 2>/dev/null | cut -c1-10)
f5rmode=$(ls -l "$work/f5x/out/appliance/root/boot/firstboot-user.conf" 2>/dev/null | cut -c1-10)
if [ "$f5mode" = '-rw-------' ] && [ "$f5rmode" = '-rw-------' ]; then
	ok "(F5) /boot/firstboot-user.conf is mode 0600 in the staged tree and in the release root"
else
	no "(F5) /boot/firstboot-user.conf is mode 0600 in the staged tree and in the release root (got ${f5mode:-none} / ${f5rmode:-none})"
fi
# the directory of the configuration is /boot of the image: 0755, never
# the 0700 of the umask that protects the configuration
f5b=$(ls -ld "$work/f5x/out/appliance/rootskels/boot" 2>/dev/null | cut -c1-10)
if [ "$f5b" = 'drwxr-xr-x' ]; then
	ok "(F5) the staged /boot that holds the configuration is mode 0755"
else
	no "(F5) the staged /boot that holds the configuration is mode 0755 (got ${f5b:-none})"
fi
# ... and it is 0600 from its creation: a chmod(1) put before the
# stand-ins records the mode of the configuration BEFORE build.sh
# changes it, then hands the call to the stand-in
mkdir -p "$work/f5u/bin"
cat > "$work/f5u/bin/chmod" <<FAKECHMOD
#!/bin/sh
for _a in "\$@"; do
	case \$_a in
	*/boot/firstboot-user.conf) ls -l "\$_a" | cut -c1-10 >> "$work/f5u/modes" ;;
	esac
done
exec "$repo/tests/stubs/chmod" "\$@"
FAKECHMOD
chmod 755 "$work/f5u/bin/chmod"
: > "$work/f5u/modes"
REAL_PATH_PREFIX="$work/f5u/bin" realbuild "$work/f5u" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
f5u=$(sort -u "$work/f5u/modes")
if [ "$realrc" -eq 0 ] && [ "$f5u" = '-rw-------' ]; then
	ok "(F5) /boot/firstboot-user.conf is created 0600 (before its chmod), never readable by others"
else
	no "(F5) /boot/firstboot-user.conf is created 0600 (before its chmod), never readable by others (rc=$realrc, modes: ${f5u:-none})"
fi
realbuild "$work/f2" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] &&
	! grep -qF "$PASS" "$work/f2/build.log" 2>/dev/null &&
	! grep -qF "$PASS" "$work/f2/stub.log" 2>/dev/null; then
	ok "(F5) the password hash is baked into the image but never reaches the build transcript"
else
	no "(F5) the password hash is baked into the image but never reaches the build transcript (rc=$realrc)"
	sed 's/^/      | /' "$work/f2/build.log" 2>/dev/null
fi
if [ -f "$work/f2/out/appliance/root/boot/firstboot-user.conf" ] &&
	grep -qF "PASSWORD_HASH=$PASS" "$work/f2/out/appliance/root/boot/firstboot-user.conf"; then
	ok "(F5) the password hash is baked into the first-boot configuration"
else
	no "(F5) the password hash is baked into the first-boot configuration"
fi
sh "$build" -n -c "$fixture" -s "$work/f2/src" -o "$work/f2/dry" -p appliance -u ciuser -k "$work/ci.pub" -P "$work/pass.hash" > "$work/f2/dry.log" 2>&1
if ! grep -qF "$PASS" "$work/f2/dry.log"; then
	ok "(F5) the dry run echoes the first-boot configuration with the password file path, not the hash"
else
	no "(F5) the dry run echoes the first-boot configuration with the password file path, not the hash"
	sed 's/^/      | /' "$work/f2/dry.log" 2>/dev/null
fi

# (5) -P was given: the hash file is read again when the configuration
#      is written. A file that is emptied or removed after the options
#      were checked stops the build; it never writes a configuration
#      without the hash. A chmod(1) before the stand-ins changes the file
#      at its first call (the modes of the overlay, before the write).
for f5case in empty gone; do
	mkdir -p "$work/f5p-$f5case/bin"
	cp "$work/pass.hash" "$work/f5p-$f5case/pass.hash"
	cat > "$work/f5p-$f5case/bin/chmod" <<FAKECHMOD
#!/bin/sh
if [ ! -e "$work/f5p-$f5case/done" ]; then
	: > "$work/f5p-$f5case/done"
	case $f5case in
	empty) : > "$work/f5p-$f5case/pass.hash" ;;
	gone) rm -f "$work/f5p-$f5case/pass.hash" ;;
	esac
fi
exec "$repo/tests/stubs/chmod" "\$@"
FAKECHMOD
	chmod 755 "$work/f5p-$f5case/bin/chmod"
	rm -f "$work/f5p-$f5case/done"
	REAL_PATH_PREFIX="$work/f5p-$f5case/bin" realbuild "$work/f5p-$f5case" \
		-u ciuser -k "$work/ci.pub" -P "$work/f5p-$f5case/pass.hash"
	f5pc="$work/f5p-$f5case/out/appliance/rootskels/boot/firstboot-user.conf"
	if [ "$realrc" -ne 0 ] && ! grep -q '^USERNAME=' "$f5pc" 2>/dev/null &&
		grep -q 'password hash file' "$work/f5p-$f5case/build.log" &&
		grep -q 'give -P a .*file whose first line is one crypt(3) hash' "$work/f5p-$f5case/build.log" &&
		! grep -qF "$PASS" "$work/f5p-$f5case/build.log"; then
		ok "(F5) a -P hash file that is $f5case when the configuration is written stops the build and says what to give -P"
	else
		no "(F5) a -P hash file that is $f5case when the configuration is written stops the build and says what to give -P (rc=$realrc)"
		tail -5 "$work/f5p-$f5case/build.log" | sed 's/^/      | /'
	fi
done

# (3) the sum of the sizes fails closed: a find that fails, a release root
#      without files, a stat that fails or a size that is not a number
#      stops the build instead of handing a too small IMGSIZE_MB to
#      nrelease. The broken tool is put before the stand-ins on PATH.
f11() { # f11 <dir> <tool> <body> <expected message> — the case is <dir>
	mkdir -p "$work/f11-$1/bin"
	printf '#!/bin/sh\n%s\n' "$3" > "$work/f11-$1/bin/$2"
	chmod 755 "$work/f11-$1/bin/$2"
	REAL_PATH_PREFIX="$work/f11-$1/bin" realbuild "$work/f11-$1" -u ciuser -k "$work/ci.pub"
	if [ "$realrc" -ne 0 ] && grep -q "$4" "$work/f11-$1/build.log" &&
		! grep -q '^CMD make .*mkimg' "$work/f11-$1/stub.log"; then
		ok "(F11) the image size fails closed: $1"
	else
		no "(F11) the image size fails closed: $1 (rc=$realrc)"
		tail -5 "$work/f11-$1/build.log" | sed 's/^/      | /'
	fi
}
f11 find-fails find 'case " $* " in *" -print0 "*) command -p find "$@"; exit 1 ;; esac; command -p find "$@"' \
	'could not list the files of the release root'
f11 no-files find 'case " $* " in *" -print0 "*) exit 0 ;; esac; command -p find "$@"' \
	'the release root holds no files'
f11 stat-fails stat 'echo "stat: $1: Permission denied" >&2; exit 1' \
	'could not read the file sizes of the release root'
f11 size-not-a-number stat 'for _f; do echo x; done; exit 0' \
	'could not sum the file sizes of the release root'

# the stand-in for make(1) keeps every modifier of the command line
mkdir -p "$work/mods/dports"
: > "$work/mods/stub.log"
STUB_LOG="$work/mods/stub.log" DPORTS_PATH="$work/mods/dports" \
	sh "$repo/tests/stubs/make" -C "$repo/tests/fixtures/fake-src/nrelease" gui binpkgs check \
	> "$work/mods/out.log" 2>&1
if grep -q '^MODIFIER gui$' "$work/mods/stub.log" && grep -q '^MODIFIER binpkgs$' "$work/mods/stub.log"; then
	ok "(F3) the stand-in for make(1) logs every modifier (gui and binpkgs)"
else
	no "(F3) the stand-in for make(1) logs every modifier (gui and binpkgs)"
	sed 's/^/      | /' "$work/mods/stub.log" "$work/mods/out.log"
fi

# (6) BINPKGS=yes|no: yes hands the binpkgs modifier to nrelease, no does
#      not, and the image is shipped either way
BINPKGS=yes REAL_PROFILE=appliance realbuild "$work/f3y" -u ciuser -k "$work/ci.pub"
if [ "$realrc" -eq 0 ] && grep -q '^MODIFIER binpkgs' "$work/f3y/stub.log" 2>/dev/null; then
	ok "(F3) the real build hands the binpkgs modifier to nrelease when BINPKGS=yes"
else
	no "(F3) the real build hands the binpkgs modifier to nrelease when BINPKGS=yes (rc=$realrc)"
	sed 's/^/      | /' "$work/f3y/stub.log" 2>/dev/null
fi
# the modifier reaches BOTH make calls that take the packages (the
# release, and the media built after the post-customize step)
f3calls=$(grep -c '^CMD make .*DPORTS_EXTRA_PACKAGES=' "$work/f3y/stub.log" 2>/dev/null || true)
f3bin=$(grep '^CMD make .*DPORTS_EXTRA_PACKAGES=' "$work/f3y/stub.log" 2>/dev/null | grep -c ' binpkgs ' || true)
if [ "$f3calls" -eq 2 ] && [ "$f3bin" -eq 2 ]; then
	ok "(F3) BINPKGS=yes hands binpkgs to both make calls (the release and the media)"
else
	no "(F3) BINPKGS=yes hands binpkgs to both make calls (the release and the media) ($f3bin of $f3calls)"
	grep '^CMD make' "$work/f3y/stub.log" 2>/dev/null | cut -c1-160 | sed 's/^/      | /'
fi
BINPKGS=no REAL_PROFILE=appliance realbuild "$work/f3n" -u ciuser -k "$work/ci.pub"
if [ "$realrc" -eq 0 ] && ! grep -q '^MODIFIER binpkgs' "$work/f3n/stub.log" 2>/dev/null &&
	[ -f "$realout/appliance/examplebsd-appliance-amd64.img" ]; then
	ok "(F3) the real build hands no binpkgs modifier and still ships the image when BINPKGS=no"
else
	no "(F3) the real build hands no binpkgs modifier and still ships the image when BINPKGS=no (rc=$realrc)"
	sed 's/^/      | /' "$work/f3n/stub.log" 2>/dev/null
fi

# (7) the first-boot script: the X fallback of the console display. It is
#      installed only when the display has no DRM device (/dev/dri/card0),
#      so a real graphics driver is never shadowed; it is installed at the
#      start of the script, whether or not a first-boot user is
#      configured and whether or not /home is writable; a file the
#      administrator put there is kept; an xorg.conf.d that cannot be
#      written is left alone. The source is the path of the product slug,
#      substituted as the build does (@SLUG@ -> examplebsd).
fb="$work/f45"
rm -rf "$fb"
mkdir -p "$fb/etc/rc.d" "$fb/boot" "$fb/usr/local/etc" "$fb/home" \
	"$fb/usr/local/share/examplebsd/xorg" "$fb/usr/local/share/otherbsd/xorg" \
	"$fb/usr/local/etc/X11/xorg.conf.d" "$fb/fakebin"
cp "$repo/overlay/profiles/desktop/rootfs/usr/local/share/@SLUG@/xorg/20-scfb.conf" \
	"$fb/usr/local/share/examplebsd/xorg/20-scfb.conf"
# a config of another product under /usr/local/share: never installed
printf 'Section "Device"\n\tIdentifier "other"\nEndSection\n' \
	> "$fb/usr/local/share/otherbsd/xorg/30-other.conf"
cat > "$fb/etc/rc.subr" <<'RCSUBR'
#!/bin/sh
load_rc_config() { :; }
run_rc_command() {
	case ${1:-} in
	start) "$start_cmd" ;;
	*) : ;;
	esac
}
RCSUBR
cat > "$fb/fakebin/pw" <<'FAKEPW'
#!/bin/sh
case ${1:-} in
usershow) exit 1 ;;
esac
exit 0
FAKEPW
cat > "$fb/fakebin/logger" <<'FAKELOG'
#!/bin/sh
exit 0
FAKELOG
cat > "$fb/fakebin/chown" <<'FAKECHOWN'
#!/bin/sh
exit 0
FAKECHOWN
chmod 755 "$fb/etc/rc.subr" "$fb/fakebin/pw" "$fb/fakebin/logger" "$fb/fakebin/chown"
# the DRM device and every path the script touches are pointed at the
# sandbox, so that the test controls both states of the gate
sed -e 's#/etc/rc\.subr#@R@/etc/rc.subr#g' \
	-e 's#/etc/master\.passwd#@R@/etc/master.passwd#g' \
	-e 's#/etc/passwd#@R@/etc/passwd#g' \
	-e 's#/boot/firstboot-user\.conf#@R@/boot/firstboot-user.conf#g' \
	-e 's#/usr/local/etc/doas\.conf#@R@/usr/local/etc/doas.conf#g' \
	-e 's#/usr/local/etc/X11#@R@/usr/local/etc/X11#g' \
	-e 's#/usr/local/share#@R@/usr/local/share#g' \
	-e 's#/home#@R@/home#g' \
	-e 's#/dev/dri/card0#@R@/.card0#g' \
	-e 's#/firstboot\([^a-z-]\)#@R@/firstboot\1#g' \
	-e 's#/firstboot$#@R@/firstboot#g' \
	-e 's#@SLUG@#examplebsd#g' \
	"$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" |
	sed "s#@R@#$fb#g" > "$fb/etc/rc.d/firstboot_user"
chmod 755 "$fb/etc/rc.d/firstboot_user"
printf 'ciuser:x:1001:1001:Ci User:%s/home/ciuser:/bin/sh\n' "$fb" > "$fb/etc/passwd"
printf 'permit persist :wheel\n' > "$fb/usr/local/etc/doas.conf"
fbxdst="$fb/usr/local/etc/X11/xorg.conf.d/20-scfb.conf"
fbsetup() { # fbsetup <card0 yes|no> <conf yes|no> — run the script once
	: > "$fb/firstboot"
	rm -f "$fb/boot/firstboot-user.conf" "$fb/boot/firstboot-user.conf.done" "$fb/.card0"
	if [ "$2" = yes ]; then
		printf 'USERNAME=ciuser\nSSH_KEY=%s %s testkey\n' 'ssh-ed25519' 'AAAAtest' > "$fb/boot/firstboot-user.conf"
	fi
	if [ "$1" = yes ]; then : > "$fb/.card0"; fi
	PATH="$fb/fakebin:$PATH" LOGGER_LOG="$fb/logger.log" \
		sh "$fb/etc/rc.d/firstboot_user" start > "$fb/fb.log" 2>&1
	fbrc=$?
}
# with /dev/dri/card0 present, the fallback is NOT installed
rm -f "$fbxdst"
fbsetup yes yes
if [ ! -e "$fbxdst" ]; then
	ok "(F7) the X fallback is not installed when /dev/dri/card0 is present (a real driver is not shadowed)"
else
	no "(F7) the X fallback is not installed when /dev/dri/card0 is present (a real driver is not shadowed)"
	sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
fi
# without /dev/dri/card0, the fallback IS installed (from the slug path)
rm -f "$fbxdst"
fbsetup no yes
if [ "$fbrc" -eq 0 ] && cmp -s "$fbxdst" "$fb/usr/local/share/examplebsd/xorg/20-scfb.conf" &&
	[ ! -e "$fb/usr/local/etc/X11/xorg.conf.d/30-other.conf" ]; then
	ok "(F7) the X fallback of the product slug is installed when /dev/dri/card0 is absent (and nothing else)"
else
	no "(F7) the X fallback of the product slug is installed when /dev/dri/card0 is absent (and nothing else) (rc=$fbrc)"
	sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
	ls "$fb/usr/local/etc/X11/xorg.conf.d" 2>/dev/null | sed 's/^/      | /'
fi
# --no-user: no first-boot configuration, the fallback is installed all
# the same (it comes before the guard of the configuration)
rm -f "$fbxdst"
fbsetup no no
if [ "$fbrc" -eq 0 ] && [ -f "$fbxdst" ]; then
	ok "(F7) the X fallback is installed without a first-boot configuration (--no-user)"
else
	no "(F7) the X fallback is installed without a first-boot configuration (--no-user) (rc=$fbrc)"
	sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
fi
# a file the administrator put there is kept
printf '# the file of the administrator\n' > "$fbxdst"
fbsetup no no
if grep -q '^# the file of the administrator$' "$fbxdst" 2>/dev/null; then
	ok "(F7) an X config the administrator put in xorg.conf.d is kept"
else
	no "(F7) an X config the administrator put in xorg.conf.d is kept"
	sed 's/^/      | /' "$fbxdst" 2>/dev/null
fi
# a KMS driver appears later: the fallback this script installed (byte-
# identical to the source) is removed; a file that differs is kept
rm -f "$fbxdst"
fbsetup no no
fbsetup yes no
if [ "$fbrc" -eq 0 ] && [ ! -e "$fbxdst" ]; then
	ok "(F7) the installed X fallback is removed once /dev/dri/card0 exists"
else
	no "(F7) the installed X fallback is removed once /dev/dri/card0 exists (rc=$fbrc)"
	sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
fi
printf '# the file of the administrator\n' > "$fbxdst"
fbsetup yes no
if grep -q '^# the file of the administrator$' "$fbxdst" 2>/dev/null; then
	ok "(F7) with /dev/dri/card0 an xorg.conf.d file that differs from the fallback is kept"
else
	no "(F7) with /dev/dri/card0 an xorg.conf.d file that differs from the fallback is kept"
fi
rm -f "$fbxdst"
if [ "$(id -u)" = 0 ]; then
	skip "(F7) the read-only cases (the suite runs as root)"
else
	# the live media: /home is read-only, the account is not created,
	# and the fallback is installed all the same
	rm -f "$fbxdst"
	chmod 555 "$fb/home"
	fbsetup no yes
	if [ "$fbrc" -eq 0 ] && [ -f "$fbxdst" ] && grep -qi 'not writable' "$fb/fb.log"; then
		ok "(F7) the X fallback is installed when /home is read-only (the live media)"
	else
		no "(F7) the X fallback is installed when /home is read-only (the live media) (rc=$fbrc)"
		sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
	fi
	chmod 755 "$fb/home"
	# an xorg.conf.d that cannot be written is left alone, without error
	rm -f "$fbxdst"
	chmod 555 "$fb/usr/local/etc/X11/xorg.conf.d"
	fbsetup no no
	if [ "$fbrc" -eq 0 ] && [ ! -e "$fbxdst" ] && ! grep -q 'could not' "$fb/fb.log"; then
		ok "(F7) a read-only xorg.conf.d is left alone, without an error"
	else
		no "(F7) a read-only xorg.conf.d is left alone, without an error (rc=$fbrc)"
		sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
	fi
	chmod 755 "$fb/usr/local/etc/X11/xorg.conf.d"
fi
# (8) a completed provisioning moves the configuration out of the way and
#      removes the sentinel, as before
fbsetup no yes
if [ -f "$fb/boot/firstboot-user.conf.done" ] && [ ! -f "$fb/boot/firstboot-user.conf" ] &&
	[ ! -f "$fb/firstboot" ]; then
	ok "(F8) a completed provisioning moves the configuration out of the way and removes the sentinel"
else
	no "(F8) a completed provisioning moves the configuration out of the way and removes the sentinel"
	sed 's/^/      | /' "$fb/fb.log" 2>/dev/null
fi
# the staged desktop tree: the script names the slug path, substituted,
# and the fallback ships there
REAL_PROFILE=desktop realbuild "$work/f7" -u ciuser -P "$work/pass.hash"
f7stage="$realout/desktop/root"
if [ "$realrc" -eq 0 ] &&
	[ -f "$f7stage/usr/local/share/examplebsd/xorg/20-scfb.conf" ] &&
	grep -q '^	_src=/usr/local/share/examplebsd/xorg/20-scfb.conf$' "$f7stage/etc/rc.d/firstboot_user" 2>/dev/null; then
	ok "(F7) the staged desktop names the X fallback by the substituted slug path, and ships it there"
else
	no "(F7) the staged desktop names the X fallback by the substituted slug path, and ships it there (rc=$realrc)"
	grep -n '_src=' "$f7stage/etc/rc.d/firstboot_user" 2>/dev/null | sed 's/^/      | /'
fi

# (4) ifconsole: the getty of the serial console is switched on in both
#      trees; the ifconsole flag is dropped only from the tty of the
#      installed system (etc.hdd), the live media keep it
d4if="$work/d4if"
rm -rf "$d4if"; mkdir -p "$d4if/etc" "$d4if/etc.hdd" "$d4if/boot" "$d4if/sk"
printf 'ttyd0\t"/usr/libexec/getty std.9600"\tdialup\toff secure ifconsole\n' > "$d4if/etc/ttys"
cp "$d4if/etc/ttys" "$d4if/etc.hdd/ttys"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$d4if/etc/master.passwd"
cp "$d4if/etc/master.passwd" "$d4if/etc.hdd/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$d4if/etc/passwd"
printf '# stock rc.conf\nhostname="localhost"\n' > "$d4if/etc/rc.conf"
cp "$d4if/etc/rc.conf" "$d4if/etc.hdd/rc.conf"
printf 'console="comconsole"\n' > "$d4if/boot/loader.conf"
sh "$repo/tools/post-customize.sh" "$d4if" "$work/norc" "$work/norc" \
	"$d4if/sk" ttyd0 comconsole - - > "$d4if/log" 2>&1
d4rc=$?
if [ "$d4rc" -eq 0 ] && grep -qE '^ttyd0[[:space:]]+"/usr/libexec/getty std.9600"[[:space:]]+dialup[[:space:]]+on[[:space:]]+secure[[:space:]]*$' \
	"$d4if/etc.hdd/ttys" 2>/dev/null; then
	ok "(F4) the getty is switched on and the ifconsole flag is dropped from the tty of the installed system (etc.hdd)"
else
	no "(F4) the getty is switched on and the ifconsole flag is dropped from the tty of the installed system (etc.hdd) (rc=$d4rc)"
	sed 's/^/      | /' "$d4if/etc.hdd/ttys" 2>/dev/null
	sed 's/^/      | /' "$d4if/log" 2>/dev/null
fi
if grep -qE '^ttyd0[[:space:]]+"/usr/libexec/getty std.9600"[[:space:]]+dialup[[:space:]]+on[[:space:]]+secure[[:space:]]+ifconsole[[:space:]]*$' \
	"$d4if/etc/ttys" 2>/dev/null; then
	ok "(F4) the getty of the live media is switched on and keeps the ifconsole flag"
else
	no "(F4) the getty of the live media is switched on and keeps the ifconsole flag"
	sed 's/^/      | /' "$d4if/etc/ttys" 2>/dev/null
fi

# (4) GETTY goes into grep patterns and sed scripts: a value that is not a
#      tty name (ttyd0, ttyv0, ...) is refused before anything changes
d4bad="$work/d4bad"
rm -rf "$d4bad"; mkdir -p "$d4bad/root/etc" "$d4bad/root/etc.hdd" "$d4bad/root/boot" "$d4bad/sk"
printf 'ttyd0\t"/usr/libexec/getty std.9600"\tdialup\toff secure ifconsole\n' > "$d4bad/root/etc/ttys"
cp "$d4bad/root/etc/ttys" "$d4bad/root/etc.hdd/ttys"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$d4bad/root/etc/master.passwd"
cp "$d4bad/root/etc/master.passwd" "$d4bad/root/etc.hdd/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$d4bad/root/etc/passwd"
printf 'hostname="localhost"\n' > "$d4bad/root/etc/rc.conf"
cp "$d4bad/root/etc/rc.conf" "$d4bad/root/etc.hdd/rc.conf"
printf 'console="comconsole"\n' > "$d4bad/root/boot/loader.conf"
cp -R "$d4bad/root" "$d4bad/before"
sh "$repo/tools/post-customize.sh" "$d4bad/root" "$work/norc" "$work/norc" \
	"$d4bad/sk" "ttyd0\"; touch $d4bad/pwned; \"" comconsole - - > "$d4bad/log" 2>&1
d4brc=$?
if [ "$d4brc" -ne 0 ] && grep -q 'GETTY must be a tty name such as ttyd0' "$d4bad/log" &&
	[ ! -e "$d4bad/pwned" ] && diff -r "$d4bad/before" "$d4bad/root" > /dev/null 2>&1; then
	ok "(F4) a GETTY that is not a tty name is refused and nothing is changed"
else
	no "(F4) a GETTY that is not a tty name is refused and nothing is changed (rc=$d4brc)"
	sed 's/^/      | /' "$d4bad/log" 2>/dev/null
	diff -r "$d4bad/before" "$d4bad/root" 2>&1 | sed 's/^/      | /'
fi
sh "$repo/tools/post-customize.sh" "$d4bad/root" "$work/norc" "$work/norc" \
	"$d4bad/sk" ttyv0 comconsole - - > "$d4bad/log2" 2>&1
if [ $? -eq 0 ]; then
	ok "(F4) GETTY=ttyv0 (the virtual console of DragonFly) is accepted"
else
	no "(F4) GETTY=ttyv0 (the virtual console of DragonFly) is accepted"
	sed 's/^/      | /' "$d4bad/log2" 2>/dev/null
fi

# (L1) the live media never consume the first-boot configuration: the
#      .img live media has a writable root and /home, and the installer
#      copies /boot, so the live media is told apart by the installer
#      account of the release tooling. On the live media: no useradd, the
#      configuration untouched, the X fallback installed all the same. On
#      the installed system (no installer account): the user is created
#      and the configuration renamed to .done.
cat > "$fb/fakebin/pw" <<FAKEPW
#!/bin/sh
printf 'pw %s\n' "\$*" >> "$fb/pw.log"
case \${1:-} in
usershow) exit 1 ;;
esac
exit 0
FAKEPW
chmod 755 "$fb/fakebin/pw"
printf 'root:*:0:0::0:0:Charlie &:/root:/bin/sh\ninstaller::0:0::0:0:DragonFly Installer:/root:/usr/sbin/installer\n' \
	> "$fb/etc/master.passwd"
: > "$fb/pw.log"
rm -f "$fbxdst"
fbsetup no yes
cp "$fb/boot/firstboot-user.conf" "$fb/l1.conf" 2>/dev/null
printf 'USERNAME=ciuser\nSSH_KEY=%s %s testkey\n' 'ssh-ed25519' 'AAAAtest' > "$fb/l1.want"
if [ "$fbrc" -eq 0 ] && [ ! -s "$fb/pw.log" ] && cmp -s "$fb/boot/firstboot-user.conf" "$fb/l1.want" &&
	[ ! -e "$fb/boot/firstboot-user.conf.done" ] && [ -f "$fb/firstboot" ] &&
	grep -q 'this is the live media' "$fb/fb.log"; then
	ok "(L1) on the live media (installer account, writable /home) no user is created and the configuration stays untouched"
else
	no "(L1) on the live media (installer account, writable /home) no user is created and the configuration stays untouched (rc=$fbrc)"
	sed 's/^/      | /' "$fb/fb.log" "$fb/pw.log" 2>/dev/null
fi
if [ -f "$fbxdst" ]; then
	ok "(L1) the X fallback is installed on the live media all the same"
else
	no "(L1) the X fallback is installed on the live media all the same"
fi
printf 'root:*:0:0::0:0:Charlie &:/root:/bin/sh\n' > "$fb/etc/master.passwd"
: > "$fb/pw.log"
fbsetup no yes
if [ "$fbrc" -eq 0 ] && grep -q '^pw useradd -n ciuser' "$fb/pw.log" &&
	[ -f "$fb/boot/firstboot-user.conf.done" ] && [ ! -e "$fb/boot/firstboot-user.conf" ]; then
	ok "(L1) on the installed system (no installer account) the user is created and the configuration renamed to .done"
else
	no "(L1) on the installed system (no installer account) the user is created and the configuration renamed to .done (rc=$fbrc)"
	sed 's/^/      | /' "$fb/fb.log" "$fb/pw.log" 2>/dev/null
fi
rm -f "$fb/etc/master.passwd"

# (L2) LightDM runs on the live media (it logs the live user in, see LV)
#      and on the installed system
REAL_PROFILE=desktop realbuild "$work/l2" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] &&
	grep -q '^lightdm_enable="YES"$' "$realout/desktop/root/etc/rc.conf" 2>/dev/null &&
	grep -q '^lightdm_enable="YES"$' "$realout/desktop/root/etc.hdd/rc.conf" 2>/dev/null; then
	ok "(L2) the desktop enables LightDM in the rc.conf of the live media and of the installed system (etc.hdd)"
else
	no "(L2) the desktop enables LightDM in the rc.conf of the live media and of the installed system (etc.hdd) (rc=$realrc)"
	grep -n 'lightdm' "$realout/desktop/root/etc/rc.conf" "$realout/desktop/root/etc.hdd/rc.conf" 2>/dev/null | sed 's/^/      | /'
fi
# an image booted as the system itself (no installer account) gets the
# installed-only fragments in its own rc.conf as well
l2r="$work/l2r"
rm -rf "$l2r"; mkdir -p "$l2r/root/etc" "$l2r/root/etc.hdd" "$l2r/root/boot" "$l2r/sk" "$l2r/inst"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$l2r/root/etc/master.passwd"
cp "$l2r/root/etc/master.passwd" "$l2r/root/etc.hdd/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$l2r/root/etc/passwd"
printf 'hostname="localhost"\n' > "$l2r/root/etc/rc.conf"
cp "$l2r/root/etc/rc.conf" "$l2r/root/etc.hdd/rc.conf"
printf 'foo_enable="YES"\n' > "$l2r/inst/foo"
sh "$repo/tools/post-customize.sh" "$l2r/root" "$work/norc" "$work/norc" \
	"$l2r/sk" ttyd0 comconsole - - "$l2r/inst" > "$l2r/log" 2>&1
if grep -q '^foo_enable="YES"$' "$l2r/root/etc/rc.conf" && grep -q '^foo_enable="YES"$' "$l2r/root/etc.hdd/rc.conf"; then
	ok "(L2) an image without the installer account gets the installed-only fragments in its own rc.conf"
else
	no "(L2) an image without the installer account gets the installed-only fragments in its own rc.conf"
	sed 's/^/      | /' "$l2r/log"
fi
# the appliance case: the live tree carries the installer account of the
# release tooling and post-customize removes it (REMOVE_ACCOUNT=installer).
# The account is gone, and since the tree is then the system itself, the
# installed-only fragments reach its own rc.conf (they are merged after
# the account handling).
l2a="$work/l2a"
rm -rf "$l2a"; mkdir -p "$l2a/root/etc" "$l2a/root/etc.hdd" "$l2a/root/boot" "$l2a/sk" "$l2a/inst"
printf 'root::0:0::0:0::/root:/bin/sh\ninstaller::0:0::0:0:DragonFly Installer:/root:/usr/sbin/installer\n' > "$l2a/root/etc/master.passwd"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$l2a/root/etc.hdd/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\ninstaller:x:0:0:DragonFly Installer:/root:/usr/sbin/installer\n' > "$l2a/root/etc/passwd"
printf 'hostname="localhost"\n' > "$l2a/root/etc/rc.conf"
cp "$l2a/root/etc/rc.conf" "$l2a/root/etc.hdd/rc.conf"
printf 'foo_enable="YES"\n' > "$l2a/inst/foo"
sh "$repo/tools/post-customize.sh" "$l2a/root" "$work/norc" "$work/norc" \
	"$l2a/sk" ttyd0 comconsole installer - "$l2a/inst" > "$l2a/log" 2>&1
l2arc=$?
if [ "$l2arc" -eq 0 ] && ! grep -q '^installer:' "$l2a/root/etc/master.passwd" &&
	! grep -q '^installer:' "$l2a/root/etc/passwd"; then
	ok "(L2) REMOVE_ACCOUNT=installer removes the installer account from master.passwd and passwd"
else
	no "(L2) REMOVE_ACCOUNT=installer removes the installer account from master.passwd and passwd (rc=$l2arc)"
	sed 's/^/      | /' "$l2a/log" "$l2a/root/etc/master.passwd" "$l2a/root/etc/passwd" 2>/dev/null
fi
if grep -q '^foo_enable="YES"$' "$l2a/root/etc/rc.conf" && grep -q '^foo_enable="YES"$' "$l2a/root/etc.hdd/rc.conf"; then
	ok "(L2) the appliance case: once the installer account is removed, the installed-only fragments reach the live rc.conf"
else
	no "(L2) the appliance case: once the installer account is removed, the installed-only fragments reach the live rc.conf"
	sed 's/^/      | /' "$l2a/root/etc/rc.conf" "$l2a/log" 2>/dev/null
fi
if grep -qi 'installer' "$repo/README.md" && grep -q 'ttyv0' "$repo/README.md" &&
	grep -q 'Log in as `installer`' "$repo/README.md"; then
	ok "(L2) the README says the installer runs on ttyv0 and ttyd0 as installer"
else
	no "(L2) the README says the installer runs on ttyv0 and ttyd0 as installer"
fi

# (L3) the staged /boot and the configuration belong to root:wheel: the
#      release tooling copies the rootskels with their owner
if grep -qF "CMD chown root:wheel $work/l2/out/desktop/rootskels/boot $work/l2/out/desktop/rootskels/boot/firstboot-user.conf" \
	"$work/l2/stub.log" 2>/dev/null; then
	ok "(L3) the staged /boot and the first-boot configuration are given to root:wheel"
else
	no "(L3) the staged /boot and the first-boot configuration are given to root:wheel"
	grep 'chown.*boot' "$work/l2/stub.log" 2>/dev/null | sed 's/^/      | /'
fi

# (L4) rcorder: DragonFly has no FILESYSTEMS placeholder (the real boot
#      warns "requirement FILESYSTEMS ... has no providers"); the script
#      requires mountcritremote, the last of the mount scripts
l4=$(grep '^# REQUIRE:' "$repo/overlay/base/rootfs/etc/rc.d/firstboot_user")
case " $l4 " in
*' FILESYSTEMS '*) no "(L4) the first-boot script requires no FILESYSTEMS (DragonFly has no provider): $l4" ;;
*' mountcritremote '*) ok "(L4) the first-boot script requires mountcritremote, not FILESYSTEMS" ;;
*) no "(L4) the first-boot script requires mountcritremote, not FILESYSTEMS: $l4" ;;
esac

# (L5) the README warns about the stock installer: its Reboot halts the
#      machine, and its screens say "DragonFly BSD"
if grep -q 'halts the machine' "$repo/README.md" && grep -q 'say "DragonFly BSD"' "$repo/README.md"; then
	ok "(L5) the README says the installer's Reboot halts the machine and its screens say DragonFly BSD"
else
	no "(L5) the README says the installer's Reboot halts the machine and its screens say DragonFly BSD"
fi

# (K1) the keyboard under bhyve: the desktop sets kern.evdev.rcpt_mask=6
#      (keys through kbdmux) in the sysctl.conf of the live media AND of
#      the installed system (etc.hdd), appended to the stock file, which
#      keeps its own lines; the appliance does not set it
REAL_PROFILE=both realbuild "$work/k1" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
k1d="$realout/desktop/root"
k1a="$realout/appliance/root"
if [ "$realrc" -eq 0 ] &&
	grep -qx 'kern.evdev.rcpt_mask=6' "$k1d/etc/sysctl.conf" 2>/dev/null &&
	grep -qx 'kern.evdev.rcpt_mask=6' "$k1d/etc.hdd/sysctl.conf" 2>/dev/null; then
	ok "(K1) the desktop sets kern.evdev.rcpt_mask=6 in the sysctl.conf of the live media and of the installed system"
else
	no "(K1) the desktop sets kern.evdev.rcpt_mask=6 in the sysctl.conf of the live media and of the installed system (rc=$realrc)"
	grep -n 'evdev' "$k1d/etc/sysctl.conf" "$k1d/etc.hdd/sysctl.conf" 2>/dev/null | sed 's/^/      | /'
fi
if grep -qx '#security.bsd.see_other_uids=0' "$k1d/etc/sysctl.conf" 2>/dev/null &&
	grep -qx '#security.bsd.see_other_uids=0' "$k1d/etc.hdd/sysctl.conf" 2>/dev/null &&
	grep -qx '# from the overlay: sysctl.conf.d/evdev' "$k1d/etc.hdd/sysctl.conf" 2>/dev/null; then
	ok "(K1) the stock sysctl.conf is appended to (its lines stay) below a marker of the fragment"
else
	no "(K1) the stock sysctl.conf is appended to (its lines stay) below a marker of the fragment"
	sed 's/^/      | /' "$k1d/etc.hdd/sysctl.conf" 2>/dev/null
fi
if ! grep -qs 'kern.evdev.rcpt_mask' "$k1a/etc/sysctl.conf" "$k1a/etc.hdd/sysctl.conf"; then
	ok "(K1) the appliance does not set kern.evdev.rcpt_mask"
else
	no "(K1) the appliance does not set kern.evdev.rcpt_mask"
fi
# idempotent: a second run, or a name already set, leaves one line
k1r="$work/k1r"
rm -rf "$k1r"; mkdir -p "$k1r/root/etc" "$k1r/root/etc.hdd" "$k1r/sk" "$k1r/sc"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$k1r/root/etc/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$k1r/root/etc/passwd"
printf 'kern.evdev.rcpt_mask=12\n' > "$k1r/root/etc/sysctl.conf"
cp "$repo/overlay/profiles/desktop/sysctl.conf.d/evdev" "$k1r/sc/evdev"
for _k in 1 2; do
	sh "$repo/tools/post-customize.sh" "$k1r/root" "$work/norc" "$work/norc" \
		"$k1r/sk" ttyd0 comconsole - - - "$k1r/sc" > "$k1r/log" 2>&1
done
if [ "$(grep -c '^kern.evdev.rcpt_mask=' "$k1r/root/etc/sysctl.conf")" -eq 1 ] &&
	grep -qx 'kern.evdev.rcpt_mask=6' "$k1r/root/etc/sysctl.conf" &&
	[ "$(grep -c '^kern.evdev.rcpt_mask=' "$k1r/root/etc.hdd/sysctl.conf")" -eq 1 ]; then
	ok "(K1) the sysctl merge is idempotent and replaces a name already set"
else
	no "(K1) the sysctl merge is idempotent and replaces a name already set"
	sed 's/^/      | /' "$k1r/root/etc/sysctl.conf" "$k1r/log" 2>/dev/null
fi

# (K2) a sysctl fragment line that is not exactly name=value (a bare
#      word, a space in the name, an empty value) stops post-customize
#      with the message, before anything is written to sysctl.conf
k2="$work/k2"
for k2case in bare space empty backslash; do
	rm -rf "$k2"; mkdir -p "$k2/root/etc" "$k2/root/etc.hdd" "$k2/sk" "$k2/sc/2-profile"
	printf 'root::0:0::0:0::/root:/bin/sh\n' > "$k2/root/etc/master.passwd"
	printf 'root:x:0:0::/root:/bin/sh\n' > "$k2/root/etc/passwd"
	cp "$repo/tests/fixtures/release-root/etc/sysctl.conf" "$k2/root/etc/sysctl.conf"
	cp "$k2/root/etc/sysctl.conf" "$k2/root/etc.hdd/sysctl.conf"
	cp -R "$k2/root" "$k2/before"
	case $k2case in
	bare) printf 'kern.foo\n' > "$k2/sc/2-profile/bad" ;;
	space) printf 'kern foo=1\n' > "$k2/sc/2-profile/bad" ;;
	empty) printf 'kern.foo=\n' > "$k2/sc/2-profile/bad" ;;
	# a backslash escape (\n): awk -v would turn it into a new line, so
	# the name is also set already: check_sysctl must refuse the backslash
	# before anything is written, so neither file changes
	backslash)
		printf 'kern.foo=a\\nb\n' > "$k2/sc/2-profile/bad"
		printf 'kern.foo=old\n' >> "$k2/root/etc/sysctl.conf"
		printf 'kern.foo=old\n' >> "$k2/root/etc.hdd/sysctl.conf"
		rm -rf "$k2/before"
		cp -R "$k2/root" "$k2/before"
		;;
	esac
	sh "$repo/tools/post-customize.sh" "$k2/root" "$work/norc" "$work/norc" \
		"$k2/sk" ttyd0 comconsole - - - "$k2/sc" > "$k2/log" 2>&1
	k2rc=$?
	if [ "$k2rc" -ne 0 ] && grep -q 'not a sysctl.conf(5) line' "$k2/log" &&
		cmp -s "$k2/before/etc/sysctl.conf" "$k2/root/etc/sysctl.conf" &&
		cmp -s "$k2/before/etc.hdd/sysctl.conf" "$k2/root/etc.hdd/sysctl.conf"; then
		ok "(K2) a sysctl fragment with a $k2case line is refused and sysctl.conf is not written"
	else
		no "(K2) a sysctl fragment with a $k2case line is refused and sysctl.conf is not written (rc=$k2rc)"
		sed 's/^/      | /' "$k2/log" "$k2/root/etc/sysctl.conf" 2>/dev/null
	fi
done

# (K3) base then profile: base sets a name in the fragment zz, the
#      profile sets it in the fragment aa; the profile's value wins
rm -rf "$k2"; mkdir -p "$k2/root/etc" "$k2/root/etc.hdd" "$k2/sk" "$k2/sc/1-base" "$k2/sc/2-profile"
printf 'root::0:0::0:0::/root:/bin/sh\n' > "$k2/root/etc/master.passwd"
printf 'root:x:0:0::/root:/bin/sh\n' > "$k2/root/etc/passwd"
cp "$repo/tests/fixtures/release-root/etc/sysctl.conf" "$k2/root/etc/sysctl.conf"
printf 'kern.foo=1\n' > "$k2/sc/1-base/zz"
printf 'kern.foo=2\n' > "$k2/sc/2-profile/aa"
sh "$repo/tools/post-customize.sh" "$k2/root" "$work/norc" "$work/norc" \
	"$k2/sk" ttyd0 comconsole - - - "$k2/sc" > "$k2/log" 2>&1
if grep -qx 'kern.foo=2' "$k2/root/etc/sysctl.conf" 2>/dev/null &&
	[ "$(grep -c '^kern.foo=' "$k2/root/etc/sysctl.conf")" -eq 1 ]; then
	ok "(K3) the profile's sysctl value wins over the base's, whatever the file names"
else
	no "(K3) the profile's sysctl value wins over the base's, whatever the file names"
	sed 's/^/      | /' "$k2/root/etc/sysctl.conf" "$k2/log" 2>/dev/null
fi
if [ -f "$work/k1/out/desktop/rc.conf.d/sysctl/2-profile/evdev" ] &&
	[ -d "$work/k1/out/desktop/rc.conf.d/sysctl/1-base" ]; then
	ok "(K3) the build stages the base and profile sysctl fragments apart (1-base, 2-profile)"
else
	no "(K3) the build stages the base and profile sysctl fragments apart (1-base, 2-profile)"
	ls -R "$work/k1/out/desktop/rc.conf.d/sysctl" 2>/dev/null | sed 's/^/      | /'
fi

# (1) the first-boot sentinel: an ISO build's release root (the tree of
#      the read-only ISO) holds no /firstboot, so the stock /etc/rc never
#      tries to remove it there
DFLY_MEDIA=iso REAL_PROFILE=desktop realbuild "$work/f9" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] && [ -f "$realout/desktop/examplebsd-desktop-amd64.iso" ] &&
	[ -d "$realout/desktop/root/etc" ] && [ ! -e "$realout/desktop/root/firstboot" ]; then
	ok "(F9) an ISO build's release root holds no /firstboot"
else
	no "(F9) an ISO build's release root holds no /firstboot (rc=$realrc)"
	sed 's/^/      | /' "$work/f9/build.log" 2>/dev/null | tail -20
fi

# (7) the knob of the media is DFLY_MEDIA: an unrelated MEDIA in the
#      environment does not stop the build; a bad DFLY_MEDIA does
MEDIA=/dev/cd0 REAL_PROFILE=desktop realbuild "$work/f10" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] && [ -f "$realout/desktop/examplebsd-desktop-amd64.img" ]; then
	ok "(F10) an unrelated MEDIA in the environment does not stop the build"
else
	no "(F10) an unrelated MEDIA in the environment does not stop the build (rc=$realrc)"
	sed 's/^/      | /' "$work/f10/build.log" 2>/dev/null | tail -20
fi
DFLY_MEDIA=dvd sh "$build" -n -c "$fixture" -p desktop --no-user -o "$work/f10/dry" > "$work/f10/bad.log" 2>&1
f10rc=$?
if [ "$f10rc" -ne 0 ] && grep -q 'DFLY_MEDIA must be' "$work/f10/bad.log"; then
	ok "(F10) a DFLY_MEDIA that is neither img nor iso is refused"
else
	no "(F10) a DFLY_MEDIA that is neither img nor iso is refused (rc=$f10rc)"
	sed 's/^/      | /' "$work/f10/bad.log" 2>/dev/null
fi
DFLY_MEDIA=iso sh "$build" -n -c "$fixture" -p desktop --no-user -o "$work/f10/dry" > "$work/f10/iso.log" 2>&1
if grep -q 'NOTE: the desktop is built as an ISO; it must stay under 2 GiB' "$work/f10/iso.log" &&
	! grep 'NOTE: the desktop is built as an ISO' "$work/f10/iso.log" | LC_ALL=C grep -q '[^ -~]'; then
	ok "(F10) the 2 GiB note of the desktop ISO is plain ASCII"
else
	no "(F10) the 2 GiB note of the desktop ISO is plain ASCII"
	grep 'NOTE' "$work/f10/iso.log" 2>/dev/null | sed 's/^/      | /'
fi

# --------------------------------------------------------------------------
# (LV) the live desktop: the live user, its automatic login, the installer
#      that opens first, and the install command of the template
# --------------------------------------------------------------------------
lv="$work/lv"
rm -rf "$lv"
mkdir -p "$lv/bin"
lvsub() { # lvsub <src> <dst> — a file of the overlay with its placeholders filled
	sed -e 's/@SLUG@/examplebsd/g' -e 's/@DISTRO_NAME@/ExampleBSD/g' "$1" > "$2" && chmod 755 "$2"
}
dov="$repo/overlay/profiles/desktop/rootfs"

# (LV1) the desktop build: LightDM on the live media AND on the installed
#       system, the live session, the install command, the installer of
#       installer-template, and a getty on ttyv1 of the live media only
REAL_PROFILE=desktop realbuild "$work/lv1" -u ciuser -P "$work/pass.hash"
lv1="$realout/desktop/root"
lv1sk="$realout/desktop/rootskels"
if [ "$realrc" -eq 0 ] &&
	grep -q '^lightdm_enable="YES"$' "$lv1/etc/rc.conf" 2>/dev/null &&
	grep -q '^lightdm_enable="YES"$' "$lv1/etc.hdd/rc.conf" 2>/dev/null; then
	ok "(LV1) the desktop enables LightDM on the live media and on the installed system"
else
	no "(LV1) the desktop enables LightDM on the live media and on the installed system (rc=$realrc)"
	grep -n 'lightdm' "$lv1/etc/rc.conf" "$lv1/etc.hdd/rc.conf" 2>/dev/null | sed 's/^/      | /'
fi
lv1miss=''
for f in etc/rc.d/live_session usr/local/sbin/examplebsd-install usr/local/sbin/examplebsd-live-clean \
	usr/local/bin/after_installation_routines.sh usr/local/share/examplebsd/live/90-live-autologin.conf \
	usr/local/bin/wtfbsd-installer usr/local/libexec/wtfbsd-installer/installer-apply \
	usr/local/share/wtfbsd-installer/autostart/wtfbsd-installer.desktop usr/local/share/wtfbsd-installer/MANIFEST; do
	[ -f "$lv1sk/$f" ] || lv1miss="$lv1miss $f"
done
if [ -z "$lv1miss" ]; then
	ok "(LV1) the staged desktop holds the live session, the install command and the installer launcher"
else
	no "(LV1) the staged desktop holds the live session, the install command and the installer launcher; missing:$lv1miss"
fi
lv1modes=''
for f in etc/rc.d/live_session usr/local/sbin/examplebsd-install usr/local/sbin/examplebsd-live-clean \
	usr/local/bin/after_installation_routines.sh; do
	src=$(printf %s "$f" | sed 's/examplebsd/@SLUG@/')
	grep -qxF "CMD chmod 755 $lv1sk/$src" "$work/lv1/stub.log" 2>/dev/null || lv1modes="$lv1modes $f"
done
if [ -z "$lv1modes" ]; then
	ok "(LV1) the scripts of the live session and the install command are made executable (0755)"
else
	no "(LV1) the scripts of the live session and the install command are made executable (0755):$lv1modes"
fi
lv1ic="$lv1sk/usr/local/libexec/wtfbsd-installer/installer.conf"
if grep -q '^PRODUCT_SLUG=examplebsd$' "$lv1ic" 2>/dev/null && grep -q '^PRODUCT_NAME=ExampleBSD$' "$lv1ic" &&
	grep -q '^OS=dragonfly$' "$lv1ic" && grep -q '^DEFAULT_KEYMAP=us.iso$' "$lv1ic"; then
	ok "(LV1) the configuration of the installer names the product and DragonFly"
else
	no "(LV1) the configuration of the installer names the product and DragonFly"
	sed 's/^/      | /' "$lv1ic" 2>/dev/null
fi
# the live media write the live medium (LV18): the installer is told to
# require it (installer-template README, "The live medium")
if [ "$(grep -c '^LIVE_MEDIUM_REQUIRED=' "$lv1ic" 2>/dev/null)" = 1 ] && grep -qx 'LIVE_MEDIUM_REQUIRED=yes' "$lv1ic"; then
	ok "(LV1) the configuration of the installer sets LIVE_MEDIUM_REQUIRED=yes once"
else
	no "(LV1) the configuration of the installer sets LIVE_MEDIUM_REQUIRED=yes once"
	sed 's/^/      | /' "$lv1ic" 2>/dev/null
fi
if grep -Eq '^ttyv1[[:space:]].*getty Pc.*[[:space:]]on[[:space:]]' "$lv1/etc/ttys" 2>/dev/null &&
	! grep -q '^ttyv1[[:space:]]' "$lv1/etc.hdd/ttys" 2>/dev/null; then
	ok "(LV1) the build adds a getty on ttyv1 (the stock installer) to the live media, and leaves the ttys of the installed system alone"
else
	no "(LV1) the build adds a getty on ttyv1 (the stock installer) to the live media, and leaves the ttys of the installed system alone"
	grep -n 'ttyv' "$lv1/etc/ttys" "$lv1/etc.hdd/ttys" 2>/dev/null | sed 's/^/      | /'
fi
if grep -qxF "INSTALL-INTO-STAGE $lv1sk" "$work/lv1/stub.log" 2>/dev/null &&
	! grep -q 'live' "$lv1sk/usr/local/etc/doas.conf" 2>/dev/null; then
	ok "(LV1) the build runs install-into-stage.sh of installer-template on the staged overlay; the shipped doas.conf has no rule for live"
else
	no "(LV1) the build runs install-into-stage.sh of installer-template on the staged overlay; the shipped doas.conf has no rule for live"
fi
# (LV16) what the real install-into-stage.sh of installer-template
#        (ceda104) asks for: without root a METALOG (it refuses otherwise),
#        and the artwork of the product as --artwork <the unpacked pack>
lv16a=$(grep '^INSTALL-INTO-STAGE-ARGS ' "$work/lv1/stub.log" 2>/dev/null | head -n 1)
lv16art=$(printf '%s\n' "$lv16a" | sed -n 's/.* --artwork \([^ ]*\).*/\1/p')
if printf '%s\n' "$lv16a" | grep -q ' --metalog [^ ]*/installer\.metalog' &&
	case $lv16art in */artwork-pack/examplebsd-*-default) true ;; *) false ;; esac &&
	[ -f "$lv16art/palette.env" ]; then
	ok "(LV16) the build hands install-into-stage.sh --metalog (built without root) and --artwork <the unpacked pack with its palette.env>"
else
	no "(LV16) the build hands install-into-stage.sh --metalog (built without root) and --artwork <the unpacked pack with its palette.env>"
	printf '      | %s\n' "$lv16a"
fi
mkdir -p "$work/lv16b/bin"
printf '#!/bin/sh\necho "python3: not found" >&2\nexit 127\n' > "$work/lv16b/bin/python3"
chmod 755 "$work/lv16b/bin/python3"
REAL_PATH_PREFIX="$work/lv16b/bin" REAL_PROFILE=desktop realbuild "$work/lv16b" -u ciuser -P "$work/pass.hash"
lv16brc=$realrc
if [ "$lv16brc" -ne 0 ] && grep -q 'no working python3: install-into-stage.sh of installer-template needs it' "$work/lv16b/build.log" 2>/dev/null &&
	! grep -q '^INSTALL-INTO-STAGE ' "$work/lv16b/stub.log" 2>/dev/null; then
	ok "(LV16) a build host without a working python3 stops before install-into-stage.sh gets the artwork, and says to install lang/python3"
else
	no "(LV16) a build host without a working python3 stops before install-into-stage.sh gets the artwork, and says to install lang/python3 (rc=$lv16brc)"
	tail -n 3 "$work/lv16b/build.log" 2>/dev/null | sed 's/^/      | /'
fi
mkdir -p "$work/lv16/sk" "$work/lv16/noart"
if [ "$(id -u)" != 0 ] &&
	! sh "$repo/tests/fixtures/fake-installer-template/install-into-stage.sh" "$work/lv16/sk" > /dev/null 2>&1 &&
	[ ! -e "$work/lv16/sk/usr/local/bin/wtfbsd-installer" ] &&
	! sh "$repo/tests/fixtures/fake-installer-template/install-into-stage.sh" "$work/lv16/sk" --metalog "$work/lv16/m" --artwork "$work/lv16/noart" > /dev/null 2>&1 &&
	sh "$repo/tests/fixtures/fake-installer-template/install-into-stage.sh" "$work/lv16/sk" --metalog "$work/lv16/m" > /dev/null 2>&1; then
	ok "(LV16) the stand-in of install-into-stage.sh refuses, like the real one, to run without root and without --metalog, and an --artwork without palette.env"
else
	no "(LV16) the stand-in of install-into-stage.sh refuses, like the real one, to run without root and without --metalog, and an --artwork without palette.env"
fi
lv1pk=''
for p in devel/py-pygobject x11-toolkits/gtk30 x11/xterm lang/python3; do
	grep -q "^$p\$" "$repo/overlay/profiles/desktop/packages.list" 2>/dev/null || lv1pk="$lv1pk $p"
done
if [ -z "$lv1pk" ] && grep -q '^VAR DPORTS_EXTRA_PACKAGES=.*devel/py-pygobject' "$work/lv1/stub.log" 2>/dev/null; then
	ok "(LV1) the desktop hands PyGObject, GTK 3, python3 and xterm to the release"
else
	no "(LV1) the desktop hands PyGObject, GTK 3, python3 and xterm to the release:$lv1pk"
fi

# (LV2) where the installer comes from: the pinned default for the desktop,
#       INSTALLER_REF is a commit or tag (no .., no leading dash) and is
#       cloned at it,
#       INSTALLER_DIR must hold install-into-stage.sh; the appliance needs none
env -u INSTALLER_DIR sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/d1" > "$lv/d1.log" 2>&1
r1=$?
env -u INSTALLER_DIR INSTALLER_REF=v1..2 sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/d2" > "$lv/d2.log" 2>&1
r2=$?
env -u INSTALLER_DIR INSTALLER_REF=4d9cd5b sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/d3" > "$lv/d3.log" 2>&1
r3=$?
mkdir -p "$lv/notinst"
INSTALLER_DIR="$lv/notinst" sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/d4" > "$lv/d4.log" 2>&1
r4=$?
env -u INSTALLER_DIR sh "$build" -n -c "$fixture" -p appliance --no-user -o "$lv/d5" > "$lv/d5.log" 2>&1
r5=$?
if [ "$r1" -eq 0 ] && grep -q 'installer-template 907e707a606edc2023d437fc41c46a674f8143f5 from' "$lv/d1.log"; then
	ok "(LV2) the desktop without INSTALLER_REF or INSTALLER_DIR takes the pinned main of installer-template"
else
	no "(LV2) the desktop without INSTALLER_REF or INSTALLER_DIR takes the pinned main of installer-template (rc=$r1)"
fi
if [ "$r2" -ne 0 ] && grep -q 'INSTALLER_REF may not contain \.\.' "$lv/d2.log"; then
	ok "(LV2) an INSTALLER_REF that is not a plain commit or tag (..) is refused"
else
	no "(LV2) an INSTALLER_REF that is not a plain commit or tag (..) is refused (rc=$r2)"
fi
if [ "$r3" -eq 0 ] && grep -q 'git clone .*installer-template' "$lv/d3.log" &&
	grep -q 'checkout --quiet 4d9cd5b$' "$lv/d3.log"; then
	ok "(LV2) INSTALLER_REF is cloned and checked out at that commit"
else
	no "(LV2) INSTALLER_REF is cloned and checked out at that commit (rc=$r3)"
	sed 's/^/      | /' "$lv/d3.log" | head -20
fi
if [ "$r4" -ne 0 ] && grep -q 'no install-into-stage.sh' "$lv/d4.log"; then
	ok "(LV2) an INSTALLER_DIR without install-into-stage.sh is refused"
else
	no "(LV2) an INSTALLER_DIR without install-into-stage.sh is refused (rc=$r4)"
fi
if [ "$r5" -eq 0 ] && ! grep -q 'install-into-stage' "$lv/d5.log"; then
	ok "(LV2) the appliance needs no installer of a live session"
else
	no "(LV2) the appliance needs no installer of a live session (rc=$r5)"
fi

# the stand-ins of the live session and of the install command
cat > "$lv/bin/pw" <<'EOF'
#!/bin/sh
printf 'pw %s\n' "$*" >> "$LV_LOG"
[ "${1:-}" = useradd ] || exit 0
n='' u=''
shift
while [ $# -gt 0 ]; do
	case $1 in -n) n=$2; shift ;; -u) u=$2; shift ;; esac
	shift
done
printf '%s:*:%s:%s::0:0:Live user:/home/%s:/bin/sh\n' "$n" "$u" "$u" "$n" >> "$LV_ROOT/etc/master.passwd"
printf '%s:*:%s:%s:Live user:/home/%s:/bin/sh\n' "$n" "$u" "$u" "$n" >> "$LV_ROOT/etc/passwd"
printf '%s:*:%s:\n' "$n" "$u" >> "$LV_ROOT/etc/group"
mkdir -p "$LV_ROOT/home/$n"
EOF
for t in chown logger pwd_mkdb; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$LV_LOG"\nexit 0\n' "$t" > "$lv/bin/$t"
done
chmod 755 "$lv/bin/"*
mkdir -p "$lv/rcsubr"
printf 'load_rc_config() { :; }\nrun_rc_command() { case ${1:-} in start) "$start_cmd" ;; esac; }\n' > "$lv/rcsubr/rc.subr"

lvroot() { # lvroot <dir> <live|installed> — a root tree for the live session
	rm -rf "$1"
	mkdir -p "$1/etc/rc.d" "$1/home" "$1/usr/local/etc/lightdm/lightdm.conf.d" \
		"$1/usr/local/share/examplebsd/live" "$1/usr/local/sbin" "$1/usr/local/bin" "$1/var/mail"
	printf 'root:*:0:0::0:0:Charlie &:/root:/bin/sh\nalice:*:1100:1100::0:0:Alice:/home/alice:/bin/sh\n' > "$1/etc/master.passwd"
	[ "$2" = live ] && printf 'installer::0:0::0:0:DragonFly Installer:/root:/usr/sbin/installer\n' >> "$1/etc/master.passwd"
	printf 'root:*:0:0:Charlie &:/root:/bin/sh\nalice:*:1100:1100:Alice:/home/alice:/bin/sh\n' > "$1/etc/passwd"
	printf 'wheel:*:0:root\nalice:*:1100:\n' > "$1/etc/group"
	printf 'permit persist :wheel\n' > "$1/usr/local/etc/doas.conf"
	sed -e 's/@SLUG@/examplebsd/g' "$dov/usr/local/share/@SLUG@/live/90-live-autologin.conf" \
		> "$1/usr/local/share/examplebsd/live/90-live-autologin.conf"
	sh "$repo/tests/fixtures/fake-installer-template/install-into-stage.sh" "$1" --metalog "$lv/metalog" > /dev/null
	lvsub "$dov/usr/local/sbin/@SLUG@-live-clean" "$1/usr/local/sbin/examplebsd-live-clean"
	sed -e "s#/etc/rc\\.subr#$lv/rcsubr/rc.subr#" -e 's/@SLUG@/examplebsd/g' -e 's/@DISTRO_NAME@/ExampleBSD/g' \
		"$dov/etc/rc.d/live_session" > "$1/etc/rc.d/live_session"
}
lvrun() { # lvrun <root> — run the live session script on the root
	: > "$lv/log"
	PATH="$lv/bin:$PATH" LV_LOG="$lv/log" LV_ROOT="$1" live_session_root="$1" \
		sh "$1/etc/rc.d/live_session" start > "$lv/run.log" 2>&1
	lvrc=$?
}

# (LV18) the live medium (installer-template README, "The live medium"):
#        the live media write /var/run/wtfbsd-live-medium early, one line,
#        the disk the root is mounted from (a part-by-label or serno link
#        followed to its device, the slice and partition dropped), a
#        regular file of mode 0644 renamed into place (a symbolic link
#        there is replaced, not followed); the installed system writes
#        none; a root that is not a device, or a link that cannot be
#        followed, writes none and says so
mkdir -p "$lv/mbin"
printf '#!/bin/sh\n[ "$1" = -p ] && printf "%%s\\n" "$LV_MOUNT_P"\nexit 0\n' > "$lv/mbin/mount"
chmod 755 "$lv/mbin/mount"
lvmed() { # lvmed <root> <mount -p output> — run live_medium on the root
	sed -e "s#/etc/rc\\.subr#$lv/rcsubr/rc.subr#" "$dov/etc/rc.d/live_medium" > "$1/etc/rc.d/live_medium"
	PATH="$lv/mbin:$PATH" LV_MOUNT_P="$2" live_medium_root="$1" \
		sh "$1/etc/rc.d/live_medium" start > "$lv/med.log" 2>&1
	lvmrc=$?
}
lvroot "$lv/med-live" live
mkdir -p "$lv/med-live/var/run" "$lv/med-live/dev/part-by-label"
ln -s ../vbd1s1a "$lv/med-live/dev/part-by-label/examplebsd-live.a"
mkdir -p "$lv/med-target"
ln -s "$lv/med-target" "$lv/med-live/var/run/wtfbsd-live-medium"
lvmed "$lv/med-live" "$(printf '/dev/part-by-label/examplebsd-live.a\t/\tufs\trw\t1\t1\ntmpfs\t/tmp\ttmpfs\trw\t0\t0')"
lvmf="$lv/med-live/var/run/wtfbsd-live-medium"
if [ "$lvmrc" -eq 0 ] && [ -f "$lvmf" ] && [ ! -L "$lvmf" ] && [ -z "$(ls -A "$lv/med-target")" ] &&
	[ "$(cat "$lvmf")" = /dev/vbd1 ] && [ "$(wc -l < "$lvmf" | tr -d ' ')" = 1 ] &&
	[ "$(ls -l "$lvmf" | cut -c1-10)" = '-rw-r--r--' ] &&
	[ -z "$(find "$lv/med-live/var/run" -name '*wtfbsd-live-medium.*')" ]; then
	ok "(LV18) the live media write /var/run/wtfbsd-live-medium: one line, the disk of the root (its label followed), mode 0644, a link in its place replaced and not followed"
else
	no "(LV18) the live media write /var/run/wtfbsd-live-medium: one line, the disk of the root (its label followed), mode 0644, a link in its place replaced and not followed (rc=$lvmrc)"
	ls -l "$lvmf" 2>&1 | sed 's/^/      | /'; cat "$lvmf" 2>/dev/null | sed 's/^/      | /'; sed 's/^/      | /' "$lv/med.log"
fi
lvroot "$lv/med-plain" live
mkdir -p "$lv/med-plain/var/run"
lvmed "$lv/med-plain" "$(printf '/dev/da0s1a\t/\tufs\trw\t1\t1')"
lvplain=$(cat "$lv/med-plain/var/run/wtfbsd-live-medium" 2>/dev/null)
lvroot "$lv/med-cd" live
mkdir -p "$lv/med-cd/var/run"
lvmed "$lv/med-cd" "$(printf '/dev/cd0\t/\tcd9660\tro\t0\t0')"
lvcd=$(cat "$lv/med-cd/var/run/wtfbsd-live-medium" 2>/dev/null)
lvroot "$lv/med-serno" live
mkdir -p "$lv/med-serno/var/run" "$lv/med-serno/dev/serno"
ln -s ../vbd3 "$lv/med-serno/dev/serno/BHYVE-1234.ABCD"
lvmed "$lv/med-serno" "$(printf '/dev/serno/BHYVE-1234.ABCD.s1a\t/\tufs\trw\t1\t1')"
lvserno=$(cat "$lv/med-serno/var/run/wtfbsd-live-medium" 2>/dev/null)
# DragonFly's part-by-label node is a device of its own, not a link: it is
# matched by its device number against the slices of the disks of
# kern.disks (stand-ins for stat -L -f and sysctl); mount -p of a single
# user start names it without /dev/
cat > "$lv/mbin/stat" <<'EOF2'
#!/bin/sh
[ "$1" = -L ] && [ "$2" = -f ] && [ "$3" = '%Hr %Lr' ] || exit 2
[ -e "$4" ] || exit 1
awk -v n="${4##*/}" '$1 == n { print $2 " " $3; f = 1 } END { exit !f }' "$LV_DEVNUMS"
EOF2
printf '#!/bin/sh\n[ "$1 $2" = "-n kern.disks" ] || exit 2\nprintf "%%s\\n" "$LV_DISKS"\n' > "$lv/mbin/sysctl"
chmod 755 "$lv/mbin/stat" "$lv/mbin/sysctl"
lvroot "$lv/med-dnum" live
mkdir -p "$lv/med-dnum/var/run" "$lv/med-dnum/dev/part-by-label"
for f in vbd0 vbd0s1 vbd0s2 vbd0s2a vbd1 vbd1s1 vbd1s1a part-by-label/DragonFly_v6.4.2.a; do : > "$lv/med-dnum/dev/$f"; done
printf 'DragonFly_v6.4.2.a 25 196608\nvbd0 25 504430599\nvbd0s1 25 504496135\nvbd0s2 25 504496136\nvbd0s2a 25 196608\nvbd1 25 504430607\nvbd1s1 25 504496143\nvbd1s1a 25 196609\n' > "$lv/devnums"
LV_DEVNUMS="$lv/devnums" LV_DISKS='vbd1 vbd0' lvmed "$lv/med-dnum" "$(printf '/dev/part-by-label/DragonFly_v6.4.2.a\t/\tufs\tro\t0\t1')"
lvdnum=$(cat "$lv/med-dnum/var/run/wtfbsd-live-medium" 2>/dev/null)
rm -f "$lv/med-dnum/var/run/wtfbsd-live-medium"
LV_DEVNUMS="$lv/devnums" LV_DISKS='vbd1 vbd0' lvmed "$lv/med-dnum" "$(printf 'part-by-label/DragonFly_v6.4.2.a\t/\tufs\tro\t0\t1')"
lvdnum2=$(cat "$lv/med-dnum/var/run/wtfbsd-live-medium" 2>/dev/null)
rm -f "$lv/med-dnum/var/run/wtfbsd-live-medium"
LV_DEVNUMS="$lv/devnums" LV_DISKS='vbd1' lvmed "$lv/med-dnum" "$(printf '/dev/part-by-label/DragonFly_v6.4.2.a\t/\tufs\tro\t0\t1')"
lvdnumrc=$lvmrc
if [ "$lvdnum" = /dev/vbd0 ] && [ "$lvdnum2" = /dev/vbd0 ] && [ "$lvdnumrc" -ne 0 ] &&
	[ ! -e "$lv/med-dnum/var/run/wtfbsd-live-medium" ] && grep -q 'cannot follow' "$lv/med.log"; then
	ok "(LV18) a part-by-label device that is not a link is matched by its device number to its disk (also named without /dev/); no match writes nothing"
else
	no "(LV18) a part-by-label device that is not a link is matched by its device number to its disk (also named without /dev/); no match writes nothing ($lvdnum/$lvdnum2/$lvdnumrc)"
	sed 's/^/      | /' "$lv/med.log"
fi
lvroot "$lv/med-nolink" live
mkdir -p "$lv/med-nolink/var/run" "$lv/med-nolink/dev/part-by-label"
lvmed "$lv/med-nolink" "$(printf '/dev/part-by-label/gone.a\t/\tufs\trw\t1\t1')"
lvnolinkrc=$lvmrc
if [ "$lvplain" = /dev/da0 ] && [ "$lvcd" = /dev/cd0 ] && [ "$lvserno" = /dev/vbd3 ] && [ "$lvnolinkrc" -ne 0 ] &&
	[ ! -e "$lv/med-nolink/var/run/wtfbsd-live-medium" ] && grep -q 'cannot follow' "$lv/med.log"; then
	ok "(LV18) a root on a partition names its disk (da0s1a: /dev/da0, cd0: /dev/cd0, a serno partition: its disk); a label that cannot be followed writes nothing and says so"
else
	no "(LV18) a root on a partition names its disk (da0s1a: /dev/da0, cd0: /dev/cd0, a serno partition: its disk); a label that cannot be followed writes nothing and says so ($lvplain/$lvcd/$lvserno/$lvnolinkrc)"
	sed 's/^/      | /' "$lv/med.log"
fi
lvroot "$lv/med-inst" installed
lvmed "$lv/med-inst" "$(printf '/dev/part-by-label/examplebsd-a1b2c3d4.d\t/\thammer2\trw\t1\t1')"
lvroot "$lv/med-odd" live
lvmed "$lv/med-odd" "$(printf 'vbd0s1d@ROOT\t/\thammer2\trw\t1\t1')"
lvmoddrc=$lvmrc
if [ ! -e "$lv/med-inst/var/run/wtfbsd-live-medium" ] && [ "$lvmoddrc" -ne 0 ] &&
	[ ! -e "$lv/med-odd/var/run/wtfbsd-live-medium" ] && grep -q 'is not a device' "$lv/med.log"; then
	ok "(LV18) the installed system writes no live-medium file; a root that is not a /dev device writes none and says so"
else
	no "(LV18) the installed system writes no live-medium file; a root that is not a /dev device writes none and says so (rc=$lvmoddrc)"
fi
if grep -q '^# REQUIRE: mountcritlocal cleanvar$' "$dov/etc/rc.d/live_medium" &&
	grep -q '^# BEFORE: live_session LOGIN$' "$dov/etc/rc.d/live_medium" &&
	[ -f "$lv1sk/etc/rc.d/live_medium" ] && grep -qxF "CMD chmod 755 $lv1sk/etc/rc.d/live_medium" "$work/lv1/stub.log"; then
	ok "(LV18) live_medium runs early (after cleanvar, before the live session and the login) and is staged executable"
else
	no "(LV18) live_medium runs early (after cleanvar, before the live session and the login) and is staged executable"
fi

# (LV3) the live media: the live user (the first free uid from 1100, not
#       in wheel), the autostart of the installer, the automatic login,
#       one doas rule: the root helper of the installer only
L="$lv/live"
lvroot "$L" live
lvrun "$L"
lvrun "$L"
if [ "$lvrc" -eq 0 ] && grep -q '^pw useradd -n live -u 1101 ' "$lv/log" 2>/dev/null ||
	grep -q '^live:\*:1101:' "$L/etc/passwd"; then
	ok "(LV3) the live media get the live user, with the first free uid from 1100 up"
else
	no "(LV3) the live media get the live user, with the first free uid from 1100 up (rc=$lvrc)"
	sed 's/^/      | /' "$lv/run.log" "$L/etc/passwd"
fi
if [ "$(grep -c '^live:' "$L/etc/passwd")" -eq 1 ]; then
	ok "(LV3) a second boot creates no second live user"
else
	no "(LV3) a second boot creates no second live user"
fi
if cmp -s "$L/usr/local/share/wtfbsd-installer/autostart/wtfbsd-installer.desktop" "$L/home/live/.config/autostart/wtfbsd-installer.desktop"; then
	ok "(LV3) the autostart entry of the installer is in the autostart directory of the live user (the installer opens first)"
else
	no "(LV3) the autostart entry of the installer is in the autostart directory of the live user (the installer opens first)"
	find "$L/home" 2>/dev/null | sed 's/^/      | /'
fi
if grep -q '^autologin-user=live$' "$L/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" 2>/dev/null &&
	grep -q '^autologin-session=xfce$' "$L/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf"; then
	ok "(LV3) LightDM logs the live user into Xfce by itself on the live media"
else
	no "(LV3) LightDM logs the live user into Xfce by itself on the live media"
fi
lvpermit=$(grep '^permit' "$L/usr/local/etc/doas.conf" | grep -c ' live ')
if [ "$lvpermit" -eq 1 ] &&
	grep -qx 'permit nopass live as root cmd /usr/local/libexec/wtfbsd-installer/installer-apply' "$L/usr/local/etc/doas.conf" &&
	! grep -Eq 'keepenv|setenv' "$L/usr/local/etc/doas.conf" &&
	grep -q '^permit persist :wheel$' "$L/usr/local/etc/doas.conf"; then
	ok "(LV3) the doas.conf of the live media holds exactly one permit line for live: the root helper of the installer, no keepenv, no setenv"
else
	no "(LV3) the doas.conf of the live media holds exactly one permit line for live: the root helper of the installer, no keepenv, no setenv"
	sed 's/^/      | /' "$L/usr/local/etc/doas.conf"
fi
if grep -q '^live:' "$L/etc/passwd" && ! grep -q -- '-G' "$lv/log" && ! grep -Eq '^wheel:.*[:,]live(,|$)' "$L/etc/group"; then
	ok "(LV3) the live user is not in the wheel group"
else
	no "(LV3) the live user is not in the wheel group"
fi

# (LV4) the installed system (no installer account): no live user is
#       created, and what a copy of the live root brought along is removed
I="$lv/inst"
lvroot "$I" installed
cp "$L/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" "$I/usr/local/etc/lightdm/lightdm.conf.d/"
cp "$L/usr/local/etc/doas.conf" "$I/usr/local/etc/doas.conf"
lvrun "$I"
if [ "$lvrc" -eq 0 ] && [ -s "$I/etc/rc.d/live_session" ] && ! grep -q '^pw useradd' "$lv/log" && ! grep -q '^live:' "$I/etc/passwd" &&
	[ ! -e "$I/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" ] &&
	! grep -q 'live' "$I/usr/local/etc/doas.conf" && grep -q '^permit persist :wheel$' "$I/usr/local/etc/doas.conf"; then
	ok "(LV4) the installed system gets no live user, and a leftover automatic login and doas rule are removed"
else
	no "(LV4) the installed system gets no live user, and a leftover automatic login and doas rule are removed (rc=$lvrc)"
	sed 's/^/      | /' "$lv/run.log" "$lv/log" "$I/usr/local/etc/doas.conf"
fi

# (LV5) the live clean-up on a copy of the live root: the live user (its
#       lines, its group, its home, its mail), the automatic login, the
#       doas rule, the menu and autostart entries are gone; the live
#       media themselves are refused
C="$lv/copy"
rm -rf "$C"; cp -R "$L" "$C"
awk '!/^installer:/' "$C/etc/master.passwd" > "$C/mp" && mv "$C/mp" "$C/etc/master.passwd"
printf 'operator:*:5:root,live\n' >> "$C/etc/group"
: > "$C/var/mail/live"
mkdir -p "$C/usr/local/etc/xdg/autostart"; : > "$C/usr/local/etc/xdg/autostart/wtfbsd-installer.desktop"
PATH="$lv/bin:$PATH" LV_LOG="$lv/log" sh "$C/usr/local/sbin/examplebsd-live-clean" "$C" > "$lv/clean.log" 2>&1
crc=$?
if [ "$crc" -eq 0 ] && ! grep -q '^live:' "$C/etc/master.passwd" "$C/etc/passwd" "$C/etc/group" &&
	grep -q '^operator:\*:5:root$' "$C/etc/group" && grep -q '^alice:' "$C/etc/passwd" &&
	[ ! -e "$C/home/live" ] && [ ! -e "$C/var/mail/live" ] &&
	[ ! -e "$C/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" ] &&
	! grep -q 'live' "$C/usr/local/etc/doas.conf" &&
	[ ! -e "$C/usr/local/share/applications/wtfbsd-installer.desktop" ] &&
	[ ! -e "$C/usr/local/etc/xdg/autostart/wtfbsd-installer.desktop" ] &&
	[ ! -e "$C/usr/local/bin/wtfbsd-installer" ] && [ ! -e "$C/usr/local/libexec/wtfbsd-installer" ] &&
	[ ! -e "$C/usr/local/share/wtfbsd-installer" ] && [ -d "$C/usr/local/bin" ]; then
	ok "(LV5) the live clean-up leaves no live user, no automatic login, no doas rule and no installer entry; every path of the MANIFEST is gone"
else
	no "(LV5) the live clean-up leaves no live user, no automatic login, no doas rule and no installer entry; every path of the MANIFEST is gone (rc=$crc)"
	sed 's/^/      | /' "$lv/clean.log" "$C/etc/group" "$C/usr/local/etc/doas.conf"
fi
# Python run as root on the live media leaves __pycache__ (only .pyc
# files) in the directories of the installer: removed with them; a
# directory that holds anything else is kept and the clean-up says so
C3="$lv/copy3"
rm -rf "$C3"; cp -R "$L" "$C3"
awk '!/^installer:/' "$C3/etc/master.passwd" > "$C3/mp" && mv "$C3/mp" "$C3/etc/master.passwd"
mkdir -p "$C3/usr/local/libexec/wtfbsd-installer/bin/__pycache__" "$C3/usr/local/libexec/wtfbsd-installer/__pycache__"
: > "$C3/usr/local/libexec/wtfbsd-installer/bin/__pycache__/diskplan.cpython-311.pyc"
: > "$C3/usr/local/libexec/wtfbsd-installer/__pycache__/x.cpython-311.pyc"
PATH="$lv/bin:$PATH" LV_LOG="$lv/log" sh "$C3/usr/local/sbin/examplebsd-live-clean" "$C3" > "$lv/clean3.log" 2>&1
crc3=$?
C4="$lv/copy4"
rm -rf "$C4"; cp -R "$L" "$C4"
awk '!/^installer:/' "$C4/etc/master.passwd" > "$C4/mp" && mv "$C4/mp" "$C4/etc/master.passwd"
mkdir -p "$C4/usr/local/libexec/wtfbsd-installer/bin/__pycache__"
: > "$C4/usr/local/libexec/wtfbsd-installer/bin/__pycache__/notes.txt"
PATH="$lv/bin:$PATH" LV_LOG="$lv/log" sh "$C4/usr/local/sbin/examplebsd-live-clean" "$C4" > "$lv/clean4.log" 2>&1
crc4=$?
if [ "$crc3" -eq 0 ] && [ ! -e "$C3/usr/local/libexec/wtfbsd-installer" ] && [ ! -e "$C3/usr/local/share/wtfbsd-installer" ] &&
	[ "$crc4" -ne 0 ] && [ -f "$C4/usr/local/libexec/wtfbsd-installer/bin/__pycache__/notes.txt" ]; then
	ok "(LV5) the bytecode caches Python left in the installer's directories go with them; a directory holding anything else is kept and reported"
else
	no "(LV5) the bytecode caches Python left in the installer's directories go with them; a directory holding anything else is kept and reported ($crc3/$crc4)"
	sed 's/^/      | /' "$lv/clean3.log"
fi
PATH="$lv/bin:$PATH" LV_LOG="$lv/log" sh "$L/usr/local/sbin/examplebsd-live-clean" "$L" > "$lv/clean2.log" 2>&1
crc=$?
if [ "$crc" -ne 0 ] && [ -e "$L/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" ] && grep -q '^live:' "$L/etc/passwd"; then
	ok "(LV5) the live clean-up refuses the live media themselves"
else
	no "(LV5) the live clean-up refuses the live media themselves (rc=$crc)"
fi
if grep -q 'exec /usr/local/sbin/@SLUG@-live-clean /mnt' "$dov/usr/local/bin/after_installation_routines.sh" 2>/dev/null; then
	ok "(LV5) the stock installer runs the live clean-up on the disk it installed (/mnt)"
else
	no "(LV5) the stock installer runs the live clean-up on the disk it installed (/mnt)"
fi

# (LV6) the install command, through stand-ins for the disk tools: the
#       live root (with the live session of LV3) is copied the way the
#       stock installer copies it (X.hdd for X), the live session is
#       removed from the copy, the first boot gets the answers
ib="$lv/ibin"
mkdir -p "$ib"
for t in dd newfs newfs_msdos newfs_hammer2 mount_msdos mount_hammer2 mount_null umount mtree pwd_mkdb chown; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$INST_LOG"\nexit 0\n' "$t" > "$ib/$t"
done
cat > "$ib/gpt" <<'EOF'
#!/bin/sh
printf 'gpt %s\n' "$*" >> "$INST_LOG"
if [ "$1" = show ]; then
	printf '     start      size  index  contents\n         0         1      -  PMBR\n      2048    262144      0  GPT part - EFI System\n    264192  83619840      1  GPT part - DragonFly Label64\n'
fi
exit 0
EOF
cat > "$ib/disklabel64" <<'EOF'
#!/bin/sh
printf 'disklabel64 %s\n' "$*" >> "$INST_LOG"
if [ "$1" = -r ] && [ $# -eq 2 ]; then
	printf '# /dev/%s:\ntype: unknown\ndisk: vbd0s1\n\n16 partitions:\n#          size     offset    fstype\n' "$2"
fi
case $* in *-R*)
	for a; do :; done
	cat "$a" >> "$INST_LOG.label"
	# devfs names the partitions of a label with a name by that name
	l=$(sed -n 's/^label: //p' "$a" | tail -n 1)
	if [ -n "$l" ] && [ "${LV_NO_LABEL_NODES:-0}" != 1 ]; then
		mkdir -p "$INSTALL_DEV/part-by-label"
		for p in a b d; do : > "$INSTALL_DEV/part-by-label/$l.$p"; done
	fi
	;;
esac
exit 0
EOF
cat > "$ib/mount" <<'EOF'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$INST_LOG"
[ "$1" = -p ] && cat "$MOUNTS_P"
exit 0
EOF
cat > "$ib/swapctl" <<'EOF'
#!/bin/sh
printf 'Device      1K-blocks     Used    Avail Capacity  Priority\n'
EOF
cat > "$ib/sysctl" <<'EOF'
#!/bin/sh
case $2 in
kern.disks) printf '%s\n' "$KERN_DISKS" ;;
hw.physmem) printf '8589934592\n' ;;
*) exit 1 ;;
esac
EOF
cat > "$ib/stat" <<'EOF'
#!/bin/sh
# stat -L -f %r PATH: the device number from the map of the case
[ "$1" = -L ] && [ "$2" = -f ] && [ "$3" = %r ] || exit 2
awk -v p="$4" '$1 == p { print $2; f = 1 } END { exit !f }' "$RDEV_MAP"
EOF
cat > "$ib/ifconfig" <<'EOF'
#!/bin/sh
[ "$1" = -l ] && printf 'vtnet0 lo0 wlan0 em1\n'
exit 0
EOF
cat > "$ib/cpdup" <<'EOF'
#!/bin/sh
printf 'cpdup %s\n' "$*" >> "$INST_LOG"
[ "$1" = -o ] && shift
if [ -d "$1" ]; then mkdir -p "$2" && cp -R "$1/." "$2/"; else cp "$1" "$2"; fi
EOF
chmod 755 "$ib/"*
lvsub "$dov/usr/local/sbin/@SLUG@-install" "$lv/examplebsd-install"

S="$lv/src"
rm -rf "$S"; cp -R "$L" "$S"
mkdir -p "$S/etc.hdd" "$S/boot/kernel" "$S/usr/share/installer" "$S/usr/share/zoneinfo/Europe" \
	"$S/usr/share/syscons/keymaps" "$S/var/log" "$S/root" "$S/bin"
printf 'root:*:0:0::0:0:Charlie &:/root:/bin/sh\n' > "$S/etc.hdd/master.passwd"
printf 'root:*:0:0:Charlie &:/root:/bin/sh\n' > "$S/etc.hdd/passwd"
printf 'wheel:*:0:root\n' > "$S/etc.hdd/group"
printf 'lightdm_enable="YES"\n' > "$S/etc.hdd/rc.conf"
printf 'kernel_options="-C"\nconsole="comconsole"\n' > "$S/boot/loader.conf"
printf 'efi\n' > "$S/boot/boot1.efi"; printf 'kernel\n' > "$S/boot/kernel/kernel"; printf 'loader\n' > "$S/boot/loader.efi"
printf 'USERNAME=builduser\n' > "$S/boot/firstboot-user.conf"
printf '/COPYRIGHT\n/bin\n/boot\n/etc\n/root\n/tmp\n/usr/local\n/usr/local/etc\n/usr/share\n/var\n' > "$S/usr/share/installer/sources.conf"
: > "$S/usr/share/zoneinfo/Europe/Berlin"; : > "$S/usr/share/syscons/keymaps/de.iso.kbd"
mkdir -p "$S/tmp"; : > "$S/tmp/live-junk"
mkdir -p "$S/usr/local/etc/xdg/autostart"; : > "$S/usr/local/etc/xdg/autostart/wtfbsd-installer.desktop"
mkdir -p "$lv/dev"
for d in vbd0 vbd0s0 vbd0s1 vbd0s1a vbd0s1b vbd0s1d vbd1 vbd1s1 vbd1s2 vbd1s2a; do : > "$lv/dev/$d"; done
mkdir -p "$lv/dev/part-by-label"; : > "$lv/dev/part-by-label/DragonFly_v6.4.2.a"
printf '%s 1\n%s 2\n%s 3\n%s 4\n%s 5\n%s 6\n%s 7\n%s 8\n%s 9\n%s 9\n' \
	"$lv/dev/vbd0" "$lv/dev/vbd0s0" "$lv/dev/vbd0s1" "$lv/dev/vbd0s1a" "$lv/dev/vbd0s1b" "$lv/dev/vbd0s1d" \
	"$lv/dev/vbd1" "$lv/dev/vbd1s1" "$lv/dev/vbd1s2a" "$lv/dev/part-by-label/DragonFly_v6.4.2.a" > "$lv/rdev"
printf '/dev/part-by-label/DragonFly_v6.4.2.a\t/\tufs rw\t1 1\ndevfs\t/dev\tdevfs rw\t0 0\ntmpfs\t/tmp\ttmpfs rw\t0 0\n' > "$lv/mounts"
umask 077; printf '%s\n' '$6$saltsalt$NotARealHashButShapedLikeOne0123456789' > "$lv/hash"; umask 022
printf '%s %s %s\n' 'ssh-ed25519' 'AAAAtest' 'k@h' > "$lv/key"

lvinst() { # lvinst <args...> — run the install command; sets irc, $lv/i.out, $lv/i.err
	rm -rf "$lv/mnt"
	: > "$lv/inst.log"; rm -f "$lv/inst.log.label"
	PATH="$ib:$PATH" INST_LOG="$lv/inst.log" MOUNTS_P="$lv/mounts" RDEV_MAP="$lv/rdev" \
	KERN_DISKS="${LV_DISKS:-vbd1 vbd0}" INSTALL_SRC="$S" INSTALL_DEV="$lv/dev" INSTALL_MNT="$lv/mnt" \
	INSTALL_TEST_ALLOW_NONROOT=1 TMPDIR="$lv" \
		sh "$lv/examplebsd-install" "$@" > "$lv/i.out" 2> "$lv/i.err"
	irc=$?
}
# a netmask, assembled so that the tree holds no dotted quad outside the
# documentation ranges
lvmask=$(printf '%s.%s.%s.%s' 255 255 255 0)
lvinst -d vbd0 -u wtfuser -k "$lv/key" -H "$lv/hash" -n box.example.org -z Europe/Berlin -K de.iso \
	-c 'Wtf User' -P -N "vtnet0:192.0.2.10/$lvmask:192.0.2.1" -N em1:dhcp -y --progress
M="$lv/mnt"
if [ "$irc" -eq 0 ] && [ "$(tail -1 "$lv/i.out")" = 'PROGRESS 100 ExampleBSD is installed on vbd0' ] &&
	! grep -qv '^PROGRESS [0-9][0-9]* ' "$lv/i.out"; then
	ok "(LV6) the install command exits 0 and prints PROGRESS lines only, up to 100"
else
	no "(LV6) the install command exits 0 and prints PROGRESS lines only, up to 100 (rc=$irc)"
	sed 's/^/      | /' "$lv/i.out" "$lv/i.err" | tail -20
fi
if grep -q '^gpt add -i 0 -s 262144 -t efi vbd0$' "$lv/inst.log" && grep -q '^gpt add -i 1 -t dragonfly vbd0$' "$lv/inst.log" &&
	grep -q "^newfs_hammer2 $lv/dev/vbd0s1d\$" "$lv/inst.log" && grep -q "^newfs -i 65536 $lv/dev/vbd0s1a\$" "$lv/inst.log" &&
	grep -Eq '^  a:	1024M	0	4.2BSD$' "$lv/inst.log.label" 2>/dev/null &&
	grep -Eq '^  d:	\*	\*	HAMMER2$' "$lv/inst.log.label" && grep -Eq '^  b:	[0-9]+M	\*	swap$' "$lv/inst.log.label" &&
	[ "$(cat "$M/EFI/BOOT/BOOTX64.EFI" 2>/dev/null)" = efi ]; then
	ok "(LV6) the disk gets the layout of the stock installer: EFI, /boot UFS, swap, / HAMMER2, and the EFI loader"
else
	no "(LV6) the disk gets the layout of the stock installer: EFI, /boot UFS, swap, / HAMMER2, and the EFI loader"
	sed 's/^/      | /' "$lv/inst.log" "$lv/inst.log.label" 2>/dev/null | head -40
fi
lvlab=$(sed -n 's/^label: //p' "$lv/inst.log.label" 2>/dev/null | tail -n 1)
if printf '%s\n' "$lvlab" | grep -Eq '^examplebsd-[0-9a-f]{8}$' &&
	grep -qx "vfs.root.mountfrom=\"hammer2:part-by-label/$lvlab.d\"" "$M/boot/loader.conf" 2>/dev/null && [ "$(grep -c . "$M/boot/loader.conf")" -eq 1 ] &&
	grep -Eq "^/dev/part-by-label/$lvlab.d[[:space:]]+/[[:space:]]+hammer2" "$M/etc/fstab" &&
	grep -Eq "^/dev/part-by-label/$lvlab.a[[:space:]]+/boot[[:space:]]+ufs" "$M/etc/fstab" &&
	grep -Eq "^/dev/part-by-label/$lvlab.b[[:space:]]+none[[:space:]]+swap" "$M/etc/fstab" &&
	grep -qx "dumpdev=\"/dev/part-by-label/$lvlab.b\"" "$M/etc/rc.conf" &&
	! grep -q 'vbd0' "$M/etc/fstab" "$M/boot/loader.conf" &&
	grep -Eq '^/build/var.log[[:space:]]+/var/log[[:space:]]+null' "$M/etc/fstab" &&
	[ "$(cat "$M/boot/kernel/kernel")" = kernel ]; then
	ok "(LV6) the installed system boots its own root by the name of its label (part-by-label/<slug>-<8 hex>), never by vbd0: loader.conf, fstab, dumpdev and the /build null mounts"
else
	no "(LV6) the installed system boots its own root by the name of its label (part-by-label/<slug>-<8 hex>), never by vbd0: loader.conf, fstab, dumpdev and the /build null mounts (label: $lvlab)"
	sed 's/^/      | /' "$M/boot/loader.conf" "$M/etc/fstab" 2>/dev/null
fi
if ! grep -q '^installer:' "$M/etc/master.passwd" 2>/dev/null && grep -q '^root:' "$M/etc/master.passwd" &&
	! grep -q '^live:' "$M/etc/master.passwd" "$M/etc/passwd" "$M/etc/group" &&
	[ ! -e "$M/home/live" ] && [ -d "$M/home" ] &&
	[ ! -e "$M/usr/local/etc/lightdm/lightdm.conf.d/90-live-autologin.conf" ] &&
	! grep -q 'live' "$M/usr/local/etc/doas.conf" &&
	[ ! -e "$M/usr/local/etc/xdg/autostart/wtfbsd-installer.desktop" ] &&
	[ ! -e "$M/usr/local/share/applications/wtfbsd-installer.desktop" ] &&
	[ ! -e "$M/tmp/live-junk" ]; then
	ok "(LV6) the installed system has no live user, no automatic login and no installer that opens by itself"
else
	no "(LV6) the installed system has no live user, no automatic login and no installer that opens by itself"
	ls -R "$M/home" "$M/usr/local/etc" 2>/dev/null | sed 's/^/      | /' | head -20
fi
fbm=$(ls -ln "$M/boot/firstboot-user.conf" 2>/dev/null | awk '{ print $1 }')
if [ "$fbm" = '-rw-------' ] && grep -q '^USERNAME=wtfuser$' "$M/boot/firstboot-user.conf" &&
	grep -qF 'PASSWORD_HASH=$6$saltsalt$' "$M/boot/firstboot-user.conf" &&
	grep -qxF "SSH_KEY=$(cat "$lv/key")" "$M/boot/firstboot-user.conf" &&
	grep -q '^HOSTNAME=box.example.org$' "$M/boot/firstboot-user.conf" &&
	grep -q '^TIMEZONE=Europe/Berlin$' "$M/boot/firstboot-user.conf" &&
	grep -q '^KEYMAP=de.iso$' "$M/boot/firstboot-user.conf" && ! grep -q builduser "$M/boot/firstboot-user.conf" &&
	grep -q '^FULLNAME=Wtf User$' "$M/boot/firstboot-user.conf" && grep -q '^DOAS_NOPASS=yes$' "$M/boot/firstboot-user.conf"; then
	ok "(LV6) the first-boot configuration (0600) holds the account, the hash, the key, the host name, the time zone, the keymap, the full name and -P"
else
	no "(LV6) the first-boot configuration (0600) holds the account, the hash, the key, the host name, the time zone, the keymap, the full name and -P (mode $fbm)"
fi
if grep -qx "ifconfig_vtnet0=\"inet 192.0.2.10 netmask $lvmask\"" "$M/etc/rc.conf" 2>/dev/null &&
	grep -qx 'defaultrouter="192.0.2.1"' "$M/etc/rc.conf" && grep -qx 'ifconfig_em1="DHCP"' "$M/etc/rc.conf" &&
	! grep -q 'wlan0\|lo0' "$M/etc/rc.conf"; then
	ok "(LV6) -N writes the static address, the gateway and DHCP of the adapters into rc.conf"
else
	no "(LV6) -N writes the static address, the gateway and DHCP of the adapters into rc.conf"
	sed 's/^/      | /' "$M/etc/rc.conf" 2>/dev/null
fi
if grep -q 'Option "XkbLayout" "de"' "$M/usr/local/etc/X11/xorg.conf.d/00-keyboard.conf" 2>/dev/null &&
	grep -q 'MatchIsKeyboard "on"' "$M/usr/local/etc/X11/xorg.conf.d/00-keyboard.conf"; then
	ok "(LV6) -K de.iso gives X the layout de (xorg.conf.d keyboard section)"
else
	no "(LV6) -K de.iso gives X the layout de (xorg.conf.d keyboard section)"
fi
if [ "$irc" -eq 0 ] && [ -d "$M/usr/local/bin" ] && [ ! -e "$M/usr/local/bin/wtfbsd-installer" ] && [ ! -e "$M/usr/local/libexec/wtfbsd-installer" ] &&
	[ ! -e "$M/usr/local/share/wtfbsd-installer" ]; then
	ok "(LV6) every path of the MANIFEST of the installer is removed from the installed system"
else
	no "(LV6) every path of the MANIFEST of the installer is removed from the installed system"
fi
if [ "$irc" -eq 0 ] && grep -qF 'PASSWORD_HASH=' "$M/boot/firstboot-user.conf" && ! grep -rqF 'NotARealHash' "$lv/i.out" "$lv/i.err" "$lv/inst.log" "$M/var/log" 2>/dev/null; then
	ok "(LV6) the hash never reaches the output or the log"
else
	no "(LV6) the hash never reaches the output or the log"
fi
lvumount=$(grep -c '^umount ' "$lv/inst.log")
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
if [ "$irc" -eq 0 ] && grep -qx 'ifconfig_vtnet0="DHCP"' "$lv/mnt/etc/rc.conf" && grep -qx 'ifconfig_em1="DHCP"' "$lv/mnt/etc/rc.conf" &&
	! grep -q 'wlan0\|lo0\|defaultrouter' "$lv/mnt/etc/rc.conf"; then
	ok "(LV6) without -N every wired adapter asks DHCP"
else
	no "(LV6) without -N every wired adapter asks DHCP (rc=$irc)"
	sed 's/^/      | /' "$lv/mnt/etc/rc.conf" "$lv/i.out" 2>/dev/null | tail -8
fi
if [ "$lvumount" -ge 9 ] && grep -q '^disklabel64 -B vbd0s1$' "$lv/inst.log"; then
	ok "(LV6) everything that was mounted is unmounted, and the label is made bootable"
else
	no "(LV6) everything that was mounted is unmounted, and the label is made bootable ($lvumount umounts)"
fi

# (LV13) the disk keeps its name across renumbering: every install gives
#        the label a name of its own, and an install whose label names do
#        not appear in devfs stops before anything is copied
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
lvl1=$(sed -n 's/^label: //p' "$lv/inst.log.label" | tail -n 1)
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
lvl2=$(sed -n 's/^label: //p' "$lv/inst.log.label" | tail -n 1)
if [ -n "$lvl1" ] && [ -n "$lvl2" ] && [ "$lvl1" != "$lvl2" ] &&
	[ "$(grep -c '^label:' "$lv/inst.log.label")" -eq 1 ]; then
	ok "(LV13) two installs give their labels different names, and the label has exactly one name line"
else
	no "(LV13) two installs give their labels different names, and the label has exactly one name line ($lvl1 / $lvl2)"
fi
printf 'lightdm_enable="YES"\ndumpdev="/dev/vbd9s1b"\n' > "$S/etc.hdd/rc.conf"
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
lvl3=$(sed -n 's/^label: //p' "$lv/inst.log.label" | tail -n 1)
if [ "$irc" -eq 0 ] && [ "$(grep -c '^dumpdev=' "$lv/mnt/etc/rc.conf")" -eq 1 ] &&
	grep -qx "dumpdev=\"/dev/part-by-label/$lvl3.b\"" "$lv/mnt/etc/rc.conf"; then
	ok "(LV13) a dumpdev the copy brought along is replaced by the swap of the new disk, by its label"
else
	no "(LV13) a dumpdev the copy brought along is replaced by the swap of the new disk, by its label (rc=$irc)"
	grep -n dumpdev "$lv/mnt/etc/rc.conf" 2>/dev/null | sed 's/^/      | /'
fi
printf 'lightdm_enable="YES"\n' > "$S/etc.hdd/rc.conf"
rm -f "$lv/dev/part-by-label"/examplebsd-*
LV_NO_LABEL_NODES=1 lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
if [ "$irc" -ne 0 ] && grep -q '^ERROR the partitions of vbd0s1 did not appear as .*part-by-label/examplebsd-' "$lv/i.out" &&
	! grep -q '^cpdup ' "$lv/inst.log"; then
	ok "(LV13) an install whose part-by-label names do not appear stops before anything is copied"
else
	no "(LV13) an install whose part-by-label names do not appear stops before anything is copied (rc=$irc)"
	tail -n 3 "$lv/i.out" | sed 's/^/      | /'
fi

# (LV7) the refusals: the disk of the running system (by name and by the
#       alias part-by-label), no -y, a hash file others can read, a plain
#       password, an unknown time zone, a disk the machine does not have;
#       nothing is written, and the ERROR line says why
lvrefuse() { # lvrefuse <what> <pattern> <args...>
	_w=$1 _p=$2
	shift 2
	lvinst "$@"
	if [ "$irc" -ne 0 ] && grep -q "^ERROR .*$_p" "$lv/i.out" && ! grep -q '^gpt \|^dd ' "$lv/inst.log"; then
		ok "(LV7) $_w is refused before anything is written"
	else
		no "(LV7) $_w is refused before anything is written (rc=$irc)"
		sed 's/^/      | /' "$lv/i.out" "$lv/i.err" | tail -5
	fi
}
lvrefuse 'the disk of the live media (mounted through part-by-label)' 'vbd1 is in use' -d vbd1 -u wtfuser -H "$lv/hash" -y --progress
printf 'vbd1s2a\t/\tufs rw\t1 1\n' > "$lv/mounts2"; cp "$lv/mounts" "$lv/mounts.keep"; cp "$lv/mounts2" "$lv/mounts"
lvrefuse 'the disk of the live media (mounted by its name)' 'vbd1 is in use' -d vbd1 -u wtfuser -H "$lv/hash" -y --progress
cp "$lv/mounts.keep" "$lv/mounts"
lvrefuse 'an install without -y' '-y is required' -d vbd0 -u wtfuser -H "$lv/hash" --progress
chmod 644 "$lv/hash"
lvrefuse 'a hash file that others can read' 'mode 0600' -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
chmod 600 "$lv/hash"
umask 077; printf 'secretpassword\n' > "$lv/plain"; umask 022
lvrefuse 'a plain password in the hash file' 'crypt(3) hash' -d vbd0 -u wtfuser -H "$lv/plain" -y --progress
lvrefuse 'an unknown time zone' 'no such time zone' -d vbd0 -u wtfuser -H "$lv/hash" -z Mars/Base -y --progress
lvrefuse 'a disk the machine does not have' 'not a disk of this machine' -d vbd7 -u wtfuser -H "$lv/hash" -y --progress
lvrefuse 'the name of the live user' 'reserved for the live media' -d vbd0 -u live -H "$lv/hash" -y --progress
lvrefuse 'a disk given as a path' 'whole disk' -d /dev/vbd0 -u wtfuser -H "$lv/hash" -y --progress
lvrefuse 'a -N that is neither dhcp nor an address' 'IF:dhcp or IF:ADDR' -d vbd0 -u wtfuser -H "$lv/hash" -N vtnet0:auto -y --progress
lvrefuse 'an account of the system itself' 'an account of the system itself' -d vbd0 -u root -H "$lv/hash" -y --progress

# (LV10) the parity flags of the install command: the disk plan (-p), the
#        filesystem, dm_crypt (LUKS) with a passphrase file, the swap, the
#        secure wipe, the locale, the hardware clock, the root password,
#        the automatic login, IPv6, the resolvers, Wi-Fi and the update
for t in cryptsetup cap_mkdb pkg; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$INST_LOG"\nexit 0\n' "$t" > "$ib/$t"
done
chmod 755 "$ib/"*
mkdir -p "$S/usr/share/locale/fr_FR.UTF-8" "$lv/dev/mapper"
: > "$lv/dev/mapper/root"
printf 'initrd\n' > "$S/boot/kernel/initrd.img.gz"
printf 'default:\\\n\t:passwd_format=sha512:\\\n\t:umask=022:\n' > "$S/etc.hdd/login.conf"
lvsec() { # lvsec <file> <content> — a file of mode 0600
	(umask 077; printf '%s' "$2" > "$1")
	chmod 600 "$1"
}
lvsec "$lv/plan-a" '{"version":1,"mode":"erase","boot":"uefi","disks":["vbd0"],"layout":"single","filesystem":"hammer2","encryption":{"enabled":false},"swap_mb":0,"wipe":{"vbd0":"secure"}}'
lvinst -p "$lv/plan-a" -u wtfuser -H "$lv/hash" -y --progress
if [ "$irc" -eq 0 ] && ! grep -q '^  b:' "$lv/inst.log.label" 2>/dev/null && grep -Eq '^  d:	\*	\*	HAMMER2$' "$lv/inst.log.label" &&
	grep -q "^dd if=/dev/zero of=$lv/dev/vbd0 bs=1m\$" "$lv/inst.log" && ! grep -q swap "$lv/mnt/etc/fstab"; then
	ok "(LV10) a plan with swap_mb 0 and wipe secure: no swap, the whole disk overwritten, HAMMER2 root"
else
	no "(LV10) a plan with swap_mb 0 and wipe secure: no swap, the whole disk overwritten, HAMMER2 root (rc=$irc)"
	sed 's/^/      | /' "$lv/i.out" "$lv/inst.log.label" 2>/dev/null | tail -12
fi

# a secret file that its group can read is refused
lvsec "$lv/plan-g" '{"version":1,"mode":"erase","boot":"uefi","disks":["vbd0"],"layout":"single","filesystem":"ufs","encryption":{"enabled":true,"swap":false},"swap_mb":2048,"wipe":{"vbd0":"quick"},"sector_4k":true,"trim":true}'
lvsec "$lv/pass-g" 'correct horse battery staple
'
chmod 640 "$lv/pass-g"
lvinst -p "$lv/plan-g" -E "$lv/pass-g" -u wtfuser -H "$lv/hash" -y
if [ "$irc" -ne 0 ] && grep -q 'readable by its owner only' "$lv/i.err" && ! grep -q luksFormat "$lv/inst.log"; then
	ok "(LV10) a passphrase file its group can read (0640) is refused"
else
	no "(LV10) a passphrase file its group can read (0640) is refused (rc=$irc)"
	sed 's/^/      | /' "$lv/i.err" | tail -4
fi

# a hash file that its group can read is refused too
cp "$lv/hash" "$lv/hash-g"; chmod 640 "$lv/hash-g"
lvsec "$lv/pass-h" 'correct horse battery staple
'
lvinst -p "$lv/plan-g" -E "$lv/pass-h" -u wtfuser -H "$lv/hash-g" -y
if [ "$irc" -ne 0 ] && grep -q 'hash file must be readable by its owner only' "$lv/i.err"; then
	ok "(LV10) a hash file its group can read (0640) is refused"
else
	no "(LV10) a hash file its group can read (0640) is refused (rc=$irc)"
	sed 's/^/      | /' "$lv/i.err" | tail -4
fi

# DragonFly does not encrypt the swap (not proven): a plan that asks for it is refused
lvsec "$lv/plan-es" '{"version":1,"mode":"erase","boot":"uefi","disks":["vbd0"],"layout":"single","filesystem":"ufs","encryption":{"enabled":true,"swap":true},"swap_mb":2048,"wipe":{"vbd0":"quick"},"sector_4k":true,"trim":true}'
lvsec "$lv/pass-es" 'correct horse battery staple
'
lvinst -p "$lv/plan-es" -E "$lv/pass-es" -u wtfuser -H "$lv/hash" -y
if [ "$irc" -ne 0 ] && grep -q 'dragonfly: no swap encryption' "$lv/i.err" && ! grep -q luksFormat "$lv/inst.log"; then
	ok "(LV10) a plan with an encrypted swap is refused before anything is written"
else
	no "(LV10) a plan with an encrypted swap is refused before anything is written (rc=$irc)"
	sed 's/^/      | /' "$lv/i.err" | tail -4
fi

lvsec "$lv/plan-e" '{"version":1,"mode":"erase","boot":"uefi","disks":["vbd0"],"layout":"single","filesystem":"ufs","encryption":{"enabled":true,"swap":false},"swap_mb":2048,"wipe":{"vbd0":"quick"},"sector_4k":true,"trim":true}'
lvsec "$lv/pass" 'correct horse battery staple
'
lvsec "$lv/roothash" '$6$rootsalt$RootHashShapedOnly0123456789
'
lvsec "$lv/wifi" '{"if":"iwn0","ssid":"Example Net","security":"wpa2","psk":"wifi-secret-words"}'
lvgw6=2001:db8::1
lvaddr6=2001:db8::10
lvinst -p "$lv/plan-e" -E "$lv/pass" -u wtfuser -H "$lv/hash" -L fr_FR.UTF-8 -Z local -A -r "$lv/roothash" \
	-6 "vtnet0:$lvaddr6/64:$lvgw6" -6 em1:slaac -D 192.0.2.53 -D 2001:db8::53 -W "$lv/wifi" -U -y --progress
M="$lv/mnt"
if [ "$irc" -eq 0 ] && grep -q "^cryptsetup -q luksFormat -d .* $lv/dev/vbd0s1d\$" "$lv/inst.log" &&
	grep -q "^cryptsetup luksOpen -d .* $lv/dev/vbd0s1d root\$" "$lv/inst.log" &&
	grep -q "^newfs -U $lv/dev/mapper/root\$" "$lv/inst.log" && grep -q '^cryptsetup luksClose root$' "$lv/inst.log" &&
	grep -Eq '^  d:	\*	\*	4.2BSD$' "$lv/inst.log.label" && grep -Eq '^  b:	2048M	\*	swap$' "$lv/inst.log.label"; then
	ok "(LV10) an encrypted UFS plan: LUKS on the root partition, the file system on the mapper, closed at the end"
else
	no "(LV10) an encrypted UFS plan: LUKS on the root partition, the file system on the mapper, closed at the end (rc=$irc)"
	sed 's/^/      | /' "$lv/i.out" "$lv/i.err" | tail -8
fi
if grep -qx 'vfs.root.mountfrom="ufs:md0s0"' "$M/boot/loader.conf" 2>/dev/null &&
	lvlab=$(sed -n 's/^label: //p' "$lv/inst.log.label" | tail -n 1) &&
	grep -qx "vfs.root.realroot=\"crypt:ufs:part-by-label/$lvlab.d:root\"" "$M/boot/loader.conf" &&
	grep -qx 'initrd.img_load="YES"' "$M/boot/loader.conf" && grep -qx 'dm_target_crypt_load="yes"' "$M/boot/loader.conf" &&
	! grep -q '^swap' "$M/etc/crypttab" 2>/dev/null &&
	grep -Eq '^/dev/mapper/root[[:space:]]+/[[:space:]]+ufs' "$M/etc/fstab" && grep -Eq "^/dev/part-by-label/$lvlab.b[[:space:]]+none[[:space:]]+swap" "$M/etc/fstab"; then
	ok "(LV10) the encrypted root boots through the initrd (realroot crypt:ufs:part-by-label/...), the swap plain, by label (no swap encryption on DragonFly)"
else
	no "(LV10) the encrypted root boots through the initrd (realroot crypt:ufs), the swap plain (no swap encryption on DragonFly)"
	sed 's/^/      | /' "$M/boot/loader.conf" "$M/etc/fstab" "$M/etc/crypttab" 2>/dev/null
fi
if [ "$irc" -eq 0 ] && grep -q '^cryptsetup -q luksFormat' "$lv/inst.log" && ! grep -rqF 'horse battery' "$lv/i.out" "$lv/i.err" "$lv/inst.log" "$M" 2>/dev/null &&
	! ls -d "$lv"/examplebsd-install.key.* > /dev/null 2>&1; then
	ok "(LV10) the passphrase is in no output, no log and no file of the installed system, and its copy is removed"
else
	no "(LV10) the passphrase is in no output, no log and no file of the installed system, and its copy is removed"
fi
if grep -q ':lang=fr_FR.UTF-8:' "$M/etc/login.conf" 2>/dev/null && grep -q "^cap_mkdb $M/etc/login.conf\$" "$lv/inst.log" &&
	[ -f "$M/etc/wall_cmos_clock" ] &&
	grep -qx 'autologin-user=wtfuser' "$M/usr/local/etc/lightdm/lightdm.conf.d/80-autologin.conf" 2>/dev/null &&
	grep -qF 'ROOT_PASSWORD_HASH=$6$rootsalt$' "$M/boot/firstboot-user.conf"; then
	ok "(LV10) -L sets the locale of login.conf, -Z local the local clock, -A the login of the user, -r the root password"
else
	no "(LV10) -L sets the locale of login.conf, -Z local the local clock, -A the login of the user, -r the root password"
fi
if grep -qx 'ifconfig_vtnet0_ipv6="inet6 2001:db8::10 prefixlen 64"' "$M/etc/rc.conf" 2>/dev/null &&
	grep -qx 'ipv6_defaultrouter="2001:db8::1"' "$M/etc/rc.conf" && grep -qx 'ifconfig_em1_ipv6="inet6 accept_rtadv"' "$M/etc/rc.conf" &&
	grep -qx 'nameserver 192.0.2.53' "$M/etc/resolv.conf" && grep -qx 'nameserver 2001:db8::53' "$M/etc/resolv.conf"; then
	ok "(LV10) -6 writes the static and the SLAAC adapters, -D the resolvers"
else
	no "(LV10) -6 writes the static and the SLAAC adapters, -D the resolvers"
	sed 's/^/      | /' "$M/etc/rc.conf" "$M/etc/resolv.conf" 2>/dev/null
fi
lvwm=$(ls -ln "$M/etc/wpa_supplicant.conf" 2>/dev/null | awk '{ print $1 }')
lvssid=$(printf 'Example Net' | od -An -tx1 | tr -d ' \n')
if [ "$lvwm" = '-rw-------' ] && grep -q "ssid=$lvssid\$" "$M/etc/wpa_supplicant.conf" &&
	grep -Eq 'psk=[0-9a-f]{64}$' "$M/etc/wpa_supplicant.conf" && grep -q 'key_mgmt=WPA-PSK' "$M/etc/wpa_supplicant.conf" &&
	grep -qx 'wlans_iwn0="wlan0"' "$M/etc/rc.conf" && grep -qx 'ifconfig_wlan0="WPA DHCP"' "$M/etc/rc.conf" &&
	! grep -rqF 'wifi-secret-words' "$lv/i.out" "$lv/i.err" "$lv/inst.log" "$M" 2>/dev/null; then
	ok "(LV10) -W writes wpa_supplicant.conf (0600, the SSID and the PSK as hex) and never the passphrase itself"
else
	no "(LV10) -W writes wpa_supplicant.conf (0600, the SSID and the PSK as hex) and never the passphrase itself (mode $lvwm)"
	sed 's/^/      | /' "$M/etc/wpa_supplicant.conf" 2>/dev/null
fi
if grep -q "^pkg -c $M update -f\$" "$lv/inst.log" && grep -q "^pkg -c $M upgrade -y\$" "$lv/inst.log" &&
	grep -q "^mount -t devfs devfs $M/dev\$" "$lv/inst.log"; then
	ok "(LV10) -U updates the packages of the installed system"
else
	no "(LV10) -U updates the packages of the installed system"
fi
lvsec "$lv/plan-m" '{"version":1,"mode":"manual","disks":["vbd0"]}'
lvrefuse 'a plan in mode manual' 'mode erase only' -p "$lv/plan-m" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/plan-r" '{"version":1,"disks":["vbd0","vbd1"],"layout":"mirror"}'
lvrefuse 'a plan on two disks' 'exactly one disk' -p "$lv/plan-r" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/plan-k" '{"version":1,"disks":["vbd0"],"colour":"red"}'
lvrefuse 'a plan with an unknown key' 'unknown key' -p "$lv/plan-k" -u wtfuser -H "$lv/hash" -y --progress
chmod 644 "$lv/plan-a"
lvrefuse 'a plan file that others can read' 'mode 0600' -p "$lv/plan-a" -u wtfuser -H "$lv/hash" -y --progress
chmod 600 "$lv/plan-a"
lvrefuse 'an encrypted plan without -E' '-E PASSPHRASEFILE is required' -p "$lv/plan-e" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/short" 'short'
lvrefuse 'a passphrase shorter than 8 bytes' '8 to 1024 bytes' -p "$lv/plan-e" -E "$lv/short" -u wtfuser -H "$lv/hash" -y --progress
lvrefuse '-E with a plan that does not encrypt' 'does not encrypt' -p "$lv/plan-a" -E "$lv/pass" -u wtfuser -H "$lv/hash" -y --progress
lvrefuse '-p and -d together' 'exclude each other' -p "$lv/plan-a" -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
lvrefuse 'a hardware clock that is neither utc nor local' 'utc or local' -d vbd0 -Z gmt -u wtfuser -H "$lv/hash" -y --progress
lvrefuse 'an unknown locale' 'no such locale' -d vbd0 -L xx_XX.UTF-8 -u wtfuser -H "$lv/hash" -y --progress
lvbad6=2001:zz::1
lvrefuse 'an IPv6 address that is not one' 'not an IPv6 address' -d vbd0 -6 "vtnet0:$lvbad6/64:" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/wifi-bad" '{"if":"iwn0","ssid":"x","security":"wep","psk":"abcdefgh"}'
lvrefuse 'a Wi-Fi security that is not offered' 'wpa2, wpa3 or open' -d vbd0 -W "$lv/wifi-bad" -u wtfuser -H "$lv/hash" -y --progress

# (LV12) the licensed software: the catalogue of the media is valid (and
#        empty: nothing of the default set needs an acceptance); -l
#        installs exactly the accepted items, checked against the
#        catalogue, and records the acceptance on the installed system
if python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); sys.exit(0 if c.get("version") == 1 and c.get("items") == [] else 1)' \
	"$dov/usr/local/share/@SLUG@/licensed-software.json" 2>/dev/null; then
	ok "(LV12) the catalogue of licensed software is valid JSON, version 1, and the default set needs no acceptance"
else
	no "(LV12) the catalogue of licensed software is valid JSON, version 1, and the default set needs no acceptance"
fi
mkdir -p "$S/usr/local/share/examplebsd/licenses"
printf 'The Example Font licence: you accept it.\n' > "$S/usr/local/share/examplebsd/licenses/examplefont.txt"
cat > "$S/usr/local/share/examplebsd/licensed-software.json" <<'EOF'
{"version": 1, "items": [{"id": "examplefont", "name": "Example Font", "description": "a font", "size_mb": 1,
 "licence": {"id": "Example-EULA", "text": "/usr/local/share/examplebsd/licenses/examplefont.txt"},
 "flags": {"non_commercial": false, "vendor_key": false, "vendor_download": true, "needs_network": true},
 "install": {"method": "pkg", "packages": ["example-font"]}}]}
EOF
lvlsha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/usr/local/share/examplebsd/licenses/examplefont.txt")
lvsec "$lv/accept" "[{\"id\":\"examplefont\",\"licence\":\"Example-EULA\",\"sha256\":\"$lvlsha\",\"timestamp\":\"2026-11-01T00:00:00Z\"}]"
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -l "$lv/accept" -y --progress
if [ "$irc" -eq 0 ] && grep -q "^pkg -c $lv/mnt install -y example-font\$" "$lv/inst.log" &&
	cmp -s "$lv/accept" "$lv/mnt/var/db/examplebsd/licenses-accepted.json"; then
	ok "(LV12) -l installs the accepted item and records the acceptance in /var/db/<slug>/licenses-accepted.json"
else
	no "(LV12) -l installs the accepted item and records the acceptance in /var/db/<slug>/licenses-accepted.json (rc=$irc)"
	sed 's/^/      | /' "$lv/i.out" | tail -5
fi
lvinst -d vbd0 -u wtfuser -H "$lv/hash" -y --progress
if [ "$irc" -eq 0 ] && grep -q '^PROGRESS 100 ' "$lv/i.out" && ! grep -q "^pkg -c .* install" "$lv/inst.log" && [ ! -e "$lv/mnt/var/db/examplebsd/licenses-accepted.json" ]; then
	ok "(LV12) without -l no licensed software is installed and no acceptance is recorded"
else
	no "(LV12) without -l no licensed software is installed and no acceptance is recorded (rc=$irc)"
fi
lvsec "$lv/accept-x" '[{"id":"otherthing","licence":"Example-EULA","sha256":"00","timestamp":"t"}]'
lvrefuse 'an accepted id that is not in the catalogue' 'not in the catalogue' -d vbd0 -l "$lv/accept-x" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/accept-s" '[{"id":"examplefont","licence":"Example-EULA","sha256":"0000","timestamp":"t"}]'
lvrefuse 'an acceptance of another licence text' 'not the one on the media' -d vbd0 -l "$lv/accept-s" -u wtfuser -H "$lv/hash" -y --progress
rm -rf "$S/usr/local/share/examplebsd/licenses" "$S/usr/local/share/examplebsd/licensed-software.json"

# (LV15) the plans the installer of installer-template sends (lib/diskplan.py
#        and lib/gui_disk.py at the pinned INSTALLER_REF): usage together,
#        usage separate with a data volume on its own disk, a data volume
#        of the erase plan; and --capabilities says what is offered
for d in vbd2 vbd2s0 vbd2s0a; do : > "$lv/dev/$d"; done
printf '%s 21\n%s 22\n%s 23\n' "$lv/dev/vbd2" "$lv/dev/vbd2s0" "$lv/dev/vbd2s0a" >> "$lv/rdev"
lvsec "$lv/plan-t" '{"version":1,"mode":"erase","boot":"uefi","filesystem":"hammer2","encryption":{"enabled":false,"swap":false},"swap_mb":2048,"sector_4k":true,"trim":true,"wipe":{"vbd0":"quick"},"confirm_foreign":[],"disks":["vbd0"],"layout":"single","usage":"together"}'
LV_DISKS="vbd1 vbd0 vbd2" lvinst -p "$lv/plan-t" -u wtfuser -H "$lv/hash" -y --progress
r1=$irc
lvsec "$lv/plan-s" '{"version":1,"mode":"erase","boot":"uefi","filesystem":"ufs","encryption":{"enabled":false,"swap":false},"swap_mb":1024,"sector_4k":false,"trim":false,"wipe":{"vbd0":"quick","vbd2":"secure"},"confirm_foreign":["vbd2"],"usage":"separate","disks":["vbd0"],"layout":"single","data":[{"name":"media","disks":["vbd2"],"layout":"single","filesystem":"ufs","mount":"/srv/media"}]}'
LV_DISKS="vbd1 vbd0 vbd2" lvinst -p "$lv/plan-s" -u wtfuser -H "$lv/hash" -y --progress
r2=$irc
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && grep -q '^gpt add -i 0 -t dragonfly vbd2$' "$lv/inst.log" &&
	grep -q "^dd if=/dev/zero of=$lv/dev/vbd2 bs=1m\$" "$lv/inst.log" && grep -q "^newfs -U $lv/dev/vbd2s0a\$" "$lv/inst.log" &&
	grep -Eq '^/dev/part-by-label/examplebsd-media-[0-9a-f]{8}\.a	/srv/media	ufs	rw	2	2$' "$lv/mnt/etc/fstab" &&
	[ -d "$lv/mnt/srv/media" ]; then
	ok "(LV15) the plans of the installer: usage together, and usage separate with a data volume (its own disk, label, fstab line and mount point)"
else
	no "(LV15) the plans of the installer: usage together, and usage separate with a data volume (its own disk, label, fstab line and mount point) ($r1/$r2)"
	tail -n 3 "$lv/i.out" | sed 's/^/      | /'; grep -n 'media' "$lv/mnt/etc/fstab" 2>/dev/null | sed 's/^/      | /'
fi
lvsec "$lv/plan-x" '{"version":1,"mode":"erase","boot":"uefi","filesystem":"hammer2","encryption":{"enabled":false,"swap":false},"swap_mb":0,"wipe":{},"confirm_foreign":[],"disks":["vbd0"],"layout":"single","data":[{"name":"data","disks":["vbd0"],"layout":"single","filesystem":"hammer2","mount":"/data"}]}'
lvrefuse 'a data volume on the system disk' 'appears twice' -p "$lv/plan-x" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/plan-b" '{"version":1,"mode":"erase","boot":"bios","disks":["vbd0"],"layout":"single"}'
lvrefuse 'a BIOS plan' 'UEFI boot only' -p "$lv/plan-b" -u wtfuser -H "$lv/hash" -y --progress
lvsec "$lv/plan-a" '{"version":1,"mode":"alongside","disks":[],"alongside":{"disk":"vbd0","region":{"start_mb":100,"size_mb":20000}}}'
lvrefuse 'an alongside plan' 'mode erase only' -p "$lv/plan-a" -u wtfuser -H "$lv/hash" -y --progress
caps=$(sh "$lv/examplebsd-install" --capabilities 2>/dev/null)
if printf '%s' "$caps" | python3 -c 'import json, sys; c = json.load(sys.stdin); sys.exit(0 if c["modes"] == ["erase"] and c["boot"] == ["uefi"] and [l["ident"] for l in c["layouts"]] == ["single"] and ["hammer2", "HAMMER2"] in c["filesystems"] else 1)'; then
	ok "(LV15) --capabilities prints what the command installs (erase, UEFI, single, HAMMER2/UFS) as JSON for the installer"
else
	no "(LV15) --capabilities prints what the command installs (erase, UEFI, single, HAMMER2/UFS) as JSON for the installer"
fi

# (LV15) the real checker of installer-template at the pinned INSTALLER_REF
#        (lib/diskplan.py --check-capabilities, the one its adapter runs on
#        the installed command) takes what --capabilities prints and gives
#        back a usable object with boot ["uefi"]. The checkout comes from
#        WTFBSD_TEST_INSTALLER_TEMPLATE, or is cloned at the pin.
lv15ref=$(sed -n 's/^INSTALLER_REF_DEFAULT=\([0-9a-f]*\)$/\1/p' "$build")
lv15it=''
if [ -n "${WTFBSD_TEST_INSTALLER_TEMPLATE:-}" ] && [ -f "$WTFBSD_TEST_INSTALLER_TEMPLATE/lib/diskplan.py" ]; then
	lv15it=$WTFBSD_TEST_INSTALLER_TEMPLATE
elif command -v git > /dev/null 2>&1 &&
	timeout 120 git clone --quiet --no-checkout https://github.com/wtfbsd/installer-template.git "$work/lv15it" > /dev/null 2>&1 &&
	git -C "$work/lv15it" -c advice.detachedHead=false checkout --quiet "$lv15ref" > /dev/null 2>&1; then
	lv15it="$work/lv15it"
fi
if [ -z "$lv15it" ]; then
	skip "(LV15) the real installer-template checker accepts --capabilities (no checkout: set WTFBSD_TEST_INSTALLER_TEMPLATE or allow the clone)"
else
	lv15caps=$(sh "$lv/examplebsd-install" --capabilities 2>/dev/null | python3 -I "$lv15it/lib/diskplan.py" --check-capabilities)
	lv15rc=$?
	if [ "$lv15rc" -eq 0 ] && printf '%s' "$lv15caps" | python3 -c '
import json, sys
c = json.load(sys.stdin)
want = {"modes", "boot", "layouts", "filesystems", "data_pools", "usages", "encryption", "swap_encryption", "not_offered"}
sys.exit(0 if set(c) == want and c["boot"] == ["uefi"] and c["modes"] == ["erase"] and c["layouts"][0]["ident"] == "single" and c["usages"] == ["together", "separate"] and c["swap_encryption"] is False else 1)'; then
		ok "(LV15) lib/diskplan.py --check-capabilities of installer-template ($(printf '%.7s' "$lv15ref")) takes the output of --capabilities whole: boot [uefi], erase, single, usages together/separate, no swap encryption, no key left out"
	else
		no "(LV15) lib/diskplan.py --check-capabilities of installer-template ($(printf '%.7s' "$lv15ref")) takes the output of --capabilities whole: boot [uefi], erase, single, usages together/separate, no swap encryption, no key left out (rc=$lv15rc)"
		printf '      | %s\n' "$lv15caps"
	fi
fi

# (LV12) the top level of every catalogue of licensed software the overlay
#        ships is one the installer reads: lib/licensed.py load() of
#        installer-template refuses a top-level key other than version, items and notices, a
#        version other than 1, items that are not a list and notices that
#        are not the path of a file next to the catalogue. The rule is
#        mirrored for every catalogue (the items are not); the real load()
#        of the checkout of LV15 reads them whole when there is one.
lvcats=$(find "$repo/overlay" -name licensed-software.json | sort)
lvcatbad=$(printf '%s\n' "$lvcats" | python3 -I -c 'import json, os, re, sys
bad = []
for p in sys.stdin.read().split("\n"):
    if not p:
        continue
    try:
        c = json.load(open(p, encoding="utf-8"))
    except ValueError as e:
        bad.append("%s: not JSON (%s)" % (p, e)); continue
    if not isinstance(c, dict):
        bad.append("%s: not an object" % p); continue
    extra = sorted(set(c) - {"version", "items", "notices"})
    if extra:
        bad.append("%s: top-level keys %s" % (p, ", ".join(extra)))
    if c.get("version") != 1 or isinstance(c.get("version"), bool):
        bad.append("%s: version is not 1" % p)
    if not isinstance(c.get("items"), list):
        bad.append("%s: items is not a list" % p)
    n = c.get("notices")
    # an empty or false notices is no notices, as load() reads it
    if n and not (isinstance(n, str) and re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*", n)
                  and ".." not in n.split("/") and "." not in n.split("/")
                  and os.path.isfile(os.path.join(os.path.dirname(p), n))):
        bad.append("%s: notices is not the path of a file next to the catalogue" % p)
print("; ".join(bad))
sys.exit(1 if bad else 0)' 2>&1)
lvcatrc=$?
if [ -n "$lvcats" ] && [ "$lvcatrc" -eq 0 ]; then
	ok "(LV12) every licensed-software.json of the overlay has only version 1, items (a list) and notices (a file next to it), as the installer reads it"
else
	no "(LV12) every licensed-software.json of the overlay has only version 1, items (a list) and notices (a file next to it), as the installer reads it ($lvcatbad)"
fi
if [ -z "$lv15it" ] || [ ! -f "$lv15it/lib/licensed.py" ]; then
	skip "(LV12) lib/licensed.py load() of installer-template reads every catalogue of the overlay (no checkout: set WTFBSD_TEST_INSTALLER_TEMPLATE or allow the clone)"
else
	lvcatload=$(printf '%s\n' "$lvcats" | python3 -I -c 'import sys
sys.path.insert(0, sys.argv[1])
import licensed
bad = []
for p in sys.stdin.read().split("\n"):
    if p:
        try:
            licensed.load(p)
        except licensed.CatalogueError as e:
            bad.append("%s: %s" % (p, e))
print("; ".join(bad))
sys.exit(1 if bad else 0)' "$lv15it/lib" 2>&1)
	if [ $? -eq 0 ]; then
		ok "(LV12) lib/licensed.py load() of installer-template ($(printf '%.7s' "$lv15ref")) reads every catalogue of the overlay"
	else
		no "(LV12) lib/licensed.py load() of installer-template ($(printf '%.7s' "$lv15ref")) reads every catalogue of the overlay ($lvcatload)"
	fi
fi

# (LV8) the first boot applies the host name, the time zone and the keymap
#       of the installer; a bad value stops it before the system changes
F="$lv/fbt"
rm -rf "$F"; mkdir -p "$F/etc/rc.d" "$F/boot" "$F/home" "$F/var/db" "$F/usr/share/zoneinfo/Europe" "$F/usr/share/syscons/keymaps" "$F/usr/local/etc" "$F/fakebin"
printf 'TZDATA\n' > "$F/usr/share/zoneinfo/Europe/Berlin"; : > "$F/usr/share/syscons/keymaps/de.iso.kbd"
printf 'root:*:0:0::0:0:Charlie &:/root:/bin/sh\n' > "$F/etc/master.passwd"
printf 'wtfuser:*:1001:1001:W:%s/home/wtfuser:/bin/sh\n' "$F" > "$F/etc/passwd"
printf 'hostname="examplebsd"\nlightdm_enable="YES"\n' > "$F/etc/rc.conf"
for t in pw logger chown hostname kbdcontrol; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "%s/cmd.log"\ncase "$1" in usershow) exit 1 ;; esac\nexit 0\n' "$t" "$F" > "$F/fakebin/$t"
done
chmod 755 "$F/fakebin/"*
sed -e "s#/etc/rc\\.subr#$lv/rcsubr/rc.subr#g" -e "s#/usr/local/#@F@/usr/local/#g" -e "s#\\([^l]\\)/etc/#\\1@F@/etc/#g" \
	-e "s#/boot/#@F@/boot/#g" -e "s#/usr/share/#@F@/usr/share/#g" -e "s#/var/db/#@F@/var/db/#g" -e "s#/home#@F@/home#g" -e "s#/firstboot\\([^_a-z-]\\)#$F/firstboot\\1#g" -e 's/@SLUG@/examplebsd/g' \
	"$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" | sed "s#@F@#$F#g" > "$F/etc/rc.d/firstboot_user"
umask 077
printf 'USERNAME=wtfuser\nPASSWORD_HASH=%s\nHOSTNAME=box.example.org\nTIMEZONE=Europe/Berlin\nKEYMAP=de.iso\nDOAS_NOPASS=yes\n' '$6$s$h' > "$F/boot/firstboot-user.conf"
printf 'permit persist :wheel\n' > "$F/usr/local/etc/doas.conf"
umask 022
PATH="$F/fakebin:$PATH" sh "$F/etc/rc.d/firstboot_user" start > "$F/out.log" 2>&1
frc=$?
if [ "$frc" -eq 0 ] && grep -q '^hostname="box.example.org"$' "$F/etc/rc.conf" && [ "$(grep -c '^hostname=' "$F/etc/rc.conf")" -eq 1 ] &&
	grep -q '^keymap="de.iso"$' "$F/etc/rc.conf" && grep -q '^lightdm_enable="YES"$' "$F/etc/rc.conf" &&
	[ "$(cat "$F/etc/localtime" 2>/dev/null)" = TZDATA ] && [ "$(cat "$F/var/db/zoneinfo" 2>/dev/null)" = Europe/Berlin ] &&
	grep -q '^hostname box.example.org$' "$F/cmd.log" && [ -f "$F/boot/firstboot-user.conf.done" ] &&
	grep -qx 'permit nopass wtfuser' "$F/usr/local/etc/doas.conf"; then
	ok "(LV8) the first boot sets the host name, the time zone, the keymap and doas without password (-P)"
else
	no "(LV8) the first boot sets the host name, the time zone, the keymap and doas without password (-P) (rc=$frc)"
	sed 's/^/      | /' "$F/out.log" "$F/etc/rc.conf" "$F/cmd.log" 2>/dev/null
fi
# /etc/localtime as a link into zoneinfo (as some installs leave it): the time
# zone replaces the link and never writes through it into the zoneinfo file
rm -f "$F/boot/firstboot-user.conf.done" "$F/etc/localtime"
mkdir -p "$F/usr/share/zoneinfo"
printf 'UTCDATA\n' > "$F/usr/share/zoneinfo/UTC"
ln -s "$F/usr/share/zoneinfo/UTC" "$F/etc/localtime"
umask 077
printf 'USERNAME=wtfuser\nPASSWORD_HASH=%s\nTIMEZONE=Europe/Berlin\n' '$6$s$h' > "$F/boot/firstboot-user.conf"
umask 022
PATH="$F/fakebin:$PATH" sh "$F/etc/rc.d/firstboot_user" start > "$F/out-tz.log" 2>&1
if [ "$(cat "$F/usr/share/zoneinfo/UTC")" = UTCDATA ] && [ ! -L "$F/etc/localtime" ] &&
	[ "$(cat "$F/etc/localtime" 2>/dev/null)" = TZDATA ]; then
	ok "(LV8) a linked /etc/localtime is replaced, the zoneinfo file it pointed at is untouched"
else
	no "(LV8) a linked /etc/localtime is replaced, the zoneinfo file it pointed at is untouched"
	sed 's/^/      | /' "$F/out-tz.log" | tail -4
fi
rm -f "$F/boot/firstboot-user.conf.done" "$F/etc/localtime"
printf 'hostname="examplebsd"\n' > "$F/etc/rc.conf"
umask 077
printf 'USERNAME=wtfuser\nPASSWORD_HASH=%s\nTIMEZONE=../../etc/passwd\n' '$6$s$h' > "$F/boot/firstboot-user.conf"
umask 022
: > "$F/cmd.log"
PATH="$F/fakebin:$PATH" sh "$F/etc/rc.d/firstboot_user" start > "$F/out.log" 2>&1
frc=$?
if [ "$frc" -ne 0 ] && grep -q 'TIMEZONE is not a time zone' "$F/out.log" && [ ! -e "$F/etc/localtime" ] && ! grep -q useradd "$F/cmd.log" && [ -f "$F/boot/firstboot-user.conf" ]; then
	ok "(LV8) a TIMEZONE that is not a zoneinfo name stops the first boot before anything changes"
else
	no "(LV8) a TIMEZONE that is not a zoneinfo name stops the first boot before anything changes (rc=$frc)"
fi

# (LV11) every image the README shows is in the tree (docs/screenshots),
#        a PNG, and small enough for a README (300 KB at most)
lvimgs=$(grep -o '!\[[^]]*\]([^)]*)' "$repo/README.md" | sed 's/.*](\(.*\))$/\1/')
lvbad=''
lvn=0
for i in $lvimgs; do
	lvn=$((lvn + 1))
	case $i in
	http://* | https://* | /* | *..*) lvbad="$lvbad $i(not-a-tree-path)"; continue ;;
	esac
	f="$repo/$i"
	if [ ! -f "$f" ]; then
		lvbad="$lvbad $i(missing)"
	elif [ "$(od -An -tx1 -N8 "$f" | tr -d ' \n')" != 89504e470d0a1a0a ]; then
		lvbad="$lvbad $i(not-png)"
	elif [ "$(wc -c < "$f")" -gt 307200 ]; then
		lvbad="$lvbad $i(over-300KB)"
	fi
done
if [ "$lvn" -ge 7 ] && [ -z "$lvbad" ] && grep -q '^## What it looks like$' "$repo/README.md"; then
	ok "(LV11) the README shows $lvn screenshots under What it looks like, and every image link resolves to a PNG of the tree"
else
	no "(LV11) the README shows at least 7 screenshots under What it looks like, and every image link resolves to a PNG of the tree ($lvn:$lvbad)"
fi

# (LV14) the branding of the desktop from the pinned artwork template (a
#        pre-rendered pack): every spot its branding/spots.tsv marks
#        supported on DragonFly is installed, the identity file matches
#        product.conf and names the base from the built kernel, the identity
#        line is stamped on the greeter and the wallpapers, the loader menu
#        names the product, and the variant, the version, the pack's
#        checksum and commit are honoured
REAL_PROFILE=desktop realbuild "$work/lv14" -u ciuser -P "$work/pass.hash"
b="$realout/desktop/root"
pname=$(sed -n "s/^DISTRO_NAME='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$fixture")
lv14sup=$(awk -F '\t' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
	/^#/ { next } $c["dragonfly"] !~ /^(n\/a|check:|-$)/ { print $c["spot"] }' "$repo/tests/fixtures/fake-artwork/branding/spots.tsv" | sort)
lv14ins=$(cut -f1 "$realout/desktop/branding/installed-spots" 2>/dev/null | sort)
if [ "$realrc" -eq 0 ] && [ -n "$lv14sup" ] && [ "$lv14sup" = "$lv14ins" ]; then
	ok "(LV14) every spot branding/spots.tsv marks supported on DragonFly is installed ($(printf '%s\n' "$lv14sup" | grep -c .))"
else
	no "(LV14) every spot branding/spots.tsv marks supported on DragonFly is installed (rc=$realrc)"
	tail -n 4 "$work/lv14/build.log" | sed 's/^/      | /'
fi
lv14miss=''
for f in /usr/local/share/examplebsd/lightdm/greeter-1920x1080.png /usr/local/etc/lightdm/lightdm-gtk-greeter.conf \
	/usr/local/share/themes/examplebsd-greeter/gtk-3.0/gtk.css /usr/local/share/examplebsd/wallpapers/wallpaper-1-1920x1080.png \
	/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml /usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
	/usr/local/share/icons/hicolor/48x48/apps/examplebsd-logo.png /usr/local/share/icons/hicolor/scalable/apps/examplebsd-installer.svg \
	/usr/local/share/examplebsd/installer/header.png /usr/local/share/examplebsd/dm/pixmaps/examplebsd-color.xpm \
	/usr/local/etc/X11/xdm/Xresources /boot/dloader.menu /etc/issue /etc.hdd/issue; do
	[ -s "$b$f" ] || lv14miss="$lv14miss $f"
done
if [ "$realrc" -eq 0 ] && [ -z "$lv14miss" ]; then
	ok "(LV14) the greeter, its theme, the wallpapers, the Xfce defaults, the icons, the loader menu and the login banner are in their DragonFly places"
else
	no "(LV14) the greeter, its theme, the wallpapers, the Xfce defaults, the icons, the loader menu and the login banner are in their DragonFly places:$lv14miss"
fi
# the wallpaper on every output: the pack's autostart entry goes to
# /etc/xdg/autostart (the live media and the installed system), its session
# helper root-owned 0755 to the path the entry's Exec= names
lvas=etc/xdg/autostart/examplebsd-wallpaper.desktop
lvss=/usr/local/share/examplebsd/xfce/session/examplebsd-wallpaper.sh
if [ "$realrc" -eq 0 ] && grep -qx 'Exec=/bin/sh "/usr/local/share/examplebsd/xfce/session/examplebsd-wallpaper.sh"' "$b/$lvas" 2>/dev/null &&
	cmp -s "$b/$lvas" "$b/etc.hdd/xdg/autostart/examplebsd-wallpaper.desktop" &&
	[ "$(ls -l "$b/$lvas" | cut -c1-10)" = '-rw-r--r--' ] &&
	grep -q 'the wallpaper of ExampleBSD on every output' "$b$lvss" 2>/dev/null &&
	[ "$(ls -l "$b$lvss" | cut -c1-10)" = '-rwxr-xr-x' ] &&
	grep -qxF "CMD chown root:wheel $b$lvss" "$work/lv14/stub.log" &&
	grep -qxF "CMD chown root:wheel $b/$lvas" "$work/lv14/stub.log"; then
	ok "(LV14) the wallpaper autostart entry is in /etc/xdg/autostart (live and installed) and its session helper root-owned 0755 where Exec= names it"
else
	no "(LV14) the wallpaper autostart entry is in /etc/xdg/autostart (live and installed) and its session helper root-owned 0755 where Exec= names it (rc=$realrc)"
	ls -l "$b/$lvas" "$b$lvss" 2>&1 | sed 's/^/      | /'
fi
rm -rf "$lv/art7"; cp -R "$repo/tests/fixtures/fake-artwork" "$lv/art7"
lvx=out/desktop/root
FAKE_ART_SESSION_EXEC=/etc/rc.conf.d/evil REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x1" -u ciuser -P "$work/pass.hash"; r14x1=$realrc
FAKE_ART_SESSION_NAME=packbsd REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x2" -u ciuser -P "$work/pass.hash"; r14x2=$realrc
if [ "$r14x1" -eq 0 ] && grep -qx 'Exec=/bin/sh "/usr/local/share/examplebsd/xfce/session/examplebsd-wallpaper.sh"' "$work/lv14x1/$lvx/$lvas" &&
	! grep -q 'evil' "$work/lv14x1/$lvx/$lvas" && [ ! -e "$work/lv14x1/$lvx/etc/rc.conf.d/evil" ] &&
	[ "$r14x2" -eq 0 ] && [ -x "$work/lv14x2/$lvx$lvss" ] &&
	grep -qx 'Exec=/bin/sh "/usr/local/share/examplebsd/xfce/session/examplebsd-wallpaper.sh"' "$work/lv14x2/$lvx/$lvas" &&
	[ -z "$(find "$work/lv14x2/$lvx" -name 'packbsd*')" ]; then
	ok "(LV14) the wallpaper helper and entry go to the product's fixed paths, Exec= written by the build (an artwork Exec= elsewhere, or files named for another slug, change nothing)"
else
	no "(LV14) the wallpaper helper and entry go to the product's fixed paths, Exec= written by the build (an artwork Exec= elsewhere, or files named for another slug, change nothing) ($r14x1/$r14x2)"
	tail -n 2 "$work/lv14x1/build.log" "$work/lv14x2/build.log" | sed 's/^/      | /'
fi
FAKE_ART_SESSION=desktop-only REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x3" -u ciuser -P "$work/pass.hash"; r14x3=$realrc
FAKE_ART_SESSION=link REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x5" -u ciuser -P "$work/pass.hash"; r14x5=$realrc
FAKE_ART_SESSION_NAME='Bad.Name' REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x6" -u ciuser -P "$work/pass.hash"; r14x6=$realrc
FAKE_ART_SESSION=none REAL_NO_PACK=1 ARTWORK_DIR="$lv/art7" REAL_PROFILE=desktop realbuild "$work/lv14x4" -u ciuser -P "$work/pass.hash"; r14x4=$realrc
if [ "$r14x3" -ne 0 ] && grep -q 'the artwork has no xfce/session/examplebsd-wallpaper.sh' "$work/lv14x3/build.log" &&
	[ "$r14x5" -ne 0 ] && grep -q 'xfce/session/examplebsd-wallpaper.sh is a symbolic link' "$work/lv14x5/build.log" &&
	[ ! -e "$work/lv14x5/$lvx$lvss" ] &&
	[ "$r14x6" -ne 0 ] && grep -q 'is not named <slug>-wallpaper.desktop' "$work/lv14x6/build.log" &&
	[ "$r14x4" -eq 0 ] && [ ! -e "$work/lv14x4/$lvx/$lvas" ]; then
	ok "(LV14) a wallpaper entry without its helper, a linked helper, or a name that is not a slug stops the build; an artwork without the pair installs none"
else
	no "(LV14) a wallpaper entry without its helper, a linked helper, or a name that is not a slug stops the build; an artwork without the pair installs none ($r14x3/$r14x5/$r14x6/$r14x4)"
	tail -n 2 "$work/lv14x3/build.log" "$work/lv14x5/build.log" "$work/lv14x6/build.log" | sed 's/^/      | /'
fi
idf="$b/usr/local/share/examplebsd/identity"
if grep -qx "PRODUCT=$pname" "$idf" 2>/dev/null && grep -qx 'VERSION=2026.11' "$idf" &&
	grep -qx 'BASE=DragonFly 6.4.2' "$idf" && grep -qx 'VARIANT=Default' "$idf" && grep -qx 'ARCH=amd64' "$idf" &&
	grep -qx 'BUILD=' "$idf"; then
	ok "(LV14) /usr/local/share/<slug>/identity matches product.conf (PRODUCT_VERSION unset: year.month) and names the base from the kernel (DragonFly 6.4.2)"
else
	no "(LV14) /usr/local/share/<slug>/identity matches product.conf (PRODUCT_VERSION unset: year.month) and names the base from the kernel (DragonFly 6.4.2)"
	sed 's/^/      | /' "$idf" 2>/dev/null
fi
lvline="STAMP $pname 2026.11 / DragonFly 6.4.2 / Default / amd64"
if grep -qx "$lvline" "$b/usr/local/share/examplebsd/lightdm/greeter-1920x1080.png" 2>/dev/null &&
	grep -qx "$lvline" "$b/usr/local/share/examplebsd/wallpapers/wallpaper-1-1920x1080.png" &&
	grep -qx "$lvline" "$b/usr/local/share/examplebsd/wallpapers/wallpaper-1-3840x2160.png"; then
	ok "(LV14) the identity line is stamped on the greeter background and on every wallpaper"
else
	no "(LV14) the identity line is stamped on the greeter background and on every wallpaper"
fi
if grep -qx 'menuitem 1 "Boot ExampleBSD \[${default_kernel}\]"' "$b/boot/dloader.menu" 2>/dev/null &&
	grep -qx 'menuadd boot -s' "$b/boot/dloader.menu" && grep -qx 'menuitem R "Reboot"' "$b/boot/dloader.menu" &&
	! grep -q 'Boot DragonFly' "$b/boot/dloader.menu" && grep -qx 'fred_disable="YES"' "$b/boot/loader.conf"; then
	ok "(LV14) the DragonFly loader menu names the product (its menuadd lines kept) and its ASCII art is off"
else
	no "(LV14) the DragonFly loader menu names the product (its menuadd lines kept) and its ASCII art is off"
	sed 's/^/      | /' "$b/boot/dloader.menu" 2>/dev/null
fi
if grep -q ':im=\\r\\nExampleBSD (%h) (%t)\\r\\n\\r\\n:sp#1200:' "$b/etc/gettytab" 2>/dev/null &&
	grep -q ':im=\\r\\nExampleBSD (%h)' "$b/etc.hdd/gettytab" && grep -q 'ExampleBSD - variant default' "$b/etc.hdd/motd"; then
	ok "(LV14) the login banner (gettytab im=) and the motd name the product, on the live media and the installed system"
else
	no "(LV14) the login banner (gettytab im=) and the motd name the product, on the live media and the installed system"
	grep -n 'im=' "$b/etc/gettytab" 2>/dev/null | sed 's/^/      | /'
fi
# the cyberpunk variant and a test version
grep -v '^PRODUCT_VERSION=\|^ARTWORK_VARIANT=' "$fixture" > "$work/lv14-cyber.conf"
printf "ARTWORK_VARIANT='cyberpunk'\nPRODUCT_VERSION='1.2-rc1'\n" >> "$work/lv14-cyber.conf"
ARTWORK_PACK=$(mkpack cyberpunk "$work/packs") REAL_CONF="$work/lv14-cyber.conf" REAL_PROFILE=desktop realbuild "$work/lv14c" -u ciuser -P "$work/pass.hash"
c="$realout/desktop/root/usr/local/share/examplebsd"
if [ "$realrc" -eq 0 ] && grep -qx 'VARIANT=Cyberpunk' "$c/identity" 2>/dev/null && grep -qx 'BUILD=2026-11-01' "$c/identity" &&
	grep -q '^variant=cyberpunk ' "$c/lightdm/greeter-1920x1080.png" &&
	grep -qx "STAMP $pname 1.2-rc1 / DragonFly 6.4.2 / Cyberpunk / amd64 / build 2026-11-01" "$c/lightdm/greeter-1920x1080.png"; then
	ok "(LV14) ARTWORK_VARIANT=cyberpunk installs the cyberpunk pack, and a test PRODUCT_VERSION (1.2-rc1) adds the build date"
else
	no "(LV14) ARTWORK_VARIANT=cyberpunk installs the cyberpunk pack, and a test PRODUCT_VERSION (1.2-rc1) adds the build date (rc=$realrc)"
	tail -n 3 "$work/lv14c/build.log" | sed 's/^/      | /'
fi
REAL_CONF="$work/lv14-cyber.conf" REAL_PROFILE=desktop realbuild "$work/lv14v" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -ne 0 ] && grep -q 'holds the variant default, not cyberpunk' "$work/lv14v/build.log"; then
	ok "(LV14) a pack of another variant than ARTWORK_VARIANT stops the build"
else
	no "(LV14) a pack of another variant than ARTWORK_VARIANT stops the build (rc=$realrc)"
fi
# the checksum, the commit and the product of the pack
p2=$(mkpack default "$work/packs2"); printf 'x' >> "$p2"
ARTWORK_PACK=$p2 sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/a3" > "$lv/a3.log" 2>&1; r3=$?
p3=$(mkpack default "$work/packs3")
ARTWORK_PACK=$p3 ARTWORK_REF=0123456789abcdef0 REAL_PROFILE=desktop realbuild "$work/lv14r" -u ciuser -P "$work/pass.hash"; r4=$realrc
p4=$(mkpack default "$work/packs4" otherbsd)
ARTWORK_PACK=$p4 REAL_PROFILE=desktop realbuild "$work/lv14o" -u ciuser -P "$work/pass.hash"; r5=$realrc
if [ "$r3" -ne 0 ] && grep -q 'does not match its checksum' "$lv/a3.log" &&
	[ "$r4" -ne 0 ] && grep -q 'not from ARTWORK_REF 0123456789abcdef0' "$work/lv14r/build.log" &&
	[ "$r5" -ne 0 ] && grep -q 'was made for otherbsd, not for examplebsd' "$work/lv14o/build.log"; then
	ok "(LV14) a pack with a wrong checksum, from another commit than ARTWORK_REF, or for another product stops the build"
else
	no "(LV14) a pack with a wrong checksum, from another commit than ARTWORK_REF, or for another product stops the build ($r3/$r4/$r5)"
fi
# the pinned defaults: the merged main of installer-template and of the
# artwork template, cloned when nothing local is given
env -u INSTALLER_DIR -u ARTWORK_PACK -u ARTWORK_PACKS_SHA256 sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/a4" > "$lv/a4.log" 2>&1
if grep -q 'checkout --quiet 907e707a606edc2023d437fc41c46a674f8143f5$' "$lv/a4.log" &&
	grep -q 'fetch -q -o .*/examplebsd-5aaea01b0829-default.tar.xz https://github.com/wtfbsd/artwork-template/releases/download/pack-5aaea01b0829/examplebsd-5aaea01b0829-default.tar.xz$' "$lv/a4.log" &&
	grep -q 'sha256 f0753807e81daacc3dc7b24995d49e74b1fd61152035115b37888fe814176a12' "$lv/a4.log"; then
	ok "(LV14) INSTALLER_REF and ARTWORK_REF default to the pinned main commits; the published pack of the variant is fetched and its checksum is pinned"
else
	no "(LV14) INSTALLER_REF and ARTWORK_REF default to the pinned main commits; the published pack of the variant is fetched and its checksum is pinned"
	grep -n 'checkout\|fetch\|artwork' "$lv/a4.log" | sed 's/^/      | /'
fi
# (LV17) the product.conf keys of the live media (wtfbsd/agents #5,
#        questions.yaml): INSTALLER_REF, INSTALLER_URL, PRODUCT_VERSION,
#        ARTWORK_VARIANT, ARTWORK_REF, ARTWORK_SHA256. Set, they are used;
#        empty, the template's pins and defaults stay.
lv17s=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
{ cat "$fixture"; printf '%s\n' 'INSTALLER_REF=v1.0' 'INSTALLER_URL=https://example.org/fork/installer-template.git' \
	'PRODUCT_VERSION=1.2+rc1' 'ARTWORK_VARIANT=cyberpunk' 'ARTWORK_REF=0123456789abcdef0123456789abcdef01234567' \
	"ARTWORK_SHA256=$lv17s"; } > "$lv/all6.conf"
{ cat "$fixture"; printf '%s\n' 'INSTALLER_REF=' 'INSTALLER_URL=' 'PRODUCT_VERSION=' 'ARTWORK_VARIANT=' 'ARTWORK_REF=' 'ARTWORK_SHA256='; } > "$lv/empty6.conf"
env -u INSTALLER_DIR -u ARTWORK_PACK -u ARTWORK_PACKS_SHA256 -u INSTALLER_REF -u INSTALLER_REPO -u ARTWORK_REF \
	sh "$build" -n -c "$lv/all6.conf" -p desktop --no-user -o "$lv/a17" > "$lv/a17.log" 2>&1
r17a=$?
env -u INSTALLER_DIR -u ARTWORK_PACK -u ARTWORK_PACKS_SHA256 -u INSTALLER_REF -u INSTALLER_REPO -u ARTWORK_REF \
	sh "$build" -n -c "$lv/empty6.conf" -p desktop --no-user -o "$lv/e17" > "$lv/e17.log" 2>&1
r17e=$?
if [ "$r17a" -eq 0 ] &&
	grep -q 'git clone --quiet --no-checkout https://example.org/fork/installer-template.git ' "$lv/a17.log" &&
	grep -q 'checkout --quiet v1.0$' "$lv/a17.log" &&
	grep -q "artwork  the published pack https://github.com/wtfbsd/artwork-template/releases/download/pack-0123456789ab/examplebsd-0123456789ab-cyberpunk.tar.xz (sha256 $lv17s), variant cyberpunk, version 1.2+rc1\$" "$lv/a17.log"; then
	ok "(LV17) a product.conf with all six keys of the live media (INSTALLER_REF tag, INSTALLER_URL, PRODUCT_VERSION, ARTWORK_VARIANT, ARTWORK_REF, ARTWORK_SHA256) is accepted and each one is used"
else
	no "(LV17) a product.conf with all six keys of the live media (INSTALLER_REF tag, INSTALLER_URL, PRODUCT_VERSION, ARTWORK_VARIANT, ARTWORK_REF, ARTWORK_SHA256) is accepted and each one is used (rc=$r17a)"
	grep -n 'installer\|artwork\|clone\|checkout\|product.conf' "$lv/a17.log" | head -8 | sed 's/^/      | /'
fi
if [ "$r17e" -eq 0 ] &&
	grep -q 'git clone --quiet --no-checkout https://github.com/wtfbsd/installer-template.git ' "$lv/e17.log" &&
	grep -q 'checkout --quiet 907e707a606edc2023d437fc41c46a674f8143f5$' "$lv/e17.log" &&
	grep -q 'artwork  the published pack https://github.com/wtfbsd/artwork-template/releases/download/pack-5aaea01b0829/examplebsd-5aaea01b0829-default.tar.xz (sha256 f0753807e81daacc3dc7b24995d49e74b1fd61152035115b37888fe814176a12), variant default, version 2026.11$' "$lv/e17.log"; then
	ok "(LV17) the six keys left empty keep the template's pins and defaults (the pinned installer from the public repository, pack 5aaea01 default with its pinned sum, version 2026.11)"
else
	no "(LV17) the six keys left empty keep the template's pins and defaults (the pinned installer from the public repository, pack 5aaea01 default with its pinned sum, version 2026.11) (rc=$r17e)"
	grep -n 'installer\|artwork\|clone\|checkout\|product.conf' "$lv/e17.log" | head -8 | sed 's/^/      | /'
fi
{ cat "$fixture"; printf '%s\n' "ARTWORK_SHA256=$lv17s"; } > "$lv/sum17.conf"
{ cat "$fixture"; printf '%s\n' 'INSTALLER_URL=http://example.org/installer-template.git'; } > "$lv/url17.conf"
{ cat "$fixture"; printf '%s\n' 'ARTWORK_SHA256=abc'; } > "$lv/bad17.conf"
env -u INSTALLER_DIR sh "$build" -n -c "$lv/sum17.conf" -p desktop --no-user -o "$lv/s17" > "$lv/s17.log" 2>&1; r17s=$?
env -u INSTALLER_DIR -u INSTALLER_REPO sh "$build" -n -c "$lv/url17.conf" -p desktop --no-user -o "$lv/u17" > "$lv/u17.log" 2>&1; r17u=$?
env -u INSTALLER_DIR sh "$build" -n -c "$lv/bad17.conf" -p desktop --no-user -o "$lv/b17" > "$lv/b17.log" 2>&1; r17b=$?
if [ "$r17s" -ne 0 ] && grep -q 'does not match ARTWORK_SHA256 of product.conf' "$lv/s17.log" &&
	[ "$r17u" -ne 0 ] && grep -q 'INSTALLER_URL (INSTALLER_REPO) must be an https URL' "$lv/u17.log" &&
	[ "$r17b" -ne 0 ] && grep -q 'ARTWORK_SHA256 must be 64 lowercase hex digits' "$lv/b17.log"; then
	ok "(LV17) a local pack that does not match ARTWORK_SHA256, an INSTALLER_URL that is not https, and an ARTWORK_SHA256 that is not a sha256 are refused"
else
	no "(LV17) a local pack that does not match ARTWORK_SHA256, an INSTALLER_URL that is not https, and an ARTWORK_SHA256 that is not a sha256 are refused ($r17s/$r17u/$r17b)"
fi
# the download, through a stand-in for fetch(1): a pack that matches the
# pinned checksum is used, any other is refused before it is unpacked
mkdir -p "$lv/fetchbin"
cat > "$lv/fetchbin/fetch" <<'EOF'
#!/bin/sh
printf 'CMD fetch %s\n' "$*" >> "$STUB_LOG"
[ "$1" = -q ] && [ "$2" = -o ] || exit 2
cp "$FAKE_DOWNLOAD" "$3"
EOF
chmod 755 "$lv/fetchbin/fetch"
pd=$(mkpack default "$work/packs5")
awk '{ print $1 "  " $2 }' "$pd.sha256" > "$lv/pinned.sha256"
FAKE_DOWNLOAD=$pd ARTWORK_PACKS_SHA256="$lv/pinned.sha256" REAL_PATH_PREFIX="$lv/fetchbin" \
	REAL_NO_PACK=1 REAL_PROFILE=desktop realbuild "$work/lv14f" -u ciuser -P "$work/pass.hash"; r8=$realrc
FAKE_DOWNLOAD=$pd REAL_PATH_PREFIX="$lv/fetchbin" ARTWORK_PACKS_SHA256="$repo/tools/artwork-packs.sha256" \
	REAL_NO_PACK=1 REAL_PROFILE=desktop realbuild "$work/lv14g" -u ciuser -P "$work/pass.hash"; r9=$realrc
if [ "$r8" -eq 0 ] && grep -q '^CMD fetch -q -o .*examplebsd-5aaea01b0829-default.tar.xz https://github.com/wtfbsd/artwork-template/releases/download/pack-5aaea01b0829/' "$work/lv14f/stub.log" &&
	[ -s "$work/lv14f/out/desktop/root/usr/local/share/examplebsd/identity" ] &&
	[ "$r9" -ne 0 ] && grep -q 'does not match the checksum pinned in' "$work/lv14g/build.log" &&
	[ ! -d "$work/lv14g/out/artwork-pack/examplebsd-5aaea01b0829-default" ]; then
	ok "(LV14) the downloaded pack is used when it matches the pinned checksum and refused before unpacking when it does not"
else
	no "(LV14) the downloaded pack is used when it matches the pinned checksum and refused before unpacking when it does not ($r8/$r9)"
	tail -n 3 "$work/lv14f/build.log" "$work/lv14g/build.log" | sed 's/^/      | /'
fi
ARTWORK_PACKS_SHA256="$repo/tools/artwork-packs.sha256" env -u ARTWORK_PACK ARTWORK_REF=0123456789abcdef sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/a5" > "$lv/a5.log" 2>&1
if [ $? -ne 0 ] && grep -q 'no pinned checksum for the artwork pack examplebsd-0123456789ab-default.tar.xz' "$lv/a5.log"; then
	ok "(LV14) an ARTWORK_REF without a pinned pack checksum is refused"
else
	no "(LV14) an ARTWORK_REF without a pinned pack checksum is refused"
fi
ARTWORK_PACKS_SHA256="$repo/tools/artwork-packs.sha256" sh "$build" -n -c "$fixture" -p desktop --no-user -o "$lv/a6" > "$lv/a6.log" 2>&1
if [ $? -ne 0 ] && grep -q 'examplebsd-5aaea01b0829-default.tar.xz is not the one pinned in' "$lv/a6.log"; then
	ok "(LV14) a local pack named like a pinned one but with other content is refused"
else
	no "(LV14) a local pack named like a pinned one but with other content is refused"
fi
# a supported spot this template cannot install, and a missing column
rm -rf "$lv/art5"; cp -R "$repo/tests/fixtures/fake-artwork" "$lv/art5"
printf 'new-spot\tsomething\tsomewhere\t-\t-\t-\t/usr/local/share/<slug>/new\t-\t-\t-\tnew/thing\t-\n' >> "$lv/art5/branding/spots.tsv"
REAL_NO_PACK=1 ARTWORK_DIR="$lv/art5" REAL_PROFILE=desktop realbuild "$work/lv14s" -u ciuser -P "$work/pass.hash"; r6=$realrc
rm -rf "$lv/art6"; cp -R "$repo/tests/fixtures/fake-artwork" "$lv/art6"
awk -F '\t' 'BEGIN { OFS = "\t" } NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dragonfly") $i = "dragonflybsd" } { print }' \
	"$repo/tests/fixtures/fake-artwork/branding/spots.tsv" > "$lv/art6/branding/spots.tsv"
REAL_NO_PACK=1 ARTWORK_DIR="$lv/art6" REAL_PROFILE=desktop realbuild "$work/lv14m" -u ciuser -P "$work/pass.hash"; r7=$realrc
if [ "$r6" -ne 0 ] && grep -q 'spot new-spot is supported on DragonFly in branding/spots.tsv' "$work/lv14s/build.log" &&
	[ "$r7" -ne 0 ] && grep -q 'has no spot, dragonfly or rendered column' "$work/lv14m/build.log"; then
	ok "(LV14) a spot the list marks supported that this template cannot install, or a missing column, stops the build"
else
	no "(LV14) a spot the list marks supported that this template cannot install, or a missing column, stops the build ($r6/$r7)"
	tail -n 2 "$work/lv14s/build.log" "$work/lv14m/build.log" | sed 's/^/      | /'
fi
# a source checkout of the template is rendered (render.sh --identity)
REAL_NO_PACK=1 ARTWORK_DIR="$repo/tests/fixtures/fake-artwork" REAL_PROFILE=desktop realbuild "$work/lv14d" -u ciuser -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] && grep -qx "STAMP $pname 2026.11 / DragonFly 6.4.2 / Default / amd64" "$realout/desktop/root/usr/local/share/examplebsd/lightdm/greeter-1920x1080.png" 2>/dev/null; then
	ok "(LV14) a source checkout of the artwork template (ARTWORK_DIR) is rendered with --variant and --identity"
else
	no "(LV14) a source checkout of the artwork template (ARTWORK_DIR) is rendered with --variant and --identity (rc=$realrc)"
	tail -n 3 "$work/lv14d/build.log" | sed 's/^/      | /'
fi

# (LV9) the README describes the live desktop and the install command
if grep -q 'autologin' "$repo/README.md" && grep -q 'examplebsd-install\|@SLUG@-install' "$repo/README.md" &&
	grep -q 'INSTALLER_REF' "$repo/README.md" && grep -q 'ttyv1' "$repo/README.md"; then
	ok "(LV9) the README describes the live desktop, the install command and INSTALLER_REF"
else
	no "(LV9) the README describes the live desktop, the install command and INSTALLER_REF"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
