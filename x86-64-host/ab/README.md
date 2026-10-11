# 单盘 A/B 双槽安全自升级 —— 设计与实施计划

**目标**：把生产系统从 U 盘迁移到 477 G SATA SSD，并在同一块盘上实现 A/B 双槽，
使固件升级变成"写非活动槽 → 重启切换"，失败可**自动回滚**，无需串口救砖。

**本文档回答两件事**：① 能不能做（附实测依据）；② 怎么做（布局、流程、验收、回退）。

---

## 一、可行性结论与依据

| 判断 | 依据（实测） |
| --- | --- |
| 安卓式 **Virtual A/B 不可行** | 需要 update_engine / boot_control / dm-snapshot 整套栈；OpenWrt 完全没有，等于自研 OTA 框架 |
| **物理 A/B 双槽可行** | GRUB 提供 `load_env`/`save_env`；feed 有 `grub2-editenv`；x86 target 的升级路径可替换 |
| **不依赖 UEFI** | `sda` 在 `ata8`（SATA M.2），AHCI 已内建 → Legacy BIOS 可直接引导 SSD。UEFI 可后续单独切 |
| **必须打一个补丁** | 官方 `package/boot/grub2/Makefile` 生成 core.img/bootx64.efi 的模块列表是 `at_keyboard biosdisk boot chain configfile fat linux ls part_gpt reboot search serial test vga` —— **没有 `loadenv`**。目标机也没有 `grub-mkimage`（grub2 包只装 `lib/apk/packages/grub2.list`），只能在构建期补。**实测教训**：GRUB 没有独立的 `saveenv` 模块，`load_env`/`save_env` 同属 `loadenv.mod`；写成 `loadenv saveenv` 会让 grub-mkimage 直接报错，已只加 `loadenv` 并用真实 grub-mkimage 对 i386-pc 与 x86_64-efi 两份列表验证通过 |
| **当前生产形态** | 整套系统跑在 U 盘 `sdb`（"Speichern Stick"，`ata`→usb），`sda`（477 G SATA SSD）**完全空白**（前 512 B 全 0）。Docker/NFS/jellyfin/HA 全部依赖这根 U 盘 |

---

## 二、磁盘布局（目标：单盘自足）

| 分区 | 大小 | 内容 | 说明 |
| --- | --- | --- | --- |
| p1 | 1 MiB | BIOS boot | Legacy GRUB `core.img`（`grub-bios-setup` 写入） |
| p2 | 512 MiB | `/boot`（vfat, `LABEL=kernel`） | `grub.cfg`+`grubenv`+`vmlinuz.a`+`vmlinuz.b`；沿用 `search -l kernel` 约定，UEFI 时兼作 ESP |
| p3 | 2 GiB | 槽 A rootfs（squashfs） | 只读系统镜像；`root=PARTUUID=…-03` |
| p4 | 2 GiB | 槽 B rootfs（squashfs） | 同上，另一份；`root=PARTUUID=…-04` |
| p5 | 16 GiB | 共享 overlay（f2fs, `LABEL=rootfs_data`） | `/overlay`，配置与软件状态，**两槽共用** —— 等价于安卓 VAB 里的共享 `/data`，避免升级丢配置 |
| p6 | 其余 | `/Lager`（ext4, `LABEL=LAGER2`） | Docker overlay2、NFS 落地数据；升级永不触碰 |

> **待演练验证 (V1)**：OpenWrt 的 `fstools`/`mount_root` 是否会把独立分区（`LABEL=rootfs_data`）
> 自动识别为 overlay。现固件是"同一分区内 squashfs + 追加 f2fs 的 loop 设备"
> （实测 `losetup`: `/dev/loop0 → (/sdb2), offset 121438208`）。
> 若 V1 不成立，退路是**每槽自带 overlay**（与现状同构）+ 升级时迁移配置。

---

## 三、引导逻辑与回滚语义

模板：[`grub.cfg.ab.tmpl`](grub.cfg.ab.tmpl)（安装时替换 PARTUUID/超时/命令行）

状态存于 `/boot/grub/grubenv`，三个变量：

| 变量 | 写入方 | 含义 |
| --- | --- | --- |
| `next_entry` | `ab-upgrade`（系统侧） | 一次性引导目标槽（0=A, 1=B），GRUB 用完即清空 |
| `boot_ok` | `ab-bootok`（系统侧） | 本次启动是否被标记为成功 |
| `bootcount` | GRUB（`save_env`） | 连续"未被标记成功"的启动次数（GRUB 无算术，用 1→2 两级递进） |

流程：

```
升级 → next_entry=1, boot_ok=0, bootcount=0  →  重启
GRUB: 读 grubenv → default=1（槽 B），清空 next_entry
      boot_ok≠1 → bootcount: 0→1
      槽 B 若能起来: ab-bootok 健康检查通过 → boot_ok=1（计数归零）
      槽 B 若起不来: 再次引导 → bootcount: 1→2 → 下一次自动把 default 切回槽 A
```

关键点：**回滚判定在引导器侧**。内核 panic / 早期挂死时系统内没有任何代码能执行，
只有 GRUB 能救——这正是必须把 `loadenv`/`saveenv` 编进 core.img 的原因。

---

## 四、升级流程（`ab-upgrade`）

1. 校验输入镜像（`*-combined*.img[.gz]`，magic/大小）
2. 从 `/proc/cmdline` 的 `root=PARTUUID=` 判断**当前槽**，推出目标槽
3. 从镜像 p1 取出内核 → 写入 `/boot/vmlinuz.<目标槽>`
4. 把镜像 p2 的 squashfs 写入**目标槽分区**（`dd`）
5. `grub-editenv /boot/grub/grubenv set next_entry=<目标槽> boot_ok=0 bootcount=0`
6. （可选）对共享 overlay 做快照，便于"回滚后配置也回退"
7. `sync` + 提示重启

回滚（人工，可选）：`grub-editenv set boot_ok=1`（锁定当前槽）或把 `next_entry` 指向另一槽。

---

## 五、上游之外的改动清单

| 改动 | 位置 | 作用 |
| --- | --- | --- |
| grub2 模块补丁 | `ab/patches/0001-grub2-embed-loadenv-saveenv.patch`（构建时 `patch -p1`，dry-run 先行，失败即停） | 让 core.img / bootx64.efi 内嵌 `loadenv`（其中含 `load_env` + `save_env` 两个命令） |
| `grub2-editenv` 包 | 特性片段 `17-grub-ab` | 系统侧读写 grubenv |
| 引导模板 | `ab/grub.cfg.ab.tmpl` | 双槽菜单 + grubenv 回滚逻辑 |
| 安装器 / 升级器 / 启动标记 | `ab/`（下一步提交） | 铺盘、升级、健康标记、状态查询 |
| 硬件适配补全 | 特性片段（下一步） | `kmod-itco-wdt` + 喂狗服务（生产环境挂死自恢复）、温度阈值、SSD SMART 巡检 |

---

## 六、实施阶段与验收标准

| 阶段 | 内容 | 验收标准 | 回退 |
| --- | --- | --- | --- |
| A | 备份 | 系统分区镜像 + 配置备份 + sha256 记录 | — |
| B | 特性/补丁构建 | CI 产出 BIOS+UEFI 两份镜像；闸门 2/5/6 全过；`grep loadenv saveenv` 断言通过 | 不刷即退 |
| C | **KVM 演练** | V1–V3 全部验证；升级→切换→标记→**故意失败自动回滚** 全流程复现 | 丢弃虚拟盘 |
| D | SSD 铺 A/B 布局（在线，不动 sdb） | 布局与预期一致；两槽均可被 GRUB 识别 | 重新铺盘 |
| E | 数据迁移（rsync + 校验） | `rsync -n` 差集为空；关键服务配置/容器数据一致 | U 盘数据不动 |
| F | 维护窗口切换（BIOS 启动顺序 → SSD） | SSD 启动、服务恢复、网络/网关正常 | BIOS 切回 U 盘 |
| G | 实机 A/B 升级演练 | 升级成功；人为制造失败后**自动回滚**到旧槽 | 自动回滚本身 |
| H | 收尾 | U 盘转冷备；文档与状态记录更新 | — |

---

## 七、风险与未决问题

1. **V1（独立 rootfs_data 分区）** —— 演练必须先过；不过就走"每槽自带 overlay + 配置迁移"。
2. **共享 overlay 的跨版本兼容**：回滚时旧槽可能被新版本写过的配置影响 → 升级前对 p5 做快照。
3. **停机时间**：A/B 仍需要重启（约 30–60 s + 服务恢复）。它买到的是"安全 + 自动回滚"，不是零停机。
4. **BIOS 启动顺序**：唯一必须"物理侧"的一步（串口重定向或人工）。U 盘保持可用即为退路。
5. **USB 盘本身**：迁移期间不要对 `sdb` 做写操作；数据搬迁用 `rsync`（不删源），确认无误后再考虑退役。
6. **watchdog 与回滚的相互作用**：喂狗服务若在"新槽启动失败"时也被拉起，会导致重启循环被 watchdog 掩盖——
   需在 `ab-bootok` 里明确"未标记成功前不启动/不喂狗"的次序（演练中一并验证）。
