include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wolplus
PKG_VERSION:=1.2
PKG_RELEASE:=1
PKG_BUILD_DEPENDS:=luci-base/host
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_MAINTAINER:=agogo233

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wolplus
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for wolplus
  DEPENDS:=+libc +luci-base +luci-lib-nixio
  PKGARCH:=all
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/wol $(PKG_BUILD_DIR)/wol.c
endef

define Package/luci-app-wolplus/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/wol $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/wolplus.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./luasrc/model/cbi/wolplus.lua $(1)/usr/lib/lua/luci/model/cbi/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/wolplus
	$(INSTALL_DATA) ./luasrc/view/wolplus/*.htm $(1)/usr/lib/lua/luci/view/wolplus/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/wolplus $(1)/etc/config/wolplus

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-app-wolplus $(1)/etc/uci-defaults/luci-app-wolplus

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(STAGING_DIR_HOSTPKG)/bin/po2lmo ./po/zh-cn/wolplus.po $(1)/usr/lib/lua/luci/i18n/wolplus.zh-cn.lmo
endef

$(eval $(call BuildPackage,luci-app-wolplus))
