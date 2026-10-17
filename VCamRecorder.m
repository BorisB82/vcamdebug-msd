// See VCamRecorder.h. Hardware-HEVC recorder for the real camera frames at the emit hook.
//
// Encoder path: VTCompressionSession drives the dedicated HEVC hardware encoder directly (rather
// than letting AVAssetWriter own it — that stalled inside mediaserverd after ~12 frames, with the
// input stuck not-ready). The encoded CMSampleBuffers are muxed into a .mov by an AVAssetWriter in
// PASSTHROUGH mode (outputSettings:nil), which does no encoding and so has nothing to stall on.
//
// Threading: the emit thread does the cheapest possible work — an atomic gate, and when recording,
// a plane memcpy into a fresh IOSurface buffer plus a dispatch. Two serial queues follow:
//   _recQueue    — all VTCompressionSession calls (encode submit, flush, lifecycle).
//   _writerQueue — all AVAssetWriter calls (create input from the first encoded sample, append, finish).
// The VT output callback hops to _writerQueue, so finalize (dispatched to _writerQueue after the
// flush) always runs after every appended sample.

#import "VCamRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <notify.h>

static NSString *const kRecStatusFile  = @"/var/mobile/Media/DCIM/vcam_rec_status.txt";
static NSString *const kRecDir         = @"/var/mobile/Media/DCIM";
static NSString *const kRecConfigPlist = @"/var/mobile/Media/DCIM/vcam_msd.plist";

static NSString *const kNoteRecStart  = @"com.vcamplus.rec.start";
static NSString *const kNoteRecStop   = @"com.vcamplus.rec.stop";
static NSString *const kNoteRecToggle = @"com.vcamplus.rec.toggle";

#define VCAM_REC_PROBE_SEC    0.5
#define VCAM_REC_MAX_INFLIGHT 6
#define VCAM_REC_BPP          0.5
#define VCAM_REC_MIN_BITRATE  (20 * 1000 * 1000)
#define VCAM_REC_MAX_BITRATE  (120 * 1000 * 1000)

// Build an OSType from a 4-char fourcc string like "420v" (as printed in the geometry report).
static OSType vcam_fourccFromString(NSString *s) {
    if (s.length != 4) return 0;
    const char *c = s.UTF8String;
    return ((OSType)(uint8_t)c[0] << 24) | ((OSType)(uint8_t)c[1] << 16) |
           ((OSType)(uint8_t)c[2] << 8)  |  (OSType)(uint8_t)c[3];
}

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

static void vcam_compressionOutput(void *refcon, void *sourceFrameRefCon, OSStatus status,
                                   VTEncodeInfoFlags infoFlags, CMSampleBufferRef sb);

@interface VCamRecorder ()
- (void)handleEncoded:(CMSampleBufferRef)sb status:(OSStatus)status;
@end

@implementation VCamRecorder {
    dispatch_queue_t _recQueue;     // VTCompressionSession calls
    dispatch_queue_t _writerQueue;  // AVAssetWriter calls
    dispatch_queue_t _noteQueue;    // Darwin-note delivery
    int _noteTokens[3];

    _Atomic bool _armed;            // control gate, read on the emit hot path
    _Atomic bool _locked;           // geometry chosen; emit path may now copy+encode
    _Atomic bool _finishing;
    _Atomic uint64_t _gen;          // bumps each start/stop to invalidate stale probe callbacks
    _Atomic int _inflight;          // copied-but-not-submitted frames

    size_t _lockW, _lockH; OSType _lockFmt;                       // locked geometry
    BOOL _hasTarget; size_t _targetW, _targetH; OSType _targetFmt;// explicit target from plist

    os_unfair_lock _candLock;                                     // probe candidate (auto mode)
    uint64_t _candPixels; size_t _candW, _candH; OSType _candFmt;

    VTCompressionSessionRef _session;   // _recQueue
    AVAssetWriter *_writer;             // _writerQueue
    AVAssetWriterInput *_input;         // _writerQueue (passthrough)
    BOOL _writerSessionStarted;         // _writerQueue
    NSString *_outPath;                 // _recQueue (set), _writerQueue (read)
    CMTime _firstPTS, _lastPTS;         // _writerQueue
    _Atomic int _writerStatus;

    _Atomic uint64_t _framesSeen;           // matched the locked geometry
    _Atomic uint64_t _framesEncoded;        // submitted to VTCompressionSession
    _Atomic uint64_t _framesWritten;        // muxed into the file
    _Atomic uint64_t _encodeCbFail;         // encoder callback reported an error
    _Atomic uint64_t _muxNotReady;          // passthrough input not ready (should be ~0)
    _Atomic uint64_t _framesDroppedInflight, _framesCopyFail;
}

+ (instancetype)shared {
    static VCamRecorder *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamRecorder new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _recQueue    = dispatch_queue_create("com.vcamplus.msd.rec.encode", DISPATCH_QUEUE_SERIAL);
        _writerQueue = dispatch_queue_create("com.vcamplus.msd.rec.mux", DISPATCH_QUEUE_SERIAL);
        _noteQueue   = dispatch_queue_create("com.vcamplus.msd.rec.note", DISPATCH_QUEUE_SERIAL);
        _candLock    = OS_UNFAIR_LOCK_INIT;
        [self registerNotes];
        [self writeStatus:@"idle" extra:@"last=- result=none frames=0"];
        NSLog(@"[vcam-rec] ready (VTCompressionSession + passthrough mux)");
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
    if (atomic_exchange(&_armed, true)) return;
    uint64_t gen = atomic_fetch_add(&_gen, 1) + 1;
    atomic_store(&_finishing, false);
    [self writeStatus:@"arming" extra:@"preparing encoder…"];
    dispatch_async(_recQueue, ^{
        [self resetSessionState];
        atomic_store(&_framesSeen, 0);    atomic_store(&_framesEncoded, 0);
        atomic_store(&_framesWritten, 0); atomic_store(&_encodeCbFail, 0);
        atomic_store(&_muxNotReady, 0);   atomic_store(&_framesDroppedInflight, 0);
        atomic_store(&_framesCopyFail, 0);
        os_unfair_lock_lock(&_candLock);
        _candPixels = 0; _candW = _candH = 0; _candFmt = 0;
        os_unfair_lock_unlock(&_candLock);

        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kRecConfigPlist];
        long tw = [cfg[@"recW"] longValue], th = [cfg[@"recH"] longValue];
        OSType tf = vcam_fourccFromString([cfg[@"recFmt"] description]);
        if (tw > 0 && th > 0 && tf != 0) {
            _hasTarget = YES; _targetW = (size_t)tw; _targetH = (size_t)th; _targetFmt = tf;
            [self openSessionW:_targetW h:_targetH fmt:_targetFmt];
        } else {
            _hasTarget = NO;
            [self scheduleProbeForGen:gen];
        }
    });
}

- (void)stop {
    if (!atomic_exchange(&_armed, false)) return;
    atomic_fetch_add(&_gen, 1);
    atomic_store(&_finishing, true);
    [self writeStatus:@"finishing" extra:nil];
    dispatch_async(_recQueue, ^{ [self finishEncoding]; });
}

#pragma mark - Emit hot path

- (void)observeSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb || !atomic_load_explicit(&_armed, memory_order_relaxed)) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);

    if (!atomic_load_explicit(&_locked, memory_order_acquire)) {
        uint64_t px = (uint64_t)w * h;
        os_unfair_lock_lock(&_candLock);
        if (px > _candPixels) { _candPixels = px; _candW = w; _candH = h; _candFmt = fmt; }
        os_unfair_lock_unlock(&_candLock);
        return;
    }
    if (w != _lockW || h != _lockH || fmt != _lockFmt) return;
    atomic_fetch_add_explicit(&_framesSeen, 1, memory_order_relaxed);

    if (atomic_load_explicit(&_inflight, memory_order_relaxed) >= VCAM_REC_MAX_INFLIGHT) {
        atomic_fetch_add_explicit(&_framesDroppedInflight, 1, memory_order_relaxed);
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    CVPixelBufferRef copy = vcam_copyPixelBuffer(pb);
    if (!copy) { atomic_fetch_add_explicit(&_framesCopyFail, 1, memory_order_relaxed); return; }
    atomic_fetch_add_explicit(&_inflight, 1, memory_order_relaxed);
    dispatch_async(_recQueue, ^{ [self encodeCopy:copy pts:pts]; });
}

#pragma mark - _recQueue (encode)

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
    if (px == 0) {
        [self writeStatus:@"arming" extra:@"waiting for camera frames — open the Camera"];
        [self scheduleProbeForGen:gen];
        return;
    }
    [self openSessionW:w h:h fmt:fmt];
}

- (void)openSessionW:(size_t)w h:(size_t)h fmt:(OSType)fmt {
    double bitrate = (double)w * h * 30.0 * VCAM_REC_BPP;
    if (bitrate < VCAM_REC_MIN_BITRATE) bitrate = VCAM_REC_MIN_BITRATE;
    if (bitrate > VCAM_REC_MAX_BITRATE) bitrate = VCAM_REC_MAX_BITRATE;

    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h,
                                            kCMVideoCodecType_HEVC, NULL, NULL, NULL,
                                            vcam_compressionOutput, (__bridge void *)self, &_session);
    if (s != noErr || !_session) {
        NSLog(@"[vcam-rec] VTCompressionSessionCreate failed: %d", (int)s);
        [self writeStatus:@"error" extra:[NSString stringWithFormat:@"encoder create failed (%d)", (int)s]];
        _session = NULL;
        return;
    }
    int32_t br = (int32_t)bitrate, fps = 30;
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
    CFNumberRef nbr  = CFNumberCreate(NULL, kCFNumberIntType, &br);
    CFNumberRef nfps = CFNumberCreate(NULL, kCFNumberIntType, &fps);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, nbr);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, nfps);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, nfps);
    if (nbr) CFRelease(nbr);
    if (nfps) CFRelease(nfps);
    VTCompressionSessionPrepareToEncodeFrames(_session);

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    _outPath = [kRecDir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"vcam_rec_%@.mov", [df stringFromDate:NSDate.date]]];
    [NSFileManager.defaultManager removeItemAtPath:_outPath error:nil];

    // The AVAssetWriter + passthrough input are created lazily on the first encoded sample (we need
    // its format description). Just open the writer object here.
    NSError *err = nil;
    __block AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:_outPath]
                                                            fileType:AVFileTypeQuickTimeMovie error:&err];
    NSString *path = _outPath;
    dispatch_async(_writerQueue, ^{
        _writer = writer;
        _writerSessionStarted = NO;
        if (!_writer) {
            NSLog(@"[vcam-rec] writer create failed: %@", err);
            [self writeStatus:@"error" extra:err.localizedDescription ?: @"writer create failed"];
        }
        (void)path;
    });

    _lockW = w; _lockH = h; _lockFmt = fmt;
    atomic_store(&_writerStatus, 0);
    atomic_store_explicit(&_locked, true, memory_order_release);

    char fcc[5] = {0};
    fcc[0]=(fmt>>24)&0xff; fcc[1]=(fmt>>16)&0xff; fcc[2]=(fmt>>8)&0xff; fcc[3]=fmt&0xff;
    [self writeStatus:@"recording"
                extra:[NSString stringWithFormat:@"%zux%zu '%s' hevc %.0fMbps file=%@",
                       w, h, fcc, bitrate / 1e6, _outPath.lastPathComponent]];
    NSLog(@"[vcam-rec] recording %zux%zu '%s' %.0fMbps -> %@", w, h, fcc, bitrate/1e6, _outPath);
}

- (void)encodeCopy:(CVPixelBufferRef)copy pts:(CMTime)pts {
    if (atomic_load(&_finishing) || !_session) {
        CFRelease(copy); atomic_fetch_sub(&_inflight, 1); return;
    }
    OSStatus s = VTCompressionSessionEncodeFrame(_session, copy, pts, kCMTimeInvalid, NULL, NULL, NULL);
    if (s == noErr) atomic_fetch_add_explicit(&_framesEncoded, 1, memory_order_relaxed);
    else            atomic_fetch_add_explicit(&_encodeCbFail, 1, memory_order_relaxed);
    CFRelease(copy);                     // VT retains the buffer internally while encoding
    atomic_fetch_sub_explicit(&_inflight, 1, memory_order_relaxed);
}

// Called by VideoToolbox (possibly on its own thread) for each encoded frame. Hop to _writerQueue.
- (void)handleEncoded:(CMSampleBufferRef)sb status:(OSStatus)status {
    if (status != noErr || !sb) {
        atomic_fetch_add_explicit(&_encodeCbFail, 1, memory_order_relaxed);
        return;
    }
    CFRetain(sb);
    dispatch_async(_writerQueue, ^{ [self muxEncoded:sb]; CFRelease(sb); });
}

#pragma mark - _writerQueue (mux)

- (void)muxEncoded:(CMSampleBufferRef)sb {
    if (!_writer || _writer.status == AVAssetWriterStatusFailed ||
        _writer.status == AVAssetWriterStatusCompleted || _writer.status == AVAssetWriterStatusCancelled) {
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);

    if (!_input) {   // first encoded sample: build the passthrough input from its format description
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
        _input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                    outputSettings:nil   // passthrough — no encoding
                                                 sourceFormatHint:fmtDesc];
        _input.expectsMediaDataInRealTime = YES;
        if (![_writer canAddInput:_input]) {
            [self writeStatus:@"error" extra:@"mux rejected the encoded format"];
            _input = nil;
            return;
        }
        [_writer addInput:_input];
        [_writer startWriting];
        [_writer startSessionAtSourceTime:pts];
        _writerSessionStarted = YES;
        _firstPTS = pts; _lastPTS = pts;
    }

    if (_writer.status == AVAssetWriterStatusWriting && _input.isReadyForMoreMediaData) {
        if ([_input appendSampleBuffer:sb]) {
            atomic_fetch_add_explicit(&_framesWritten, 1, memory_order_relaxed);
            _lastPTS = pts;
        }
    } else {
        atomic_fetch_add_explicit(&_muxNotReady, 1, memory_order_relaxed);
    }
    atomic_store(&_writerStatus, (int)_writer.status);
}

#pragma mark - finish

- (void)finishEncoding {
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);   // flush → callbacks → mux
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    atomic_store_explicit(&_locked, false, memory_order_relaxed);
    // Runs after every flushed sample has been appended (FIFO on _writerQueue).
    dispatch_async(_writerQueue, ^{ [self finalizeWriter]; });
}

- (void)finalizeWriter {
    if (_writer && _writerSessionStarted && _writer.status == AVAssetWriterStatusWriting) {
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
        [self writeStatus:@"idle" extra:@"last=- result=none frames=0 (no frames encoded)"];
    }
    _writer = nil; _input = nil; _writerSessionStarted = NO; _outPath = nil;
}

- (void)resetSessionState {
    if (_session) { VTCompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
    _lockW = _lockH = 0; _lockFmt = 0;
    _hasTarget = NO; _targetW = _targetH = 0; _targetFmt = 0;
    atomic_store(&_writerStatus, 0);
    atomic_store_explicit(&_locked, false, memory_order_relaxed);
    dispatch_async(_writerQueue, ^{ _writer = nil; _input = nil; _writerSessionStarted = NO; });
}

#pragma mark - Status

- (void)writeStatus:(NSString *)state extra:(NSString *)extra {
    NSString *s = [NSString stringWithFormat:@"state=%@\n%@\n", state, extra ?: @""];
    [s writeToFile:kRecStatusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)statusReport {
    NSMutableString *s = [NSMutableString stringWithCapacity:256];
    [s appendString:@"\n--- recorder (VTCompressionSession) ---\n"];
    static const char *ws[] = {"unknown","writing","completed","failed","cancelled"};
    int wst = atomic_load(&_writerStatus);
    [s appendFormat:@"armed=%d locked=%d target=%@ mux=%s", atomic_load(&_armed), atomic_load(&_locked),
        _hasTarget ? @"explicit" : @"auto-largest", (wst >= 0 && wst <= 4) ? ws[wst] : "?"];
    if (atomic_load(&_locked)) {
        char fcc[5] = {0};
        fcc[0]=(_lockFmt>>24)&0xff; fcc[1]=(_lockFmt>>16)&0xff; fcc[2]=(_lockFmt>>8)&0xff; fcc[3]=_lockFmt&0xff;
        [s appendFormat:@" geom=%zux%zu '%s'", _lockW, _lockH, fcc];
    }
    // seen = frames of the locked geometry; encoded = submitted to the HW encoder; written = muxed.
    [s appendFormat:@"\nseen=%llu encoded=%llu written=%llu encFail=%llu muxNotReady=%llu dropInflight=%llu copyFail=%llu inflight=%d\n",
        atomic_load(&_framesSeen), atomic_load(&_framesEncoded), atomic_load(&_framesWritten),
        atomic_load(&_encodeCbFail), atomic_load(&_muxNotReady), atomic_load(&_framesDroppedInflight),
        atomic_load(&_framesCopyFail), atomic_load(&_inflight)];
    if (_outPath) [s appendFormat:@"file=%@\n", _outPath.lastPathComponent];
    return s;
}

@end

static void vcam_compressionOutput(void *refcon, void *sourceFrameRefCon, OSStatus status,
                                   VTEncodeInfoFlags infoFlags, CMSampleBufferRef sb) {
    @autoreleasepool {
        [(__bridge VCamRecorder *)refcon handleEncoded:sb status:status];
    }
}
