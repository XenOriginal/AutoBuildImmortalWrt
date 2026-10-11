# 编译期优化清单 —— x86-64 Host 宿主机固件

**机型**：Inspur AliMoC-MD-02-25G (x86/64 软路由 / NAS / 容器宿主)
**基线**：ImmortalWrt `openwrt-25.12` 分支源码编译（非 ImageBuilder）
**本文档回答一个问题**：为了这台机器，编译阶段要打开/关闭哪些东西，凭什么，怎么验收。

> 机制：所有优化以**特性片段**形式存在于 `features/`，构建脚本主体不再增长。
> 契约与新增方法见 [`features/README.md`](features/README.md)。

---

## 一、基线实测（决定"要不要做某项优化"的事实依据）

| 事实 | 实测证据（2026-10-11，宿主机 ImmortalWrt 25.12 / kernel 6.12.74） |
| --- | --- |
| CPU | Intel Atom C3958 (Denverton)，16 线程全部带 `vmx`；EPT/VPID/APICv 齐备 |
| 不是虚拟机 | `/proc/cpuinfo` 无 `hypervisor` 标志 |
| 内存 / 负载 | 31.2 GB；但宿主同时跑 jellyfin(≈196% CPU)、frigate+ffmpeg、homeassistant 等容器 |
| 网卡 | 2× Mellanox ConnectX-4 Lx (mlx5) + 1× Intel X553 (ixgbe) |
| 拓扑 | **WAN = PPPoE (eth0)**，LAN = br-lan(eth1+eth2)，其余是 Docker 网桥 |
| 软件 flowtable | 已开启且生效：`flowtable ft { devices={docker0,eth0,eth1,eth2,pppoe-wan} flags offload }`，实测 28 条 conntrack 处于 `OFFLOAD` |
| 硬件卸载 | `ethtool -k eth0/eth1` → `hw-tc-offload: off [fixed]`（内核未编 TC 卸载基础设施） |
| KVM | 官方固件里**无任何 KVM 模块**、`/dev/kvm` 不存在（CPU 支持，纯软件缺失） |
| QAT | `lspci` 全表 21 个设备，**无任何 `[0b40] Processing accelerators`**，无 QAT 固件/驱动/包 |
| 官方内核基线 | `NET_CLS_ACT/FLOWER/ACT_CT/SCH_INGRESS/PSAMPLE` 全部 `not set`；`HZ=100`；`GENERIC_CPU=y`；`CRYPTO_AES_NI_INTEL=y` |

---

## 二、默认启用（`features/enabled.txt`）

| 片段 | 内容 | 依据 | 刷机后核验 |
| --- | --- | --- | --- |
| `10-kvm-host` | `kmod-kvm-x86/-intel`、`vhost-net`、`vfio(-pci)`、`qemu-x86_64-softmmu`、`qemu-img`、SeaBIOS/EFI 固件、`qemu-bridge-helper` | 手工装包后 `/dev/kvm` 出现、`qemu -accel kvm -cpu host` 实跑通 SeaBIOS 引导（`-cpu host` 仅 KVM 可用，排除 TCG） | `ls -l /dev/kvm`；`lsmod \| grep -E 'kvm\|vhost'` |
| `20-crypto-accel` | `kmod-crypto-sha1/sha256/ghash/crc32c`、`kmod-lib-crc32c` | AES-NI 官方基线已 `=y`；SHA-NI/GHASH/CRC32C 缺失。**用包而非强写 `=y`**：`crypto.mk` 里加速变体本身就是 kmod 子变体，强写 `=y` 会让对应 `.ko` 消失 → 触发"missing .ko"（QAT SDK 的失败模式） | `ls /lib/modules/$(uname -r) \| grep -E 'sha256\|ghash\|crc32c'` |
| `30-microcode` | `intel-microcode`、`iucode-tool` | feed 实测存在；内核 `CONFIG_MICROCODE=y` 已内建。Denverton 长周期 SoC，BIOS 微码往往落后 | `dmesg \| grep -i microcode`；`grep microcode /proc/cpuinfo` |

三项片段在 `[meta] expect_pkgs=` 中自报验收标准，**闸门 5** 会用固件 `.manifest` 逐包断言，缺包直接判定构建失败。

---

## 三、可选（默认关闭，需要时 `FEATURES=` 打开）

| 片段 | 内容 | 为什么默认关 | 打开方式 |
| --- | --- | --- | --- |
| `40-net-tune` | `CONFIG_HZ_100 → 250`（同时 `kconfig-unset HZ_100`，避免 choice 双置位） | 收益未实测；本机瓶颈是容器负载而非 tick 精度，且 16 线程上定时器中断×2.5 | `FEATURES=40-net-tune` |
| `50-image-slim` | 关闭 `KERNEL_DEBUG_INFO / BTF / BTF_MODULES` | 会失去 bpftrace/BCC 观测能力；在拿到一次完整构建耗时基线前不砍调试能力 | `FEATURES=50-image-slim` |

---

## 四、评估后**不做**的项（附证据与"什么条件下再评估"）

### 4.1 TC / nftables flowtable 硬件卸载（mlx5）

**结论：不做。** 理由链：

1. **能力确实缺**：官方基线 `NET_CLS_ACT / NET_CLS_FLOWER / NET_ACT_CT / NET_SCH_INGRESS / PSAMPLE` 全部 `not set`，故 `hw-tc-offload` 恒为 `off [fixed]`；要让 mlx5 卸载需要 `MLX5_TC_CT`（依赖 `NET_ACT_CT`）。
2. **不能简单写 `=y`**：`NET_ACT_CT` 的上游依赖含 `NF_FLOW_TABLE`，而官方是 `=m`（`nf_flow_table.ko` 已随固件安装）→ `NET_ACT_CT` 最多只能 `=m`；`=m` 又必须**自建 kmod 包**把它们打进 rootfs，否则复现"编了但没装进固件"。
3. **即使做了也没有收益**：本机唯一的被路由路径是 **LAN → PPPoE WAN**（eth0 上的 pppoe-wan 虚拟设备），硬件卸载覆盖不到；LAN↔LAN 不经过路由（同桥二层转发），Docker 网桥流量最终也走 PPPoE。
4. 软件侧已经拿到快路径：flowtable 已开启，实测 28 条流处于 `OFFLOAD`。

**再评估触发条件**：WAN 改为 DHCP/静态（非 PPPoE），或出现 LAN↔LAN 三层转发 / 虚拟化桥接转发的实际需求。

### 4.2 CPU 微架构调优（原计划 `CONFIG_MGOLDMONT`）

**结论：不做，维持 `GENERIC_CPU=y`。**

- 上游 `arch/x86/Kconfig.cpu` **不存在 `MGOLDMONT` 符号**（实测只有 `GENERIC_CPU / MCORE2 / MATOM` 等）。凭直觉写 `CONFIG_MGOLDMONT=y` 会被 kconfig 静默丢弃 —— 正是 `features/README.md` 里强调要防的事故类型。
- `MATOM` 是 Bonnell/Silvermont 取向，对 Goldmont 代（Denverton）未必优于通用 `GENERIC_CPU`，且会牺牲镜像在其他 x86 上的通用性。
- 用户态 `-march=goldmont` 属于"特定机型优化"，有跨机 `SIGILL` 风险；若要做，应当是**独立可选项 + 实测数据支撑**，不是默认行为。

### 4.3 OVMF / UEFI guest 固件

feed 实测无 `ovmf` / `edk2-ovmf` 包（宿主自身也是 Legacy BIOS 启动，无 `/sys/firmware/efi`）。
需要 UEFI / SecureBoot 固件测试时：外带 `OVMF.fd`，用 `qemu-system-x86_64 -bios OVMF.fd` 加载即可，无需进入固件。

### 4.4 QAT（已有实现，但硬件前提待确认）

现有构建已把 DH895XCC QAT 打进固件（`qat-src/` + `HOST_PKGS`）。但**本次实测的这台机器 PCI 上不存在 QAT 设备**：

```
lspci -nn  →  只有 Denverton SoC + 2×Mellanox ConnectX-4 Lx + Intel X553
无任何 [0b40] Processing accelerators；/lib/firmware 无 qat_*.bin
```

而 `FIRMWARE-REPORT-2026-09-20.md` 记录的是 `0000:01:00.0 = 8086:19e2`（QAT）+ 7.6 GB 内存，本机 `01:00.0` 是 Mellanox、内存 31.2 GB。
**待确认**：QAT 是给另一台同型号机器编的，还是当年的硬件识别有误。在确认前，建议给 QAT 加载加一道运行时门控（无设备时不 modprobe），避免无谓报错。

### 4.5 运行期调优（不属于编译期，已在别处）

`host-files/etc/sysctl.conf` 已固化 BBR + fq_codel + 收发缓冲 + 脏页回写/zram 策略；conntrack 上限 262144（当前使用 2427）无需调整；网卡均为 16 队列 RSS。

---

## 五、验证路径（一次构建怎么算"过了"）

| 闸门 | 位置 | 断言内容 |
| --- | --- | --- |
| 1 | 注入后 | 用上游真实 `scripts/kconfig.pl` 预演合并，符号缺失/冲突当场失败 |
| 2 | `make world` 后 | 内核**最终** `.config`：串口符号 + **特性片段的 kconf 行**（读 `.features-applied`） |
| 3 | 产物 | `.manifest` 里 QAT 三个包必须存在（=y 而非 =m 的权威凭据） |
| 4 | rootfs 暂存区 | 覆盖层文件与 `intel_qat.ko` 落地 |
| 5 | 产物 | `.manifest` 里**特性片段 `expect_pkgs`** 声明的每个包必须存在 |

刷机后自查（固件内已开 `IKCONFIG_PROC`）：

```sh
zgrep -E 'SERIAL_8250_MID|HSU_DMA|NR_UARTS|CONFIG_HZ' /proc/config.gz
ls -l /dev/kvm && lsmod | grep -E 'kvm|vhost'
dmesg | grep -i microcode
```

---

## 六、下一步（按收益排序）

1. 跑一次源码构建，验证片段机制在 CI 里端到端可用（闸门 2/5 是新增断言，首次必须实测）。
2. 用 `FEATURES=40-net-tune` 做一次 A/B，再决定 HZ 是否转默认。
3. 就 QAT 硬件归属给出结论（4.4），据此决定保留或加运行时门控。
4. 固件虚拟机工作流（KVM 已备）：qcow2 模板 + 快照回滚 + `-nographic` 串口日志，用于自编译固件/驱动的启动验证。
