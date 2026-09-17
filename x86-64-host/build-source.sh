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

# GNU tar 等工具的 configure 会拒绝以 root 身份运行 (容器内是 root),
# 必须显式跳过该检查, 否则 tools/tar 构建失败。
export FORCE_UNSAFE_CONFIGURE=1

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
#
# 【关键教训 — run #5 失败原因】
#   ImageBuilder 导出的 host.config 不能直接用于源码编译!
#   它的内核符号不完整, 导致 Linux 内核回退到上游
#   arch/x86/configs/x86_64_defconfig, 出现 3174 个全新符号,
#   oldconfig 进入交互式提问并卡死:
#       RFC 7919 FFDHE groups (CRYPTO_DH_RFC7919_GROUPS) [N/y/?] (NEW)
#       make[8]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
#
#   正确做法: 让 OpenWrt 自己生成目标基线配置 (它会合并
#   target/linux/x86/config-6.12 与内核 KCONFIG 声明),
#   再把我们的个性化选项叠加其上。
# ---------------------------------------------------------------------------
echo ">>> 生成目标基线配置 (x86/64)..."

# 4.1 先写入最小 seed, 让 OpenWrt 生成完整的目标配置
cat > .config <<'SEED'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_SUBTARGET="64"
CONFIG_TARGET_PROFILE="generic"
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_x86_64_DEVICE_generic=y
SEED

make defconfig >>"$LOG" 2>&1

# 4.2 叠加个性化选项
echo ">>> 叠加宿主机个性化选项..."

# ---- 版本信息 ----
sed -i "/^CONFIG_VERSION_REPO=/d" .config
echo 'CONFIG_VERSION_REPO="https://downloads.immortalwrt.org/releases/25.12.1"' >> .config

# ---- 根文件系统大小 ----
sed -i "/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d" .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=${PROFILE}" >> .config

# ---- 宿主机必备软件包 ----
HOST_PKGS="
CONFIG_PACKAGE_kmod-mlx5-core=y
CONFIG_PACKAGE_kmod-mlxfw=y
CONFIG_PACKAGE_kmod-ixgbe=y
CONFIG_PACKAGE_kmod-ixgbevf=y
CONFIG_PACKAGE_kmod-i40e=y
CONFIG_PACKAGE_kmod-e1000e=y
CONFIG_PACKAGE_kmod-r8125=y
CONFIG_PACKAGE_kmod-tg3=y
CONFIG_PACKAGE_kmod-vmxnet3=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-zram=y
CONFIG_PACKAGE_zram-swap=y
CONFIG_PACKAGE_kmod-tcp-bbr=y
CONFIG_PACKAGE_kmod-fs-nfs=y
CONFIG_PACKAGE_kmod-fs-nfs-common=y
CONFIG_PACKAGE_kmod-fs-nfs-v3=y
CONFIG_PACKAGE_kmod-fs-nfs-v4=y
CONFIG_PACKAGE_kmod-dnsresolver=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-f2fs=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-fs-msdos=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_automount=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-extras=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_git=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_dmidecode=y
CONFIG_PACKAGE_smartmontools=y
CONFIG_PACKAGE_lm-sensors=y
CONFIG_PACKAGE_sysfsutils=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_partx-utils=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_dosfstools=y
CONFIG_PACKAGE_mkf2fs=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_make=y
CONFIG_PACKAGE_tini=y
CONFIG_PACKAGE_conntrack=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_openssl-util=y
CONFIG_PACKAGE_rsync=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_iftop=y
CONFIG_PACKAGE_nload=y
CONFIG_PACKAGE_ncdu=y
CONFIG_PACKAGE_tmux=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_vim-full=y
CONFIG_PACKAGE_lsof=y
CONFIG_PACKAGE_pciutils=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_ttyd=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_odhcp6c=y
CONFIG_PACKAGE_odhcpd-ipv6only=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y
CONFIG_PACKAGE_luci-app-filemanager=y
CONFIG_PACKAGE_luci-i18n-filemanager-zh-cn=y
CONFIG_PACKAGE_luci-proto-ipv6=y
CONFIG_PACKAGE_luci-proto-ppp=y
"

# ---- QAT 软件包 (内核符号由 KCONFIG 声明) ----
HOST_PKGS="$HOST_PKGS
CONFIG_PACKAGE_kmod-crypto-qat-common=m
CONFIG_PACKAGE_kmod-crypto-qat-dh895xcc=m
CONFIG_PACKAGE_qat-firmware-dh895xcc=m
CONFIG_KERNEL_CRYPTO_DH=y
CONFIG_KERNEL_CRYPTO_DH_RFC7919_GROUPS=y
CONFIG_KERNEL_CRYPTO_RSA=y
"

# ---- Docker (可选) ----
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    HOST_PKGS="$HOST_PKGS
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_containerd=y
CONFIG_PACKAGE_runc=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
"
    echo ">>> Docker 已启用"
fi

# 写入并让 OpenWrt 解析依赖
echo "$HOST_PKGS" >> .config
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
# 4.5 预检: 确认必需的系统依赖齐全
#     (OpenWrt 的 prereq 检查会把 mkisofs 等缺失当作普通 make 错误,
#      信息藏在 make[6] 深层输出里, 故此处提前显式检查)
# ---------------------------------------------------------------------------
echo ">>> 预检系统依赖..."
MISSING_DEPS=""
for cmd in gcc g++ make perl python3 rsync unzip wget git file \
           mkisofs genisoimage bzip2 tar patch cpio bc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        # mkisofs 与 genisoimage 任一存在即可
        case "$cmd" in
            mkisofs)
                command -v genisoimage >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $cmd" ;;
            genisoimage)
                command -v mkisofs >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $cmd" ;;
            *)
                MISSING_DEPS="$MISSING_DEPS $cmd" ;;
        esac
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo "!!! 缺失必需的系统依赖:$MISSING_DEPS"
    echo "!!! Ubuntu 22.04 请执行: apt-get install -y genisoimage build-essential ..."
    exit 1
fi
echo "  OK: 系统依赖齐全"

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
#    (ROOTFS_PARTSIZE 与 Docker 已在第 4 节写入并经 defconfig 解析)
# ---------------------------------------------------------------------------
echo ">>> 编译前配置确认:"
echo "    ROOTFS_PARTSIZE = $(grep '^CONFIG_TARGET_ROOTFS_PARTSIZE=' .config | cut -d= -f2)"
echo "    QAT 包数量      = $(grep -c '^CONFIG_PACKAGE_.*qat' .config)"
echo "    .config 总行数  = $(wc -l < .config)"

# ---------------------------------------------------------------------------
# 5.5 预生成内核 .config, 避免 syncconfig 在编译期遇到 (NEW) 符号
#
# 【run #7 失败根因】
#   最终内核阶段直接执行 `make bzImage modules`, 该命令内部会触发
#   syncconfig。若此时存在尚未回答的新符号 (如 CRYPTO_DH_RFC7919_GROUPS),
#   kconfig 会打印 `[N/y/?] (NEW)` 并读取 stdin; 而我们的 stdin 是
#   /dev/null, 立即 EOF, 于是:
#       RFC 7919 FFDHE groups (CRYPTO_DH_RFC7919_GROUPS) [N/y/?] (NEW)
#       make[8]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
#
#   对比: 工具链内核阶段之所以成功, 是因为 OpenWrt 显式使用了
#   `yes '' | make oldconfig` 自动应答。
#
#   解法: 在正式编译前, 先对目标内核执行一次 `yes '' | make oldconfig`,
#         把所有 (NEW) 符号一次性落盘到 .config。此后 syncconfig 无事可做。
# ---------------------------------------------------------------------------
KERNEL_BUILD_DIR="$SRC_DIR/build_dir/target-x86_64_musl/linux-x86_64"
echo ">>> 预热内核配置 (消除残留的 NEW 符号)..."
if [ -d "$KERNEL_BUILD_DIR" ]; then
    KDIR=$(find "$KERNEL_BUILD_DIR" -maxdepth 1 -type d -name "linux-*" | head -1)
    if [ -n "$KDIR" ] && [ -d "$KDIR" ]; then
        echo "    目标内核目录: $KDIR"
        # 先执行 prepare 让 OpenWrt 生成 .config.set
        make target/linux/prepare V=s >>"$LOG" 2>&1 || true
        if [ -f "$KDIR/.config" ] || [ -f "$KDIR/.config.set" ]; then
            ( cd "$KDIR" && yes '' | make ARCH=x86 oldconfig >>"$LOG" 2>&1 ) || true
            echo "    oldconfig 完成, (NEW) 符号已落盘"
        else
            echo "    (跳过: 内核 .config 尚未生成)"
        fi
    fi
else
    echo "    (跳过: 内核 build_dir 尚不存在)"
fi

echo ">>> 开始编译 (日志: $LOG)..."
#
# 【关键教训 — run #6 失败原因】
#   不要设置 KCONFIG_NOSILENTUPDATE=1 !
#   该变量会让内核 syncconfig 在遇到新符号时直接报错退出:
#       *** The configuration requires explicit update.
#       make[8]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
#   OpenWrt 自身已用 `yes '' | make oldconfig` 自动应答新符号,
#   不应再叠加此限制。
#
export CI=1
export DEBIAN_FRONTEND=noninteractive

# stdin 接 /dev/null: 防止任何残留提示无限等待输入
if ! make -j"$(nproc)" V=s </dev/null 2>&1 | tee -a "$LOG"; then
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
