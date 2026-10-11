#!/bin/sh
# ============================================================================
# A/B 双槽布局安装器  (ab-layout.sh)
#
# 在一块【空盘】上铺设单盘 A/B 布局 (分区按创建顺序编号):
#
#   p1  BOOT_MIB   /boot (vfat)   LABEL=kernel: grub.cfg/grubenv/vmlinuz.a/.b
#   p2  1 MiB      BIOS boot      Legacy GRUB core.img (bios_grub)
#   p3  SLOT_MIB   槽 A rootfs    squashfs (dd 自镜像 p2); overlay 由系统在分区剩余空间内建立
#   p4  SLOT_MIB   槽 B rootfs    同上; 初始与 A 完全一致 (开局就有回滚目标)
#   p5  其余       /Lager (ext4)  LABEL=LAGER2; 升级永不触碰
#
# 【overlay 说明】OpenWrt x86 对 squashfs 根固定使用"根分区内 loop overlay",
#   独立 rootfs_data 分区不会被采用 (两次对照实验证实, 见 README 第五节)。
#   因此默认 per-slot: 两槽各自持有 overlay, 升级时由 ab-upgrade 迁移配置 ——
#   这比共享 overlay 更安全: 回滚时旧槽连配置一起回退。
#   --overlay-mode shared 仅保留用于复现实验, 不要用于生产。
#
# 【为什么 /boot 必须是 p1】官方 core.img 内嵌的 early config 是
#     configfile (hd0,gpt1)/boot/grub/grub.cfg
#   (取自 package/boot/grub2/files/grub-early.cfg, 构建时经 s#msdos1#gpt1# 替换)
#   即【硬编码从分区 1 加载 grub.cfg】。把 /boot 放到别的分区号, 真实部署
#   (使用镜像自带 core.img) 会直接起不来 —— 演练前实测发现。
#
# 设计依据/回滚语义见同目录 README.md。
#
# 【安全底线】
#   1. 目标盘不能是当前系统盘; 2. 目标盘不能有分区被挂载; 3. 必须显式 --yes;
#   4. 只写目标盘, 不碰其它盘。
#
# 用法:
#   ab-layout.sh --disk /dev/sda --image immortalwrt-x86-64-...-combined.img[.gz] --yes
#   可选: --core-img <内嵌 loadenv 的 core.img>  (镜像自带 core.img 未打补丁时必须给)
#         --overlay-mode shared|per-slot  --boot-mib 512  --slot-mib 2048
#         --overlay-mib 16384  --data-mib 0(=吃完剩余)  --bootopts "..."  --timeout 3
#
# 实测要点 (2026-10-11):
#   - GPT 下 `parted -m unit s print` 字段: num:start:end:size:fs:NAME:flags
#   - 目标机的 losetup 是 busybox 版(无 -P), 故文件镜像需 losetup + partx -a
#   - 镜像 p1 挂载用 loop+offset (busybox mount 支持)
# ============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPL="$SCRIPT_DIR/grub.cfg.ab.tmpl"

DISK=""; IMAGE=""; CORE_IMG=""; OVERLAY_MODE="per-slot"
BOOT_MIB=512; SLOT_MIB=2048; OVERLAY_MIB=16384; DATA_MIB=0
BOOTOPTS="console=tty1 console=ttyS0,115200n8 intel_iommu=on iommu=pt"
GRUB_TIMEOUT=3; GRUB_BAUD=57600; ASSUME_YES=0
MNT=/tmp/ab-layout.mnt; WORK=/tmp/ab-layout.work

log() { echo ">>> $*"; }
die() { echo "!!! $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --disk) DISK="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --core-img) CORE_IMG="$2"; shift 2 ;;
        --overlay-mode) OVERLAY_MODE="$2"; shift 2 ;;
        --boot-mib) BOOT_MIB="$2"; shift 2 ;;
        --slot-mib) SLOT_MIB="$2"; shift 2 ;;
        --overlay-mib) OVERLAY_MIB="$2"; shift 2 ;;
        --data-mib) DATA_MIB="$2"; shift 2 ;;
        --bootopts) BOOTOPTS="$2"; shift 2 ;;
        --timeout) GRUB_TIMEOUT="$2"; shift 2 ;;
        --baud) GRUB_BAUD="$2"; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -n "$DISK" ] || die "缺少 --disk"
[ -n "$IMAGE" ] || die "缺少 --image"
[ -f "$IMAGE" ] || die "镜像不存在: $IMAGE"
[ -e "$DISK" ] || die "目标盘不存在: $DISK"
[ -f "$TMPL" ] || die "缺少引导模板: $TMPL"
case "$OVERLAY_MODE" in shared|per-slot) ;; *) die "--overlay-mode 只能是 shared/per-slot" ;; esac
[ "$ASSUME_YES" = 1 ] || die "破坏性操作(会清空 $DISK), 确认后加 --yes"

# ---------------------------------------------------------------------------
# 0. 安全检查
# ---------------------------------------------------------------------------
ROOT_SRC=$(awk '$2=="/" {print $1; exit}' /proc/mounts 2>/dev/null || echo "")
case "$DISK" in
    /dev/loop*|/dev/ram*) log "目标为 loop/ram 设备 -> 演练模式" ;;
    *)
        if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
            ROOT_DISK=$(echo "$ROOT_SRC" | sed -e 's/p\?[0-9]*$//')
            [ "$ROOT_DISK" = "$DISK" ] && die "目标盘即当前系统盘 ($ROOT_SRC), 拒绝"
        fi
        grep -q "^$DISK" /proc/mounts && die "目标盘有分区被挂载, 拒绝"
        ;;
esac

DISK_BYTES=0
if [ -r "/sys/class/block/$(basename "$DISK")/size" ]; then
    DISK_BYTES=$(( $(cat "/sys/class/block/$(basename "$DISK")/size") * 512 ))
else
    DISK_BYTES=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    [ "$DISK_BYTES" -gt 0 ] || DISK_BYTES=$(( $(blockdev --getsz "$DISK" 2>/dev/null || echo 0) * 512 ))
fi
[ "$DISK_BYTES" -gt 0 ] || die "无法读取 $DISK 容量"
DISK_MIB=$((DISK_BYTES / 1048576))
NEED_MIB=$((2 + BOOT_MIB + SLOT_MIB * 2 + OVERLAY_MIB + 64))
log "目标盘 $DISK = ${DISK_MIB} MiB ; 布局至少需要 ${NEED_MIB} MiB"
[ "$DISK_MIB" -ge "$NEED_MIB" ] || die "目标盘太小"

# ---------------------------------------------------------------------------
# 1. 准备镜像 (支持 .gz) + 解析分区表
# ---------------------------------------------------------------------------
mkdir -p "$WORK" "$MNT"
IMG="$IMAGE"
case "$IMAGE" in
    *.gz) log "解压镜像 (gz)..."; IMG="$WORK/image.img"; gzip -dc "$IMAGE" > "$IMG" ;;
    *.xz) log "解压镜像 (xz)..."; IMG="$WORK/image.img"; xz -dc "$IMAGE" > "$IMG" ;;
esac
log "解析镜像分区表: $IMG"
IMG_SPEC=$(parted -s -m "$IMG" unit s print 2>/dev/null | awk -F: '/^[0-9]+:/{print $1" "$2" "$4}') || true
[ -n "$IMG_SPEC" ] || die "无法解析镜像分区表"
IMG_P1_START=$(echo "$IMG_SPEC" | awk '$1==1{print $2}' | tr -d 's')
IMG_P1_SIZE=$(echo "$IMG_SPEC" | awk '$1==1{print $3}' | tr -d 's')
IMG_P2_START=$(echo "$IMG_SPEC" | awk '$1==2{print $2}' | tr -d 's')
IMG_P2_SIZE=$(echo "$IMG_SPEC" | awk '$1==2{print $3}' | tr -d 's')
[ -n "$IMG_P1_START" ] && [ -n "$IMG_P2_START" ] || die "镜像缺少 p1/p2"
log "  镜像 p1 start=${IMG_P1_START}s size=${IMG_P1_SIZE}s ; p2 start=${IMG_P2_START}s size=${IMG_P2_SIZE}s"

# ---------------------------------------------------------------------------
# 2. 分区 (创建顺序 = 分区号)
# ---------------------------------------------------------------------------
log "写入 GPT 分区表..."
umount "$MNT" 2>/dev/null || true
parted -s "$DISK" mklabel gpt

# p1: /boot —— 分区号必须是 1 (官方 core.img early config 硬编码 gpt1),
#     物理位置从 2MiB 起, 把最前面 1MiB 让给 BIOS boot 分区 (同 OpenWrt 自身布局)
b_start=2
b_end=$((b_start + BOOT_MIB))
parted -s "$DISK" mkpart BOOT fat32 "${b_start}MiB" "${b_end}MiB"
parted -s "$DISK" set 1 boot on
parted -s "$DISK" set 1 esp on

# p2: BIOS boot (core.img 落点), 位于物理最前
parted -s "$DISK" mkpart BIOSBOOT 1MiB 2MiB
parted -s "$DISK" set 2 bios_grub on

# p3/p4: 两个槽
a_start=$b_end; a_end=$((a_start + SLOT_MIB))
parted -s "$DISK" mkpart SLOT_A ext4 "${a_start}MiB" "${a_end}MiB"
b2_start=$a_end; b2_end=$((b2_start + SLOT_MIB))
parted -s "$DISK" mkpart SLOT_B ext4 "${b2_start}MiB" "${b2_end}MiB"

# p5: 共享 overlay (仅 shared 模式)
if [ "$OVERLAY_MODE" = "shared" ]; then
    o_start=$b2_end; o_end=$((o_start + OVERLAY_MIB))
    parted -s "$DISK" mkpart ROOTFS_DATA ext4 "${o_start}MiB" "${o_end}MiB"
    d_start=$o_end
else
    d_start=$b2_end
fi

# 数据分区: 吃掉剩余空间
if [ "$DATA_MIB" = "0" ]; then
    parted -s "$DISK" mkpart LAGER ext4 "${d_start}MiB" 100%
else
    parted -s "$DISK" mkpart LAGER ext4 "${d_start}MiB" "$((d_start + DATA_MIB))MiB"
fi

sync
blockdev --rereadpt "$DISK" 2>/dev/null || true
partx -a "$DISK" >/dev/null 2>&1 || partx -a - "$DISK" >/dev/null 2>&1 || true
sleep 1

partdev() { # $1=disk $2=num
    for cand in "$1p$2" "$1$2"; do
        [ -b "$cand" ] && { echo "$cand"; return 0; }
    done
    partx -a "$1" >/dev/null 2>&1 || true
    sleep 1
    for cand in "$1p$2" "$1$2"; do
        [ -b "$cand" ] && { echo "$cand"; return 0; }
    done
    return 1
}

DEV_BOOT=$(partdev "$DISK" 1) || die "找不到 p1 (BOOT) 设备"
DEV_BIOS=$(partdev "$DISK" 2) || true
DEV_A=$(partdev "$DISK" 3) || die "找不到 p3 (SLOT_A) 设备"
DEV_B=$(partdev "$DISK" 4) || die "找不到 p4 (SLOT_B) 设备"
if [ "$OVERLAY_MODE" = "shared" ]; then
    DEV_OVL=$(partdev "$DISK" 5) || die "找不到 p5 (ROOTFS_DATA) 设备"
    DEV_DATA=$(partdev "$DISK" 6) || true
else
    DEV_OVL=""; DEV_DATA=$(partdev "$DISK" 5) || true
fi
log "  设备: boot=$DEV_BOOT slotA=$DEV_A slotB=$DEV_B overlay=${DEV_OVL:-无} data=${DEV_DATA:-无}"

# ---------------------------------------------------------------------------
# 3. 格式化
# ---------------------------------------------------------------------------
log "格式化 p2/p5/p6..."
mkfs.fat -n kernel -F 32 "$DEV_BOOT" >/dev/null 2>&1 || die "mkfs.fat 失败"
if [ -n "$DEV_DATA" ]; then
    mkfs.ext4 -L LAGER2 -F "$DEV_DATA" >/dev/null 2>&1 || mkfs.ext4 -L LAGER2 "$DEV_DATA" >/dev/null 2>&1 || log "  (数据分区格式化失败, 可后续手工处理)"
fi
if [ -n "$DEV_OVL" ]; then
    mkfs.f2fs -l rootfs_data -f "$DEV_OVL" >/dev/null 2>&1 || mkfs.f2fs -l rootfs_data "$DEV_OVL" >/dev/null 2>&1 || die "mkfs.f2fs 失败"
fi

# ---------------------------------------------------------------------------
# 4. 铺系统
# ---------------------------------------------------------------------------
log "挂载镜像 p1 取内核与 GRUB 文件..."
mounted=0
for t in vfat ext4 auto; do
    if mount -t "$t" -o loop,ro,offset=$((IMG_P1_START * 512)) "$IMG" "$MNT" 2>/dev/null; then mounted=1; break; fi
done
[ "$mounted" = 1 ] || die "挂载镜像 p1 失败"
[ -f "$MNT/boot/vmlinuz" ] || die "镜像 p1 无 /boot/vmlinuz"
cp "$MNT/boot/vmlinuz" "$WORK/vmlinuz"
for f in boot.img core.img; do [ -f "$MNT/boot/grub/$f" ] && cp "$MNT/boot/grub/$f" "$WORK/$f"; done
umount "$MNT"
[ -f "$WORK/boot.img" ] || die "镜像里没有 grub boot.img"
if [ -n "$CORE_IMG" ]; then
    [ -f "$CORE_IMG" ] || die "--core-img 不存在: $CORE_IMG"
    cp "$CORE_IMG" "$WORK/core.img"
    log "  使用外部 core.img (需已内嵌 loadenv): $CORE_IMG"
fi

log "写 rootfs 到两个槽 (镜像 p2 = squashfs)..."
for dev in "$DEV_A" "$DEV_B"; do
    dd if="$IMG" of="$dev" bs=512 skip="$IMG_P2_START" count="$IMG_P2_SIZE" conv=fsync 2>/dev/null \
        || die "写 rootfs 到 $dev 失败"
    log "  $dev <- p2 (${IMG_P2_SIZE} 扇区)"
done

log "布置 /boot (内核 a/b + grub.cfg + grubenv)..."
mount -t vfat "$DEV_BOOT" "$MNT" || die "挂载 $DEV_BOOT 失败"
mkdir -p "$MNT/boot/grub"
cp "$WORK/vmlinuz" "$MNT/boot/vmlinuz.a"
cp "$WORK/vmlinuz" "$MNT/boot/vmlinuz.b"
cp "$WORK/boot.img" "$MNT/boot/grub/boot.img"
cp "$WORK/core.img" "$MNT/boot/grub/core.img"

PU_A=$(blkid -s PARTUUID -o value "$DEV_A" 2>/dev/null || true)
PU_B=$(blkid -s PARTUUID -o value "$DEV_B" 2>/dev/null || true)
[ -n "$PU_A" ] && [ -n "$PU_B" ] || die "无法取得槽 PARTUUID (需要 blkid)"
log "  槽 A PARTUUID=$PU_A ; 槽 B PARTUUID=$PU_B"

sed -e "s|@@PARTUUID_A@@|$PU_A|g" -e "s|@@PARTUUID_B@@|$PU_B|g" \
    -e "s|@@BOOTOPTS@@|$BOOTOPTS|g" -e "s|@@TIMEOUT@@|$GRUB_TIMEOUT|g" \
    -e "s|@@BAUD@@|$GRUB_BAUD|g" \
    "$TMPL" > "$MNT/boot/grub/grub.cfg"

if command -v grub-editenv >/dev/null 2>&1; then
    grub-editenv "$MNT/boot/grub/grubenv" create
    grub-editenv "$MNT/boot/grub/grubenv" set boot_ok=1 bootcount=0
    log "  grubenv: boot_ok=1 bootcount=0 (槽 A 已知良好)"
else
    log "  ⚠️ 无 grub-editenv: 未初始化 grubenv (则没有自动回滚)"
fi
umount "$MNT"

log "安装 GRUB (MBR + BIOS boot 分区)..."
mount -t vfat "$DEV_BOOT" "$MNT" || die "挂载 $DEV_BOOT 失败(2)"
echo "(hd0) $DISK" > "$WORK/device.map"
grub-bios-setup -m "$WORK/device.map" -d "$MNT/boot/grub" -r "hd0,gpt1" "$DISK" || die "grub-bios-setup 失败"
umount "$MNT"

sync
log "完成。布局:"
parted -s -m "$DISK" unit MiB print 2>/dev/null | awk -F: '/^[0-9]+:/{printf "    p%s  %9s MiB  %-12s %s\n", $1, $4, $6, $7}'
echo
echo "下一步: 1) BIOS 设该盘为第一启动项  2) 起来后 cat /proc/cmdline 确认槽  3) ab-upgrade <新镜像>"
