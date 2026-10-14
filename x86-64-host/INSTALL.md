# 部署 · 安装 · 升级 · 回滚手册（A/B 双槽）

> 适用：Inspur AliMoC-MD-02-25G（x86/64 宿主机固件）
> 前置阅读：[`README.md`](README.md)（固件总览）、[`ab/README.md`](ab/README.md)（A/B 设计与演练记录）
> 本手册里的工具都在固件/仓库里：`x86-64-host/ab/`

---

## 0. 一分钟理解 A/B

**核心思想**：盘上有**两个系统槽**。升级时把新固件写进**当前没在用的那个槽**，然后重启切过去；
如果新槽起不来，**引导器会自动切回旧槽**——全程不需要人到现场。

```
p1  /boot (vfat, LABEL=kernel)   512M  ← grub.cfg / grubenv / vmlinuz.a / vmlinuz.b
p2  BIOS boot                    1M    ← Legacy GRUB core.img（物理位置最前）
p3  槽 A rootfs                  2G    ← squashfs（含该槽自己的 overlay）
p4  槽 B rootfs                  2G
p5  /Lager (ext4, LABEL=LAGER2)  其余   ← Docker / NFS 数据，升级永不触碰
```

**引导状态存在 `/boot/.../grubenv`（GRUB 侧 `load_env`/`save_env` 读写）**：

| 变量 | 写入方 | 含义 |
| --- | --- | --- |
| `next_entry` | `ab-upgrade` | 一次性引导目标槽（`0`=A，`1`=B），GRUB 用完即清空 |
| `boot_ok` | `ab-bootok` | 本次启动是否被系统标记为成功（健康检查通过才写 `1`） |
| `bootcount` | GRUB | 连续"未被标记成功"的次数（1→2 递进，GRUB 无算术） |

状态机：

```
正常启动        boot_ok=1 ──────────────► 计数归零，保持当前槽
升级后首启      next_entry=B, boot_ok=0 ─► 引导 B；B 起来并标记成功 → boot_ok=1
B 起不来（第1次）bootcount 0→1 ──────────► 下次仍引导 B
B 起不来（第2次）bootcount=2 ────────────► 自动把 default 切回 A，计数归零
```

**关键**：回滚判定在**引导器侧**。内核 panic / 早期挂死时系统里没有任何代码能执行，只有 GRUB 能救。

---

## 1. 前置条件

### 1.1 硬件 / BIOS

| 项 | 要求 |
| --- | --- |
| 目标盘 | SSD（本机 `sda`，原为空盘）；**不要**把安装器指向正在运行的系统盘 |
| BIOS | 目标盘设为第一启动项（Legacy 或 UEFI 均可，两份镜像都有） |
| VT-d / QAT | 需要在 BIOS 里打开（打开后才可直通 / 用硬件加速；固件已预留） |
| 串口 | 建议接上串口线（`ttyS4` @ **57600**），这是出问题时唯一的"眼睛" |

### 1.2 需要的文件

- 合盘镜像：`immortalwrt-x86-64-generic-squashfs-combined.img.gz`（Legacy）
  或 `...-combined-efi.img.gz`（UEFI）
- 安装器 / 升级器：来自本仓库 `x86-64-host/ab/`（新固件内已内置 `/usr/sbin/ab-*`）

### 1.3 在旧系统上执行安装器时的依赖

`ab-layout.sh` 需要：`parted`、`mkfs.fat`、`mkfs.ext4`、`mkfs.f2fs`、`blkid`、`grub-bios-setup`、`grub-editenv`。
新固件已全部内置；**旧固件**（当前 U 盘系统）缺 `grub-editenv`（可能还缺 fstrim 等），先补齐：

```sh
apk update && apk add grub2-editenv fstrim rsync      # rsync/fstrim 供迁移与 TRIM 使用
```

### 1.4 三条硬约束（务必遵守）

1. **不要用系统自带的 `sysupgrade` 升级本机**。我们的分区布局与 OpenWrt 默认假设不同，
   `sysupgrade` 会写到"第一个分区"，可能破坏 A/B 布局。**只用 `ab-upgrade`**。
2. **不要把 `/boot` 放到别的分区号**。官方 `core.img` 的 early config 硬编码
   `configfile (hd0,gpt1)/boot/grub/grub.cfg`——安装器已按此设计，不要手工改分区表。
3. **升级期间不要动 `/Lager`**（数据分区），也**不要拔掉作为退路的旧盘**。

---

## 2. 场景 A：全新安装到空盘

> 目标：把空 SSD 铺成 A/B 布局，两个槽都装同一份固件（开局就有回滚目标）。
> 建议在**正在运行的旧系统**上执行（对空盘操作不影响运行中的系统）。
> 预计 3–6 分钟。

### 步骤

```sh
# 0) 确认目标盘确实是空的、且不是当前系统盘
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
grep -E '/dev/sd' /proc/mounts           # 确认 /dev/sda 没有任何分区被挂载

# 1) 铺盘（--yes 表示确认破坏性操作）
sh x86-64-host/ab/ab-layout.sh \
    --disk /dev/sda \
    --image /path/to/immortalwrt-x86-64-generic-squashfs-combined.img.gz \
    --yes
```

常用可选参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--boot-mib` | 512 | `/boot` 分区大小 |
| `--slot-mib` | 2048 | 每个槽大小（需 ≥ 镜像 rootfs 大小） |
| `--data-mib` | 0（吃满剩余） | 数据分区大小 |
| `--overlay-mode` | `per-slot` | 每槽独立 overlay（已实验证明共享 overlay 不可用，见 `ab/README.md` 第五节） |
| `--core-img` | 用镜像自带 | 仅当镜像的 core.img 未内嵌 `loadenv` 时需显式给一个（新版固件已内嵌） |
| `--bootopts` | 串口 + `intel_iommu=on iommu=pt` | 内核命令行 |
| `--baud` / `--timeout` | 57600 / 3 | GRUB 串口波特率、菜单超时 |

### 检查点（安装器会打印，逐项确认）

1. 分区布局：`p1 BOOT(fat32)` + `p2 BIOSBOOT(bios_grub)` + `p3/p4 SLOT_A/SLOT_B` + `p5 LAGER`
2. `槽 A/B PARTUUID` 已读出并写进 `grub.cfg`
3. `grubenv: boot_ok=1 bootcount=0`（槽 A 视为"已知良好"）
4. `grub-bios-setup` 成功（MBR + BIOS boot 分区已写入）
5. 结束语提示"BIOS 设该盘为第一启动项"

### 装完到切盘

1. 进 BIOS 把 **SSD 设为第一启动项**（旧盘保留在后面，作为退路）
2. 启动后确认：

```sh
ab-status                 # 应显示 启动槽 A、grubenv boot_ok=1、两槽 PARTUUID
cat /proc/cmdline | tr ' ' '\n' | grep root=    # 应指向槽 A 的 PARTUUID
```

---

## 3. 场景 B：日常升级（写非活动槽）

> 目标：把新固件写进另一个槽，重启切换；不成功自动回滚。预计 2–5 分钟 + 一次重启。

```sh
# 1) 把新固件放到设备上（/tmp 是内存盘；大文件建议放 /Lager）
#    例如从 Actions 产物里取出 *-combined.img.gz

# 2) 查看当前状态
ab-status

# 3) 升级（自动判定当前槽 → 写另一槽 → 迁移 overlay → 设置一次性引导）
ab-upgrade /path/to/immortalwrt-x86-64-generic-squashfs-combined.img.gz

#    可选参数：
#      --no-overlay   不迁移配置（新槽将以默认配置启动，谨慎使用）
#      --yes          跳过交互确认
```

`ab-upgrade` 做了五件事，逐条核对它的输出：

1. 判定当前槽 → 目标槽；检查镜像 rootfs 是否装得下目标槽
2. 镜像 p1 的内核 → `/boot/vmlinuz.<目标槽>`
3. 镜像 p2 的 squashfs → 目标槽分区
4. **overlay 迁移**：在目标槽分区内、按 OpenWrt 的偏移（squashfs `bytes_used` 向上 4 KiB 对齐）
   新建 f2fs，并把当前 `/overlay` 内容整份复制过去 —— 否则新槽首次启动是**空配置**
5. 写 `grubenv`：`next_entry=<目标槽> boot_ok=0 bootcount=0`

```sh
# 4) 重启切换（重启后 GRUB 会引导新槽）
reboot

# 5) 起来后确认
ab-status                 # 启动槽 = 新槽；boot_ok 稍后会被 ab-bootok 置 1
logread | grep ab-bootok  # 健康检查通过后写入 boot_ok=1
```

### 升级成功的标志

- `ab-status` 显示 **启动槽 = 目标槽**，且 `boot_ok=1`（健康检查通过）
- 服务/网络正常（`ab-bootok` 的健康判据：有默认路由 + 可选 `/etc/ab-health.sh`）

### 如果想立刻回滚（不等自动回滚）

```sh
# 方式一：把下次引导指回旧槽（一次性）
grub-editenv "$(ab-status | sed -n 's/.*grubenv (\(.*\)):/\1/p')" set next_entry=0   # 0=A, 1=B
reboot
# 方式二：直接重启两次不做标记 —— 见场景 C 的自动回滚
```

---

## 4. 场景 C：失败自动回滚（系统已经起不来时）

**不需要你做任何事。** 机制：新槽启动后若没被 `ab-bootok` 标记成功，GRUB 每次启动把 `bootcount` 加一；
到 2 就自动把默认槽切回另一个。

- 触发条件：内核 panic / 早期挂死 / 网络或健康检查不通过（未写 `boot_ok=1`）
- 表现：机器会**重启两次**，然后自动回到旧槽启动
- 回滚后：旧槽的配置也是它自己的（每槽独立 overlay），连配置一起回退

**验证方法（可选的实机演练）**：升级到新槽后，故意让健康检查失败（例如临时把
`/etc/ab-health.sh` 写成 `exit 1`），观察两次重启后自动切回旧槽。

**锁定当前槽**（不想让它再被回滚）：

```sh
grub-editenv /boot/grub/grubenv set boot_ok=1 bootcount=0     # 注意实际路径见 ab-status
```

---

## 5. 场景 D：从现有 U 盘系统迁移到 SSD（本次要做的）

> 现状：系统跑在 U 盘（`/dev/sdb`，含 `/Lager` 数据 41 GB），SSD（`/dev/sda`）为空。
> 迁移要**先备份、后铺盘、再搬数据、最后切盘**，每一步都可回退。

### D1. 备份（零风险，先做）

```sh
# 系统分区镜像（约 1 GB）+ 配置全备份
mkdir -p /nfs/Lager/backup-alimoc/$(date +%Y%m%d) && cd $_
dd if=/dev/sdb1 of=sdb1-kernel.img bs=4M conv=fsync
dd if=/dev/sdb2 of=sdb2-rootfs+overlay.img bs=4M conv=fsync
dd if=/dev/sdb3 of=sdb3-biosboot.img bs=4M conv=fsync
sha256sum *.img > sysparts.sha256
sysupgrade -b config-backup.tar.gz
```

### D2. 铺 A/B 布局到 SSD（在线执行，不影响运行中的系统）

见 **场景 A**（用同一份固件镜像铺两个槽）。

### D3. 数据迁移（两轮，避免长时间停机）

```sh
# 第一轮（在线，服务不停）：把大头先搬过去
sh x86-64-host/ab/migrate-data.sh --target /dev/sda5 --seed

# 真正切换前：停写 → 增量补齐 → 校验差异
sh x86-64-host/ab/migrate-data.sh --target /dev/sda5 --final
#   该步会停止 dockerd/containerd，做完增量后保持停止
#   成功标志：输出 "✅ 数据已完全一致" + 差异条目 0 + 目标盘写入 .migrate-complete

# 只想看差异、不动数据：
sh x86-64-host/ab/migrate-data.sh --target /dev/sda5 --verify
```

> 迁移脚本的安全约束：源与目标必须是不同设备；目标不能是系统盘；任一步失败都不动源数据。

### D4. 切换窗口（需要短暂停机 + BIOS 操作）

1. `--final` 已完成且差异为 0
2. 把 `/Lager` 的挂载指向新分区（`/etc/config/fstab` 里的 UUID 换成新分区；或直接重启后由 A/B 系统的 fstab 处理）
3. **BIOS 把 SSD 设为第一启动项**（U 盘留在后面）
4. 重启 → 应进入 SSD 上的 A/B 系统（槽 A）
5. 起来后确认：`ab-status`、`lsblk`、`docker ps`、NFS 挂载、网关/NAT 正常

### D5. 验收与回退

- 验收：见附录 A 的核验脚本；重点确认数据、Docker、NFS、网络、串口
- **回退**：BIOS 改回 U 盘启动即可（旧系统原样保留，什么都没动过）
- 稳定运行一段时间后，再把 U 盘转为**冷备**（不要立刻格式化）

---

## 6. 日常巡检

```sh
ab-status -v          # 槽位 / grubenv / 内核文件 / 分区布局 / 最近日志
hw-health             # 温度 / SSD SMART 与磨损 / overlay 使用率 / 内存
logread | grep -E 'hw-watchdog|hw-tune|hw-healthd|ab-bootok|hw-mem'
```

自动运行的服务（启动顺序有讲究）：

| 服务 | START | 作用 |
| --- | --- | --- |
| `ab-bootok` | 95 | A/B：健康检查通过后写 `boot_ok=1` |
| `hw-watchdog` | 96 | 等 `boot_ok=1` 后 arm 硬件看门狗，每 5s 喂狗（挂死自动重启） |
| `hw-healthd` | 97 | 每 15 min 巡检；每 24h 对 SSD 执行一次 `fstrim` |
| `hw-storage-guard` | 98 | **存储自愈**（/Lager、/boot 挂载失败时预检/强制 fsck 后重挂）+ **dockerd 门控** |
| `hw-tune` | 98 | 网卡级调优（转发 UDP GRO 等）与可选 CPU governor |
| `hw-mem` | 94 | 按存储层级自适应内存/IO 策略（USB 保守 / SSD 放宽） |

> ⚠️ 顺序不能改：喂狗必须在"启动成功标记"之后，否则新槽启动失败会被看门狗反复重启、掩盖回滚判定。
> ⚠️ `hw-storage-guard` 与 `hw-tune` 同为 S98，按名字排序 guard 先跑；两者都早于 `dockerd`(S99)。

---

## 7. 故障速查

| 现象 | 可能原因 | 处置 |
| --- | --- | --- |
| 开机停在 `grub>` | grub.cfg 丢失/损坏 | 用串口在 GRUB 里 `configfile (hd0,gpt1)/boot/grub/grub.cfg`；仍不行则用安装器重铺 `/boot` |
| 引导了但系统起不来 | 内核/rootfs 写坏 | **什么都不做，等它重启两次自动回滚**；或手动 `next_entry` 指回旧槽 |
| 起来是**空配置** | overlay 未迁移（用了 `--no-overlay`） | 重新用 `ab-upgrade`（不带 `--no-overlay`） |
| 升级后网络不通 | 新槽配置与硬件不符 / 健康检查失败 | 等自动回滚；或进 failsafe 菜单修配置 |
| 整机挂死无响应 | 内核/IO 卡死 | 看门狗在 ~20s 内自动重启；重启后 `logread` + `/etc/hw-watchdog.log` 查原因 |
| **容器/镜像"好像全没了"** | `/Lager` 没挂上 → dockerd 退回 vfs | `hw-storage-guard status` 看挂载；按日志里的提示先修存储，再 `/etc/init.d/dockerd enable && start` |
| 存储自愈失败标记 | `/etc/hw-storage-guard.FAILED` 存在 | 看 `/etc/hw-storage-guard.log`；必要时停服务后手工 `e2fsck -y <设备>` |
| 想强制用旧槽 | — | BIOS 改回旧盘启动（最稳），或在 GRUB 菜单选 `slot A/B` |
| 串口无输出 | 波特率不对 / HSUART 未接管 | 确认 **57600 8N1**；`dmesg \| grep 8250_mid` |
| 中文文件名乱码 | 老固件 FAT 默认字符集 | 新固件已改 UTF-8；临时可 `mount -o iocharset=utf8` |

**永远不会丢的退路**：旧 U 盘系统（BIOS 切回即可）+ 备份的镜像/配置（D1）。

---

## 8. 附录 A：刷机后核验（复制粘贴）

```sh
# A/B 与引导
ab-status -v
cat /proc/cmdline | tr ' ' '\n' | grep -E 'root=|intel_iommu'

# 平台专属能力
dmesg | grep -iE '8250_mid|hsu_dma|microcode'
zgrep -E 'SERIAL_8250_MID|IKCONFIG|TRANSPARENT_HUGEPAGE|HUGETLBFS|FAT_DEFAULT_IOCHARSET|NET_SCH_(FQ|CAKE)' /proc/config.gz
ls -l /dev/kvm /dev/watchdog; lsmod | grep -E 'kvm|vhost|vfio'
ls /sys/kernel/iommu_groups/ | wc -l        # BIOS 开 VT-d 后应 >0
cat /sys/kernel/mm/transparent_hugepage/enabled     # [madvise]

# 网络与存储
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.netdev_max_backlog
for i in eth0 eth1 eth2; do echo "$i udp-gro=$(ethtool -k $i | awk '/rx-udp-gro-forwarding/{print $2}')"; done
for c in mkfs.exfat fsck.exfat mkntfs ntfsfix fstrim; do echo "$c: $(command -v $c || echo -)"; done
hw-health
```

## 附录 B：`grubenv` 变量与手工操作

```sh
E=/boot/grub/grubenv            # 实际路径请以 `ab-status` 显示为准（也可能是 /boot/boot/grub/grubenv）
grub-editenv $E list            # 查看
grub-editenv $E set next_entry=1 boot_ok=0 bootcount=0    # 下次引导槽 B 并开启回滚计数
grub-editenv $E set boot_ok=1 bootcount=0                 # 锁定当前槽
```

## 附录 C：文件清单（部署相关）

| 路径 | 作用 |
| --- | --- |
| `/usr/sbin/ab-upgrade` | 写非活动槽 + 迁移 overlay + 设置一次性引导 |
| `/usr/sbin/ab-status` | 查看槽位/grubenv/内核/布局 |
| `/usr/lib/ab-lib.sh` | 公共库（槽识别、overlay 偏移、裸 GPT/MBR 解析） |
| `/etc/init.d/ab-bootok` | 健康检查后写 `boot_ok=1`（S95） |
| `/etc/init.d/hw-watchdog` / `hw-healthd` / `hw-tune` / `hw-mem` | 看门狗 / 巡检 / 网卡调优 / 内存策略（S96–S98 / S94） |
| `/etc/hw-tune.conf` | 网卡与 CPU governor 可选开关 |
| 仓库 `x86-64-host/ab/ab-layout.sh` | 铺盘安装器（在运行系统上对空盘执行） |
| 仓库 `x86-64-host/ab/migrate-data.sh` | 数据迁移（seed / final / verify） |
