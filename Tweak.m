// NovaShield: performance and thermal rescue for SpringBoard (rootless, iOS 15+).
//
// What it does, in short:
//  * While the screen is ON it samples CPU load, memory use and the system thermal state every 2.5 s.
//  * While the screen is OFF it runs nothing at all: the timer is cancelled, nothing is scheduled, and
//    anything NovaShield paused is resumed first. Standby battery is not touched.
//  * When the load stays too high (or the phone gets hot) a floating glass HUD offers "Boost & Cool".
//  * Boost & Cool clears memory caches, closes safe background apps, pauses background analysis daemons
//    for a while, and tries to raise the foreground app's priority.
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

static const NSTimeInterval kPollInterval = 2.5;     // seconds between samples while the screen is on
static const int kOverChecksNeeded = 3;              // consecutive high samples before the HUD appears
static const int kCalmChecksNeeded = 2;              // consecutive calm samples before it goes away
static const double kMemoryLimit = 92.0;             // memory saturation (%) that counts as "high"
static const NSTimeInterval kHUDCooldown = 45.0;     // quiet time after the HUD is dismissed
static const NSTimeInterval kBoostCooldown = 25.0;   // quiet time after a Boost & Cool
static const NSTimeInterval kFreezeSeconds = 90.0;   // how long paused daemons stay paused per boost
static const NSTimeInterval kGamingBoostDelay = 5.0; // wait after a game opens so it can finish loading

#pragma mark - Settings

typedef struct {
    BOOL enabled;
    double threshold;      // CPU warning threshold, percent
    BOOL gaming;           // auto boost for games and calls
    NSInteger hudPosition; // 0 = top, 1 = bottom
    double hudDuration;    // seconds the HUD stays if the load does not settle
    BOOL warnMemory;
    BOOL closeApps;
    BOOL pauseDaemons;
} NVConfig;

static NVConfig cfg = {
    .enabled = YES, .threshold = 80, .gaming = YES, .hudPosition = 0, .hudDuration = 8,
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
    cfg.hudDuration = NVNumberPref(@"hudDuration", 8, 3, 30);
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

// Runs the whole rescue. The completion block runs on the main thread with a short summary.
static void NVBoostAndCool(void (^completion)(NSString *summary)) {
    if (gBoosting) { if (completion) completion(@"Already working"); return; }
    gBoosting = YES;

    NVPurgeMemory();
    int closed = cfg.closeApps ? NVCloseBackgroundApps() : 0;
    BOOL raised = NVRaiseForegroundPriority();
    BOOL pause = cfg.pauseDaemons;

    dispatch_async(gQueue, ^{
        int paused = pause ? NVPauseDaemons() : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *parts = [NSMutableArray arrayWithObject:@"Memory cleared"];
            if (closed) [parts addObject:[NSString stringWithFormat:@"%d app%@ closed", closed, closed == 1 ? @"" : @"s"]];
            if (paused) [parts addObject:[NSString stringWithFormat:@"%d daemon%@ paused", paused, paused == 1 ? @"" : @"s"]];
            if (raised) [parts addObject:@"priority raised"];
            gBoosting = NO;
            if (completion) completion([parts componentsJoinedByString:@" · "]);
        });
    });
}

#pragma mark - HUD

@interface NVHUDWindow : UIWindow
@end

@implementation NVHUDWindow
// Only the HUD card takes touches; everything else falls through to the app underneath.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    if (view == self || view == self.rootViewController.view) return nil;
    return view;
}
@end

@interface NVHUD : NSObject
@property (nonatomic, strong) NVHUDWindow *window;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic) NSInteger orientation;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL visible;
@property (nonatomic) CGAffineTransform baseTransform;
+ (instancetype)shared;
- (void)showWithCPU:(double)cpu memory:(double)mem thermal:(NSInteger)thermal;
- (void)updateWithCPU:(double)cpu memory:(double)mem thermal:(NSInteger)thermal;
- (void)dismissAnimated:(BOOL)animated;
- (void)followOrientation;
@end

static CFTimeInterval gCooldownUntil;   // main thread

@implementation NVHUD

+ (instancetype)shared {
    static NVHUD *hud;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hud = [[NVHUD alloc] init]; });
    return hud;
}

- (void)buildWindow {
    CGRect screen = UIScreen.mainScreen.bounds;
    NVHUDWindow *window = [[NVHUDWindow alloc] initWithFrame:screen];
    window.windowLevel = 10000000;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    SEL secure = NSSelectorFromString(@"_setSecure:");
    if ([window respondsToSelector:secure]) ((void (*)(id, SEL, BOOL))objc_msgSend)(window, secure, YES);
    self.window = window;

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.28;
    card.layer.shadowRadius = 20;
    card.layer.shadowOffset = CGSizeMake(0, 8);
    [root.view addSubview:card];
    self.card = card;

    UIVisualEffectView *glass = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    glass.layer.cornerRadius = 22;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 0.5;
    glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [card addSubview:glass];

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(16, 13, 28, 28)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [glass.contentView addSubview:icon];
    self.icon = icon;

    UILabel *title = [[UILabel alloc] init];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [glass.contentView addSubview:title];
    self.titleLabel = title;

    UILabel *detail = [[UILabel alloc] init];
    detail.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [glass.contentView addSubview:detail];
    self.detailLabel = detail;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor colorWithRed:0.33 green:0.42 blue:1.0 alpha:1.0];
    button.layer.cornerRadius = 11;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitle:@"⚡️ Boost & Cool" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:self action:@selector(boostTapped) forControlEvents:UIControlEventTouchUpInside];
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [glass.contentView addSubview:button];
    self.button = button;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [card addGestureRecognizer:pan];
}

- (void)fillWithCPU:(double)cpu memory:(double)mem thermal:(NSInteger)thermal {
    BOOL hot = thermal >= 2;
    BOOL cpuHigh = cpu >= cfg.threshold;
    NSString *title;
    NSString *symbol;
    UIColor *tint;
    if (hot) {
        title = @"Phone is running hot"; symbol = @"thermometer.high"; tint = UIColor.systemRedColor;
    } else if (cpuHigh) {
        title = @"High CPU load"; symbol = @"exclamationmark.triangle.fill"; tint = UIColor.systemOrangeColor;
    } else {
        title = @"Memory is almost full"; symbol = @"memorychip"; tint = UIColor.systemOrangeColor;
    }
    self.titleLabel.text = title;
    self.icon.image = [UIImage systemImageNamed:symbol];
    self.icon.tintColor = tint;
    NSString *cpuText = cpu >= 0 ? [NSString stringWithFormat:@"%.0f%%", cpu] : @"--";
    NSString *memText = mem >= 0 ? [NSString stringWithFormat:@"%.0f%%", mem] : @"--";
    self.detailLabel.text = [NSString stringWithFormat:@"CPU %@  ·  RAM %@  ·  %@", cpuText, memText, NVThermalName(thermal)];
}

// Position and rotate the card so it is upright for the app in front (games are often landscape).
- (void)layoutCardAnimated:(BOOL)animated {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat W = screen.size.width, H = screen.size.height;
    NSInteger o = self.orientation;
    BOOL landscape = (o == 3 || o == 4);
    CGFloat visualW = landscape ? H : W;
    CGFloat visualH = landscape ? W : H;
    CGFloat w = MIN(380, visualW - 24);
    CGFloat h = 90;
    BOOL top = cfg.hudPosition == 0;
    CGFloat margin = top ? (landscape ? 10 : 28) : 14;
    CGFloat dy = top ? (margin + h / 2 - visualH / 2) : (visualH - margin - h / 2 - visualH / 2);

    CGFloat angle = 0;
    if (o == 4) angle = -M_PI_2;
    else if (o == 3) angle = M_PI_2;
    else if (o == 2) angle = M_PI;

    void (^apply)(void) = ^{
        self.card.transform = CGAffineTransformIdentity;
        self.card.bounds = CGRectMake(0, 0, w, h);
        self.card.center = CGPointMake(W / 2 - dy * sin(angle), H / 2 + dy * cos(angle));
        self.baseTransform = CGAffineTransformMakeRotation(angle);
        self.card.transform = self.baseTransform;
        self.card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.card.bounds cornerRadius:22].CGPath;
        self.titleLabel.frame = CGRectMake(54, 11, w - 70, 20);
        self.detailLabel.frame = CGRectMake(54, 31, w - 70, 18);
        self.button.frame = CGRectMake(16, 54, w - 32, 30);
    };
    if (animated) [UIView animateWithDuration:0.3 animations:apply]; else apply();
}

- (void)followOrientation {
    if (!self.visible) return;
    NSInteger o = NVFrontOrientation();
    if (o != self.orientation) {
        self.orientation = o;
        [self layoutCardAnimated:YES];
    }
}

- (void)showWithCPU:(double)cpu memory:(double)mem thermal:(NSInteger)thermal {
    if (self.visible) { [self updateWithCPU:cpu memory:mem thermal:thermal]; return; }
    if (!self.window) [self buildWindow];
    self.visible = YES;
    self.generation++;
    NSUInteger token = self.generation;
    self.orientation = NVFrontOrientation();
    [self.button setTitle:@"⚡️ Boost & Cool" forState:UIControlStateNormal];
    self.button.enabled = YES;
    self.button.alpha = 1;
    [self fillWithCPU:cpu memory:mem thermal:thermal];
    [self layoutCardAnimated:NO];

    // Spring in from the edge the card is attached to.
    CGFloat slide = cfg.hudPosition == 0 ? -70 : 70;
    self.card.alpha = 0;
    self.card.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, slide), self.baseTransform);
    self.window.hidden = NO;
    [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.7
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.card.alpha = 1;
        self.card.transform = self.baseTransform;
    } completion:nil];

    // Leave by itself if the load does not settle.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cfg.hudDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.visible && self.generation == token) {
            gCooldownUntil = CACurrentMediaTime() + kHUDCooldown;
            [self dismissAnimated:YES];
        }
    });
}

- (void)updateWithCPU:(double)cpu memory:(double)mem thermal:(NSInteger)thermal {
    if (!self.visible) return;
    [self fillWithCPU:cpu memory:mem thermal:thermal];
    [self followOrientation];
}

- (void)dismissAnimated:(BOOL)animated {
    if (!self.visible) return;
    self.visible = NO;
    self.generation++;
    void (^finish)(void) = ^{
        if (self.visible) return;   // shown again in the meantime
        self.window.hidden = YES;
        self.window = nil;          // nothing stays alive while there is no HUD
        self.card = nil;
    };
    if (!animated) { finish(); return; }
    CGFloat slide = cfg.hudPosition == 0 ? -60 : 60;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.card.alpha = 0;
        self.card.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, slide), self.baseTransform);
    } completion:^(BOOL done) { finish(); }];
}

- (void)boostTapped {
    self.generation++;   // cancel the auto-dismiss timer while working
    NSUInteger token = self.generation;
    self.button.enabled = NO;
    self.button.alpha = 0.7;
    [self.button setTitle:@"Working…" forState:UIControlStateNormal];
    NVBoostAndCool(^(NSString *summary) {
        NVHaptic();
        [self.button setTitle:[@"✓ " stringByAppendingString:summary] forState:UIControlStateNormal];
        self.button.alpha = 1;
        gCooldownUntil = CACurrentMediaTime() + kBoostCooldown;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.visible && self.generation == token) [self dismissAnimated:YES];
        });
    });
}

// Drag the card away (toward its edge or sideways) to dismiss it.
- (void)panned:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.card];
    CGFloat edgeSign = cfg.hudPosition == 0 ? -1 : 1;   // local direction of the nearest edge
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat dy = edgeSign > 0 ? MAX(t.y, -8) : MIN(t.y, 8);
        self.card.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(t.x * 0.6, dy), self.baseTransform);
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGPoint v = [pan velocityInView:self.card];
        BOOL towardEdge = edgeSign * t.y > 28 || edgeSign * v.y > 500;
        BOOL sideways = fabs(t.x) > 90 || fabs(v.x) > 700;
        if (pan.state == UIGestureRecognizerStateEnded && (towardEdge || sideways)) {
            gCooldownUntil = CACurrentMediaTime() + kHUDCooldown;
            [self dismissAnimated:YES];
        } else {
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                                options:0 animations:^{ self.card.transform = self.baseTransform; } completion:nil];
        }
    }
}

@end

#pragma mark - Sampling loop

static BOOL gScreenOn = YES;
static dispatch_source_t gTimer;      // main thread owns it; the handler runs on gQueue
static int gOverCount, gCalmCount;    // main thread
static NSString *gGamingFront;        // front app that last triggered gaming mode (main thread)

// Called on the main thread with every sample.
static void NVHandleSample(double cpu, double mem, NSInteger thermal) {
    if (!gScreenOn || !cfg.enabled) return;

    NVHUD *hud = NVHUD.shared;
    [hud followOrientation];

    // Gaming Optimization Mode: boost once when a game or call app comes to the front, keep daemons paused.
    NSString *front = NVFrontBundleID();
    BOOL gameFront = cfg.gaming && front && [gGamingApps containsObject:front];
    if (gameFront && ![front isEqualToString:gGamingFront]) {
        gGamingFront = front;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGamingBoostDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gScreenOn && cfg.enabled && [NVFrontBundleID() isEqualToString:front]) {
                NVBoostAndCool(nil);
            }
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

    BOOL memHigh = cfg.warnMemory && mem >= kMemoryLimit;
    BOOL over = (cpu >= cfg.threshold) || memHigh || thermal >= 2;
    BOOL calm = (cpu < cfg.threshold - 10) && !(cfg.warnMemory && mem >= kMemoryLimit - 4) && thermal < 2;
    if (over) { gOverCount++; gCalmCount = 0; }
    else { gOverCount = 0; gCalmCount = calm ? gCalmCount + 1 : 0; }

    if (hud.visible) {
        [hud updateWithCPU:cpu memory:mem thermal:thermal];
        if (gCalmCount >= kCalmChecksNeeded && !gBoosting) [hud dismissAnimated:YES];   // load stabilised
    } else if (gOverCount >= kOverChecksNeeded && CACurrentMediaTime() > gCooldownUntil) {
        [hud showWithCPU:cpu memory:mem thermal:thermal];
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
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                              (uint64_t)(kPollInterval * NSEC_PER_SEC), (uint64_t)(0.25 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ NVPoll(); });
    gTimer = timer;
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

// Everything NovaShield started is wound down: no timer, no HUD, no paused daemons.
static void NVShutDownEverything(void) {
    NVStopTelemetry();
    [NVHUD.shared dismissAnimated:NO];
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
            double cpu = MIN(99, MAX(cfg.threshold + 8, 88));
            [NVHUD.shared showWithCPU:cpu memory:93 thermal:1];
        });

        notify_register_dispatch(NV_NOTIFY_RESPRING, &gRespringToken, main, ^(int token) { NVRespring(); });

        // Start sampling once SpringBoard has finished launching.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), main, ^{
            NVStartTelemetry();
        });
    }
}
