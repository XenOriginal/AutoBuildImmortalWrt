# 新固件的平台专属优化清单 —— Inspur AliMoC-MD-02-25G

**本文回答一个问题**：新固件里，哪些特性是**专门为这块硬件平台**做的，为什么。

平台身份（实测）：

| 维度 | 实测值 |
| --- | --- |
| 整机 | Inspur AliMoC-MD-02-25G，BIOS: Insyde 4.00.11，Legacy 启动（无 `/sys/firmware/efi`） |
| CPU | Intel Atom C3958（Denverton，family 6 model 95），16 线程，一律带 `vmx`/EPT/VPID/APICv |
| 网卡 | 2× Mellanox ConnectX-4 Lx（`mlx5_core`，WAN 在其上跑 PPPoE）+ 1× Intel X553（`ixgbe`） |
| 内存 | 31.2 GB（后加装） |
| 存储 | 目标盘 SAMSUNG MZMTE512HMHP（SATA M.2，`ata8`，TRIM 可用，SMART=PASSED）；现系统跑在 USB 盘 |
| 串口 | 板载 HSUART（PCI 00:1a.0）+ BIOS console redirection **57600 8N1** |

分类口径：**【专属】**= 换一台机器就不成立/不需要；**【半专属】**= 通用最佳实践，但因这台机器的用途/拓扑而成为必做；**【通用】**= 顺手加入的通用基线。

---

## 一、启动链与串口（平台最"硬"的一层）

| # | 项 | 为什么是这台机器专属 | 实测证据 | 实现位置 | 刷机后核验 |
| --- | --- | --- | --- | --- | --- |
| 1.1 | **板载 HSUART 作为内核控制台** | 8250_pci 把该 SoC 的 HSUART（00:1a.0）列入黑名单，不启用 `SERIAL_8250_MID` 就**没有串口可用** | `dmesg` 历史报 `ignoring port, enable SERIAL_8250_MID to handle`；本机物理口 = UAR0 = `/dev/ttyS4` | `build-source.sh` 注入 `CONFIG_SERIAL_8250_MID/HSU_DMA`、`NR_UARTS=16`；`host-files/etc/uci-defaults/98-hsuart-kernel-console` | `dmesg \| grep -i 8250_mid`；`cat /proc/tty/driver/serial` |
| 1.2 | **串口参数三处对齐 57600** | 本机 BIOS console redirection 实测 57600（固件默认 115200 → 乱码） | 设备侧字节率偏差 +0.07% | `CONFIG_TARGET_SERIAL="ttyS4"`、`CONFIG_GRUB_BAUDRATE=57600`、`CONFIG_GRUB_BOOTOPTS` | GRUB 菜单/内核日志在串口可读 |
| 1.3 | **Legacy + UEFI 双份镜像都产出，且配置共用** | 本机当前是 Legacy，后续要切 UEFI；两份镜像必须都在 | 官方 target 同时产出 `*-combined` 与 `*-combined-efi`，共用 `Build/grub-config` | 特性片段 `12-uefi-boot` + **闸门 6**（缺一份即判失败） | `ls /sys/firmware/efi`（切 UEFI 后）；`efibootmgr -v` |
| 1.4 | **`/boot` 必须落在分区 1** | 官方 core.img 的 early config 硬编码 `configfile (hd0,gpt1)/boot/grub/grub.cfg` —— 放别的分区号**真实部署直接起不来** | 从 `package/boot/grub2/files/grub-early.cfg` 读出并实测 | `ab/ab-layout.sh`（p1=/boot，BIOS boot 分区物理最前） | GRUB 能加载菜单并引导 |
| 1.5 | **A/B 双槽安全自升级** | 生产环境单盘、无人在场；失败必须自动回滚 | 演练：切槽 ✅、`save_env` 回写 ✅、连续失败自动回滚 ✅ | `ab/`（layout/upgrade/status/bootok/lib + 模板） | `ab-status`；连续两次未标记成功 → 自动切回 |

---

## 二、CPU / SoC 层（Denverton 特有）

| # | 项 | 为什么专属 | 实测证据 | 实现位置 |
| --- | --- | --- | --- | --- |
| 2.1 | **Intel 微码更新** | Denverton 是长周期嵌入式 SoC，BIOS 微码常年落后 | feed 有 `intel-microcode`；内核 `CONFIG_MICROCODE=y` 已内建 | 特性片段 `30-microcode` |
| 2.2 | **QAT（DH895XCC）驱动与固件** | 该 SoC **在 BIOS 里可开关 QAT**；不开就完全看不到设备 | 现机 `lspci` 无 `[0b40]`（BIOS 未开）；历史报告 BIOS 打开后为 `8086:19e2`；BIOS 打开后即应出现 | `qat-src/` + `HOST_PKGS`（既有实现）；模块加载 `/etc/modules.d/40-qat` |
| 2.3 | **AES-NI 内建 + SHA-NI/GHASH/CRC32C 模块** | 该 CPU 有 AES-NI 与 SHA 扩展，但官方基线没开 SHA-NI | 基线 `CRYPTO_AES_NI_INTEL=y`；`CRYPTO_SHA256_SSSE3` 未设；`kmod-crypto-sha256` 在 x86_64 上带 `sha256-ssse3.ko` | 特性片段 `20-crypto-accel` |
| 2.4 | **不加 CPU 微架构优化（`-march`）** | 上游**没有** `CONFIG_MGOLDMONT` 符号；镜像要跨 x86 通用 | `arch/x86/Kconfig.cpu` 实测只有 `GENERIC_CPU/MCORE2/MATOM` | 维持 `GENERIC_CPU=y`（文档说明） |
| 2.5 | **不牺牲性能的缓解措施策略** | 该 CPU 对主要硬件漏洞**免疫**，没必要付性能代价 | `meltdown/l1tf/mds = Not affected`；仅 spectre_v2 用 Retpolines | 保持默认（**不做** `mitigations=off`） |
| 2.6 | **[可选] 内核时钟 100→250Hz** | 16 线程上 tick 提升有代价，需实测 | 基线 `CONFIG_HZ_100=y` | 可选片段 `40-net-tune` |
| 2.7 | **调频/功耗不改默认** | 当前 `schedutil`（acpi-cpufreq 驱动）；改 `performance` 会动功耗/温度曲线，需数据支撑 | `/sys/.../scaling_governor=schedutil` | `/etc/hw-tune.conf` 里一行可切 |

---

## 三、虚拟化层（这台机器要当 KVM 宿主）

| # | 项 | 为什么专属 | 实测证据 | 实现位置 |
| --- | --- | --- | --- | --- |
| 3.1 | **KVM 宿主能力固化** | CPU 全特性具备，但官方固件**一个 KVM 模块都没有**、`/dev/kvm` 不存在 | 手工装包后 `/dev/kvm` 出现，`qemu -accel kvm -cpu host` 跑通 SeaBIOS | 特性片段 `10-kvm-host` |
| 3.2 | **VT-d 预留（IOMMU + VFIO）** | 该板 ACPI 有 DMAR（硬件在），但内核 `INTEL_IOMMU_DEFAULT_ON` 未开、**VFIO 完全没编** | `iommu_groups=0`、`/sys/class/iommu` 空、无 vfio 模块 | 特性片段 `15-iommu-vtd` + 命令行 `intel_iommu=on iommu=pt` |
| 3.3 | **THP + HugeTLBFS** | 官方基线**内核里没有大页支持**，客户机内存 TLB 效率受限 | 基线 `TRANSPARENT_HUGEPAGE`/`HUGETLBFS` 均 `not set`；现无 `/sys/kernel/mm/transparent_hugepage` | 特性片段 `45-kvm-net-perf` |
| 3.4 | **vhost-net / QEMU / SeaBIOS+EFI 固件** | 本机既无 vhost 也无 QEMU 二进制 | 手工验证 `-accel kvm` 可用 | 特性片段 `10-kvm-host` |
| 3.5 | **A/B 升级演练用 KVM 完成** | 生产盘不能拿来做第一次实验 | 铺盘→启动→切槽→自动回滚 全链路在 KVM 通过 | `ab/README.md` 第四节 |

---

## 四、内存 / 存储层

| # | 项 | 为什么专属 | 实测证据 | 实现位置 |
| --- | --- | --- | --- | --- |
| 4.1 | **脏页回写上限压到 32/64MB** | 系统跑在**慢速 USB 盘**上（实测小文件回写仅 ~0.44MB/s），默认策略会堆积成堰塞湖 → 整机 D 状态挂死 | 历史故障现象 | 既有 `host-files/etc/sysctl.conf`（保留） |
| 4.2 | **zram swap + swappiness=150** | 配合上面的回写限制，优先换出匿名页 | 现机 zram 15.6G 生效 | `host-files/etc/init.d/host-zram`（**本轮修好 shebang + 补 rc.d**，此前是死代码） |
| 4.3 | **f2fs overlay / NFS 客户端** | 现固件 overlay 就是分区内 loop f2fs；数据在 NFS 上 | `losetup` 实测 overlay 偏移机制 | 既有 `HOST_PKGS`（kmod-fs-f2fs/nfs） |
| 4.4 | **SSD SMART 巡检** | 迁移目标就是那块三星 SATA M.2，需要健康基线 | `smartctl -H /dev/sda` = **PASSED**；USB 盘无 SMART | `hw/hw-health` + `hw-healthd` |
| 4.5 | **单盘 A/B 分区布局 + 数据分区** | 单盘、无冗余，必须靠 A/B 而非备份盘兜底 | `sda` 原为空盘（前 512B 全 0） | `ab/ab-layout.sh` |
| 4.6 | **数据两轮迁移（seed/final）+ 校验** | 41GB Docker 数据在 U 盘，停机时间必须可控 | U 盘读 ~17MB/s → 全量停机不可接受 | `ab/migrate-data.sh` |

---

## 五、网络层

| # | 项 | 为什么专属 | 实测证据 | 实现位置 |
| --- | --- | --- | --- | --- |
| 5.1 | **按实际网卡装驱动（mlx5 ×2 + ixgbe ×1）** | 该机就是这两种网卡；WAN 在 ConnectX-4 Lx 上跑 PPPoE | `lsmod`/`lspci` 实测 | 既有 `HOST_PKGS` |
| 5.2 | **转发 UDP GRO 开启** | 这两款网卡都支持该特性且**默认关闭**；对 PPPoE 上 UDP/QUIC/游戏吞吐有正收益 | 实测 `ethtool -K` 可切换，已在运行机三张网卡生效 | `hw/hw-tune`（S98）+ `/etc/hw-tune.conf` |
| 5.3 | **软件 flowtable 已开（28 条流实测在 OFFLOAD）** | 官方 fw4 默认已开；硬件卸载对本机（PPPoE）无收益 | `nft list ruleset` 可见 `flowtable ft` | 既有配置（**刻意不折腾 NIC 硬件卸载**） |
| 5.4 | **BBR + fq_codel + TFO + tw_reuse** | 该机是网关/代理宿主，拥塞控制与队列算法直接影响体验 | 运行中 `bbr`、`fq_codel`、`tcp_fastopen=3`、`tcp_tw_reuse=2` | 既有 `host-files/etc/sysctl.conf`（本轮**扩写**） |
| 5.5 | **突发/端口/队列参数** | 10G 网卡 + Docker/NFS/代理并发 | 实测 before→after：backlog 1000→16384、端口范围放宽、somaxconn 4096→8192、syn_backlog 2048→8192、`notsent_lowat`=128K（BBR 延迟优化） | `host-files/etc/sysctl.conf`（已在运行机生效） |
| 5.6 | **队列算法能力 sch_fq / sch_cake** | 基线里没有；BBR 原配 `fq`，SQM 需要 `cake` | 基线 `NET_SCH_FQ`/`NET_SCH_CAKE` 未设；默认仍 `fq_codel` | 特性片段 `45-kvm-net-perf`（只补能力） |
| 5.7 | **未来：QAT 卸载 IPsec/WG** | 该 SoC 带 QAT（BIOS 待开） | 见 2.2 | 既有 QAT 包；文档说明触发条件 |
| 5.8 | **不做 NIC 硬件 TC 卸载** | WAN 是 PPPoE，硬件卸载覆盖不到主路径；`NET_ACT_CT` 依赖 `NF_FLOW_TABLE=m` 只能 `=m`，还需自建 kmod 包 → 收益≈0 | 官方基线 `NET_CLS_*` 全未开；实测 `hw-tc-offload: off [fixed]` | 见 `FEATURES.md` 4.1 |

---

## 六、可靠性与运维

| # | 项 | 为什么专属 | 实测证据 | 实现位置 |
| --- | --- | --- | --- | --- |
| 6.1 | **硬件看门狗（iTCO）+ 用户态喂狗** | Denverton 有 iTCO 看门狗；本机历史上出现过整机挂死，只能断电 | `iTCO_wdt.ko` 在固件里但 `/dev/watchdog` 不存在、无喂狗服务 | `hw/hw-watchdog`（S96，等 `boot_ok=1` 才 arm） |
| 6.2 | **温度/健康周期巡检** | 被动散热 SoC + 新 SSD，需要长期可观测 | coretemp 52–55°C（high 75/crit 95）、acpitz 26.8°C | `hw/hw-health` + `hw-healthd`（S97，15min） |
| 6.3 | **启动序号约束 95/96/97/98** | A/B 的"启动成功标记"必须早于喂狗与巡检，否则会掩盖回滚判定 | 设计约束（本轮实测 `USE_PROCD` 坑后修复） | 各 init 脚本 `START=` |
| 6.4 | **产物级闸门（2/5/6）** | 这台机器历史上出过"看着编译成功、实际没生效"的固件 | 闸门 5 断言 `expect_pkgs`；闸门 6 断言双启动镜像 | `build-source.sh` |

---

## 七、通用基线（非平台专属，顺手补齐）

- 特性片段机制本身（`features/` + `apply-features.sh`）：让上述所有项可插拔、可验收
- `efibootmgr` + `efivarfs`（UEFI 工具链）
- `grub2-editenv`（读写 grubenv）
- crypto kmod 集合（sha1/sha256/ghash/crc32c）
- 镜像精简选项（关 DEBUG_INFO/BTF，默认关）
- A/B 设备侧工具的**依赖收敛**：裸 GPT/MBR 解析，不依赖 parted/blkid/losetup

---

## 八、刻意不做（附原因）

| 项 | 原因 |
| --- | --- |
| 安卓式 Virtual A/B（dm-snapshot + update_engine） | OpenWrt 无此栈，等于自研 OTA 框架；改为物理 A/B |
| NIC 硬件 TC 卸载 | 本机 WAN=PPPoE，主路径覆盖不到（5.8） |
| CPU `-march=goldmont` / `CONFIG_MGOLDMONT` | 上游无此符号；牺牲跨机通用性 |
| 共享 overlay 分区 | 两次对照实验证明 OpenWrt x86 固定用分区内 loop overlay（`ab/README.md` 第五节） |
| `mitigations=off` | 该 CPU 对主要漏洞免疫，收益小、风险大（2.5） |
| `default_qdisc=fq` / `tcp_ecn=1` | 策略取舍，写在 `sysctl.conf` 注释项，需要时一行开启 |

---

## 九、刷机后一次性核验（复制粘贴即可）

```sh
# 1) 平台身份
uname -a; grep -m1 'model name' /proc/cpuinfo; lspci -nn | grep -E 'Mellanox|15c2'

# 2) 串口与启动链
dmesg | grep -iE '8250_mid|hsu_dma'; cat /proc/tty/driver/serial | head -6
zgrep -E 'SERIAL_8250_MID|HSU_DMA|NR_UARTS|IKCONFIG' /proc/config.gz

# 3) CPU/加速
zgrep -E 'TRANSPARENT_HUGEPAGE|HUGETLBFS|CRYPTO_SHA256_SSSE3|NET_SCH_FQ|NET_SCH_CAKE' /proc/config.gz
dmesg | grep -i microcode; ls /lib/modules/$(uname -r) | grep -E 'sha256-ssse3|ghash|qat'
for v in meltdown l1tf mds; do echo "$v: $(cat /sys/devices/system/cpu/vulnerabilities/$v)"; done

# 4) 虚拟化
ls -l /dev/kvm; lsmod | grep -E 'kvm|vhost|vfio'
ls /sys/kernel/iommu_groups/ | wc -l      # BIOS 开 VT-d 后应 >0
cat /sys/kernel/mm/transparent_hugepage/enabled   # 期望 [madvise]

# 5) 网络
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
       net.core.netdev_max_backlog net.ipv4.tcp_notsent_lowat
for i in eth0 eth1 eth2; do echo "$i: $(ethtool -k $i | awk '/rx-udp-gro-forwarding/{print $2}')"; done
nft list ruleset | grep -A3 flowtable

# 6) 可靠性与 A/B
ls -l /dev/watchdog; logread | grep -E 'hw-watchdog|hw-tune|hw-health'
hw-health; ab-status
```

---

## 十、状态一览

| | 条目 |
| --- | --- |
| **平台专属**（换机器即不成立） | 1.1–1.5、2.1、2.2、2.3、2.7、3.1–3.4、4.1–4.5、5.1–5.5、6.1、6.2 |
| **半专属**（通用实践，因本机用途/拓扑成为必做） | 2.6、3.5、4.6、5.6、6.3、6.4 |
| **通用基线** | 第七节（特性片段机制、efibootmgr/efivarfs、grub2-editenv、crypto kmod、镜像精简可选、依赖收敛） |
| **刻意不做** | 第八节（VAB、NIC 硬件 TC 卸载、`-march`、共享 overlay、`mitigations=off`、`fq`/ECN 默认切换） |
| **待外部条件** | QAT 与 VT-d 直通（BIOS 开关）、A/B 实机切换（维护窗口）、CI 产物（构建中） |

> 所有条目均可在仓库内定位：编译期项见 `x86-64-host/features/*.conf`，
> 运行期项见 `x86-64-host/hw/` 与 `host-files/`，A/B 与迁移见 `x86-64-host/ab/`，
> 依据与演练记录见 `x86-64-host/FEATURES.md` 与 `x86-64-host/ab/README.md`。
