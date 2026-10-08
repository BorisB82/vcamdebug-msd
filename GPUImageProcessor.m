// VTPixelTransferSession-based converter with a per-(width,height,format) CVPixelBuffer cache. A
// geometry's cached frame is rebuilt only when the source frame id changes (VT scale/convert,
// ScalingMode=CropSourceToCleanAperture, RealTime=true); the per-emit fast path is a CPU memcpy from
// cache into the destination. No rotation/orientation handling.

#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <dlfcn.h>
#import <string.h>

static BOOL vcam_cpuCopyPixelBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL planar = CVPixelBufferIsPlanar(src);
    if (!planar) {
        const uint8_t *sp = CVPixelBufferGetBaseAddress(src);
        uint8_t *dp = CVPixelBufferGetBaseAddress(dst);
        size_t ss = CVPixelBufferGetBytesPerRow(src);
        size_t ds = CVPixelBufferGetBytesPerRow(dst);
        size_t h  = CVPixelBufferGetHeight(src);
        size_t copy = ss < ds ? ss : ds;
        if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
    } else {
        size_t np = CVPixelBufferGetPlaneCount(src);
        for (size_t p = 0; p < np; p++) {
            const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h  = CVPixelBufferGetHeightOfPlane(src, p);
            size_t copy = ss < ds ? ss : ds;
            if (sp && dp) for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

@interface VCamCacheEntry : NSObject {
@public
    CVPixelBufferRef _cached;
    uint64_t _srcID;
    size_t _w;
    size_t _h;
    OSType _fmt;
}
@end
@implementation VCamCacheEntry
- (void)dealloc { if (_cached) CFRelease(_cached); }
@end

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSRecursiveLock *_lock;
    mach_timebase_info_data_t _tb;

    NSMutableDictionary<NSString *, VCamCacheEntry *> *_caches;

    _Atomic uint64_t _vtCount;
    _Atomic uint64_t _vtTotalNs;
    _Atomic uint64_t _vtMaxNs;
    _Atomic uint64_t _cacheHits;
    _Atomic uint64_t _cacheRebuilds;
    _Atomic uint64_t _cacheRebuildTotalNs;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        _caches = [NSMutableDictionary new];
        mach_timebase_info(&_tb);
        OSStatus s = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_session);
        if (s != noErr || !_session) {
            NSLog(@"[vcam-msd] VTPixelTransferSessionCreate failed: %d", (int)s);
            _session = NULL;
            return self;
        }
        CFStringRef *pRT  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_RealTime");
        CFStringRef *pSM  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_ScalingMode");
        CFStringRef *pCrop= (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTScalingMode_CropSourceToCleanAperture");
        if (pRT && *pRT) VTSessionSetProperty(_session, *pRT, kCFBooleanTrue);
        if (pSM && *pSM && pCrop && *pCrop) VTSessionSetProperty(_session, *pSM, *pCrop);
    }
    return self;
}

- (void)dealloc {
    if (_session) {
        VTPixelTransferSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

- (BOOL)transferFrom:(CVPixelBufferRef)src
               srcID:(uint64_t)srcID
                into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_session) return NO;

    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);

    uint64_t t0 = mach_absolute_time();

    [_lock lock];
    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", dstW, dstH, (unsigned)dstFmt];
    VCamCacheEntry *entry = _caches[key];

    if (!entry) {

        NSDictionary *attrs = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(dstFmt),
            (NSString *)kCVPixelBufferWidthKey:           @(dstW),
            (NSString *)kCVPixelBufferHeightKey:          @(dstH),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferRef pb = NULL;
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, dstFmt,
                                         (__bridge CFDictionaryRef)attrs, &pb);
        if (r != kCVReturnSuccess || !pb) { [_lock unlock]; return NO; }
        entry = [VCamCacheEntry new];
        entry->_cached = pb;
        entry->_w = dstW; entry->_h = dstH; entry->_fmt = dstFmt;
        entry->_srcID = 0;
        _caches[key] = entry;
    }

    OSStatus rebuildStatus = noErr;
    if (entry->_srcID != srcID) {

        uint64_t r0 = mach_absolute_time();
        rebuildStatus = VTPixelTransferSessionTransferImage(_session, src, entry->_cached);
        uint64_t r1 = mach_absolute_time();
        if (rebuildStatus == noErr) {
            entry->_srcID = srcID;
            uint64_t dtNs = (r1 - r0) * _tb.numer / _tb.denom;
            atomic_fetch_add_explicit(&_cacheRebuilds, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&_cacheRebuildTotalNs, dtNs, memory_order_relaxed);
        }
    } else {
        atomic_fetch_add_explicit(&_cacheHits, 1, memory_order_relaxed);
    }

    CVPixelBufferRef cachedSnap = entry->_cached;
    if (rebuildStatus == noErr) CFRetain(cachedSnap);
    [_lock unlock];

    BOOL ok = NO;
    if (rebuildStatus == noErr) {
        ok = vcam_cpuCopyPixelBuffer(cachedSnap, dst);
        CFRelease(cachedSnap);
    }

    uint64_t t1 = mach_absolute_time();
    uint64_t dtNs = (t1 - t0) * _tb.numer / _tb.denom;
    atomic_fetch_add_explicit(&_vtCount,   1,    memory_order_relaxed);
    atomic_fetch_add_explicit(&_vtTotalNs, dtNs, memory_order_relaxed);
    uint64_t prev = atomic_load_explicit(&_vtMaxNs, memory_order_relaxed);
    while (dtNs > prev &&
           !atomic_compare_exchange_weak_explicit(&_vtMaxNs, &prev, dtNs,
               memory_order_relaxed, memory_order_relaxed)) {}
    return ok;
}

- (uint64_t)vtCallCount         { return atomic_load_explicit(&_vtCount,            memory_order_relaxed); }
- (uint64_t)vtTotalNs           { return atomic_load_explicit(&_vtTotalNs,          memory_order_relaxed); }
- (uint64_t)vtMaxNs             { return atomic_load_explicit(&_vtMaxNs,            memory_order_relaxed); }
- (uint64_t)cacheHitCount       { return atomic_load_explicit(&_cacheHits,          memory_order_relaxed); }
- (uint64_t)cacheRebuildCount   { return atomic_load_explicit(&_cacheRebuilds,      memory_order_relaxed); }
- (uint64_t)cacheRebuildTotalNs { return atomic_load_explicit(&_cacheRebuildTotalNs,memory_order_relaxed); }

@end
