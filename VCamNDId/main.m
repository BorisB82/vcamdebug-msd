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
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdatomic.h>
#import <pthread.h>
#include "Processing.NDI.Lib.h"
#include "VCamNDIShared.h"

static NSString *const kConfigPlist = @"/var/mobile/Media/DCIM/vcam_ndi.plist";
static NSString *const kStatsFile   = @"/var/mobile/Media/DCIM/vcam_ndi_stats.txt";
static const char  *const kNoteReload = "com.vcamplus.ndi.reload";

static volatile int gReload = 0;

// ---- Shared-memory frame publisher ---------------------------------------
// Maps VCAMNDI_PATH MAP_SHARED and writes decoded UYVY frames into a ring of slots
// for the mediaserverd tweak to consume.
typedef struct {
    int fd;
    uint8_t *base;          // mmap base (header page + ring slots)
    VCamNDIHeader *hdr;
    uint32_t writeIndex;    // next slot to write
} VCamNDIPublisher;

static BOOL pub_open(VCamNDIPublisher *p) {
    memset(p, 0, sizeof(*p));
    p->fd = open(VCAMNDI_PATH, O_RDWR | O_CREAT, 0644);
    if (p->fd < 0) { NSLog(@"[vcam-ndi] shm open failed: %s", strerror(errno)); return NO; }
    if (ftruncate(p->fd, (off_t)VCAMNDI_FILE_SIZE) != 0) {
        NSLog(@"[vcam-ndi] ftruncate failed: %s", strerror(errno)); close(p->fd); p->fd = -1; return NO;
    }
    // World-readable so the _mediaserverd user can map it read-only.
    fchmod(p->fd, 0644);
    p->base = mmap(NULL, (size_t)VCAMNDI_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, p->fd, 0);
    if (p->base == MAP_FAILED) {
        NSLog(@"[vcam-ndi] mmap failed: %s", strerror(errno)); close(p->fd); p->fd = -1; return NO;
    }
    p->hdr = (VCamNDIHeader *)p->base;
    p->hdr->magic = 0; // mark uninitialized until first config
    p->hdr->abi = VCAMNDI_ABI;
    p->hdr->ringCount = VCAMNDI_RING;
    p->hdr->slotBytes = VCAMNDI_SLOT_BYTES;
    p->hdr->enabled = 0;
    p->hdr->frameSeq = 0;
    p->writeIndex = 0;
    NSLog(@"[vcam-ndi] shm mapped (%llu bytes)", (unsigned long long)VCAMNDI_FILE_SIZE);
    return YES;
}

static void pub_set_enabled(VCamNDIPublisher *p, BOOL on) {
    if (p->hdr) p->hdr->enabled = on ? 1 : 0;
}

// Publish a packed UYVY (4:2:2, stride = w*2) frame into the next ring slot as-is. The byte
// reorganize to NV12 was moved back out: doing it in the daemon process starved NDI's internal
// network thread and dropped the connection. The consumer takes UYVY directly. This runs on the
// CONVERTER thread and is just a memcpy, so it stays cheap. Kept decoupled from capture so a
// stall drops frames, not the NDI link.
static void pub_write_packed(VCamNDIPublisher *p, const uint8_t *src, uint32_t w, uint32_t h) {
    if (!p->hdr || !src) return;
    if (w < 2 || h < 2 || (w & 1u) || (h & 1u)) return;
    if (w > VCAMNDI_MAX_W || h > VCAMNDI_MAX_H) return;
    uint32_t rowBytes = w * 2u;

    uint32_t idx = p->writeIndex;
    uint8_t *slot = p->base + vcamndi_slot_offset(idx);
    memcpy(slot, src, (size_t)rowBytes * h);                 // src is packed UYVY

    if (p->hdr->width != w || p->hdr->height != h || p->hdr->magic != VCAMNDI_MAGIC) {
        p->hdr->width = w; p->hdr->height = h;
        p->hdr->rowBytes = rowBytes; p->hdr->fourcc = VCAMNDI_FOURCC_2VUY;
        atomic_thread_fence(memory_order_release);
        p->hdr->configGen = p->hdr->configGen + 1;
        p->hdr->magic = VCAMNDI_MAGIC;
    }

    uint64_t seq = p->hdr->frameSeq;
    p->hdr->frameSeq = seq + 1;                 // -> odd (write in progress)
    atomic_thread_fence(memory_order_release);
    p->hdr->currentIndex = idx;
    atomic_thread_fence(memory_order_release);
    p->hdr->frameSeq = seq + 2;                 // -> even, new frame id

    p->writeIndex = (idx + 1) % VCAMNDI_RING;
}

// ---- Capture/convert decoupling ------------------------------------------
// The NDI capture thread must stay responsive or the sender drops the connection, so it only
// does a fast packed copy of the latest frame into a hand-off buffer (latest wins; older
// unconsumed frames are overwritten) and signals the converter. The converter thread does the
// heavy UYVY->NV12 + publish. gPub is shared; only the converter touches the ring.
static VCamNDIPublisher gPub;
static pthread_mutex_t  gRawLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_semaphore_t gRawSignal;
static uint8_t  *gRawBuf = NULL;       // packed UYVY, capacity VCAMNDI_SLOT_BYTES
static uint32_t  gRawW = 0, gRawH = 0;
static uint64_t  gRawSeq = 0;          // bumped on each new captured frame
static volatile int gConverterRun = 1;

// Capture thread: fast packed copy + signal. Returns quickly so capture_v2 is called again soon.
static void handoff_raw(const NDIlib_video_frame_v2_t *vid) {
    uint32_t w = (uint32_t)vid->xres, h = (uint32_t)vid->yres;
    if (w < 2 || h < 2 || (w & 1u) || (h & 1u)) return;
    if (w > VCAMNDI_MAX_W || h > VCAMNDI_MAX_H) return;
    uint32_t dstStride = w * 2u;      // UYVY
    int srcStride = vid->line_stride_in_bytes ? vid->line_stride_in_bytes : (int)dstStride;
    const uint8_t *src = vid->p_data;
    if (!src) return;

    pthread_mutex_lock(&gRawLock);
    for (uint32_t y = 0; y < h; y++)
        memcpy(gRawBuf + (size_t)y * dstStride, src + (size_t)y * srcStride, dstStride);
    gRawW = w; gRawH = h; gRawSeq++;
    pthread_mutex_unlock(&gRawLock);
    dispatch_semaphore_signal(gRawSignal);
}

static void *converter_main(void *arg) {
    uint8_t *local = malloc(VCAMNDI_SLOT_BYTES);
    uint64_t lastSeq = 0;
    while (gConverterRun) {
        dispatch_semaphore_wait(gRawSignal, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
        uint32_t w = 0, h = 0;
        pthread_mutex_lock(&gRawLock);
        if (gRawSeq == lastSeq || !local) { pthread_mutex_unlock(&gRawLock); continue; }
        lastSeq = gRawSeq; w = gRawW; h = gRawH;
        memcpy(local, gRawBuf, (size_t)w * h * 2u);      // snapshot packed UYVY
        pthread_mutex_unlock(&gRawLock);
        pub_write_packed(&gPub, local, w, h);
    }
    if (local) free(local);
    return NULL;
}


typedef struct {
    NSString *source;    // substring match, or nil
    NSString *url;       // explicit ip:port, or nil
    NSString *extraIps;  // comma-separated IPs for unicast discovery, or nil
    BOOL enabled;
} VCamNDIConfig;

static VCamNDIConfig readConfig(void) {
    VCamNDIConfig c = { .source = nil, .url = nil, .extraIps = nil, .enabled = YES };
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
    if ([d isKindOfClass:NSDictionary.class]) {
        if ([d[@"source"]    isKindOfClass:NSString.class]) c.source   = d[@"source"];
        if ([d[@"url"]       isKindOfClass:NSString.class]) c.url      = d[@"url"];
        if ([d[@"extra_ips"] isKindOfClass:NSString.class]) c.extraIps = d[@"extra_ips"];
        if (d[@"enabled"] != nil) c.enabled = [d[@"enabled"] boolValue];
    }
    return c;
}

static void fourccToStr(int fcc, char out[5]) {
    out[0] = (char)(fcc & 0xff);  out[1] = (char)((fcc >> 8) & 0xff);
    out[2] = (char)((fcc >> 16) & 0xff); out[3] = (char)((fcc >> 24) & 0xff); out[4] = 0;
}

// Append-only event log (NSLog doesn't reach a file for a RootHide daemon; this does, like the
// stats). One read shows the whole connection lifecycle. Capped so it can't grow unbounded.
static NSString *const kEventsFile = @"/var/mobile/Media/DCIM/vcam_ndi_events.txt";
static void ev(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterNoStyle
                                       timeStyle:NSDateFormatterMediumStyle], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kEventsFile];
    if (!fh || [fh seekToEndOfFile] > 200000) {   // (re)create if missing or too big
        [fh closeFile];
        [line writeToFile:kEventsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (id e) {}
    [fh closeFile];
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

// Discovery diagnostics: how many NDI sources the finder currently sees, their names, and
// whether unicast extra_ips is active. Written to the stats file every search iteration so the
// discovery problem is visible without a working log channel.
static void writeStatsSearching(uint32_t nSources, NSString *names, NSString *extraIps) {
    NSMutableString *s = [NSMutableString stringWithCapacity:512];
    [s appendFormat:@"=== vcam-ndi milestone2 @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"state=searching\n"];
    [s appendFormat:@"discovery=%@\n", extraIps.length ? [@"extra_ips " stringByAppendingString:extraIps]
                                                       : @"mDNS only"];
    [s appendFormat:@"sourcesFound=%u\n", nSources];
    [s appendFormat:@"sources=%@\n", names.length ? names : @"(none)"];
    [s appendFormat:@"--- if sourcesFound=0 ---\n"];
    [s appendFormat:@"mDNS/multicast is blocked. Set extra_ips to the sender's IP in\n"];
    [s appendFormat:@"/var/mobile/Media/DCIM/vcam_ndi.plist and reconnect.\n"];
    [s writeToFile:kStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Richer stats for the live connection: adds receive/drop/queue + arrival jitter + thermal
// so network vs CPU vs code can be told apart.
static void writeStatsConnected(NSString *sourceName, int xres, int yres, int fourcc,
                                double fps, unsigned long long frames,
                                long long recvTotal, long long recvDropped, long long droppedDelta,
                                int queueDepth, double maxGapMs) {
    char fcc[5] = {0}; fourccToStr(fourcc, fcc);
    const char *thermal = "nominal";
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateFair:     thermal = "fair"; break;
        case NSProcessInfoThermalStateSerious:  thermal = "serious"; break;
        case NSProcessInfoThermalStateCritical: thermal = "critical"; break;
        default: break;
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:640];
    [s appendFormat:@"=== vcam-ndi milestone2 @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"state=%@\n", frames ? @"connected" : @"connected-nodata"];
    [s appendFormat:@"source=%@\n", sourceName.length ? sourceName : @"(none)"];
    [s appendFormat:@"frame=%dx%d fourcc=%s\n", xres, yres, fcc];
    [s appendFormat:@"publishFps=%.2f framesTotal=%llu\n", fps, frames];
    [s appendFormat:@"--- receive health ---\n"];
    [s appendFormat:@"recvTotal=%lld recvDropped=%lld droppedThisSec=%lld\n",
        recvTotal, recvDropped, droppedDelta];
    [s appendFormat:@"queueDepth=%d  maxArrivalGapMs=%.1f\n", queueDepth, maxGapMs];
    [s appendFormat:@"thermalState=%s\n", thermal];
    [s appendFormat:@"--- how to read ---\n"];
    [s appendFormat:@"droppedThisSec>0  -> frames lost (network or we drain too slow)\n"];
    [s appendFormat:@"queueDepth rising -> daemon decode/copy too slow (CPU)\n"];
    [s appendFormat:@"maxGapMs >> 33    -> network stall/jitter (bursty delivery)\n"];
    [s writeToFile:kStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[vcam-ndi] starting");
        ev(@"=== daemon starting ===");

        if (!NDIlib_initialize()) {
            NSLog(@"[vcam-ndi] NDIlib_initialize failed (unsupported CPU?)");
            writeStats(@"ndi-init-failed", nil, 0, 0, 0, 0, 0);
            // Sleep rather than exit, so KeepAlive doesn't crash-loop us.
            [NSThread sleepForTimeInterval:30]; return 1;
        }

        BOOL pubOK = pub_open(&gPub);
        if (!pubOK) NSLog(@"[vcam-ndi] continuing without shm publish");

        // Start the converter thread + hand-off buffer (keeps the capture thread tight).
        pthread_t convThread = 0;
        if (pubOK) {
            gRawBuf = malloc(VCAMNDI_SLOT_BYTES);
            gRawSignal = dispatch_semaphore_create(0);
            if (!gRawBuf || !gRawSignal ||
                pthread_create(&convThread, NULL, converter_main, NULL) != 0) {
                NSLog(@"[vcam-ndi] converter thread start failed; no shm publish");
                pubOK = NO;
            }
        }

        int token;
        notify_register_dispatch(kNoteReload, &token,
                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                 ^(int t){ (void)t; gReload = 1; });

        // The finder is (re)created inside the loop so an extra_ips change (unicast discovery
        // bypassing mDNS multicast) takes effect without a daemon restart.
        NDIlib_find_instance_t finder = NULL;
        NSString *curExtraIps = nil;

        unsigned long long framesTotal = 0;

        while (1) {
            @autoreleasepool {
                gReload = 0;
                VCamNDIConfig cfg = readConfig();

                if (!cfg.enabled) {
                    if (pubOK) pub_set_enabled(&gPub, NO);
                    writeStats(@"disabled", nil, 0, 0, 0, 0.0, framesTotal);
                    for (int i = 0; i < 10 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // (Re)create the finder if extra_ips changed (or first time).
                NSString *wantExtra = cfg.extraIps ?: @"";
                if (!finder || ![curExtraIps isEqualToString:wantExtra]) {
                    if (finder) NDIlib_find_destroy(finder);
                    NDIlib_find_create_t fc = { .show_local_sources = true, .p_groups = NULL,
                        .p_extra_ips = wantExtra.length ? wantExtra.UTF8String : NULL };
                    finder = NDIlib_find_create_v2(&fc);
                    curExtraIps = wantExtra;
                    ev(@"finder created (extra_ips=%@)", wantExtra.length ? wantExtra : @"mDNS");
                    NSLog(@"[vcam-ndi] finder created (extra_ips=%@)",
                          wantExtra.length ? wantExtra : @"(mDNS only)");
                    if (!finder) {
                        writeStats(@"find-create-failed", nil, 0, 0, 0, 0.0, framesTotal);
                        for (int i = 0; i < 10 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                        continue;
                    }
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
                    NDIlib_find_wait_for_sources(finder, 2000);
                    uint32_t n = 0;
                    const NDIlib_source_t *srcs = NDIlib_find_get_current_sources(finder, &n);
                    // Record how many sources the finder sees + their names, so the stats file
                    // shows whether discovery (mDNS or extra_ips unicast) is working at all.
                    NSMutableString *names = [NSMutableString string];
                    const NDIlib_source_t *pick = NULL;
                    for (uint32_t i = 0; i < n; i++) {
                        NSString *nm = srcs[i].p_ndi_name
                            ? [NSString stringWithUTF8String:srcs[i].p_ndi_name] : @"";
                        if (i < 6) [names appendFormat:@"%@%@", names.length ? @", " : @"", nm];
                        if (!pick) {
                            if (!cfg.source.length) { pick = &srcs[i]; chosenName = nm; }
                            else if ([nm localizedCaseInsensitiveContainsString:cfg.source]) {
                                pick = &srcs[i]; chosenName = nm;
                            }
                        }
                    }
                    // A `source` filter is a preference, not a hard gate: if it matches nothing
                    // but a source exists, use the first one rather than searching forever (a
                    // stale/placeholder filter must never wedge discovery).
                    if (!pick && n > 0) {
                        pick = &srcs[0];
                        chosenName = srcs[0].p_ndi_name ? @(srcs[0].p_ndi_name) : @"(unnamed)";
                        NSLog(@"[vcam-ndi] source filter '%@' matched nothing; using first: %@",
                              cfg.source, chosenName);
                    }
                    writeStatsSearching(n, names, curExtraIps);
                    if (!pick) {
                        for (int i = 0; i < 5 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                        continue;
                    }
                    chosen = *pick;
                }

                ev(@"connecting to '%@'", chosenName);
                NSLog(@"[vcam-ndi] connecting to %@ (pubOK=%d fileSize=%llu)",
                      chosenName, pubOK, (unsigned long long)VCAMNDI_FILE_SIZE);
                NDIlib_recv_create_v3_t rcreate = {
                    .source_to_connect_to = chosen,
                    // 'fastest' = UYVY native: no conversion in the NDI process, which keeps the
                    // A11's connection stable (converted formats starved the network thread).
                    .color_format = NDIlib_recv_color_format_fastest,
                    .bandwidth    = NDIlib_recv_bandwidth_highest,
                    .allow_video_fields = true,
                    .p_ndi_recv_name = "VCamNDI",
                };
                NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&rcreate);
                if (!recv) {
                    ev(@"recv_create FAILED");
                    writeStats(@"recv-create-failed", chosenName, 0, 0, 0, 0.0, framesTotal);
                    for (int i = 0; i < 10 && !gReload; i++) [NSThread sleepForTimeInterval:0.1];
                    continue;
                }
                ev(@"recv_create ok; entering capture loop");

                // Capture loop for this connection.
                double lastStat = NSProcessInfo.processInfo.systemUptime;
                unsigned long long framesAtLastStat = framesTotal;
                int lastX = 0, lastY = 0, lastFourCC = 0;
                double measuredFps = 0.0;
                BOOL stayConnected = YES;
                double lastArrival = 0.0, maxGapMs = 0.0;   // inter-frame jitter in window
                long long droppedAtLastStat = 0;
                BOOL loggedFirstFrame = NO;

                while (stayConnected && !gReload) {
                    @autoreleasepool {
                        NDIlib_video_frame_v2_t vid = {0};
                        NDIlib_frame_type_e type =
                            NDIlib_recv_capture_v2(recv, &vid, NULL, NULL, 1000);

                        if (type == NDIlib_frame_type_video) {
                            framesTotal++;
                            lastX = vid.xres; lastY = vid.yres; lastFourCC = (int)vid.FourCC;
                            if (!loggedFirstFrame) {
                                char fcc[5] = {0}; fourccToStr((int)vid.FourCC, fcc);
                                ev(@"first frame %dx%d fourcc=%s stride=%d (published=%d)",
                                   vid.xres, vid.yres, fcc, vid.line_stride_in_bytes,
                                   (pubOK && vid.FourCC == NDIlib_FourCC_type_UYVY));
                                NSLog(@"[vcam-ndi] first frame: %dx%d fourcc=%s stride=%d",
                                      vid.xres, vid.yres, fcc, vid.line_stride_in_bytes);
                                loggedFirstFrame = YES;
                            }
                            double nowA = NSProcessInfo.processInfo.systemUptime;
                            if (lastArrival > 0.0) {
                                double gap = (nowA - lastArrival) * 1000.0;
                                if (gap > maxGapMs) maxGapMs = gap;
                            }
                            lastArrival = nowA;
                            // Hand the frame to the publisher thread (fast copy) and free the NDI
                            // frame immediately so capture_v2 is called again promptly, keeping the
                            // NDI connection alive. 'fastest' delivers UYVY (4:2:2).
                            if (pubOK && vid.FourCC == NDIlib_FourCC_type_UYVY) {
                                pub_set_enabled(&gPub, YES);
                                handoff_raw(&vid);
                            }
                            NDIlib_recv_free_video_v2(recv, &vid);   // free immediately
                        } else if (type == NDIlib_frame_type_error) {
                            ev(@"capture returned ERROR after %llu frames -> disconnect", framesTotal);
                            stayConnected = NO;
                        }
                        // none / status_change: just keep polling.

                        double now = NSProcessInfo.processInfo.systemUptime;
                        if (now - lastStat >= 1.0) {
                            measuredFps = (double)(framesTotal - framesAtLastStat) / (now - lastStat);

                            NDIlib_recv_performance_t tot = {0}, drop = {0};
                            NDIlib_recv_get_performance(recv, &tot, &drop);
                            NDIlib_recv_queue_t q = {0};
                            NDIlib_recv_get_queue(recv, &q);
                            long long dropDelta = drop.video_frames - droppedAtLastStat;

                            writeStatsConnected(chosenName, lastX, lastY, lastFourCC,
                                                measuredFps, framesTotal,
                                                tot.video_frames, drop.video_frames, dropDelta,
                                                q.video_frames, maxGapMs);

                            lastStat = now; framesAtLastStat = framesTotal;
                            droppedAtLastStat = drop.video_frames;
                            maxGapMs = 0.0;   // reset jitter window

                            // Re-read config so enabled=false / source change takes effect.
                            VCamNDIConfig c2 = readConfig();
                            if (!c2.enabled) stayConnected = NO;
                        }
                    }
                }

                ev(@"capture loop exited (reload=%d) after %llu frames total", gReload, framesTotal);
                if (pubOK) pub_set_enabled(&gPub, NO);
                NDIlib_recv_destroy(recv);
            }
        }

        NDIlib_find_destroy(finder);
        NDIlib_destroy();
        return 0;
    }
}
