#import <UIKit/UIKit.h>
#import <notify.h>

// Minimal declarations of the private Preferences.framework classes we subclass.
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

#define NS_DOMAIN CFSTR("com.kwarnu.novashield")
#define NS_NOTIFY_PREFS "com.kwarnu.novashield/prefschanged"
#define NS_NOTIFY_TESTHUD "com.kwarnu.novashield/testhud"
#define NS_NOTIFY_RESPRING "com.kwarnu.novashield/respring"

@interface NovaShieldRootListController : PSListController
@end

@implementation NovaShieldRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Shows the small tick indicator so you can check the look, position and timing.
- (void)testHUD {
    notify_post(NS_NOTIFY_TESTHUD);
}

- (void)resetDefaults {
    NSArray *keys = @[@"enabled", @"threshold", @"gaming", @"hudPosition", @"hudDuration",
                      @"warnMemory", @"closeApps", @"pauseDaemons", @"showIndicator"];
    for (NSString *key in keys) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, NS_DOMAIN);
    }
    CFPreferencesAppSynchronize(NS_DOMAIN);
    notify_post(NS_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self showAlert:@"Defaults restored" message:@"All NovaShield settings are back to their defaults."];
}

- (void)respring {
    notify_post(NS_NOTIFY_RESPRING);
}

@end
