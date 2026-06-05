// lightburn_mac_helper.m
// ─────────────────────────────────────────────────────────────────────────────
// Objective-C / AppKit implementation of the LightBurn Monitor tray icon.
// Compiled by Nim via {.compile: "lightburn_mac_helper.m".} in
// lightburn_tray_mac.nim.
// ─────────────────────────────────────────────────────────────────────────────

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

// ── Nim exports called from this file ────────────────────────────────────────
extern void        nim_poll_tick(void);
extern void        nim_complete_revert(void);
extern void        nim_toggle_sound(void);
extern void        nim_toggle_notify(void);
extern void        nim_toggle_email(void);
extern void        nim_do_exit(void);
extern const char *nim_status_label(void);
extern int         nim_get_sound_on(void);
extern int         nim_get_notify_on(void);
extern int         nim_get_email_on(void);
extern int         nim_get_status(void);
extern int         nim_send_test_email(void);
extern const char *nim_email_last_error(void);
// Settings read API (main-thread only)
extern const char *nim_cfg_lb_host(void);
extern int         nim_cfg_lb_out_port(void);
extern int         nim_cfg_lb_in_port(void);
extern double      nim_cfg_poll_secs(void);
extern double      nim_cfg_complete_secs(void);
extern int         nim_cfg_recv_timeout_ms(void);
extern const char *nim_cfg_smtp_host(void);
extern int         nim_cfg_smtp_port(void);
extern int         nim_cfg_smtp_use_ssl(void);
extern const char *nim_cfg_smtp_username(void);
extern const char *nim_cfg_smtp_password(void);
extern const char *nim_cfg_smtp_from(void);
extern const char *nim_cfg_smtp_to(void);
extern int         nim_reload_settings(void);

// ── Forward declarations ──────────────────────────────────────────────────────
@class TrayDelegate;
void mac_show_notification(const char *title, const char *body);
void mac_update_poll_interval(double newSecs);
const char *mac_resource_dir(void);

// ── Statics ───────────────────────────────────────────────────────────────────
static NSStatusItem *gItem       = nil;
static NSMenuItem   *gStatusHdr  = nil;
static NSMenuItem   *gSoundItem  = nil;
static NSMenuItem   *gNotifyItem = nil;
static NSMenuItem   *gEmailItem  = nil;
static double        gPollSecs     = 2.0;
static double        gCompleteSecs = 8.0;
static TrayDelegate *gDelegate   = nil;  // forward-declared so schedulePoll can use it

// ── Dedicated serial poll queue ───────────────────────────────────────────────
// Replaces NSTimer + global concurrent queue.  Chained dispatch_after on a
// serial queue means:
//   - Only one nim_poll_tick() is ever in flight — no concurrent Nim GC access.
//   - Queue depth never grows, so icon-update latency stays constant over time.
static dispatch_queue_t gPollQueue = NULL;
static volatile BOOL    gPolling   = NO;

// ── Coloured dot icon ─────────────────────────────────────────────────────────
static NSImage *dotImage(CGFloat r, CGFloat g, CGFloat b) {
    int sz = 18;
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    CGContextRef    ctx = CGBitmapContextCreate(NULL, sz, sz, 8, 0, cs,
                              kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(1.5, 1.5, sz - 3.0, sz - 3.0));
    CGImageRef cg  = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(sz, sz)];
    CGImageRelease(cg);
    img.template = NO;
    return img;
}

static NSImage *iconForStatus(int s) {
    switch (s) {
        case 1:  return dotImage(0.00, 0.78, 0.31);   // green  - idle
        case 2:  return dotImage(1.00, 0.55, 0.00);   // orange - burning
        case 3:  return dotImage(0.00, 0.63, 1.00);   // blue   - complete
        default: return dotImage(0.39, 0.39, 0.39);   // grey   - disconnected
    }
}

// =============================================================================
// SettingsController — native settings panel (two-tab layout)
// =============================================================================
@interface SettingsController : NSObject <NSWindowDelegate>
@property (strong) NSPanel            *panel;
// Connection tab
@property (strong) NSTextField        *hostField;
@property (strong) NSTextField        *outPortField;
@property (strong) NSTextField        *inPortField;
@property (strong) NSTextField        *pollSecsField;
@property (strong) NSTextField        *completeSecsField;
@property (strong) NSTextField        *recvTimeoutField;
// Email & Alerts tab
@property (strong) NSButton           *soundCheck;
@property (strong) NSButton           *notifyCheck;
@property (strong) NSButton           *emailCheck;
@property (strong) NSTextField        *smtpHostField;
@property (strong) NSTextField        *smtpPortField;
@property (strong) NSButton           *smtpSslCheck;
@property (strong) NSTextField        *smtpUserField;
@property (strong) NSSecureTextField  *smtpPassField;
@property (strong) NSTextField        *smtpFromField;
@property (strong) NSTextField        *smtpToField;
- (void)buildPanel;
- (void)show;
@end

@implementation SettingsController

// ── UI helpers ────────────────────────────────────────────────────────────────

static NSTextField *makeLabel(NSString *text) {
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.alignment    = NSTextAlignmentRight;
    tf.font         = [NSFont systemFontOfSize:13];
    [tf setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [tf.widthAnchor constraintEqualToConstant:155].active = YES;
    return tf;
}

static NSTextField *makeField(NSString *ph) {
    NSTextField *tf      = [[NSTextField alloc] init];
    tf.placeholderString = ph;
    tf.bordered  = YES;
    tf.editable  = YES;
    tf.font      = [NSFont systemFontOfSize:13];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    return tf;
}

static NSSecureTextField *makeSecureField(NSString *ph) {
    NSSecureTextField *tf = [[NSSecureTextField alloc] init];
    tf.placeholderString  = ph;
    tf.bordered  = YES;
    tf.editable  = YES;
    tf.font      = [NSFont systemFontOfSize:13];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    return tf;
}

// Integer formatter clamped to [lo, hi] — rejects non-numeric input
static NSNumberFormatter *intFmt(int lo, int hi) {
    NSNumberFormatter *f   = [[NSNumberFormatter alloc] init];
    f.numberStyle           = NSNumberFormatterDecimalStyle;
    f.allowsFloats          = NO;
    f.minimum               = @(lo);
    f.maximum               = @(hi);
    f.usesGroupingSeparator = NO;
    return f;
}

// Float formatter clamped to [lo, hi]
static NSNumberFormatter *floatFmt(double lo, double hi) {
    NSNumberFormatter *f   = [[NSNumberFormatter alloc] init];
    f.numberStyle           = NSNumberFormatterDecimalStyle;
    f.allowsFloats          = YES;
    f.minimum               = @(lo);
    f.maximum               = @(hi);
    f.maximumFractionDigits = 2;
    f.usesGroupingSeparator = NO;
    return f;
}

static NSTextField *sectionHdr(NSString *text) {
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.font         = [NSFont boldSystemFontOfSize:11];
    tf.textColor    = [NSColor secondaryLabelColor];
    return tf;
}

// Build one horizontal row: right-aligned label (fixed width) + filling field
- (NSView *)row:(NSString *)lbl field:(NSView *)field {
    NSTextField *label = makeLabel(lbl);
    NSStackView *row   = [NSStackView stackViewWithViews:@[label, field]];
    row.orientation    = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing        = 8;
    row.alignment      = NSLayoutAttributeCenterY;
    row.distribution   = NSStackViewDistributionFill;
    [field setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

// ── Tab: Connection ───────────────────────────────────────────────────────────
- (NSTabViewItem *)buildConnectionTab {
    NSTextField *host = makeField(@"127.0.0.1");
    NSTextField *op   = makeField(@"19840"); op.formatter   = intFmt(1, 65535);
    NSTextField *ip   = makeField(@"19841"); ip.formatter   = intFmt(1, 65535);
    NSTextField *poll = makeField(@"1.0");   poll.formatter = floatFmt(0.1, 60.0);
    NSTextField *comp = makeField(@"8.0");   comp.formatter = floatFmt(1.0, 3600.0);
    NSTextField *recv = makeField(@"400");   recv.formatter = intFmt(50, 10000);

    self.hostField         = host;
    self.outPortField      = op;
    self.inPortField       = ip;
    self.pollSecsField     = poll;
    self.completeSecsField = comp;
    self.recvTimeoutField  = recv;

    NSStackView *v = [NSStackView new];
    v.orientation  = NSUserInterfaceLayoutOrientationVertical;
    v.spacing      = 9;
    v.alignment    = NSLayoutAttributeLeading;
    v.edgeInsets   = NSEdgeInsetsMake(14, 16, 14, 16);
    [v addArrangedSubview:sectionHdr(@"LIGHTBURN CONNECTION")];
    [v addArrangedSubview:[self row:@"LightBurn Host:"       field:host]];
    [v addArrangedSubview:[self row:@"Out Port:"             field:op]];
    [v addArrangedSubview:[self row:@"In Port:"              field:ip]];
    [v addArrangedSubview:sectionHdr(@"TIMING")];
    [v addArrangedSubview:[self row:@"Poll Interval (s):"    field:poll]];
    [v addArrangedSubview:[self row:@"Complete Display (s):" field:comp]];
    [v addArrangedSubview:[self row:@"Recv Timeout (ms):"    field:recv]];

    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"conn"];
    item.label = @"Connection";
    item.view  = v;
    return item;
}

// ── Tab: Email & Alerts ───────────────────────────────────────────────────────
- (NSTabViewItem *)buildEmailTab {
    NSButton *snd = [NSButton checkboxWithTitle:@"Sound Alert"           target:nil action:nil];
    NSButton *ntf = [NSButton checkboxWithTitle:@"Desktop Notifications" target:nil action:nil];
    NSButton *em  = [NSButton checkboxWithTitle:@"Email Alerts"          target:nil action:nil];
    self.soundCheck  = snd;
    self.notifyCheck = ntf;
    self.emailCheck  = em;

    NSTextField       *sh  = makeField(@"smtp.example.com");
    NSTextField       *sp  = makeField(@"587");  sp.formatter = intFmt(1, 65535);
    NSButton          *ssl = [NSButton checkboxWithTitle:@"Use STARTTLS (587) or implicit SSL (465)"
                                                  target:nil action:nil];
    NSTextField       *su  = makeField(@"user@example.com");
    NSSecureTextField *spw = makeSecureField(@"app password");
    NSTextField       *sf  = makeField(@"lightburn@example.com");
    NSTextField       *st  = makeField(@"you@example.com, other@example.com");

    self.smtpHostField = sh;
    self.smtpPortField = sp;
    self.smtpSslCheck  = ssl;
    self.smtpUserField = su;
    self.smtpPassField = spw;
    self.smtpFromField = sf;
    self.smtpToField   = st;

    NSStackView *v = [NSStackView new];
    v.orientation  = NSUserInterfaceLayoutOrientationVertical;
    v.spacing      = 9;
    v.alignment    = NSLayoutAttributeLeading;
    v.edgeInsets   = NSEdgeInsetsMake(14, 16, 14, 16);
    [v addArrangedSubview:sectionHdr(@"ALERTS")];
    [v addArrangedSubview:snd];
    [v addArrangedSubview:ntf];
    [v addArrangedSubview:em];
    [v addArrangedSubview:sectionHdr(@"SMTP EMAIL")];
    [v addArrangedSubview:[self row:@"SMTP Host:"       field:sh]];
    [v addArrangedSubview:[self row:@"SMTP Port:"       field:sp]];
    [v addArrangedSubview:ssl];
    [v addArrangedSubview:[self row:@"Username:"        field:su]];
    [v addArrangedSubview:[self row:@"Password:"        field:spw]];
    [v addArrangedSubview:[self row:@"From:"            field:sf]];
    [v addArrangedSubview:[self row:@"To (comma-sep.):" field:st]];

    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"email"];
    item.label = @"Email & Alerts";
    item.view  = v;
    return item;
}

// ── Populate fields from current Nim config ────────────────────────────────────
- (void)populateFields {
    self.hostField.stringValue         = [NSString stringWithUTF8String:nim_cfg_lb_host()];
    self.outPortField.intValue         = nim_cfg_lb_out_port();
    self.inPortField.intValue          = nim_cfg_lb_in_port();
    self.pollSecsField.doubleValue     = nim_cfg_poll_secs();
    self.completeSecsField.doubleValue = nim_cfg_complete_secs();
    self.recvTimeoutField.intValue     = nim_cfg_recv_timeout_ms();
    self.soundCheck.state  = nim_get_sound_on()  ? NSControlStateValueOn : NSControlStateValueOff;
    self.notifyCheck.state = nim_get_notify_on() ? NSControlStateValueOn : NSControlStateValueOff;
    self.emailCheck.state  = nim_get_email_on()  ? NSControlStateValueOn : NSControlStateValueOff;
    self.smtpHostField.stringValue = [NSString stringWithUTF8String:nim_cfg_smtp_host()];
    self.smtpPortField.intValue    = nim_cfg_smtp_port();
    self.smtpSslCheck.state = nim_cfg_smtp_use_ssl() ? NSControlStateValueOn : NSControlStateValueOff;
    self.smtpUserField.stringValue = [NSString stringWithUTF8String:nim_cfg_smtp_username()];
    self.smtpPassField.stringValue = [NSString stringWithUTF8String:nim_cfg_smtp_password()];
    self.smtpFromField.stringValue = [NSString stringWithUTF8String:nim_cfg_smtp_from()];
    self.smtpToField.stringValue   = [NSString stringWithUTF8String:nim_cfg_smtp_to()];
}

// ── Validate, write JSON, reload Nim ─────────────────────────────────────────
- (BOOL)saveAndApply {
    NSMutableArray *errs = [NSMutableArray array];
    NSCharacterSet *ws   = [NSCharacterSet whitespaceCharacterSet];

    NSString *host = [self.hostField.stringValue stringByTrimmingCharactersInSet:ws];
    if (host.length == 0) [errs addObject:@"LightBurn Host cannot be empty."];

    int outPort = self.outPortField.intValue;
    if (outPort < 1 || outPort > 65535) [errs addObject:@"Out Port must be 1-65535."];
    int inPort  = self.inPortField.intValue;
    if (inPort  < 1 || inPort  > 65535) [errs addObject:@"In Port must be 1-65535."];

    double pollSecs = self.pollSecsField.doubleValue;
    if (pollSecs < 0.1 || pollSecs > 60.0)
        [errs addObject:@"Poll Interval must be 0.1-60 s."];
    double completeSecs = self.completeSecsField.doubleValue;
    if (completeSecs < 1.0 || completeSecs > 3600.0)
        [errs addObject:@"Complete Display must be 1-3600 s."];
    int recvMs = self.recvTimeoutField.intValue;
    if (recvMs < 50 || recvMs > 10000)
        [errs addObject:@"Recv Timeout must be 50-10000 ms."];

    int smtpPort = self.smtpPortField.intValue;
    if (smtpPort < 1 || smtpPort > 65535)
        [errs addObject:@"SMTP Port must be 1-65535."];

    NSString *fromAddr = [self.smtpFromField.stringValue stringByTrimmingCharactersInSet:ws];
    if (fromAddr.length > 0 && [fromAddr rangeOfString:@"@"].location == NSNotFound)
        [errs addObject:@"From address does not look like a valid email."];

    if (errs.count > 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText     = @"Please fix the following:";
        a.informativeText = [errs componentsJoinedByString:@"\n"];
        a.alertStyle      = NSAlertStyleWarning;
        [a addButtonWithTitle:@"OK"];
        [a beginSheetModalForWindow:self.panel completionHandler:nil];
        [a release];
        return NO;
    }

    // Build to-address array
    NSMutableArray *toAddrs = [NSMutableArray array];
    for (NSString *p in [self.smtpToField.stringValue componentsSeparatedByString:@","]) {
        NSString *t = [p stringByTrimmingCharactersInSet:ws];
        if (t.length > 0) [toAddrs addObject:t];
    }

    NSDictionary *smtp = @{
        @"host":     [self.smtpHostField.stringValue stringByTrimmingCharactersInSet:ws],
        @"port":     @(smtpPort),
        @"useSsl":   @(self.smtpSslCheck.state == NSControlStateValueOn),
        @"username": self.smtpUserField.stringValue,
        @"password": self.smtpPassField.stringValue,
        @"fromAddr": fromAddr,
        @"toAddrs":  toAddrs,
    };
    NSDictionary *cfg = @{
        @"lbHost":        host,
        @"lbOutPort":     @(outPort),
        @"lbInPort":      @(inPort),
        @"pollSecs":      @(pollSecs),
        @"completeSecs":  @(completeSecs),
        @"recvTimeoutMs": @(recvMs),
        @"soundOn":       @(self.soundCheck.state  == NSControlStateValueOn),
        @"notifyOn":      @(self.notifyCheck.state == NSControlStateValueOn),
        @"emailOn":       @(self.emailCheck.state  == NSControlStateValueOn),
        @"smtp":          smtp,
    };

    NSString *resDir   = [NSString stringWithUTF8String:mac_resource_dir()];
    NSString *jsonPath = [resDir stringByAppendingPathComponent:@"lightburn_tray.json"];
    NSData   *data     = [NSJSONSerialization dataWithJSONObject:cfg
                                                         options:NSJSONWritingPrettyPrinted
                                                           error:nil];
    if (!data) {
        NSLog(@"[LightBurnMonitor] Failed to serialise settings");
        return NO;
    }
    [data writeToFile:jsonPath atomically:YES];

    nim_reload_settings();
    mac_update_poll_interval(nim_cfg_poll_secs());
    return YES;
}

// ── Build the panel ───────────────────────────────────────────────────────────
- (void)buildPanel {
    NSPanel *p = [[NSPanel alloc]
                  initWithContentRect:NSMakeRect(0, 0, 520, 490)
                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                               backing:NSBackingStoreBuffered
                                 defer:NO];
    p.title              = @"LightBurn Monitor \342\200\224 Settings";
    p.delegate           = self;
    p.releasedWhenClosed = NO;
    [p center];
    self.panel = p;

    NSTabView *tabs = [[NSTabView alloc] init];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [tabs addTabViewItem:[self buildConnectionTab]];
    [tabs addTabViewItem:[self buildEmailTab]];

    // Button row: [Test Email]  ........  [Cancel] [Save]
    NSButton *testBtn   = [NSButton buttonWithTitle:@"Test Email\342\200\246"
                                             target:self action:@selector(onTestEmail:)];
    NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel"
                                             target:self action:@selector(onCancel:)];
    NSButton *saveBtn   = [NSButton buttonWithTitle:@"Save"
                                             target:self action:@selector(onSave:)];
    saveBtn.keyEquivalent   = @"\r";
    cancelBtn.keyEquivalent = @"\033";

    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *btns = [NSStackView stackViewWithViews:@[testBtn, spacer, cancelBtn, saveBtn]];
    btns.orientation  = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing      = 8;
    btns.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[tabs, btns]];
    vStack.orientation  = NSUserInterfaceLayoutOrientationVertical;
    vStack.spacing      = 12;
    vStack.edgeInsets   = NSEdgeInsetsMake(16, 20, 16, 20);
    vStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *cv = p.contentView;
    [cv addSubview:vStack];
    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor      constraintEqualToAnchor:cv.topAnchor],
        [vStack.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor],
        [vStack.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [vStack.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor],
        [tabs.heightAnchor     constraintEqualToConstant:400],
    ]];
}

- (void)show {
    [self populateFields];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.panel center];
    [self.panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (IBAction)onSave:(id)sender      { if ([self saveAndApply]) [self.panel close]; }
- (IBAction)onCancel:(id)sender    { [self.panel close]; }
- (IBAction)onTestEmail:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int ok = nim_send_test_email();
        mac_show_notification(ok ? "Email Sent" : "Email Failed",
                              ok ? "Test email delivered successfully."
                                 : nim_email_last_error());
    });
}

@end  // SettingsController

// =============================================================================
// TrayDelegate — NSApplication / status-bar delegate
// =============================================================================
@interface TrayDelegate : NSObject <NSApplicationDelegate,
                                    UNUserNotificationCenterDelegate>
@property (strong) NSTimer            *completeTimer;
@property (strong) SettingsController *settingsCtrl;
- (NSMenu *)buildMenu;
- (void)syncMenuItems;
- (void)startCompleteTimer;
- (void)schedulePoll;
@end

@implementation TrayDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    gItem = [[[NSStatusBar systemStatusBar]
              statusItemWithLength:NSSquareStatusItemLength] retain];
    gItem.button.image   = iconForStatus(nim_get_status());
    gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
    gItem.menu           = [self buildMenu];

    self.settingsCtrl = [[SettingsController alloc] init];
    [self.settingsCtrl buildPanel];

    // Notification permission
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText     = @"Notification Permission Needed";
                alert.informativeText =
                    @"LightBurn Monitor needs permission to show notifications "
                    @"when a burn completes.\n\nPlease enable it in "
                    @"System Settings \342\206\222 Notifications \342\206\222 LightBurnMonitor.";
                alert.alertStyle = NSAlertStyleWarning;
                [alert addButtonWithTitle:@"Open System Settings"];
                [alert addButtonWithTitle:@"Dismiss"];
                NSModalResponse resp = [alert runModal];
                if (resp == NSAlertFirstButtonReturn) {
                    NSURL *url = [NSURL URLWithString:
                        @"x-apple.systempreferences:com.apple.Notifications-Settings"];
                    [[NSWorkspace sharedWorkspace] openURL:url];
                }
                [alert release];
            });
        }
    }];

    // Start the serial poll chain
    gPollQueue = dispatch_queue_create("com.lightburn.poll", DISPATCH_QUEUE_SERIAL);
    gPolling   = YES;
    [self schedulePoll];
}

// ── Chained serial poll ───────────────────────────────────────────────────────
// Each poll schedules the NEXT poll only after itself completes, so queue depth
// never grows regardless of how long nim_poll_tick() blocks.
- (void)schedulePoll {
    if (!gPolling) return;
    int64_t ns = (int64_t)(gPollSecs * NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), gPollQueue, ^{
        if (!gPolling) return;
        nim_poll_tick();                          // blocks up to recvTimeoutMs on serial queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gDelegate) return;
            gItem.button.image   = iconForStatus(nim_get_status());
            gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
            if (gStatusHdr)
                gStatusHdr.title = [NSString stringWithUTF8String:nim_status_label()];
            [gDelegate syncMenuItems];
        });
        if (gDelegate) [gDelegate schedulePoll];  // schedule next poll after this one finishes
    });
}

// ── Build menu ────────────────────────────────────────────────────────────────
- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    gStatusHdr = [[NSMenuItem alloc]
                   initWithTitle:[NSString stringWithUTF8String:nim_status_label()]
                          action:nil keyEquivalent:@""];
    gStatusHdr.enabled = NO;
    [menu addItem:gStatusHdr];
    [menu addItem:[NSMenuItem separatorItem]];

    gNotifyItem = [[NSMenuItem alloc]
                    initWithTitle:nim_get_notify_on() ? @"Notifications: On" : @"Notifications: Off"
                           action:@selector(onNotify:) keyEquivalent:@""];
    gNotifyItem.state  = nim_get_notify_on() ? NSControlStateValueOn : NSControlStateValueOff;
    gNotifyItem.target = self;
    [menu addItem:gNotifyItem];

    gSoundItem = [[NSMenuItem alloc]
                   initWithTitle:nim_get_sound_on() ? @"Sound: On" : @"Sound: Off"
                          action:@selector(onSound:) keyEquivalent:@""];
    gSoundItem.state  = nim_get_sound_on() ? NSControlStateValueOn : NSControlStateValueOff;
    gSoundItem.target = self;
    [menu addItem:gSoundItem];

    gEmailItem = [[NSMenuItem alloc]
                   initWithTitle:nim_get_email_on() ? @"Email Alert: On" : @"Email Alert: Off"
                          action:@selector(onEmail:) keyEquivalent:@""];
    gEmailItem.state  = nim_get_email_on() ? NSControlStateValueOn : NSControlStateValueOff;
    gEmailItem.target = self;
    [menu addItem:gEmailItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Settings... (Test Email is inside the settings window)
    NSMenuItem *settingsItem = [[NSMenuItem alloc]
                                 initWithTitle:@"Settings\342\200\246"
                                        action:@selector(onSettings:)
                                 keyEquivalent:@","];
    settingsItem.target = self;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *exitItem = [[NSMenuItem alloc]
                             initWithTitle:@"Exit"
                                    action:@selector(onExit:) keyEquivalent:@"q"];
    exitItem.target = self;
    [menu addItem:exitItem];

    return menu;
}

- (IBAction)onSound:(id)sender    { nim_toggle_sound();  [self syncMenuItems]; }
- (IBAction)onNotify:(id)sender   { nim_toggle_notify(); [self syncMenuItems]; }
- (IBAction)onEmail:(id)sender    { nim_toggle_email();  [self syncMenuItems]; }
- (IBAction)onExit:(id)sender     { nim_do_exit(); }
- (IBAction)onSettings:(id)sender { [self.settingsCtrl show]; }

- (void)syncMenuItems {
    gSoundItem.title  = nim_get_sound_on()  ? @"Sound: On"         : @"Sound: Off";
    gSoundItem.state  = nim_get_sound_on()  ? NSControlStateValueOn : NSControlStateValueOff;
    gNotifyItem.title = nim_get_notify_on() ? @"Notifications: On" : @"Notifications: Off";
    gNotifyItem.state = nim_get_notify_on() ? NSControlStateValueOn : NSControlStateValueOff;
    gEmailItem.title  = nim_get_email_on()  ? @"Email Alert: On"   : @"Email Alert: Off";
    gEmailItem.state  = nim_get_email_on()  ? NSControlStateValueOn : NSControlStateValueOff;
}

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

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList  |
                      UNNotificationPresentationOptionSound);
}

@end  // TrayDelegate

// ── C API called from Nim ─────────────────────────────────────────────────────

void mac_setup(double pollSecs, double completeSecs) {
    gPollSecs     = pollSecs;
    gCompleteSecs = completeSecs;
}

void mac_run(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    gDelegate      = [[TrayDelegate alloc] init];
    NSApp.delegate = gDelegate;
    [NSApp run];
}

void mac_update_poll_interval(double newSecs) {
    // gPollSecs is read by schedulePoll at the start of each chained dispatch.
    // Updating it here takes effect for the very next scheduled poll.
    gPollSecs     = newSecs;
    gCompleteSecs = nim_cfg_complete_secs();
}

const char *mac_resource_dir(void) {
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
            addNotificationRequest:req withCompletionHandler:^(NSError *error) {
                if (error) NSLog(@"[LightBurnMonitor] Notification error: %@", error);
            }];
    });
}

void mac_start_complete_timer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [gDelegate startCompleteTimer]; });
}

void mac_stop_all_timers(void) {
    gPolling = NO;   // stops the schedulePoll chain after the current in-flight poll
    dispatch_async(dispatch_get_main_queue(), ^{ [gDelegate stopCompleteTimer]; });
}

void mac_quit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
