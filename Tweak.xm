// mediaserverd-side injector. In a constructor (only when process == mediaserverd) it enumerates all
// ObjC classes descending from BWNodeOutput that own an -emitSampleBuffer: implementation and
// replaces each IMP via method_setImplementation (PAC-safe), storing originals per class. The hook
// routes each frame through VCamCore.replaceInPlace: then calls the original. Installation retries
// on a detached pthread (500ms poll) until BWNodeOutput is loaded.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <pthread.h>
#import <unistd.h>
#import <stdatomic.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);

static NSMutableDictionary<NSValue *, NSValue *> *gOrigEmitByClass = nil;

_Atomic int gInstallPollCount    = 0;
_Atomic int gInstallState        = 0;
_Atomic int gInstallHookKind     = 0;
_Atomic int gInstallSubclassHits = 0;
_Atomic int gFirstClassReachedHook = 0;

static EmitFn orig_for_class(Class cls) {
    if (!gOrigEmitByClass) return NULL;
    @synchronized(gOrigEmitByClass) {
        NSValue *v = gOrigEmitByClass[[NSValue valueWithPointer:(__bridge const void *)cls]];
        return v ? (EmitFn)[v pointerValue] : NULL;
    }
}

static void hooked_emit(id _self, SEL sel, CMSampleBufferRef sb) {
    atomic_store_explicit(&gFirstClassReachedHook, 1, memory_order_relaxed);
    @autoreleasepool {
        @try {
            if (sb && [VCamCore.shared isEnabled]) {
                [VCamCore.shared replaceInPlace:sb];
            }
        } @catch (NSException *e) {
            NSLog(@"[vcam-msd] emit hook exception: %@", e);
        }
    }
    EmitFn orig = orig_for_class(object_getClass(_self));
    if (orig) orig(_self, sel, sb);
}

static BOOL hook_class_emit(Class cls) {
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    BOOL owns = NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) { owns = YES; break; }
    }
    if (list) free(list);
    if (!owns) return NO;

    IMP newImp = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
        hooked_emit(_self, @selector(emitSampleBuffer:), sb);
    });

    IMP origImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    if (!gOrigEmitByClass) gOrigEmitByClass = [NSMutableDictionary new];
    @synchronized(gOrigEmitByClass) {
        gOrigEmitByClass[[NSValue valueWithPointer:(__bridge const void *)cls]] =
            [NSValue valueWithPointer:(const void *)origImp];
    }
    return YES;
}

static int hook_all_emit_classes(void) {
    Class baseCls = objc_getClass("BWNodeOutput");
    if (!baseCls) return 0;
    int hooked = 0;

    if (hook_class_emit(baseCls)) hooked++;

    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        if (c == baseCls) continue;

        Class p = c;
        BOOL isDescendant = NO;
        while (p) {
            if (p == baseCls) { isDescendant = YES; break; }
            p = class_getSuperclass(p);
        }
        if (!isDescendant) continue;
        if (hook_class_emit(c)) hooked++;
    }
    if (all) free(all);
    return hooked;
}

static BOOL try_install(void) {
    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) return NO;
    atomic_store_explicit(&gInstallState, 1, memory_order_relaxed);
    int n = hook_all_emit_classes();
    atomic_store_explicit(&gInstallSubclassHits, n, memory_order_relaxed);
    if (n == 0) {
        atomic_store_explicit(&gInstallState, 2, memory_order_relaxed);
        return NO;
    }
    atomic_store_explicit(&gInstallState, 3, memory_order_relaxed);
    atomic_store_explicit(&gInstallHookKind, 1, memory_order_relaxed);
    NSLog(@"[vcam-msd] hooked %d emit-implementing classes", n);
    return YES;
}

static void *install_thread_main(void *_unused) {
    while (1) {
        atomic_fetch_add_explicit(&gInstallPollCount, 1, memory_order_relaxed);
        if (try_install()) return NULL;
        usleep(500 * 1000);
    }
    return NULL;
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) return;
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.7.6, broad subclass hook)");
        NSLog(@"[vcam-msd] To activate: touch /var/mobile/Media/DCIM/vcam_msd_active");
        NSLog(@"[vcam-msd] Stats: /var/mobile/Media/DCIM/vcam_msd_stats.txt (every 5s)");
        (void)[VCamCore shared];

        if (try_install()) return;

        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&th, &attr, install_thread_main, NULL);
        pthread_attr_destroy(&attr);
    }
}
