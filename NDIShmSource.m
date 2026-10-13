#import "NDIShmSource.h"
#import "VCamNDIShared.h"

#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <Accelerate/Accelerate.h>
#import <os/lock.h>
#import <stdatomic.h>

@implementation NDIShmSource {
    int _fd;
    const uint8_t *_base;
    const VCamNDIHeader *_hdr;
    size_t _mappedSize;          // actual bytes mapped (= file size), to bound reads
    BOOL _running;

    os_unfair_lock _lock;            // guards the local pool
    uint32_t _w, _h;
    CVPixelBufferRef _pool[VCAMNDI_RING];   // 32BGRA (hardware VT transfer path)
    int _poolIdx;

    vImage_YpCbCrToARGB _ycInfo;     // UYVY(422) -> ARGB conversion info
    BOOL _ycReady;
}

// UYVY is byte order Cb Y Cr Y (== "422CbYpCrYp8"). Build the YpCbCr->ARGB conversion once,
// BT.709 video-range (standard for HD NDI). Colors can be retuned here without touching stability.
- (void)ensureConversion {
    if (_ycReady) return;
    vImage_YpCbCrPixelRange range = { 16, 128, 235, 240, 255, 0, 255, 0 }; // 8-bit video range
    vImage_Error e = vImageConvert_YpCbCrToARGB_GenerateConversion(
        kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &_ycInfo,
        kvImage422CbYpCrYp8, kvImageARGB8888, kvImageNoFlags);
    if (e == kvImageNoError) _ycReady = YES;
    else NSLog(@"[vcam-msd] vImage conversion gen failed: %ld", (long)e);
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
        // Map the file's ACTUAL size, not the compile-time expectation. If a stale/smaller
        // file is present (e.g. from an older daemon with a different slot size), mapping the
        // full size and reading a high slot would SIGBUS mediaserverd. We bound reads to
        // _mappedSize instead.
        struct stat st;
        if (fstat(_fd, &st) != 0 || (size_t)st.st_size < VCAMNDI_HEADER_SIZE) {
            NSLog(@"[vcam-msd] ndi shm too small/fstat failed"); close(_fd); _fd = -1; return;
        }
        _mappedSize = (size_t)st.st_size;
        void *m = mmap(NULL, _mappedSize, PROT_READ, MAP_SHARED, _fd, 0);
        if (m == MAP_FAILED) { NSLog(@"[vcam-msd] ndi shm mmap failed: %s", strerror(errno));
                               close(_fd); _fd = -1; _mappedSize = 0; return; }
        _base = (const uint8_t *)m;
        _hdr  = (const VCamNDIHeader *)m;
        _running = YES;
        NSLog(@"[vcam-msd] ndi shm mapped (%zu bytes)", _mappedSize);
    }
}

- (void)stop {
    @synchronized(self) {
        if (_base) { munmap((void *)_base, _mappedSize); _base = NULL; _hdr = NULL; _mappedSize = 0; }
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

// Caller holds _lock. 32BGRA pool: the daemon publishes UYVY, we convert UYVY->BGRA here with
// vImage, and hand BGRA to VideoToolbox — the same hardware transfer path the mp4 source uses
// (UYVY->420v directly was the software fallback / -12905). This conversion is in mediaserverd,
// which does not affect the NDI daemon's connection.
- (BOOL)ensurePoolW:(uint32_t)w h:(uint32_t)h {
    if (_w == w && _h == h && _pool[0]) return YES;
    for (int i = 0; i < (int)VCAMNDI_RING; i++) { if (_pool[i]) { CFRelease(_pool[i]); _pool[i] = NULL; } }
    _w = w; _h = h; _poolIdx = 0;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    for (int i = 0; i < (int)VCAMNDI_RING; i++) {
        CVPixelBufferRef pb = NULL;
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32BGRA,
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
        // Bound the slot against the actually-mapped size to avoid SIGBUS on a stale file.
        if (vcamndi_slot_offset(idx) + (uint64_t)rb * hh > _mappedSize) return NULL;

        os_unfair_lock_lock(&_lock);
        [self ensureConversion];
        if (!_ycReady || ![self ensurePoolW:w h:hh]) { os_unfair_lock_unlock(&_lock); return NULL; }
        CVPixelBufferRef dst = _pool[_poolIdx];
        const uint8_t *slot = _base + vcamndi_slot_offset(idx);   // packed UYVY, rowBytes = rb

        CVPixelBufferLockBaseAddress(dst, 0);
        // UYVY (422) -> BGRA via vImage. permuteMap {3,2,1,0} turns ARGB into BGRA byte order.
        vImage_Buffer srcB = { .data = (void *)slot, .height = hh, .width = w, .rowBytes = rb };
        vImage_Buffer dstB = { .data = CVPixelBufferGetBaseAddress(dst), .height = hh, .width = w,
                               .rowBytes = CVPixelBufferGetBytesPerRow(dst) };
        const uint8_t permuteMap[4] = { 3, 2, 1, 0 };
        vImage_Error ve = vImageConvert_422CbYpCrYp8ToARGB8888(&srcB, &dstB, &_ycInfo,
                                                               permuteMap, 255, kvImageNoFlags);
        CVPixelBufferUnlockBaseAddress(dst, 0);
        if (ve != kvImageNoError) { os_unfair_lock_unlock(&_lock); return NULL; }

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
