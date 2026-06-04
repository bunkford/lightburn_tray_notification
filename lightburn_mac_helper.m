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

// ── Statics ───────────────────────────────────────────────────────────────────
static NSStatusItem *gItem      = nil;
static NSMenuItem   *gStatusHdr = nil;
static NSMenuItem   *gSoundItem = nil;
static NSMenuItem   *gNotifyItem= nil;
static NSMenuItem   *gEmailItem = nil;
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
                                    NSUserNotificationCenterDelegate>
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

    // Be a notification centre delegate so alerts appear even without a dock entry
    [NSUserNotificationCenter defaultUserNotificationCenter].delegate = self;

    // Poll timer
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:gPollSecs
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        nim_poll_tick();
        // After Nim updates gStatus, sync the icon / tooltip
        gItem.button.image   = iconForStatus(nim_get_status());
        gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
        if (gStatusHdr)
            gStatusHdr.title = [NSString stringWithUTF8String:nim_status_label()];
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

// ── NSUserNotificationCenterDelegate ─────────────────────────────────────────
// Allow notifications even when the app has no Dock presence.
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)c
     shouldPresentNotification:(NSUserNotification *)n {
    return YES;
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

void mac_show_notification(const char *title, const char *body) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserNotification *n = [[NSUserNotification alloc] init];
        n.title           = [NSString stringWithUTF8String:title];
        n.informativeText = [NSString stringWithUTF8String:body];
        [[NSUserNotificationCenter defaultUserNotificationCenter]
            deliverNotification:n];
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
