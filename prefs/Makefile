include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NovaShieldPrefs

NovaShieldPrefs_FILES = NovaShieldRootListController.m
NovaShieldPrefs_INSTALL_PATH = /Library/PreferenceBundles
NovaShieldPrefs_FRAMEWORKS = UIKit
NovaShieldPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# Preferences.framework is private and already loaded inside Settings, so resolve it at runtime.
NovaShieldPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
