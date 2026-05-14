//
//  MCPServer+Testing.h
//  Kairos
//
//  Test-target-only header exposing pure helpers and the tool-definitions
//  catalogue so XCTest can validate the MCP surface without touching stdio.
//

#import "MCPServer.h"
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPServer (Testing)

+ (EKSpan)spanFromString:(nullable NSString *)s;

/// Pure (no side effects, no state) — safe to call from tests.
- (NSArray *)toolDefinitions;

@end

NS_ASSUME_NONNULL_END
