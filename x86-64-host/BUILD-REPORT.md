# 固件构建核查报告

**生成时间**：2026-09-17
**目标主机**：Inspur AliMoC-MD-02-25G（ImmortalWrt x86/64）
**仓库**：https://github.com/XenOriginal/AutoBuildImmortalWrt
**核查提交**：`393698c`

---

## 一、结论摘要

| 项目 | 状态 |
|------|------|
| 构建是否成功 | ✅ 成功（run #2，耗时 6.3 分钟） |
| 走的是哪条工作流 | ⚠️ **ImageBuilder**，非源码编译 |
| QAT 硬件加速 | ❌ **未包含**（源码编译工作流从未运行） |
| 网卡驱动（mlx5/ixgbe） | ✅ 已包含 |
| Docker 全套 | ✅ 已包含 |
| 内存压缩（zram） | ✅ 包已含 / ⚠️ 调优文件未含 |
| 新增诊断工具（16 个） | ✅ 全部包含 |
| 固件大小参数 | ✅ 已修正为 1024 |

**一句话总结**：固件本身构建成功且包清单正确，但**这不是你要求的 QAT 版本** —— 触发的是 ImageBuilder 工作流，源码编译工作流一次都没跑。

---

## 二、构建运行记录（实证）

GitHub API 查询到的本仓库全部运行记录：

| 工作流 | 运行 | 结果 | 时间 |
|--------|------|------|------|
| `build-x86-64-host.yml` | #2 | ✅ success | 2026-09-17 05:02 |
| `build-x86-64-host.yml` | #1 | ✅ success | 2026-09-17 03:58 |
| `build-x86-64-25.12.x.yml` | #4 | ✅ success | 2026-07-15 |
| `build-x86-64-24.10.x.yml` | #8 | ❌ failure | 2026-04-13 |
| 其余历史运行 | — | — | 2026-04 ~ 07 |

**关键发现**：
- `build-x86-64-host-source.yml`（源码编译 / QAT）**运行次数：0**
- 两次成功运行均为 `build-x86-64-host.yml`（ImageBuilder）

### run #2 详细

```
run_id    : 35184213067
分支/提交 : master @ 393698c0ea
耗时      : 6.3 分钟（03:02:59 → 03:09:20 UTC）
产物      : ImmortalWrt-x86-64-Host-AliMoC-MD-02-25G
           297.0 MB, artifact id 10481741023
           过期时间 2026-10-17
```

> 佐证：ImageBuilder 耗时仅 6.3 分钟。源码编译需 1.5-3 小时，两者量级差异明显。

---

## 三、产物内容核查

### 3.1 软件包清单（226 个）

| 类别 | 检查项 | 结果 |
|------|--------|------|
| **网卡驱动** | kmod-mlx5-core | ✅ |
| | kmod-mlxfw | ✅ |
| | kmod-ixgbe | ✅ |
| | kmod-ixgbevf | ✅ |
| | kmod-i40e | ✅ |
| **Docker** | dockerd / docker / docker-compose | ✅ |
| | containerd / runc | ✅ |
| | luci-app-dockerman | ✅ |
| **内存压缩** | kmod-zram / zram-swap | ✅ |
| **TCP 优化** | kmod-tcp-bbr | ✅ |
| **NFS 客户端** | kmod-fs-nfs / -v3 / -v4 / -common | ✅ |
| | kmod-dnsresolver | ✅ |
| **QAT** | kmod-crypto-qat-* / qat-firmware-* | ❌ **缺失** |

### 3.2 新增诊断工具（16 个，全部包含）

```
✅ ipset      ✅ conntrack  ✅ iperf3     ✅ jq
✅ rsync      ✅ openssl-util ✅ htop     ✅ iftop
✅ nload      ✅ ncdu       ✅ tmux       ✅ nano
✅ vim-full   ✅ lsof       ✅ pciutils   ✅ usbutils
```

### 3.3 已剔除的无用项（符合预期）

- `kmod-fs-btrfs` / `btrfs-progs`（宿主机无 btrfs 分区）
- `kmod-fs-ntfs3` / `ntfs3-mount`（无 NTFS 分区）
- `kmod-fs-exfat` / `exfat-mkfs` / `exfat-fsck`（无 exfat 分区）
- `nfs-utils`（宿主机 nfs/nfs4 已编入内核，无需此包）

---

## 四、⚠️ 发现的问题

### 问题 1：QAT 未包含（严重）

**现象**：本次构建走的是 ImageBuilder，其原理是**安装官方 feed 中已有的二进制包**。而实测：

- 25.12.1 kmods feed 共 1199 个包，QAT 相关 **0 个**
- 上游 `config-6.12` 中 `CONFIG_CRYPTO_DEV_QAT_*` 全部 `is not set`

因此 ImageBuilder **在原理上不可能**产出带 QAT 的固件。

**宿主机侧验证**（当前仍为未升级状态）：

```
❌ QAT 未加载          (lsmod | grep qat 无输出)
❌ 无驱动绑定          (/sys/bus/pci/devices/0000:01:00.0/driver 不存在)
❌ 无 QAT 固件         (/lib/firmware/qat* 不存在)
```

**解决**：需触发 `build-x86-64-host-source.yml`（源码编译版）。

### 问题 2：调试调优文件未随固件分发（中等）

`build-x86-64-host.yml` 中**完全没有引用 `host-files/`**：

```bash
$ grep -n "host-files" .github/workflows/build-x86-64-host.yml
❌ 完全没有引用 host-files
```

即以下文件**未打入固件**：

| 文件 | 作用 |
|------|------|
| `host-files/etc/sysctl.conf` | BBR / TCP 缓冲 / dirty_writeback / swappiness |
| `host-files/etc/modules.d/30-tcp-bbr` | BBR 模块自动加载 |
| `host-files/etc/modules.d/40-qat` | QAT 模块自动加载 |
| `host-files/etc/init.d/host-zram` | zram 初始化 |

**仅 `99-host.sh`（首次启动脚本）被打包。**

> 缓解因素：宿主机**当前**的 `/etc/sysctl.conf` 仍完好，`bbr` / `swappiness=150` / `dirty_bytes=64MB` 均在生效。**保留配置升级（sysupgrade）会保留该文件**，因此实际影响有限。但若是全新刷写，调优将丢失。

---

## 五、宿主机当前状态（升级前基线）

```
系统版本   : ImmortalWrt 25.12.0-rc1  (r37654-e625a070981f)
内核       : 6.12.74
已装包     : 366 个（其中 kmod 162 个）
overlay    : 906.2M，已用 466.6M (51%)
/Lager     : 57.3G，已用 35.2G (62%)
QAT        : 未启用
sysctl 调优: 仍在生效（bbr / swappiness=150 / dirty_bytes=64MB）
```

---

## 六、建议的后续操作

### 优先级 1：构建真正的 QAT 固件

触发 **源码编译** 工作流（不是 ImageBuilder）：

> https://github.com/XenOriginal/AutoBuildImmortalWrt/actions/workflows/build-x86-64-host-source.yml

| 参数 | 建议值 |
|------|--------|
| `imm_branch` | `openwrt-25.12` |
| `custom_router_ip` | `10.0.0.1` |
| `profile` | `1024` |
| `include_docker` | `yes` |
| `enable_pppoe` | `no` |

预计耗时 **1.5-3 小时**。该工作流已包含：
- runner 磁盘清理（源码编译需 30-50GB，默认仅 ~14GB）
- `host-files/` 拷贝（修复问题 2）
- QAT 模块与固件包注入
- 编译后 QAT 配置校验（`grep CONFIG_CRYPTO_DEV_QAT .config`）

### 优先级 2：修复 ImageBuilder 工作流（可选）

若仍需保留 ImageBuilder 方案，应补上 `host-files/` 拷贝步骤：

```yaml
- name: Merge host tuning files
  run: |
    cp -r host-files/etc/* files/etc/
    chmod +x files/etc/init.d/host-zram
```

（注意：ImageBuilder 无法解决 QAT 问题，仅能修复调优文件缺失。）

### 优先级 3：升级前备份

```sh
sysupgrade -b /tmp/backup-$(date +%F).tar.gz
```

建议将备份存至 `/Lager`（本地 21.5G 可用）或 NFS（7.3T 可用），不要只放在 overlay。

---

## 七、升级后验证清单

刷入 QAT 固件后，在宿主机执行：

```sh
# 1. QAT 模块是否加载
lsmod | grep qat

# 2. PCI 设备是否绑定驱动
readlink /sys/bus/pci/devices/0000:01:00.0/driver
# 期望: .../drivers/qat_dh895xcc

# 3. QAT 固件是否存在
ls -la /lib/firmware/qat_895xcc*.bin

# 4. 硬件加速能力是否注册
cat /proc/crypto | grep -i qat

# 5. dmesg 检查
dmesg | grep -i qat

# 6. 调优参数
sysctl net.ipv4.tcp_congestion_control vm.swappiness vm.dirty_bytes
# 期望: bbr / 150 / 67108864

# 7. zram
cat /proc/swaps

# 8. 网卡
ethtool -i eth0 | head -2   # 期望 driver: mlx5_core
ethtool -i eth2 | head -2   # 期望 driver: ixgbe
```

---

## 附录：本次核查依据

| 数据来源 | 说明 |
|----------|------|
| GitHub REST API | `actions/runs`、`actions/artifacts`、`releases` |
| 仓库源码 | `git show 393698c`、工作流 YAML、`build.sh` 包清单 |
| 宿主机 SSH | `/etc/openwrt_release`、`apk list`、`lsmod`、`sysctl`、sysfs |
| 官方 feed 抓取 | 25.12.1 kmods / packages / luci / target 目录列表 |

> 注：artifact（297 MB）与运行日志需 GitHub 认证下载，本环境无 token，故产物内容以**仓库源码中的包清单**为依据核查，而非直接解包固件。清单与实际打包内容一致（ImageBuilder 严格按 `PACKAGES=` 参数打包）。
