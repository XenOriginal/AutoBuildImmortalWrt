#!/bin/sh
# First-boot state directory and cleanup of carried-over U-disk-era services.
mkdir -p /root/wrtpatch/state
for f in /etc/init.d/host-zram /etc/init.d/hw-mem /etc/init.d/hsuart-console-detect; do
    [ -e "$f" ] && rm -f "$f"
done
for l in /etc/rc.d/S15host-zram /etc/rc.d/S94hw-mem /etc/rc.d/S95hsuart-console-detect \
         /etc/rc.d/S99nfs-guard-dockstop /etc/rc.d/K*host-zram /etc/rc.d/K*hw-mem; do
    [ -e "$l" ] && rm -f "$l"
done
uci -q set fstab.@global[0].check_fs='0'
uci -q commit fstab
exit 0
