# Inspur AliMoC-MD-02-25G 宿主机 UEFI / BIOS 配置调整与 H2OUVE 调优指南

> **设备平台**：Inspur AliMoC-MD-02-25G（Intel Atom C3958 Denverton 16核 / 32GB DDR4 / 双25G mlx5 + 双千兆 ixgbe）  
> **BIOS 版本**：INSYDE Corp. **MOC.4.00.11**（2019-09-29，Rev. 5.0，InsydeH2O）  
> **串口控制台基准**：板载 HSUART（`ttyS4` @ 57600 8N1，或重定向 `ttyS0` @ 57600 8N1）

---

## 〇、 核心结论速览

1. **为什么此前在 Linux 系统下无法调整 UEFI 变量？**  
   当前宿主机从 U 盘启动时，使用的是 **Legacy BIOS / CSM 模式**（系统内无 `/sys/firmware/efi` 目录）。在该模式下，内核不挂载 EFI Runtime Services，任何用户态工具（`efibootmgr` / `efivar`）都无法直接与 NVRAM 通信。
2. **迁移到 SSD 后开启 UEFI 调整的条件**：  
   新 SSD 写入了 UEFI 合盘固件（`*-combined-efi.img.gz`），在 BIOS 中切换为 **UEFI 启动模式** 后，内核即可加载标准 `efivarfs`，支持在 Linux 运行态在线读写。
3. **主板已内建 H2oUve SMM 处理模块**：  
   根据实机 BIOS 菜单取证，在 `Advanced -> H2oUve Configuration` 中证实出厂固件已集成 InsydeH2O UVE 运行时。推荐使用 **UEFI Shell + H2OUVE.efi** 方式进行无损全量导出与导入。

---

## 一、 BIOS 关键配置清单（改什么、不碰什么）

根据历史功耗与稳定性实测（RAPL 物理功耗计），核定以下改动策略：

### 1. 必改 / 推荐项（降功耗与开启新特性）

| 设置菜单路径 | 设置项名称 | 推荐目标值 | 实际收益 / 作用 |
| :--- | :--- | :--- | :--- |
| **`Boot -> Boot Type`** | **`Boot Type`** | **`Dual Boot Type`** 或 **`UEFI Boot Type`** | 允许从 SSD 的 EFI ESP 分区启动，激活系统内 efivarfs 接口 |
| **`Advanced -> South Bridge Chipset Configuration`** | **`IQAT` / `Intel QuickAssist Technology`** | **`Enabled`** | 启用片内 DH895XCC QAT 协处理器（固件已编译驱动与固件包） |
| **`Advanced -> PCI Subsystem Settings`** | **`PCIe 虚拟化 / VT-d`** | **`Enabled`** | 开启 Intel VT-d / IOMMU，为后续 KVM 虚拟机 PCIe 直通铺平道路 |
| **`Power -> Advanced CPU Control`** | **`Package C State limit`** | **`No Limit`** | 解除封装 C 状态锁定（注：OS 侧还需通过内核脚本解除 C6 限制以节省 0.6W） |
| **`Advanced -> Console Redirection`** | **`Baud Rate`** | **`57600`** | 与固件内核控制台 `57600 8N1` 严格对齐，避免启动切换时串口出现波特率乱码 |

### 2. 严禁改动红线（碰了会导致网络瘫痪或硬件离线）

- ⛔ **切勿禁用 00:09.0 根端口**：该根端口连接 Mellanox ConnectX-4 Lx 25G 网卡，关闭将导致 WAN（PPPoE）与 LAN 物理断开！
- ⛔ **切勿随意调整 FIA Mux Configuration**：20 条 FIA lane 出厂默认全部为 `<Lane Disabled>`（用于为片上闲置 FPGA 断电）。若未摸清走线强行开启，可能导致 PCIe 总线资源冲突。
- ⛔ **切勿修改双口 RJ45 的物理映射**：两个板载千兆口在物理硬件上即为同一网卡的物理镜像分流，BIOS 中无法将其虚拟成独立硬件。

---

## 二、 UEFI 环境下使用 H2OUVE 导出与修改配置

由于 Linux 下的 `H2OUVE-L64` 依赖特定闭源 `.ko` 内核模块（不支持 Linux 6.12 内核），**工业界最稳妥的标准做法是在 UEFI ESP 分区放置 UEFI Shell 版工具**。

### 1. 准备工具到 SSD ESP 分区
在宿主机挂载新 SSD 的 `/boot` 分区（例如 `/mnt/sda1`），创建工具目录：
```bash
mount -o remount,rw /boot
mkdir -p /boot/efi/tools/
# 放置 H2OUVE.efi 与 Shell.efi (x86_64 版本)
# /boot/efi/tools/H2OUVE.efi
# /boot/efi/tools/Shell.efi
```

### 2. 导出全量 BIOS 变量表（文本格式）
在 UEFI Shell 提示符下执行：
```shell
FS0:
cd \efi\tools
# 导出当前 BIOS 全部配置变量为可读文本
H2OUVE.efi -gv bios_config.txt
```

### 3. 修改并无损刷回
在导出的 `bios_config.txt` 中修改目标项参数后，在 Shell 中刷回并重启：
```shell
# 校验并写入修改后的配置变量
H2OUVE.efi -sv bios_config.txt
# 重启使新 BIOS 设置生效
reset
```

---

## 三、 Linux 操作系统运行态在线调优命令

在系统以 UEFI 模式启动后，直接在软路由终端执行以下指令维护：

```bash
# 1. 验证系统是否已处于 UEFI 运行时
ls -ld /sys/firmware/efi/efivars

# 2. 查看当前所有 NVRAM 变量
efivar -l

# 3. 查看 EFI 启动项与引导优先级
efibootmgr -v

# 4. 在线调整引导顺序（例如将 SSD 设为优先）
efibootmgr -o 0001,0002

# 5. OS 侧激活 CPU C6 极致节能（省 ~0.6W）
for c in /sys/devices/system/cpu/cpu*/cpuidle/state3/disable; do echo 0 > $c; done
```
