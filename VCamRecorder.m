// See VCamRecorder.h. Hardware-HEVC recorder for the real camera frames at the emit hook.
//
// Threading model (same lesson as the render pump): the emit thread does the cheapest possible
// work — an atomic gate, and when recording, a plane memcpy into a fresh IOSurface buffer plus a
// dispatch_async. All AVAssetWriter touching happens on a single serial queue (_recQueue), so the
// writer is never driven from the time-critical emit thread and never from two threads at once.

#import "VCamRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <notify.h>

static NSString *const kRecStatusFile = @"/var/mobile/Media/DCIM/vcam_rec_status.txt";
static NSString *const kRecDir        = @"/var/mobile/Media/DCIM";
static NSString *const kRecConfigPlist = @"/var/mobile/Media/DCIM/vcam_msd.plist";

static NSString *const kNoteRecStart  = @"com.vcamplus.rec.start";
static NSString *const kNoteRecStop   = @"com.vcamplus.rec.stop";
static NSString *const kNoteRecToggle = @"com.vcamplus.rec.toggle";

// Build an OSType from a 4-char fourcc string like "420v" (as printed in the geometry report).
static OSType vcam_fourccFromString(NSString *s) {
    if (s.length != 4) return 0;
    const char *c = s.UTF8String;
    return ((OSType)(uint8_t)c[0] << 24) | ((OSType)(uint8_t)c[1] << 16) |
           ((OSType)(uint8_t)c[2] << 8)  |  (OSType)(uint8_t)c[3];
}

// How long to watch the emitted geometries before locking onto the largest (the master feed).
#define VCAM_REC_PROBE_SEC   0.5
// Cap of frames copied-but-not-yet-encoded; bounds memory if the encoder falls behind.
#define VCAM_REC_MAX_INFLIGHT 6
// Target bitrate = pixels/s * this (bits per pixel). 0.5 bpp HEVC ≈ visually lossless for a
// 3 MP feed (~45 Mbps at 2304x1296@30).
#define VCAM_REC_BPP         0.5
#define VCAM_REC_MIN_BITRATE (20 * 1000 * 1000)
#define VCAM_REC_MAX_BITRATE (120 * 1000 * 1000)

// Deep-copy a camera pixel buffer into a fresh IOSurface-backed buffer of the same format, so the
// encoder owns a stable copy after the emit hook returns (the pipeline recycles its own buffers).
static CVPixelBufferRef vcam_copyPixelBuffer(CVPixelBufferRef src) {
    if (!src) return NULL;
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferPixelFormatTypeKey     : @(fmt),
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (CVPixelBufferIsPlanar(src)) {
        size_t n = CVPixelBufferGetPlaneCount(src);
        for (size_t p = 0; p < n; p++) {
            const uint8_t *s = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *d       = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t rows = CVPixelBufferGetHeightOfPlane(src, p);
            size_t bytes = sbpr < dbpr ? sbpr : dbpr;
            if (s && d) for (size_t y = 0; y < rows; y++) memcpy(d + y * dbpr, s + y * sbpr, bytes);
        }
    } else {
        const uint8_t *s = CVPixelBufferGetBaseAddress(src);
        uint8_t *d       = CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src);
        size_t dbpr = CVPixelBufferGetBytesPerRow(dst);
        size_t bytes = sbpr < dbpr ? sbpr : dbpr;
        if (s && d) for (size_t y = 0; y < h; y++) memcpy(d + y * dbpr, s + y * sbpr, bytes);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

@implementation VCamRecorder {
    dispatch_queue_t _recQueue;     // serializes ALL writer work
    dispatch_queue_t _noteQueue;    // Darwin-note delivery
    int _noteTokens[3];

    _Atomic bool _armed;            // control gate, read on the emit hot path
    _Atomic bool _locked;           // geometry chosen; emit path may now copy+append
    _Atomic uint64_t _gen;          // bumps each start/stop to invalidate stale probe callbacks
    _Atomic int _inflight;          // copied-but-not-encoded frames

    // Chosen geometry (written on _recQueue before _locked is released; read on emit thread after).
    size_t _lockW, _lockH; OSType _lockFmt;

    // Explicit target geometry from the config plist (recW/recH/recFmt). When set, we lock onto it
    // immediately with no probe. Touched only on _recQueue.
    BOOL _hasTarget; size_t _targetW, _targetH; OSType _targetFmt;

    // Probe candidate (largest geometry seen), guarded by _candLock.
    os_unfair_lock _candLock;
    uint64_t _candPixels; size_t _candW, _candH; OSType _candFmt;

    _Atomic int _writerStatus;      // snapshot of AVAssetWriterStatus for the stats dump

    // Writer state — touched only on _recQueue.
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    BOOL _sessionStarted;
    BOOL _finishing;
    NSString *_outPath;
    CMTime _firstPTS, _lastPTS;

    // Session counters.
    _Atomic uint64_t _framesSeen;   // frames matching the locked geometry (vs notReady = stall)
    _Atomic uint64_t _framesWritten, _framesNotReady, _framesAppendFail;
    _Atomic uint64_t _framesDroppedInflight, _framesCopyFail;
}

+ (instancetype)shared {
    static VCamRecorder *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamRecorder new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _recQueue  = dispatch_queue_create("com.vcamplus.msd.recorder", DISPATCH_QUEUE_SERIAL);
        _noteQueue = dispatch_queue_create("com.vcamplus.msd.recorder.note", DISPATCH_QUEUE_SERIAL);
        _candLock  = OS_UNFAIR_LOCK_INIT;
        [self registerNotes];
        [self writeStatus:@"idle" extra:@"last=- result=none frames=0"];
        NSLog(@"[vcam-rec] ready (rec.start/.stop/.toggle)");
    }
    return self;
}

- (void)registerNotes {
    NSArray<NSString *> *names = @[kNoteRecStart, kNoteRecStop, kNoteRecToggle];
    __weak typeof(self) weakSelf = self;
    [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        notify_register_dispatch(name.UTF8String, &self->_noteTokens[i], self->_noteQueue, ^(int t) {
            typeof(self) s = weakSelf; if (!s) return;
            if      ([name isEqualToString:kNoteRecStart])  [s start];
            else if ([name isEqualToString:kNoteRecStop])   [s stop];
            else                                            [s toggle];
        });
    }];
}

- (BOOL)isRecording { return atomic_load_explicit(&_armed, memory_order_relaxed); }

- (void)toggle { if ([self isRecording]) [self stop]; else [self start]; }

- (void)start {
    if (atomic_exchange(&_armed, true)) return;         // already armed
    uint64_t gen = atomic_fetch_add(&_gen, 1) + 1;
    [self writeStatus:@"arming" extra:@"probing for largest feed…"];
    dispatch_async(_recQueue, ^{
        [self resetWriterState];
        atomic_store(&_framesSeen, 0);           atomic_store(&_framesWritten, 0);
        atomic_store(&_framesNotReady, 0);       atomic_store(&_framesAppendFail, 0);
        atomic_store(&_framesDroppedInflight, 0);atomic_store(&_framesCopyFail, 0);
        os_unfair_lock_lock(&_candLock);
        _candPixels = 0; _candW = _candH = 0; _candFmt = 0;
        os_unfair_lock_unlock(&_candLock);

        // Explicit target from the control app (recW/recH/recFmt) → lock immediately, no probe.
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kRecConfigPlist];
        long tw = [cfg[@"recW"] longValue], th = [cfg[@"recH"] longValue];
        OSType tf = vcam_fourccFromString([cfg[@"recFmt"] description]);
        if (tw > 0 && th > 0 && tf != 0) {
            _hasTarget = YES; _targetW = (size_t)tw; _targetH = (size_t)th; _targetFmt = tf;
            [self buildWriterW:_targetW h:_targetH fmt:_targetFmt];   // ready before any frame
        } else {
            _hasTarget = NO;
            [self scheduleProbeForGen:gen];
        }
    });
}

- (void)stop {
    if (!atomic_exchange(&_armed, false)) return;       // wasn't armed
    atomic_fetch_add(&_gen, 1);                          // invalidate pending probes
    [self writeStatus:@"finishing" extra:nil];
    dispatch_async(_recQueue, ^{ [self finishWriting]; });
}

#pragma mark - Emit hot path

- (void)observeSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb || !atomic_load_explicit(&_armed, memory_order_relaxed)) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);

    if (!atomic_load_explicit(&_locked, memory_order_acquire)) {
        uint64_t px = (uint64_t)w * h;                   // probing: remember the largest feed
        os_unfair_lock_lock(&_candLock);
        if (px > _candPixels) { _candPixels = px; _candW = w; _candH = h; _candFmt = fmt; }
        os_unfair_lock_unlock(&_candLock);
        return;
    }
    if (w != _lockW || h != _lockH || fmt != _lockFmt) return;   // only the locked geometry
    atomic_fetch_add_explicit(&_framesSeen, 1, memory_order_relaxed);

    if (atomic_load_explicit(&_inflight, memory_order_relaxed) >= VCAM_REC_MAX_INFLIGHT) {
        atomic_fetch_add_explicit(&_framesDroppedInflight, 1, memory_order_relaxed);
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    CVPixelBufferRef copy = vcam_copyPixelBuffer(pb);
    if (!copy) { atomic_fetch_add_explicit(&_framesCopyFail, 1, memory_order_relaxed); return; }
    atomic_fetch_add_explicit(&_inflight, 1, memory_order_relaxed);
    dispatch_async(_recQueue, ^{ [self appendCopy:copy pts:pts]; });
}

#pragma mark - _recQueue only

- (void)scheduleProbeForGen:(uint64_t)gen {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VCAM_REC_PROBE_SEC * NSEC_PER_SEC)),
                   _recQueue, ^{ [self tryLockForGen:gen]; });
}

- (void)tryLockForGen:(uint64_t)gen {
    if (!atomic_load(&_armed) || atomic_load(&_gen) != gen) return;
    if (atomic_load_explicit(&_locked, memory_order_relaxed)) return;
    uint64_t px; size_t w, h; OSType fmt;
    os_unfair_lock_lock(&_candLock);
    px = _candPixels; w = _candW; h = _candH; fmt = _candFmt;
    os_unfair_lock_unlock(&_candLock);
    if (px == 0) {                                               // no frames yet; keep watching
        [self writeStatus:@"arming" extra:@"waiting for camera frames — open the Camera"];
        [self scheduleProbeForGen:gen];
        return;
    }
    [self buildWriterW:w h:h fmt:fmt];
}

- (void)buildWriterW:(size_t)w h:(size_t)h fmt:(OSType)fmt {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    _outPath = [kRecDir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"vcam_rec_%@.mov", [df stringFromDate:NSDate.date]]];
    [NSFileManager.defaultManager removeItemAtPath:_outPath error:nil];

    NSError *err = nil;
    _writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:_outPath]
                                       fileType:AVFileTypeQuickTimeMovie error:&err];
    if (!_writer) {
        NSLog(@"[vcam-rec] writer create failed: %@", err);
        [self writeStatus:@"error" extra:err.localizedDescription ?: @"writer create failed"];
        return;
    }

    double bitrate = (double)w * h * 30.0 * VCAM_REC_BPP;
    if (bitrate < VCAM_REC_MIN_BITRATE) bitrate = VCAM_REC_MIN_BITRATE;
    if (bitrate > VCAM_REC_MAX_BITRATE) bitrate = VCAM_REC_MAX_BITRATE;

    NSDictionary *compression = @{
        AVVideoAverageBitRateKey          : @((NSInteger)bitrate),
        AVVideoExpectedSourceFrameRateKey : @30,
        AVVideoMaxKeyFrameIntervalKey     : @30,
        AVVideoProfileLevelKey            : @"HEVC_Main_AutoLevel",
    };
    NSDictionary *settings = @{
        AVVideoCodecKey  : AVVideoCodecTypeHEVC,
        AVVideoWidthKey  : @(w),
        AVVideoHeightKey : @(h),
        AVVideoCompressionPropertiesKey : compression,
    };
    _input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    _input.expectsMediaDataInRealTime = YES;

    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(fmt),
        (id)kCVPixelBufferWidthKey           : @(w),
        (id)kCVPixelBufferHeightKey          : @(h),
    };
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_input
                sourcePixelBufferAttributes:srcAttrs];

    if (![_writer canAddInput:_input]) {
        NSLog(@"[vcam-rec] cannot add input for %zux%zu fmt=0x%08x", w, h, fmt);
        [self writeStatus:@"error" extra:@"codec rejected this pixel format"];
        _writer = nil; _input = nil; _adaptor = nil;
        return;
    }
    [_writer addInput:_input];

    _sessionStarted = NO; _finishing = NO;
    atomic_store(&_writerStatus, (int)_writer.status);
    _lockW = w; _lockH = h; _lockFmt = fmt;
    atomic_store_explicit(&_locked, true, memory_order_release);

    char fcc[5] = {0};
    fcc[0]=(fmt>>24)&0xff; fcc[1]=(fmt>>16)&0xff; fcc[2]=(fmt>>8)&0xff; fcc[3]=fmt&0xff;
    [self writeStatus:@"recording"
                extra:[NSString stringWithFormat:@"%zux%zu '%s' hevc %.0fMbps file=%@",
                       w, h, fcc, bitrate / 1e6, _outPath.lastPathComponent]];
    NSLog(@"[vcam-rec] recording %zux%zu '%s' %.0fMbps -> %@", w, h, fcc, bitrate/1e6, _outPath);
}

- (void)appendCopy:(CVPixelBufferRef)copy pts:(CMTime)pts {
    if (_finishing || !_writer) { CFRelease(copy); atomic_fetch_sub(&_inflight, 1); return; }

    if (_writer.status == AVAssetWriterStatusUnknown) {
        if (![_writer startWriting]) {
            NSLog(@"[vcam-rec] startWriting failed: %@", _writer.error);
            [self writeStatus:@"error" extra:_writer.error.localizedDescription ?: @"startWriting failed"];
            CFRelease(copy); atomic_fetch_sub(&_inflight, 1); return;
        }
        [_writer startSessionAtSourceTime:pts];
        _sessionStarted = YES; _firstPTS = pts; _lastPTS = pts;
    }

    if (_writer.status == AVAssetWriterStatusWriting && _input.isReadyForMoreMediaData) {
        if ([_adaptor appendPixelBuffer:copy withPresentationTime:pts]) {
            atomic_fetch_add_explicit(&_framesWritten, 1, memory_order_relaxed);
            _lastPTS = pts;
        } else {
            atomic_fetch_add_explicit(&_framesAppendFail, 1, memory_order_relaxed);
        }
    } else {
        atomic_fetch_add_explicit(&_framesNotReady, 1, memory_order_relaxed);
    }
    atomic_store(&_writerStatus, (int)_writer.status);
    CFRelease(copy);
    atomic_fetch_sub_explicit(&_inflight, 1, memory_order_relaxed);
}

- (void)finishWriting {
    _finishing = YES;
    atomic_store_explicit(&_locked, false, memory_order_relaxed);

    if (_writer && _sessionStarted && _writer.status == AVAssetWriterStatusWriting) {
        [_input markAsFinished];
        AVAssetWriter *w = _writer;
        NSString *path = _outPath;
        uint64_t n = atomic_load(&_framesWritten);
        double secs = CMTIME_IS_VALID(_lastPTS) && CMTIME_IS_VALID(_firstPTS)
            ? CMTimeGetSeconds(CMTimeSubtract(_lastPTS, _firstPTS)) : 0.0;
        [w finishWritingWithCompletionHandler:^{
            BOOL ok = (w.status == AVAssetWriterStatusCompleted);
            [self writeStatus:@"idle"
                        extra:[NSString stringWithFormat:@"last=%@ result=%@ frames=%llu dur=%.1fs err=%@",
                               path.lastPathComponent ?: @"-", ok ? @"ok" : @"failed", n, secs,
                               w.error ? w.error.localizedDescription : @"-"]];
            NSLog(@"[vcam-rec] finished %@ ok=%d frames=%llu", path, ok, n);
        }];
    } else {
        if (_writer && _writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
        [self writeStatus:@"idle" extra:@"last=- result=none frames=0 (no frames captured)"];
    }
    [self resetWriterState];
}

- (void)resetWriterState {
    _writer = nil; _input = nil; _adaptor = nil;
    _sessionStarted = NO; _finishing = NO; _outPath = nil;
    _lockW = _lockH = 0; _lockFmt = 0;
    _hasTarget = NO; _targetW = _targetH = 0; _targetFmt = 0;
    atomic_store(&_writerStatus, 0);
    atomic_store_explicit(&_locked, false, memory_order_relaxed);
}

#pragma mark - Status

- (void)writeStatus:(NSString *)state extra:(NSString *)extra {
    NSString *s = [NSString stringWithFormat:@"state=%@\n%@\n", state, extra ?: @""];
    [s writeToFile:kRecStatusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)statusReport {
    NSMutableString *s = [NSMutableString stringWithCapacity:256];
    [s appendString:@"\n--- recorder ---\n"];
    BOOL armed = atomic_load(&_armed);
    BOOL locked = atomic_load(&_locked);
    // Writer status: 0=unknown 1=writing 2=completed 3=failed 4=cancelled.
    static const char *ws[] = {"unknown","writing","completed","failed","cancelled"};
    int wst = atomic_load(&_writerStatus);
    [s appendFormat:@"armed=%d locked=%d target=%@ writer=%s", armed, locked,
        _hasTarget ? @"explicit" : @"auto-largest", (wst >= 0 && wst <= 4) ? ws[wst] : "?"];
    if (locked) {
        char fcc[5] = {0};
        fcc[0]=(_lockFmt>>24)&0xff; fcc[1]=(_lockFmt>>16)&0xff; fcc[2]=(_lockFmt>>8)&0xff; fcc[3]=_lockFmt&0xff;
        [s appendFormat:@" geom=%zux%zu '%s'", _lockW, _lockH, fcc];
    }
    // framesSeen = frames matching the locked geometry that reached us. If framesSeen keeps rising
    // while written stalls, the encoder (not the camera) is the bottleneck.
    [s appendFormat:@"\nseen=%llu written=%llu notReady=%llu appendFail=%llu dropInflight=%llu copyFail=%llu inflight=%d\n",
        atomic_load(&_framesSeen), atomic_load(&_framesWritten), atomic_load(&_framesNotReady),
        atomic_load(&_framesAppendFail), atomic_load(&_framesDroppedInflight),
        atomic_load(&_framesCopyFail), atomic_load(&_inflight)];
    if (_outPath) [s appendFormat:@"file=%@\n", _outPath.lastPathComponent];
    return s;
}

@end
