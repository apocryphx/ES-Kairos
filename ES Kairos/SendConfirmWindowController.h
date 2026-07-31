//
//  SendConfirmWindowController.h
//  Kairos
//
//  Native confirmation dialog for outgoing mail — the hard gate between
//  Claude and the outside world. Shows every recipient, the subject, and
//  the FULL body in a scrollable view; nothing is sent unless the user
//  clicks Send. Modeled on AskUserWindowController.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SendConfirmWindowController : NSWindowController <NSWindowDelegate>

/// Single-flight: returns NO if a dialog is already on screen.
/// Must be called on the main thread.
/// Completion is invoked on the main thread with YES only on Send.
+ (BOOL)presentWithTitle:(NSString *)title
              recipients:(NSArray<NSString *> *)recipients
                 subject:(NSString *)subject
                    body:(NSString *)body
              completion:(void (^)(BOOL confirmed))completion;

/// Convenience for tool handlers: dispatches to the main thread and blocks
/// the calling (work-queue) thread until the user decides — the same
/// semaphore pattern as the delete alerts (dragon N.5). Returns YES only
/// on Send; a dialog already on screen counts as Cancel.
/// MUST NOT be called on the main thread.
+ (BOOL)runBlockingWithTitle:(NSString *)title
                  recipients:(NSArray<NSString *> *)recipients
                     subject:(NSString *)subject
                        body:(NSString *)body;

@end

NS_ASSUME_NONNULL_END
