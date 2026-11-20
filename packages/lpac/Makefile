# SPDX-License-Identifier: AGPL-3.0-only
#
# lpac 2.3.x + FM350 patches, packaged for OpenWrt.
# Source is our patched fork (estkme-group/lpac main + curated PRs + the
# LPAC_DRIVER_HOME loader patch), pulled by git at the v2.3.0-fm350 tag.
#
# 2.3.x split lpac into shared libs + dlopen'd driver plugins found via ELF
# RUNPATH; OpenWrt strips RUNPATH (CMAKE_SKIP_RPATH), so our loader patch adds a
# getenv("LPAC_DRIVER_HOME") fallback and we ship the plugins under
# /usr/lib/lpac/driver, with the wrapper exporting LPAC_DRIVER_HOME=/usr/lib/lpac.

include $(TOPDIR)/rules.mk

PKG_NAME:=lpac
PKG_VERSION:=2.3.0_p9
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/fildunsky/lpac.git
PKG_SOURCE_VERSION:=v2.3.0-fm350-p9
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=fildunsky
PKG_LICENSE:=AGPL-3.0-only LGPL-2.0-only

# libqmi/libmbim нужны ТОЛЬКО нативным QMI/MBIM-бэкендам (qmi.c/mbim.c линкуют
# qmi-glib/mbim-glib). Форсим их стейджинг ЛИШЬ когда соответствующий бэкенд
# включён - иначе SDK впустую собирал бы glib2 (в CI он ловит host-header leak
# "-I/usr/include" -> bits/libc-header-start.h) для сборки, где нативный QMI/MBIM
# не нужен. UQMI-бэкенд вызывает uqmi CLI в рантайме, glib и стейджинга не требует,
# поэтому AT+UQMI собирается без glib2 вовсе.
PKG_BUILD_DEPENDS:=$(if $(CONFIG_LPAC_WITH_QMI),libqmi) $(if $(CONFIG_LPAC_WITH_MBIM),libmbim)

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/lpac
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=eUICC eSIM LPA (patched 2.3.x for OpenWrt)
  DEPENDS:= \
    +LPAC_WITH_PCSC:libpcsclite \
    +LPAC_WITH_PCSC:pcscd \
    +LPAC_WITH_QMI:libqmi \
    +LPAC_WITH_MBIM:libmbim \
    +LPAC_WITH_UQMI:uqmi
  URL:=https://github.com/fildunsky/lpac
endef

define Package/lpac/description
  lpac is a eUICC eSIM LPA manager written in C. This build tracks our patched
  fork (2.3.x + AT-driver robustness PRs #446/#447/#448, bare-CCHO #449 and the
  LPAC_DRIVER_HOME loader fix). It is a general-purpose OpenWrt build, not a
  single-modem one: it ships every modem APDU backend - AT, QMI (libqmi), uqmi
  and MBIM - plus the stdio HTTP bridge, so the LuCI app can pick the right
  transport per modem. Verified on Fibocom FM350-GL (AT) and Qualcomm SDX55
  modules such as Foxconn T99W175 / Thales MV31-W / Dell DW5930e (MBIM/QMI).
endef

# Config INLINE (not `source "$(SOURCE)/Config.in"`): on the 24.10 SDK the build
# system resolved $(SOURCE) for this package to a non-existent feeds/base/lpac and
# defconfig died with `glob failed: No files found "feeds/base/lpac/Config.in"`.
# Inlining sidesteps that path resolution entirely; 25.12 builds the same either way.
define Package/lpac/config
	menu "Configuration"
		depends on PACKAGE_lpac

	config LPAC_WITH_PCSC
		bool "Include APDU PCSC Backend support"
		default n
		help
		  Compile LPAC with APDU PCSC Backend support (local smartcard readers).
		  Adds libpcsclite + pcscd dependencies; not needed for USB modems.

	config LPAC_WITH_AT
		bool "Include APDU AT Backend support"
		default y
		help
		  Native AT APDU backend (Fibocom FM350-GL and other modems that expose
		  AT+CCHO/CGLA on a serial port).

	config LPAC_WITH_QMI
		bool "Include APDU QMI (libqmi) Backend support"
		default y
		help
		  QMI APDU backend via libqmi (talks to the eUICC over cdc-wdm through
		  qmi-proxy, so it shares the channel with the data session). For Qualcomm
		  modems such as Foxconn T99W175 / Thales MV31-W / Dell DW5930e.

	config LPAC_WITH_UQMI
		bool "Include APDU uqmi Backend support"
		default y
		help
		  QMI APDU backend via the uqmi CLI (fallback where the libqmi backend does
		  not work). Adds a uqmi dependency.

	config LPAC_WITH_MBIM
		bool "Include APDU MBIM Backend support"
		default y
		help
		  MBIM APDU backend via libmbim (talks to the eUICC over cdc-wdm through
		  mbim-proxy). For modems running an MBIM composition.

	endmenu
endef

# УСТАНОВКА ПОВЕРХ ОФИЦИАЛЬНОГО ПАКЕТА. Официальный lpac кладёт бинарь ФАЙЛОМ
# /usr/lib/lpac, а нам нужен КАТАЛОГ (бинарь + dlopen-плагины). apk не заменяет
# файл каталогом: он валится на каждом файле "failed to extract usr/lib/lpac/...:
# Not a directory", успевает снести зависимости (pcscd/libpcsclite) и оставляет
# пакет полудохлым - обёртка есть, бинаря нет. Пользователю это выглядело как
# "eSIM не работает", а лечилось только ручным apk del + rm -rf.
# Воспроизведено на стенде 28.07.2026. Снимаем файл ДО распаковки.
define Package/lpac/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /usr/lib/lpac ] && rm -f /usr/lib/lpac
}
exit 0
endef

define Package/lpac/conffiles
/etc/config/lpac
endef

TARGET_CFLAGS += $(FPIC)

CMAKE_OPTIONS += \
  -DLPAC_WITH_APDU_PCSC=$(if $(CONFIG_LPAC_WITH_PCSC),ON,OFF) \
  -DLPAC_WITH_APDU_AT=$(if $(CONFIG_LPAC_WITH_AT),ON,OFF) \
  -DLPAC_WITH_APDU_QMI=$(if $(CONFIG_LPAC_WITH_QMI),ON,OFF) \
  -DLPAC_WITH_APDU_UQMI=$(if $(CONFIG_LPAC_WITH_UQMI),ON,OFF) \
  -DLPAC_WITH_APDU_MBIM=$(if $(CONFIG_LPAC_WITH_MBIM),ON,OFF) \
  -DLPAC_WITH_APDU_QMI_QRTR=OFF \
  -DLPAC_WITH_APDU_GBINDER=OFF \
  -DLPAC_WITH_HTTP_CURL=OFF

define Package/lpac/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/lpac.sh $(1)/usr/bin/lpac

	$(INSTALL_DIR) $(1)/etc/config
	$(CP) ./files/lpac.uci $(1)/etc/config/lpac

	# Real binary + dlopen'd driver plugins under /usr/lib/lpac; the loader finds
	# the plugins via LPAC_DRIVER_HOME (our patch), since OpenWrt strips RUNPATH.
	$(INSTALL_DIR) $(1)/usr/lib/lpac
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/lpac $(1)/usr/lib/lpac/lpac
	$(INSTALL_DIR) $(1)/usr/lib/lpac/driver
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/lpac/driver/*.so $(1)/usr/lib/lpac/driver/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/lib*.so* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,lpac))
