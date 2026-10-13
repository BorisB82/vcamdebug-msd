// Interface for the cached pixel-transfer pipeline: transferFrom:srcID:into: plus VT/cache timing
// accessors.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPUImageProcessor : NSObject

// Background thread: GPU-render a new source frame into ready buffers for every destination
// geometry the emit path has asked for. Heavy (~GPU time); must NOT be called on the emit thread.
- (void)renderSource:(CVPixelBufferRef)src srcID:(uint64_t)srcID;

// Emit thread: register the destination geometry and copy the latest ready frame into it.
// Cheap (a memcpy); returns NO if nothing is rendered yet for this geometry (caller passes the
// real camera frame through unchanged).
- (BOOL)copyLatestInto:(CVPixelBufferRef)dst;

// Rotation applied during the render, in degrees clockwise: 0, 90, 180, or 270.
- (void)setRotationDegrees:(int)degrees;

// Diagnostic: per-geometry emit/render counts (which buffer sizes the pipeline emits).
- (NSString *)geometryReport;

- (uint64_t)vtCallCount;
- (uint64_t)vtTotalNs;
- (uint64_t)vtMaxNs;
- (uint64_t)cacheHitCount;
- (uint64_t)cacheRebuildCount;
- (uint64_t)cacheRebuildTotalNs;
- (int)lastFailStatus;   // last non-noErr VTPixelTransfer status (0 = none)

@end

NS_ASSUME_NONNULL_END
