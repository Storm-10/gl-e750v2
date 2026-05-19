# By Claude Sonnet 4.6 integrating mods by Vasiliy Olekhov
# https://github.com/olekhov/gl-e750v2/tree/cade5c063f6c883eef9d25c6a4e2a0c7d7e90f6a

include $(TOPDIR)/rules.mk

PKG_NAME:=gl-e750-mcu
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/gl-e750-mcu
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=GL-E750 MCU and modem support
	MAINTAINER:=Vasiliy Olekhov <olekhov@gmail.com>
	DEPENDS:=@TARGET_ath79 +lua-eco +lua-eco-termios +lua-eco-ubus \
		+lua-eco-uci +lua-eco-log +lua-cjson-lua5.4 +libiwinfo-lua \
		+kmod-usb-net-qmi-wwan +kmod-usb-serial-option \
		+kmod-usb-serial-wwan +uqmi
endef

define Package/gl-e750-mcu/description
	Provides:
	- mcu-proto: UART protocol tool for GL-E750 MCU (OLED, battery, power)
	- qmi-dtr: DTR assertion tool for Quectel EM060K-GL QMI activation
	- USB hotplug rules for Quectel EM060K-GL (2c7c:030b)
	- wwan0 raw-ip configuration hook
	- procd init script and UCI config for MCU daemon
endef

define Build/Configure
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -Wall -O2" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Package/gl-e750-mcu/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mcu-proto $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qmi-dtr $(1)/usr/bin
	$(INSTALL_BIN) ./files//mcu $(1)/usr/bin

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mcu.init $(1)/etc/init.d/mcu

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mcu.config $(1)/etc/config/mcu

	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) ./files/20-quectel-em060k $(1)/etc/hotplug.d/usb

	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./files/20-wwan-up $(1)/etc/hotplug.d/net
endef

$(eval $(call BuildPackage,gl-e750-mcu))
