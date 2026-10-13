// GPU scale+convert+rotate using a Metal-backed CIContext. Replaces the old
// VTPixelTransferSession path, which ran the 1080->2304 scale on the CPU (~12ms/frame on the
// A11) regardless of pixel format. Core Image renders on the GPU, so the mediaserverd emit
// thread stays cheap (which also removes the CPU contention that was starving the NDI daemon's
// receive). Source is BGRA (from the mp4 decoder, or NDIShmSource's UYVY->BGRA); destination is
// the camera's buffer (e.g. 420v) — CIContext handles the RGB->YUV + scale, and rotation is a
// free orientation transform in the same pass.

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

@implementation GPUImageProcessor {
    id<MTLDevice> _device;
    CIContext *_ci;
    CGColorSpaceRef _cs;
    mach_timebase_info_data_t _tb;

    _Atomic int _rotation;        // 0/90/180/270 (clockwise)

    _Atomic uint64_t _renderCount;
    _Atomic uint64_t _renderTotalNs;
    _Atomic uint64_t _renderMaxNs;
    _Atomic uint64_t _failCount;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&_tb);
        _cs = CGColorSpaceCreateDeviceRGB();
        _device = MTLCreateSystemDefaultDevice();
        // No working color space => no implicit color management overhead; we want a direct
        // scale + matrix convert. (Color can be retuned here without affecting stability.)
        NSDictionary *opts = @{ kCIContextWorkingColorSpace : [NSNull null],
                                kCIContextOutputColorSpace  : [NSNull null] };
        _ci = _device ? [CIContext contextWithMTLDevice:_device options:opts]
                      : [CIContext contextWithOptions:opts];
        if (!_ci) NSLog(@"[vcam-msd] CIContext create failed");
        else NSLog(@"[vcam-msd] CIContext ready (metal=%d)", _device != nil);
    }
    return self;
}

- (void)dealloc {
    if (_cs) CGColorSpaceRelease(_cs);
}

- (void)setRotationDegrees:(int)degrees {
    int r = ((degrees % 360) + 360) % 360;
    atomic_store_explicit(&_rotation, r, memory_order_relaxed);
}

- (BOOL)transferFrom:(CVPixelBufferRef)src
               srcID:(uint64_t)srcID
                into:(CVPixelBufferRef)dst {
    (void)srcID;
    if (!src || !dst || !_ci) return NO;

    uint64_t t0 = mach_absolute_time();

    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    if (!img) { atomic_fetch_add_explicit(&_failCount, 1, memory_order_relaxed); return NO; }

    // Rotation (clockwise) via a baked orientation.
    int rot = atomic_load_explicit(&_rotation, memory_order_relaxed);
    CGImagePropertyOrientation o = kCGImagePropertyOrientationUp;
    if      (rot == 90)  o = kCGImagePropertyOrientationRight;
    else if (rot == 180) o = kCGImagePropertyOrientationDown;
    else if (rot == 270) o = kCGImagePropertyOrientationLeft;
    if (o != kCGImagePropertyOrientationUp) img = [img imageByApplyingCGOrientation:o];

    // Normalize to origin, then stretch to fill the destination.
    CGRect e = img.extent;
    if (e.origin.x != 0 || e.origin.y != 0)
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
    e = img.extent;
    if (e.size.width < 1 || e.size.height < 1) {
        atomic_fetch_add_explicit(&_failCount, 1, memory_order_relaxed); return NO;
    }
    CGFloat sx = (CGFloat)dstW / e.size.width;
    CGFloat sy = (CGFloat)dstH / e.size.height;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

    [_ci render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, dstW, dstH) colorSpace:_cs];

    uint64_t dtNs = (mach_absolute_time() - t0) * _tb.numer / _tb.denom;
    atomic_fetch_add_explicit(&_renderCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&_renderTotalNs, dtNs, memory_order_relaxed);
    uint64_t prev = atomic_load_explicit(&_renderMaxNs, memory_order_relaxed);
    while (dtNs > prev &&
           !atomic_compare_exchange_weak_explicit(&_renderMaxNs, &prev, dtNs,
               memory_order_relaxed, memory_order_relaxed)) {}
    return YES;
}

// Stats accessors keep their names so VCamCore's dump still compiles; they now report the GPU
// render instead of the old VT/cache path. rebuildMean (cacheRebuild*) == GPU render mean.
- (uint64_t)vtCallCount         { return atomic_load_explicit(&_renderCount,   memory_order_relaxed); }
- (uint64_t)vtTotalNs           { return atomic_load_explicit(&_renderTotalNs, memory_order_relaxed); }
- (uint64_t)vtMaxNs             { return atomic_load_explicit(&_renderMaxNs,   memory_order_relaxed); }
- (uint64_t)cacheHitCount       { return 0; }
- (uint64_t)cacheRebuildCount   { return atomic_load_explicit(&_renderCount,   memory_order_relaxed); }
- (uint64_t)cacheRebuildTotalNs { return atomic_load_explicit(&_renderTotalNs, memory_order_relaxed); }
- (int)lastFailStatus           { return (int)atomic_load_explicit(&_failCount, memory_order_relaxed); }

@end
