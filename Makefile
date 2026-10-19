# NovaShield: rootless only (Dopamine / palera1n rootless), arm64, iOS 15 and later.
export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NovaShield

NovaShield_FILES = Tweak.m
NovaShield_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
NovaShield_FRAMEWORKS = UIKit QuartzCore AudioToolbox

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
