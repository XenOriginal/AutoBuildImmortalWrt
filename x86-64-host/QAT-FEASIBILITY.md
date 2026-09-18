# QAT 驱动方案可行性结论

**日期**: 2026-09-18
**结论**: SDK 方案**不可行**（技术限制），需回到源码编译路线

---

## 一、SDK 方案的致命限制（已实证）

四轮 SDK 编译（run #1-#4）逐层验证后，最终失败于：

```
ERROR: module '.../linux-6.12.94/drivers/crypto/intel/qat/qat_common/intel_qat.ko' is missing.
make[2]: *** [Makefile:115: .../kmod-crypto-qat-common.installed] Error 1
```

**根因**: OpenWrt SDK 的内核目录中**没有内核源码树**，只有：

| SDK 实际包含 | 说明 |
|-------------|------|
| `linux-6.12.94/Module.symvers` | 内核导出符号表（供链接校验） |
| staging_dir 内的内核头文件 | 供 out-of-tree 模块编译 |
| 交叉工具链 | x86_64-openwrt-linux-musl-gcc |

**SDK 不含**: `drivers/`、`include/`、`scripts/`、`Makefile` 等内核构建必需文件。

因此 `package/kernel/linux` 在 SDK 中**只是"打包器"**——它把**已编译好**的 `.ko`
装进 `.apk`，而**不编译**内核驱动源码。日志中可见它对数百个预制 kmod 执行
`cp -fpR .../.pkgdir/kmod-xxx/. ...`（纯复制），本身不产出 `.ko`。

### 各轮失败对照

| Run | 耗时 | 错误 | 层次 |
|-----|------|------|------|
| #1 | 18.4 分 | `golang-bootstrap` 失败 | 我的用法（编了 world） |
| #2 | 9.6 分 | `No targets specified and no makefile found`（空 PKG_BUILD_DIR） | 包写法 |
| #3 | 9.3 分 | 同上（PKG_BUILD_DIR 已修正） | 缺构建钩子 |
| #4 | 10.6 分 | **`intel_qat.ko is missing`** | **SDK 能力边界** |

前三个是我的实现错误，第四个是 SDK 的**硬性限制**。

---

## 二、已验证的有利事实

尽管 SDK 方案不可行，排查过程确认了几个关键事实：

### 1. QAT 依赖的内核符号【全部存在】

```
=== 检查内核导出符号 (QAT 依赖) ===
符号表: .../linux-6.12.94/Module.symvers
  ✅ crypto_register_alg
  ✅ crypto_unregister_alg
  ✅ crypto_alloc_aead
  ✅ pci_enable_device
  ✅ pci_request_regions
  ✅ debugfs_create_dir
```

**官方内核已导出 QAT 所需的全部 crypto/PCI/debugfs 符号。**
这意味着只要能把 `.ko` 编出来，就能正常装载——不存在符号缺口。

### 2. QAT 可作为模块编译

内核 Kconfig 中 QAT 全部是 tristate（`[N/m/y]`），非 bool，
因此**不需要改动内核内建配置**，可编译为可加载模块。

### 3. 版本链一致

| 组件 | 内核版本 |
|------|---------|
| 官方 25.12.1 SDK | 6.12.94 |
| 官方 25.12.1 ImageBuilder | 6.12.94 |

vermagic 一致，模块与固件可配合。

---

## 三、可行的替代路径

### 路径 A：源码编译 + 修复 syncconfig（推荐）

回到全量源码编译，但必须解决内核配置问题。关键改变：

**不再"注入符号"，而是给内核 Makefile 打补丁**，让目标内核的
`syncconfig` 也接受空输入（如同工具链内核阶段的 `yes '' | make oldconfig`）：

```makefile
# 在 include/kernel-build.mk 或内核 Makefile 的 syncconfig 目标前
# 强制 oldconfig 自动应答
```

或者更简单可靠：**预先执行一次完整的 oldconfig 落盘**

```bash
make target/linux/prepare
KDIR=$(find build_dir -name "linux-*" -maxdepth 3 | head -1)
cd "$KDIR" && yes '' | make ARCH=x86 oldconfig
# 此后 syncconfig 无新符号可问
```

**注意**: 之前失败是因为预热时机不对（在 build_dir 存在之前就执行）。
正确做法是在 `make target/linux/prepare` **之后**、`make world` **之前**执行。

### 路径 B：手动提取 QAT 源码做 out-of-tree 模块

QAT 源码共 133 个文件（qat_common 125 + qat_dh895xcc 4 + qat_dh895xccvf 4）。
理论上可提取为独立包，用 SDK 以 out-of-tree 方式编译——因为 SDK
确实支持 out-of-tree 模块（提供头文件与符号表）。

**风险**: QAT 源码深度依赖内核内部头文件与 `qat_common` 的相对路径
（`ccflags-y := -I $(src)/../qat_common`），提取后需大量适配。
工作量可能超过路径 A。

### 路径 C：放弃 QAT

QAT 是较老代次的协处理器（DH895XCC），加速能力以 AES/SHA 与压缩为主。
若实际收益有限，可放弃以节省精力。

---

## 四、建议

**优先路径 A**，并且把验证前置：

1. 先用 2-5 分钟的快速验证（`validate-kernel-config.yml` 思路），
   确认 `make target/linux/prepare` + `oldconfig` 后
   `syncconfig </dev/null` 能通过
2. 验证通过后再跑完整编译（30-50 分钟）

这样避免再次出现"跑 50 分钟才在末尾失败"的情况。

---

## 五、附：本次排查的完整教训

QAT 这一个功能，累计消耗 13 轮 CI（9 轮源码编译 + 4 轮 SDK），
其中**大部分失败源自我自己的实现错误**：

| 类别 | 次数 | 具体 |
|------|------|------|
| 我的实现错误 | 9 | 符号注入、日志吞噬、路径不匹配、PROFILE 未传、PKG_HASH、KCONFIG_NOSILENTUPDATE、`/dev/null`、预热时机、构建钩子 |
| 环境问题 | 2 | mkisofs 缺失、root 触发 tar configure |
| 方案限制 | 2 | ImageBuilder 无法加驱动、SDK 无法编译内核树内模块 |

**最值得记取的两点**:

1. **日志必须可见**。我把 make 输出重定向到容器内文件，容器销毁后
   日志全失，导致连续两轮只能看到 `exit code 2` 而被迫盲猜。
   改成 `tee` 后问题立刻暴露。

2. **防护性改动必须先验证语义**。我为了"防御"加的
   `KCONFIG_NOSILENTUPDATE` 和 `</dev/null`，各自制造了一个新故障。
