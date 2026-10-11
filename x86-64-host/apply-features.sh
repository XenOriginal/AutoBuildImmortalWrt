#!/bin/bash
# ============================================================================
# 编译期特性片段应用器 (feature fragment applier)
#
# 【为什么需要它】
#   宿主机固件的"编译阶段优化"此前是直接内联在 build-source.sh 里的长列表
#   (HOST_PKGS / set_kconfig)。每加一项优化都要改构建脚本主体, 无法按需开关,
#   也无法单独验收。本脚本把优化拆成可插拔片段:
#
#       x86-64-host/features/<NN>-<name>.conf      ← 片段本体 (改动只在这里)
#       x86-64-host/features/enabled.txt           ← 默认启用清单 (一行一个)
#
#   新增一项 = 新增一个片段 + 登记一行; 可选优化不登记, 需要时用
#       FEATURES=40-net-tune,50-image-slim bash build-source.sh
#   生效。构建脚本主体不再需要改动 —— 这就是"可扩展性的基础"。
#
# 【片段格式】INI 风格, 只认下列段 (以 # 开头的行是注释, 空行忽略):
#   [meta]           desc=<一句话说明>           在汇总里显示
#                    expect_pkgs=<pkg1,pkg2>     产物验收: 必须出现在 .manifest
#   [config]         OpenWrt .config 行, 形如 CONFIG_PACKAGE_xxx=y
#   [config-unset]   只写符号名, 生成 "# CONFIG_xxx is not set"
#   [kconfig]        内核 config 行, 形如 CONFIG_NET_CLS_ACT=y
#                    (写入 target/linux/x86/64/config-6.12)
#   [kconfig-unset]  只写符号名, 生成 "# CONFIG_xxx is not set"
#
# 【两条硬保证】
#   1. 幂等: 写入前先删除同名字段, 重复执行不会产生重复行。
#   2. 自校验: 写完立即回读断言。任何一行没落地就非零退出 ——
#      针对"符号拼错被 kconfig/make defconfig 静默丢弃"这一历史教训
#      (QAT 的 DH895XCC 大小写事故)。
#
# 【用法】
#   apply-features.sh --stage config  --config <SRC/.config> [--stamp <文件>]
#   apply-features.sh --stage kconfig --kconfig <target/linux/x86/64/config-6.12> \
#                     [--stamp <文件>]
#   --stamp 文件为追加写入的 TSV 戳记, 供构建脚本做产物级验收:
#       pkgs<TAB>特性名<TAB>pkg1,pkg2
#       kconf<TAB>特性名<TAB>CONFIG_X=y       (值为 n 表示要求 "# ... is not set")
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURES_DIR="${FEATURES_DIR:-$SCRIPT_DIR/features}"
ENABLED_FILE="$FEATURES_DIR/enabled.txt"

STAGE=""
CONFIG_FILE=""
KCONFIG_FILE=""
STAMP=""
FEATURE_OVERRIDE="${FEATURES:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --stage)    STAGE="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --kconfig)  KCONFIG_FILE="$2"; shift 2 ;;
        --stamp)    STAMP="$2"; shift 2 ;;
        --features) FEATURE_OVERRIDE="$2"; shift 2 ;;
        -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

case "$STAGE" in
    config)  [ -n "$CONFIG_FILE" ]  || { echo "!! stage=config 需要 --config <文件>" >&2; exit 2; } ;;
    kconfig) [ -n "$KCONFIG_FILE" ] || { echo "!! stage=kconfig 需要 --kconfig <文件>" >&2; exit 2; } ;;
    *) echo "!! 必须指定 --stage config|kconfig" >&2; exit 2 ;;
esac
[ -d "$FEATURES_DIR" ] || { echo "!! 特性目录不存在: $FEATURES_DIR" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 取片段里某个段的配置行 (去注释/空行/首尾空白)
# ---------------------------------------------------------------------------
section_lines() {
    awk -v want="$2" '
        /^[[:space:]]*\[/ {
            sec = $0
            gsub(/^[[:space:]]*\[/, "", sec); gsub(/\][[:space:]]*$/, "", sec)
            next
        }
        sec == want {
            sub(/\r$/, "")
            if ($0 ~ /^[[:space:]]*$/) next
            if ($0 ~ /^[[:space:]]*#/) next
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
        }
    ' "$1"
}

# ---------------------------------------------------------------------------
# 写入 / 取消 (幂等)
# ---------------------------------------------------------------------------
cfg_set() {
    sed -i "/^$2=/d" "$1"
    sed -i "/^#[[:space:]]*$2 is not set$/d" "$1"
    printf '%s=%s\n' "$2" "$3" >> "$1"
}
cfg_unset() {
    sed -i "/^$2=/d" "$1"
    sed -i "/^#[[:space:]]*$2 is not set$/d" "$1"
    printf '# %s is not set\n' "$2" >> "$1"
}

# ---------------------------------------------------------------------------
# 该片段是否启用 (enabled.txt 登记 或 FEATURES= 显式覆盖)
# ---------------------------------------------------------------------------
is_enabled() {
    local n="$1"
    grep -qE "^[[:space:]]*${n}[[:space:]]*(#.*)?$" "$ENABLED_FILE" 2>/dev/null && return 0
    case ",${FEATURE_OVERRIDE//[[:space:]]/}," in
        *",$n,"*) return 0 ;;
    esac
    return 1
}

echo ">>> 特性片段应用 (stage=${STAGE})"
echo "    片段目录: $FEATURES_DIR"
echo "    默认清单: $ENABLED_FILE"
[ -n "$FEATURE_OVERRIDE" ] && echo "    FEATURES 覆盖: $FEATURE_OVERRIDE"

n_applied=0
n_ops=0
fail=0

for conf in "$FEATURES_DIR"/*.conf; do
    [ -e "$conf" ] || continue
    name="$(basename "$conf" .conf)"
    desc="$(section_lines "$conf" meta | sed -n 's/^desc=//p' | head -1)"

    if ! is_enabled "$name"; then
        printf '    [未启用] %-20s %s\n' "$name" "$desc"
        continue
    fi

    ops=0
    fail_before=$fail

    if [ "$STAGE" = "config" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
                *=*) cfg_set "$CONFIG_FILE" "${l%%=*}" "${l#*=}" ;;
                *)   echo "    !! [$name/config] 缺 '=': $l" >&2; fail=1 ;;
            esac
            ops=$((ops + 1))
        done < <(section_lines "$conf" config)

        while IFS= read -r l; do
            [ -n "$l" ] || continue
            cfg_unset "$CONFIG_FILE" "$l"
            ops=$((ops + 1))
        done < <(section_lines "$conf" config-unset)

        # 回读断言
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
                *=*) grep -qxF "$l" "$CONFIG_FILE" \
                         || { echo "    !! 未落地: $l" >&2; fail=1; } ;;
                *)   echo "    !! [$name/config] 缺 '=': $l" >&2; fail=1 ;;
            esac
        done < <(section_lines "$conf" config)

        while IFS= read -r l; do
            [ -n "$l" ] || continue
            grep -qxF "# $l is not set" "$CONFIG_FILE" \
                || { echo "    !! 未落地: # $l is not set" >&2; fail=1; }
        done < <(section_lines "$conf" config-unset)

        if [ -n "$STAMP" ]; then
            pk="$(section_lines "$conf" meta | sed -n 's/^expect_pkgs=//p' | head -1)"
            [ -n "$pk" ] && printf 'pkgs\t%s\t%s\n' "$name" "$pk" >> "$STAMP"
        fi

    else
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
                *=*) cfg_set "$KCONFIG_FILE" "${l%%=*}" "${l#*=}" ;;
                *)   echo "    !! [$name/kconfig] 缺 '=': $l" >&2; fail=1 ;;
            esac
            ops=$((ops + 1))
        done < <(section_lines "$conf" kconfig)

        while IFS= read -r l; do
            [ -n "$l" ] || continue
            cfg_unset "$KCONFIG_FILE" "$l"
            ops=$((ops + 1))
        done < <(section_lines "$conf" kconfig-unset)

        # 回读断言 + 戳记 (供构建脚本在最终内核 .config 上复验)
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
                *=*)
                    grep -qxF "$l" "$KCONFIG_FILE" \
                        || { echo "    !! 未落地: $l" >&2; fail=1; }
                    [ -n "$STAMP" ] && printf 'kconf\t%s\t%s\n' "$name" "$l" >> "$STAMP"
                    ;;
                *)   echo "    !! [$name/kconfig] 缺 '=': $l" >&2; fail=1 ;;
            esac
        done < <(section_lines "$conf" kconfig)

        while IFS= read -r l; do
            [ -n "$l" ] || continue
            grep -qxF "# $l is not set" "$KCONFIG_FILE" \
                || { echo "    !! 未落地: # $l is not set" >&2; fail=1; }
            [ -n "$STAMP" ] && printf 'kconf\t%s\t%s=n\n' "$name" "$l" >> "$STAMP"
        done < <(section_lines "$conf" kconfig-unset)
    fi

    if [ "$fail" -eq "$fail_before" ]; then
        printf '    [已应用] %-20s %-44s %2d 项\n' "$name" "$desc" "$ops"
        n_applied=$((n_applied + 1))
    else
        printf '    [失败  ] %-20s %-44s %2d 项\n' "$name" "$desc" "$ops"
    fi
    n_ops=$((n_ops + ops))
done

echo "    合计: ${n_applied} 个特性 / ${n_ops} 项配置"
if [ "$fail" -ne 0 ]; then
    echo "!!! 特性片段应用存在未落地项 —— 拒绝继续 (防静默丢弃)"
    exit 1
fi
