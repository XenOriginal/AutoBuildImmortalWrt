# ImmortalWrt Host-QAT 固件 说明与编译报告

**机型**：Inspur AliMoC-MD-02-25G（x86/64 宿主机软路由）
**源码分支**：ImmortalWrt `openwrt-25.12`（25.12-SNAPSHOT，`r0-37013c8`）
**内核版本**：Linux `6.12.108`
**构建方式**：GitHub Actions —— “Build 25.12.x x86-64 Host SOURCE (QAT enabled)”
**本次 Run**：`35494288498`（2026-09-20，✅ 成功）
**构建 commit**：`3d8808f`（`fix(qat): 补齐 kmod-crypto-qat-common 的 rng.ko 依赖`）

本固件在**源码级**集成 Intel QAT（QuickAssist Technology）DH895XCC 硬件加速驱动，并固化宿主机网络/存储/内存调优，适合作为 7.6G 内存、3 网口（2×25G Mellanox + 1×10G Intel）软路由的 NAS / 容器宿主。

---

## 一、构建产物（Artifact: `ImmortalWrt-x86-64-Host-QAT-source`）

| 固件文件 | 大小 | 说明 |
|---|---|---|
| `immortalwrt-x86-64-generic-squashfs-combined.img.gz` | 100M | squashfs 通用镜像（合盘，Legacy 启动） |
| `immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz` | 101M | squashfs 通用镜像（合盘，UEFI 启动） |
| `immortalwrt-x86-64-generic-squashfs-rootfs.img.gz` | 94M | squashfs 纯 rootfs |
| `immortalwrt-x86-64-generic-ext4-combined-efi.img.gz` | 125M | ext4 通用镜像（合盘，UEFI 启动） |
| `immortalwrt-x86-64-generic-ext4-combined.img.gz` | 124M | ext4 通用镜像（合盘，BIOS 启动） |
| `immortalwrt-x86-64-generic-ext4-rootfs.img.gz` | 118M | ext4 纯 rootfs |
| `immortalwrt-x86-64-1024.manifest` | 12K | 固件内**已安装软件包清单** |
| `sha256sums` | 1.5K | 各镜像校验和 |

> ROOTFS 分区大小：**1024 MB**（`CONFIG_TARGET_ROOTFS_PARTSIZE=1024`）。
> QAT 内核模块包已随固件编译产出并托管于 packages 目录：
> - `kmod-crypto-qat-common-6.12.108-r1.apk`
> - `kmod-crypto-qat-dh895xcc-6.12.108-r1.apk`
> - `qat-firmware-dh895xcc-2026.01.01-r1.apk`

---

## 2. 驱动（内核模块 / kernel）

### 2.1 新增：Intel QAT DH895XCC 硬件加速（本固件核心）

由于上游 ImmortalWrt 25.12 的 kmods feed（1199 个包）里**没有任何 QAT 相关项**、且内核 config 中 `CONFIG_CRYPTO_DEV_QAT_*` 全部 `is not set`，故必须源码编译启用。

**硬件**（PCIe 实测）：
```
0000:01:00.0  vendor=0x8086  device=0x19e2  class=0x0b4000  → Intel DH895XCC QAT 协处理器
```

| 模块 | 内核路径 | 作用 |
|---|---|---|
| `intel_qat.ko` | `drivers/crypto/intel/qat/qat_common/` | QAT 公共层（所有驱动共享的 API/ACL/中断层） |
| `qat_dh895xcc.ko` | `drivers/crypto/intel/qat/qat_dh895xcc/` | DH895XCC 主体驱动（AES/SHA 硬件卸载） |
| `qat_dh895xccvf.ko` | `drivers/crypto/intel/qat/qat_dh895xccvf/` | SR-IOV 虚拟功能驱动 |

加载顺序（固化于 `host-files/etc/modules.d/40-qat`）：
```
intel_qat → qat_dh895xcc → qat_dh895xccvf
```

固件 blob（`/lib/firmware/`）：
- `qat_895xcc.bin`（SHA256 3bd7958f…077）
- `qat_895xcc_mmp.bin`（SHA256 4b7bd593…3db）

**依赖闭环**（`kmod-crypto-qat-common` 的 `DEPENDS` + `HOST_PKGS`）：
`kmod-crypto-authenc`、`kmod-crypto-kpp`、`kmod-crypto-rng`、`kmod-crypto-rsa`、`kmod-lib-crc8`、`kmod-crypto-manager`、`kmod-crypto-acompress`、`kmod-crypto-hash/aead/sha1/sha256/sha512`。

> 本次修复（`3d8808f`）正是补齐缺失的 `rng.ko`（→ `+kmod-crypto-rng`），解决了 Run #13 打包阶段 `missing dependencies ... rng.ko` 的报错。

### 2.2 网络 / 存储 / 内存相关内核模块

| 模块包 | 用途 |
|---|---|
| `kmod-mlx5-core` / `kmod-mlxfw` | Mellanox**25G** 网卡（ConnectX-5）驱动 + 固件逻辑 |
| `kmod-ixgbe`（+VF） | Intel 10G（I/7）网卡，带 SR-IOV VF |
| `kmod-e1000e` | Intel 千兆（Server 板载网卡） |
| `kmod-i40e` | Intel XL710/（山有 40G 场景） |
| `kmod-r8125` | Realtek 2.5G 网卡 |
| `kmod-tg3` | Broadcom 网卡 |
| `kmod-vmxnet3` / `kmod-tun` | VMXNET3 虚拟网卡 / TUN 隧道 |
| `kmod-inet-diag` / `kmod-nft-tproxy` / `kmod-nft-socket` | 网络诊断 / NAT-回程等 |
| `kmod-tcp-bbr` | BBR 拥塞控制（配合 `sysctl` 加载 `tcp_bbr`） |
| `kmod-zram` + `zram-swap` | 内存压缩交换 |
| `kmod-fs-nfs*` / `kmod-fs-ext4` / `f2fs` / `vfat` / `msdos` / `dns64` | 网络与本地文件系统 |
| `kmod-usb-storage*` | USB 外接存储（USB-存储/UAS 三种方式） |

---

## 3. 功能性软件包（应用层）

### 3.1 管理 / 网络

| 包 | 用途 |
|---|---|
| `luci` + `luci-base` + `luci-compat` | OpenWrt Web 管理界面 |
| `luci-theme-argon` + `luci-app-argon-config` | Argon 主题（+ 简体中文 i18n） |
| `luci-app-diskman` | 磁盘分区管理 |
| `luci-app-filemanager` | 文件管理 |
| `luci-app-dockerman` | Docker 图形化管理面板 |
| `luci-i18n-*` | 全中文语言包（base/firewall/package-manager/ttyd/diskman/filemanager/dockerman/argon） |
| `dnsmasq-full` | DNS/DHCP（含 DHCP 域名映射，安卓时间服务器映射） |
| `odhcp6c` / `odhcpd-ipv6only` | IPv6 客户端 / 服务端 |
| `luci-proto-ipv6` / `luci-proto-ppp` | IPv6 / PPPoE 协议支持 |
| `ip-full` / `ipset` / `ethtool-full` | 网络配置 / 规则集 / 网卡诊断 |
| `conntrack` / `kmod-nft-tproxy` | 连接跟踪 / 透明代理辅助 |
| `ppp-mod-pppoe` | PPPoE 拨号（可动态配置账号密码） |
| `openssh-sftp-server` | SSH 文件传输 |

### 3.2 存储 / 系统 / 运维

| 包 | 用途 |
|---|---|
| `block-mount` / `automount` | U盘/块设备按需自动挂载 |
| `e2fsprogs` / `dosfstools` / `mkf2fs` / `lsblk` / `fdisk` / `parted` / `blkid` / `partx-utils` | 完整分区/格式化/块设备工具链 |
| `bash` / `curl` / `git` / `unzip` / `rsync` / `jq` / `make` / `tini` | 通用系统工具 |
| `htop` / `iftop` / `nload` / `ncdu` / `nano` / `vim-full` / `tmux` / `lsof` | 监控与编辑器 |
| `pciutils` / `usbutils` / `dmidecode` / `smartmontooles` / `lm-sensors` / `sysfsutils` | 硬件健康 / 身份识别 |
| `openssl-util` | 证书与加解密 |
| `ttyd` | Web 终端（串口/命令行，可配 UCI） |
| `docker` + `docker-compose` + `containerd` + `runc` | 容器运行时（可选，`INCLUDE_DOCKER=yes`） |

> 默认 `INCLUDE_DOCKER=yes`，故固件内置 Docker 全家桶并能用 `luci-app-dockerman` 管理。

---

## 4. 固话的宿主机调优（首启自动脚本 / 内核参数）

**入口**：`/etc/uci-defaults/99-host.sh`（仅首次刷机执行一次）+ `/etc/sysctl.conf` + `/etc/modules.d/*` + `/etc/init.d/host-zram`。

- **网络接线**：自动探测 3 网口，`eth1/eth2` 桥接进 `br-lan`（管理口），第一个物理口作 `wan`（DHCP 或 PPPoE）。
- **LAN 地址**：默认 `10.0.0.1`（可在 dispatch 时自定义 `custom_router_ip`）。
- **防火墙**：`wan` 入站先放开以便调试，Docker 区域 `172.16.0.0/12` 全通。
- **NFS 挂载点**：预建 `/nfs/Lager`、`/nfs/Surveillance`、`/nfs/Container`。
- **TCP 调优**（`sysctl`）：`bbr` 拥塞控制 + `fq_codel`、放大 `rmem/wmem` 至 16MB、`tcp_mtu_probing=1`、`tcp_fastopen=3`、`slow_start_after_idle=0`（高 RTT 国际链路）。
- **脏页 / zram**：`dirty_background_bytes=32M`、`dirty_bytes=64M`、`swappiness=150`；`host-zram` 把物理内存的 50% 做成 lz4 压缩 zram 交换盘。
- **SSH/TTYD**：开放所有网口访问。
- **系统信息**：`DISTRIB_DESCRIPTION='Packaged by wukongdaily'`；时区 `Asia/Shanghai`；安卓 TV 时间服务器映射 `time.android.com`→`203.107.6.88`。

---

## 5. 构建过程（本次 Run 耗时/阶段）

| 阶段 | 结果 | 说明 |
|---|---|---|
| Set up / Checkout / 磁盘清理 / 装依赖 / 配置准备 / PPPoE 校验 | ✅ | 前置环境就绪 |
| **源码编译（make world，容器内 Ubuntu 22.04）** | ✅（约 85+ 分钟） | 内核 6.12.108 与全部包编译完成 |
| 内核配置确定性流程 | ✅ | `prepare → oldconfig → syncconfig` 三步落盘，无残留 NEW 符号 |
| **Verify QAT and tuning** | ✅ | 确认产物含 `qat` .apk，QAT 模块与调优文件进固件 |
| Upload firmware（Artifact） | ✅ | 685.6 MB 上传完成 |

**本次新增提交**（`3d8808f`）修复了打包阶段缺失 `rng.ko` 的问题，使固件从 Run #12/#13 的失败推进到成功出包。
** 历史修复路径**（本固件的成熟保障）：
- `make defconfig` 生成目标基线（避免 3000+ NEW 符号卡死）
- 依赖受 `set -o pipefail` 而误报 SIGPIPE 的问题 → 切换到 `olddefconfig`
- 补装 `flex/bison/mkisofs` 等缺失工具链
- 直接写 `target config` 消除 `CRYPTO_DH_RFC7919_GROUPS` 与 `QAT_ERROR_INJECTION`（NEW）

---

## 6. 验证方法（刷机后）

```sh
# 1) 确认 QAT 驱动已加载
lsmod | grep qat          # 应见 intel_PAT, qat_dh895xcc, qat_dh895xccvf
ls /sys/bus/pci/devices/0000:01:00.0/driver

# 2) 查看硬件加速模块是否存在
find /lib/modules/6.12.108 -name '*qat*'

# 3) 确认固件内已装包
cat /etc/openwrt_release | grep -i immortal
awk '{print "APK: "$0}' /usr/lib/apk/db/installed | grep -iE 'qat|docker|bbr|zram'

# 4) 网络与调优生效
sysctl net.ipv4.tcp_congestion_control   # 应输出 bbr
swapon -show                              # 应出现 /dev/zram0

# 5) 上传校验（可选，对照 sha256sums）
sha256sum immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz
```

---

*报告生成于 2026-09-20 · 来源：构建日志 `35494288498`、`build-source.sh`、`qat-src/*/Makefile`、`host-files/*`、`x86-64-host/99-host.sh`*