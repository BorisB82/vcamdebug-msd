// Background AVAssetReader loop decoding the source mp4 to 32BGRA at ~30fps; publishes the latest
// CVPixelBuffer (retained) and a monotonic frame id under an os_unfair_lock; recreates the reader to
// loop at EOF. Does not apply the track preferredTransform, so frames are produced in stored pixel
// orientation.

#import "LocalVideoPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import <stdatomic.h>

static const NSTimeInterval kFrameInterval = 1.0 / 30.0;

@implementation LocalVideoPlayer {
    NSString *_path;
    dispatch_queue_t _queue;
    os_unfair_lock _frameLock;
    CVPixelBufferRef _latestFrame;
    _Atomic uint64_t _frameID;
    BOOL _running;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    NSTimeInterval _frameInterval;   // target cadence = 1/source-fps (falls back to 1/30)
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _queue = dispatch_queue_create("com.vcamplus.msd.decoder", DISPATCH_QUEUE_SERIAL);
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _frameInterval = kFrameInterval;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    @synchronized(self) {
        if (_running) return;
        _running = YES;
    }
    dispatch_async(_queue, ^{ [self decodeLoop]; });
}

- (void)stop {
    @synchronized(self) {
        if (!_running) return;
        _running = NO;
    }
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    os_unfair_lock_lock(&_frameLock);
    if (_latestFrame) { CFRelease(_latestFrame); _latestFrame = NULL; }
    os_unfair_lock_unlock(&_frameLock);
}

- (void)setPath:(NSString *)path {
    BOOL wasRunning;
    @synchronized(self) { wasRunning = _running; }
    if (wasRunning) [self stop];
    @synchronized(self) { _path = [path copy]; }
    if (wasRunning) [self start];
}

- (CVPixelBufferRef)latestFrameRetained {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef pb = _latestFrame;
    if (pb) CFRetain(pb);
    os_unfair_lock_unlock(&_frameLock);
    return pb;
}

- (uint64_t)latestFrameID {
    return atomic_load_explicit(&_frameID, memory_order_relaxed);
}

- (BOOL)openReader {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:_path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;

    NSError *err = nil;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!_reader || err) {
        NSLog(@"[vcam-msd] AVAssetReader create failed: %@", err);
        return NO;
    }
    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
    _output.alwaysCopiesSampleData = NO;
    float fps = ((AVAssetTrack *)tracks[0]).nominalFrameRate;
    _frameInterval = (fps > 1.0f && fps <= 120.0f) ? (1.0 / fps) : kFrameInterval;
    if (![_reader canAddOutput:_output]) return NO;
    [_reader addOutput:_output];
    if (![_reader startReading]) {
        NSLog(@"[vcam-msd] AVAssetReader startReading failed: %@", _reader.error);
        return NO;
    }
    return YES;
}

- (void)decodeLoop {
    NSLog(@"[vcam-msd] decoder loop starting (path=%@)", _path);
    // Absolute-deadline pacing: sleep only the time left until the next frame's slot, so the
    // cadence is the true source fps (1/_frameInterval) rather than decodeTime + interval.
    NSTimeInterval next = NSProcessInfo.processInfo.systemUptime;
    while (1) {
        BOOL running;
        @synchronized(self) { running = _running; }
        if (!running) break;

        @autoreleasepool {
            if (!_reader || _reader.status != AVAssetReaderStatusReading) {
                _reader = nil; _output = nil;
                if (![self openReader]) {
                    [NSThread sleepForTimeInterval:0.5];
                    next = NSProcessInfo.processInfo.systemUptime;
                    continue;
                }
                next = NSProcessInfo.processInfo.systemUptime;   // resync at (re)open / loop point
            }

            CMSampleBufferRef sb = [_output copyNextSampleBuffer];
            if (!sb) {
                [_reader cancelReading];
                _reader = nil; _output = nil;
                continue;
            }
            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (pb) {
                CFRetain(pb);
                os_unfair_lock_lock(&_frameLock);
                CVPixelBufferRef old = _latestFrame;
                _latestFrame = pb;
                atomic_fetch_add_explicit(&_frameID, 1, memory_order_relaxed);
                os_unfair_lock_unlock(&_frameLock);
                if (old) CFRelease(old);
            }
            CFRelease(sb);
        }

        // Pace to the next slot; if decoding already overran it, don't sleep (and resync so we
        // don't spiral) — the decode itself is then the limiter, not an added sleep.
        next += _frameInterval;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSTimeInterval delay = next - now;
        if (delay > 0) [NSThread sleepForTimeInterval:delay];
        else next = now;
    }
    NSLog(@"[vcam-msd] decoder loop exiting");
}

@end
