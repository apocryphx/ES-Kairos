//
//  AskUserWindowController.h
//  Kairos
//
//  Native popup that presents a question and returns the typed answer.
//  Adapted from ES UITest/AskUserWindowController.h — logic unchanged.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AskUserWindowController : NSWindowController <NSWindowDelegate>

/// Single-flight: returns NO if a popup is already on screen.
/// Must be called on the main thread.
/// Completion is invoked on the main thread with the typed string, or nil on cancel.
+ (BOOL)presentQuestion:(NSString *)question
             completion:(void (^)(NSString *_Nullable answer))completion;

@end

NS_ASSUME_NONNULL_END
