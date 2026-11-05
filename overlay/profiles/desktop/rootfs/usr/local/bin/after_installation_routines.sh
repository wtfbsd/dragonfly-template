#!/bin/sh
#
# after_installation_routines.sh — the hook of the stock DragonFly
# installer.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The stock installer (/usr/sbin/installer, log in as installer on ttyv1
# or on the serial line of the live media) runs this file, when it
# exists, after it has copied the live root onto the disk, which it has
# mounted on /mnt. The copy holds what the live session added to the live
# root; it is removed here, so that the installed system has no live
# user, no automatic login and no installer that opens by itself.

exec /usr/local/sbin/@SLUG@-live-clean /mnt
