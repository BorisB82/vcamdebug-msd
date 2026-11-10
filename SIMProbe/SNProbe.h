// SNProbe: gathers every SIM / mobile-network fact the device will give up, split by how a
// *normal sandboxed App Store app* would fare getting it — even though this app itself runs
// unsandboxed (platform-application) so it can also reveal the root-only values for comparison.
//
// Tiers (what a regular sandboxed app sees):
//   SNTierPublic            public API, real value — any app gets this.
//   SNTierPublicRandomized  public API, but iOS returns a placeholder to EVERY app (incl. root).
//                           The hiding is at the framework level, not the sandbox.
//   SNTierRoot              a sandboxed app is blocked (sandbox/private API). Shown here only
//                           because this build runs outside the container on your jailbreak.
//   SNTierInfo             context, not a SIM value (device setting, environment).

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SNTier) {
    SNTierPublic = 0,
    SNTierPublicRandomized,
    SNTierRoot,
    SNTierInfo,
};

// Row keys: @"k" (NSString label), @"v" (NSString value), @"tier" (NSNumber SNTier),
//           @"note" (NSString, optional).
// Section keys: @"title" (NSString), @"rows" (NSArray<NSDictionary *>).
@interface SNProbe : NSObject
+ (NSArray<NSDictionary *> *)collectSections;
+ (NSString *)plainTextDump:(NSArray<NSDictionary *> *)sections;
@end
