#!/bin/bash
# ============================================================================
# QAT 内核模块独立编译 —— 使用官方 SDK
#
# 【设计思路】
#   之前的方案走"全量源码编译", 每轮 30-50 分钟且反复卡在内核 syncconfig。
#   实际上只有 QAT 驱动是官方库里【没有现成编译好的】, 其余全部可以用
#   ImageBuilder 的现成二进制包。
#
#   因此改为:
#     1. 用官方 SDK 单独编译 QAT 模块 → 产出 .apk
#     2. 用官方 ImageBuilder + 现成包做固件, 把 QAT 的 .apk 作为额外包塞进去
#
#   这样每轮只要 10-15 分钟, 且完全绕开内核 syncconfig 问题。
#
# 【版本匹配】
#   官方 25.12.1 SDK        → 内核 6.12.94
#   官方 25.12.1 ImageBuilder → 内核 6.12.94
#   两者 vermagic 一致, 模块可直接装载。
# ============================================================================
set -euo pipefail

export FORCE_UNSAFE_CONFIGURE=1

WORK=/work
SDK_DIR="$WORK/sdk"
OUT_DIR="$WORK/out"

IMM_VERSION="${IMM_VERSION:-25.12.1}"
ARCH="${ARCH:-x86-64}"

echo "============================================================"
echo " QAT 模块独立编译 (SDK 方案)"
echo " ImmortalWrt 版本 : $IMM_VERSION"
echo " 目标架构         : $ARCH"
echo "============================================================"

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. 下载并解压 SDK
# ---------------------------------------------------------------------------
SDK_FILE="immortalwrt-sdk-${IMM_VERSION}-${ARCH}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_URL="https://downloads.immortalwrt.org/releases/${IMM_VERSION}/targets/x86/64/${SDK_FILE}"

if [ ! -d "$SDK_DIR" ]; then
    echo ">>> 下载 SDK: $SDK_FILE"
    wget -q --show-progress -O "$WORK/sdk.tar.zst" "$SDK_URL"

    echo ">>> 解压 SDK..."
    mkdir -p "$SDK_DIR"
    # zstd + tar; 兼容不同 tar 版本
    if command -v zstd >/dev/null 2>&1; then
        tar --use-compress-program=unzstd -xf "$WORK/sdk.tar.zst" -C "$SDK_DIR" --strip-components=1
    else
        tar -I zstd -xf "$WORK/sdk.tar.zst" -C "$SDK_DIR" --strip-components=1
    fi
    rm -f "$WORK/sdk.tar.zst"
fi
echo ">>> SDK 就绪: $(ls "$SDK_DIR" | head -5 | tr '\n' ' ')"

cd "$SDK_DIR"

# ---------------------------------------------------------------------------
# 2. 注入 QAT 包
# ---------------------------------------------------------------------------
echo ">>> 注入 QAT 包..."
mkdir -p package/qat
cp -r /host-qat/qat-kmod     package/qat/
cp -r /host-qat/qat-firmware package/qat/
find package/qat -type f | sort

# ---------------------------------------------------------------------------
# 3. 更新 feeds 并选择 QAT 包
# ---------------------------------------------------------------------------
echo ">>> 更新 feeds..."
./scripts/feeds update -a >/dev/null 2>&1
./scripts/feeds install -a >/dev/null 2>&1

echo ">>> 配置 QAT 包..."
cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-crypto-qat-common=m
CONFIG_PACKAGE_kmod-crypto-qat-dh895xcc=m
CONFIG_PACKAGE_qat-firmware-dh895xcc=m
EOF

# SDK 的 defconfig 会处理依赖
make defconfig >/dev/null 2>&1

echo "=== QAT 相关配置 ==="
grep -iE "QAT" .config || { echo "!!! QAT 未进入配置"; exit 1; }

# 校验三个包都被选中
for sym in CONFIG_PACKAGE_kmod-crypto-qat-common \
           CONFIG_PACKAGE_kmod-crypto-qat-dh895xcc \
           CONFIG_PACKAGE_qat-firmware-dh895xcc; do
    val=$(grep -E "^${sym}=" .config | head -1 | cut -d= -f2)
    echo "  $sym = ${val:-未设置}"
    [ "$val" = "m" ] || { echo "!!! $sym 期望 m"; exit 1; }
done

# ---------------------------------------------------------------------------
# 4. 编译
# ---------------------------------------------------------------------------
echo ">>> 开始编译 QAT 模块..."
make -j"$(nproc)" V=s 2>&1 | tail -60

echo
echo "=== 编译产物 (.apk) ==="
find bin/ -name "*.apk" | sort | while read -r f; do
    echo "  $(basename "$f")  ($(du -h "$f" | cut -f1))"
done

# ---------------------------------------------------------------------------
# 5. 收集产物
# ---------------------------------------------------------------------------
echo ">>> 收集产物到 $OUT_DIR ..."
mkdir -p "$OUT_DIR/packages"
find bin/ -name "*qat*.apk" -exec cp -v {} "$OUT_DIR/packages/" \;

echo
echo "=== 最终产物 ==="
ls -lah "$OUT_DIR/packages/" || echo "(无产物)"

# 校验 QAT 驱动模块确实被编译
echo
echo "=== 校验内核模块内容 ==="
for apk in "$OUT_DIR/packages/"*qat*.apk; do
    [ -e "$apk" ] || continue
    echo "--- $(basename "$apk") ---"
    tar tzf "$apk" 2>/dev/null | head -20 || \
        (mkdir -p /tmp/x && cd /tmp/x && tar xzf "$apk" 2>/dev/null && find . -name "*.ko" | head)
done
