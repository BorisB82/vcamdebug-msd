#import "VCamRecProvider.h"
#import "VCamRecToggle.h"
#import <UIKit/UIKit.h>

static NSString *const kModuleId = @"com.vcamplus.reccc.toggle";

@implementation VCamRecProvider

- (NSUInteger)numberOfProvidedModules { return 1; }
- (NSString *)identifierForModuleAtIndex:(NSUInteger)index { return kModuleId; }
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier { return [VCamRecToggle new]; }
- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier { return @"VCam Record"; }
- (UIImage *)settingsIconForModuleIdentifier:(NSString *)identifier {
    return [UIImage systemImageNamed:@"record.circle"];
}

@end
