#import "VCCAppDelegate.h"
#import "VCCRootViewController.h"
#import "VCCRec.h"

#import <UserNotifications/UserNotifications.h>
#import <notify.h>

@interface VCCAppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation VCCAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    VCCRootViewController *root = [VCCRootViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    [self setUpNotifications];
    return YES;
}

- (void)setUpNotifications {
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    c.delegate = self;

    UNNotificationAction *start =
        [UNNotificationAction actionWithIdentifier:kRecActionStart
                                             title:@"● Start Recording"
                                           options:UNNotificationActionOptionNone];
    UNNotificationAction *stop =
        [UNNotificationAction actionWithIdentifier:kRecActionStop
                                             title:@"■ Stop Recording"
                                           options:UNNotificationActionOptionDestructive];
    UNNotificationCategory *cat =
        [UNNotificationCategory categoryWithIdentifier:kRecCategoryId
                                               actions:@[start, stop]
                                     intentIdentifiers:@[]
                                               options:UNNotificationCategoryOptionCustomDismissAction];
    [c setNotificationCategories:[NSSet setWithObject:cat]];

    [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                     completionHandler:^(BOOL granted, NSError *error) {
        NSLog(@"[vcc] notification auth granted=%d err=%@", granted, error);
    }];
}

+ (void)presentRecordingNotificationRecording:(BOOL)recording {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"VCam Recorder";
    content.body  = recording ? @"● Recording — pull down and tap Stop to finish."
                              : @"Idle — pull down and tap Start to record the camera feed.";
    content.categoryIdentifier = kRecCategoryId;
    content.sound = nil;
    if (@available(iOS 15.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelActive;
    }

    // Fixed identifier → each post replaces the previous one, so there is a single live control.
    UNNotificationRequest *req =
        [UNNotificationRequest requestWithIdentifier:kRecNotifReqId content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:req
                                                        withCompletionHandler:^(NSError *e) {
        if (e) NSLog(@"[vcc] present notification failed: %@", e);
    }];
}

#pragma mark - UNUserNotificationCenterDelegate

// Show the banner even while the app is in the foreground, so the control is always visible.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert);
    }
}

// An action was tapped. Drive the tweak via Darwin note, then re-post the notification reflecting
// the new state so the live control stays in Notification Center.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *action = response.actionIdentifier;
    BOOL nowRecording;
    if ([action isEqualToString:kRecActionStart]) {
        notify_post(kNoteRecStart.UTF8String);
        nowRecording = YES;
    } else if ([action isEqualToString:kRecActionStop]) {
        notify_post(kNoteRecStop.UTF8String);
        nowRecording = NO;
    } else {
        // Default tap / dismiss: leave state as-is, just keep a control available.
        nowRecording = VCCRecIsRecording();
    }

    if (![action isEqualToString:UNNotificationDismissActionIdentifier]) {
        [VCCAppDelegate presentRecordingNotificationRecording:nowRecording];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:kRecStateDidChange object:nil];
    });
    completionHandler();
}

@end
