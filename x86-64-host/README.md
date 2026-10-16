# 宿主机专属固件（x86-64 Host）—— 架构与运维总览

> 专为 **Inspur AliMoC-MD-02-25G**（x86/64 软路由 + 容器宿主 + KVM 虚拟化服务器）定制的源码编译固件。
> 包含 **物理双槽 A/B 高可用自升级**、**端到端硬盘防掉电拓扑加固**、**KVM 硬件虚拟化** 与 **UEFI 在线配置** 支持。

---

## 一、 硬件平台规格基准

| 硬件维度 | 实机配置与参数 | 平台特性与固件适配状态 |
| :--- | :--- | :--- |
| **SoC / CPU** | **Intel Atom C3958** (Denverton, 14nm, 16核/16线程, 2.0GHz, 16MB L2) | 内置 Intel 官方 Denverton 最新 CPU 微码，内建 AES-NI，补齐 SHA-NI/GHASH/CRC32C 硬件加速指令 |
| **内存 (RAM)** | **32 GB DDR4** ECC Registered | 开启透明大页（THP `madvise`）与显式大页（`HugeTLB`），降低 KVM 客户机内存映射 TLB miss；绝对字节脏页写回控制 |
| **系统盘 (新)** | **477 GB SATA M.2 SSD** (SAMSUNG PM851 / MZMTE512HMHP) | 划分 A/B 双槽（各 2GB）+ 共享大容量 `/Lager` 数据盘（~470GB），全流程防断电文件系统加固 |
| **网卡 (NIC 1)** | **Mellanox ConnectX-4 Lx** 双口 25GbE (PCIe 3.0 x8, `mlx5_core`) | eth0 (WAN PPPoE) + eth1 (LAN)，开启软件 Flowtable 转发快路径，支持 SR-IOV 虚拟化 |
| **网卡 (NIC 2)** | **Intel X553** 双口千兆/万兆电口 (`ixgbe`) | eth2，板载 RJ45 接口，直通/网桥支持 |
| **协处理器** | **Intel DH895XCC QAT** (QuickAssist Technology) | 固件源码编译阶段打入 QAT SDK 内核模块与固件包，BIOS 开启后即可用于 IPSec/TLS 硬件卸载加速 |
| **控制台** | **板载 HSUART** (`ttyS4` @ 57600 8N1) | 内核打入 8250_mid 补丁，BIOS、GRUB 引导与 Linux 控制台三处严格对齐 |

---

## 二、 三大构建变体：`clean-ab` / `full` / `clean`

同一份源码仓库 + 同一套特性片段，可按需编译产出三种不同定位的固件：

| 评估维度 | **clean-ab（推荐·纯净A/B版）** | **full（宿主机全量版）** | **clean（纯净非A/B版）** |
| :--- | :--- | :--- | :--- |
| **固件定位** | **专为本机 SSD 打造的纯净高可用基线** | 包含全部试验性/特定专属脚本的全量包 | 供其他标准双分区 x86 机型使用的分发版 |
| **内核优化** | ✅ 全部特性（KVM/VT-d/微码/加密/THP+HugeTLB/文件系统/efivar…） | ✅ 完全相同 | ✅ 完全相同 |
| **A/B 补丁与工具** | ✅ **完整集成**（GRUB2 loadenv 补丁 + ab 工具链 + Web 升级） | ✅ 完整集成 | ❌ 不集成（用官方两分区） |
| **硬盘防掉电拓扑** | ✅ **完整加固**（sysctl 64MB 脏页限制 + /boot ro + 存储门控） | ✅ 完整加固 | ❌ 官方默认 |
| **额外侵入式脚本** | ❌ **彻底剥离**（无 watchdog/healthd/tune/mem/99-host 等） | ✅ 注入全量脚本 | ❌ 不注入 |
| **升级方式** | **Web 界面 A/B 升级 / `ab-upgrade`**（sysupgrade 自动转接守护）| Web 界面 / `ab-upgrade` | **常规 `sysupgrade -v`** |
| **产物名称** | `ImmortalWrt-x86-64-Host-QAT-source-clean-ab` | `ImmortalWrt-x86-64-Host-QAT-source` | `ImmortalWrt-x86-64-Host-QAT-source-clean` |

> 💡 **为什么推荐 `clean-ab`？**  
> 软路由和容器宿主最重要的生命线是**底层绝对稳定**。`clean-ab` 将所有非必要的常驻后台守护（看门狗自动喂狗重启、温度巡检轮询、CPU governor 绑定、写死固定 IP 的脚本等）全部取消，不夹带机型私货，先把纯净的高可用底层环境建立好；待正式在 SSD 上稳定运行后，后续再根据需要通过专用 Agent 逐步引入扩展服务。

---

## 三、 核心架构设计

### 1. 物理双槽 A/B 高可用自升级体系

```
/dev/sda (477G SATA SSD)
  ├─ p1: 512 MiB  /boot (vfat, LABEL=kernel, 常态只读)  -> grub.cfg / grubenv / vmlinuz.a / vmlinuz.b
  ├─ p2: 1 MiB    BIOS boot                             -> Legacy GRUB core.img (内嵌 loadenv)
  ├─ p3: 2048 MiB 槽 A rootfs (squashfs + 槽内 F2FS overlay)
  ├─ p4: 2048 MiB 槽 B rootfs (squashfs + 槽内 F2FS overlay)
  └─ p5: ~470 GiB /Lager (ext4, 挂载 barrier=1,commit=5) -> Docker 容器与 KVM 虚拟磁盘
```

- **引导器级自动回滚状态机**：
  状态由 `/boot/boot/grub/grubenv` 维护：
  - `next_entry`：由升级工具写入目标槽（`0`=A, `1`=B），GRUB 引导后立即清除（单次试跑）；
  - `boot_ok`：由系统健康检测服务 `/etc/init.d/ab-bootok` 写入。只有当默认路由通畅、网关正常时才写入 `1`；
  - `bootcount`：GRUB 每次引导时若发现 `boot_ok != 1` 则递增计数；若连续 2 次无法成功启动并标记，**GRUB 引导器将在物理上自动切回上一个正常槽位**，无需串口人工救砖！
- **Web 端升级看板（替换原生 sysupgrade）**：
  在 LuCI 的 **“系统 -> 备份/升级”** 中提供了全新的 A/B 双槽可视化看板：
  - 实时对比 Slot A / Slot B 运行状态（ACTIVE / STANDBY）、PARTUUID 与内核构建时间；
  - 呈现 GRUB 状态机指示器，支持**一键切换引导槽位并重启**以及**手动确认健康**；
  - 升级上传镜像后自动进行分区校验，支持**保留当前系统配置（Overlay 迁移）**，并在前台流式展示升级进度。
- **命令行误操作防护**：
  在 `/usr/sbin/sysupgrade` 部署守护包装器。当管理员在 SSH 终端敲击 `sysupgrade <镜像>` 时，自动拦截可能导致整盘变砖的覆写行为，并无缝转接至 `ab-upgrade` 执行非活动槽写入。

---

### 2. 端到端硬盘防掉电拓扑加固

软路由随时可能面临突然拔电或断电重启，固件通过多层联动解决掉电丢写与文件系统损坏问题：

1. **`/boot` 常态只读挂载（ro）**：
   `/boot` 为 FAT32 文件系统，容易因掉电写 FAT 表而损坏。固件通过首启脚本配置为 `ro,noatime` 挂载；只有在执行 `ab-upgrade` 写入新内核或更新引导变量时，由底层库 `ab-lib.sh` 临时动态 `mount -o remount,rw /boot`，写完并 `sync` 完毕后立即切回 `ro`。平日拔电绝对免疫。
2. **内核脏页绝对字节写回控制（`sysctl.conf`）**：
   针对 32GB 大内存机器，抛弃默认的百分比脏页（默认允许数 GB 脏数据滞留内存），严格限制：
   ```ini
   vm.dirty_bytes = 67108864          # 内存中脏页达 64MB 强制阻塞刷盘
   vm.dirty_background_bytes = 33554432 # 内存脏页达 32MB 后台异步刷盘
   vm.dirty_expire_centisecs = 500     # 脏页最长存活 5 秒
   vm.dirty_writeback_centisecs = 200  # 刷盘线程每 2 秒唤醒一次
   ```
   突然断电时，全系统滞留未写盘的临时数据严格控制在 32~64MB / 5秒 内。
3. **数据盘 `/Lager` 屏障挂载**：
   采用 `barrier=1,commit=5,errors=remount-ro,noatime`，强制向 SSD 固件发送硬件落盘刷新指令（FLUSH/FUA），事务提交周期压短到 5 秒。
4. **存储自愈与 Docker 门控（`hw-storage-guard`）**：
   开机时先于 Docker 启动（S98 先于 S99），对关键分区进行预检修复；若数据盘无法挂载，**强行禁用 dockerd 自启并报警**，坚决杜绝“Docker 在只读根目录自动生成假空目录导致容器镜像看起来全丢失”的次生灾害。

---

### 3. KVM 硬件虚拟化与运行模式建议

固件已集成 `kmod-kvm-intel` 与 QEMU 10.1.2：
- **CPU 硬件支持**：Atom C3958 16 线程全量支持 VMX、EPT、VPID、unrestricted_guest 与 APICv，宿主机实测 `/dev/kvm` 存在。
- **IOMMU / VT-d 设备直通**：内核编译开启 `INTEL_IOMMU=y` 与 `CONFIG_VFIO`，命令行预置 `intel_iommu=on iommu=pt`，BIOS 开启 VT-d 后可直通 ConnectX-4 25G VF 或 PCIe 设备。
- **运行模式建议**：
  - **首选 Docker 容器化 KVM（如 `dockur/windows` 等）**：环境完全隔离，不污染 OpenWrt 系统，自包含 glibc 与 Web-VNC 控制台，与现有容器运维范式统一；
  - **备选 原生 QEMU 脚本 + procd 守护**：直接调用系统内 `/usr/bin/qemu-system-x86_64`，虚拟网卡 tap 直挂 `br-lan`，开销为零，性能最极致；
  - **禁止 原生 libvirt/virsh**：OpenWrt 环境下依赖树严重缺失，易与底层 netifd/nftables 冲突引发网络死锁。

---

### 四、 快速部署与操作手册

#### 1. 全新安装到内置 SSD（铺设 A/B 布局）
在当前运行的 U 盘系统上，将下载的 `ImmortalWrt-x86-64-Host-QAT-source-clean-ab` 镜像上传至 `/tmp/`，对空盘 `/dev/sda` 执行铺盘：
```bash
# 1. 确保安装器依赖就绪
apk add parted e2fsprogs dosfstools f2fs-tools grub2-editenv

# 2. 一键铺盘并写入双槽 A/B 镜像 (会格式化 /dev/sda)
/workspace/_wrt/repo/x86-64-host/ab/ab-layout.sh \
  --disk /dev/sda \
  --image /tmp/immortalwrt-x86-64-generic-squashfs-combined.img.gz \
  --yes

# 3. 关机并拔掉旧 U 盘，在 BIOS 中将 /dev/sda 设为第一启动项即可启动！
```

#### 2. 日常 A/B 固件升级
- **方式 A（Web 界面升级·最直观）**：
  进入 LuCI **“系统” -> “备份/升级”**，在【A/B 双槽平滑升级】卡片中点击上传新的 `.img.gz` 镜像，保持勾选“保留并迁移当前系统配置”，点击“写入备用槽”；写入完成后点击“立即重启切换”即可。
- **方式 B（终端命令行升级）**：
  ```bash
  # 升级会自动写入当前非活动槽，并迁移当前 Overlay 配置
  ab-upgrade /tmp/immortalwrt-x86-64-generic-squashfs-combined.img.gz --yes
  reboot
  ```

#### 3. 槽位状态查看与手动切换
```bash
# 查看当前双槽状态与引导健康标记 (支持 --json 结构化输出)
ab-status

# 手动将引导槽切换至另一个槽 (一次性试跑模式，启动失败自动回滚)
ab-switch toggle --reboot --yes

# 手动确认当前槽位健康 (将 boot_ok=1 写入 grubenv)
/etc/init.d/ab-bootok confirm
```

#### 4. UEFI 运行时变量查看与在线配置
当系统以 UEFI 模式启动后，可通过固件内置的标准工具查看和修改 UEFI NVRAM 变量：
```bash
# 列出系统当前所有 UEFI 变量
efivar -l

# 查看 EFI 启动项与引导优先级
efibootmgr -v

# 在线修改启动优先级
efibootmgr -o 0001,0002
```
若需批量导出或修改 InsydeH2O Setup 完整表单（类似 BIOS 界面中的 `H2oUve Configuration`），推荐将 `H2OUVE.efi` 与 `shellx64.efi` 放入 `/boot/efi/tools/`，利用 GRUB 一次性切入 UEFI Shell 执行 `H2OUVE.efi -gv setup.txt` 导出与修改。

---

## 五、 如何触发 GitHub CI 源码构建

固件源码工作流已配置完成（`.github/workflows/build-x86-64-host-source.yml`）：

1. 访问 GitHub 仓库 Actions 页面：
   👉 **`Build 25.12.x x86-64 Host SOURCE (QAT enabled)`**
2. 点击 **Run workflow**：
   - `variant`：选择默认推荐的 **`clean-ab`**（纯净 A/B 版）；
   - 其余参数保持默认（分支 `openwrt-25.12`，容量 `1024MB`，Docker `yes`）；
3. 构建完成后，在 Artifacts 产物区下载 **`ImmortalWrt-x86-64-Host-QAT-source-clean-ab`**（内含 Legacy combined 与 UEFI combined 双镜像及校验和）。
