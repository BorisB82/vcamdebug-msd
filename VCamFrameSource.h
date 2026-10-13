// A frame source that VCamCore can pull replacement frames from, independent of origin
// (local mp4 decode, or NDI frames arriving via shared memory). replaceInPlace: only needs
// a latest CVPixelBuffer + a monotonic frame id.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VCamFrameSource <NSObject>
- (void)start;
- (void)stop;
- (nullable CVPixelBufferRef)latestFrameRetained CF_RETURNS_RETAINED;
- (uint64_t)latestFrameID;   // 0 means "no frame available"
@end

NS_ASSUME_NONNULL_END
