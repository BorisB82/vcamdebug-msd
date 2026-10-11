TARGET                   = iphone:clang:latest:16.0
ARCHS                    = arm64
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

TOOL_NAME = vcamndid

NDI_DIR = $(THEOS_PROJECT_DIR)/../third_party/NDI

vcamndid_FILES        = main.m
vcamndid_FRAMEWORKS   = Foundation CoreMedia CoreVideo VideoToolbox AudioToolbox Accelerate SystemConfiguration CFNetwork
vcamndid_CFLAGS       = -fobjc-arc -I$(NDI_DIR)/include
vcamndid_LDFLAGS      = -L$(NDI_DIR)/lib -lndi_ios -lc++
vcamndid_CODESIGN_FLAGS = -Sentitlements.plist
vcamndid_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
