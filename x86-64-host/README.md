# 宿主机专属固件（x86-64 Host）—— 总览

> 面向 **Inspur AliMoC-MD-02-25G**（x86/64 软路由 + NAS/容器宿主）的源码构建固件。
> 本目录是整个仓库里"这台机器专属"的那一部分；仓库其余目录是其他机型的自动构建配置。

**最新构建状态**：run **#22**（commit `d396d63`）✅ 成功，产物 `ImmortalWrt-x86-64-Host-QAT-source`（约 810 MB）。
构建日志与产物：https://github.com/XenOriginal/AutoBuildImmortalWrt/actions/runs/38201531129

---

## 一、这台机器的目标形态

| 维度 | 现状 → 目标 |
| --- | --- |
| 系统盘 | 现在跑在 **U 盘**（`/dev/sdb`）→ 迁移到 **477 G SATA SSD**（`/dev/sda`，三星 MZMTE512HMHP，SMART=PASSED） |
| 分区 | 单槽 → **A/B 双槽**（`p1 /boot` + `p2 BIOS boot` + `p3 槽A` + `p4 槽B` + `p5 /Lager`） |
| 升级方式 | 单槽整盘覆盖、失败要人到场 → **写非活动槽 + 重启切换 + 失败自动回滚** |
| 引导 | Legacy BIOS（后续可切 UEFI，两份镜像都已产出） |

## 二、这份固件为你做了哪些"平台专属"的事

完整清单见 **[`PLATFORM.md`](PLATFORM.md)**（按硬件域组织，每条含实测证据与核验命令）。速览：

- **启动/串口**：板载 HSUART 当内核控制台（`ttyS4`）、BIOS 串口 57600 三处对齐、`/boot` 固定为分区 1（官方 core.img 硬编码 `(hd0,gpt1)`）、Legacy+UEFI 双份镜像
- **CPU**：Intel 微码、QAT（BIOS 待开）、AES-NI 内建 + SHA-NI/GHASH/CRC32C
- **虚拟化**：KVM 宿主能力（官方固件原本一个 KVM 模块都没有）、VT-d/IOMMU + VFIO 预留、THP/HugeTLB
- **网络**：BBR + fq_codel（已生效）+ `netdev_max_backlog`/端口范围/`notsent_lowat` 等进阶项、转发 UDP GRO、`sch_fq`/`sch_cake` 能力
- **存储**：exFAT/NTFS/FAT32 工具链 + **FAT 默认字符集改 UTF-8**（中文名不再乱码）+ 周期 `fstrim`
- **内存/IO**：按存储层级自适应（U 盘保留保守回写策略；SSD 切大内存策略 + hung_task 检测）
- **可靠性**：iTCO 看门狗 + 健康巡检（温度/SSD 磨损）+ A/B 自动回滚

编译期清单（每一项的开关与依据）见 **[`FEATURES.md`](FEATURES.md)**；A/B 设计与演练记录见 **[`ab/README.md`](ab/README.md)**。

## 三、怎么构建

**CI 工作流**：`Build 25.12.x x86-64 Host SOURCE (QAT enabled)`（文件 `.github/workflows/build-x86-64-host-source.yml`）

- 手动触发（`workflow_dispatch`）；`features` 输入可临时开启可选特性片段（例如 `40-net-tune,50-image-slim`），留空即用仓库默认清单
- 走**完整源码编译**（不是 ImageBuilder）：只有源码编译才能改内核配置、打 grub2 补丁、装自定义包
- 耗时约 **50 分钟 ~ 2 小时**；产物名 `ImmortalWrt-x86-64-Host-QAT-source`

**构建流水线里的硬闸门**（不通过就不出固件）：

| 闸门 | 断言内容 |
| --- | --- |
| 0 | **choice 完整性**：凡启用的内核 choice，其每个成员都必须显式取值（否则 syncconfig 会提问并失败） |
| 1 | 用上游真实 `kconfig.pl` 预演合并内核配置 |
| 2 | 内核**最终** `.config`：串口符号 + 特性片段注入的 kconfig 行 |
| 3 | 固件 `.manifest` 里 QAT 三包存在 |
| 4 | rootfs 暂存区里的覆盖层文件与 QAT 驱动 |
| 5 | 固件 `.manifest` 里**特性片段声明的每个包**（`expect_pkgs`） |
| 6 | **Legacy 与 UEFI 两份合盘镜像都在** |

## 四、产物里有哪几种镜像

| 文件 | 用途 |
| --- | --- |
| `*-generic-squashfs-combined.img.gz` | Legacy BIOS 启动的合盘镜像（squashfs 根） |
| `*-generic-squashfs-combined-efi.img.gz` | **UEFI** 启动的合盘镜像 |
| `*-generic-ext4-*.img.gz` | ext4 根版本（同上两种启动方式） |
| `*-1024.manifest` | 固件内**已安装软件包权威清单**（验收用） |
| `sha256sums` | 校验和 |

> 说明：A/B 安装器吃的是**合盘镜像**（`*-combined*.img[.gz]`），它会把镜像里的内核与 rootfs 分别铺到两个槽。

## 五、首次启动与默认访问

- 管理地址：`10.0.0.1`（LAN，`br-lan`），用户名 `root`，**无密码**
- 串口控制台：**`ttyS4` @ 57600 8N1**（板载 HSUART）；同时保留 `ttyS0` 候选，便于 BIOS 重定向场景
- 若使用 A/B 布局：启动后先跑 `ab-status` 确认槽位与 grubenv 状态

## 六、文档地图

| 文档 | 内容 |
| --- | --- |
| **本文件** | 固件总览、构建方式、产物 |
| [`PLATFORM.md`](PLATFORM.md) | **哪些是这台机器专属的优化**（含实测证据、核验命令、刻意不做项） |
| [`FEATURES.md`](FEATURES.md) | 编译期特性清单与依据（含可选片段） |
| [`features/README.md`](features/README.md) | 特性片段机制：如何新增一项优化 |
| [`INSTALL.md`](INSTALL.md) | **部署 / 安装 / 升级 / 回滚手册（A/B 双槽）** ← 运维必读 |
| [`ab/README.md`](ab/README.md) | A/B 设计、演练结果、V1 实验结论、实施阶段 |
| [`migrate-data.sh`](ab/migrate-data.sh) + `ab/README.md` | 从现有系统迁移数据的脚本与流程 |
| `AUDIT-*.md` / `BUILD-REPORT.md` / `FIRMWARE-REPORT-*.md` | 历史审计与构建报告（背景资料） |
