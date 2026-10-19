// NovaShield: performance and thermal rescue for SpringBoard (rootless, iOS 15+).
//
// What it does, in short:
//  * While the screen is ON it checks CPU load, memory use and thermal state every 5 s (every 10 s while all is calm).
//  * While the screen is OFF it runs nothing at all: the timer is cancelled, nothing is scheduled, and
//    anything NovaShield paused is resumed first. Standby battery is not touched.
//  * When the load stays too high (or the phone gets hot) it runs Boost & Cool by itself: it clears memory
//    caches, closes safe background apps and pauses background analysis daemons for a while.
//  * Only after a boost that really changed something, a tiny glass pill with green ticks shows the proof
//    for a couple of seconds. There are no buttons, dialogs or taps.
//
// Honest limits (iOS sandboxing): SpringBoard runs as the "mobile" user, so NovaShield can only pause
// daemons owned by mobile, never root daemons such as thermalmonitord, and it cannot change kernel
// thermal management or the I2C bus. It reduces the load that causes those problems.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <signal.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/resource.h>
#import <unistd.h>

#define NV_DOMAIN CFSTR("com.kwarnu.novashield")
#define NV_NOTIFY_PREFS "com.kwarnu.novashield/prefschanged"
#define NV_NOTIFY_TESTHUD "com.kwarnu.novashield/testhud"
#define NV_NOTIFY_RESPRING "com.kwarnu.novashield/respring"
#define NV_NOTIFY_BLANKED "com.apple.springboard.hasBlankedScreen"

static const NSTimeInterval kPollFast = 5.0;         // seconds between samples while the load is high or unsettled
static const NSTimeInterval kPollSlow = 10.0;        // seconds between samples once everything has been calm
static const int kCalmChecksForSlow = 6;             // calm samples in a row before sampling slows down
static const int kOverChecksNeeded = 2;              // consecutive high samples before an automatic boost
static const double kMemoryLimit = 92.0;             // memory saturation (%) that counts as "high"
static const NSTimeInterval kBoostCooldown = 90.0;   // an automatic boost runs at most this often
static const NSTimeInterval kFreezeSeconds = 90.0;   // how long paused daemons stay paused per boost
static const NSTimeInterval kGamingBoostDelay = 5.0; // wait after a game opens so it can finish loading

#pragma mark - Settings

typedef struct {
    BOOL enabled;
    double threshold;      // CPU warning threshold, percent
    BOOL gaming;           // auto boost for games and calls
    NSInteger hudPosition; // 0 = top, 1 = bottom
    double hudDuration;    // seconds the tick indicator stays on screen
    BOOL showIndicator;    // show the small tick indicator after an automatic boost
    BOOL warnMemory;
    BOOL closeApps;
    BOOL pauseDaemons;
} NVConfig;

static NVConfig cfg = {
    .enabled = YES, .threshold = 80, .gaming = YES, .hudPosition = 0, .hudDuration = 2.5, .showIndicator = YES,
    .warnMemory = YES, .closeApps = YES, .pauseDaemons = YES,
};

static NSSet<NSString *> *gGamingApps;   // apps that trigger Gaming Optimization Mode

static id NVPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, NV_DOMAIN));
}

static BOOL NVBoolPref(NSString *key, BOOL fallback) {
    id v = NVPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static double NVNumberPref(NSString *key, double fallback, double lo, double hi) {
    id v = NVPref(key);
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
    return MIN(hi, MAX(lo, d));
}

static void NVLoadConfig(void) {
    CFPreferencesAppSynchronize(NV_DOMAIN);
    cfg.enabled = NVBoolPref(@"enabled", YES);
    cfg.threshold = NVNumberPref(@"threshold", 80, 60, 95);
    cfg.gaming = NVBoolPref(@"gaming", YES);
    cfg.hudPosition = (NSInteger)NVNumberPref(@"hudPosition", 0, 0, 1);
    cfg.hudDuration = NVNumberPref(@"hudDuration", 2.5, 1.5, 6);
    cfg.showIndicator = NVBoolPref(@"showIndicator", YES);
    cfg.warnMemory = NVBoolPref(@"warnMemory", YES);
    cfg.closeApps = NVBoolPref(@"closeApps", YES);
    cfg.pauseDaemons = NVBoolPref(@"pauseDaemons", YES);

    // Advanced, no UI: write an array of bundle IDs to "gamingApps" to replace the built-in list.
    NSArray *custom = NVPref(@"gamingApps");
    if ([custom isKindOfClass:NSArray.class] && custom.count) {
        gGamingApps = [NSSet setWithArray:custom];
    } else {
        gGamingApps = [NSSet setWithArray:@[
            @"com.mobile.legends", @"com.moonton.mobilelegends", @"com.moonton.MobileLegends",
            @"ph.telegra.Telegraph", @"org.telegram.TelegramHD", @"org.telegram.Telegram-iOS",
            @"com.apple.facetime",
        ]];
    }
}

#pragma mark - SpringBoard helpers (private APIs, always looked up at runtime)

static id NVShared(const char *className, NSString *selectorName) {
    Class cls = objc_getClass(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static NSString *NVStringFrom(id object, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, sel);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id NVFrontApp(void) {
    id application = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![application respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(application, sel);
}

static NSString *NVFrontBundleID(void) {
    return NVStringFrom(NVFrontApp(), @"bundleIdentifier");
}

static pid_t NVFrontPID(void) {
    id app = NVFrontApp();
    SEL sel = NSSelectorFromString(@"pid");
    if (!app || ![app respondsToSelector:sel]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(app, sel);
}

// UIInterfaceOrientation of the front app: 1 portrait, 2 upside down, 3 landscape right, 4 landscape left.
static NSInteger NVFrontOrientation(void) {
    id application = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"_frontMostAppOrientation");
    if (![application respondsToSelector:sel]) return 1;
    NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(application, sel);
    return (o >= 1 && o <= 4) ? o : 1;
}

static void NVRespring(void) {
    id service = NVShared("FBSystemService", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"exitAndRelaunch:");
    if (service && [service respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(service, sel, YES);
        return;
    }
    exit(0);
}

static void NVHaptic(void) {
    AudioServicesPlaySystemSound(1519);   // "peek" tap on the Taptic Engine
}

#pragma mark - Telemetry (CPU, memory, thermal)

static mach_port_t gHost;

static double NVCPULoad(BOOL reset) {
    static host_cpu_load_info_data_t prev;
    static BOOL havePrev = NO;
    if (reset) { havePrev = NO; return -1; }

    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(gHost, HOST_CPU_LOAD_INFO, (host_info_t)&cur, &count) != KERN_SUCCESS) return -1;
    if (!havePrev) { prev = cur; havePrev = YES; return -1; }

    double user = cur.cpu_ticks[CPU_STATE_USER] - prev.cpu_ticks[CPU_STATE_USER];
    double system = cur.cpu_ticks[CPU_STATE_SYSTEM] - prev.cpu_ticks[CPU_STATE_SYSTEM];
    double nice = cur.cpu_ticks[CPU_STATE_NICE] - prev.cpu_ticks[CPU_STATE_NICE];
    double idle = cur.cpu_ticks[CPU_STATE_IDLE] - prev.cpu_ticks[CPU_STATE_IDLE];
    prev = cur;
    double busy = user + system + nice;
    double total = busy + idle;
    return total > 0 ? busy * 100.0 / total : 0;
}

// Percent of RAM that is neither free, inactive, speculative nor purgeable.
static double NVMemorySaturation(void) {
    static uint64_t total = 0;
    if (!total) {
        size_t len = sizeof(total);
        sysctlbyname("hw.memsize", &total, &len, NULL, 0);
    }
    if (!total) return -1;

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(gHost, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return -1;

    uint64_t reclaimable = ((uint64_t)vm.free_count + vm.inactive_count + vm.speculative_count +
                            vm.purgeable_count) * (uint64_t)vm_kernel_page_size;
    if (reclaimable > total) reclaimable = total;
    return 100.0 - (double)reclaimable * 100.0 / (double)total;
}

static NSString *NVThermalName(NSInteger state) {
    switch (state) {
        case 0: return @"Nominal";
        case 1: return @"Fair";
        case 2: return @"Serious";
        default: return @"Critical";
    }
}

#pragma mark - Processes (pause and resume background daemons)

// Analysis, indexing and learning daemons that are safe to pause for a while. Only processes owned by
// the "mobile" user can be touched from SpringBoard, so root daemons (thermalmonitord etc.) never are.
static NSArray<NSString *> *NVPausableDaemons(void) {
    return @[@"photoanalysisd", @"mediaanalysisd", @"parsecd", @"suggestd", @"searchd",
             @"duetexpertd", @"biomesyncd", @"spotlightknowledged", @"siriknowledged",
             @"knowledgeconstructiond"];
}

static dispatch_queue_t gQueue;           // utility queue: sampling and process work
static NSMutableSet<NSNumber *> *gFrozen; // pids paused by us (gQueue only)
static CFTimeInterval gFrozenDeadline;    // when paused daemons are resumed again (gQueue only)
static CFTimeInterval gLastFreezeScan;    // last time gaming mode re-scanned for daemons (gQueue only)

static void NVEnumerateProcesses(void (^block)(pid_t pid, const char *name, uid_t uid)) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return;
    len += len / 8 + sizeof(struct kinfo_proc) * 8;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
        size_t n = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            block(procs[i].kp_proc.p_pid, procs[i].kp_proc.p_comm, procs[i].kp_eproc.e_ucred.cr_uid);
        }
    }
    free(procs);
}

static BOOL NVNameIsPausable(const char *name) {
    for (NSString *daemon in NVPausableDaemons()) {
        if (strncmp(name, daemon.UTF8String, 15) == 0) return YES;   // p_comm is cut to 15 characters
    }
    return NO;
}

// Pause daemons. Runs on gQueue. Returns how many were newly paused.
static int NVPauseDaemons(void) {
    __block int paused = 0;
    uid_t me = getuid();
    pid_t self = getpid();
    NVEnumerateProcesses(^(pid_t pid, const char *name, uid_t uid) {
        if (pid <= 1 || pid == self || uid != me || !NVNameIsPausable(name)) return;
        if ([gFrozen containsObject:@(pid)]) return;
        if (kill(pid, SIGSTOP) == 0) {
            [gFrozen addObject:@(pid)];
            paused++;
        }
    });
    gFrozenDeadline = CACurrentMediaTime() + kFreezeSeconds;
    gLastFreezeScan = CACurrentMediaTime();
    return paused;
}

// Resume everything NovaShield paused. Runs on gQueue.
static void NVResumeDaemons(void) {
    for (NSNumber *pid in gFrozen) kill(pid.intValue, SIGCONT);
    [gFrozen removeAllObjects];
}

// Safety net: resume every pausable daemon by name, in case SpringBoard crashed while some were paused.
static void NVResumeAllByName(void) {
    uid_t me = getuid();
    NVEnumerateProcesses(^(pid_t pid, const char *name, uid_t uid) {
        if (pid <= 1 || uid != me || !NVNameIsPausable(name)) return;
        kill(pid, SIGCONT);
    });
    [gFrozen removeAllObjects];
}

#pragma mark - Boost & Cool

static NSSet<NSString *> *NVProtectedApps(void) {
    NSMutableSet *set = [NSMutableSet setWithSet:gGamingApps ?: [NSSet set]];
    [set addObjectsFromArray:@[
        @"com.apple.springboard", @"com.apple.mobilephone", @"com.apple.facetime", @"com.apple.InCallService",
        @"com.apple.Music", @"com.apple.Maps", @"com.apple.mobiletimer", @"com.apple.Preferences",
        @"com.apple.Passbook", @"com.apple.findmy",
        @"net.whatsapp.WhatsApp", @"com.facebook.Messenger", @"com.viber", @"com.skype.skype",
        @"us.zoom.videomeetings", @"com.google.Meet", @"com.spotify.client", @"com.google.ios.youtube",
    ]];
    return set;
}

// Apple apps that are safe to close; every other com.apple.* app is left alone.
static NSSet<NSString *> *NVClosableAppleApps(void) {
    return [NSSet setWithArray:@[
        @"com.apple.mobilesafari", @"com.apple.mobileslideshow", @"com.apple.mobilemail",
        @"com.apple.News", @"com.apple.mobilenotes", @"com.apple.podcasts", @"com.apple.AppStore",
        @"com.apple.iBooks", @"com.apple.weather", @"com.apple.stocks", @"com.apple.Health",
        @"com.apple.shortcuts", @"com.apple.tv",
    ]];
}

// Close background apps that are safe to close. Main thread. Returns how many were closed.
static int NVCloseBackgroundApps(void) {
    id controller = NVShared("SBApplicationController", @"sharedInstance");
    SEL running = NSSelectorFromString(@"runningApplications");
    if (!controller || ![controller respondsToSelector:running]) return 0;

    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    typedef void (*KillFn)(NSString *, int, BOOL, NSString *);
    KillFn terminate = (KillFn)dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
    if (!terminate) return 0;

    NSMutableSet *keep = [NSMutableSet setWithSet:NVProtectedApps()];
    NSString *front = NVFrontBundleID();
    if (front) [keep addObject:front];
    id media = NVShared("SBMediaController", @"sharedInstance");
    SEL nowPlayingSel = NSSelectorFromString(@"nowPlayingApplication");
    id nowPlayingApp = (media && [media respondsToSelector:nowPlayingSel])
        ? ((id (*)(id, SEL))objc_msgSend)(media, nowPlayingSel) : nil;
    NSString *nowPlaying = NVStringFrom(nowPlayingApp, @"bundleIdentifier");
    if (nowPlaying) [keep addObject:nowPlaying];

    NSSet *closableApple = NVClosableAppleApps();
    int closed = 0;
    NSArray *apps = ((NSArray *(*)(id, SEL))objc_msgSend)(controller, running);
    for (id app in apps) {
        NSString *bundleID = NVStringFrom(app, @"bundleIdentifier");
        if (!bundleID.length || [keep containsObject:bundleID]) continue;
        if ([bundleID hasPrefix:@"com.apple."] && ![closableApple containsObject:bundleID]) continue;
        terminate(bundleID, 5, NO, @"NovaShield Boost & Cool");
        closed++;
    }
    return closed;
}

// Ask SpringBoard to drop its caches and give freed memory back to the system. Main thread.
static void NVPurgeMemory(void) {
    malloc_zone_pressure_relief(NULL, 0);
    [NSURLCache.sharedURLCache removeAllCachedResponses];
    id application = UIApplication.sharedApplication;
    SEL warning = NSSelectorFromString(@"_performMemoryWarning");
    if ([application respondsToSelector:warning]) {
        ((void (*)(id, SEL))objc_msgSend)(application, warning);
    }
}

// Best effort: iOS normally lets only privileged processes raise another process's priority.
static BOOL NVRaiseForegroundPriority(void) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // keep SpringBoard's own UI snappy
    pid_t pid = NVFrontPID();
    if (pid <= 1) return NO;
    return setpriority(PRIO_PROCESS, (id_t)pid, -10) == 0;
}

static BOOL gBoosting;   // main thread

typedef struct {
    double memBefore, memAfter;   // memory saturation (%) around the boost, -1 if unknown
    int closed, paused;
    BOOL raised;
} NVBoostResult;

// Runs the whole rescue on its own. The completion block runs on the main thread with what really happened.
static void NVBoostAndCool(void (^completion)(NVBoostResult result)) {
    if (gBoosting) return;
    gBoosting = YES;

    double before = NVMemorySaturation();
    NVPurgeMemory();
    int closed = cfg.closeApps ? NVCloseBackgroundApps() : 0;
    BOOL raised = NVRaiseForegroundPriority();
    BOOL pause = cfg.pauseDaemons;

    dispatch_async(gQueue, ^{
        int paused = pause ? NVPauseDaemons() : 0;
        // Give the system a moment to hand the memory back, then measure for the proof.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), gQueue, ^{
            double after = NVMemorySaturation();
            dispatch_async(dispatch_get_main_queue(), ^{
                gBoosting = NO;
                NVBoostResult r = { before, after, closed, paused, raised };
                if (completion) completion(r);
            });
        });
    });
}

#pragma mark - Tick indicator (small, passive, never asks for a tap)

@interface NVIndicatorWindow : UIWindow
@end

@implementation NVIndicatorWindow
// Completely transparent to touches: it can never get in the way of an app.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

@interface NVIndicator : NSObject
@property (nonatomic, strong) NVIndicatorWindow *window;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL visible;
+ (instancetype)shared;
- (void)showItems:(NSArray<NSString *> *)items;
- (void)hideAnimated:(BOOL)animated;
@end

@implementation NVIndicator

+ (instancetype)shared {
    static NVIndicator *indicator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ indicator = [[NVIndicator alloc] init]; });
    return indicator;
}

// Green ticks followed by what was done, e.g. "✓ RAM 93→88%  ✓ 2 apps closed".
- (NSAttributedString *)textForItems:(NSArray<NSString *> *)items {
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
    NSDictionary *tick = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.systemGreenColor};
    NSDictionary *body = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor};
    for (NSUInteger i = 0; i < items.count; i++) {
        if (i) [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:body]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"✓ " attributes:tick]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:items[i] attributes:body]];
    }
    return text;
}

- (void)showItems:(NSArray<NSString *> *)items {
    if (!items.count || !cfg.showIndicator) return;
    [self hideAnimated:NO];

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat W = screen.size.width, H = screen.size.height;

    NVIndicatorWindow *window = [[NVIndicatorWindow alloc] initWithFrame:screen];
    window.windowLevel = 10000000;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    SEL secure = NSSelectorFromString(@"_setSecure:");
    if ([window respondsToSelector:secure]) ((void (*)(id, SEL, BOOL))objc_msgSend)(window, secure, YES);

    UILabel *label = [[UILabel alloc] init];
    label.attributedText = [self textForItems:items];
    label.numberOfLines = 1;
    [label sizeToFit];

    CGFloat h = 28;
    CGFloat w = MIN(label.bounds.size.width + 26, MAX(120, MAX(W, H) - 24));
    label.frame = CGRectMake(13, (h - label.bounds.size.height) / 2, w - 26, label.bounds.size.height);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;

    // Liquid glass: a very thin blur with a soft light edge and a faint highlight, no solid background.
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    pill.layer.shadowColor = UIColor.blackColor.CGColor;
    pill.layer.shadowOpacity = 0.14;
    pill.layer.shadowRadius = 10;
    pill.layer.shadowOffset = CGSizeMake(0, 4);
    pill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:pill.bounds cornerRadius:h / 2].CGPath;

    UIVisualEffectView *glass = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    glass.frame = pill.bounds;
    glass.layer.cornerRadius = h / 2;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 0.6;
    glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.38].CGColor;
    [pill addSubview:glass];

    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.frame = glass.bounds;
    sheen.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.03].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.12].CGColor];
    sheen.startPoint = CGPointMake(0, 0);
    sheen.endPoint = CGPointMake(1, 1);
    [glass.contentView.layer addSublayer:sheen];
    [glass.contentView addSubview:label];

    [root.view addSubview:pill];
    self.window = window;
    self.pill = pill;

    // Sit upright for the app in front (games are often landscape).
    NSInteger o = NVFrontOrientation();
    BOOL landscape = (o == 3 || o == 4);
    CGFloat visualH = landscape ? W : H;
    BOOL top = cfg.hudPosition == 0;
    CGFloat margin = top ? (landscape ? 8 : 26) : 16;
    CGFloat dy = top ? (margin + h / 2 - visualH / 2) : (visualH - margin - h / 2 - visualH / 2);
    CGFloat angle = (o == 4) ? -M_PI_2 : (o == 3) ? M_PI_2 : (o == 2) ? M_PI : 0;
    pill.center = CGPointMake(W / 2 - dy * sin(angle), H / 2 + dy * cos(angle));
    CGAffineTransform base = CGAffineTransformMakeRotation(angle);
    pill.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.7, 0.7), base);
    pill.alpha = 0;

    self.visible = YES;
    self.generation++;
    NSUInteger token = self.generation;
    window.hidden = NO;
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ pill.alpha = 1; pill.transform = base; } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cfg.hudDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.visible && self.generation == token) [self hideAnimated:YES];
    });
}

- (void)hideAnimated:(BOOL)animated {
    if (!self.visible) return;
    self.visible = NO;
    self.generation++;
    NVIndicatorWindow *window = self.window;
    UIView *pill = self.pill;
    void (^finish)(void) = ^{
        if (self.visible) return;      // a new indicator was shown in the meantime
        window.hidden = YES;
        if (self.window == window) { self.window = nil; self.pill = nil; }   // nothing stays alive when idle
    };
    if (!animated) { finish(); return; }
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ pill.alpha = 0; } completion:^(BOOL done) { finish(); }];
}

@end

// The proof shown after a boost: only things that really happened.
static NSArray<NSString *> *NVProofItems(NVBoostResult r) {
    NSMutableArray *items = [NSMutableArray array];
    if (r.memBefore >= 0 && r.memAfter >= 0 && r.memBefore - r.memAfter >= 0.5) {
        [items addObject:[NSString stringWithFormat:@"RAM %.0f→%.0f%%", r.memBefore, r.memAfter]];
    }
    if (r.closed) [items addObject:[NSString stringWithFormat:@"%d app%@ closed", r.closed, r.closed == 1 ? @"" : @"s"]];
    if (r.paused) [items addObject:[NSString stringWithFormat:@"%d paused", r.paused]];
    if (r.raised) [items addObject:@"priority up"];
    return items;
}

#pragma mark - Sampling loop (automatic, no buttons)

static BOOL gScreenOn = YES;
static dispatch_source_t gTimer;      // main thread owns it; the handler runs on gQueue
static NSTimeInterval gInterval;      // current sampling interval
static int gOverCount, gCalmCount;    // main thread
static CFTimeInterval gBoostNotBefore;   // main thread: automatic boosts are spaced out
static NSString *gGamingFront;        // front app that last triggered gaming mode (main thread)

static void NVSetInterval(NSTimeInterval interval) {
    if (!gTimer || interval == gInterval) return;
    gInterval = interval;
    // Big leeway lets the system batch our wake-ups with its own, which keeps the battery cost near zero.
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(interval * 0.5 * NSEC_PER_SEC));
}

static void NVAutoBoost(void) {
    gBoostNotBefore = CACurrentMediaTime() + kBoostCooldown;
    NVBoostAndCool(^(NVBoostResult r) {
        if (!gScreenOn) return;
        [NVIndicator.shared showItems:NVProofItems(r)];   // stays silent when nothing changed
    });
}

// Called on the main thread with every sample.
static void NVHandleSample(double cpu, double mem, NSInteger thermal) {
    if (!gScreenOn || !cfg.enabled) return;

    // Gaming Optimization Mode: boost once when a game or call app comes to the front, keep daemons paused.
    NSString *front = NVFrontBundleID();
    BOOL gameFront = cfg.gaming && front && [gGamingApps containsObject:front];
    if (gameFront && ![front isEqualToString:gGamingFront]) {
        gGamingFront = front;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGamingBoostDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gScreenOn && cfg.enabled && [NVFrontBundleID() isEqualToString:front]) NVAutoBoost();
        });
    } else if (!gameFront && gGamingFront) {
        gGamingFront = nil;
        dispatch_async(gQueue, ^{ NVResumeDaemons(); });
    }
    if (gameFront && cfg.pauseDaemons) {
        dispatch_async(gQueue, ^{
            if (!gFrozen.count) return;
            CFTimeInterval now = CACurrentMediaTime();
            gFrozenDeadline = now + kFreezeSeconds;           // stay paused while the game is in front
            if (now - gLastFreezeScan > 30) NVPauseDaemons(); // catch daemons that were restarted
        });
    }

    BOOL over = (cpu >= cfg.threshold) || (cfg.warnMemory && mem >= kMemoryLimit) || thermal >= 2;
    BOOL calm = (cpu < cfg.threshold - 10) && !(cfg.warnMemory && mem >= kMemoryLimit - 4) && thermal < 2;
    if (over) { gOverCount++; gCalmCount = 0; }
    else { gOverCount = 0; gCalmCount = calm ? gCalmCount + 1 : 0; }

    // Quiet phone: check less often. Busy phone: check more often.
    NVSetInterval(gCalmCount >= kCalmChecksForSlow ? kPollSlow : kPollFast);

    if (gOverCount >= kOverChecksNeeded && !gBoosting && CACurrentMediaTime() > gBoostNotBefore) {
        gOverCount = 0;
        NVAutoBoost();
    }
}

static void NVPoll(void) {
    double cpu = NVCPULoad(NO);
    if (cpu < 0) return;   // first sample only primes the counters
    double mem = NVMemorySaturation();
    NSInteger thermal = NSProcessInfo.processInfo.thermalState;

    // Release paused daemons when their time is up and no game needs them paused.
    if (gFrozen.count && CACurrentMediaTime() > gFrozenDeadline) NVResumeDaemons();

    dispatch_async(dispatch_get_main_queue(), ^{ NVHandleSample(cpu, mem, thermal); });
}

static void NVStartTelemetry(void) {
    if (gTimer || !cfg.enabled || !gScreenOn) return;
    dispatch_async(gQueue, ^{ NVCPULoad(YES); });   // forget the counters from before the screen turned off
    gOverCount = gCalmCount = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    gTimer = timer;
    gInterval = 0;
    dispatch_source_set_event_handler(timer, ^{ NVPoll(); });
    NVSetInterval(kPollFast);
    dispatch_resume(timer);
}

static void NVStopTelemetry(void) {
    if (gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
    gOverCount = gCalmCount = 0;
    gGamingFront = nil;
}

// Everything NovaShield started is wound down: no timer, no indicator, no paused daemons.
static void NVShutDownEverything(void) {
    NVStopTelemetry();
    [NVIndicator.shared hideAnimated:NO];
    dispatch_async(gQueue, ^{ NVResumeDaemons(); });
}

#pragma mark - Screen state and notifications

static int gBlankToken, gPrefsToken, gTestToken, gRespringToken;

static BOOL NVScreenBlanked(void) {
    uint64_t state = 0;
    if (gBlankToken) notify_get_state(gBlankToken, &state);
    return state != 0;
}

static void NVScreenChanged(void) {
    BOOL on = !NVScreenBlanked();
    if (on == gScreenOn) return;
    gScreenOn = on;
    if (on) {
        NVLoadConfig();
        NVStartTelemetry();
    } else {
        NVShutDownEverything();   // zero activity while the screen is off
    }
}

__attribute__((constructor))
static void NVInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        gHost = mach_host_self();
        gFrozen = [NSMutableSet set];
        gQueue = dispatch_queue_create("com.kwarnu.novashield.work",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        NVLoadConfig();
        dispatch_async(gQueue, ^{ NVResumeAllByName(); });   // recover from a crash that left daemons paused

        dispatch_queue_t main = dispatch_get_main_queue();

        notify_register_dispatch(NV_NOTIFY_BLANKED, &gBlankToken, main, ^(int token) { NVScreenChanged(); });
        gScreenOn = !NVScreenBlanked();

        notify_register_dispatch(NV_NOTIFY_PREFS, &gPrefsToken, main, ^(int token) {
            NVLoadConfig();
            if (!cfg.enabled) NVShutDownEverything();
            else if (gScreenOn) NVStartTelemetry();
        });

        notify_register_dispatch(NV_NOTIFY_TESTHUD, &gTestToken, main, ^(int token) {
            NVLoadConfig();
            [NVIndicator.shared showItems:@[@"RAM 93→88%", @"2 apps closed", @"4 paused"]];
        });

        notify_register_dispatch(NV_NOTIFY_RESPRING, &gRespringToken, main, ^(int token) { NVRespring(); });

        // Start sampling once SpringBoard has finished launching.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), main, ^{
            NVStartTelemetry();
        });
    }
}
