#!/bin/sh
# ============================================================================
# A/B 公共函数库 (ab-upgrade / ab-status / ab-bootok 共用)
#
# 设备侧运行, 目标环境是 OpenWrt busybox ash, 只用 POSIX sh + busybox 工具。
# 依赖: blkid / hexdump / parted / losetup / mkfs.f2fs / grub-editenv
# 布局与设计见仓库 x86-64-host/ab/README.md。
# ============================================================================

AB_ENV=${AB_ENV:-/boot/grub/grubenv}
AB_LOG=${AB_LOG:-/etc/ab.log}

ab_info() { echo ">>> $*"; }
ab_warn() { echo "  !! $*" >&2; }
ab_die()  { echo "!!! $*" >&2; exit 1; }

# /dev/sda1 -> /dev/sda ; /dev/loop0p3 -> /dev/loop0
ab_strip_part() { echo "$1" | sed -e 's/p\?[0-9]*$//'; }

# 分区设备节点 (兼容 sdX/nvme/loop 两种命名)
ab_partdev() { # $1=disk $2=num
    for c in "$1p$2" "$1$2"; do
        [ -b "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

ab_boot_dev() { awk '$2=="/boot"{print $1; exit}' /proc/mounts 2>/dev/null; }
ab_disk_dev() { ab_strip_part "$(ab_boot_dev)"; }

# 读取设备的十六进制字节 (长度 len, 起始 offset)
# 注意: 必须写成 1/1 "%02x" —— busybox hexdump 的默认迭代单位不是 1 字节,
#       用 "%02x" 会把 8 字节读成 8 个字符 (实测踩过), 导致长度断言失败。
ab_read_hex() { # $1=dev $2=offset $3=len -> hex 字符串(小写)
    dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

# squashfs 内容长度: 超级块偏移 40 处为 LE64 bytes_used
ab_squashfs_bytes_used() { # $1=dev
    h=$(ab_read_hex "$1" 40 8)
    [ ${#h} -eq 16 ] || return 1
    p0=$(echo "$h" | cut -c1-2);  p1=$(echo "$h" | cut -c3-4)
    p2=$(echo "$h" | cut -c5-6);  p3=$(echo "$h" | cut -c7-8)
    p4=$(echo "$h" | cut -c9-10); p5=$(echo "$h" | cut -c11-12)
    p6=$(echo "$h" | cut -c13-14); p7=$(echo "$h" | cut -c15-16)
    echo $(( 0x$p0 + 0x$p1*256 + 0x$p2*65536 + 0x$p3*16777216 \
           + 0x$p4*4294967296 + 0x$p5*1099511627776 \
           + 0x$p6*281474976710656 + 0x$p7*72057594037927936 ))
}

# OpenWrt 在该槽分区内建立 overlay 的起始偏移 = bytes_used 按 4KiB 向上对齐
# (实测依据: 槽 A 启动后系统自建 f2fs 的魔数正好落在此偏移; 见 README 第五节)
ab_overlay_offset() { # $1=dev
    bu=$(ab_squashfs_bytes_used "$1") || return 1
    echo $(( (bu + 4095) / 4096 * 4096 ))
}

# 两个槽的设备: 优先按 PARTLABEL=SLOT_A/SLOT_B 识别, 退化到分区号 3/4
ab_slot_devs() {
    disk=$(ab_disk_dev)
    a=$(ab_partdev "$disk" 3) || a=""
    b=$(ab_partdev "$disk" 4) || b=""
    n=1
    while [ $n -le 8 ]; do
        d=$(ab_partdev "$disk" "$n") || { n=$((n+1)); continue; }
        pl=$(blkid -s PARTLABEL -o value "$d" 2>/dev/null || true)
        case "$pl" in
            SLOT_A) a="$d" ;;
            SLOT_B) b="$d" ;;
        esac
        n=$((n+1))
    done
    echo "$a $b"
}

# 当前启动槽 (A/B), 依据内核命令行 root=PARTUUID= 与槽分区比对
ab_current_slot() { # $1=slotA dev $2=slotB dev -> A|B|unknown
    pu=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=PARTUUID=//p')
    [ -n "$pu" ] || { echo unknown; return 1; }
    a=$(blkid -s PARTUUID -o value "$1" 2>/dev/null || true)
    b=$(blkid -s PARTUUID -o value "$2" 2>/dev/null || true)
    if [ "$pu" = "$a" ]; then echo A
    elif [ "$pu" = "$b" ]; then echo B
    else echo unknown; return 1
    fi
}

# 当前 overlay 挂载点 (OpenWrt 固定 /overlay)
ab_overlay_dir() { awk '$2=="/overlay"{print $2; exit}' /proc/mounts 2>/dev/null || true; }

# grubenv 读取 (缺文件时返回空)
ab_env_get() { # $1=变量名
    grub-editenv "$AB_ENV" list 2>/dev/null | sed -n "s/^$1=//p" | head -1
}

# grubenv 写入
ab_env_set() { grub-editenv "$AB_ENV" set "$@" 2>/dev/null; }

# 是否为可引导的 combined 镜像 (含分区表 + p2 为 squashfs)
ab_check_image() { # $1=镜像文件 -> 回显 "p1start p1size p2start p2size"
    spec=$(parted -s -m "$1" unit s print 2>/dev/null | awk -F: '/^[0-9]+:/{print $1" "$2" "$4}')
    [ -n "$spec" ] || return 1
    p1s=$(echo "$spec" | awk '$1==1{print $2}' | tr -d 's')
    p1n=$(echo "$spec" | awk '$1==1{print $3}' | tr -d 's')
    p2s=$(echo "$spec" | awk '$1==2{print $2}' | tr -d 's')
    p2n=$(echo "$spec" | awk '$1==2{print $3}' | tr -d 's')
    [ -n "$p1s" ] && [ -n "$p2s" ] || return 1
    m=$(ab_read_hex "$1" $((p2s * 512)) 4)
    [ "$m" = "68737173" ] || return 1      # "hsqs"
    echo "$p1s $p1n $p2s $p2n"
}
