# 单盘 A/B 双槽安全自升级 —— 设计、演练与实施计划

**目标**：把生产系统从 U 盘迁移到 477 G SATA SSD，并在同一块盘上实现 A/B 双槽，
使固件升级变成"写非活动槽 → 重启切换"，失败可**自动回滚**，无需串口救砖。

---

## 一、可行性结论与依据

| 判断 | 依据（实测） |
| --- | --- |
| 安卓式 **Virtual A/B 不可行** | 需要 update_engine / boot_control / dm-snapshot 整套栈；OpenWrt 完全没有 |
| **物理 A/B 双槽可行（已演练通过）** | 见第四节：KVM 中完成 铺盘→启动→切槽→grubenv 回写→**连续失败自动回滚** 全链路 |
| **不依赖 UEFI** | `sda` 在 `ata8`（SATA M.2），AHCI 已内建 → Legacy BIOS 可直接引导 SSD |
| **必须打构建补丁** | 官方 `package/boot/grub2/Makefile` 生成的 core.img/bootx64.efi 模块列表里**没有 `loadenv`**（也没有 `echo`），目标机又没有 `grub-mkimage`，只能在构建期补。实测教训：GRUB 的 `load_env`/`save_env` **同属 `loadenv.mod`**，没有独立的 `saveenv` 模块 |
| **`/boot` 必须是分区 1** | 官方 core.img 内嵌 early config 是 `configfile (hd0,gpt1)/boot/grub/grub.cfg`（硬编码分区 1），把 /boot 放别处会导致真实部署起不来 |
| **共享 overlay 不可行** | 见第五节 V1：OpenWrt x86 对 squashfs 根固定使用"分区内 loop overlay"，独立 `rootfs_data` 分区不会被采用 → 改为每槽独立 overlay + 升级时迁移配置 |
| **当前生产形态** | 整套系统跑在 U 盘 `sdb`（"Speichern Stick"），`sda`（477 G SATA SSD）**完全空白**；Docker/NFS/jellyfin/HA 全部依赖这根 U 盘 |

---

## 二、磁盘布局（最终设计）

| 分区 | 大小 | 内容 | 说明 |
| --- | --- | --- | --- |
| p1 | 512 MiB | `/boot`（vfat, `LABEL=kernel`） | **必须是分区 1**（见上）；放 `grub.cfg`/`grubenv`/`vmlinuz.a`/`vmlinuz.b` |
| p2 | 1 MiB | BIOS boot | Legacy GRUB `core.img`（`bios_grub`）；物理位置最前，同 OpenWrt 自身布局 |
| p3 | 2 GiB | 槽 A rootfs | squashfs；overlay 由系统在该分区剩余空间内自动建立 |
| p4 | 2 GiB | 槽 B rootfs | 同上；安装时与 A 相同，保证开局即有回滚目标 |
| p5 | 其余 | `/Lager`（ext4, `LABEL=LAGER2`） | Docker overlay2 / NFS 数据；升级永不触碰 |

> `--overlay-mode shared` 仍保留在脚本里（做过对照实验），但**不采用**：见第五节。

---

## 三、引导逻辑与回滚语义

模板：[`grub.cfg.ab.tmpl`](grub.cfg.ab.tmpl)

状态存于 `/boot/grub/grubenv`：

| 变量 | 写入方 | 含义 |
| --- | --- | --- |
| `next_entry` | `ab-upgrade` | 一次性引导目标槽（0=A, 1=B），GRUB 用完即清空 |
| `boot_ok` | `ab-bootok` | 本次启动是否被标记为成功 |
| `bootcount` | GRUB | 连续"未被标记成功"的启动次数（GRUB 无算术，1→2 两级递进） |

**三个必须遵守的实现约束（都是实测踩出来的）**：

1. **串口初始化必须放在 grub.cfg 最前面** —— 否则此前的输出只去 VGA，无头机器上等于黑屏。
2. **grubenv 必须用显式路径**：`search --label kernel --set=abroot` 后 `load_env -f ($abroot)/boot/grub/grubenv`。
   直接 `load_env` 会因为 early config 未设置 `$root`/`$prefix` 而失败（实测报 `unknown filesystem`）。
3. **模块表要带 `echo`**：官方模块表没有 `echo`，任何调试打印都会报 `can't find command 'echo'`。

---

## 四、演练结果（KVM + KVM 加速，全部实测）

环境：官方 ImmortalWrt x86-64 squashfs combined 镜像 + 24 GiB 稀疏盘（loop 设备），
`qemu-system-x86_64 -accel kvm -cpu host`，串口日志逐项核对。

| 验证项 | 结果 |
| --- | --- |
| 铺盘（GPT/分区/格式化/写双槽/装 GRUB） | ✅ `ab-layout.sh` 一次跑通 |
| 从槽 A 启动 | ✅ GRUB 菜单出现在串口 → 自动引导槽 A → 内核命令行 `root=PARTUUID=<槽A>` |
| squashfs 根 + overlay 自动建立 | ✅ `Mounted root (squashfs filesystem) readonly` → `switching to f2fs overlay` |
| 数据分区自动挂载 | ✅ `EXT4-fs (sda6): mounted` |
| 一次性引导 `next_entry` | ✅ 置 `next_entry=1` 后重启 → 引导 **槽 B**（`vmlinuz.b`） |
| **GRUB 回写 grubenv（`save_env`）** | ✅ 启动后 `next_entry` 被清空、`bootcount=1`、`default=1` 落盘 |
| **连续失败自动回滚** | ✅ `boot_ok=0`：第 2 次启动计数升到 2；第 3 次启动**自动切回槽 A**（`default=0`），无需人工干预 |
| 两槽均可独立启动 | ✅ 槽 A / 槽 B 都实际启动到网络就绪 |

结论：**A/B 核心机制（布局、引导、一次性切换、失败自动回滚）已在真机等价环境验证通过。**

---

## 五、V1 结论：共享 overlay 不采用

曾设想 p5 作为两槽共享的 `rootfs_data`（等价安卓共享 /data），实测两次对照：

| 实验 | 结果 |
| --- | --- |
| 槽分区 2 GiB + 独立 `rootfs_data` 分区（f2fs, LABEL=rootfs_data） | 系统仍用 `loop0`（槽分区内部偏移）作为 overlay；p5 未被使用 |
| 槽分区**压到镜像大小**（300 MiB，无剩余空间）+ 独立 rootfs_data 分区 | 仍然建立 `loop0` overlay（在 squashfs 内容之后），p5 依旧空 |

→ OpenWrt x86 的 squashfs 根**固定**在根分区内建立 loop overlay，不会改用独立分区。

**采用的方案：每槽独立 overlay + 升级时迁移配置。**

- `ab-upgrade` 写新槽后，把当前 overlay 内容复制进新槽的 overlay 区（偏移 = squashfs 内容长度，可从 squashfs superblock 的 `bytes_used` 取得）。
- 这反而比共享 overlay 更安全：**回滚时旧槽连配置一起回退**，新固件写坏配置不会污染旧槽。

---

## 六、上游之外的改动清单

| 改动 | 位置 | 作用 |
| --- | --- | --- |
| grub2 模块补丁 | `ab/patches/0001-grub2-embed-loadenv-saveenv.patch`（构建时 `patch -p1`，dry-run 先行，失败即停） | core.img / bootx64.efi 内嵌 `echo` + `loadenv` |
| `grub2-editenv` 包 | 特性片段 `17-grub-ab` | 系统侧读写 grubenv |
| 引导模板 | `ab/grub.cfg.ab.tmpl` | 双槽菜单 + grubenv 一次性引导与回退 |
| 安装器 | `ab/ab-layout.sh`（已演练） | 铺盘、双槽、装 GRUB、初始化 grubenv |
| 升级器/启动标记/状态 | `ab/ab-upgrade`、`ab/ab-bootok`、`ab-status`（待实现） | 写非活动槽 + 迁移 overlay；健康后标记成功 |
| 硬件适配补全 | 特性片段（待实现） | `kmod-itco-wdt` + 喂狗服务、温度阈值、SSD SMART 巡检 |

---

## 七、实施阶段与验收标准

| 阶段 | 内容 | 验收标准 | 回退 |
| --- | --- | --- | --- |
| A | 备份 | ✅ 已完成：系统分区镜像 + 配置备份 + sha256 | — |
| B | 特性/补丁构建 | CI 产出 BIOS+UEFI 两份镜像；闸门 2/5/6 通过 | 不刷即退 |
| C | KVM 演练 | ✅ 核心机制全部通过（第四节） | — |
| C2 | 升级器与 overlay 迁移演练 | 槽 A 升级到槽 B，配置随槽迁移；回滚后配置回退 | 丢弃虚拟盘 |
| D | SSD 铺 A/B 布局（在线，不动 sdb） | 布局与预期一致 | 重铺 |
| E | 数据迁移（rsync + 校验） | `rsync -n` 差集为空 | U 盘数据不动 |
| F | 维护窗口切换（BIOS 启动顺序 → SSD） | SSD 启动、服务恢复 | BIOS 切回 U 盘 |
| G | 实机 A/B 升级演练 | 升级成功；人为失败后自动回滚 | 自动回滚本身 |
| H | 收尾 | U 盘转冷备；文档与状态记录更新 | — |

## 八、风险与未决问题

1. **停机时间**：A/B 仍需重启（30–60 s + 服务恢复）；它买到的是"安全 + 自动回滚"。
2. **BIOS 启动顺序**：唯一必须"物理侧"的一步（串口重定向或人工）；U 盘即退路。
3. **watchdog 与回滚的次序**：喂狗服务必须在 `ab-bootok` 标记成功之后才启动，
   否则新槽启动失败会被 watchdog 反复重启、掩盖回退判定（升级器实现时一并处理）。
4. **overlay 迁移体积**：当前 overlay 约 900 MB 上限，迁移耗时可接受；迁移前做快照。
