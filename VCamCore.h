// Interface for the mediaserverd virtual-camera coordinator: shared singleton, isEnabled gate, and
// replaceInPlace: which overwrites a CMSampleBuffer's pixel content while preserving its
// format/timing/attachments/IOSurface.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@class LocalVideoPlayer;
@class GPUImageProcessor;

NS_ASSUME_NONNULL_BEGIN

@interface VCamCore : NSObject

@property (class, nonatomic, readonly) VCamCore *shared;
@property (nonatomic, strong, readonly) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong, readonly) GPUImageProcessor *gpuProcessor;

- (BOOL)isEnabled;

- (BOOL)replaceInPlace:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
