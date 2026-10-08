// Interface for the background video source: init with path, start/stop, latestFrameRetained
// (CF_RETURNS_RETAINED), and a monotonic latestFrameID used to invalidate downstream caches.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocalVideoPlayer : NSObject

- (instancetype)initWithPath:(NSString *)path;

- (void)start;
- (void)stop;

// Swap the source clip at runtime. If currently running, restarts the decode loop on the new path.
- (void)setPath:(NSString *)path;

- (nullable CVPixelBufferRef)latestFrameRetained CF_RETURNS_RETAINED;

- (uint64_t)latestFrameID;

@end

NS_ASSUME_NONNULL_END
