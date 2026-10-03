#!/bin/bash
# ============================================================================
# ImmortalWrt 源码编译  ——  宿主机专属固件
# 机型: Inspur AliMoC-MD-02-25G  (x86/64)
#
# 与 ImageBuilder 方案的区别:
#   ImageBuilder 只能安装官方 feed 中【已有】的二进制包, 无法新增内核驱动。
#   本脚本走完整源码编译, 因此可以:
#     1. 启用 CONFIG_CRYPTO_DEV_QAT_* —— Intel QAT DH895XCC 硬件加速
#     2. 启用 CONFIG_SERIAL_8250_MID + HSU_DMA —— Atom C3000 (Denverton)
#        板载 HSUART (PCI 00:1a.0) 作为标准 Linux 串口控制台 (详见 5.6 节)
#     3. 任意增删内核配置与软件包
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
# 【改为 SNAPSHOT 源】
#   本固件基于 openwrt-25.12 分支的最新 tip 编译 (VERSION_CODE=r0-<sha>),
#   属于滚动更新性质, 与 releases/25.12.x 正式版的包哈希并不对齐。
#   若仍指向 releases/25.12.1, 在线安装包时会因版本/哈希不匹配而失败。
#   因此改用 snapshots 源, 与本构建的基点一致。
sed -i "/^CONFIG_VERSION_REPO=/d" .config
echo 'CONFIG_VERSION_REPO="https://downloads.immortalwrt.org/snapshots"' >> .config
sed -i "/^CONFIG_VERSION_NUMBER=/d" .config
echo 'CONFIG_VERSION_NUMBER="SNAPSHOT"' >> .config

# ---- 根文件系统大小 ----
sed -i "/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d" .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=${PROFILE}" >> .config

# ---- 串口控制台 (Atom C3000 HSUART) ----
# CONFIG_TARGET_SERIAL 一处决定两个位置 (target/linux/x86/image/Makefile 与 base-files.mk):
#   1) grub.cfg 内核命令行 → console=<ttyS>,<baud>n8
#   2) /etc/inittab 里 @GRUB_SERIAL@ 占位符 → <ttyS>::askfirst:/usr/libexec/login.sh
# 取值必须是真实的 HSUART 节点。编号推导见 5.6 节: 物理口 UAR0 (00:1a.0) = ttyS4。
# 空值会让 base-files.mk 直接 $(error) 终止构建, 故必须显式给值。
sed -i "/^CONFIG_TARGET_SERIAL=/d" .config
echo 'CONFIG_TARGET_SERIAL="ttyS4"' >> .config

# BIOS console redirection 实测 57600 8N1 (设备侧字节率偏差 +0.07%)。
# 三处必须一致, 否则控制台乱码: BIOS / 内核 console= / PC 侧串口工具。
# 本项默认 115200, 与本机 BIOS 不符。
sed -i "/^CONFIG_GRUB_BAUDRATE=/d" .config
echo 'CONFIG_GRUB_BAUDRATE=57600' >> .config

# 兜底: CONFIG_GRUB_BOOTOPTS 会被【前置】到内核命令行
# (image/Makefile: BOOTOPTS=$(CONFIG_GRUB_BOOTOPTS); @CMDLINE@=$(BOOTOPTS) $(GRUB_CONSOLE_CMDLINE))。
# 多声明一个候选 console= 是官方支持的注入口, 且内核对该端口不存在时会静默忽略;
# 万一实测编号与 5.6 节推导不符, 仍能在物理口上看到内核启动日志。
# 登录口不依赖它 —— 由固件内 hsuart-console-detect 服务按 /sys 动态补齐。
sed -i "/^CONFIG_GRUB_BOOTOPTS=/d" .config
echo 'CONFIG_GRUB_BOOTOPTS="console=ttyS4,57600n8 console=ttyS5,57600n8"' >> .config

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
CONFIG_PACKAGE_kmod-crypto-authenc=m
CONFIG_PACKAGE_kmod-crypto-kpp=m
CONFIG_PACKAGE_kmod-crypto-rng=m
CONFIG_PACKAGE_kmod-crypto-rsa=m
CONFIG_PACKAGE_kmod-lib-crc8=m
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
           mkisofs genisoimage bzip2 tar patch cpio bc flex bison; do
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
    echo "!!! Ubuntu 22.04 请执行: apt-get install -y flex bison genisoimage build-essential ..."
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
# 5.5 彻底消除内核 (NEW) 符号 —— 写入 target config
#
# 【run #8 失败根因】
#   上一轮把预热放在编译【之前】, 日志证明其无效:
#       >>> 预热内核配置...
#           (跳过: 内核 build_dir 尚不存在)
#   时间线: 12:47:20 预热跳过 → 13:30:48 内核解压 → 13:31:10 失败
#
# 【关键机制】
#   内核 .config.target 由这三份文件合成 (日志可见):
#       kconfig.pl + + target/linux/generic/config-6.12 \
#                      target/linux/x86/config-6.12 \
#                      target/linux/x86/64/config-6.12
#   而 CRYPTO_DH_RFC7919_GROUPS 是 bool 型, `depends on CRYPTO_DH`。
#   当 CRYPTO_DH=m 时它变为"可见且全新", kconfig 必须提问, 于是失败。
#
# 【解法】直接把这行写进 target config —— 它是 .config.target 的源头,
#         随构建自动合并, 无时序依赖, 无竞态。
# ---------------------------------------------------------------------------
echo ">>> 注入内核符号以消除 (NEW) 提示..."
# 这些是"依赖型"符号: 本身不显眼, 但当其依赖项被拉成 =m 时会变成
# 全新可见符号, 迫使 kconfig 提问, 在非交互环境下直接失败。
#
# 已确认会触发的符号 (从 run#9 日志):
#   CRYPTO_DEV_QAT_ERROR_INJECTION
#     bool, depends on CRYPTO_DEV_QAT + DEBUG_FS
#     —— 我们启用 QAT 后它变为可见且全新
#   CRYPTO_DH_RFC7919_GROUPS
#     bool, depends on CRYPTO_DH
#     —— 某依赖把 CRYPTO_DH 拉成 m 后它变为可见且全新
#
KCONFIG_EXTRA="
CONFIG_CRYPTO_DH_RFC7919_GROUPS=y
CONFIG_CRYPTO_DEV_QAT_ERROR_INJECTION=n
"
for cfg in "$SRC_DIR/target/linux/x86/config-6.12" \
           "$SRC_DIR/target/linux/generic/config-6.12" \
           "$SRC_DIR/target/linux/x86/64/config-6.12"; do
    if [ -f "$cfg" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            sym="${line%%=*}"
            grep -q "^${sym}=" "$cfg" || echo "$line" >> "$cfg"
        done <<EOF
$KCONFIG_EXTRA
EOF
        echo "    已处理: $cfg"
    fi
done

# ---------------------------------------------------------------------------
# 5.6 【串口控制台】Intel Atom C3000 (Denverton) 板载 HSUART
#
# 硬件: PCI 00:1a.0 = 8086:19d8 (Atom C3000 HSUART / ACPI 名 UAR0),
#       BAR0 = I/O 0x2050 (legacy 16550 窗口), BAR1 = MMIO (dnv_board 用 BAR1)。
#       本机 00:1a.1 / 00:1a.2 同样存在 (UAR1/UAR2), 会被一并接管。
#
# 【为什么静默】
#   drivers/tty/serial/8250/8250_pci.c 有一张 blacklist[], 把 0x19d8 显式排除,
#   强制让路给 8250_mid.c 的 dnv_board; 而本分支的
#   target/linux/x86/64/config-6.12 既没有 CONFIG_SERIAL_8250_MID,
#   也没有 CONFIG_HSU_DMA (8250_mid.c 无条件 #include <linux/dma/hsu.h> 并调用
#   hsu_dma_probe(), 必须 =y 否则链接失败)。
#   ⇒ 无人接管 → dmesg: "ignoring port, enable SERIAL_8250_MID to handle",
#     物理串口全静默。
#   开 =y 后 blacklist 项自身变哑 (driver_data == 0), 8250_pci 仍返回 -ENODEV
#   让路, 端口归 8250_mid —— 这是上游既定分工, 【不需要改任何内核源码】。
#
# 【为什么 NR_UARTS 必须写死 16】
#   generic/config-6.12 是 NR_UARTS=2 / RUNTIME_UARTS=2, 而本机运行值实测为 16。
#   行号总数只由 nr_uarts 决定 (serial8250_find_match_or_unused 的三次扫描
#   全部是 for (i = 0; i < nr_uarts; i++))。行数不足时, 末次回退会让 PCI 口
#   顶掉 0-3 号 ISA 幽灵口 (iobase != 0 且 PORT_UNKNOWN), 编号整体前移,
#   CONFIG_TARGET_SERIAL 就会指向不存在的节点、登录口静默失效。
#
# 【ttyS 编号推导 —— 依据内核源码 + 本机 /proc/tty/driver/serial 实证】
#   1) arch/x86 的 SERIAL_PORT_DFNS 先注册 4 个 ISA 幽灵口 → 占 0/1/2/3
#      (本机实测: 0-3 = uart:unknown, iobase 0x3F8/0x2F8/0x3E8/0x2E8)
#   2) 之后按【链接顺序】执行各 PCI 驱动的 device_initcall:
#        drivers/tty/serial/8250/Makefile  第41行 8250_mid.o  ← 先注册
#                                          第46行 8250_pci.o  ← 后注册
#      ⇒ 8250_mid 先探测 00:1a.0/1/2, 取走前 3 个 iobase==0 的空槽 = 4/5/6
#        8250_pci 再探测 00:1b.3 (Intel ME KT) → 7
#      (本机现状佐证: MID 未开时, 00:1b.3 正是 ttyS4)
#   3) 8250_mid 不设置 port->line (memset 后为 0), 而槽 0 是 ISA 幽灵口
#      (iobase != 0), 故 "try line number first" 提示必然落空 → 走首个空闲槽。
#   ⇒ 物理控制台 UAR0 (00:1a.0) = 【ttyS4】(ttyS5 是 UAR1, 无外接)
#
#   ★ 兜底: 万一实测编号与上述推导不符, 不必为编号再刷一次机 ——
#     固件内的 hsuart-console-detect 服务会在每次启动时按 /sys 反查真实编号,
#     并自动补上 inittab 登录口。
#
# 【合并顺序保证生效】
#   include/target.mk: LINUX_KCONFIG_LIST = generic → x86 → x86/64,
#   经 scripts/kconfig.pl 的 '+' 语义(后加载覆盖先加载), 故只写
#   子目标 x86/64/config-6.12 即可稳定胜出, 且不会污染 generic。
# ---------------------------------------------------------------------------
echo ">>> 注入串口控制台内核符号 (Atom C3000 HSUART)..."

# set_kconfig <file> <symbol> <value>
#   已存在则原地替换 (含 "# CONFIG_X is not set" 形式), 否则追加。
set_kconfig() {
    local file="$1" sym="$2" val="$3"
    if grep -qE "^${sym}=" "$file"; then
        sed -i "s|^${sym}=.*|${sym}=${val}|" "$file"
    elif grep -qE "^# ${sym} is not set" "$file"; then
        sed -i "s|^# ${sym} is not set|${sym}=${val}|" "$file"
    else
        echo "${sym}=${val}" >> "$file"
    fi
}

SUB_CONFIG="$SRC_DIR/target/linux/x86/64/config-6.12"
if [ ! -f "$SUB_CONFIG" ]; then
    echo "!!! 未找到子目标内核配置: $SUB_CONFIG"
    exit 1
fi
while IFS= read -r line; do
    [ -z "$line" ] && continue
    set_kconfig "$SUB_CONFIG" "${line%%=*}" "${line#*=}"
    echo "    + $line"
done <<'SERIAL_KCONFIG'
CONFIG_HSU_DMA=y
CONFIG_SERIAL_8250_MID=y
CONFIG_SERIAL_8250_NR_UARTS=16
CONFIG_SERIAL_8250_RUNTIME_UARTS=16
SERIAL_KCONFIG
echo "    写入文件: $SUB_CONFIG"

# ---------------------------------------------------------------------------
# 5.7 【可观测性】把内核配置本身装进固件
#
# 刷机后要核验 "CONFIG_SERIAL_8250_MID 到底有没有生效", 只看 dmesg/lsmod
# 属于间接推断 (能反推, 但要绕)。开启 IKCONFIG_PROC 后固件内会有 /proc/config.gz:
#     zgrep -E 'SERIAL_8250_MID|HSU_DMA|NR_UARTS' /proc/config.gz
# 这是对本次改动最直接的证明, 也让今后排查内核配置问题不必重新编译。
# 代价: 内核里多一份压缩后的配置 blob (约几十 KB), 无运行时开销。
# ---------------------------------------------------------------------------
echo ">>> 注入内核配置自省符号 (IKCONFIG_PROC)..."
for kv in CONFIG_IKCONFIG=y CONFIG_IKCONFIG_PROC=y; do
    set_kconfig "$SUB_CONFIG" "${kv%%=*}" "${kv#*=}"
    echo "    + $kv"
done

# ---------------------------------------------------------------------------
# 5.8 内核合并结果断言 —— 两道闸门
#
# 【为什么不能在 prepare 之后查】
#   实测(成功运行 35557214648 的日志):
#     03:28:58  prepare 完成
#     03:29:01  脚本里 step2 的 olddefconfig "完成"   ← 此时 $KDIR/.config 尚不存在
#     04:11:36  OpenWrt 才真正调用 kconfig.pl 生成 .config.target  ← 整整晚 43 分钟
#   即"合并后的内核 .config"是 OpenWrt 在 make world 中途才产出的。
#   在 prepare 后断言它只会拿到"文件不存在"的假失败 —— 本脚本第一版正是
#   这样误杀了一次构建 (run 37100787247), 教训记在这里。
#
# 【闸门 1 — 注入后立即执行, 最快】
#   直接调用【上游真实的 scripts/kconfig.pl】, 用与 OpenWrt 完全相同的调用形状
#   合并三份 target config 并断言。既早于长时间编译, 又用的是真脚本而非模拟。
#   OpenWrt 实际命令(取自成功运行日志):
#     scripts/kconfig.pl + + generic/config-6.12 x86/config-6.12 x86/64/config-6.12
#
# 【闸门 2 — make world 之后, 才是真凭据】
#   断言内核最终 .config; 不通过则以失败收场, 使产物【不会被上传】。
#   宁可这一次不出固件, 也不出一个没有串口驱动的固件。
# ---------------------------------------------------------------------------
verify_symbols_in() {
    local kcfg="$1" label="$2" bad=0 want got sym
    echo ">>> 校验内核串口配置 ($label)"
    echo "    文件: $kcfg"
    if [ ! -f "$kcfg" ]; then
        echo "    ❌ 配置文件不存在, 无法校验"
        return 1
    fi
    for sym in CONFIG_SERIAL_8250_MID CONFIG_HSU_DMA \
               CONFIG_SERIAL_8250_NR_UARTS CONFIG_SERIAL_8250_RUNTIME_UARTS \
               CONFIG_IKCONFIG CONFIG_IKCONFIG_PROC; do
        case "$sym" in
            *NR_UARTS|*RUNTIME_UARTS) want=16 ;;
            *)                        want=y  ;;
        esac
        # 顶层开了 set -o pipefail: 符号缺失时 grep 返回 1, 不加 '|| true'
        # 则赋值本身失败会被 set -e 直接中止, 反而看不到下面的诊断。
        got=$(grep -E "^${sym}=" "$kcfg" 2>/dev/null | head -1 | cut -d= -f2- || true)
        if [ "$got" = "$want" ]; then
            echo "    ✅ ${sym}=${got}"
        else
            echo "    ❌ ${sym} 期望 '${want}', 实际 '${got:-未设置}'"
            bad=1
        fi
    done
    if [ "$bad" -ne 0 ]; then
        echo "!!! 串口控制台内核配置未生效"
        echo "--- 该配置中的相关行 ---"
        grep -nE "SERIAL_8250_MID|HSU_DMA|SERIAL_8250_NR_UARTS|SERIAL_8250_RUNTIME_UARTS|IKCONFIG" "$kcfg" || true
        echo "--- 子目标 config 中的相关行 ---"
        grep -nE "SERIAL_8250_MID|HSU_DMA|SERIAL_8250_NR_UARTS|SERIAL_8250_RUNTIME_UARTS|IKCONFIG" "$SUB_CONFIG" || true
        return 1
    fi
    return 0
}

echo ">>> 闸门 1: 用上游真实 kconfig.pl 预演合并 (与 OpenWrt 同形状)"
MERGED_CHECK="/tmp/.config.target.precheck"
if perl "$SRC_DIR/scripts/kconfig.pl" + + \
        "$SRC_DIR/target/linux/generic/config-6.12" \
        "$SRC_DIR/target/linux/x86/config-6.12" \
        "$SRC_DIR/target/linux/x86/64/config-6.12" >"$MERGED_CHECK" 2>"$MERGED_CHECK.err"; then
    verify_symbols_in "$MERGED_CHECK" "kconfig.pl 预演合并结果" || {
        echo "!!! 提前终止: 子目标 config 未能覆盖 generic"
        exit 1
    }
else
    echo "    ⚠️ kconfig.pl 预演执行失败, 跳过闸门 1 (闸门 2 仍会兜底)"
    tail -5 "$MERGED_CHECK.err" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5.5 【确定性方案】prepare → oldconfig 落盘 → 验证 → 再编译
#
# 【历史失败复盘】
#   run#5: 基线配置缺失 → 3172 个 NEW
#   run#6: 误加 KCONFIG_NOSILENTUPDATE → explicit update 报错
#   run#7: 误用 </dev/null → 遇 NEW 即 EOF 失败
#   run#8: 预热在 build_dir 存在【之前】执行 → 被跳过, 完全无效
#   run#9: 只剩 1 个 NEW (CRYPTO_DEV_QAT_ERROR_INJECTION), 仍失败
#
# 【为什么后台守护进程也不可靠】
#   轮询等待内核目录出现, 与 OpenWrt 的构建流程存在竞态:
#   目录一出现, OpenWrt 可能立刻开始 syncconfig, 而守护进程
#   还在 sleep 周期里。
#
# 【确定性做法】
#   显式分三步, 不依赖任何轮询或时序:
#     1. make target/linux/prepare   —— 同步执行, 完成后内核目录必然存在
#     2. 在【该目录】执行 oldconfig  —— 把所有 NEW 符号一次性落盘
#     3. 验证 syncconfig 能非交互通过 —— 确认无残留, 否则立即失败
#   三步全部成功后才进入真正的 make world。
# ---------------------------------------------------------------------------
echo ">>> 步骤 1/3: 准备内核 (make target/linux/prepare)..."
make target/linux/prepare V=s 2>&1 | tail -20 >>"$LOG"
echo "    prepare 完成"

# 定位目标内核目录 (target 用, 不是 toolchain 用)
TARGET_KERNEL_BASE="$SRC_DIR/build_dir/target-x86_64_musl/linux-x86_64"
# 注意: 基目录名 linux-x86_64 本身也匹配 "linux-*", 故必须用 maxdepth 2
# 且匹配 "linux-6.*" 才能定位到真正的内核源码树
KDIR=$(find "$TARGET_KERNEL_BASE" -maxdepth 2 -type d -name "linux-6.*" 2>/dev/null | head -1)

if [ -z "$KDIR" ] || [ ! -d "$KDIR" ]; then
    echo "!!! 未找到目标内核目录: $TARGET_KERNEL_BASE"
    echo "--- 调试: build_dir 结构 ---"
    find "$SRC_DIR/build_dir" -maxdepth 3 -type d -name "linux-*" 2>/dev/null | head
    exit 1
fi
if [ ! -f "$KDIR/Makefile" ]; then
    echo "!!! 目录不是内核源码树 (无 Makefile): $KDIR"
    ls -la "$KDIR" | head
    exit 1
fi
echo "    内核目录: $KDIR"

echo ">>> 步骤 2/3: 落盘内核配置 (olddefconfig / yes '' | make oldconfig)..."
# 注意: 顶层开启了 set -o pipefail。
# 当 make oldconfig 写入配置并关闭 stdin 后, yes 写入 broken pipe 会产生 SIGPIPE (退出码 141)。
# 在 pipefail 下 141 会被判定为管道命令失败!
# 因此此处首选非交互官方指令 olddefconfig; 若使用管道必须隔离 pipefail。
(
    cd "$KDIR"
    make ARCH=x86 olddefconfig >>"$LOG" 2>&1 || {
        set +o pipefail
        yes '' | make ARCH=x86 oldconfig >>"$LOG" 2>&1
    }
) || {
    echo "!!! oldconfig 失败, 最后 40 行:"
    tail -40 "$LOG"
    exit 1
}
echo "    oldconfig 完成"

echo ">>> 步骤 3/3: 验证 syncconfig 可非交互通过..."
if ( cd "$KDIR" && make ARCH=x86 syncconfig </dev/null >/tmp/syncconfig-test.log 2>&1 ); then
    echo "    ✅ 内核配置已定型, 无残留 NEW 符号"
else
    echo "    ❌ syncconfig 仍失败, 残留符号:"
    grep -E "\(NEW\)|Error" /tmp/syncconfig-test.log | head -20
    echo "!!! 提前终止, 避免浪费完整编译时间"
    exit 1
fi

echo ">>> 开始编译 (日志: $LOG)..."
export CI=1
export DEBIAN_FRONTEND=noninteractive

# stdin 接 /dev/null: 防止任何残留提示无限等待输入
if ! make -j"$(nproc)" V=s </dev/null 2>&1 | tee -a "$LOG"; then
    echo "!!! 编译失败, 最后 150 行日志:"
    tail -150 "$LOG"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6.5 【闸门 2】编译完成后断言内核最终 .config
#
#   OpenWrt 是在 make world 中途才用 kconfig.pl 产出内核 .config 的
#   (实测: prepare 后 43 分钟), 所以真正的凭据只能在这里查。
#   不通过就直接失败 —— 后续的产物复制与 artifact 上传都不会发生,
#   宁可这一次不出固件, 也不流出没有串口驱动的固件。
# ---------------------------------------------------------------------------
if [ -n "${KDIR:-}" ] && [ -d "$KDIR" ]; then
    verify_symbols_in "$KDIR/.config" "内核最终 .config (编译完成后)" || {
        echo "!!! 串口控制台内核配置未进入最终 .config —— 拒绝产出固件"
        exit 1
    }
else
    echo "!!! 警告: 未记录到内核目录(KDIR), 跳过闸门 2"
fi

# ---------------------------------------------------------------------------
# 7. 产物
# ---------------------------------------------------------------------------
echo ">>> 编译完成, 产物列表:"
ls -lah bin/targets/x86/64/ 2>/dev/null || true

# 校验 QAT 模块确实被编译进产物
echo ">>> 校验 QAT 内核模块:"
find bin/ -name "*qat*" 2>/dev/null || echo "(未找到 qat 文件)"

# 校验串口控制台相关配置确实落进最终产物
echo ">>> 校验串口控制台 (Atom C3000 HSUART):"
echo "    TARGET_SERIAL  = $(grep '^CONFIG_TARGET_SERIAL=' .config | cut -d= -f2-)"
echo "    GRUB_BAUDRATE  = $(grep '^CONFIG_GRUB_BAUDRATE=' .config | cut -d= -f2-)"
echo "    GRUB_BOOTOPTS  = $(grep '^CONFIG_GRUB_BOOTOPTS=' .config | cut -d= -f2-)"
echo "    QAT 包数量     = $(grep -c '^CONFIG_PACKAGE_.*qat' .config)"
# inittab 由 base-files 在 rootfs 暂存目录里生成 (@GRUB_SERIAL@ 占位符被替换)
INITTAB=$(find "$SRC_DIR/build_dir/target-x86_64_musl" -maxdepth 3 -path '*/etc/inittab' 2>/dev/null | head -1)
if [ -n "$INITTAB" ] && [ -f "$INITTAB" ]; then
    echo "    inittab: $INITTAB"
    if grep -q 'ttyS' "$INITTAB"; then
        grep -n 'ttyS' "$INITTAB" | sed 's/^/      /'
    else
        echo "      ❌ inittab 中没有 ttyS 登录口 —— CONFIG_TARGET_SERIAL 未生效"
    fi
else
    echo "    (未定位到 rootfs 的 /etc/inittab, 跳过该检查)"
fi
# 内核模块文件是否真的编出来了
KVER=$(make -s kernelversion 2>/dev/null || true)
if [ -n "$KVER" ]; then
    echo "    内核版本       = $KVER"
    find "bin/targets/x86/64" -path "*${KVER}*" \
         \( -name 'intel_qat.ko*' -o -name 'qat_dh895xcc.ko*' \) 2>/dev/null | sed 's/^/      /' \
         || echo "      (未找到 QAT 模块文件)"
fi

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
