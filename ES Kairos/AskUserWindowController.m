//
//  AskUserWindowController.m
//  Kairos
//
//  Adapted from ES UITest/AskUserWindowController.m — logic unchanged,
//  window title updated.
//

#import "AskUserWindowController.h"

@interface AskUserWindowController ()
@property (strong) NSTextField *promptLabel;
@property (strong) NSTextField *inputField;
@property (strong) NSButton    *okButton;
@property (strong) NSButton    *cancelButton;
@property (copy)   void (^completionHandler)(NSString *_Nullable);
@property (assign) BOOL didFire;
@end

static AskUserWindowController *gCurrent = nil;

@implementation AskUserWindowController

+ (BOOL)presentQuestion:(NSString *)question
             completion:(void (^)(NSString *_Nullable))completion {
    NSAssert(NSThread.isMainThread, @"presentQuestion: must be called on the main thread");
    if (gCurrent) return NO;

    AskUserWindowController *ctrl =
        [[AskUserWindowController alloc] initWithQuestion:question completion:completion];
    gCurrent = ctrl;

    [NSApp activateIgnoringOtherApps:YES];
    [ctrl showWindow:nil];
    [ctrl.window center];
    [ctrl.window makeKeyAndOrderFront:nil];
    [ctrl.window makeFirstResponder:ctrl.inputField];
    return YES;
}

- (instancetype)initWithQuestion:(NSString *)question
                      completion:(void (^)(NSString *_Nullable))completion {
    NSRect frame = NSMakeRect(0, 0, 460, 170);
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

    _promptLabel = [NSTextField wrappingLabelWithString:question ?: @""];
    _promptLabel.frame = NSMakeRect(20, 96, 420, 56);
    _promptLabel.font = [NSFont systemFontOfSize:13];
    _promptLabel.selectable = NO;
    [content addSubview:_promptLabel];

    _inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 60, 420, 24)];
    _inputField.font = [NSFont systemFontOfSize:13];
    _inputField.target = self;
    _inputField.action = @selector(okClicked:);
    _inputField.placeholderString = @"Type your answer and press Return";
    [content addSubview:_inputField];

    _cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                       target:self
                                       action:@selector(cancelClicked:)];
    _cancelButton.frame = NSMakeRect(258, 14, 90, 32);
    _cancelButton.keyEquivalent = @"\e";
    [content addSubview:_cancelButton];

    _okButton = [NSButton buttonWithTitle:@"OK"
                                   target:self
                                   action:@selector(okClicked:)];
    _okButton.frame = NSMakeRect(354, 14, 90, 32);
    _okButton.keyEquivalent = @"\r";
    [content addSubview:_okButton];

    return self;
}

- (void)okClicked:(id)sender     { [self finishWithAnswer:self.inputField.stringValue ?: @""]; }
- (void)cancelClicked:(id)sender { [self finishWithAnswer:nil]; }

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self finishWithAnswer:nil];
    return YES;
}

- (void)finishWithAnswer:(NSString *_Nullable)answer {
    if (self.didFire) return;
    self.didFire = YES;

    void (^cb)(NSString *_Nullable) = self.completionHandler;
    self.completionHandler = nil;

    [self.window orderOut:nil];
    if (cb) cb(answer);
    if (gCurrent == self) gCurrent = nil;
}

@end
