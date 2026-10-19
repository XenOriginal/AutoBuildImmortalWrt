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
# Remove stale U-disk-era fstab entries: /mnt/sda1, /rom, /mnt/sda4 and the
# old disabled /overlay entry.  The new mount points are /boot and /Lager.
for sec in $(uci -q show fstab | sed -n 's/^fstab\.\([^=]*\)=mount$/\1/p' | sort -r); do
    target=$(uci -q get "fstab.$sec.target" 2>/dev/null || true)
    case "$target" in
        /mnt/sda1|/rom|/mnt/sda4|/overlay) uci -q delete "fstab.$sec" ;;
    esac
done
uci -q set fstab.@global[0].check_fs='0'
uci -q commit fstab
exit 0
