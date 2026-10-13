// GPU scale+convert+rotate using a Metal-backed CIContext, with a per-(geometry) frame cache.
// Core Image renders each NEW source frame once (on the GPU) into a cached buffer matching the
// destination; every emit then does a cheap CPU copy of that cache into the camera's buffer. The
// cache is essential: the emit hook fires many times per source frame (multiple output nodes), so
// rendering per-emit would be ~5-6x the GPU work. Source is BGRA (mp4 decoder, or NDIShmSource's
// UYVY->BGRA); destination is the camera buffer (e.g. 420v) — CIContext does RGB->YUV + scale, and
// rotation is a free orientation transform in the render.

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

static BOOL vcam_cpuCopyPixelBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL ok = YES;
    if (!CVPixelBufferIsPlanar(src)) {
        const uint8_t *sp = CVPixelBufferGetBaseAddress(src);
        uint8_t *dp = CVPixelBufferGetBaseAddress(dst);
        size_t ss = CVPixelBufferGetBytesPerRow(src), ds = CVPixelBufferGetBytesPerRow(dst);
        size_t h = CVPixelBufferGetHeight(src), copy = ss < ds ? ss : ds;
        if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy); else ok = NO;
    } else {
        size_t np = CVPixelBufferGetPlaneCount(src);
        for (size_t p = 0; p < np; p++) {
            const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h  = CVPixelBufferGetHeightOfPlane(src, p), copy = ss < ds ? ss : ds;
            if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy); else ok = NO;
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}

@interface VCamCacheEntry : NSObject { @public CVPixelBufferRef _cached; uint64_t _srcID; }
@end
@implementation VCamCacheEntry
- (void)dealloc { if (_cached) CFRelease(_cached); }
@end

@implementation GPUImageProcessor {
    id<MTLDevice> _device;
    CIContext *_ci;
    CGColorSpaceRef _cs;
    NSRecursiveLock *_lock;
    NSMutableDictionary<NSString *, VCamCacheEntry *> *_caches;
    mach_timebase_info_data_t _tb;

    _Atomic int _rotation;        // 0/90/180/270 clockwise

    _Atomic uint64_t _renderCount;      // GPU renders (fresh frames)
    _Atomic uint64_t _renderTotalNs;
    _Atomic uint64_t _renderMaxNs;
    _Atomic uint64_t _hitCount;         // emits served from cache
    _Atomic uint64_t _failCount;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&_tb);
        _lock = [NSRecursiveLock new];
        _caches = [NSMutableDictionary new];
        _cs = CGColorSpaceCreateDeviceRGB();
        _device = MTLCreateSystemDefaultDevice();
        NSDictionary *opts = @{ kCIContextWorkingColorSpace : [NSNull null],
                                kCIContextOutputColorSpace  : [NSNull null] };
        _ci = _device ? [CIContext contextWithMTLDevice:_device options:opts]
                      : [CIContext contextWithOptions:opts];
        NSLog(@"[vcam-msd] CIContext ready (metal=%d, ci=%d)", _device != nil, _ci != nil);
    }
    return self;
}

- (void)dealloc { if (_cs) CGColorSpaceRelease(_cs); }

- (void)setRotationDegrees:(int)degrees {
    atomic_store_explicit(&_rotation, ((degrees % 360) + 360) % 360, memory_order_relaxed);
}

// GPU render src (BGRA) -> dstBuf (dst format), scaled to fill and rotated. Caller holds _lock.
- (BOOL)renderFrom:(CVPixelBufferRef)src into:(CVPixelBufferRef)dstBuf w:(size_t)w h:(size_t)h {
    @try {
        CIImage *img = [CIImage imageWithCVPixelBuffer:src];
        if (!img) return NO;
        int rot = atomic_load_explicit(&_rotation, memory_order_relaxed);
        CGImagePropertyOrientation o = kCGImagePropertyOrientationUp;
        if      (rot == 90)  o = kCGImagePropertyOrientationRight;
        else if (rot == 180) o = kCGImagePropertyOrientationDown;
        else if (rot == 270) o = kCGImagePropertyOrientationLeft;
        if (o != kCGImagePropertyOrientationUp) img = [img imageByApplyingCGOrientation:o];
        CGRect e = img.extent;
        if (e.origin.x != 0 || e.origin.y != 0)
            img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
        e = img.extent;
        if (e.size.width < 1 || e.size.height < 1) return NO;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale((CGFloat)w / e.size.width,
                                                                       (CGFloat)h / e.size.height)];
        [_ci render:img toCVPixelBuffer:dstBuf bounds:CGRectMake(0, 0, w, h) colorSpace:_cs];
        return YES;
    } @catch (id ex) {
        NSLog(@"[vcam-msd] CIContext render exception: %@", ex);
        return NO;
    }
}

- (BOOL)transferFrom:(CVPixelBufferRef)src srcID:(uint64_t)srcID into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_ci) return NO;
    size_t dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);

    [_lock lock];
    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", dstW, dstH, (unsigned)dstFmt];
    VCamCacheEntry *entry = _caches[key];
    if (!entry) {
        NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, dstFmt,
                                (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
            [_lock unlock]; return NO;
        }
        entry = [VCamCacheEntry new];
        entry->_cached = pb; entry->_srcID = 0;
        _caches[key] = entry;
    }

    BOOL ok = YES;
    if (entry->_srcID != srcID) {               // fresh frame -> one GPU render
        uint64_t r0 = mach_absolute_time();
        ok = [self renderFrom:src into:entry->_cached w:dstW h:dstH];
        if (ok) {
            entry->_srcID = srcID;
            uint64_t dt = (mach_absolute_time() - r0) * _tb.numer / _tb.denom;
            atomic_fetch_add_explicit(&_renderCount, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&_renderTotalNs, dt, memory_order_relaxed);
            uint64_t prev = atomic_load_explicit(&_renderMaxNs, memory_order_relaxed);
            while (dt > prev && !atomic_compare_exchange_weak_explicit(&_renderMaxNs, &prev, dt,
                       memory_order_relaxed, memory_order_relaxed)) {}
        } else {
            atomic_fetch_add_explicit(&_failCount, 1, memory_order_relaxed);
        }
    } else {
        atomic_fetch_add_explicit(&_hitCount, 1, memory_order_relaxed);
    }

    CVPixelBufferRef cached = entry->_cached;
    if (ok) CFRetain(cached);
    [_lock unlock];

    if (!ok) return NO;
    BOOL copied = vcam_cpuCopyPixelBuffer(cached, dst);
    CFRelease(cached);
    return copied;
}

- (uint64_t)vtCallCount         { return atomic_load_explicit(&_renderCount, memory_order_relaxed)
                                       + atomic_load_explicit(&_hitCount,    memory_order_relaxed); }
- (uint64_t)vtTotalNs           { return atomic_load_explicit(&_renderTotalNs, memory_order_relaxed); }
- (uint64_t)vtMaxNs             { return atomic_load_explicit(&_renderMaxNs,   memory_order_relaxed); }
- (uint64_t)cacheHitCount       { return atomic_load_explicit(&_hitCount,      memory_order_relaxed); }
- (uint64_t)cacheRebuildCount   { return atomic_load_explicit(&_renderCount,   memory_order_relaxed); }
- (uint64_t)cacheRebuildTotalNs { return atomic_load_explicit(&_renderTotalNs, memory_order_relaxed); }
- (int)lastFailStatus           { return (int)atomic_load_explicit(&_failCount, memory_order_relaxed); }

@end
