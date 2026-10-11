# 编译期特性片段 (feature fragments)

把"编译阶段要做哪些优化"从构建脚本里拆出来, 变成可插拔、可验收、可开关的片段。

```
features/
├── enabled.txt          # 默认启用清单 (一行一个片段名)
├── 10-kvm-host.conf     # KVM/QEMU 硬件虚拟机宿主能力
├── 20-crypto-accel.conf # 加密/校验内核模块
├── 30-microcode.conf    # Intel CPU 微码
├── 40-net-tune.conf     # [可选] 内核时钟 100→250Hz
└── 50-image-slim.conf   # [可选] 关闭 DEBUG_INFO/BTF
```

## 一、怎么新增一项优化

1. 新建 `features/<NN>-<名字>.conf`(NN 决定应用顺序, 两位数字)
2. 在 `features/enabled.txt` 里登记一行 (想让它是可选优化就别登记)
3. 在 `x86-64-host/FEATURES.md` 的表格里补一行, 写清**实测依据**与**刷机后核验方法**
4. 需要时在 `[meta] expect_pkgs=` 里写上"必须出现在固件清单里的包" —— 构建脚本
   会在编译末尾自动断言 (闸门 5), 不通过就直接失败, 不会流出残缺固件

**构建脚本主体不需要任何改动。**

## 二、片段格式

```ini
[meta]
desc=一句话说明                       # 出现在构建日志的汇总里
expect_pkgs=pkgA,pkgB                 # 可选: 产物级验收 (读 .manifest)

[config]                              # OpenWrt .config 行
CONFIG_PACKAGE_kmod-foo=y

[config-unset]                        # 生成 "# CONFIG_KERNEL_XXX is not set"
CONFIG_KERNEL_XXX

[kconfig]                             # 写入 target/linux/x86/64/config-6.12
CONFIG_NET_CLS_ACT=y

[kconfig-unset]
CONFIG_HZ_100
```

规则:

- `#` 开头是注释, 空行忽略; 段名必须正好是上面 5 个之一
- 幂等: 同一片段重复应用不会产生重复行
- 自校验: 写入后立即回读断言, 任何一行没落地 → 非零退出

## 三、为什么必须自校验

内核符号写错 (或写了对当前 target 不存在的符号) 会被 `make defconfig` /
kconfig 合并**静默丢弃**, 只在几十分钟后的产物里表现为"功能没生效"。
历史事故: QAT 的 `CONFIG_CRYPTO_DEV_QAT_DH895XCC` 曾写成 `DH895XCC`,
配置项被悄悄丢掉。因此本机制的表态是: **宁可构建早期失败, 也不出"看起来开了"的固件。**

## 四、怎么只开某个可选优化

```bash
# 本地/CI 均可: 逗号分隔, 与 enabled.txt 是并集
FEATURES=40-net-tune,50-image-slim bash x86-64-host/build-source.sh
```

## 五、构建脚本里的两个挂载点

| 阶段 | 调用 | 作用 |
| --- | --- | --- |
| config | `apply-features.sh --stage config --config <SRC>/.config --stamp <SRC>/.features-applied` | 追加包选择, 写出验收戳记 |
| kconfig | `apply-features.sh --stage kconfig --kconfig <SRC>/target/linux/x86/64/config-6.12 --stamp <SRC>/.features-applied` | 追加内核符号 |

戳记 `.features-applied` 是 TSV, 供构建脚本末尾做两道产物级断言:

- `kconf<TAB>特性<TAB>CONFIG_X=y` → 断言**内核最终 .config** (闸门 2 扩展)
- `pkgs<TAB>特性<TAB>pkgA,pkgB` → 断言**固件 .manifest** (闸门 5)
