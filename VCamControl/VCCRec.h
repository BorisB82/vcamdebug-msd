// Shared identifiers for the recorder control surface (notification + in-app). The note names
// must match VCamRecorder.m in the tweak.

#import <Foundation/Foundation.h>

static NSString *const kNoteRecStart  = @"com.vcamplus.rec.start";
static NSString *const kNoteRecStop   = @"com.vcamplus.rec.stop";
static NSString *const kNoteRecToggle = @"com.vcamplus.rec.toggle";

// Tweak-written status file: "state=<idle|arming|recording|finishing|error>\n<detail>\n".
static NSString *const kRecStatusFile = @"/var/mobile/Media/DCIM/vcam_rec_status.txt";

// Interactive-notification identifiers.
static NSString *const kRecCategoryId   = @"VCAM_REC_CTRL";
static NSString *const kRecActionStart  = @"VCAM_REC_START";
static NSString *const kRecActionStop   = @"VCAM_REC_STOP";
static NSString *const kRecNotifReqId    = @"vcam.rec.control";

// Posted (NSNotificationCenter, in-process) after a notification action changes recorder state,
// so the open view controller can refresh its status immediately.
static NSString *const kRecStateDidChange = @"VCCRecStateDidChange";

// Reads the tweak's status file; treats both "recording" and "arming" (probe) as active.
static inline BOOL VCCRecIsRecording(void) {
    NSString *s = [NSString stringWithContentsOfFile:kRecStatusFile
                                            encoding:NSUTF8StringEncoding error:nil];
    return [s containsString:@"state=recording"] || [s containsString:@"state=arming"];
}
