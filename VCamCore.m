// Singleton coordinator. Enabled only when /var/mobile/Media/DCIM/vcam.mp4 and vcam_msd_active both
// exist (stat cached ~500ms); starts/stops LocalVideoPlayer accordingly. replaceInPlace: validates
// the destination CVPixelBuffer (video media type, non-lossy format), fetches the latest decoded
// source frame, and delegates scale/format conversion to GPUImageProcessor. Maintains atomic
// hit/latency counters written to a stats file every 5s.

#import "VCamCore.h"
#import "LocalVideoPlayer.h"
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
    NSString *_sourcePath;          // current source; swappable at runtime via .reload
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

    dispatch_source_t _statsTimer;
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
    }
    return self;
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

// Runs on _ctrlQueue. Toggles the gate and starts/stops the decoder to match.
- (void)applyEnabled:(BOOL)on {
    if (on && !_playerStarted) {
        [_videoPlayer start];
        _playerStarted = YES;
    } else if (!on && _playerStarted) {
        [_videoPlayer stop];
        _playerStarted = NO;
    }
    atomic_store(&_enabled, on);
    NSLog(@"[vcam-msd] enabled=%d (source=%@)", on, _sourcePath);
}

// Runs on _ctrlQueue. Re-reads the source path; if it changed, swaps the decoder's input
// without dropping the enabled state.
- (void)reloadSource {
    NSString *next = [self configuredSourcePath];
    if ([next isEqualToString:_sourcePath]) {
        NSLog(@"[vcam-msd] reload: source unchanged (%@)", _sourcePath);
        return;
    }
    _sourcePath = [next copy];
    [_videoPlayer setPath:_sourcePath];
    NSLog(@"[vcam-msd] reload: source -> %@", _sourcePath);
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

    NSMutableString *s = [NSMutableString stringWithCapacity:1024];
    [s appendFormat:@"=== vcam-msd v0.7 stats @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"playerStarted=%d enabled=%d\n", _playerStarted, atomic_load(&_enabled)];
    [s appendFormat:@"source=%@\n", _sourcePath];
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
    [s appendFormat:@"  vtFail:        %llu\n", atomic_load(&_hitVTFail)];
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

    uint64_t srcID = [_videoPlayer latestFrameID];
    if (srcID == 0) {
        atomic_fetch_add_explicit(&_hitNoSrc, 1, memory_order_relaxed);
        return NO;
    }

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) {
        atomic_fetch_add_explicit(&_hitNoSrc, 1, memory_order_relaxed);
        return NO;
    }

    atomic_fetch_add_explicit(&_hitVTAttempt, 1, memory_order_relaxed);
    BOOL ok = [_gpuProcessor transferFrom:srcFrame srcID:srcID into:dstPB];
    CFRelease(srcFrame);
    atomic_store_explicit(&_lastConsumedSrcID, srcID, memory_order_relaxed);
    if (ok) {
        atomic_fetch_add_explicit(&_hitVTSuccess, 1, memory_order_relaxed);
        return YES;
    } else {
        atomic_fetch_add_explicit(&_hitVTFail, 1, memory_order_relaxed);
        return NO;
    }
}

@end
