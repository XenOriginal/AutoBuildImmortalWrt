#
# Intel QAT (QuickAssist Technology) DH895XCC kernel modules
#
# 背景:
#   上游 OpenWrt/ImmortalWrt 未提供 QAT 驱动包, 此处新增。
#   上游 target/linux/generic/config-6.12 中 CONFIG_CRYPTO_DEV_QAT_* 全为
#   "is not set", kmods feed 中也没有任何 qat 相关包。
#
# 硬件 (宿主机实测):
#   0000:01:00.0  vendor=0x8086  device=0x19e2  class=0x0b4000
#   = Intel DH895XCC QAT 协处理器
#
# 【重要: 这是 in-tree 内核模块包】
#   QAT 驱动源码位于 Linux 内核树内 drivers/crypto/intel/qat/,
#   因此必须采用与 package/kernel/linux 相同的写法:
#     - 同时 include kernel.mk 与 package.mk
#     - PKG_BUILD_DIR 指向 $(KERNEL_BUILD_DIR)/packages
#     - Build/Compile 留空 (模块由内核构建系统编译)
#
#   若按 out-of-tree 写法 (只 include package.mk), 会出现:
#     make[3]: *** No targets specified and no makefile found.  Stop.
#   因为 OpenWrt 会在空的 PKG_BUILD_DIR 里找 Makefile。
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qat-dh895xcc
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/packages

include $(INCLUDE_DIR)/package.mk

# ---------------------------------------------------------------------------
# 构建钩子 —— 必须显式提供, 否则 OpenWrt 会在 PKG_BUILD_DIR 里
# 找 Makefile 并报 "No targets specified and no makefile found"
#
# 内核模块由内核自身的构建系统编译, 因此 Build/Compile 留空,
# 只需保证 Build/Prepare 创建出 PKG_BUILD_DIR 目录即可
# (与官方 package/kernel/linux/Makefile 完全一致)。
# ---------------------------------------------------------------------------
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Quilt
endef

define Build/Compile
endef

define KernelPackage/depends
endef

# ---------------------------------------------------------------------------
# 1. 公共层 intel_qat.ko —— 所有 QAT 驱动共享
# ---------------------------------------------------------------------------
define KernelPackage/crypto-qat-common
  SUBMENU:=Cryptographic API modules
  TITLE:=Intel QAT common library
  DEPENDS:=@TARGET_x86_64 \
	+kmod-crypto-manager \
	+kmod-crypto-acompress \
	+kmod-crypto-authenc \
	+kmod-crypto-kpp \
	+kmod-crypto-rsa \
	+kmod-crypto-rng \
	+kmod-lib-crc8
  KCONFIG:= \
	CONFIG_CRYPTO_HW=y \
	CONFIG_CRYPTO_DEV_QAT=m \
	CONFIG_CRYPTO_DH=m \
	CONFIG_PCI_IOV=y \
	CONFIG_PCI_MSI=y \
	CONFIG_PCIEAER=y
  FILES:= \
	$(LINUX_DIR)/drivers/crypto/intel/qat/qat_common/intel_qat.ko \
	$(LINUX_DIR)/crypto/dh_generic.ko
  AUTOLOAD:=$(call AutoLoad,08,dh_generic intel_qat)
endef

define KernelPackage/crypto-qat-common/description
  Intel QuickAssist Technology common library (intel_qat.ko).
  Shared by all QAT device drivers.
endef

# ---------------------------------------------------------------------------
# 2. DH895XCC 主体驱动 + SR-IOV VF
# ---------------------------------------------------------------------------
define KernelPackage/crypto-qat-dh895xcc
  SUBMENU:=Cryptographic API modules
  TITLE:=Intel QAT DH895XCC crypto accelerator
  DEPENDS:=@TARGET_x86_64 \
	+kmod-crypto-qat-common \
	+kmod-crypto-hash \
	+kmod-crypto-sha1 \
	+kmod-crypto-sha256 \
	+kmod-crypto-sha512 \
	+kmod-crypto-authenc \
	+kmod-crypto-aead \
	+qat-firmware-dh895xcc
  KCONFIG:= \
	CONFIG_CRYPTO_DEV_QAT_DH895xCC=m \
	CONFIG_CRYPTO_DEV_QAT_DH895xCCVF=m \
	CONFIG_CRYPTO_DEV_QAT_ERROR_INJECTION=n
  FILES:= \
	$(LINUX_DIR)/drivers/crypto/intel/qat/qat_dh895xcc/qat_dh895xcc.ko \
	$(LINUX_DIR)/drivers/crypto/intel/qat/qat_dh895xccvf/qat_dh895xccvf.ko
  AUTOLOAD:=$(call AutoLoad,09,qat_dh895xcc qat_dh895xccvf)
endef

define KernelPackage/crypto-qat-dh895xcc/description
  Intel QuickAssist Technology DH895XCC crypto accelerator driver.
  Provides hardware-accelerated AES/SHA and compression offload.
  Requires qat-firmware-dh895xcc for the firmware blobs.
endef

$(eval $(call KernelPackage,crypto-qat-common))
$(eval $(call KernelPackage,crypto-qat-dh895xcc))
