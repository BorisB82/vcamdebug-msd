INSTALL_TARGET_PROCESSES = mediaserverd
THEOS_PACKAGE_SCHEME     = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus-msd

vcamplus-msd_FILES      = Tweak.xm VCamCore.m LocalVideoPlayer.m GPUImageProcessor.m
vcamplus-msd_LDFLAGS    = -Wl,-x -Wl,-S -lsubstrate
vcamplus-msd_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage Foundation IOSurface ImageIO
vcamplus-msd_ARCHS      = arm64 arm64e
vcamplus-msd_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new -O2

include $(THEOS_MAKE_PATH)/tweak.mk
