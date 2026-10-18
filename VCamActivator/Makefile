INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus-activator

vcamplus-activator_FILES      = Tweak.xm
vcamplus-activator_FRAMEWORKS = UIKit Foundation
vcamplus-activator_ARCHS      = arm64 arm64e
vcamplus-activator_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
