TARGET                   = iphone:clang:latest:15.0
ARCHS                    = arm64 arm64e
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VCamControl

VCamControl_FILES        = main.m VCCAppDelegate.m VCCRootViewController.m
VCamControl_FRAMEWORKS   = UIKit Foundation UniformTypeIdentifiers
VCamControl_CFLAGS       = -fobjc-arc
VCamControl_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -a || true"
