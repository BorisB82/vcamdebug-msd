// SpringBoard-side Activator listener for the VCamdebug recorder. Registers Start / Stop / Toggle
// actions with Activator; when the user fires a bound gesture, we post the recorder's Darwin
// notifications (the same ones the control app and mediaserverd use). No link against libactivator
// — we look it up at runtime and no-op if Activator isn't installed.

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import "libactivator.h"

static NSString *const kToggle = @"com.vcamplus.rec.toggle";
static NSString *const kStart  = @"com.vcamplus.rec.start";
static NSString *const kStop   = @"com.vcamplus.rec.stop";

@interface VCamActListener : NSObject <LAListener>
@end

@implementation VCamActListener

+ (instancetype)shared {
    static VCamActListener *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamActListener new]; });
    return s;
}

- (void)postForName:(NSString *)name {
    if      ([name isEqualToString:kStart]) notify_post(kStart.UTF8String);
    else if ([name isEqualToString:kStop])  notify_post(kStop.UTF8String);
    else                                    notify_post(kToggle.UTF8String);
}

- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event forListenerName:(NSString *)listenerName {
    [self postForName:listenerName];
    if ([event respondsToSelector:@selector(setHandled:)]) event.handled = YES;
}

// Fallback for older Activator builds that don't pass the listener name.
- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event {
    [self postForName:kToggle];
    if ([event respondsToSelector:@selector(setHandled:)]) event.handled = YES;
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName {
    if ([listenerName isEqualToString:kStart]) return @"VCam: Start Recording";
    if ([listenerName isEqualToString:kStop])  return @"VCam: Stop Recording";
    return @"VCam: Toggle Recording";
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName {
    return @"VCamdebug";
}

@end

static void vcam_registerActivator(void) {
    Class cls = objc_getClass("LAActivator");
    if (!cls) return;                                   // Activator not installed → silently skip
    id act = [cls sharedInstance];
    if (![act respondsToSelector:@selector(registerListener:forName:)]) return;
    for (NSString *n in @[kToggle, kStart, kStop]) {
        @try { [act registerListener:[VCamActListener shared] forName:n]; }
        @catch (__unused NSException *e) {}
    }
    NSLog(@"[vcam-act] registered Activator listeners (toggle/start/stop)");
}

%ctor {
    @autoreleasepool {
        // Register once SpringBoard has finished launching (Activator loads around then), and retry
        // once a few seconds later in case we were injected before Activator.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *n) { vcam_registerActivator(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ vcam_registerActivator(); });
    }
}
