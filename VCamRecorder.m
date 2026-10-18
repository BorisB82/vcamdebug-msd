// See VCamRecorder.h. Hardware-HEVC recorder for the real camera frames at the emit hook.
//
// Encoder path: VTCompressionSession drives the dedicated HEVC hardware encoder directly (rather
// than letting AVAssetWriter own it — that stalled inside mediaserverd). Encoded CMSampleBuffers
// are muxed into a .mov by an AVAssetWriter in PASSTHROUGH mode (no encoder → nothing to stall).
//
// Capture strategy: apps switch surfaces mid-session (a 540 preview, then a snapshot at another
// size), so locking onto one geometry loses the feed on a switch. Instead we FOLLOW the active
// feed: an evaluator picks whichever geometry is currently streaming, records it, and when the
// active resolution changes it finalizes the current clip and opens a new one (a .mov track can't
// change size mid-stream). Geometries that produce no encoder output (e.g. the 2304 internal
// buffer, or BGRA) are blacklisted for the session so we move on instead of recording nothing.
// An explicit recW/recH/recFmt in the config plist overrides this with a single locked geometry.
//
// Threading: the emit thread does an atomic gate + (on a match) a plane memcpy and a dispatch.
//   _recQueue    — VTCompressionSession + the active-feed evaluator (encode-side state).
//   _writerQueue — AVAssetWriter per-clip state (create, append, finish). All _w* ivars live here.
// Clips are strictly sequential (close flushes before the next opens), so the two queues' blocks
// stay FIFO-ordered and never touch the same clip concurrently.

#import "VCamRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <notify.h>

static NSString *const kRecStatusFile  = @"/var/mobile/Media/DCIM/vcam_rec_status.txt";
static NSString *const kRecDir         = @"/var/mobile/Media/DCIM/VCamRec";
static NSString *const kRecTimeline    = @"/var/mobile/Media/DCIM/VCamRec/vcam_rec_timeline.txt";
static NSString *const kRecConfigPlist = @"/var/mobile/Media/DCIM/vcam_msd.plist";

static NSString *const kNoteRecStart  = @"com.vcamplus.rec.start";
static NSString *const kNoteRecStop   = @"com.vcamplus.rec.stop";
static NSString *const kNoteRecToggle = @"com.vcamplus.rec.toggle";

#define VCAM_REC_MAX_INFLIGHT 6
#define VCAM_REC_BPP          0.5
#define VCAM_REC_MIN_BITRATE  (20 * 1000 * 1000)
#define VCAM_REC_MAX_BITRATE  (120 * 1000 * 1000)

#define VCAM_EVAL_SEC         0.25     // active-feed evaluator interval
#define VCAM_QUIET_SEC        0.40     // active feed silent this long → eligible to switch
#define VCAM_IDLE_SEC         1.50     // active feed silent this long → close the clip
#define VCAM_MIN_AREA         100000   // ignore tiny thumbnail/face buffers (<~316²)
#define VCAM_FAIL_SEEN        15       // frames seen with zero output → geometry unencodable
#define VCAM_FAIL_SEC         1.00
#define VCAM_BLACKLIST_MAX    16

static inline uint64_t vcam_key(size_t w, size_t h, OSType fmt) {
    return ((uint64_t)(w & 0xFFFF) << 48) | ((uint64_t)(h & 0xFFFF) << 32) | (uint64_t)fmt;
}
static inline void vcam_unkey(uint64_t k, size_t *w, size_t *h, OSType *fmt) {
    if (w) *w = (size_t)((k >> 48) & 0xFFFF);
    if (h) *h = (size_t)((k >> 32) & 0xFFFF);
    if (fmt) *fmt = (OSType)(k & 0xFFFFFFFF);
}
static OSType vcam_fourccFromString(NSString *s) {
    if (s.length != 4) return 0;
    const char *c = s.UTF8String;
    return ((OSType)(uint8_t)c[0] << 24) | ((OSType)(uint8_t)c[1] << 16) |
           ((OSType)(uint8_t)c[2] << 8)  |  (OSType)(uint8_t)c[3];
}
static void vcam_fccStr(OSType fmt, char out[5]) {
    out[0]=(fmt>>24)&0xff; out[1]=(fmt>>16)&0xff; out[2]=(fmt>>8)&0xff; out[3]=fmt&0xff; out[4]=0;
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
    dispatch_queue_t _recQueue;     // VTCompressionSession + evaluator
    dispatch_queue_t _writerQueue;  // AVAssetWriter per-clip
    dispatch_queue_t _noteQueue;    // Darwin-note delivery
    int _noteTokens[3];

    _Atomic bool _armed;            // control gate, read on the emit hot path
    _Atomic bool _finishing;
    _Atomic uint64_t _gen;          // bumps each start/stop to invalidate stale evaluator ticks
    _Atomic int _inflight;          // copied-but-not-submitted frames

    _Atomic uint64_t _activeKey;    // the geometry the emit path should copy+encode (0 = none)
    _Atomic double _lastMatchTime;  // uptime of the last active-feed frame
    _Atomic uint64_t _candKey;      // most recent non-active, big-enough geometry seen
    _Atomic double _candTime;
    _Atomic uint64_t _clipSeen;     // active-feed frames matched for the current clip

    // Encode-side (_recQueue only).
    BOOL _followMode;
    VTCompressionSessionRef _session;
    uint64_t _curKey; size_t _curW, _curH; OSType _curFmt;
    int _clipIndex;
    double _clipOpenTime;
    NSString *_sessionTs;
    uint64_t _blacklist[VCAM_BLACKLIST_MAX]; int _blacklistN;

    // Writer-side (_writerQueue only).
    AVAssetWriter *_wWriter;
    AVAssetWriterInput *_wInput;
    BOOL _wStarted;
    NSString *_wPath;
    int _wIndex;
    CMTime _wFirst, _wLast;
    _Atomic uint64_t _wWritten;     // atomic so the evaluator can read it for fail-detection

    // Global counters (status dump).
    _Atomic uint64_t _framesSeen, _framesEncoded, _framesWritten, _encodeCbFail;
    _Atomic uint64_t _framesDroppedInflight, _framesCopyFail;
    _Atomic int _writerStatus;
    _Atomic int _clipsDone;
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
        [self registerNotes];
        [self writeStatus:@"idle" extra:@"last=- clips=0"];
        NSLog(@"[vcam-rec] ready (follow-active + VTCompressionSession)");
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
    atomic_store(&_activeKey, 0);
    atomic_store(&_candKey, 0);
    [self writeStatus:@"arming" extra:@"waiting for the active feed…"];
    dispatch_async(_recQueue, ^{
        atomic_store(&_framesSeen, 0);   atomic_store(&_framesEncoded, 0);
        atomic_store(&_framesWritten, 0);atomic_store(&_encodeCbFail, 0);
        atomic_store(&_framesDroppedInflight, 0); atomic_store(&_framesCopyFail, 0);
        atomic_store(&_clipsDone, 0);
        _blacklistN = 0; _clipIndex = 0; _curKey = 0;
        [NSFileManager.defaultManager createDirectoryAtPath:kRecDir
                                withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd_HHmmss";
        _sessionTs = [df stringFromDate:NSDate.date];

        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kRecConfigPlist];
        long tw = [cfg[@"recW"] longValue], th = [cfg[@"recH"] longValue];
        OSType tf = vcam_fourccFromString([cfg[@"recFmt"] description]);
        if (tw > 0 && th > 0 && tf != 0) {
            _followMode = NO;                       // explicit single-geometry override
            [self openClipForKey:vcam_key((size_t)tw, (size_t)th, tf)];
        } else {
            _followMode = YES;
            [self scheduleEvalForGen:gen];
        }
    });
}

- (void)stop {
    if (!atomic_exchange(&_armed, false)) return;
    atomic_fetch_add(&_gen, 1);
    atomic_store(&_finishing, true);
    atomic_store(&_activeKey, 0);
    [self writeStatus:@"finishing" extra:nil];
    dispatch_async(_recQueue, ^{ [self closeCurrentClip]; [self writeFinalStatus]; });
}

#pragma mark - Emit hot path

- (void)observeSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb || !atomic_load_explicit(&_armed, memory_order_relaxed)) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    uint64_t key = vcam_key(w, h, fmt);

    if (key == atomic_load_explicit(&_activeKey, memory_order_acquire)) {
        atomic_store_explicit(&_lastMatchTime, NSProcessInfo.processInfo.systemUptime, memory_order_relaxed);
        atomic_fetch_add_explicit(&_framesSeen, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&_clipSeen, 1, memory_order_relaxed);
        if (atomic_load_explicit(&_inflight, memory_order_relaxed) >= VCAM_REC_MAX_INFLIGHT) {
            atomic_fetch_add_explicit(&_framesDroppedInflight, 1, memory_order_relaxed);
            return;
        }
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        CVPixelBufferRef copy = vcam_copyPixelBuffer(pb);
        if (!copy) { atomic_fetch_add_explicit(&_framesCopyFail, 1, memory_order_relaxed); return; }
        atomic_fetch_add_explicit(&_inflight, 1, memory_order_relaxed);
        dispatch_async(_recQueue, ^{ [self encodeCopy:copy pts:pts]; });
        return;
    }
    // Not the active feed: in follow mode, remember it as a switch candidate (ignore thumbnails).
    if (atomic_load_explicit(&_finishing, memory_order_relaxed)) return;
    if ((uint64_t)w * h < VCAM_MIN_AREA) return;
    atomic_store_explicit(&_candKey, key, memory_order_relaxed);
    atomic_store_explicit(&_candTime, NSProcessInfo.processInfo.systemUptime, memory_order_relaxed);
}

#pragma mark - _recQueue: active-feed evaluator

- (void)scheduleEvalForGen:(uint64_t)gen {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VCAM_EVAL_SEC * NSEC_PER_SEC)),
                   _recQueue, ^{ [self evalForGen:gen]; });
}

- (void)evalForGen:(uint64_t)gen {
    if (!atomic_load(&_armed) || atomic_load(&_gen) != gen || !_followMode) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    double lastMatch = atomic_load(&_lastMatchTime);
    uint64_t cand = atomic_load(&_candKey);
    double candTime = atomic_load(&_candTime);

    if (_curKey != 0) {
        uint64_t seen = atomic_load(&_clipSeen);
        uint64_t written = atomic_load(&_wWritten);
        if (now - _clipOpenTime > VCAM_FAIL_SEC && seen >= VCAM_FAIL_SEEN && written == 0) {
            [self blacklist:_curKey];               // geometry won't encode (e.g. 2304 / BGRA)
            [self closeCurrentClip];
        } else if (now - lastMatch > VCAM_IDLE_SEC) {
            [self closeCurrentClip];                // feed went idle — save what we have
        } else if (cand && cand != _curKey && (now - candTime) < 0.5 &&
                   (now - lastMatch) > VCAM_QUIET_SEC && ![self isBlacklisted:cand]) {
            [self closeCurrentClip];                // a different feed took over → split
            [self openClipForKey:cand];
        }
    } else if (cand && (now - candTime) < 0.5 && ![self isBlacklisted:cand]) {
        [self openClipForKey:cand];
    }
    [self scheduleEvalForGen:gen];
}

- (void)blacklist:(uint64_t)key {
    if (_blacklistN < VCAM_BLACKLIST_MAX) _blacklist[_blacklistN++] = key;
    char fcc[5]; size_t w,h; OSType f; vcam_unkey(key,&w,&h,&f); vcam_fccStr(f,fcc);
    NSLog(@"[vcam-rec] blacklisted %zux%zu '%s' (no encoder output)", w, h, fcc);
}
- (BOOL)isBlacklisted:(uint64_t)key {
    for (int i = 0; i < _blacklistN; i++) if (_blacklist[i] == key) return YES;
    return NO;
}

#pragma mark - _recQueue: clip lifecycle (encode side)

- (void)openClipForKey:(uint64_t)key {
    size_t w, h; OSType fmt; vcam_unkey(key, &w, &h, &fmt);
    double bitrate = (double)w * h * 30.0 * VCAM_REC_BPP;
    if (bitrate < VCAM_REC_MIN_BITRATE) bitrate = VCAM_REC_MIN_BITRATE;
    if (bitrate > VCAM_REC_MAX_BITRATE) bitrate = VCAM_REC_MAX_BITRATE;

    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h,
                                            kCMVideoCodecType_HEVC, NULL, NULL, NULL,
                                            vcam_compressionOutput, (__bridge void *)self, &_session);
    if (s != noErr || !_session) {
        NSLog(@"[vcam-rec] VTCompressionSessionCreate failed %d for %zux%zu", (int)s, w, h);
        [self blacklist:key];
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

    _curKey = key; _curW = w; _curH = h; _curFmt = fmt;
    _clipIndex += 1;
    _clipOpenTime = NSProcessInfo.processInfo.systemUptime;
    atomic_store(&_clipSeen, 0);
    atomic_store(&_lastMatchTime, _clipOpenTime);

    char fcc[5]; vcam_fccStr(fmt, fcc);
    NSString *path = [kRecDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vcam_%@_%02d_%zux%zu_%s.mov", _sessionTs, _clipIndex, w, h, fcc]];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    int idx = _clipIndex;
    dispatch_async(_writerQueue, ^{ [self openWriterAtPath:path index:idx]; });

    atomic_store_explicit(&_activeKey, key, memory_order_release);   // emit may now encode this feed
    [self writeStatus:@"recording"
                extra:[NSString stringWithFormat:@"clip %d: %zux%zu '%s' hevc %.0fMbps",
                       _clipIndex, w, h, fcc, bitrate / 1e6]];
    NSLog(@"[vcam-rec] clip %d recording %zux%zu '%s' %.0fMbps", _clipIndex, w, h, fcc, bitrate/1e6);
}

- (void)encodeCopy:(CVPixelBufferRef)copy pts:(CMTime)pts {
    if (atomic_load(&_finishing) || !_session) {
        CFRelease(copy); atomic_fetch_sub(&_inflight, 1); return;
    }
    OSStatus s = VTCompressionSessionEncodeFrame(_session, copy, pts, kCMTimeInvalid, NULL, NULL, NULL);
    if (s == noErr) atomic_fetch_add_explicit(&_framesEncoded, 1, memory_order_relaxed);
    else            atomic_fetch_add_explicit(&_encodeCbFail, 1, memory_order_relaxed);
    CFRelease(copy);
    atomic_fetch_sub_explicit(&_inflight, 1, memory_order_relaxed);
}

// Flush the current clip's encoder and queue its finalize on the writer queue. Encode-side only.
- (void)closeCurrentClip {
    atomic_store_explicit(&_activeKey, 0, memory_order_release);   // stop emit from feeding this clip
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);  // flush → callbacks → mux
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _curKey = 0;
    dispatch_async(_writerQueue, ^{ [self finalizeWriter]; });     // after this clip's muxed frames
}

- (void)handleEncoded:(CMSampleBufferRef)sb status:(OSStatus)status {
    if (status != noErr || !sb) {
        atomic_fetch_add_explicit(&_encodeCbFail, 1, memory_order_relaxed);
        return;
    }
    CFRetain(sb);
    dispatch_async(_writerQueue, ^{ [self muxEncoded:sb]; CFRelease(sb); });
}

#pragma mark - _writerQueue: per-clip AVAssetWriter

- (void)openWriterAtPath:(NSString *)path index:(int)index {
    NSError *err = nil;
    _wWriter = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path]
                                        fileType:AVFileTypeQuickTimeMovie error:&err];
    _wInput = nil; _wStarted = NO; _wPath = path; _wIndex = index;
    _wFirst = kCMTimeInvalid; _wLast = kCMTimeInvalid;
    atomic_store(&_wWritten, 0);
    if (!_wWriter) NSLog(@"[vcam-rec] writer create failed: %@", err);
}

- (void)muxEncoded:(CMSampleBufferRef)sb {
    AVAssetWriter *writer = _wWriter;
    if (!writer || writer.status == AVAssetWriterStatusFailed ||
        writer.status == AVAssetWriterStatusCompleted || writer.status == AVAssetWriterStatusCancelled) {
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (!_wInput) {
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
        _wInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                     outputSettings:nil sourceFormatHint:fmtDesc];
        _wInput.expectsMediaDataInRealTime = YES;
        if (![writer canAddInput:_wInput]) { _wInput = nil; return; }
        [writer addInput:_wInput];
        [writer startWriting];
        [writer startSessionAtSourceTime:pts];
        _wStarted = YES; _wFirst = pts; _wLast = pts;
    }
    if (writer.status == AVAssetWriterStatusWriting && _wInput.isReadyForMoreMediaData) {
        if ([_wInput appendSampleBuffer:sb]) {
            atomic_fetch_add_explicit(&_framesWritten, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&_wWritten, 1, memory_order_relaxed);
            _wLast = pts;
        }
    }
    atomic_store(&_writerStatus, (int)writer.status);
}

- (void)finalizeWriter {
    AVAssetWriter *w = _wWriter; AVAssetWriterInput *in = _wInput;
    NSString *path = _wPath; int index = _wIndex;
    uint64_t n = atomic_load(&_wWritten);
    double secs = (CMTIME_IS_VALID(_wLast) && CMTIME_IS_VALID(_wFirst))
        ? CMTimeGetSeconds(CMTimeSubtract(_wLast, _wFirst)) : 0.0;
    _wWriter = nil; _wInput = nil; _wStarted = NO; _wPath = nil;

    if (w && in && n > 0 && w.status == AVAssetWriterStatusWriting) {
        [in markAsFinished];
        [w finishWritingWithCompletionHandler:^{
            BOOL ok = (w.status == AVAssetWriterStatusCompleted);
            if (ok) atomic_fetch_add(&_clipsDone, 1);
            [self appendTimeline:[NSString stringWithFormat:@"clip %02d  %@  frames=%llu  dur=%.1fs  %@",
                                  index, path.lastPathComponent ?: @"-", n, secs, ok ? @"ok" : @"FAILED"]];
            NSLog(@"[vcam-rec] clip %d finished ok=%d frames=%llu", index, ok, n);
        }];
    } else {
        if (w && w.status == AVAssetWriterStatusWriting) [w cancelWriting];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];   // empty clip — drop the file
    }
}

#pragma mark - Status

- (void)writeStatus:(NSString *)state extra:(NSString *)extra {
    NSString *s = [NSString stringWithFormat:@"state=%@\n%@\n", state, extra ?: @""];
    [s writeToFile:kRecStatusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)writeFinalStatus {
    [self writeStatus:@"idle" extra:[NSString stringWithFormat:@"last session=%@ clips=%d",
                                     _sessionTs ?: @"-", atomic_load(&_clipsDone)]];
}

- (void)appendTimeline:(NSString *)line {
    NSString *entry = [NSString stringWithFormat:@"%@  %@\n",
                       [NSDateFormatter localizedStringFromDate:NSDate.date
                             dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kRecTimeline];
    if (!fh) { [entry writeToFile:kRecTimeline atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; }
    @finally { [fh closeFile]; }
}

- (NSString *)statusReport {
    NSMutableString *s = [NSMutableString stringWithCapacity:256];
    [s appendString:@"\n--- recorder (follow-active / VTCompressionSession) ---\n"];
    static const char *ws[] = {"unknown","writing","completed","failed","cancelled"};
    int wst = atomic_load(&_writerStatus);
    uint64_t active = atomic_load(&_activeKey);
    [s appendFormat:@"armed=%d mode=%@ mux=%s clipsDone=%d", atomic_load(&_armed),
        _followMode ? @"follow" : @"explicit", (wst >= 0 && wst <= 4) ? ws[wst] : "?",
        atomic_load(&_clipsDone)];
    if (active) {
        size_t w,h; OSType f; char fcc[5]; vcam_unkey(active,&w,&h,&f); vcam_fccStr(f,fcc);
        [s appendFormat:@" active=%zux%zu '%s' clip#%d", w, h, fcc, _clipIndex];
    }
    [s appendFormat:@"\nseen=%llu encoded=%llu written=%llu encFail=%llu dropInflight=%llu copyFail=%llu inflight=%d blacklisted=%d\n",
        atomic_load(&_framesSeen), atomic_load(&_framesEncoded), atomic_load(&_framesWritten),
        atomic_load(&_encodeCbFail), atomic_load(&_framesDroppedInflight),
        atomic_load(&_framesCopyFail), atomic_load(&_inflight), _blacklistN];
    return s;
}

@end

static void vcam_compressionOutput(void *refcon, void *sourceFrameRefCon, OSStatus status,
                                   VTEncodeInfoFlags infoFlags, CMSampleBufferRef sb) {
    @autoreleasepool {
        [(__bridge VCamRecorder *)refcon handleEncoded:sb status:status];
    }
}
