#!/bin/sh
# ============================================================================
# 数据迁移: /Lager (U 盘 sdb4) -> SSD 数据分区
#
# 【为什么要分两轮】
#   /Lager 里有正在运行的 Docker overlay2 (写得很频繁)。一次性停服务拷贝
#   会让停机时间等于全量拷贝时间 (~41GB, U 盘读 ~17MB/s -> 40 分钟以上)。
#   正确做法是分两轮:
#       --seed   在线首轮 (服务不停) 把大头先搬过去
#       --final  停写后增量补齐 + 校验 (通常只需几分钟) -> 再切换
#
# 【安全约束】
#   1. 源与目标必须是不同设备; 2. 目标不能是当前系统盘;
#   3. --seed 不加 --delete (源在变); --final 才 --delete (源已停写, 删除同步才正确)
#   4. 任何一步失败都不动源数据 —— 拷贝是单向的, 切换是独立步骤。
#
# 用法:
#   migrate-data.sh --target /dev/sda5 --seed
#   migrate-data.sh --target /dev/sda5 --final          # 会自动停/起 dockerd
#   migrate-data.sh --target /dev/sda5 --verify         # 只报告差异, 不改动
#
# 限速(避免抢占在线业务的 I/O):
#   --bwlimit N     KB/s, 0=不限; 默认 seed/verify=8000(8MB/s), final=0
#   也可用环境变量 BWLIMIT_SEED / BWLIMIT_FINAL / BWLIMIT_VERIFY 调整
#
# 目标挂载点: /mnt/lager-new
# ============================================================================
set -eu

SRC=${SRC:-/Lager}
MNT=${MNT:-/mnt/lager-new}
TARGET=""
MODE=""
STOP_SERVICES=${STOP_SERVICES:-"dockerd containerd"}
ASSUME=0
# 【限速默认值】KB/s; 0=不限
#   seed  : 在线首轮, 服务在跑 -> 默认 8 MB/s, 把 U 盘带宽留给 Docker/NFS
#   final : 已停写 -> 不限, 尽快做完减少停机
#   verify: 只读比较 -> 与 seed 同档, 避免校验本身又抢占
BWLIMIT_SEED=${BWLIMIT_SEED:-8000}
BWLIMIT_FINAL=${BWLIMIT_FINAL:-0}
BWLIMIT_VERIFY=${BWLIMIT_VERIFY:-8000}
BWLIMIT=""   # --bwlimit 显式覆盖(优先级最高)
LOG=${LOG:-/tmp/migrate-data.log}

log()  { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
die()  { echo "!!! $*" >&2; echo "$(date '+%F %T') !!! $*" >> "$LOG"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --src) SRC="$2"; shift 2 ;;
        --seed) MODE=seed; shift ;;
        --final) MODE=final; shift ;;
        --verify) MODE=verify; shift ;;
        --bwlimit) BWLIMIT="$2"; shift 2 ;;
        --yes) ASSUME=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done
[ -n "$TARGET" ] || die "缺少 --target <数据分区设备>"
[ -n "$MODE" ] || die "必须指定 --seed | --final | --verify"
[ -b "$TARGET" ] || die "目标设备不存在: $TARGET"
[ -d "$SRC" ] || die "源目录不存在: $SRC"
command -v rsync >/dev/null 2>&1 || die "缺少 rsync (可执行: apk add rsync)"

SRC_DEV=$(awk -v s="$SRC" '$2==s{print $1; exit}' /proc/mounts)
[ -n "$SRC_DEV" ] || die "$SRC 不是挂载点 (先确认 /Lager 已挂载)"

# --- 安全: 目标不能是源所在设备, 也不能是系统盘 ---
strip_part() { # 去掉分区号 -> 整盘设备名
    local d=$1 bb pre
    case "$d" in
        *p[0-9]|*p[0-9][0-9]|*p[0-9][0-9][0-9])
            pre=${d%p*}
            case "$pre" in
                *[0-9]|*n) echo "$pre" ;;
                *) echo "$d" ;;
            esac ;;
        /dev/sd[a-z][0-9]*|/dev/hd[a-z][0-9]*|/dev/vd[a-z][0-9]*)
            bb=$d; while :; do case "$bb" in *[0-9]) bb=${bb%[0-9]} ;; *) break ;; esac; done
            echo "$bb" ;;
        *) echo "$d" ;;
    esac
}
TGT_BASE=$(strip_part "$TARGET")
SRC_BASE=$(strip_part "$SRC_DEV")
[ "$TGT_BASE" = "$SRC_BASE" ] && die "目标是源所在设备 ($SRC_BASE), 拒绝"
ROOT_DEV=$(strip_part "$(awk '$2=="/"{print $1; exit}' /proc/mounts)")
[ "$TGT_BASE" = "$ROOT_DEV" ] && die "目标是当前系统盘 ($ROOT_DEV), 拒绝"

log "=== 数据迁移: $SRC ($SRC_DEV) -> $TARGET  模式=$MODE ==="

# --- 挂载目标 ---
if grep -q " $MNT " /proc/mounts; then
    log "目标已挂载于 $MNT"
else
    mkdir -p "$MNT"
    mount "$TARGET" "$MNT" || die "挂载 $TARGET 失败"
    log "已挂载 $TARGET -> $MNT"
fi

# --whole-file: 本地拷贝不做增量算法, 顺序读写 —— 对慢速 U 盘更友好
RSYNC_OPTS="-aHAX --numeric-ids --whole-file --info=stats2"
[ "$MODE" = final ] && RSYNC_OPTS="$RSYNC_OPTS --delete"

# ---- I/O 控速 ----
# 【为什么用 --bwlimit 而不是 ionice】
#   实测本机: 没有 ionice; 且两块盘的 I/O 调度器都是 none
#   (/sys/block/sdX/queue/scheduler = [none]) —— ionice 只在 CFQ/BFQ 下有意义,
#   在 none/mq-deadline 上对吞吐几乎无影响。直接限速才是有效手段。
case "$MODE" in
    seed)   RATE=${BWLIMIT:-$BWLIMIT_SEED} ;;
    final)  RATE=${BWLIMIT:-$BWLIMIT_FINAL} ;;
    verify) RATE=${BWLIMIT:-$BWLIMIT_VERIFY} ;;
esac
BWOPT=""
if [ "${RATE:-0}" -gt 0 ] 2>/dev/null; then
    BWOPT="--bwlimit=$RATE"
fi
NICECMD=""
command -v nice >/dev/null 2>&1 && NICECMD="nice -n 19"

# 估算耗时(仅提示): 源数据量 / 速率
if [ -n "$BWOPT" ]; then
    SRC_BYTES=$(du -sb "$SRC" 2>/dev/null | awk '{print $1}')
    if [ -n "${SRC_BYTES:-}" ]; then
        ETA_MIN=$(( SRC_BYTES / 1024 / RATE / 60 ))
        log "限速: ${RATE} KB/s -> 源约 $(( SRC_BYTES / 1048576 )) MiB, 预计 ${ETA_MIN} 分钟"
    else
        log "限速: ${RATE} KB/s"
    fi
else
    log "限速: 不限 (0)"
fi


# 统一的 rsync 调用 (带限速与低优先级)
run_rsync() {
    $NICECMD rsync $RSYNC_OPTS $BWOPT "$@"
}

case "$MODE" in
    verify)
        log "差异报告 (不改动任何数据):"
        run_rsync --delete -n -i --out-format='%i %n' "$SRC/" "$MNT/" \
            | awk 'NR<=40{print} END{print "  (差异条目合计: " NR ")"}'
        log "源用量: $(du -sh "$SRC" 2>/dev/null | cut -f1) ; 目标用量: $(du -sh "$MNT" 2>/dev/null | cut -f1)"
        log "校验完毕 (差异应为 0 条目才可切换)"
        ;;

    seed)
        log "--seed: 在线首轮拷贝 (不停服务; 本轮不删目标多余文件)"
        [ "$ASSUME" = 1 ] || { printf "继续? [y/N] "; read -r a; case "$a" in y|Y) ;; *) die "已取消" ;; esac; }
        run_rsync --exclude 'docker/overlay2/*/merged' "$SRC/" "$MNT/" || die "rsync 失败"
        sync
        log "首轮完成。目标用量: $(du -sh "$MNT" 2>/dev/null | cut -f1)"
        log "下一步: 维护窗口内执行 --final"
        ;;

    final)
        log "--final: 停写 -> 增量补齐 -> 校验"
        [ "$ASSUME" = 1 ] || { printf "将停止服务(%s)并做增量同步, 继续? [y/N] " "$STOP_SERVICES"; read -r a; case "$a" in y|Y) ;; *) die "已取消" ;; esac; }
        STARTED=""
        for s in $STOP_SERVICES; do
            if [ -x "/etc/init.d/$s" ]; then /etc/init.d/$s stop && STARTED="$STARTED $s"; log "已停止 $s"; fi
        done
        sleep 5
        run_rsync "$SRC/" "$MNT/" || { log "rsync 失败, 尝试恢复服务"; for s in $STARTED; do /etc/init.d/$s start; done; die "增量同步失败"; }
        sync

        log "校验差异 (期望 0 条目):"
        DIFF=$(run_rsync -n -i --out-format='%n' "$SRC/" "$MNT/" | wc -l)
        log "  差异条目: $DIFF"

        if [ "$DIFF" -eq 0 ]; then
            log "✅ 数据已完全一致, 可以切换 (见 CUTOVER-runbook.md)"
            cat > "$MNT/.migrate-complete" <<EOF
migrated_at=$(date '+%F %T')
src_dev=$SRC_DEV
target=$TARGET
diff_items=$DIFF
EOF
        else
            log "⚠️ 仍有 $DIFF 条差异, 先不要切换"
        fi

        log "服务保持停止状态 —— 切换完成后再启动 (避免在旧盘上继续写入)"
        log "如需放弃切换: 直接 /etc/init.d/dockerd start 即可继续用旧盘"
        ;;
esac
