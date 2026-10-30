# AGENTS.md — how to work in this repository

Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

## What this repository is

`dragonfly-template` is a **public, generic template** for shipping a
per-product DragonFly distribution. It builds images that are an **overlay
on unmodified upstream DragonFly**: the DragonFly source tree is never
patched, the product is the set of files under `overlay/` plus the DPorts
packages it names. The placeholders are **ExampleBSD**, the slug
`examplebsd` and the host name `example.org`; the real values come from
`product.conf`, which is parsed, never sourced.

## The overlay rules

1. **Never patch the DragonFly source tree and never patch DPorts.**
   Everything a product needs is a file under `overlay/**/rootfs/`, an
   `rc.conf.d` fragment or a package name in a `packages.list`.
2. The overlay is staged base-first, then the profile on top of it, and
   the staged tree is handed to the release tooling as `ROOTSKELS`: the
   release tooling copies it over the release root before the media are
   built, so the product is part of the media itself. The packages of the
   two `packages.list` files are handed over as
   `DPORTS_EXTRA_PACKAGES`.
3. Placeholders `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@`, `@BRAND_URL@` and
   `@FILESYSTEM_ROOT@` are substituted by `build.sh` in the staged copies
   of the overlay, the `rc.conf.d` fragments included; a staged file
   whose *name* contains `@SLUG@` is renamed to the slug.
4. `rc.conf.d` fragments are named after the service that reads them
   (`rc.conf.d/sshd`, `rc.conf.d/dbus`, ...) and hold one `rc.conf(5)`
   variable per file. DragonFly's `rc.conf(5)` is a single file like
   FreeBSD's, so `build.sh` merges the fragments into the `rc.conf` of
   the release root; the fragments themselves are not shipped. DragonFly
   has no `rc_configured`: nothing of this repository may ask for it.
5. Between the release and the media, `build.sh` runs the
   **post-customize step** (`tools/post-customize.sh`) in the release
   root. It merges the `rc.conf(5)` variables, enables the getty of the
   serial console, points the console of the kernel at it, locks every
   account with uid 0, removes the `installer` account of the release
   tooling from the appliance image, mirrors `/etc` into `/etc.hdd` (the
   installer copies `<dir>.hdd` in place of `<dir>`) and creates the
   sentinel of the first boot.
6. Edits to a staged file (the `rc.conf` variables, the passwords) touch
   the staged copy only. The upstream tree is never modified.
7. Every `rm -rf` goes through the guarded `rmrf()` helper: the path must
   be non-empty and under the output directory.
8. The wireless driver this template never enables may not be mentioned
   anywhere in `overlay/`; `build.sh` fails the build if it is.
9. The overlay is copied with `cp -R`, never with `cp -p`: every staged
   path of the overlay gets the owner and the mode of a system file
   (`root:wheel`, directories 0755, files 0644, scripts 0755). The paths
   are handled one by one: no tree of the release root is ever walked
   with `chown -R` or `chmod -R`.
10. Every account with uid 0 is locked in the staged image by the
    password field of `etc/master.passwd` (the stock release leaves root,
    toor and operator with an **empty** password, and the release tooling
    creates an `installer` account with uid 0 and an empty password); the
    password database is rebuilt with `pwd_mkdb(8)`. The login account is
    provisioned on the first boot by
    `overlay/base/rootfs/etc/rc.d/firstboot_user` (the configuration is
    `/boot/firstboot-user.conf`, parsed and never sourced). The
    privilege escalation is `doas(1)`: the overlay ships
    `/usr/local/etc/doas.conf` with `permit persist :wheel`, and there is
    no `sudo` anywhere in this template.

## The no-ZFS rule

DragonFly has no ZFS at all. The native filesystem of DragonFly is
HAMMER2, UFS is available as well, and the root of the **release image**
is UFS: the release tooling creates the image root with `newfs(8)`.
`build.sh` refuses `FILESYSTEM_ROOT=zfs` and `ZFS_DATA_POOL=yes` and
quotes the honesty note of the per_os row of `wtfbsd/agents
questions.yaml`:

> The native filesystem is HAMMER2 (UFS is also available). No ZFS.

A product therefore answers `FILESYSTEM_ROOT=hammer2` and
`ZFS_DATA_POOL=no`. The `motd` of the product states the truth about the
image: it never claims that the root of the image is HAMMER2.

## How to build

```sh
./build.sh -c product.conf -n     # dry run: validate and print the plan
./build.sh -c product.conf        # the real build (DragonFly only)
./build.sh -c product.conf -p both
./build.sh -c product.conf -u ciuser -k ./ci.pub              # a key
./build.sh -c product.conf -u ciuser -P ./passwd.hash         # a password
```

The dry run changes nothing and works on any POSIX host; always run it
first. It prints the very commands the real path runs: the plan and the
build are the same code, every command goes through the `step()` helper.

The real build needs an unmodified DragonFly source tree (with its
`nrelease` directory), runs on DragonFly itself (DragonFly cannot be
cross-built) and runs as root. Two environment variables exist for the
test suite only and relax those two checks: `WTFBSD_TEST_ALLOW_ANY_OS`
and `WTFBSD_TEST_ALLOW_NONROOT`. A build host never sets them.

The first-boot user needs a way in: the appliance profile needs a key
(`-k`), the desktop profile needs a password (`-P`, a `crypt(3)` hash; a
plain text password is refused), because a key is of no use on a desktop
without sshd.

## How to test

```sh
sh tests/run-tests.sh             # the whole suite, in the foreground
sh tests/boot-test.sh IMAGE PROFILE [NAME]   # boot an image and wait for it
```

The suite needs no root, no network and no VM. It runs the dry run **and
the real build path** of `build.sh` against the stand-ins in
`tests/stubs` and a fake source tree, checks the tree statically, runs
the leak check (`tests/leak-check.sh`) and runs the boot test against the
fake provider in `tests/fixtures`. The boot test uses `ci/vm.sh` only,
waits for a `login:` prompt on the serial console (and for `sshd` on the
appliance profile), fails on a timeout and always destroys the VM.

## The generic-template rule

This repository ships to anyone, so it carries no organisation-specific
name, no real host name, no real address, no internal service name, no
ticket number, no user name and no credential value. Credentials are
referenced by a documented generic id only. The VM handling goes through
the one pluggable script `ci/vm.sh`; a site plugs in its own provider
with `WTFBSD_VM_PROVIDER_PATH` (a file outside this repository). An
unknown or missing provider must fail closed. That provider script runs
with the rights of the agent: it has to be root-owned and not writable
by anyone who may start a job.

The leak check (`tests/leak-check.sh`) looks for generic shapes only —
addresses, foreign email addresses, internal top level domains, key
headers, token prefixes and credential names. The repository ships **no
list of names**: a list of names is itself a list of names. A site checks
for its own names with `WTFBSD_DENYLIST`, a file outside this
repository.

## The agents

`opencode.json` registers two agents, both of which read this file:
`builder` (dry run first, the real build only when it is asked to, never
edits the overlay rules away) and `tester` (runs `tests/run-tests.sh` in
the foreground, reports red and green, never weakens a test).

## Conventions

- POSIX `sh` (`#!/bin/sh`, `set -eu`), no bashisms, every expansion
  quoted, no `eval` on a configuration file, no global `IFS` change.
- Configuration files are parsed line by line (`KEY=value`), never
  sourced.
- Every new file starts with the license header:
  `Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).`
- Comments and documentation describe what the code does now, never what
  changed.
- Nothing outside the scope of the task is touched, and no git command
  that writes history or moves `HEAD` is run.
