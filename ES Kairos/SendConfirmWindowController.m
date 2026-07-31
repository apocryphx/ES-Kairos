//
//  SendConfirmWindowController.m
//  Kairos
//

#import "SendConfirmWindowController.h"

@interface SendConfirmWindowController ()
@property (strong) NSButton *sendButton;
@property (strong) NSButton *cancelButton;
@property (copy)   void (^completionHandler)(BOOL);
@property (assign) BOOL didFire;
@end

static SendConfirmWindowController *gCurrent = nil;

@implementation SendConfirmWindowController

+ (BOOL)presentWithTitle:(NSString *)title
              recipients:(NSArray<NSString *> *)recipients
                 subject:(NSString *)subject
                    body:(NSString *)body
              completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"presentWithTitle: must be called on the main thread");
    if (gCurrent) return NO;

    SendConfirmWindowController *ctrl =
        [[SendConfirmWindowController alloc] initWithTitle:title
                                                recipients:recipients
                                                   subject:subject
                                                      body:body
                                                completion:completion];
    gCurrent = ctrl;

    [NSApp activateIgnoringOtherApps:YES];
    [ctrl showWindow:nil];
    [ctrl.window center];
    [ctrl.window makeKeyAndOrderFront:nil];
    return YES;
}

+ (BOOL)runBlockingWithTitle:(NSString *)title
                  recipients:(NSArray<NSString *> *)recipients
                     subject:(NSString *)subject
                        body:(NSString *)body {
    NSAssert(!NSThread.isMainThread, @"runBlockingWithTitle: would deadlock on the main thread");

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL confirmed = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL presented = [self presentWithTitle:title
                                     recipients:recipients
                                        subject:subject
                                           body:body
                                     completion:^(BOOL ok) {
            confirmed = ok;
            dispatch_semaphore_signal(sem);
        }];
        // Another dialog is up — treat as declined rather than queueing
        // a second outgoing-mail decision behind the first.
        if (!presented) dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return confirmed;
}

- (instancetype)initWithTitle:(NSString *)title
                   recipients:(NSArray<NSString *> *)recipients
                      subject:(NSString *)subject
                         body:(NSString *)body
                   completion:(void (^)(BOOL))completion {
    NSRect frame = NSMakeRect(0, 0, 560, 460);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Kairos";
    window.releasedWhenClosed = NO;
    window.level = NSFloatingWindowLevel;

    self = [super initWithWindow:window];
    if (!self) return nil;

    _completionHandler = [completion copy];
    window.delegate = self;

    NSView *content = window.contentView;

    NSTextField *titleLabel = [NSTextField wrappingLabelWithString:title ?: @"Send this email?"];
    titleLabel.frame = NSMakeRect(20, 424, 520, 22);
    titleLabel.font = [NSFont boldSystemFontOfSize:14];
    titleLabel.selectable = NO;
    [content addSubview:titleLabel];

    NSString *toLine = [NSString stringWithFormat:@"To: %@",
                        recipients.count ? [recipients componentsJoinedByString:@", "]
                                         : @"(no recipients)"];
    NSTextField *toLabel = [NSTextField wrappingLabelWithString:toLine];
    toLabel.frame = NSMakeRect(20, 384, 520, 36);
    toLabel.font = [NSFont systemFontOfSize:12];
    [content addSubview:toLabel];

    NSTextField *subjectLabel = [NSTextField wrappingLabelWithString:
                                 [NSString stringWithFormat:@"Subject: %@", subject ?: @""]];
    subjectLabel.frame = NSMakeRect(20, 356, 520, 22);
    subjectLabel.font = [NSFont systemFontOfSize:12];
    [content addSubview:subjectLabel];

    NSScrollView *scroll = [[NSScrollView alloc]
                            initWithFrame:NSMakeRect(20, 60, 520, 288)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSTextView *bodyView = [[NSTextView alloc]
        initWithFrame:NSMakeRect(0, 0, scroll.contentSize.width, scroll.contentSize.height)];
    bodyView.editable = NO;
    bodyView.font = [NSFont systemFontOfSize:12];
    bodyView.string = body ?: @"";
    bodyView.autoresizingMask = NSViewWidthSizable;
    bodyView.textContainerInset = NSMakeSize(6, 8);
    scroll.documentView = bodyView;
    [content addSubview:scroll];

    _cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                       target:self
                                       action:@selector(cancelClicked:)];
    _cancelButton.frame = NSMakeRect(354, 14, 90, 32);
    _cancelButton.keyEquivalent = @"\e";
    [content addSubview:_cancelButton];

    _sendButton = [NSButton buttonWithTitle:@"Send"
                                     target:self
                                     action:@selector(sendClicked:)];
    _sendButton.frame = NSMakeRect(450, 14, 90, 32);
    // Deliberately NO key equivalent: the dialog steals keyboard focus
    // when it appears, and a Return already in flight from typing must
    // never send email. Sending requires a mouse click; Escape cancels.
    [content addSubview:_sendButton];

    return self;
}

- (void)sendClicked:(id)sender   { [self finishConfirmed:YES]; }
- (void)cancelClicked:(id)sender { [self finishConfirmed:NO]; }

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self finishConfirmed:NO];
    return YES;
}

- (void)finishConfirmed:(BOOL)confirmed {
    if (self.didFire) return;
    self.didFire = YES;

    void (^cb)(BOOL) = self.completionHandler;
    self.completionHandler = nil;

    [self.window orderOut:nil];
    if (cb) cb(confirmed);
    if (gCurrent == self) gCurrent = nil;
}

@end
