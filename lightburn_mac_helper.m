// lightburn_mac_helper.m
// ─────────────────────────────────────────────────────────────────────────────
// Objective-C / AppKit implementation of the LightBurn Monitor tray icon.
// Compiled by Nim via {.compile: "lightburn_mac_helper.m".} in
// lightburn_tray_mac.nim.
//
// All AppKit calls must run on the main thread; NSTimer callbacks already do.
// The poll callback blocks for up to recvTimeoutMs ms (SO_RCVTIMEO) — that is
// acceptable for a tray-only app with no interactive windows.
// ─────────────────────────────────────────────────────────────────────────────

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

// ── Nim → ObjC: C functions exported from lightburn_tray_mac.nim ─────────────
extern void   nim_poll_tick(void);
extern void   nim_complete_revert(void);
extern void   nim_toggle_sound(void);
extern void   nim_toggle_notify(void);
extern void   nim_toggle_email(void);
extern void   nim_do_exit(void);
extern const char* nim_status_label(void);
extern int    nim_get_sound_on(void);
extern int    nim_get_notify_on(void);
extern int    nim_get_email_on(void);
extern int    nim_get_status(void);
extern int         nim_send_test_email(void);
extern const char* nim_email_last_error(void);

// ── Forward declarations for C API functions used inside @implementation ──────
void mac_show_notification(const char *title, const char *body);

// ── Statics ───────────────────────────────────────────────────────────────────
static NSStatusItem *gItem      = nil;
static NSMenuItem   *gStatusHdr = nil;
static NSMenuItem   *gSoundItem = nil;
static NSMenuItem   *gNotifyItem= nil;
static NSMenuItem   *gEmailItem     = nil;
static NSMenuItem   *gTestEmailItem = nil;
static double gPollSecs         = 2.0;
static double gCompleteSecs     = 8.0;

// ── Coloured dot icon (18×18 NSImage) ────────────────────────────────────────
static NSImage* dotImage(CGFloat r, CGFloat g, CGFloat b) {
    int sz = 18;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, sz, sz, 8, 0, cs,
                           kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(1.5, 1.5, sz - 3.0, sz - 3.0));
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(sz, sz)];
    CGImageRelease(cg);
    img.template = NO;
    return img;
}

// Matches BurnStatus ordinals: 0=disconnected, 1=idle, 2=burning, 3=complete
static NSImage* iconForStatus(int s) {
    switch (s) {
        case 1:  return dotImage(0.00, 0.78, 0.31);   // green  – idle
        case 2:  return dotImage(1.00, 0.55, 0.00);   // orange – burning
        case 3:  return dotImage(0.00, 0.63, 1.00);   // blue   – complete
        default: return dotImage(0.39, 0.39, 0.39);   // grey   – disconnected
    }
}

// ── AppDelegate ───────────────────────────────────────────────────────────────
@interface TrayDelegate : NSObject <NSApplicationDelegate,
                                    UNUserNotificationCenterDelegate>
@property (strong) NSTimer *pollTimer;
@property (strong) NSTimer *completeTimer;
- (NSMenu *)buildMenu;
- (void)syncMenuItems;
- (void)startCompleteTimer;
@end

@implementation TrayDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Build the status-bar item — retain explicitly (MRC: statusItemWithLength returns autoreleased)
    gItem = [[[NSStatusBar systemStatusBar]
              statusItemWithLength:NSSquareStatusItemLength] retain];
    gItem.button.image   = iconForStatus(nim_get_status());
    gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
    gItem.menu           = [self buildMenu];

    // Register as notification delegate and request permission.
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Notification Permission Needed";
                alert.informativeText =
                    @"LightBurn Monitor needs permission to show notifications "
                    @"when a burn completes.\n\nPlease enable it in "
                    @"System Settings \u2192 Notifications \u2192 LightBurnMonitor.";
                alert.alertStyle = NSAlertStyleWarning;
                [alert addButtonWithTitle:@"Open System Settings"];
                [alert addButtonWithTitle:@"Dismiss"];
                NSModalResponse resp = [alert runModal];
                if (resp == NSAlertFirstButtonReturn) {
                    // macOS 14+ URL; falls back gracefully on older systems
                    NSURL *url = [NSURL URLWithString:
                        @"x-apple.systempreferences:com.apple.Notifications-Settings"];
                    [[NSWorkspace sharedWorkspace] openURL:url];
                }
                [alert release];
            });
        }
    }];

    // Poll timer — nim_poll_tick() blocks for up to recvTimeoutMs waiting on the
    // socket, so dispatch it off the main thread to keep the run loop responsive.
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:gPollSecs
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            nim_poll_tick();
            dispatch_async(dispatch_get_main_queue(), ^{
                gItem.button.image   = iconForStatus(nim_get_status());
                gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
                if (gStatusHdr)
                    gStatusHdr.title = [NSString stringWithUTF8String:nim_status_label()];
            });
        });
    }];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    // Status header (greyed out, read-only)
    gStatusHdr = [[NSMenuItem alloc]
                   initWithTitle:[NSString stringWithUTF8String:nim_status_label()]
                          action:nil
                   keyEquivalent:@""];
    gStatusHdr.enabled = NO;
    [menu addItem:gStatusHdr];
    [menu addItem:[NSMenuItem separatorItem]];

    // Notifications toggle
    gNotifyItem = [[NSMenuItem alloc]
                    initWithTitle:nim_get_notify_on() ? @"Notifications: On"
                                                      : @"Notifications: Off"
                           action:@selector(onNotify:)
                    keyEquivalent:@""];
    gNotifyItem.state  = nim_get_notify_on() ? NSControlStateValueOn
                                             : NSControlStateValueOff;
    gNotifyItem.target = self;
    [menu addItem:gNotifyItem];

    // Sound toggle
    gSoundItem = [[NSMenuItem alloc]
                   initWithTitle:nim_get_sound_on() ? @"Sound: On" : @"Sound: Off"
                          action:@selector(onSound:)
                   keyEquivalent:@""];
    gSoundItem.state  = nim_get_sound_on() ? NSControlStateValueOn
                                           : NSControlStateValueOff;
    gSoundItem.target = self;
    [menu addItem:gSoundItem];

    // Email Alert toggle
    gEmailItem = [[NSMenuItem alloc]
                   initWithTitle:nim_get_email_on() ? @"Email Alert: On"
                                                    : @"Email Alert: Off"
                          action:@selector(onEmail:)
                   keyEquivalent:@""];
    gEmailItem.state  = nim_get_email_on() ? NSControlStateValueOn
                                           : NSControlStateValueOff;
    gEmailItem.target = self;
    [menu addItem:gEmailItem];

    // Test Email
    gTestEmailItem = [[NSMenuItem alloc]
                       initWithTitle:@"Send Test Email\u2026"
                              action:@selector(onTestEmail:)
                       keyEquivalent:@""];
    gTestEmailItem.target = self;
    [menu addItem:gTestEmailItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Exit
    NSMenuItem *exitItem = [[NSMenuItem alloc]
                             initWithTitle:@"Exit"
                                    action:@selector(onExit:)
                             keyEquivalent:@"q"];
    exitItem.target = self;
    [menu addItem:exitItem];

    return menu;
}

// ── Menu action handlers ──────────────────────────────────────────────────────
- (IBAction)onSound:(id)sender  { nim_toggle_sound();  [self syncMenuItems]; }
- (IBAction)onNotify:(id)sender { nim_toggle_notify(); [self syncMenuItems]; }
- (IBAction)onEmail:(id)sender  { nim_toggle_email();  [self syncMenuItems]; }
- (IBAction)onExit:(id)sender   { nim_do_exit(); }
- (IBAction)onTestEmail:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int ok = nim_send_test_email();
        const char *title = ok ? "Email Sent"   : "Email Failed";
        const char *body  = ok ? "Test email delivered successfully."
                               : nim_email_last_error();
        mac_show_notification(title, body);
    });
}

- (void)syncMenuItems {
    gSoundItem.title  = nim_get_sound_on()  ? @"Sound: On"         : @"Sound: Off";
    gSoundItem.state  = nim_get_sound_on()  ? NSControlStateValueOn: NSControlStateValueOff;
    gNotifyItem.title = nim_get_notify_on() ? @"Notifications: On" : @"Notifications: Off";
    gNotifyItem.state = nim_get_notify_on() ? NSControlStateValueOn: NSControlStateValueOff;
    gEmailItem.title  = nim_get_email_on()  ? @"Email Alert: On"   : @"Email Alert: Off";
    gEmailItem.state  = nim_get_email_on()  ? NSControlStateValueOn: NSControlStateValueOff;
}

// ── Complete timer (fires once after CompleteSecs, reverts icon to idle) ──────
- (void)startCompleteTimer {
    [self.completeTimer invalidate];
    self.completeTimer = [NSTimer scheduledTimerWithTimeInterval:gCompleteSecs
                                                         repeats:NO
                                                           block:^(NSTimer *t) {
        nim_complete_revert();
        gItem.button.image   = iconForStatus(nim_get_status());
        gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
        if (gStatusHdr)
            gStatusHdr.title = [NSString stringWithUTF8String:nim_status_label()];
    }];
}

- (void)stopCompleteTimer {
    [self.completeTimer invalidate];
    self.completeTimer = nil;
}

// ── UNUserNotificationCenterDelegate ─────────────────────────────────────────
// Allow banners to appear even while the app is active (menu-bar only apps are
// always "in the foreground", so this is required to see any notification).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList  |
                      UNNotificationPresentationOptionSound);
}

@end

// ── Global delegate (needed by C functions below) ─────────────────────────────
static TrayDelegate *gDelegate = nil;

// ── C API called from Nim (lightburn_tray_mac.nim) ───────────────────────────

void mac_setup(double pollSecs, double completeSecs) {
    gPollSecs     = pollSecs;
    gCompleteSecs = completeSecs;
}

void mac_run(void) {
    [NSApplication sharedApplication];
    // Accessory policy = menu-bar only, no Dock icon, no app switcher entry
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gDelegate      = [[TrayDelegate alloc] init];
    NSApp.delegate = gDelegate;
    [NSApp run];
}

// Returns the bundle Resources directory (or the binary directory when not in a bundle).
// The returned pointer is valid for the lifetime of the process.
const char* mac_resource_dir(void) {
    static NSString *sPath = nil;
    if (sPath == nil) {
        NSString *rp = [[NSBundle mainBundle] resourcePath];
        sPath = (rp ? rp : [[[[NSBundle mainBundle] executableURL]
                               URLByDeletingLastPathComponent] path]);
        [sPath retain];
    }
    return [sPath UTF8String];
}

void mac_show_notification(const char *title, const char *body) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = [NSString stringWithUTF8String:title];
        content.body  = [NSString stringWithUTF8String:body];
        UNNotificationRequest *req = [UNNotificationRequest
            requestWithIdentifier:[[NSUUID UUID] UUIDString]
                          content:content
                          trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:req withCompletionHandler:nil];
    });
}

void mac_start_complete_timer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gDelegate startCompleteTimer];
    });
}

void mac_stop_all_timers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gDelegate.pollTimer invalidate];
        [gDelegate stopCompleteTimer];
    });
}

void mac_quit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}
