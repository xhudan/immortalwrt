#
# atinout - send AT commands to a modem and read the response.
# Local recipe (no upstream OpenWrt package). Source from SourceForge.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=atinout
PKG_VERSION:=0.9.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=@SF/atinout
PKG_HASH:=skip

PKG_MAINTAINER:=Muhammad Huda Nugroho <mhudan21@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/atinout
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Send AT commands to a modem and read the response
  URL:=https://atinout.sourceforge.net/
endef

define Package/atinout/description
  atinout reads AT commands from a file (or stdin), sends them to a modem's
  control port, and writes the responses to a file (or stdout). Handy for
  scripting a cellular modem over its AT port (e.g. /dev/wwan0at0).
endef

# atinout.c uses VERSION as a string literal ("atinout version " VERSION),
# but the release tarball ships no value for it (normally injected from git).
# Define it as a quoted C string -- single-quotes keep the double-quotes
# literal through make+shell so the compiler sees -DVERSION="0.9.1".
define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-DVERSION='"$(PKG_VERSION)"' \
		-o $(PKG_BUILD_DIR)/atinout $(PKG_BUILD_DIR)/atinout.c
endef

define Package/atinout/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/atinout $(1)/usr/bin/atinout
endef

$(eval $(call BuildPackage,atinout))
