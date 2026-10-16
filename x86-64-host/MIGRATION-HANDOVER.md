# 宿主机迁移切换与交接手册 (U 盘 -> SATA SSD)

> **迁移目标**：将宿主机生产环境从原 64G U 盘（`/dev/sdb`）无损迁移到内置 477G SATA SSD（`/dev/sda`），启用 **A/B 双槽高可用** 与 **防断电文件系统加固**。  
> **保护原则**：在整个操作过程中，**旧 U 盘（`sdb`）只读不删**。即便新 SSD 启动有任何意外，拔掉 SSD 或在 BIOS 中切回 U 盘即可 100% 恢复当前原样。

---

## 阶段一：数据与配置迁移状态

### 1. 核心业务配置（已暂存备份于宿主机 `/root/clean_ab_migration/`）
- ✅ **PPPoE 宽带账号密码与网络配置**：`/etc/config/network`（账号 `nbzha86576797`，密码已就绪，保持 eth0 拨号与 eth1+eth2 `br-lan` 10.0.0.1/24）。
- ✅ **OpenClash 核心与节点分流规则**：
  - `/etc/config/openclash`（包括混合模式端口、DNS 转发配置）；
  - `/etc/openclash/Datalix.yaml` 及所有节点订阅、`Country.mmdb`、`GeoIP.dat`、`GeoSite.dat`、`custom/` 自定义规则集。
- ✅ **防火墙与 DHCP 配置**：`/etc/config/firewall`、`/etc/config/dhcp`。
- ✅ **Docker 引擎配置**：`/etc/config/dockerd`（保持 `data_root=/Lager/docker` 与 DaoCloud 镜像加速）。
- ✅ **SSH 安全密钥与凭据**：`/etc/dropbear/`（保持当前免密公钥认证）。

### 2. 剥离的非核心自定义脚本清单（暂不迁移，保持环境纯净）
- ⏸️ `/etc/init.d/hw-watchdog`（看门狗自动喂狗重启服务）
- ⏸️ `/etc/init.d/hw-healthd`（温度与健康轮询守护）
- ⏸️ `/etc/init.d/hw-tune`（网卡中断软绑定与 CPU 调优）
- ⏸️ `/etc/init.d/hw-mem`（动态 zram 内存压缩伸缩）
- ⏸️ `/etc/init.d/host-zram`（旧版 zram 脚本）
- ⏸️ `/etc/init.d/hsuart-console-detect` / `/etc/init.d/qat-off`
- ⏸️ `/etc/crontabs/root` 中的抓取定时任务（新系统稳定后再行恢复）

---

## 阶段二：固件镜像获取与 SSD 铺盘操作流程

### 步骤 1：下载刚刚编译完成的 `clean-ab` 固件
在能够访问 GitHub Actions 的管理机或通过宿主机浏览器下载最新 Run **38886222964** 产物：
- 产物包：`ImmortalWrt-x86-64-Host-QAT-source-clean-ab.zip`
- 解压后取出其中的合盘镜像：
  - **UEFI 模式推荐**：`immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz`
  - **Legacy BIOS 模式**：`immortalwrt-x86-64-generic-squashfs-combined.img.gz`
- 将镜像上传至宿主机 `/tmp/clean-ab.img.gz`。

### 步骤 2：对内置 SSD（`/dev/sda`）执行一键铺盘
在宿主机终端执行：
```bash
# 1. 确保安装器权限
chmod +x /workspace/_wrt/repo/x86-64-host/ab/ab-layout.sh

# 2. 对空盘 /dev/sda 铺设 A/B 结构与格式化
/workspace/_wrt/repo/x86-64-host/ab/ab-layout.sh \
  --disk /dev/sda \
  --image /tmp/clean-ab.img.gz \
  --yes
```
铺盘完成后，`/dev/sda` 分区结构如下：
- `sda1` (512MB, vfat, LABEL=kernel) -> `/boot`
- `sda2` (1MB, bios_grub) -> Legacy BIOS 引导辅助
- `sda3` (2048MB) -> 槽 A（已预装系统）
- `sda4` (2048MB) -> 槽 B（已预装系统）
- `sda5` (~470GB, ext4, LABEL=LAGER2) -> `/Lager` 新数据盘

### 步骤 3：数据盘 `/Lager` 迁移（分两阶段）
宿主机上的 Docker 数据（`/Lager/docker`）占用约 44GB。使用仓库内的专用迁移脚本避免长时间断网：
```bash
# 阶段 3.1：在线首轮热同步（Docker 容器不停止，先拷贝 90% 数据）
/workspace/_wrt/repo/x86-64-host/ab/migrate-data.sh --target /dev/sda5 --seed --yes

# 阶段 3.2：停写并最终增量补齐（维护窗口，耗时通常只需 1~2 分钟）
/workspace/_wrt/repo/x86-64-host/ab/migrate-data.sh --target /dev/sda5 --final --yes
```

### 步骤 4：将网络、PPPoE 与 OpenClash 配置灌入新系统
挂载新系统的 Slot A overlay，将暂存的配置复制进去：
```bash
# 挂载新系统的 Slot A
mkdir -p /mnt/slot_a_boot
mount /dev/sda1 /mnt/slot_a_boot

# 将配置注入新系统对应槽位
# (注：使用仓库的 ab-lib 工具或直接将 /root/clean_ab_migration/ 内容还原)
```

---

## 阶段三：关机重启与 BIOS 引导项切换

1. **安全重启进入 BIOS**：
   在宿主机执行 `poweroff` 关机，或在重启时通过串口终端连续发送 `F2`（或 `0x1B` Esc / Del）进入 InsydeH2O Setup Utility。
2. **设置启动项**：
   - 切换到 `Boot` 选项卡；
   - 将 `SAMSUNG MZMTE512`（`/dev/sda`）上移至第一启动项（Boot Option #1）；
   - 若使用 UEFI 镜像，将 `Boot Type` 设为 `Dual Boot Type` 或 `UEFI Boot Type`；
   - 保存退出（F10 -> `[Yes]`）。
3. **退路保障**：
   拔掉旧 U 盘，妥善保管。在确认新 SSD 运行满意之前，**绝不对旧 U 盘进行格式化或覆写**。若新盘有任何问题，插回 U 盘、进 BIOS 选回 U 盘启动，1 分钟即可原样还原。
