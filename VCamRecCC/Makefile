TARGET               = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VCamRecProvider

VCamRecProvider_FILES        = VCamRecProvider.m VCamRecToggle.m
VCamRecProvider_INSTALL_PATH = /Library/ControlCenter/CCSupport_Providers
VCamRecProvider_FRAMEWORKS   = UIKit Foundation
# Resolve the private CCUIToggleModule superclass at load time inside SpringBoard, so we don't
# need a ControlCenterUIKit SDK stub to link against.
VCamRecProvider_LDFLAGS      = -undefined dynamic_lookup
VCamRecProvider_CFLAGS       = -fobjc-arc -Wno-deprecated-declarations
VCamRecProvider_ARCHS        = arm64 arm64e

include $(THEOS_MAKE_PATH)/bundle.mk
