#!/bin/sh
# ============================================================================
# 宿主机专属首次启动脚本  Inspur AliMoC-MD-02-25G
# 目标: ImmortalWrt 25.12.x x86/64
# 位置: 固件内 /etc/uci-defaults/99-host.sh
# 说明: 该脚本仅在首次刷机启动时执行一次, 之后自动删除
# ============================================================================
LOGFILE="/etc/config/host-defaults-log.txt"
echo "===== 99-host.sh start $(date) =====" >> "$LOGFILE"

# ---------------------------------------------------------------------------
# 0. 网络接口映射 —— 本机为 3 网口 (mlx5 x2 + ixgbe x1)
#    eth0 = LAN (管理口), eth1/eth2 = WAN 候选
# ---------------------------------------------------------------------------
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board: $board_name" >> "$LOGFILE"

# 收集物理接口
ifnames=""
for iface in /sys/class/net/*; do
    n=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$n" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $n"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')
count=$(echo "$ifnames" | wc -w)
echo "Physical interfaces: $ifnames (count=$count)" >> "$LOGFILE"

if [ "$count" -ge 2 ]; then
    wan_ifname=$(echo "$ifnames" | awk '{print $1}')
    lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)

    # LAN 静态地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
    else
        CUSTOM_IP="10.0.0.1"
    fi

    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$CUSTOM_IP"
    uci set network.lan.netmask='255.255.255.0'
    echo "LAN ip = $CUSTOM_IP" >> "$LOGFILE"

    # WAN = 第一个网口 (eth0) DHCP; 需要 PPPoE 时由 pppoe-settings 覆盖
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # br-lan 桥接除 WAN 外的所有网口
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -n "$section" ]; then
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "br-lan ports: $lan_ifnames" >> "$LOGFILE"
    fi

    # PPPoE (由 build.sh 写入的 pppoe-settings 决定)
    SETTINGS_FILE="/etc/config/pppoe-settings"
    if [ -f "$SETTINGS_FILE" ]; then
        . "$SETTINGS_FILE"
        if [ "$enable_pppoe" = "yes" ] && [ -n "$pppoe_account" ]; then
            uci set network.wan.proto='pppoe'
            uci set network.wan.username="$pppoe_account"
            uci set network.wan.password="$pppoe_password"
            uci set network.wan.peerdns='1'
            uci set network.wan.auto='1'
            uci set network.wan6.proto='none'
            echo "PPPoE enabled for $pppoe_account" >> "$LOGFILE"
        fi
    fi
    uci commit network
elif [ "$count" -eq 1 ]; then
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr 2>/dev/null
    uci delete network.lan.netmask 2>/dev/null
    uci commit network
fi

# ---------------------------------------------------------------------------
# 1. 主机名
# ---------------------------------------------------------------------------
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# ---------------------------------------------------------------------------
# 2. 防火墙: 允许 WAN 入站 (方便首次调试), 后续可在 UI 收紧
# ---------------------------------------------------------------------------
uci set firewall.@zone[1].input='ACCEPT'
uci commit firewall

# ---------------------------------------------------------------------------
# 3. Docker 防火墙区域 (172.16.0.0/12)
# ---------------------------------------------------------------------------
if command -v dockerd >/dev/null 2>&1; then
    echo "Configuring docker firewall zone..." >> "$LOGFILE"
    FW_FILE="/etc/config/firewall"
    uci -q delete firewall.docker
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci -q delete "firewall.@forwarding[$idx]"
        fi
    done
    uci commit firewall
    cat <<EOF >> "$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF
fi

# ---------------------------------------------------------------------------
# 4. NFS 客户端挂载点 (rc.local 负责实际挂载逻辑)
# ---------------------------------------------------------------------------
mkdir -p /nfs/Lager /nfs/Surveillance /nfs/Container
echo "Created NFS mount points" >> "$LOGFILE"

# ---------------------------------------------------------------------------
# 5. 终端 / SSH 开放所有网口
# ---------------------------------------------------------------------------
uci -q delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit

# ---------------------------------------------------------------------------
# 6. 作者信息
# ---------------------------------------------------------------------------
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='Packaged by wukongdaily'/" /etc/openwrt_release 2>/dev/null

# ---------------------------------------------------------------------------
# 7. 安卓 TV 时间服务器映射
# ---------------------------------------------------------------------------
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

echo "===== 99-host.sh done $(date) =====" >> "$LOGFILE"
exit 0
