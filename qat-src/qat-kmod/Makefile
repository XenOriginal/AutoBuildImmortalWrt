#
# Intel QAT (QuickAssist Technology) DH895XCC kernel modules
#
# 背景: 上游 OpenWrt/ImmortalWrt 未提供 QAT 驱动包, 此处新增。
#   - 上游 target/linux/generic/config-6.12 中 CONFIG_CRYPTO_DEV_QAT_* 全部 "is not set"
#   - kmods feed 1199 个包中无任何 qat 相关项
#
# 本机硬件 (实测):
#   0000:01:00.0  vendor=0x8086  device=0x19e2  class=0x0b4000
#   = Intel DH895XCC QAT 协处理器, 当前无驱动绑定 (裸设备)
#
# 模块依赖链: intel_qat.ko (common) -> qat_dh895xcc.ko -> qat_dh895xccvf.ko
# 固件依赖:   /lib/firmware/qat_895xcc.bin + qat_895xcc_mmp.bin
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qat-dh895xcc
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

# ---------------------------------------------------------------------------
# 1. 公共层 intel_qat.ko  —— 所有 QAT 驱动共享, 必须最先加载
# ---------------------------------------------------------------------------
define KernelPackage/crypto-qat-common
  SUBMENU:=Cryptographic API modules
  TITLE:=Intel QAT common library
  DEPENDS:=@TARGET_x86_64 +kmod-crypto-manager +kmod-crypto-acompress
  KCONFIG:= \
	CONFIG_CRYPTO_HW=y \
	CONFIG_CRYPTO_DEV_QAT=m \
	CONFIG_PCI_IOV=y \
	CONFIG_PCI_MSI=y \
	CONFIG_PCIEAER=y
  FILES:=$(LINUX_DIR)/drivers/crypto/intel/qat/qat_common/intel_qat.ko
  AUTOLOAD:=$(call AutoLoad,08,intel_qat)
endef

define KernelPackage/crypto-qat-common/description
  Intel QuickAssist Technology common library (intel_qat.ko).
  Shared by all QAT device drivers.
endef

# ---------------------------------------------------------------------------
# 2. DH895XCC 主体驱动 + VF (SR-IOV 虚拟功能)
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
	+kmod-crypto-manager \
	+qat-firmware-dh895xcc
  KCONFIG:= \
	CONFIG_CRYPTO_DEV_QAT_DH895xCC=m \
	CONFIG_CRYPTO_DEV_QAT_DH895xCCVF=m
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
