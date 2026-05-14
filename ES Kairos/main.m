//
//  main.m
//  Kairos
//
//  Same pattern as ES UITest/main.m. Bypasses NSApplicationMain so the
//  stock MainMenu.xib window is never loaded (see ES UITest §10.3).
//  NSApp.delegate is held in a static to survive ARC scope exit (§10.4).
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#include <stdio.h>

static AppDelegate *gAppDelegate = nil;

int main(int argc, const char *argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);   // JSON-RPC channel — never buffer
    setvbuf(stderr, NULL, _IONBF, 0);   // diagnostics — never buffer (§10.1)
    fprintf(stderr, "[Kairos] main() pid=%d\n", getpid());

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        gAppDelegate = [[AppDelegate alloc] init];
        app.delegate = gAppDelegate;

        [app run];
    }
    return 0;
}
