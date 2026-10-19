#
# Intel QAT C3XXX firmware blobs
#
# Upstream files:
#   intel/qat/qat_c3xxx.bin
#   intel/qat/qat_c3xxx_mmp.bin
#
# The C3XXX driver (8086:19e2) uses these names.  The old
# qat_895xcc.bin blobs belong to the discrete DH895XCC (8086:0435).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=qat-firmware-c3xxx
PKG_VERSION:=2026.10.19
PKG_RELEASE:=1

PKG_MAINTAINER:=XenOriginal
PKG_LICENSE:=Intel
PKG_LICENSE_FILES:=LICENCE.qat

include $(INCLUDE_DIR)/package.mk

QAT_FW_BASE:=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat

define Download/qat-fw-c3xxx-bin
  FILE:=qat_c3xxx.bin
  URL:=$(QAT_FW_BASE)
  HASH:=99a1e70b24facc6e7834d7a72cbc82d113796af0d70af94f66f224fbc27c5340
endef
$(eval $(call Download,qat-fw-c3xxx-bin))

define Download/qat-fw-c3xxx-mmp
  FILE:=qat_c3xxx_mmp.bin
  URL:=$(QAT_FW_BASE)
  HASH:=2869d2306c60dff528bb68c4b55c3c5aab96e43c6fcd858540235eb283118de9
endef
$(eval $(call Download,qat-fw-c3xxx-mmp))

define Package/qat-firmware-c3xxx
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Intel QAT C3XXX firmware
  DEPENDS:=@TARGET_x86_64
  PKGARCH:=all
endef

define Package/qat-firmware-c3xxx/description
  Firmware blobs for Intel Atom C3000 QuickAssist Technology (C3XXX).
  Installed as /lib/firmware/qat_c3xxx.bin and qat_c3xxx_mmp.bin.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/qat_c3xxx.bin $(PKG_BUILD_DIR)/
	$(CP) $(DL_DIR)/qat_c3xxx_mmp.bin $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/qat-firmware-c3xxx/install
	$(INSTALL_DIR) $(1)/lib/firmware
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qat_c3xxx.bin $(1)/lib/firmware/qat_c3xxx.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qat_c3xxx_mmp.bin $(1)/lib/firmware/qat_c3xxx_mmp.bin
endef

$(eval $(call BuildPackage,qat-firmware-c3xxx))
