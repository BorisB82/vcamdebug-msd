// Standalone HEVC recorder for the real camera frames flowing through the emit hook. Read-only:
// it observes the sample buffers BEFORE any replacement, copies them off the emit thread, and
// encodes them to an .mov in DCIM via AVAssetWriter (hardware HEVC). Driven by Darwin
// notifications (com.vcamplus.rec.start / .stop / .toggle) so the control app — or an
// interactive notification — can arm/disarm it without touching the replacement pipeline.
//
// On start it probes briefly to find the largest active geometry (the master feed), locks onto
// it, and records only that geometry so the output is a single coherent video.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamRecorder : NSObject

+ (instancetype)shared;

// Emit hot path: feed every real camera sample buffer here (before replacement). Returns
// immediately with a single atomic load when not armed, so it is cheap to call unconditionally.
- (void)observeSampleBuffer:(CMSampleBufferRef)sb;

// Control (safe from any thread). start/stop also post status to vcam_rec_status.txt.
- (void)start;
- (void)stop;
- (void)toggle;
- (BOOL)isRecording;

// One-line-ish status block for the stats dump.
- (NSString *)statusReport;

@end

NS_ASSUME_NONNULL_END
