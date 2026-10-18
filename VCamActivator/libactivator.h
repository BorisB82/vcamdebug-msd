// Minimal libactivator declarations — just what the listener needs. We don't link libactivator;
// registration is done via the Objective-C runtime at launch and no-ops if Activator is absent.

#import <Foundation/Foundation.h>

@class LAActivator, LAEvent;

@protocol LAListener <NSObject>
@optional
- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event;
- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event forListenerName:(NSString *)listenerName;
- (NSString *)activator:(LAActivator *)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName;
- (NSString *)activator:(LAActivator *)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName;
@end

@interface LAEvent : NSObject
@property (nonatomic, getter=isHandled) BOOL handled;
@end

@interface LAActivator : NSObject
+ (instancetype)sharedInstance;
- (void)registerListener:(id<LAListener>)listener forName:(NSString *)name;
- (void)unregisterListenerWithName:(NSString *)name;
@end
