// mediaserverd-side consumer of the NDI daemon's shared-memory frame ring. Maps
// VCAMNDI_PATH read-only and, per frame, copies the latest published UYVY slot into a
// local IOSurface-backed CVPixelBuffer (so VideoToolbox's pixel transfer accepts it).
// Conforms to VCamFrameSource so VCamCore treats it like the mp4 player.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "VCamFrameSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDIShmSource : NSObject <VCamFrameSource>
@end

NS_ASSUME_NONNULL_END
