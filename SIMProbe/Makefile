TARGET                   = iphone:clang:latest:15.0
ARCHS                    = arm64 arm64e
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SIMProbe

SIMProbe_FILES          = main.m SNAppDelegate.m SNRootViewController.m SNProbe.m
SIMProbe_FRAMEWORKS     = UIKit Foundation CoreTelephony SystemConfiguration
SIMProbe_CFLAGS         = -fobjc-arc -Wno-deprecated-declarations
SIMProbe_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -a || true"
