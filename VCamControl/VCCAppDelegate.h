#import <UIKit/UIKit.h>

@interface VCCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;

// Post (or replace) the interactive recorder-control notification, showing Start/Stop actions.
// `recording` selects the body text; the action buttons themselves are always both available.
+ (void)presentRecordingNotificationRecording:(BOOL)recording;
@end
