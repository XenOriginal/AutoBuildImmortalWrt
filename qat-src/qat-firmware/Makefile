#
# Intel QAT DH895XCC firmware blobs
#
# 这些 blob 来自 linux-firmware 仓库 (WHENCE 中已确认存在):
#   File: intel/qat/qat_895xcc.bin
#   File: intel/qat/qat_895xcc_mmp.bin
#
# 下载源: kernel.org linux-firmware (git.kernel.org 明文提供)
#
include $(TOPDIR)/rules.mk

PKG_NAME:=qat-firmware-dh895xcc
PKG_VERSION:=2026.01.01
PKG_RELEASE:=1

PKG_MAINTAINER:=XenOriginal
PKG_LICENSE:=Intel
PKG_LICENSE_FILES:=LICENCE.qat

include $(INCLUDE_DIR)/package.mk

QAT_FW_BASE:=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat

define Download/qat-fw-bin
  FILE:=qat_895xcc.bin
  URL:=$(QAT_FW_BASE)
endef
$(eval $(call Download,qat-fw-bin))

define Download/qat-fw-mmp
  FILE:=qat_895xcc_mmp.bin
  URL:=$(QAT_FW_BASE)
endef
$(eval $(call Download,qat-fw-mmp))

define Package/qat-firmware-dh895xcc
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Intel QAT DH895XCC firmware
  DEPENDS:=@TARGET_x86_64
endef

define Package/qat-firmware-dh895xcc/description
  Firmware blobs for Intel QuickAssist Technology DH895XCC.
  Installed to /lib/firmware/qat_895xcc.bin and qat_895xcc_mmp.bin,
  which is where the qat_dh895xcc driver looks for them.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/qat_895xcc.bin $(PKG_BUILD_DIR)/
	$(CP) $(DL_DIR)/qat_895xcc_mmp.bin $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/qat-firmware-dh895xcc/install
	$(INSTALL_DIR) $(1)/lib/firmware
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qat_895xcc.bin $(1)/lib/firmware/qat_895xcc.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qat_895xcc_mmp.bin $(1)/lib/firmware/qat_895xcc_mmp.bin
endef

$(eval $(call BuildPackage,qat-firmware-dh895xcc))
