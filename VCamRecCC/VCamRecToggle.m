#import "VCamRecToggle.h"
#import <notify.h>

// Must match VCamRecorder.m / VCCRec.h.
static NSString *const kRecStatusFile = @"/var/mobile/Media/DCIM/vcam_rec_status.txt";
static NSString *const kNoteRecStart  = @"com.vcamplus.rec.start";
static NSString *const kNoteRecStop   = @"com.vcamplus.rec.stop";

@implementation VCamRecToggle

- (UIImage *)iconGlyph         { return [UIImage systemImageNamed:@"record.circle"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"stop.circle.fill"]; }
- (UIColor *)selectedColor     { return UIColor.systemRedColor; }

// Reflect the real recorder state (written by the tweak), so the toggle is correct even if
// recording was started/stopped elsewhere. "arming" (probe) counts as on.
- (BOOL)isSelected {
    NSString *s = [NSString stringWithContentsOfFile:kRecStatusFile
                                            encoding:NSUTF8StringEncoding error:nil];
    return [s containsString:@"state=recording"] || [s containsString:@"state=arming"];
}

// Control Center hands us the new desired state on tap; drive the recorder via Darwin note and
// ask CC to re-query our appearance.
- (void)setSelected:(BOOL)selected {
    notify_post((selected ? kNoteRecStart : kNoteRecStop).UTF8String);
    [self refreshState];
}

@end
