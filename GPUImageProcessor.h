// Interface for the cached pixel-transfer pipeline: transferFrom:srcID:into: plus VT/cache timing
// accessors.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPUImageProcessor : NSObject

- (BOOL)transferFrom:(CVPixelBufferRef)src
               srcID:(uint64_t)srcID
                into:(CVPixelBufferRef)dst;

- (uint64_t)vtCallCount;
- (uint64_t)vtTotalNs;
- (uint64_t)vtMaxNs;
- (uint64_t)cacheHitCount;
- (uint64_t)cacheRebuildCount;
- (uint64_t)cacheRebuildTotalNs;

@end

NS_ASSUME_NONNULL_END
