#
# Intel QAT DH895XCC firmware blobs
#
# 这些 blob 来自 linux-firmware 仓库 (WHENCE 中已确认存在):
#   File: intel/qat/qat_895xcc.bin
#   File: intel/qat/qat_895xcc_mmp.bin
#
# 下载源: kernel.org linux-firmware
# 哈希: 实测下载后计算 (2026-09-17)
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

# 注意: PKG_HASH 必须提供, 否则 make download 会因哈希校验失败而报错。
define Download/qat-fw-bin
  FILE:=qat_895xcc.bin
  URL:=$(QAT_FW_BASE)
  HASH:=3bd7958f092eed553f3ae7a4543409d4ac34c0057e8fe609b6dabedd4f5a0077
endef
$(eval $(call Download,qat-fw-bin))

define Download/qat-fw-mmp
  FILE:=qat_895xcc_mmp.bin
  URL:=$(QAT_FW_BASE)
  HASH:=4b7bd5930690accaf9dac6301ab7d91ea24bc1398c943ad7aa14c7a8118b63db
endef
$(eval $(call Download,qat-fw-mmp))

define Package/qat-firmware-dh895xcc
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Intel QAT DH895XCC firmware
  DEPENDS:=@TARGET_x86_64
  PKGARCH:=all
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
