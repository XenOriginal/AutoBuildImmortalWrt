#!/bin/sh
# ============================================================================
# A/B 公共函数库 (ab-upgrade / ab-status / ab-bootok 共用)
#
# 设备侧运行, 目标环境是 OpenWrt busybox ash。
#
# 【依赖原则】只用最小镜像里一定有的工具: dd / hexdump / awk / sed / cut /
# mkfs.f2fs / tar / mount / grub-editenv。**不依赖 parted / blkid / losetup** ——
# 演练实测: 官方最小镜像里这三者都不存在, 而设备侧工具一旦缺依赖就是"升级器
# 直接不可用"。分区表与 PARTUUID 改为直接读裸 GPT/MBR 字节。
#
# 布局与设计见仓库 x86-64-host/ab/README.md。
# ============================================================================

AB_ENV=${AB_ENV:-/boot/grub/grubenv}
AB_LOG=${AB_LOG:-/etc/ab.log}

ab_info() { echo ">>> $*"; }
ab_warn() { echo "  !! $*" >&2; }
ab_die()  { echo "!!! $*" >&2; exit 1; }

# 去掉分区号, 得到整盘设备名。
# 注意不能用 sed 's/p\?[0-9]*$//': 它会把 /dev/loop3 误裁成 /dev/loo
# (把结尾的 "p3" 当成分区后缀), 从而让"源/目标同盘"这类安全判断失效。
ab_strip_part() { # $1=/dev/sda1 | /dev/loop1p3 | /dev/loop3 | /dev/nvme0n1p2
    local d=$1 bb pre
    case "$d" in
        *p[0-9]|*p[0-9][0-9]|*p[0-9][0-9][0-9])
            pre=${d%p*}
            # 只有 'p' 前是数字或 'n' 时才当分区后缀 (排除 /dev/loop3 里的 "p3")
            case "$pre" in
                *[0-9]|*n) echo "$pre" ;;
                *) echo "$d" ;;
            esac ;;
        /dev/sd[a-z][0-9]*|/dev/hd[a-z][0-9]*|/dev/vd[a-z][0-9]*)
            bb=$d
            while :; do case "$bb" in *[0-9]) bb=${bb%[0-9]} ;; *) break ;; esac; done
            echo "$bb" ;;
        *) echo "$d" ;;
    esac
}

ab_partdev() { # $1=disk $2=num
    local c
    for c in "$1p$2" "$1$2"; do
        [ -b "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

ab_boot_mounted() { awk '$2=="/boot"{found=1} END{exit !found}' /proc/mounts 2>/dev/null; }

# /boot 分区: 先看挂载表, 再按 LABEL=kernel 兜底扫描 (不能假设 fstab 一定有 /boot)
ab_boot_dev() {
    local d b v
    d=$(awk '$2=="/boot"{print $1; exit}' /proc/mounts 2>/dev/null)
    [ -n "$d" ] && { echo "$d"; return 0; }
    for b in /dev/sd*[0-9] /dev/hd*[0-9] /dev/vd*[0-9] /dev/nvme*p[0-9] /dev/mmcblk*p[0-9]; do
        [ -b "$b" ] || continue
        # 不依赖 blkid: FAT 卷标在引导扇区偏移 43 (FAT12/16) 或 71 (FAT32)
        v=$(ab_fat_label "$b")
        [ "$v" = "kernel" ] && { echo "$b"; return 0; }
    done
    return 1
}

ab_ensure_boot() {
    local b
    ab_boot_mounted && return 0
    b=$(ab_boot_dev) || return 1
    mkdir -p /boot
    mount -t vfat "$b" /boot 2>/dev/null || mount "$b" /boot 2>/dev/null || return 1
    return 0
}

ab_boot_is_ro() {
    awk '$2=="/boot" && $4 ~ /(^|,)ro(,|$)/{found=1} END{exit !found}' /proc/mounts 2>/dev/null
}

ab_boot_rw_begin() {
    # Re-entrant: ab-upgrade calls this for the kernel copy and again from
    # ab_env_set().  Preserve the original ro/rw state across the whole
    # operation, otherwise the second call loses _AB_BOOT_WAS_RO and leaves
    # /boot writable after the upgrade.
    if [ "${_AB_BOOT_ACTIVE:-0}" = "1" ]; then
        return 0
    fi
    ab_ensure_boot || return 1
    if ab_boot_is_ro; then
        mount -o remount,rw /boot 2>/dev/null || return 1
        export _AB_BOOT_WAS_RO=1
    else
        export _AB_BOOT_WAS_RO=0
    fi
    export _AB_BOOT_ACTIVE=1
    return 0
}

ab_boot_rw_end() {
    [ "${_AB_BOOT_ACTIVE:-0}" = "1" ] || return 0
    sync
    if [ "${_AB_BOOT_WAS_RO:-0}" = "1" ]; then
        mount -o remount,ro /boot 2>/dev/null || true
    fi
    export _AB_BOOT_WAS_RO=0
    export _AB_BOOT_ACTIVE=0
}

ab_disk_dev() { ab_strip_part "$(ab_boot_dev)"; }

# ---------------------------------------------------------------------------
# 内核分区 (/boot) 的两种布局约定:
#   A) 官方 core.img 的 early config 是 configfile (hd0,gpt1)/boot/grub/grub.cfg
#      -> 挂到 /boot 后路径是 /boot/boot/grub/grubenv   (本仓库安装器的布局)
#   B) 部分镜像把内容直接放在分区根 -> /boot/grub/grubenv
#   设备侧工具必须两种都能用, 否则"找不到 grubenv"直接判非 A/B 布局。
# ---------------------------------------------------------------------------
ab_boot_layout_paths() {
    echo "/boot/grub/grubenv /boot/boot/grub/grubenv"
}
ab_env_path() {
    local p
    for p in $(ab_boot_layout_paths); do [ -f "$p" ] && { echo "$p"; return 0; }; done
    ab_ensure_boot || return 1
    for p in $(ab_boot_layout_paths); do [ -f "$p" ] && { echo "$p"; return 0; }; done
    return 1
}
# 内核文件所在目录 (vmlinuz.a/vmlinuz.b 所在处)
#
# Two layouts are supported:
#   A) env = /boot/grub/grubenv          -> kernel dir = /boot
#   B) env = /boot/boot/grub/grubenv     -> kernel dir = /boot/boot
# The old implementation returned the env directory (/boot/boot/grub), which
# made ab-upgrade write vmlinuz.b next to grub.cfg instead of next to
# vmlinuz.a.  Check for the actual kernel files to avoid that silent mismatch.
ab_kernel_dir() {
    local e d p
    e=$(ab_env_path) || return 1
    d=$(dirname "$e")
    if [ -f "$d/vmlinuz.a" ] || [ -f "$d/vmlinuz.b" ]; then
        echo "$d"; return 0
    fi
    p=$(dirname "$d")
    if [ -f "$p/vmlinuz.a" ] || [ -f "$p/vmlinuz.b" ]; then
        echo "$p"; return 0
    fi
    echo "$d"
}

# ---------------------------------------------------------------------------
# 裸字节工具
# ---------------------------------------------------------------------------
# 注意: 必须写 1/1 "%02x" —— busybox hexdump 默认迭代单位不是 1 字节,
#       用 "%02x" 会把 8 字节读成 8 个字符(实测踩过), 导致长度断言失败。
ab_read_hex() { # $1=dev $2=offset $3=len -> 小写 hex
    dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

ab_hex_le32() { # 8 hex -> 十进制
    local h=$1
    echo $(( 0x$(echo "$h" | cut -c1-2) + 0x$(echo "$h" | cut -c3-4)*256 \
           + 0x$(echo "$h" | cut -c5-6)*65536 + 0x$(echo "$h" | cut -c7-8)*16777216 ))
}

ab_hex_le64() { # 16 hex -> 十进制
    local lo hi
    lo=$(ab_hex_le32 "$(echo "$1" | cut -c1-8)")
    hi=$(ab_hex_le32 "$(echo "$1" | cut -c9-16)")
    echo $(( lo + hi * 4294967296 ))
}

# FAT 卷标是否为 kernel (FAT32 卷标在偏移 71, FAT12/16 在 43; "kernel" = 6b65 726e 656c)
ab_fat_label() {
    local off
    for off in 71 43; do
        [ "$(ab_read_hex "$1" "$off" 6)" = "6b65726e656c" ] && { echo kernel; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# 分区表 (MBR 与 GPT), 不依赖 parted
#   输出每行: 序号:起始扇区:扇区数
# ---------------------------------------------------------------------------
ab_raw_parts() { # $1=镜像或磁盘
    local t0 ent_lba ent_sz base i e first last cnt
    [ "$(ab_read_hex "$1" 510 2)" = "55aa" ] || return 1
    t0=$(ab_read_hex "$1" $((446 + 4)) 1)
    if [ "$t0" = "ee" ]; then
        # GPT: 分区项数组位置在 GPT 头偏移 72, 项大小在 84
        ent_lba=$(ab_hex_le64 "$(ab_read_hex "$1" $((512 + 72)) 8)")
        ent_sz=$(ab_hex_le32 "$(ab_read_hex "$1" $((512 + 84)) 4)")
        [ "$ent_sz" -gt 0 ] || return 1
        base=$(( ent_lba * 512 ))
        i=1
        while [ $i -le 4 ]; do
            e=$(( base + (i - 1) * ent_sz ))
            if [ "$(ab_read_hex "$1" "$e" 16)" != "00000000000000000000000000000000" ]; then
                first=$(ab_hex_le64 "$(ab_read_hex "$1" $((e + 32)) 8)")
                last=$(ab_hex_le64 "$(ab_read_hex "$1" $((e + 40)) 8)")
                echo "$i:$first:$((last - first + 1))"
            fi
            i=$((i + 1))
        done
    else
        i=1
        while [ $i -le 4 ]; do
            e=$((446 + (i - 1) * 16))
            if [ "$(ab_read_hex "$1" $((e + 4)) 1)" != "00" ]; then
                first=$(ab_hex_le32 "$(ab_read_hex "$1" $((e + 8)) 4)")
                cnt=$(ab_hex_le32 "$(ab_read_hex "$1" $((e + 12)) 4)")
                echo "$i:$first:$cnt"
            fi
            i=$((i + 1))
        done
    fi
}

# GPT 分区的 Linux PARTUUID (前 3 段小端序, 末段原样)
ab_partuuid_gpt() { # $1=磁盘 $2=分区号
    local ent_lba ent_sz e g a b c d1 d2
    ent_lba=$(ab_hex_le64 "$(ab_read_hex "$1" $((512 + 72)) 8)")
    ent_sz=$(ab_hex_le32 "$(ab_read_hex "$1" $((512 + 84)) 4)")
    [ "$ent_sz" -gt 0 ] || return 1
    e=$(( ent_lba * 512 + ($2 - 1) * ent_sz + 16 ))
    g=$(ab_read_hex "$1" "$e" 16)
    [ ${#g} -eq 32 ] || return 1
    a=$(echo "$g" | cut -c7-8)$(echo "$g" | cut -c5-6)$(echo "$g" | cut -c3-4)$(echo "$g" | cut -c1-2)
    b=$(echo "$g" | cut -c11-12)$(echo "$g" | cut -c9-10)
    c=$(echo "$g" | cut -c15-16)$(echo "$g" | cut -c13-14)
    d1=$(echo "$g" | cut -c17-20)
    d2=$(echo "$g" | cut -c21-32)
    echo "$a-$b-$c-$d1-$d2"
}

# ---------------------------------------------------------------------------
# squashfs / overlay
# ---------------------------------------------------------------------------
ab_squashfs_bytes_used() { # $1=dev (超级块偏移 40 处为 LE64 bytes_used)
    h=$(ab_read_hex "$1" 40 8)
    [ ${#h} -eq 16 ] || return 1
    ab_hex_le64 "$h"
}

# OpenWrt 在槽分区内建立 overlay 的偏移 = bytes_used 向上 4KiB 对齐
# (实测: 10,416,478 -> 10,420,224 处正是 f2fs 魔数; 128KiB 对齐处为空)
ab_overlay_offset() { # $1=dev
    local bu
    bu=$(ab_squashfs_bytes_used "$1") || return 1
    echo $(( (bu + 4095) / 4096 * 4096 ))
}

# 在分区指定偏移处建立 f2fs overlay 镜像 (不依赖 losetup: 先在稀疏文件上
# mkfs, 再用 dd 落到目标偏移)
# 在目标分区指定偏移处铺一个"已灌入内容"的 f2fs overlay。
#
# 【为什么绕一圈】实测: mount -o loop,offset=N 对【分区设备】并不可靠
# (busybox mount 的 offset 只对文件镜像可靠)。因此改为:
#     临时文件上建 f2fs -> 挂载这个文件 -> 灌入内容 -> 整块 dd 到目标偏移
# 全程只用 dd + mkfs.f2fs + mount, 不依赖 losetup, 也不依赖偏移挂载。
ab_seed_overlay() { # $1=目标分区设备 $2=偏移(4KiB 对齐) $3=大小(MiB) $4=源目录(可为空)
    local f=/tmp/ab-ovl.$$
    local m=/tmp/ab-ovl.mnt.$$
    local rc=0
    dd if=/dev/zero of="$f" bs=1M count=1 seek=$(( $3 - 1 )) 2>/dev/null || return 1
    mkfs.f2fs -f "$f" >/dev/null 2>&1 || mkfs.f2fs "$f" >/dev/null 2>&1 || { rm -f "$f"; return 1; }

    if [ -n "${4:-}" ] && [ -d "$4" ]; then
        mkdir -p "$m"
        if mount -o loop "$f" "$m" 2>/dev/null; then
            # Only migrate mutable configuration/state, not the old image's
            # binaries, init scripts or package database.  The new rootfs
            # lower layer must supply those; otherwise an A/B upgrade would
            # silently resurrect the old fsck/nfs/poweroff scripts and even
            # the old apk database.
            EXCL="/tmp/ab-ovl.excl.$$"
            cat > "$EXCL" <<'EXCLUDES'
./usr
./usr/*
./bin
./bin/*
./sbin
./sbin/*
./lib
./lib/*
./etc/init.d
./etc/init.d/*
./etc/hotplug.d
./etc/hotplug.d/*
./etc/rc.d
./etc/rc.d/*
./etc/modules.d
./etc/modules.d/*
./etc/uci-defaults
./etc/uci-defaults/*
./etc/sysctl.conf
./etc/ab-bootopts
./etc/hw-storage-guard.conf
./var
./var/*
EXCLUDES
            ( cd "$4" && tar -cf - -X "$EXCL" . ) | tar -C "$m" -xf - || rc=1
            rm -f "$EXCL"
            sync
            umount "$m"
        else
            rc=1
        fi
        rmdir "$m" 2>/dev/null || true
    fi

    # 偏移不保证是 MiB 整数倍 (实测 10420224 = 9.9375 MiB), 按 4KiB 块定位
    dd if="$f" of="$1" bs=4096 seek=$(( $2 / 4096 )) conv=fsync 2>/dev/null || rc=1
    rm -f "$f"
    return $rc
}

# ---------------------------------------------------------------------------
# 槽识别
#   布局由 ab-layout.sh 固定生成, 故按分区号 3/4 识别 (不依赖 blkid)
# ---------------------------------------------------------------------------
ab_slot_devs() {
    local disk a b
    disk=$(ab_disk_dev) || return 1
    a=$(ab_partdev "$disk" 3) || return 1
    b=$(ab_partdev "$disk" 4) || return 1
    echo "$a $b"
}

ab_current_slot() { # $1=槽A dev $2=槽B dev -> A|B
    local pu disk a b
    pu=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=PARTUUID=//p')
    [ -n "$pu" ] || return 1
    disk=$(ab_disk_dev) || return 1
    a=$(ab_partuuid_gpt "$disk" 3 2>/dev/null)
    b=$(ab_partuuid_gpt "$disk" 4 2>/dev/null)
    if [ -n "$a" ] && [ "$pu" = "$a" ]; then echo A
    elif [ -n "$b" ] && [ "$pu" = "$b" ]; then echo B
    else return 1
    fi
}

ab_overlay_dir() { awk '$2=="/overlay"{print $2; exit}' /proc/mounts 2>/dev/null; }

ab_env_get() {
    local e; e=$(ab_env_path) || return 1
    grub-editenv "$e" list 2>/dev/null | sed -n "s/^$1=//p" | head -1
}
ab_env_set() {
    local e rc
    ab_boot_rw_begin || return 1
    e=$(ab_env_path) || { ab_boot_rw_end; return 1; }
    grub-editenv "$e" set "$@"
    rc=$?
    ab_boot_rw_end
    return $rc
}

# 校验 combined 镜像: 有分区表且 p2 为 squashfs -> 回显 "p1起始 p1扇区数 p2起始 p2扇区数"
ab_check_image() { # $1=镜像
    local parts p1s p1n p2s p2n
    parts=$(ab_raw_parts "$1") || return 1
    p1s=$(echo "$parts" | awk -F: '$1==1{print $2}')
    p1n=$(echo "$parts" | awk -F: '$1==1{print $3}')
    p2s=$(echo "$parts" | awk -F: '$1==2{print $2}')
    p2n=$(echo "$parts" | awk -F: '$1==2{print $3}')
    [ -n "$p1s" ] && [ -n "$p2s" ] || return 1
    [ "$(ab_read_hex "$1" $((p2s * 512)) 4)" = "68737173" ] || return 1
    echo "$p1s $p1n $p2s $p2n"
}
