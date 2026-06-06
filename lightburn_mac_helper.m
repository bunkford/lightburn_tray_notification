// lightburn_mac_helper.m
// ─────────────────────────────────────────────────────────────────────────────
// Objective-C / AppKit implementation of the LightBurn Monitor tray icon.
// Compiled by Nim via {.compile: "lightburn_mac_helper.m".} in
// lightburn_tray_mac.nim.
// ─────────────────────────────────────────────────────────────────────────────

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <Security/Security.h>

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
extern void        nim_set_smtp_password(const char *pw);

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
static TrayDelegate *gDelegate   = nil;   // forward-declared so schedulePoll can use it

// ── Dedicated serial poll queue ───────────────────────────────────────────────
// Chained dispatch_after on a serial queue: only one nim_poll_tick() is ever
// in flight, preventing queue depth growth and Nim GC thread-safety issues.
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
// Keychain helpers — SMTP password stored under service "LightBurnMonitor"
// =============================================================================
#define KC_SERVICE "LightBurnMonitor"
#define KC_ACCOUNT "smtp"

static char gKcPwBuf[1024];

// Delete-then-add so we handle both create and update.
static void mac_save_to_keychain(const char *password) {
    NSDictionary *del = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @KC_SERVICE,
        (__bridge id)kSecAttrAccount: @KC_ACCOUNT,
    };
    SecItemDelete((__bridge CFDictionaryRef)del);
    if (!password || password[0] == '\0') return;
    NSDictionary *add = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @KC_SERVICE,
        (__bridge id)kSecAttrAccount: @KC_ACCOUNT,
        (__bridge id)kSecValueData:   [NSData dataWithBytes:password length:strlen(password)],
    };
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

// Returns pointer to a static buffer; valid until next call.
static const char *mac_load_from_keychain(void) {
    gKcPwBuf[0] = '\0';
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @KC_SERVICE,
        (__bridge id)kSecAttrAccount: @KC_ACCOUNT,
        (__bridge id)kSecReturnData:  @YES,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    CFDataRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (st == errSecSuccess && result != NULL) {
        CFIndex len = CFDataGetLength(result);
        if (len >= (CFIndex)sizeof(gKcPwBuf)) len = sizeof(gKcPwBuf) - 1;
        memcpy(gKcPwBuf, CFDataGetBytePtr(result), (size_t)len);
        gKcPwBuf[len] = '\0';
        CFRelease(result);
    }
    return gKcPwBuf;
}

// =============================================================================
// SettingsController - native two-tab settings panel
// =============================================================================

// ── Layout constants ──────────────────────────────────────────────────────────
// All positions are relative to the tab content view's bounds.
// Labels go from LBL_LEAD to (FLD_LEAD-8); fields go from FLD_LEAD to (width-FLD_TRAIL).
#define LBL_LEAD   10    // label leading inset
#define FLD_LEAD  174    // field leading x (right of the label column)
#define FLD_TRAIL  14    // field trailing margin
#define ROW_H      22    // text-field height
#define ROW_GAP     9    // vertical gap between consecutive rows
#define SEC_GAP    16    // extra gap before a section header
#define TOP_PAD    16    // top padding inside the tab content view

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

// ── Number formatters ─────────────────────────────────────────────────────────

static NSNumberFormatter *intFmt(int lo, int hi) {
    NSNumberFormatter *f   = [[NSNumberFormatter alloc] init];
    f.numberStyle           = NSNumberFormatterDecimalStyle;
    f.allowsFloats          = NO;
    f.minimum               = @(lo);
    f.maximum               = @(hi);
    f.usesGroupingSeparator = NO;
    return f;
}

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

// ── Widget factories ──────────────────────────────────────────────────────────

static NSTextField *sectionHdr(NSString *text) {
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.font         = [NSFont boldSystemFontOfSize:11];
    tf.textColor    = [NSColor secondaryLabelColor];
    return tf;
}

// Plain editable text field. translatesAutoresizingMaskIntoConstraints is left
// as YES (default); the addRow helper will set it to NO before adding constraints.
static NSTextField *makeField(NSString *ph) {
    NSTextField *tf      = [[NSTextField alloc] init];
    tf.placeholderString = ph;
    tf.bordered          = YES;
    tf.editable          = YES;
    tf.usesSingleLineMode = YES;
    tf.font              = [NSFont systemFontOfSize:13];
    return tf;
}

static NSSecureTextField *makeSecureField(NSString *ph) {
    NSSecureTextField *tf = [[NSSecureTextField alloc] init];
    tf.placeholderString  = ph;
    tf.bordered           = YES;
    tf.editable           = YES;
    tf.font               = [NSFont systemFontOfSize:13];
    return tf;
}

// ── Auto-Layout row helpers ───────────────────────────────────────────────────
// Each helper adds subview(s) to `p`, applies constraints, and returns the
// bottomAnchor of the last view added so callers can chain rows vertically.

// Section header (bold small-caps label spanning from LBL_LEAD)
static NSLayoutYAxisAnchor *addHdr(NSView *p, NSLayoutYAxisAnchor *top,
                                    CGFloat gap, NSString *text) {
    NSTextField *hdr = sectionHdr(text);
    hdr.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:hdr];
    [hdr.leadingAnchor  constraintEqualToAnchor:p.leadingAnchor constant:LBL_LEAD].active = YES;
    [hdr.topAnchor      constraintEqualToAnchor:top constant:gap].active = YES;
    return hdr.bottomAnchor;
}

// Right-aligned label + full-width text field.
// Label occupies LBL_LEAD … (FLD_LEAD-8); field spans FLD_LEAD … (trailing - FLD_TRAIL).
static NSLayoutYAxisAnchor *addRow(NSView *p, NSLayoutYAxisAnchor *top,
                                    CGFloat gap, NSString *lbl, NSView *fld) {
    NSTextField *lb = [NSTextField labelWithString:lbl];
    lb.font      = [NSFont systemFontOfSize:13];
    lb.alignment = NSTextAlignmentRight;
    lb.translatesAutoresizingMaskIntoConstraints = NO;
    fld.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:lb];
    [p addSubview:fld];
    // Label: pinned left and right within the label column
    [lb.leadingAnchor   constraintEqualToAnchor:p.leadingAnchor constant:LBL_LEAD].active = YES;
    [lb.trailingAnchor  constraintEqualToAnchor:p.leadingAnchor constant:(FLD_LEAD - 8)].active = YES;
    [lb.centerYAnchor   constraintEqualToAnchor:fld.centerYAnchor].active = YES;
    // Field: spans from FLD_LEAD to trailing-FLD_TRAIL, fixed height ROW_H
    [fld.leadingAnchor  constraintEqualToAnchor:p.leadingAnchor constant:FLD_LEAD].active = YES;
    [fld.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-FLD_TRAIL].active = YES;
    [fld.heightAnchor   constraintEqualToConstant:ROW_H].active = YES;
    [fld.topAnchor      constraintEqualToAnchor:top constant:gap].active = YES;
    return fld.bottomAnchor;
}

// Checkbox aligned with the field leading edge (indented same as fields).
static NSLayoutYAxisAnchor *addChk(NSView *p, NSLayoutYAxisAnchor *top,
                                    CGFloat gap, NSButton *btn) {
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:btn];
    [btn.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:FLD_LEAD].active = YES;
    [btn.topAnchor     constraintEqualToAnchor:top constant:gap].active = YES;
    return btn.bottomAnchor;
}

// ── Tab: Connection ───────────────────────────────────────────────────────────
- (NSTabViewItem *)buildConnectionTab {
    NSTextField *host = makeField(@"127.0.0.1");
    NSTextField *op   = makeField(@"19840");  op.formatter   = intFmt(1, 65535);
    NSTextField *ip   = makeField(@"19841");  ip.formatter   = intFmt(1, 65535);
    NSTextField *poll = makeField(@"1.0");    poll.formatter = floatFmt(0.1, 60.0);
    NSTextField *comp = makeField(@"8.0");    comp.formatter = floatFmt(1.0, 3600.0);
    NSTextField *recv = makeField(@"400");    recv.formatter = intFmt(50, 10000);

    self.hostField         = host;
    self.outPortField      = op;
    self.inPortField       = ip;
    self.pollSecsField     = poll;
    self.completeSecsField = comp;
    self.recvTimeoutField  = recv;

    // Content view — tab view will resize this to fill its content area.
    // Our subviews use Auto Layout constraints relative to this view's bounds.
    NSView *v = [[NSView alloc] init];
    NSLayoutYAxisAnchor *top = v.topAnchor;
    top = addHdr(v, top, TOP_PAD,  @"LIGHTBURN CONNECTION");
    top = addRow(v, top, ROW_GAP,  @"LightBurn Host:", host);
    top = addRow(v, top, ROW_GAP,  @"Out Port:",       op);
    top = addRow(v, top, ROW_GAP,  @"In Port:",        ip);
    top = addHdr(v, top, SEC_GAP,  @"TIMING");
    top = addRow(v, top, ROW_GAP,  @"Poll Interval (s):",    poll);
    top = addRow(v, top, ROW_GAP,  @"Complete Display (s):", comp);
    top = addRow(v, top, ROW_GAP,  @"Recv Timeout (ms):",    recv);
    (void)top;

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

    NSView *v = [[NSView alloc] init];
    NSLayoutYAxisAnchor *top = v.topAnchor;
    top = addHdr(v, top, TOP_PAD,  @"ALERTS");
    top = addChk(v, top, ROW_GAP,  snd);
    top = addChk(v, top, ROW_GAP,  ntf);
    top = addChk(v, top, ROW_GAP,  em);
    top = addHdr(v, top, SEC_GAP,  @"SMTP EMAIL");
    top = addRow(v, top, ROW_GAP,  @"SMTP Host:",       sh);
    top = addRow(v, top, ROW_GAP,  @"SMTP Port:",       sp);
    top = addChk(v, top, ROW_GAP,  ssl);
    top = addRow(v, top, ROW_GAP,  @"Username:",        su);
    top = addRow(v, top, ROW_GAP,  @"Password:",        spw);
    top = addRow(v, top, ROW_GAP,  @"From:",            sf);
    top = addRow(v, top, ROW_GAP,  @"To (comma-sep.):", st);
    (void)top;

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
    for (NSString *part in [self.smtpToField.stringValue componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:ws];
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
    // Restore SMTP password: nim_reload_settings() wiped it (JSON holds no password).
    // Save the user-entered value to Keychain and restore it in Nim's state.
    const char *pw = self.smtpPassField.stringValue.UTF8String ?: "";
    mac_save_to_keychain(pw);
    nim_set_smtp_password(pw);
    mac_update_poll_interval(nim_cfg_poll_secs());
    return YES;
}

// ── Build the settings panel ──────────────────────────────────────────────────
- (void)buildPanel {
    // Panel content height: TOP(16) + tabs(435) + gap(12) + buttons(28) + BOTTOM(16) = 507
    NSPanel *p = [[NSPanel alloc]
                  initWithContentRect:NSMakeRect(0, 0, 560, 507)
                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                               backing:NSBackingStoreBuffered
                                 defer:NO];
    p.title              = @"LightBurn Monitor \342\200\224 Settings";
    p.delegate           = self;
    p.releasedWhenClosed = NO;
    [p center];
    self.panel = p;

    // Tab view
    NSTabView *tabs = [[NSTabView alloc] init];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [tabs addTabViewItem:[self buildConnectionTab]];
    [tabs addTabViewItem:[self buildEmailTab]];

    // Button row: [Test Email] ...spacer... [Cancel] [Save]
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
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing     = 8;
    btns.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *cv = p.contentView;
    [cv addSubview:tabs];
    [cv addSubview:btns];

    [NSLayoutConstraint activateConstraints:@[
        // Tab view: top / sides / explicit height
        [tabs.topAnchor      constraintEqualToAnchor:cv.topAnchor    constant:16],
        [tabs.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor constant:16],
        [tabs.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-16],
        [tabs.heightAnchor   constraintEqualToConstant:435],
        // Button row: below tabs / sides / bottom
        [btns.topAnchor      constraintEqualToAnchor:tabs.bottomAnchor constant:12],
        [btns.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor  constant:16],
        [btns.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-16],
        [btns.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor   constant:-16],
    ]];
}

// ── Show / hide ───────────────────────────────────────────────────────────────
- (void)show {
    [self populateFields];
    // Temporarily raise activation policy so the panel can become key
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.panel center];
    [self.panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

// ── Actions ───────────────────────────────────────────────────────────────────
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

    // Load SMTP password from macOS Keychain into Nim state.
    // Migrates transparently: if Keychain is empty but JSON had a plaintext
    // password (older versions), save it to Keychain now.
    {
        const char *kc_pw = mac_load_from_keychain();
        if (kc_pw[0] != '\0') {
            nim_set_smtp_password(kc_pw);   // Keychain value wins
        } else {
            // Nothing in Keychain — check if an old JSON password was loaded
            const char *json_pw = nim_cfg_smtp_password();
            if (json_pw && json_pw[0] != '\0') {
                mac_save_to_keychain(json_pw);  // migrate to Keychain
                // gCfg.smtp.password already has the value; no need to call nim_set_smtp_password
            }
        }
    }

    // Request notification permission
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
// Each iteration schedules the NEXT one only AFTER the current poll completes,
// so the queue never accumulates a backlog and latency stays constant over time.
- (void)schedulePoll {
    if (!gPolling) return;
    int64_t ns = (int64_t)(gPollSecs * NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), gPollQueue, ^{
        if (!gPolling) return;
        nim_poll_tick();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gDelegate) return;
            gItem.button.image   = iconForStatus(nim_get_status());
            gItem.button.toolTip = [NSString stringWithUTF8String:nim_status_label()];
            if (gStatusHdr)
                gStatusHdr.title = [NSString stringWithUTF8String:nim_status_label()];
            [gDelegate syncMenuItems];
        });
        if (gDelegate) [gDelegate schedulePoll];
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

    // Settings... (Test Email lives inside)
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

// ── Menu actions ──────────────────────────────────────────────────────────────
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

// ── Complete timer ────────────────────────────────────────────────────────────
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
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList  |
                      UNNotificationPresentationOptionSound);
}

@end  // TrayDelegate

// =============================================================================
// C API called from Nim (lightburn_tray_mac.nim)
// =============================================================================

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
    gPolling = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ [gDelegate stopCompleteTimer]; });
}

void mac_quit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
