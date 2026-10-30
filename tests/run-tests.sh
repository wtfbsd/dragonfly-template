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
	_rb_w=$1
	shift
	rm -rf "$_rb_w/src" "$_rb_w/out" "$_rb_w/release" "$_rb_w/dports"
	mkdir -p "$_rb_w/src" "$_rb_w/release" "$_rb_w/dports"
	cp -R "$repo/tests/fixtures/fake-src/." "$_rb_w/src/"
	: > "$_rb_w/stub.log"
	_rb_args="$*"
	case " $_rb_args " in
	*' -u '*) ;;
	*) _rb_args="$_rb_args --no-user" ;;
	esac
	# shellcheck disable=SC2086
	(
		cd "$_rb_w" || exit 1
		PATH="$repo/tests/stubs:$PATH" \
		STUB_LOG="$_rb_w/stub.log" \
		WTFBSD_TEST_ALLOW_ANY_OS=1 \
		WTFBSD_TEST_ALLOW_NONROOT=1 \
		DPORTS_PATH="$_rb_w/dports" \
			sh "$build" -c "${REAL_CONF:-$fixture}" -s "$_rb_w/src" -o "$_rb_w/out" \
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
	WTFBSD_BHYVE_FIRMWARE= \
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
	WTFBSD_BHYVE_FIRMWARE= \
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
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/opencode.json" > "$work/json.log" 2>&1; then
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
for f in $(find "$repo/overlay" -type f -path '*rc.conf.d/*'); do
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
	if [ -n "$(find "$repo/overlay" -type f -path "*rc.conf.d/$svc" 2>/dev/null)" ]; then
		ok "rc.conf.d/$svc exists"
	else
		no "rc.conf.d/$svc exists"
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
# the gui modifier of the release tooling adds a browser and an editor to
# the packages of the release: the build does not use it. The skeleton of
# the GUI is named in ROOTSKELS instead.
if [ "$realrc" -eq 0 ] &&
	! grep -q '^TARGET gui$' "$work/desk/stub.log" 2>/dev/null &&
	! grep -q '^MODIFIER gui$' "$work/desk/stub.log" 2>/dev/null &&
	grep -q '^VAR ROOTSKELS=.*/nrelease/gui ' "$work/desk/stub.log" 2>/dev/null &&
	[ -f "$work/desk/out/desktop/examplebsd-desktop-amd64.iso" ]; then
	ok "(C1) the desktop profile is built without the gui modifier of nrelease"
else
	no "(C1) the desktop profile is built without the gui modifier of nrelease (rc=$realrc)"
	sed 's/^/      | /' "$work/desk/build.log"
fi
REAL_PROFILE=both realbuild "$work/both" -u ciuser -k "$work/ci.pub" -P "$work/pass.hash"
if [ "$realrc" -eq 0 ] &&
	! grep -q '^TARGET gui$' "$work/both/stub.log" 2>/dev/null &&
	! grep -q '^MODIFIER gui$' "$work/both/stub.log" 2>/dev/null &&
	[ -f "$work/both/out/appliance/examplebsd-appliance-amd64.img" ] &&
	[ -f "$work/both/out/desktop/examplebsd-desktop-amd64.iso" ]; then
	ok "(C1) the profile both is built through the real path"
else
	no "(C1) the profile both is built through the real path (rc=$realrc)"
	sed 's/^/      | /' "$work/both/build.log"
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
printf 'USERNAME=ciuser\nSSH_KEY=%s %s testkey\n' 'ssh-ed25519' 'AAAAtest' \
	> "$work/fbroot/boot/firstboot-user.conf"
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
if [ -f "$stage/firstboot" ]; then
	ok "(C3) the image holds the sentinel of the first boot"
else
	no "(C3) the image holds the sentinel of the first boot"
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
	WTFBSD_BHYVE_FIRMWARE= \
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
	WTFBSD_BHYVE_FIRMWARE= \
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
	WTFBSD_BHYVE_FIRMWARE= \
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
	awk -v q="$_q" '
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
	awk -v q="$_q" -v d="$_d" '
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
#      build hold the skeleton of the release root, the skeleton of the
#      GUI (the desktop) and the overlay of the product, in that order
# --------------------------------------------------------------------------
d1log="$work/c1/stub.log"
if grep -q '^VAR ROOTSKELS=.*/nrelease/root .*/rootskels$' "$d1log" 2>/dev/null; then
	ok "(D1) the build hands the skeleton of the release tooling and the overlay to make(1)"
else
	no "(D1) the build hands the skeleton of the release tooling and the overlay to make(1)"
	grep '^VAR ROOTSKELS=' "$d1log" 2>/dev/null | sed 's/^/      | /'
fi
if grep -q '^VAR ROOTSKELS=.*/nrelease/gui .*/rootskels$' "$work/desk/stub.log" 2>/dev/null; then
	ok "(D1) the desktop hands the skeleton of the GUI to make(1) as well"
else
	no "(D1) the desktop hands the skeleton of the GUI to make(1) as well"
	grep '^VAR ROOTSKELS=' "$work/desk/stub.log" 2>/dev/null | sed 's/^/      | /'
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
# (D2) the packages are DPorts origins: dsynth takes category/port only
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
# a list with a bare name is refused: dsynth would not take it
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
