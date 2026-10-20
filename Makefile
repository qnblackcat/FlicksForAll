TARGET=iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard druid
ARCHS = arm64 arm64e
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = flickplus

flickplus_FILES = Tweak.xm OtherSettings.xm ShiftDelete.x Utils.m NFPPrefs.m
flickplus_FRAMEWORKS = UIKit QuartzCore
flickplus_CFLAGS = -fobjc-arc -Wno-c++11-extensions

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
