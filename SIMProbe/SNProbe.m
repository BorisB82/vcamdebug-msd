#import "SNProbe.h"

#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <netinet/in.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#pragma mark - small helpers

static NSDictionary *Row(NSString *k, NSString *v, SNTier tier, NSString *note) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"k"] = k ?: @"?";
    d[@"v"] = v.length ? v : @"(empty / nil)";
    d[@"tier"] = @(tier);
    if (note.length) d[@"note"] = note;
    return d;
}

static NSDictionary *Section(NSString *title, NSArray *rows) {
    return @{ @"title": title ?: @"", @"rows": rows ?: @[] };
}

static BOOL AllDigits(NSString *s) {
    if (!s.length) return NO;
    NSCharacterSet *non = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [s rangeOfCharacterFromSet:non].location == NSNotFound;
}

// iOS 16 returns these fixed placeholders from the deprecated CTCarrier API to ALL apps.
static BOOL LooksLikePlaceholder(NSString *s) {
    if (!s.length) return YES;
    return [s isEqualToString:@"65535"] || [s isEqualToString:@"--"];
}

#pragma mark - SNProbe

@implementation SNProbe

+ (NSArray<NSDictionary *> *)collectSections {
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:[self environmentSection]];
    [sections addObject:[self carrierSection]];
    [sections addObject:[self radioSection]];
    [sections addObject:[self connectivitySection]];
    [sections addObject:[self regionSection]];
    [sections addObject:[self mobileGestaltSection]];
    [sections addObjectsFromArray:[self commCenterSections]];
    return sections;
}

#pragma mark environment

+ (NSString *)sysctlString:(const char *)name {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return nil;
    char *buf = malloc(len);
    NSString *out = nil;
    if (sysctlbyname(name, buf, &len, NULL, 0) == 0) out = [NSString stringWithUTF8String:buf];
    free(buf);
    return out;
}

+ (NSDictionary *)environmentSection {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:Row(@"iOS version", UIDevice.currentDevice.systemVersion, SNTierInfo, nil)];
    [rows addObject:Row(@"Model id", [self sysctlString:"hw.machine"] ?: @"?", SNTierInfo, nil)];

    // Can THIS process read a file outside an app container? (It should: it runs as a platform app.)
    // A normal sandboxed app gets EACCES/EPERM here — that is the whole point of the root rows below.
    const char *probe = "/var/mobile/Library/Preferences";
    BOOL outsideContainer = (access(probe, R_OK) == 0);
    [rows addObject:Row(@"This app is sandboxed?",
                        outsideContainer ? @"NO — running unsandboxed (platform-application)"
                                         : @"YES — confined to its container",
                        SNTierInfo,
                        @"This build runs unsandboxed on purpose, to reveal the root rows. A normal "
                        @"App Store app WOULD be sandboxed and could not read any 🔴 ROOT row below.")];
    return Section(@"Environment", rows);
}

#pragma mark CoreTelephony — carrier (public API)

+ (NSDictionary *)carrierSection {
    NSMutableArray *rows = [NSMutableArray array];
    CTTelephonyNetworkInfo *ni = [CTTelephonyNetworkInfo new];

    NSDictionary<NSString *, CTCarrier *> *carriers = nil;
    @try { carriers = ni.serviceSubscriberCellularProviders; } @catch (__unused id e) {}

    if (carriers.count == 0) {
        [rows addObject:Row(@"serviceSubscriberCellularProviders", @"(none returned)", SNTierPublic,
                            @"No SIM services reported by the public API.")];
        return Section(@"CoreTelephony — Carrier  (public CTCarrier API)", rows);
    }

    NSInteger idx = 0;
    for (NSString *svc in carriers) {
        CTCarrier *c = carriers[svc];
        NSString *slot = [NSString stringWithFormat:@"SIM %ld", (long)(++idx)];

        NSString *name = c.carrierName;
        [rows addObject:Row([NSString stringWithFormat:@"%@ · carrierName", slot], name,
                            LooksLikePlaceholder(name) ? SNTierPublicRandomized : SNTierPublic,
                            LooksLikePlaceholder(name) ? @"Placeholder — iOS 16 hides this at the API level (same for root)." : nil)];

        NSString *mcc = c.mobileCountryCode;
        [rows addObject:Row([NSString stringWithFormat:@"%@ · MCC (country)", slot], mcc,
                            LooksLikePlaceholder(mcc) ? SNTierPublicRandomized : SNTierPublic,
                            [mcc isEqualToString:@"65535"] ? @"65535 = iOS 16 placeholder; real MCC hidden for all apps." : nil)];

        NSString *mnc = c.mobileNetworkCode;
        [rows addObject:Row([NSString stringWithFormat:@"%@ · MNC (network)", slot], mnc,
                            LooksLikePlaceholder(mnc) ? SNTierPublicRandomized : SNTierPublic,
                            [mnc isEqualToString:@"65535"] ? @"65535 = iOS 16 placeholder." : nil)];

        NSString *iso = c.isoCountryCode;
        [rows addObject:Row([NSString stringWithFormat:@"%@ · ISO country", slot], iso,
                            LooksLikePlaceholder(iso) ? SNTierPublicRandomized : SNTierPublic, nil)];

        [rows addObject:Row([NSString stringWithFormat:@"%@ · allowsVOIP", slot],
                            c.allowsVOIP ? @"YES" : @"NO", SNTierPublic, nil)];
    }
    return Section(@"CoreTelephony — Carrier  (public CTCarrier API)", rows);
}

#pragma mark CoreTelephony — radio (public API, not randomized)

+ (NSString *)prettyRAT:(NSString *)rat {
    if (!rat.length) return @"(none)";
    NSDictionary *map = @{
        CTRadioAccessTechnologyGPRS: @"GPRS (2G)",
        CTRadioAccessTechnologyEdge: @"EDGE (2G)",
        CTRadioAccessTechnologyWCDMA: @"WCDMA (3G)",
        CTRadioAccessTechnologyHSDPA: @"HSDPA (3G)",
        CTRadioAccessTechnologyHSUPA: @"HSUPA (3G)",
        CTRadioAccessTechnologyCDMA1x: @"CDMA 1x (2G)",
        CTRadioAccessTechnologyCDMAEVDORev0: @"EVDO r0 (3G)",
        CTRadioAccessTechnologyCDMAEVDORevA: @"EVDO rA (3G)",
        CTRadioAccessTechnologyCDMAEVDORevB: @"EVDO rB (3G)",
        CTRadioAccessTechnologyeHRPD: @"eHRPD (3G)",
        CTRadioAccessTechnologyLTE: @"LTE (4G)",
    };
    if (@available(iOS 14.1, *)) {
        if ([rat isEqualToString:CTRadioAccessTechnologyNRNSA]) return @"5G NSA";
        if ([rat isEqualToString:CTRadioAccessTechnologyNR])    return @"5G SA";
    }
    NSString *p = map[rat];
    if (p) return p;
    // strip the "CTRadioAccessTechnology" prefix for anything unmapped
    return [rat stringByReplacingOccurrencesOfString:@"CTRadioAccessTechnology" withString:@""];
}

+ (NSDictionary *)radioSection {
    NSMutableArray *rows = [NSMutableArray array];
    CTTelephonyNetworkInfo *ni = [CTTelephonyNetworkInfo new];

    NSDictionary<NSString *, NSString *> *rats = nil;
    @try { rats = ni.serviceCurrentRadioAccessTechnology; } @catch (__unused id e) {}

    if (rats.count == 0) {
        [rows addObject:Row(@"Radio access technology", @"(none reported)", SNTierPublic, nil)];
    } else {
        NSInteger idx = 0;
        for (NSString *svc in rats) {
            [rows addObject:Row([NSString stringWithFormat:@"SIM %ld · data radio", (long)(++idx)],
                                [self prettyRAT:rats[svc]], SNTierPublic,
                                @"Not randomized — the connection generation IS visible to any app.")];
        }
    }
    if (@available(iOS 13.0, *)) {
        NSString *dsi = nil;
        @try { dsi = ni.dataServiceIdentifier; } @catch (__unused id e) {}
        [rows addObject:Row(@"Data service identifier", dsi ?: @"(nil)", SNTierPublic,
                            @"Which SIM service currently carries cellular data.")];
    }
    return Section(@"CoreTelephony — Radio  (public, NOT randomized)", rows);
}

#pragma mark connectivity (public — getifaddrs + reachability)

+ (NSDictionary *)connectivitySection {
    NSMutableArray *rows = [NSMutableArray array];

    // Default-route reachability: the WWAN flag tells any app whether the path is cellular.
    SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithName(NULL, "apple.com");
    if (r) {
        SCNetworkReachabilityFlags f = 0;
        if (SCNetworkReachabilityGetFlags(r, &f)) {
            BOOL reachable = (f & kSCNetworkReachabilityFlagsReachable) != 0;
            BOOL wwan = (f & kSCNetworkReachabilityFlagsIsWWAN) != 0;
            [rows addObject:Row(@"Default route", reachable ? (wwan ? @"Cellular (WWAN)" : @"Wi-Fi / other")
                                                            : @"Not reachable", SNTierPublic,
                                @"SCNetworkReachability — any sandboxed app can read this.")];
        }
        CFRelease(r);
    }

    // Interface addresses: pdp_ipN = cellular data interface. Its presence/IP = cellular is up.
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        BOOL anyCell = NO;
        for (struct ifaddrs *ifa = ifs; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr) continue;
            int fam = ifa->ifa_addr->sa_family;
            if (fam != AF_INET && fam != AF_INET6) continue;
            NSString *name = @(ifa->ifa_name);
            BOOL isCell = [name hasPrefix:@"pdp_ip"];
            BOOL isWifi = [name isEqualToString:@"en0"];
            if (!isCell && !isWifi) continue;

            char ip[INET6_ADDRSTRLEN] = {0};
            void *addr = (fam == AF_INET)
                ? (void *)&((struct sockaddr_in *)ifa->ifa_addr)->sin_addr
                : (void *)&((struct sockaddr_in6 *)ifa->ifa_addr)->sin6_addr;
            inet_ntop(fam, addr, ip, sizeof(ip));
            if (isCell) anyCell = YES;
            [rows addObject:Row([NSString stringWithFormat:@"%@ (%@)", name, isCell ? @"cellular" : @"wifi"],
                                @(ip), SNTierPublic,
                                isCell ? @"Cellular data interface has an IP → cellular is active." : nil)];
        }
        if (!anyCell)
            [rows addObject:Row(@"Cellular data interface (pdp_ip*)", @"(none — cellular data down)",
                                SNTierPublic, nil)];
        freeifaddrs(ifs);
    }
    return Section(@"Connectivity  (public — getifaddrs / reachability)", rows);
}

#pragma mark device region (public, NOT SIM)

+ (NSDictionary *)regionSection {
    NSMutableArray *rows = [NSMutableArray array];
    NSLocale *loc = [NSLocale currentLocale];
    [rows addObject:Row(@"Region", [loc objectForKey:NSLocaleCountryCode] ?: @"?", SNTierInfo,
                        @"Device SETTING, not SIM-derived. Apps often mistake this for SIM country.")];
    [rows addObject:Row(@"Language", [[NSLocale preferredLanguages] firstObject] ?: @"?", SNTierInfo, nil)];
    [rows addObject:Row(@"Currency", [loc objectForKey:NSLocaleCurrencyCode] ?: @"?", SNTierInfo, nil)];
    [rows addObject:Row(@"Uses metric", [[loc objectForKey:NSLocaleUsesMetricSystem] boolValue] ? @"YES" : @"NO",
                        SNTierInfo, nil)];
    return Section(@"Device region  (public — a SETTING, not the SIM)", rows);
}

#pragma mark MobileGestalt (private — root / entitlement)

+ (NSDictionary *)mobileGestaltSection {
    NSMutableArray *rows = [NSMutableArray array];

    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!h) h = dlopen("libMobileGestalt.dylib", RTLD_NOW);
    CFTypeRef (*MGCopyAnswer)(CFStringRef) = h ? dlsym(h, "MGCopyAnswer") : NULL;

    if (!MGCopyAnswer) {
        [rows addObject:Row(@"MGCopyAnswer", @"unavailable", SNTierRoot,
                            @"libMobileGestalt is a private API — a sandboxed app cannot link it at all.")];
        return Section(@"MobileGestalt  (🔴 private API — root/entitlement)", rows);
    }

    // Some keys are open; identity keys are protected and return nil without the
    // com.apple.private.MobileGestalt.AllowedProtectedKeys entitlement (we request it, but the
    // jailbreak may or may not honour it — nil just means still protected).
    NSArray *keys = @[
        @"UniqueDeviceID", @"SerialNumber",
        @"InternationalMobileEquipmentIdentity", @"InternationalMobileEquipmentIdentity2",
        @"MobileEquipmentIdentifier",
        @"IntegratedCircuitCardIdentity", @"InternationalMobileSubscriberIdentity",
    ];
    for (NSString *key in keys) {
        id val = CFBridgingRelease(MGCopyAnswer((__bridge CFStringRef)key));
        NSString *str = [val isKindOfClass:NSString.class] ? val
                      : (val ? [val description] : nil);
        [rows addObject:Row(key, str ?: @"nil (protected — still hidden)", SNTierRoot,
                            @"Private API; off-limits to any sandboxed app.")];
    }
    return Section(@"MobileGestalt  (🔴 private API — root/entitlement)", rows);
}

#pragma mark CommCenter plists (root — sandbox blocks these)

// Recursively collect string/number leaves AND dictionary keys (ICCIDs are often keys).
static void CollectLeaves(id obj, NSMutableArray *out) {
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id k in (NSDictionary *)obj) {
            if ([k isKindOfClass:NSString.class]) [out addObject:k];
            CollectLeaves(((NSDictionary *)obj)[k], out);
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id e in (NSArray *)obj) CollectLeaves(e, out);
    } else if ([obj isKindOfClass:NSString.class]) {
        [out addObject:obj];
    } else if ([obj isKindOfClass:NSNumber.class]) {
        [out addObject:[obj stringValue]];
    }
}

+ (NSArray<NSDictionary *> *)commCenterSections {
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.apple.commcenter.plist",
        @"/var/mobile/Library/Preferences/com.apple.commcenter.counts.plist",
        @"/var/wireless/Library/Preferences/com.apple.commcenter.plist",
        @"/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist",
    ];

    NSMutableArray *sections = [NSMutableArray array];
    NSMutableSet *iccids = [NSMutableSet set];
    NSMutableSet *imsis  = [NSMutableSet set];
    NSMutableSet *phones = [NSMutableSet set];

    for (NSString *path in paths) {
        NSMutableArray *rows = [NSMutableArray array];
        NSString *shortName = path.lastPathComponent;

        if (access(path.fileSystemRepresentation, R_OK) != 0) {
            int e = errno;
            [rows addObject:Row(@"access()",
                                [NSString stringWithFormat:@"DENIED — errno %d (%s)", e, strerror(e)],
                                SNTierRoot,
                                @"This is exactly what a sandboxed app gets for this path.")];
            [sections addObject:Section([@"🔴 " stringByAppendingString:shortName], rows)];
            continue;
        }

        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!plist) {
            [rows addObject:Row(@"read", @"readable, but not a parseable dictionary", SNTierRoot, nil)];
            [sections addObject:Section([@"🔴 " stringByAppendingString:shortName], rows)];
            continue;
        }

        NSMutableArray *leaves = [NSMutableArray array];
        CollectLeaves(plist, leaves);
        for (NSString *s in leaves) {
            if (![s isKindOfClass:NSString.class]) continue;
            if ([s hasPrefix:@"89"] && AllDigits(s) && s.length >= 18 && s.length <= 22) [iccids addObject:s];
            else if (AllDigits(s) && s.length >= 14 && s.length <= 16) [imsis addObject:s];
            else if ([s hasPrefix:@"+"] && s.length >= 8 && s.length <= 17 &&
                     AllDigits([s substringFromIndex:1])) [phones addObject:s];
        }

        NSArray *topKeys = [plist.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSString *keyList = [topKeys componentsJoinedByString:@", "];
        if (keyList.length > 400) keyList = [[keyList substringToIndex:400] stringByAppendingString:@" …"];
        [rows addObject:Row([NSString stringWithFormat:@"readable ✓  (%lu top-level keys)", (unsigned long)topKeys.count],
                            keyList, SNTierRoot,
                            @"A sandboxed app CANNOT open this file (sandbox denies it, even though the "
                            @"file's own permissions would allow the read).")];
        [sections addObject:Section([@"🔴 " stringByAppendingString:shortName], rows)];
    }

    // Harvested real identifiers — the values the public CTCarrier API refuses to give anyone.
    NSMutableArray *idRows = [NSMutableArray array];
    for (NSString *v in iccids)
        [idRows addObject:Row(@"ICCID (SIM serial)", v, SNTierRoot,
                              @"The real SIM identity. Public API never exposes this.")];
    for (NSString *v in imsis)
        [idRows addObject:Row(@"IMSI candidate", v, SNTierRoot, @"15-digit subscriber id (MCC+MNC+MSIN).")];
    for (NSString *v in phones)
        [idRows addObject:Row(@"Phone number candidate", v, SNTierRoot, nil)];
    if (idRows.count == 0)
        [idRows addObject:Row(@"Harvested identifiers", @"(none matched — see raw keys above)", SNTierRoot, nil)];
    [sections insertObject:Section(@"🔴 Real SIM identifiers  (harvested from CommCenter)", idRows)
                   atIndex:0];

    return sections;
}

#pragma mark text dump

+ (NSString *)plainTextDump:(NSArray<NSDictionary *> *)sections {
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *sec in sections) {
        [s appendFormat:@"\n== %@ ==\n", sec[@"title"]];
        for (NSDictionary *row in sec[@"rows"]) {
            [s appendFormat:@"  %@: %@\n", row[@"k"], row[@"v"]];
            if (row[@"note"]) [s appendFormat:@"      ↳ %@\n", row[@"note"]];
        }
    }
    return s;
}

@end
