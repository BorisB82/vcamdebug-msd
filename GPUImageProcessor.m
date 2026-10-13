// GPU scale+convert+rotate (Metal-backed CIContext), rendered OFF the emit thread.
//
// The render (~GPU time, several ms) must never block mediaserverd's emit thread or the camera
// pipeline stutters. So: a background caller (VCamCore's render timer) hands each NEW source frame
// to -renderSource:, which GPU-renders it into a triple-buffered "ready" slot for every destination
// geometry the emit path has registered. The emit path calls -copyLatestInto:, which only does a
// CPU memcpy of the latest ready slot into the camera buffer — microseconds, never blocks.
//
// Source is BGRA (mp4 decoder, or NDIShmSource's UYVY->BGRA); destination is the camera buffer
// (e.g. 420v). CIContext does RGB->YUV + scale; rotation is a free orientation transform.

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>

#define VCAM_GEOM_POOL 3

static BOOL vcam_cpuCopyPixelBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly); return NO;
    }
    BOOL ok = YES;
    if (!CVPixelBufferIsPlanar(src)) {
        const uint8_t *sp = CVPixelBufferGetBaseAddress(src); uint8_t *dp = CVPixelBufferGetBaseAddress(dst);
        size_t ss = CVPixelBufferGetBytesPerRow(src), ds = CVPixelBufferGetBytesPerRow(dst);
        size_t h = CVPixelBufferGetHeight(src), c = ss < ds ? ss : ds;
        if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, c); else ok = NO;
    } else {
        for (size_t p = 0, np = CVPixelBufferGetPlaneCount(src); p < np; p++) {
            const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, p), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h = CVPixelBufferGetHeightOfPlane(src, p), c = ss < ds ? ss : ds;
            if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, c); else ok = NO;
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}

// One destination geometry: a triple-buffer of rendered frames + the latest-ready pointer.
@interface VCamGeom : NSObject {
@public
    size_t w, h; OSType fmt;
    CVPixelBufferRef pool[VCAM_GEOM_POOL];
    int poolIdx;
    CVPixelBufferRef ready;     // latest fully-rendered (points into pool); not retained here
    uint64_t readySrcID;
    double lastSeen;            // uptime of last emit touch (to retire dead geometries)
    uint64_t emits;             // how many times the emit path asked for this geometry
    uint64_t renders;           // how many times we GPU-rendered it
}
@end
@implementation VCamGeom
- (void)dealloc { for (int i = 0; i < VCAM_GEOM_POOL; i++) if (pool[i]) CFRelease(pool[i]); }
@end

@implementation GPUImageProcessor {
    id<MTLDevice> _device;
    CIContext *_ci;
    CGColorSpaceRef _cs;
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, VCamGeom *> *_geoms;
    mach_timebase_info_data_t _tb;

    _Atomic int _rotation;
    _Atomic uint64_t _renderCount, _renderTotalNs, _renderMaxNs, _hitCount, _failCount;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&_tb);
        _lock = OS_UNFAIR_LOCK_INIT;
        _geoms = [NSMutableDictionary new];
        _cs = CGColorSpaceCreateDeviceRGB();
        _device = MTLCreateSystemDefaultDevice();
        NSDictionary *opts = @{ kCIContextWorkingColorSpace : [NSNull null],
                                kCIContextOutputColorSpace  : [NSNull null] };
        _ci = _device ? [CIContext contextWithMTLDevice:_device options:opts]
                      : [CIContext contextWithOptions:opts];
        NSLog(@"[vcam-msd] CIContext ready (metal=%d ci=%d)", _device != nil, _ci != nil);
    }
    return self;
}

- (void)dealloc { if (_cs) CGColorSpaceRelease(_cs); }

- (void)setRotationDegrees:(int)degrees {
    atomic_store_explicit(&_rotation, ((degrees % 360) + 360) % 360, memory_order_relaxed);
}

- (double)nowSec {
    return (double)(mach_absolute_time() * _tb.numer / _tb.denom) / 1.0e9;
}

- (BOOL)renderImage:(CIImage *)srcImg into:(CVPixelBufferRef)buf w:(size_t)w h:(size_t)h {
    @try {
        CIImage *img = srcImg;
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
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale((CGFloat)w/e.size.width,
                                                                       (CGFloat)h/e.size.height)];
        [_ci render:img toCVPixelBuffer:buf bounds:CGRectMake(0,0,w,h) colorSpace:_cs];
        return YES;
    } @catch (id ex) { NSLog(@"[vcam-msd] render exception: %@", ex); return NO; }
}

- (void)renderSource:(CVPixelBufferRef)src srcID:(uint64_t)srcID {
    if (!src || !_ci) return;
    CIImage *srcImg = [CIImage imageWithCVPixelBuffer:src];
    if (!srcImg) return;

    // Snapshot the list of live geometries (touched by an emit in the last ~2s).
    double now = [self nowSec];
    os_unfair_lock_lock(&_lock);
    NSMutableArray<VCamGeom *> *live = [NSMutableArray array];
    NSMutableArray<NSString *> *dead = [NSMutableArray array];
    [_geoms enumerateKeysAndObjectsUsingBlock:^(NSString *k, VCamGeom *g, BOOL *s) {
        if (now - g->lastSeen > 2.0) [dead addObject:k]; else [live addObject:g];
    }];
    for (NSString *k in dead) [_geoms removeObjectForKey:k];
    os_unfair_lock_unlock(&_lock);

    for (VCamGeom *g in live) {
        os_unfair_lock_lock(&_lock);
        int idx = g->poolIdx;
        CVPixelBufferRef buf = g->pool[idx];
        if (!buf) {
            NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
            if (CVPixelBufferCreate(kCFAllocatorDefault, g->w, g->h, g->fmt,
                                    (__bridge CFDictionaryRef)attrs, &buf) == kCVReturnSuccess) {
                g->pool[idx] = buf;
            } else buf = NULL;
        }
        size_t w = g->w, h = g->h;
        os_unfair_lock_unlock(&_lock);
        if (!buf) continue;

        uint64_t r0 = mach_absolute_time();
        BOOL ok = [self renderImage:srcImg into:buf w:w h:h];
        if (!ok) { atomic_fetch_add_explicit(&_failCount, 1, memory_order_relaxed); continue; }

        uint64_t dt = (mach_absolute_time() - r0) * _tb.numer / _tb.denom;
        atomic_fetch_add_explicit(&_renderCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&_renderTotalNs, dt, memory_order_relaxed);
        uint64_t prev = atomic_load_explicit(&_renderMaxNs, memory_order_relaxed);
        while (dt > prev && !atomic_compare_exchange_weak_explicit(&_renderMaxNs, &prev, dt,
                   memory_order_relaxed, memory_order_relaxed)) {}

        os_unfair_lock_lock(&_lock);
        g->ready = buf; g->readySrcID = srcID; g->renders++;
        g->poolIdx = (idx + 1) % VCAM_GEOM_POOL;   // next render uses a different slot
        os_unfair_lock_unlock(&_lock);
    }
}

// A one-line-per-geometry report of everything flowing through the hook, so we can see which
// buffer sizes/formats the pipeline actually emits (and how often) vs which we render.
- (NSString *)geometryReport {
    NSMutableString *s = [NSMutableString stringWithString:@"--- dst geometries seen ---\n"];
    os_unfair_lock_lock(&_lock);
    [_geoms enumerateKeysAndObjectsUsingBlock:^(NSString *k, VCamGeom *g, BOOL *stop) {
        char fcc[5] = {0};
        fcc[0]=(g->fmt>>24)&0xff; fcc[1]=(g->fmt>>16)&0xff; fcc[2]=(g->fmt>>8)&0xff; fcc[3]=g->fmt&0xff;
        [s appendFormat:@"%zux%zu '%s': emits=%llu renders=%llu\n",
            g->w, g->h, fcc, g->emits, g->renders];
    }];
    os_unfair_lock_unlock(&_lock);
    return s;
}

- (BOOL)copyLatestInto:(CVPixelBufferRef)dst {
    if (!dst) return NO;
    size_t w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);
    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", w, h, (unsigned)fmt];

    os_unfair_lock_lock(&_lock);
    VCamGeom *g = _geoms[key];
    if (!g) { g = [VCamGeom new]; g->w = w; g->h = h; g->fmt = fmt; _geoms[key] = g; }
    g->lastSeen = [self nowSec];
    g->emits++;
    CVPixelBufferRef ready = g->ready;
    if (ready) CFRetain(ready);
    os_unfair_lock_unlock(&_lock);

    if (!ready) return NO;                 // nothing rendered yet -> passthrough
    BOOL ok = vcam_cpuCopyPixelBuffer(ready, dst);
    CFRelease(ready);
    if (ok) atomic_fetch_add_explicit(&_hitCount, 1, memory_order_relaxed);
    return ok;
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
