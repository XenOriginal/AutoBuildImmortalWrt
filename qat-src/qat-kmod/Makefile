#
# Intel QAT C3XXX kernel modules (Atom C3000 integrated QAT)
#
# Hardware on this host:
#   0000:01:00.0  8086:19e2  class 0x0b4000
#   = Intel Atom C3000 Series QuickAssist Technology (C3XXX)
#
# Note: 8086:19e2 is NOT the discrete DH895XCC (0x0435).  The upstream
# driver for this device is qat_c3xxx / qat_c3xxxvf.  Using qat_dh895xcc
# leaves the device unbound (the bug found on 2026-10-19).
#
# QAT source is in-tree under drivers/crypto/intel/qat; use the same
# in-tree kmod package shape as package/kernel/linux.
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qat-c3xxx
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/packages

include $(INCLUDE_DIR)/package.mk

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
# 1. Common QAT library: intel_qat.ko
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
CONFIG_PCIEAER=y \
CONFIG_CRYPTO_DEV_QAT_ERROR_INJECTION=n
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
# 2. Atom C3000 QAT (C3XXX) driver + SR-IOV VF
# ---------------------------------------------------------------------------
define KernelPackage/crypto-qat-c3xxx
  SUBMENU:=Cryptographic API modules
  TITLE:=Intel Atom C3000 QAT (C3XXX) crypto accelerator
  DEPENDS:=@TARGET_x86_64 \
+kmod-crypto-qat-common \
+kmod-crypto-hash \
+kmod-crypto-sha1 \
+kmod-crypto-sha256 \
+kmod-crypto-sha512 \
+kmod-crypto-authenc \
+kmod-crypto-aead \
+qat-firmware-c3xxx
  KCONFIG:= \
CONFIG_CRYPTO_DEV_QAT_C3XXX=m \
CONFIG_CRYPTO_DEV_QAT_C3XXXVF=m
  FILES:= \
$(LINUX_DIR)/drivers/crypto/intel/qat/qat_c3xxx/qat_c3xxx.ko \
$(LINUX_DIR)/drivers/crypto/intel/qat/qat_c3xxxvf/qat_c3xxxvf.ko
  AUTOLOAD:=$(call AutoLoad,09,qat_c3xxx qat_c3xxxvf)
endef

define KernelPackage/crypto-qat-c3xxx/description
  Intel Atom C3000 Series QuickAssist Technology (C3XXX) driver.
  Provides hardware-accelerated AES/SHA and compression offload.
  Correct driver for PCI ID 8086:19e2 (not qat_dh895xcc/0x0435).
  Requires qat-firmware-c3xxx for the qat_c3xxx.bin blobs.
endef

$(eval $(call KernelPackage,crypto-qat-common))
$(eval $(call KernelPackage,crypto-qat-c3xxx))
