//
//  EKBridge+Testing.h
//  Kairos
//
//  Test-target-only header exposing pure helpers and the underlying
//  EKEventStore so XCTest can construct a throwaway local calendar
//  for round-trip tests. Not imported by the app target.
//

#import "EKBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface EKBridge (Testing)

+ (NSString *)stringForCalendarType:(EKCalendarType)type;

/// Direct access to the underlying store. Tests must dispatch onto the
/// bridge's queue if they touch this from another thread — but creating
/// and removing a calendar from setUp/tearDown on a fresh test instance
/// is safe.
@property (readonly) EKEventStore *underlyingStore;

@end

NS_ASSUME_NONNULL_END
