#!/bin/bash
# ============================================================================
# 宿主机专属构建脚本  Inspur AliMoC-MD-02-25G
# 目标主机: ImmortalWrt 25.12.x  x86/64
# 网卡: mlx5_core (ConnectX) x2 + ixgbe (X550/X540) 
# 用途: 软路由 + Docker 宿主 + OpenClash + NFS 客户端
# ============================================================================
set -o pipefail

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting host build at $(date)" >> "$LOGFILE"
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# ---------------------------------------------------------------------------
# 1. PPPoE 配置文件 (由工作流环境变量注入, 供 99-custom.sh 读取)
# ---------------------------------------------------------------------------
mkdir -p /home/build/immortalwrt/files/etc/config
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "---- pppoe-settings ----"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# ---------------------------------------------------------------------------
# 2. 第三方软件仓库 (可选, 通过 shell/apk-custom-packages.sh 打开注释)
# ---------------------------------------------------------------------------
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/
  echo "✅ Run files copied to extra-packages:"
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# ---------------------------------------------------------------------------
# 3. 软件包清单 —— 严格按宿主机实际安装状态定制
# ---------------------------------------------------------------------------
PACKAGES=""

# ===== 3.1 基础运行时 / 工具 (宿主机已装) =====
PACKAGES="$PACKAGES bash"
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES unzip"
PACKAGES="$PACKAGES git"
PACKAGES="$PACKAGES ip-full"
PACKAGES="$PACKAGES ipset"
PACKAGES="$PACKAGES ethtool-full"
PACKAGES="$PACKAGES dmidecode"
PACKAGES="$PACKAGES smartmontools"       # SMART 硬盘健康监测
PACKAGES="$PACKAGES lm-sensors"          # 温度/风扇/电压监测
PACKAGES="$PACKAGES sysfsutils"
PACKAGES="$PACKAGES lsblk"
PACKAGES="$PACKAGES fdisk"
PACKAGES="$PACKAGES parted"
PACKAGES="$PACKAGES partx-utils"
PACKAGES="$PACKAGES blkid"
PACKAGES="$PACKAGES e2fsprogs"
PACKAGES="$PACKAGES dosfstools"
PACKAGES="$PACKAGES mkf2fs"              # /overlay = f2fs (宿主机实测)
# 注: 宿主机不使用 btrfs / exfat / ntfs, 故不集成对应工具与内核模块, 已剔除
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES make"
PACKAGES="$PACKAGES tini"
PACKAGES="$PACKAGES ca-bundle"
PACKAGES="$PACKAGES ca-certificates"

# ===== 3.1b 补齐宿主机当前缺失的实用诊断工具 =====
PACKAGES="$PACKAGES ipset"               # 防火墙 IP 集合 (OpenClash 常用)
PACKAGES="$PACKAGES jq"                  # JSON 处理
PACKAGES="$PACKAGES openssl-util"        # openssl 命令行
PACKAGES="$PACKAGES rsync"               # 增量同步
PACKAGES="$PACKAGES htop"                # 进程监视
PACKAGES="$PACKAGES iftop"               # 实时流量
PACKAGES="$PACKAGES nload"               # 网卡流量
PACKAGES="$PACKAGES ncdu"                # 磁盘占用分析
PACKAGES="$PACKAGES tmux"                # 终端复用
PACKAGES="$PACKAGES nano"                # 轻量编辑器
PACKAGES="$PACKAGES vim-full"            # 完整 vim
PACKAGES="$PACKAGES lsof"                # 打开文件/端口
PACKAGES="$PACKAGES conntrack"           # 连接跟踪查看 (包名为 conntrack)
PACKAGES="$PACKAGES iperf3"              # 带宽测试
PACKAGES="$PACKAGES pciutils"            # lspci (查看 mlx5/ixgbe 网卡)
PACKAGES="$PACKAGES usbutils"            # lsusb

# ===== 3.2 LuCI 界面 / 中文语言包 =====
PACKAGES="$PACKAGES luci-base"
PACKAGES="$PACKAGES luci-compat"
PACKAGES="$PACKAGES luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"

# ===== 3.3 主题: Argon =====
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"

# ===== 3.4 磁盘管理 / 文件管理 =====
PACKAGES="$PACKAGES luci-app-diskman"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-app-filemanager"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# ===== 3.5 Docker 全套 (宿主机跑 deepseek-harness / QwenPaw 等容器) =====
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES dockerd"
    PACKAGES="$PACKAGES docker"
    PACKAGES="$PACKAGES docker-compose"
    PACKAGES="$PACKAGES containerd"
    PACKAGES="$PACKAGES runc"
    PACKAGES="$PACKAGES luci-app-dockerman"
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ Adding Docker packages"
else
    echo "⚪️ Docker 未启用"
fi

# ===== 3.6 网络存储: NFS 客户端 (挂载 10.0.0.10 的三处共享) =====
PACKAGES="$PACKAGES nfs-utils"
PACKAGES="$PACKAGES kmod-fs-nfs"
PACKAGES="$PACKAGES kmod-fs-nfs-common"
PACKAGES="$PACKAGES kmod-fs-nfs-v3"
PACKAGES="$PACKAGES kmod-fs-nfs-v4"
PACKAGES="$PACKAGES kmod-dnsresolver"
PACKAGES="$PACKAGES kmod-fs-ext4"        # /Lager 数据盘 = ext4
PACKAGES="$PACKAGES kmod-fs-f2fs"        # /overlay = f2fs
PACKAGES="$PACKAGES kmod-fs-vfat"        # /boot = vfat
PACKAGES="$PACKAGES kmod-fs-msdos"
PACKAGES="$PACKAGES block-mount"
PACKAGES="$PACKAGES automount"
# 注: 宿主机无 btrfs / exfat / ntfs 分区, 已剔除 kmod-fs-btrfs / exfat / ntfs3 / btrfs-progs

# ===== 3.7 存储 / USB 相关内核模块 =====
PACKAGES="$PACKAGES kmod-usb-core"
PACKAGES="$PACKAGES kmod-usb-common"
PACKAGES="$PACKAGES kmod-usb-storage"
PACKAGES="$PACKAGES kmod-usb-storage-extras"
PACKAGES="$PACKAGES kmod-usb-storage-uas"
PACKAGES="$PACKAGES kmod-usb-hid"
PACKAGES="$PACKAGES kmod-scsi-core"

# ===== 3.8 网卡驱动 —— 宿主机关键模块 (mlx5 + ixgbe) =====
PACKAGES="$PACKAGES kmod-mlx5-core"     # eth0/eth1  ConnectX 网卡 (关键!)
PACKAGES="$PACKAGES kmod-mlxfw"
PACKAGES="$PACKAGES kmod-ixgbe"         # eth2  Intel X550/X540
PACKAGES="$PACKAGES kmod-ixgbevf"
PACKAGES="$PACKAGES kmod-i40e"
PACKAGES="$PACKAGES kmod-igb"
PACKAGES="$PACKAGES kmod-igbvf"
PACKAGES="$PACKAGES kmod-igc"
PACKAGES="$PACKAGES kmod-e1000"
PACKAGES="$PACKAGES kmod-e1000e"
PACKAGES="$PACKAGES kmod-r8125"
PACKAGES="$PACKAGES kmod-r8126"
PACKAGES="$PACKAGES kmod-r8168"
PACKAGES="$PACKAGES kmod-r8101"
PACKAGES="$PACKAGES kmod-tg3"
PACKAGES="$PACKAGES kmod-bnx2"
PACKAGES="$PACKAGES kmod-amd-xgbe"
PACKAGES="$PACKAGES kmod-amazon-ena"
PACKAGES="$PACKAGES kmod-vmxnet3"       # 虚拟机场景备用
PACKAGES="$PACKAGES kmod-forcedeth"
PACKAGES="$PACKAGES kmod-pcnet32"
PACKAGES="$PACKAGES kmod-8139too"
PACKAGES="$PACKAGES kmod-8139cp"
PACKAGES="$PACKAGES kmod-tulip"
PACKAGES="$PACKAGES kmod-dwmac-intel"
PACKAGES="$PACKAGES kmod-stmmac-core"
PACKAGES="$PACKAGES kmod-libphy"
PACKAGES="$PACKAGES kmod-phylink"
PACKAGES="$PACKAGES kmod-mdio"
PACKAGES="$PACKAGES kmod-mdio-devres"
PACKAGES="$PACKAGES kmod-mii"
PACKAGES="$PACKAGES kmod-pcs-xpcs"
PACKAGES="$PACKAGES kmod-phy-ax88796b"
PACKAGES="$PACKAGES kmod-libie"
PACKAGES="$PACKAGES kmod-pps"
PACKAGES="$PACKAGES kmod-ptp"

# ===== 3.9 USB 网卡 (2.5G/千兆 外接网卡) =====
PACKAGES="$PACKAGES kmod-usb-net"
PACKAGES="$PACKAGES kmod-usb-net-asix"
PACKAGES="$PACKAGES kmod-usb-net-asix-ax88179"
PACKAGES="$PACKAGES kmod-usb-net-rtl8150"
PACKAGES="$PACKAGES kmod-usb-net-rtl8152-vendor"
PACKAGES="$PACKAGES kmod-macvlan"
PACKAGES="$PACKAGES kmod-veth"
PACKAGES="$PACKAGES kmod-tun"

# ===== 3.10 PPPoE 拨号 =====
PACKAGES="$PACKAGES ppp"
PACKAGES="$PACKAGES ppp-mod-pppoe"
PACKAGES="$PACKAGES kmod-ppp"
PACKAGES="$PACKAGES kmod-pppoe"
PACKAGES="$PACKAGES kmod-pppox"
PACKAGES="$PACKAGES kmod-slhc"
PACKAGES="$PACKAGES kmod-mppe"
PACKAGES="$PACKAGES kmod-lib-crc-ccitt"
PACKAGES="$PACKAGES luci-proto-ppp"

# ===== 3.11 防火墙 / NAT =====
PACKAGES="$PACKAGES firewall4"
PACKAGES="$PACKAGES nftables-json"
PACKAGES="$PACKAGES kmod-nft-core"
PACKAGES="$PACKAGES kmod-nft-nat"
PACKAGES="$PACKAGES kmod-nft-offload"
PACKAGES="$PACKAGES kmod-nft-fib"
PACKAGES="$PACKAGES kmod-nft-compat"
PACKAGES="$PACKAGES kmod-nft-fullcone"
PACKAGES="$PACKAGES kmod-nf-conntrack"
PACKAGES="$PACKAGES kmod-nf-conntrack6"
PACKAGES="$PACKAGES kmod-nf-conntrack-netlink"
PACKAGES="$PACKAGES kmod-nf-nat"
PACKAGES="$PACKAGES kmod-nf-nat6"
PACKAGES="$PACKAGES kmod-nf-nathelper"
PACKAGES="$PACKAGES kmod-nf-flow"
PACKAGES="$PACKAGES kmod-nf-ipt"
PACKAGES="$PACKAGES kmod-nf-ipt6"
PACKAGES="$PACKAGES kmod-nf-ipvs"
PACKAGES="$PACKAGES kmod-nf-log"
PACKAGES="$PACKAGES kmod-nf-log6"
PACKAGES="$PACKAGES kmod-nf-reject"
PACKAGES="$PACKAGES kmod-nf-reject6"
PACKAGES="$PACKAGES kmod-nfnetlink"
PACKAGES="$PACKAGES kmod-br-netfilter"
PACKAGES="$PACKAGES kmod-ipt-core"
PACKAGES="$PACKAGES kmod-ipt-conntrack"
PACKAGES="$PACKAGES kmod-ipt-extra"
PACKAGES="$PACKAGES kmod-ipt-nat"
PACKAGES="$PACKAGES kmod-ipt-nat6"
PACKAGES="$PACKAGES kmod-ipt-physdev"
PACKAGES="$PACKAGES kmod-ip6tables"
PACKAGES="$PACKAGES iptables-nft"
PACKAGES="$PACKAGES iptables-mod-extra"
PACKAGES="$PACKAGES ip6tables-nft"
PACKAGES="$PACKAGES xtables-nft"
PACKAGES="$PACKAGES kmod-tcp-bbr"       # BBR 拥塞控制

# ===== 3.12 Tproxy / OpenClash 所需 =====
PACKAGES="$PACKAGES kmod-nft-tproxy"
PACKAGES="$PACKAGES kmod-nft-socket"
PACKAGES="$PACKAGES kmod-inet-diag"

# ===== 3.13 IPv6 / DHCP =====
PACKAGES="$PACKAGES odhcp6c"
PACKAGES="$PACKAGES odhcpd-ipv6only"
PACKAGES="$PACKAGES luci-proto-ipv6"
PACKAGES="$PACKAGES dnsmasq-full"

# ===== 3.14 终端 / Web 终端 =====
PACKAGES="$PACKAGES ttyd"

# ===== 3.15 显示/传感器 (i915 核显 + acpi) =====
PACKAGES="$PACKAGES kmod-drm-i915"
PACKAGES="$PACKAGES kmod-drm"
PACKAGES="$PACKAGES kmod-acpi-video"
PACKAGES="$PACKAGES kmod-backlight"
PACKAGES="$PACKAGES kmod-hid"
PACKAGES="$PACKAGES kmod-hid-generic"
PACKAGES="$PACKAGES kmod-input-core"
PACKAGES="$PACKAGES kmod-input-evdev"
PACKAGES="$PACKAGES kmod-hwmon-core"
PACKAGES="$PACKAGES kmod-i2c-core"
PACKAGES="$PACKAGES kmod-i2c-algo-bit"
PACKAGES="$PACKAGES i915-firmware-dmc"
PACKAGES="$PACKAGES bnx2-firmware"

# ===== 3.16 加密 / zram =====
PACKAGES="$PACKAGES kmod-crypto-hash"
PACKAGES="$PACKAGES kmod-crypto-hmac"
PACKAGES="$PACKAGES kmod-crypto-manager"
PACKAGES="$PACKAGES kmod-crypto-null"
PACKAGES="$PACKAGES kmod-crypto-aead"
PACKAGES="$PACKAGES kmod-crypto-sha1"
PACKAGES="$PACKAGES kmod-crypto-sha3"
PACKAGES="$PACKAGES kmod-crypto-sha512"
PACKAGES="$PACKAGES kmod-crypto-user"
PACKAGES="$PACKAGES kmod-crypto-rng"
PACKAGES="$PACKAGES kmod-crypto-arc4"
PACKAGES="$PACKAGES kmod-crypto-ecb"
PACKAGES="$PACKAGES kmod-crypto-crc32"
PACKAGES="$PACKAGES kmod-crypto-crc32c"
PACKAGES="$PACKAGES kmod-crypto-blake2b"
PACKAGES="$PACKAGES kmod-crypto-xxhash"
PACKAGES="$PACKAGES kmod-crypto-acompress"
PACKAGES="$PACKAGES kmod-zram"
PACKAGES="$PACKAGES zram-swap"
PACKAGES="$PACKAGES automount"
PACKAGES="$PACKAGES kmod-lib-zstd"
PACKAGES="$PACKAGES kmod-lib-lzo"
PACKAGES="$PACKAGES kmod-lib-zlib-deflate"
PACKAGES="$PACKAGES kmod-lib-zlib-inflate"
PACKAGES="$PACKAGES kmod-lib-crc32c"
PACKAGES="$PACKAGES kmod-lib-crc16"
PACKAGES="$PACKAGES kmod-lib-xxhash"
PACKAGES="$PACKAGES kmod-lib-raid6"
PACKAGES="$PACKAGES kmod-lib-xor"
PACKAGES="$PACKAGES kmod-libeth"

# ===== 3.17 文件系统编码 (中文文件名) =====
PACKAGES="$PACKAGES kmod-nls-base"
PACKAGES="$PACKAGES kmod-nls-utf8"
PACKAGES="$PACKAGES kmod-nls-cp437"
PACKAGES="$PACKAGES kmod-nls-cp936"
PACKAGES="$PACKAGES kmod-nls-cp932"
PACKAGES="$PACKAGES kmod-nls-cp950"
PACKAGES="$PACKAGES kmod-nls-iso8859-1"
PACKAGES="$PACKAGES kmod-oid-registry"

# ===== 3.18 内核基础 =====
PACKAGES="$PACKAGES kmod-button-hotplug"
PACKAGES="$PACKAGES kmod-dma-buf"

# ===== 3.19 第三方插件 (由 shell/apk-custom-packages.sh 控制) =====
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ---------------------------------------------------------------------------
# 4. OpenClash 内核与 GeoIP/GeoSite (若集成 openclash)
# ---------------------------------------------------------------------------
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- "$META_URL" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat   -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" | head -n1 | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    [ -n "$URL" ] && wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ---------------------------------------------------------------------------
# 5. 输出最终清单并构建
# ---------------------------------------------------------------------------
echo "$(date '+%Y-%m-%d %H:%M:%S') - 最终软件包清单:"
echo "$PACKAGES" | tr ' ' '\n' | grep -v '^$' | sort -u | tee /tmp/final-packages.txt
echo "包总数: $(wc -l < /tmp/final-packages.txt)"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
ls -lah bin/targets/x86/64/ 2>/dev/null
