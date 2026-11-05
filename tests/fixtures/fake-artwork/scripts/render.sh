#!/bin/sh
# render.sh --variant NAME [--identity FILE] PALETTE OUTDIR — the source
# checkout path of the stand-in artwork template.
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
v=default i=''
while [ $# -gt 2 ]; do case $1 in --variant) v=$2; shift 2 ;; --identity) i=$2; shift 2 ;; *) break ;; esac; done
out=$2
sh "$here/make-out.sh" "$out" examplebsd ExampleBSD "$v"
if [ -n "$i" ]; then
	for f in "$out/lightdm/greeter-1920x1080.png" "$out"/wallpapers/wallpaper-*.png; do
		sh "$here/identity-stamp.sh" "$i" "$f" "$f.s" && mv "$f.s" "$f"
	done
fi
