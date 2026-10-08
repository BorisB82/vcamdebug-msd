#import <UIKit/UIKit.h>

// Standalone controller for vcamplus-msd. Lists candidate source clips, writes the shared
// config plist, and drives the mediaserverd-side tweak purely via Darwin notifications.
// No injection into any other process.
@interface VCCRootViewController : UIViewController
@end
