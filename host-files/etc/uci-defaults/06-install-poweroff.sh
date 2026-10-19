#!/bin/sh
# Install the deterministic /sbin/poweroff engine without following the
# original /sbin/poweroff -> /bin/busybox symlink (otherwise cp would
# overwrite busybox itself).
SRC=/usr/lib/wrtpatch/poweroff.wrapper
[ -x "$SRC" ] || exit 0
rm -f /sbin/poweroff
cp "$SRC" /sbin/poweroff
chmod 0755 /sbin/poweroff
exit 0
