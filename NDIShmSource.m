#import "NDIShmSource.h"
#import "VCamNDIShared.h"

#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>
#import <os/lock.h>
#import <stdatomic.h>

@implementation NDIShmSource {
    int _fd;
    const uint8_t *_base;
    const VCamNDIHeader *_hdr;
    BOOL _running;

    os_unfair_lock _lock;            // guards the local pool
    uint32_t _w, _h;
    CVPixelBufferRef _pool[VCAMNDI_RING];
    int _poolIdx;
}

- (instancetype)init {
    if ((self = [super init])) { _fd = -1; _lock = OS_UNFAIR_LOCK_INIT; }
    return self;
}

- (void)dealloc { [self stop]; }

- (void)start {
    @synchronized(self) {
        if (_running) return;
        _fd = open(VCAMNDI_PATH, O_RDONLY);
        if (_fd < 0) { NSLog(@"[vcam-msd] ndi shm open failed: %s", strerror(errno)); return; }
        void *m = mmap(NULL, (size_t)VCAMNDI_FILE_SIZE, PROT_READ, MAP_SHARED, _fd, 0);
        if (m == MAP_FAILED) { NSLog(@"[vcam-msd] ndi shm mmap failed: %s", strerror(errno));
                               close(_fd); _fd = -1; return; }
        _base = (const uint8_t *)m;
        _hdr  = (const VCamNDIHeader *)m;
        _running = YES;
        NSLog(@"[vcam-msd] ndi shm mapped");
    }
}

- (void)stop {
    @synchronized(self) {
        if (_base) { munmap((void *)_base, (size_t)VCAMNDI_FILE_SIZE); _base = NULL; _hdr = NULL; }
        if (_fd >= 0) { close(_fd); _fd = -1; }
        _running = NO;
    }
    os_unfair_lock_lock(&_lock);
    for (int i = 0; i < (int)VCAMNDI_RING; i++) { if (_pool[i]) { CFRelease(_pool[i]); _pool[i] = NULL; } }
    _w = _h = 0; _poolIdx = 0;
    os_unfair_lock_unlock(&_lock);
}

- (uint64_t)latestFrameID {
    const VCamNDIHeader *h = _hdr;
    if (!h || h->magic != VCAMNDI_MAGIC || !h->enabled) return 0;
    uint64_t seq = h->frameSeq;
    return (seq & 1ULL) ? 0 : seq;   // odd = write in progress
}

// Caller holds _lock. UYVY / 422 single-plane to match the daemon's published format.
- (BOOL)ensurePoolW:(uint32_t)w h:(uint32_t)h {
    if (_w == w && _h == h && _pool[0]) return YES;
    for (int i = 0; i < (int)VCAMNDI_RING; i++) { if (_pool[i]) { CFRelease(_pool[i]); _pool[i] = NULL; } }
    _w = w; _h = h; _poolIdx = 0;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    for (int i = 0; i < (int)VCAMNDI_RING; i++) {
        CVPixelBufferRef pb = NULL;
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_422YpCbCr8,
                                         (__bridge CFDictionaryRef)attrs, &pb);
        if (r != kCVReturnSuccess || !pb) {
            NSLog(@"[vcam-msd] ndi pool create failed (%d)", r);
            _w = _h = 0; return NO;
        }
        _pool[i] = pb;
    }
    return YES;
}

- (CVPixelBufferRef)latestFrameRetained {
    const VCamNDIHeader *h = _hdr;
    if (!h || h->magic != VCAMNDI_MAGIC || !h->enabled) return NULL;

    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t s1 = h->frameSeq;
        if (s1 & 1ULL) continue;                 // mid-write, retry
        atomic_thread_fence(memory_order_acquire);
        uint32_t idx = h->currentIndex;
        uint32_t w = h->width, hh = h->height, rb = h->rowBytes;
        if (idx >= VCAMNDI_RING || w < 2 || hh < 2 || rb == 0) return NULL;
        if ((size_t)rb * hh > VCAMNDI_SLOT_BYTES) return NULL;   // sanity

        os_unfair_lock_lock(&_lock);
        if (![self ensurePoolW:w h:hh]) { os_unfair_lock_unlock(&_lock); return NULL; }
        CVPixelBufferRef dst = _pool[_poolIdx];
        const uint8_t *slot = _base + vcamndi_slot_offset(idx);   // packed UYVY, rowBytes = rb

        CVPixelBufferLockBaseAddress(dst, 0);
        uint8_t *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t dstStride = CVPixelBufferGetBytesPerRow(dst);
        size_t copyBytes = rb < dstStride ? rb : dstStride;
        for (uint32_t y = 0; y < hh; y++)
            memcpy(dstBase + (size_t)y * dstStride, slot + (size_t)y * rb, copyBytes);
        CVPixelBufferUnlockBaseAddress(dst, 0);

        atomic_thread_fence(memory_order_acquire);
        uint64_t s2 = h->frameSeq;
        if (s1 == s2) {                          // no publish happened mid-copy
            _poolIdx = (_poolIdx + 1) % VCAMNDI_RING;
            CFRetain(dst);
            os_unfair_lock_unlock(&_lock);
            return dst;
        }
        os_unfair_lock_unlock(&_lock);           // torn/raced, retry
    }
    return NULL;
}

@end
