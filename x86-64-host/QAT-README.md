# 宿主机专属固件 —— Intel QAT 硬件加速说明

## 一、为什么必须走源码编译

ImageBuilder **只能安装官方 feed 中已有的二进制包**，无法新增内核驱动。

实证核查（ImmortalWrt 25.12.1）：

| 检查项 | 结果 |
|--------|------|
| kmods feed 包总数 | 1199 个 |
| 其中 QAT 相关 | **0 个** |
| `target/linux/generic/config-6.12` 中 QAT | 全部 `# ... is not set` |
| 现有 crypto hw 驱动 | 仅 atmel / ccp / hifn-795x / padlock |

因此 QAT 只能通过**源码编译**启用。

## 二、本机 QAT 硬件

```
0000:01:00.0  vendor=0x8086  device=0x19e2  class=0x0b4000
```

- `0x19e2` = Intel DH895XCC QAT 协处理器
- `0x0b4000` = 协处理器设备类
- 当前状态：**裸设备，无驱动绑定**（`/sys/bus/pci/devices/0000:01:00.0/driver` 不存在）

## 三、内核符号（大小写敏感）

Linux 6.12 `drivers/crypto/intel/qat/Kconfig` 中的确切符号名：

```
CONFIG_CRYPTO_DEV_QAT=m
CONFIG_CRYPTO_DEV_QAT_DH895xCC=m      # 注意是小写 x
CONFIG_CRYPTO_DEV_QAT_DH895xCCVF=m    # SR-IOV 虚拟功能
```

> 曾误写为 `DH895XCC`，已修正。大小写错误会导致配置项被 `make defconfig` 静默丢弃。

## 四、模块依赖链

```
intel_qat.ko        ← 公共层 (qat_common/), 所有 QAT 驱动共享
    ↓
qat_dh895xcc.ko     ← DH895XCC 主体驱动
    ↓
qat_dh895xccvf.ko   ← SR-IOV 虚拟功能
```

加载顺序由 `/etc/modules.d/40-qat` 保证。

路径（Linux 6.12）：
```
drivers/crypto/intel/qat/qat_common/intel_qat.ko
drivers/crypto/intel/qat/qat_dh895xcc/qat_dh895xcc.ko
drivers/crypto/intel/qat/qat_dh895xccvf/qat_dh895xccvf.ko
```

## 五、固件 blob

DH895XCC 驱动需要两个 blob，来自 `linux-firmware`（WHENCE 中已确认存在）：

```
intel/qat/qat_895xcc.bin
intel/qat/qat_895xcc_mmp.bin
```

下载源：`https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/`

安装位置：`/lib/firmware/qat_895xcc.bin` 与 `/lib/firmware/qat_895xcc_mmp.bin`

## 六、新增的文件

| 路径 | 作用 |
|------|------|
| `qat-src/qat-kmod/Makefile` | QAT 内核模块包（common + dh895xcc + vf） |
| `qat-src/qat-firmware/Makefile` | QAT 固件 blob 包（自动下载） |
| `host-files/etc/modules.d/40-qat` | 开机自动加载 QAT 模块 |

## 七、验证方法

编译成功后在宿主机执行：

```sh
# 1. 模块是否加载
lsmod | grep qat

# 2. PCI 设备是否绑定驱动
readlink /sys/bus/pci/devices/0000:01:00.0/driver
# 期望输出: .../drivers/qat_dh895xcc

# 3. 硬件加速能力是否注册
cat /proc/crypto | grep -i qat

# 4. dmesg
dmesg | grep -i qat
```

## 八、注意事项

1. **首次编译耗时长**：源码编译约 1.5-3 小时，远超 ImageBuilder 的 7-8 分钟。
2. **磁盘要求**：需 30-50GB，工作流中已加入 runner 磁盘清理步骤。
3. **DH895XCC 是较老代次**：加速能力以 AES/SHA 与压缩为主，实际收益视负载而定。
4. **不影响 Web 升级**：仍产出 sysupgrade 包，可保留配置升级。
