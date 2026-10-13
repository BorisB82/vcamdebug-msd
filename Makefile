INSTALL_TARGET_PROCESSES = mediaserverd
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus-msd

vcamplus-msd_FILES      = Tweak.xm VCamCore.m LocalVideoPlayer.m NDIShmSource.m GPUImageProcessor.m
vcamplus-msd_LDFLAGS    = -Wl,-x -Wl,-S -lsubstrate
vcamplus-msd_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage Foundation IOSurface ImageIO Accelerate
vcamplus-msd_ARCHS      = arm64 arm64e
vcamplus-msd_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new -O2 -I$(THEOS_PROJECT_DIR)/common

include $(THEOS_MAKE_PATH)/tweak.mk
