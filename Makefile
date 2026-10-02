TARGET=iphone:clang:16.5:16.0

INSTALL_TARGET_PROCESSES = SpringBoard

ARCHS = arm64 arm64e
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = flickplus

flickplus_FILES = Tweak.xm Utils.m
flickplus_CFLAGS = -fobjc-arc -Wno-c++11-extensions
flickplus_EXTRA_FRAMEWORKS += Cephei

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
