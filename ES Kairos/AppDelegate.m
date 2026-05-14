//
//  AppDelegate.m
//  Kairos
//
//  Authorization is requested before the MCP server starts accepting calls.
//  Both EventKit and Contacts use async completion handlers; we fire them
//  both and let them settle. Tool handlers check isAuthorized at call time
//  and return a clear error if the user denied.
//

#import "AppDelegate.h"
#import "EKBridge.h"
#import "CNBridge.h"
#import "MCPServer.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    fprintf(stderr, "[Kairos] applicationDidFinishLaunching\n");

    // CRITICAL: macOS TCC serializes permission dialogs. Two requestAccess
    // calls back-to-back race — the second is often silently denied
    // without a prompt. Chain them: Contacts only fires AFTER Calendar
    // settles, AND hop back to the main thread + short delay so the
    // Calendar dialog has fully dismissed before Contacts attempts to
    // present its own.

    [[EKBridge shared] requestAccessWithCompletion:^(BOOL granted, NSError *error) {
        fprintf(stderr, "[Kairos] calendar access: %s%s\n",
                granted ? "granted" : "denied",
                error ? [NSString stringWithFormat:@" (%@)", error.localizedDescription].UTF8String : "");

        // Hop to main thread with a short delay so the Calendar prompt's
        // dismissal animation completes and TCC's internal lock releases
        // before we ask for Contacts.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[CNBridge shared] requestAccessWithCompletion:^(BOOL cnGranted, NSError *cnError) {
                fprintf(stderr, "[Kairos] contacts access: %s%s\n",
                        cnGranted ? "granted" : "denied",
                        cnError ? [NSString stringWithFormat:@" (%@)", cnError.localizedDescription].UTF8String : "");
                if (cnError) {
                    fprintf(stderr, "[Kairos] contacts error detail — domain=%s code=%ld userInfo=%s\n",
                            cnError.domain.UTF8String,
                            (long)cnError.code,
                            cnError.userInfo.description.UTF8String ?: "(none)");
                }

                // And finally Reminders, again on main thread with delay so
                // the third dialog doesn't race the Contacts dismissal.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [[EKBridge shared] requestRemindersAccessWithCompletion:^(BOOL rGranted, NSError *rError) {
                        fprintf(stderr, "[Kairos] reminders access: %s%s\n",
                                rGranted ? "granted" : "denied",
                                rError ? [NSString stringWithFormat:@" (%@)", rError.localizedDescription].UTF8String : "");
                    }];
                });
            }];
        });
    }];

    [[MCPServer shared] start];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    fprintf(stderr, "[Kairos] terminating\n");
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

@end
