// Singleton coordinator. Enabled only when /var/mobile/Media/DCIM/vcam.mp4 and vcam_msd_active both
// exist (stat cached ~500ms); starts/stops LocalVideoPlayer accordingly. replaceInPlace: validates
// the destination CVPixelBuffer (video media type, non-lossy format), fetches the latest decoded
// source frame, and delegates scale/format conversion to GPUImageProcessor. Maintains atomic
// hit/latency counters written to a stats file every 5s.

#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "NDIShmSource.h"
#import "VCamFrameSource.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>
#import <stdatomic.h>
#import <notify.h>

static NSString *const kVCamDefaultVideo = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kVCamConfigPlist  = @"/var/mobile/Media/DCIM/vcam_msd.plist";
static NSString *const kVCamStatsFile    = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";

// Darwin notification names. Payload-less: post from any process (control app, CC toggle,
// Activator, or `notifyutil -p <name>`) to drive the mediaserverd-side gate. The source path
// travels out-of-band in kVCamConfigPlist and is re-read on the .reload note.
static NSString *const kVCamNoteEnable  = @"com.vcamplus.msd.enable";
static NSString *const kVCamNoteDisable = @"com.vcamplus.msd.disable";
static NSString *const kVCamNoteToggle  = @"com.vcamplus.msd.toggle";
static NSString *const kVCamNoteReload  = @"com.vcamplus.msd.reload";

static inline BOOL vcam_isLossyDestination(OSType fmt) {
    switch (fmt) {
        case 0x2D387630:
        case 0x2D386630:
        case 0x2D787630:
        case 0x2D786630:
        case 0x2D343230:
            return YES;
        default:
            return NO;
    }
}

@interface VCamCore ()
@property (nonatomic, strong, readwrite) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong, readwrite) GPUImageProcessor *gpuProcessor;
@end

@implementation VCamCore {
    _Atomic bool _enabled;          // driven by Darwin notifications, read on the emit hot path
    BOOL _playerStarted;
    NSString *_sourcePath;          // current mp4 source; swappable at runtime via .reload
    BOOL _ndiMode;                  // YES = pull frames from NDIShmSource, NO = mp4 player
    NDIShmSource *_ndiSource;
    __weak id<VCamFrameSource> _activeSource;  // -> _videoPlayer or _ndiSource
    dispatch_queue_t _ctrlQueue;    // serializes enable/disable/reload handling
    int _noteTokens[4];
    mach_timebase_info_data_t _tb;

    _Atomic uint64_t _hitTotal;
    _Atomic uint64_t _hitNonVideo;
    _Atomic uint64_t _hitNoPB;
    _Atomic uint64_t _hitLossyDst;
    _Atomic uint64_t _hitNoSrc;
    _Atomic uint64_t _hitAlreadyConsumed;
    _Atomic uint64_t _hitVTAttempt;
    _Atomic uint64_t _hitVTSuccess;
    _Atomic uint64_t _hitVTFail;
    _Atomic uint32_t _lastDstFmt;
    _Atomic uint32_t _lastDstW;
    _Atomic uint32_t _lastDstH;

    _Atomic uint64_t _lastConsumedSrcID;

    // For per-interval rate reporting in dumpStats.
    double _lastDumpUptime;
    uint64_t _lastHitSnap;
    uint64_t _lastRebuildSnap;

    dispatch_source_t _statsTimer;

    // Off-emit-thread GPU render pump: pulls new source frames and renders them so the emit
    // path only has to copy. Keeps the ~GPU-time render off mediaserverd's emit thread.
    dispatch_queue_t _renderQueue;
    dispatch_source_t _renderTimer;
    uint64_t _lastRenderedID;
}

+ (instancetype)shared {
    static VCamCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&_tb);
        _gpuProcessor = [GPUImageProcessor new];
        _sourcePath   = [[self configuredSourcePath] copy];
        _videoPlayer  = [[LocalVideoPlayer alloc] initWithPath:_sourcePath];
        _ndiSource    = [NDIShmSource new];
        _ndiMode      = [self configuredNDIMode];
        _activeSource = _ndiMode ? (id<VCamFrameSource>)_ndiSource : (id<VCamFrameSource>)_videoPlayer;
        _ctrlQueue    = dispatch_queue_create("com.vcamplus.msd.control", DISPATCH_QUEUE_SERIAL);

        [self registerControlNotifications];

        dispatch_queue_t q = dispatch_queue_create("com.vcamplus.msd.stats", DISPATCH_QUEUE_SERIAL);
        _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(_statsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_statsTimer, ^{
            @autoreleasepool { [weakSelf dumpStats]; }
        });
        dispatch_resume(_statsTimer);

        // Render pump @ ~60 Hz: renders new source frames off the emit thread.
        _renderQueue = dispatch_queue_create("com.vcamplus.msd.render", DISPATCH_QUEUE_SERIAL);
        _renderTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _renderQueue);
        dispatch_source_set_timer(_renderTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(NSEC_PER_SEC / 60), 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(_renderTimer, ^{
            @autoreleasepool { [weakSelf renderTick]; }
        });
        dispatch_resume(_renderTimer);
    }
    return self;
}

// Runs on _renderQueue (NOT the emit thread). When enabled, grab the latest source frame and
// GPU-render it into the ready buffers the emit path copies from.
- (void)renderTick {
    if (!atomic_load_explicit(&_enabled, memory_order_relaxed)) return;
    id<VCamFrameSource> source = _activeSource;
    if (!source) return;
    uint64_t srcID = [source latestFrameID];
    if (srcID == 0 || srcID == _lastRenderedID) return;
    CVPixelBufferRef src = [source latestFrameRetained];
    if (!src) return;
    [_gpuProcessor renderSource:src srcID:srcID];
    CFRelease(src);
    _lastRenderedID = srcID;
}

// Reads the configured source path from kVCamConfigPlist ({"source": "/path/to/clip.mp4"}),
// falling back to the legacy fixed path. Container is read by content, so any extension works.
- (NSString *)configuredSourcePath {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kVCamConfigPlist];
    NSString *p = [cfg[@"source"] isKindOfClass:NSString.class] ? cfg[@"source"] : nil;
    if (p.length && [NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    return kVCamDefaultVideo;
}

- (void)registerControlNotifications {
    NSArray<NSString *> *names = @[kVCamNoteEnable, kVCamNoteDisable, kVCamNoteToggle, kVCamNoteReload];
    __weak typeof(self) weakSelf = self;
    [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        notify_register_dispatch(name.UTF8String, &self->_noteTokens[i], self->_ctrlQueue, ^(int token) {
            typeof(self) s = weakSelf; if (!s) return;
            if      ([name isEqualToString:kVCamNoteEnable])  [s applyEnabled:YES];
            else if ([name isEqualToString:kVCamNoteDisable]) [s applyEnabled:NO];
            else if ([name isEqualToString:kVCamNoteToggle])  [s applyEnabled:!atomic_load(&s->_enabled)];
            else if ([name isEqualToString:kVCamNoteReload])  [s reloadSource];
        });
    }];
    NSLog(@"[vcam-msd] control notifications registered (enable/disable/toggle/reload)");
}

// Reads the frame-source mode from kVCamConfigPlist ({"mode": "ndi"} vs file/absent).
- (BOOL)configuredNDIMode {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kVCamConfigPlist];
    NSString *m = [cfg[@"mode"] isKindOfClass:NSString.class] ? cfg[@"mode"] : nil;
    return [m caseInsensitiveCompare:@"ndi"] == NSOrderedSame;
}

// Runs on _ctrlQueue. Sets the gate and reconciles the active source to match.
- (void)applyEnabled:(BOOL)on {
    atomic_store(&_enabled, on);
    [self reconfigure];
    NSLog(@"[vcam-msd] enabled=%d mode=%@ source=%@", on, _ndiMode ? @"ndi" : @"file", _sourcePath);
}

// Runs on _ctrlQueue. Re-reads mode + mp4 path and reconciles.
- (void)reloadSource { [self reconfigure]; }

// Runs on _ctrlQueue. Picks the source for the current mode, swaps it in if changed, and
// starts/stops it to match the enabled gate.
- (void)reconfigure {
    // Rotation (degrees clockwise) from the shared plist, applied in the GPU transfer.
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kVCamConfigPlist];
    [_gpuProcessor setRotationDegrees:[cfg[@"rotation"] intValue]];

    BOOL ndi = [self configuredNDIMode];
    _ndiMode = ndi;
    id<VCamFrameSource> desired = ndi ? (id<VCamFrameSource>)_ndiSource
                                      : (id<VCamFrameSource>)_videoPlayer;

    if (!ndi) {  // keep the mp4 player's path current
        NSString *next = [self configuredSourcePath];
        if (![next isEqualToString:_sourcePath]) {
            _sourcePath = [next copy];
            [_videoPlayer setPath:_sourcePath];
        }
    }

    if (_activeSource != desired) {             // mode changed: stop the old source
        [_activeSource stop];
        _playerStarted = NO;
        _activeSource = desired;
    }

    BOOL on = atomic_load(&_enabled);
    if (on && !_playerStarted)      { [_activeSource start]; _playerStarted = YES; }
    else if (!on && _playerStarted) { [_activeSource stop];  _playerStarted = NO; }
}

- (void)dumpStats {
    uint32_t fmt = atomic_load(&_lastDstFmt);
    uint32_t w   = atomic_load(&_lastDstW);
    uint32_t h   = atomic_load(&_lastDstH);
    char fcc[5] = {0};
    fcc[0] = (fmt >> 24) & 0xff; fcc[1] = (fmt >> 16) & 0xff;
    fcc[2] = (fmt >> 8) & 0xff;  fcc[3] = fmt & 0xff;

    uint64_t vtCount = [_gpuProcessor vtCallCount];
    uint64_t vtTotalNs = [_gpuProcessor vtTotalNs];
    uint64_t vtMaxNs = [_gpuProcessor vtMaxNs];
    double vtMeanUs = vtCount > 0 ? (double)vtTotalNs / vtCount / 1000.0 : 0.0;
    double vtMaxUs = vtMaxNs / 1000.0;
    uint64_t cacheHits = [_gpuProcessor cacheHitCount];
    uint64_t cacheRebuilds = [_gpuProcessor cacheRebuildCount];
    uint64_t cacheRebuildNs = [_gpuProcessor cacheRebuildTotalNs];
    double rebuildMeanUs = cacheRebuilds > 0 ? (double)cacheRebuildNs / cacheRebuilds / 1000.0 : 0.0;
    double cacheHitRate = (cacheHits + cacheRebuilds) > 0
        ? 100.0 * cacheHits / (cacheHits + cacheRebuilds) : 0.0;

    // Per-interval rates: emitFps = camera emits/sec through the hook; freshFps = how often
    // the replacement image actually updates (new source frames = cache rebuilds). A low
    // freshFps while enabled means the source is starving the consumer (cpu/network).
    double upNow = NSProcessInfo.processInfo.systemUptime;
    uint64_t hitNow = atomic_load(&_hitTotal);
    double emitFps = 0.0, freshFps = 0.0;
    if (_lastDumpUptime > 0.0) {
        double dt = upNow - _lastDumpUptime;
        if (dt > 0.0) {
            emitFps  = (double)(hitNow - _lastHitSnap) / dt;
            freshFps = (double)(cacheRebuilds - _lastRebuildSnap) / dt;
        }
    }
    _lastDumpUptime = upNow; _lastHitSnap = hitNow; _lastRebuildSnap = cacheRebuilds;

    NSMutableString *s = [NSMutableString stringWithCapacity:1024];
    [s appendFormat:@"=== vcam-msd stats @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"SUMMARY emitFps=%.1f freshFps=%.1f  (freshFps = real image update rate)\n",
        emitFps, freshFps];
    if (atomic_load(&_enabled)) {
        [s appendFormat:@"VERDICT: %@\n", freshFps < 20.0
            ? @"source STARVED — fresh frames not arriving fast enough (cpu/network)"
            : @"source healthy"];
    }
    [s appendFormat:@"playerStarted=%d enabled=%d\n", _playerStarted, atomic_load(&_enabled)];
    [s appendFormat:@"mode=%@ source=%@\n", _ndiMode ? @"ndi" : @"file", _ndiMode ? @"(ndi shm)" : _sourcePath];
    [s appendFormat:@"lastDst=%ux%u '%s' (0x%08x)\n", w, h, fcc, fmt];
    [s appendFormat:@"\n--- emit hit breakdown ---\n"];
    [s appendFormat:@"hitTotal:        %llu\n", atomic_load(&_hitTotal)];
    [s appendFormat:@"  nonVideo:      %llu\n", atomic_load(&_hitNonVideo)];
    [s appendFormat:@"  noPB:          %llu\n", atomic_load(&_hitNoPB)];
    [s appendFormat:@"  lossyDst:      %llu\n", atomic_load(&_hitLossyDst)];
    [s appendFormat:@"  alreadyDone:   %llu  (srcID throttle: src frame already consumed)\n",
        atomic_load(&_hitAlreadyConsumed)];
    [s appendFormat:@"  noSrc:         %llu\n", atomic_load(&_hitNoSrc)];
    [s appendFormat:@"  vtAttempt:     %llu\n", atomic_load(&_hitVTAttempt)];
    [s appendFormat:@"  vtSuccess:     %llu\n", atomic_load(&_hitVTSuccess)];
    [s appendFormat:@"  vtFail:        %llu (lastStatus=%d)\n",
        atomic_load(&_hitVTFail), [_gpuProcessor lastFailStatus]];
    [s appendFormat:@"\n--- VT latency (P0+cache: RealTime + CropMode + cached transfer) ---\n"];
    [s appendFormat:@"vtCount:        %llu  (every emit that called transferFrom)\n", vtCount];
    [s appendFormat:@"vtMeanUs:       %.1f µs  (overall, mixing fast and slow path)\n", vtMeanUs];
    [s appendFormat:@"vtMaxUs:        %.1f µs\n", vtMaxUs];
    [s appendFormat:@"cacheHits:      %llu  (fast path = cached → dst, hardware blit)\n", cacheHits];
    [s appendFormat:@"cacheRebuilds:  %llu  (slow path = src → cached, scale+rotate+convert)\n", cacheRebuilds];
    [s appendFormat:@"cacheHitRate:   %.1f%%\n", cacheHitRate];
    [s appendFormat:@"rebuildMeanUs:  %.1f µs  (per slow-path call; expect ~2000µs first-time)\n", rebuildMeanUs];

    extern _Atomic int gInstallPollCount;
    extern _Atomic int gInstallState;
    extern _Atomic int gInstallHookKind;
    extern _Atomic int gInstallSubclassHits;
    extern _Atomic int gFirstClassReachedHook;
    [s appendFormat:@"\n--- hook install diagnostics ---\n"];
    [s appendFormat:@"installPollCount:    %d\n", atomic_load(&gInstallPollCount)];
    [s appendFormat:@"installState:        %d  (0=class missing, 1=class found, 2=no class owns method, 3=hooked OK)\n",
        atomic_load(&gInstallState)];
    [s appendFormat:@"installHookKind:     %d  (0=not yet, 1=MSHookMessageEx, 2=method_setImplementation)\n",
        atomic_load(&gInstallHookKind)];
    [s appendFormat:@"installSubclassHits: %d  (total emit-implementing classes hooked)\n",
        atomic_load(&gInstallSubclassHits)];
    [s appendFormat:@"emitHookEverFired:   %d  (1 if any hooked class's emit was actually called)\n",
        atomic_load(&gFirstClassReachedHook)];
    [s writeToFile:kVCamStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Hot path: a single relaxed atomic load, no stat/syscall. State is driven entirely by the
// Darwin-notification handlers on _ctrlQueue.
- (BOOL)isEnabled {
    return atomic_load_explicit(&_enabled, memory_order_relaxed);
}

- (BOOL)replaceInPlace:(CMSampleBufferRef)sb {
    if (!sb) return NO;
    atomic_fetch_add_explicit(&_hitTotal, 1, memory_order_relaxed);

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) {
        atomic_fetch_add_explicit(&_hitNonVideo, 1, memory_order_relaxed);
        return NO;
    }

    CVImageBufferRef dstPB = CMSampleBufferGetImageBuffer(sb);
    if (!dstPB) {
        atomic_fetch_add_explicit(&_hitNoPB, 1, memory_order_relaxed);
        return NO;
    }

    OSType dstFmt = CVPixelBufferGetPixelFormatType(dstPB);
    atomic_store_explicit(&_lastDstFmt, dstFmt, memory_order_relaxed);
    atomic_store_explicit(&_lastDstW, (uint32_t)CVPixelBufferGetWidth(dstPB), memory_order_relaxed);
    atomic_store_explicit(&_lastDstH, (uint32_t)CVPixelBufferGetHeight(dstPB), memory_order_relaxed);

    if (vcam_isLossyDestination(dstFmt)) {
        atomic_fetch_add_explicit(&_hitLossyDst, 1, memory_order_relaxed);
        return NO;
    }

    // Emit hot path: copy the latest off-thread-rendered frame into the camera buffer. No render
    // here — the GPU work happens on _renderQueue (renderTick), so this stays a quick memcpy.
    atomic_fetch_add_explicit(&_hitVTAttempt, 1, memory_order_relaxed);
    if (![_gpuProcessor copyLatestInto:dstPB]) {  // not rendered yet -> pass real camera through
        atomic_fetch_add_explicit(&_hitNoSrc, 1, memory_order_relaxed);
        return NO;
    }
    atomic_fetch_add_explicit(&_hitVTSuccess, 1, memory_order_relaxed);
    return YES;
}

@end
