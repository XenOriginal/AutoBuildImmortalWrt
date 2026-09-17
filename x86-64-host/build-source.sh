#!/bin/bash
# ============================================================================
# ImmortalWrt 源码编译  ——  宿主机专属固件
# 机型: Inspur AliMoC-MD-02-25G  (x86/64)
#
# 与 ImageBuilder 方案的区别:
#   ImageBuilder 只能安装官方 feed 中【已有】的二进制包, 无法新增内核驱动。
#   本脚本走完整源码编译, 因此可以:
#     1. 启用 CONFIG_CRYPTO_DEV_QAT_* —— Intel QAT DH895XCC 硬件加速
#     2. 任意增删内核配置与软件包
#
# 注意: 源码编译耗时远长于 ImageBuilder (首次约 1.5-3 小时)。
# ============================================================================
set -euo pipefail

SRC_DIR="/work/immortalwrt"
REPO_URL="https://github.com/immortalwrt/immortalwrt.git"
REPO_BRANCH="${IMM_BRANCH:-openwrt-25.12}"
LOG="$SRC_DIR/build-host.log"

# 为 set -u 提供默认值, 避免未传入时直接终止
PROFILE="${PROFILE:-1024}"
INCLUDE_DOCKER="${INCLUDE_DOCKER:-yes}"
ENABLE_PPPOE="${ENABLE_PPPOE:-no}"
PPPOE_ACCOUNT="${PPPOE_ACCOUNT:-}"
PPPOE_PASSWORD="${PPPOE_PASSWORD:-}"

echo "============================================================"
echo " ImmortalWrt 源码编译 - 宿主机专属"
echo " 分支     : $REPO_BRANCH"
echo " 固件大小 : ${PROFILE} MB"
echo " Docker   : ${INCLUDE_DOCKER}"
echo " 并发编译 : $(nproc) 线程"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. 拉取源码
# ---------------------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
    echo ">>> 克隆 ImmortalWrt 源码 (浅克隆以节省时间)..."
    git clone --depth=1 -b "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
else
    echo ">>> 源码目录已存在, 复用"
fi
cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# 2. 注入自定义 QAT 包
# ---------------------------------------------------------------------------
echo ">>> 注入 QAT 驱动包与固件包..."
mkdir -p package/qat
cp -r /host-qat/qat-kmod    package/qat/
cp -r /host-qat/qat-firmware package/qat/
echo "--- package/qat 内容 ---"
find package/qat -type f | sort

# ---------------------------------------------------------------------------
# 3. feeds
# ---------------------------------------------------------------------------
echo ">>> 更新 feeds..."
cp -f /host-config/feeds.conf.default feeds.conf.default 2>/dev/null || true
./scripts/feeds update -a
./scripts/feeds install -a

# ---------------------------------------------------------------------------
# 4. 应用 .config
# ---------------------------------------------------------------------------
echo ">>> 应用内核/软件包配置..."
cp -f /host-config/host.config .config

# ---------------------------------------------------------------------------
# 重要 —— 关于内核符号 CONFIG_CRYPTO_DEV_QAT_*
#
#   【不要】把内核符号直接追加到 .config!
#   ImageBuilder 生成的 .config 不含内核源码树, make defconfig 会把这些
#   "未知符号"当作垃圾清除。实测 (run #1): 追加 4 个内核符号 + 3 个包符号,
#   defconfig 后内核符号【全部消失】, 只剩 3 个 CONFIG_PACKAGE_*。
#
#   正确做法: 内核符号由 KernelPackage 的 KCONFIG:= 字段声明, OpenWrt
#   构建系统会在编译内核时自动写入并生效。见 qat-src/qat-kmod/Makefile。
# ---------------------------------------------------------------------------
# 仅追加【软件包】符号 (这些会被 defconfig 保留)
cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-crypto-qat-common=m
CONFIG_PACKAGE_kmod-crypto-qat-dh895xcc=m
CONFIG_PACKAGE_qat-firmware-dh895xcc=m
EOF

# 自动接受新增符号的默认值
make defconfig >>"$LOG" 2>&1

echo "--- QAT 相关最终配置 (软件包层) ---"
grep -iE "QAT" .config || echo "(警告: 未在 .config 中找到 QAT 配置)"

# 校验【软件包】符号 (内核符号由 KernelPackage KCONFIG 保证, 不在此校验)
missing=0
for sym in CONFIG_PACKAGE_kmod-crypto-qat-common \
           CONFIG_PACKAGE_kmod-crypto-qat-dh895xcc \
           CONFIG_PACKAGE_qat-firmware-dh895xcc; do
    val=$(grep -E "^${sym}=" .config | head -1 | cut -d= -f2)
    if [ "$val" != "m" ]; then
        echo "!!! 错误: $sym 期望 'm', 实际 '${val:-未设置}'"
        missing=1
    else
        echo "  OK: $sym=$val"
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "!!! QAT 软件包未正确选中, 终止"
    grep -i qat .config || echo "(调试: .config 中无 qat 相关行)"
    exit 1
fi

echo "--- 确认内核符号已由 KCONFIG 声明 ---"
grep -E "CONFIG_CRYPTO_DEV_QAT_DH895" package/qat/qat-kmod/Makefile

# ---------------------------------------------------------------------------
# 5. 下载源码包
#    【注意】日志必须同时打到 stdout, 否则容器销毁后无法排错。
# ---------------------------------------------------------------------------
echo ">>> 下载依赖源码 (多线程)..."
if ! make download -j"$(nproc)" 2>&1 | tee -a "$LOG"; then
    echo ">>> 多线程下载失败, 改用单线程 + 详细输出重试..."
    if ! make download -j1 V=s 2>&1 | tee -a "$LOG"; then
        echo "!!! 下载依赖失败, 最后 60 行:"
        tail -60 "$LOG"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 6. 编译
# ---------------------------------------------------------------------------
# 注入根文件系统分区大小 (对应工作流的 profile 输入)
sed -i "/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d" .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=${PROFILE}" >> .config

# 注入 Docker 开关
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    for p in CONFIG_PACKAGE_dockerd CONFIG_PACKAGE_docker CONFIG_PACKAGE_docker-compose \
             CONFIG_PACKAGE_containerd CONFIG_PACKAGE_runc \
             CONFIG_PACKAGE_luci-app-dockerman CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn; do
        sed -i "/^${p}=/d" .config
        echo "${p}=y" >> .config
    done
    echo ">>> Docker 已启用"
fi

make defconfig >>"$LOG" 2>&1

echo ">>> ROOTFS_PARTSIZE = $(grep '^CONFIG_TARGET_ROOTFS_PARTSIZE=' .config | cut -d= -f2)"

echo ">>> 开始编译 (日志: $LOG)..."
if ! make -j"$(nproc)" V=s 2>&1 | tee -a "$LOG"; then
    echo "!!! 编译失败, 最后 150 行日志:"
    tail -150 "$LOG"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. 产物
# ---------------------------------------------------------------------------
echo ">>> 编译完成, 产物列表:"
ls -lah bin/targets/x86/64/ 2>/dev/null || true

# 校验 QAT 模块确实被编译进产物
echo ">>> 校验 QAT 内核模块:"
find bin/ -name "*qat*" 2>/dev/null || echo "(未找到 qat 文件)"

# ---------------------------------------------------------------------------
# 8. 把产物复制到挂载点 /work/bin —— 容器销毁后仍可被 upload-artifact 取到
#    (/work 是宿主机 $PWD 的挂载点; SRC_DIR 在容器可写层, 必须显式复制出来)
# ---------------------------------------------------------------------------
echo ">>> 复制产物到 /work/bin ..."
mkdir -p /work/bin
cp -a bin/. /work/bin/ 2>/dev/null || cp -a bin/* /work/bin/ 2>/dev/null || true
echo "--- /work/bin 内容 ---"
ls -lah /work/bin/targets/x86/64/ 2>/dev/null | head -30 || echo "(复制失败)"

# 同时导出最终 .config 与 QAT 内核配置, 便于复核
cp -f .config /work/host-final.config 2>/dev/null || true
echo ">>> 完成"
