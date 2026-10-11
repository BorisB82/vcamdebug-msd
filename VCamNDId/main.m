// vcamndid — milestone 1: a standalone LaunchDaemon that receives a full-bandwidth NDI
// stream, CPU-decodes it (via the NDI SDK), and logs frame geometry/format/fps to a stats
// file. No mediaserverd involvement and no IPC yet — this proves receive + decode work on
// the device before the IOSurface bridge is added in milestone 2.
//
// Config:  /var/mobile/Media/DCIM/vcam_ndi.plist
//            source  (string) — substring to match against an NDI source's name
//                               "MACHINE (Source)"; empty = use the first discovered source
//            url     (string) — explicit "ip:port" to connect without discovery (optional)
//            enabled (bool)   — default true; false idles the daemon
// Stats:   /var/mobile/Media/DCIM/vcam_ndi_stats.txt   (rewritten ~1 Hz)
// Reload:  Darwin notification "com.vcamplus.ndi.reload" re-reads config + reconnects.

#import <Foundation/Foundation.h>
#import <notify.h>
#include "Processing.NDI.Lib.h"

static NSString *const kConfigPlist = @"/var/mobile/Media/DCIM/vcam_ndi.plist";
static NSString *const kStatsFile   = @"/var/mobile/Media/DCIM/vcam_ndi_stats.txt";
static const char  *const kNoteReload = "com.vcamplus.ndi.reload";

static volatile int gReload = 0;

typedef struct {
    NSString *source;   // substring match, or nil
    NSString *url;      // explicit ip:port, or nil
    BOOL enabled;
} VCamNDIConfig;

static VCamNDIConfig readConfig(void) {
    VCamNDIConfig c = { .source = nil, .url = nil, .enabled = YES };
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    if ([d isKindOfClass:NSDictionary.class]) {
        if ([d[@"source"] isKindOfClass:NSString.class]) c.source = d[@"source"];
        if ([d[@"url"]    isKindOfClass:NSString.class]) c.url    = d[@"url"];
        if (d[@"enabled"] != nil) c.enabled = [d[@"enabled"] boolValue];
    }
    return c;
}

static void fourccToStr(int fcc, char out[5]) {
    out[0] = (char)(fcc & 0xff);  out[1] = (char)((fcc >> 8) & 0xff);
    out[2] = (char)((fcc >> 16) & 0xff); out[3] = (char)((fcc >> 24) & 0xff); out[4] = 0;
}

static void writeStats(NSString *state, NSString *sourceName,
                       int xres, int yres, int fourcc, double fps,
                       unsigned long long frames) {
    char fcc[5] = {0}; fourccToStr(fourcc, fcc);
    NSMutableString *s = [NSMutableString stringWithCapacity:512];
    [s appendFormat:@"=== vcam-ndi milestone1 @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"state=%@\n", state];
    [s appendFormat:@"source=%@\n", sourceName.length ? sourceName : @"(none)"];
    [s appendFormat:@"frame=%dx%d fourcc=%s\n", xres, yres, fcc];
    [s appendFormat:@"fps=%.2f framesTotal=%llu\n", fps, frames];
    [s writeToFile:kStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[vcam-ndi] starting");

        if (!NDIlib_initialize()) {
            NSLog(@"[vcam-ndi] NDIlib_initialize failed (unsupported CPU?)");
            writeStats(@"ndi-init-failed", nil, 0, 0, 0, 0, 0);
            // Sleep rather than exit, so KeepAlive doesn't crash-loop us.
            [NSThread sleepForTimeInterval:30]; return 1;
        }

        int token;
        notify_register_dispatch(kNoteReload, &token,
                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                 ^(int t){ (void)t; gReload = 1; });

        NDIlib_find_create_t fcreate = { .show_local_sources = true,
                                         .p_groups = NULL, .p_extra_ips = NULL };
        NDIlib_find_instance_t finder = NDIlib_find_create_v2(&fcreate);
        if (!finder) {
            NSLog(@"[vcam-ndi] find_create failed");
            writeStats(@"find-create-failed", nil, 0, 0, 0, 0, 0);
            [NSThread sleepForTimeInterval:30]; return 1;
        }

        unsigned long long framesTotal = 0;

        while (1) {
            @autoreleasepool {
                gReload = 0;
                VCamNDIConfig cfg = readConfig();

                if (!cfg.enabled) {
                    writeStats(@"disabled", nil, 0, 0, 0, 0.0, framesTotal);
                    for (int i = 0; i < 10 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // Resolve a source: explicit url, else substring match, else first found.
                NDIlib_source_t chosen = (NDIlib_source_t){0};
                NSString *chosenName = nil;
                char urlBuf[256] = {0};

                if (cfg.url.length) {
                    strncpy(urlBuf, cfg.url.UTF8String, sizeof(urlBuf) - 1);
                    chosen.p_ndi_name = NULL;
                    chosen.p_url_address = urlBuf;
                    chosenName = [NSString stringWithFormat:@"url:%@", cfg.url];
                } else {
                    writeStats(@"searching", nil, 0, 0, 0, 0.0, framesTotal);
                    NDIlib_find_wait_for_sources(finder, 2000);
                    uint32_t n = 0;
                    const NDIlib_source_t *srcs = NDIlib_find_get_current_sources(finder, &n);
                    const NDIlib_source_t *pick = NULL;
                    for (uint32_t i = 0; i < n; i++) {
                        NSString *nm = srcs[i].p_ndi_name
                            ? [NSString stringWithUTF8String:srcs[i].p_ndi_name] : @"";
                        if (!cfg.source.length) { pick = &srcs[i]; chosenName = nm; break; }
                        if ([nm localizedCaseInsensitiveContainsString:cfg.source]) {
                            pick = &srcs[i]; chosenName = nm; break;
                        }
                    }
                    if (!pick) {
                        // nothing matched yet; keep looping (find list updates over time)
                        for (int i = 0; i < 5 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                        continue;
                    }
                    chosen = *pick;
                }

                NSLog(@"[vcam-ndi] connecting to %@", chosenName);
                NDIlib_recv_create_v3_t rcreate = {
                    .source_to_connect_to = chosen,
                    .color_format = NDIlib_recv_color_format_fastest,
                    .bandwidth    = NDIlib_recv_bandwidth_highest,
                    .allow_video_fields = true,
                    .p_ndi_recv_name = "VCamNDI",
                };
                NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&rcreate);
                if (!recv) {
                    writeStats(@"recv-create-failed", chosenName, 0, 0, 0, 0.0, framesTotal);
                    for (int i = 0; i < 10 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // Capture loop for this connection.
                double lastStat = NSProcessInfo.processInfo.systemUptime;
                unsigned long long framesAtLastStat = framesTotal;
                int lastX = 0, lastY = 0, lastFourCC = 0;
                double measuredFps = 0.0;
                BOOL stayConnected = YES;

                while (stayConnected && !gReload) {
                    @autoreleasepool {
                        NDIlib_video_frame_v2_t vid = {0};
                        NDIlib_frame_type_e type =
                            NDIlib_recv_capture_v2(recv, &vid, NULL, NULL, 1000);

                        if (type == NDIlib_frame_type_video) {
                            framesTotal++;
                            lastX = vid.xres; lastY = vid.yres; lastFourCC = (int)vid.FourCC;
                            NDIlib_recv_free_video_v2(recv, &vid);   // free immediately
                        } else if (type == NDIlib_frame_type_error) {
                            stayConnected = NO;
                        }
                        // none / status_change: just keep polling.

                        double now = NSProcessInfo.processInfo.systemUptime;
                        if (now - lastStat >= 1.0) {
                            measuredFps = (double)(framesTotal - framesAtLastStat) / (now - lastStat);
                            BOOL live = (framesTotal > framesAtLastStat);
                            writeStats(live ? @"connected" : @"connected-nodata",
                                       chosenName, lastX, lastY, lastFourCC,
                                       measuredFps, framesTotal);
                            lastStat = now; framesAtLastStat = framesTotal;

                            // Re-read config so enabled=false / source change takes effect.
                            VCamNDIConfig c2 = readConfig();
                            if (!c2.enabled) stayConnected = NO;
                        }
                    }
                }

                NDIlib_recv_destroy(recv);
            }
        }

        NDIlib_find_destroy(finder);
        NDIlib_destroy();
        return 0;
    }
}
