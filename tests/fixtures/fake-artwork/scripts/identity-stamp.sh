#!/bin/sh
# identity-stamp.sh [options] IDENTITY IN OUT — a stand-in: OUT is IN with a
# line "STAMP <the identity line>" (the real one draws it with ImageMagick).
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib-identity.sh"
while [ $# -gt 3 ]; do shift; done
cp "$2" "$3"
identity_read "$1"
printf 'STAMP %s\n' "$(identity_line ' / ')" >> "$3"
