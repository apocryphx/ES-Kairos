//
//  EKBridgeDateTests.m
//

#import <XCTest/XCTest.h>
#import "EKBridge.h"

@interface EKBridgeDateTests : XCTestCase
@end

@implementation EKBridgeDateTests

- (EKBridge *)bridge { return [EKBridge shared]; }

- (void)testParseISOWithZuluZone {
    NSDate *d = [self.bridge parseDateString:@"2026-05-14T00:00:00Z"];
    XCTAssertNotNil(d);
    NSDateComponents *c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone timeZoneWithName:@"UTC"] fromDate:d];
    XCTAssertEqual(c.year,  2026);
    XCTAssertEqual(c.month, 5);
    XCTAssertEqual(c.day,   14);
    XCTAssertEqual(c.hour,  0);
}

- (void)testParseISOWithOffset {
    NSDate *d = [self.bridge parseDateString:@"2026-05-14T10:00:00-04:00"];
    XCTAssertNotNil(d);
    // 10:00 -04:00 = 14:00 UTC
    NSDateComponents *c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone timeZoneWithName:@"UTC"] fromDate:d];
    XCTAssertEqual(c.hour, 14);
}

- (void)testParseLocalISOWithoutTimezone {
    // Regression: the README's documented input "2026-05-14T14:30:00" was
    // previously returning nil because the formatter required a TZ offset.
    NSDate *d = [self.bridge parseDateString:@"2026-05-14T14:30:00"];
    XCTAssertNotNil(d);
    NSDateComponents *c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone localTimeZone] fromDate:d];
    XCTAssertEqual(c.year,   2026);
    XCTAssertEqual(c.month,  5);
    XCTAssertEqual(c.day,    14);
    XCTAssertEqual(c.hour,   14);
    XCTAssertEqual(c.minute, 30);
}

- (void)testParseDateOnly {
    NSDate *d = [self.bridge parseDateString:@"2026-05-14"];
    XCTAssertNotNil(d);
    NSDateComponents *c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone localTimeZone] fromDate:d];
    XCTAssertEqual(c.year,  2026);
    XCTAssertEqual(c.month, 5);
    XCTAssertEqual(c.day,   14);
    XCTAssertEqual(c.hour,  0);
    XCTAssertEqual(c.minute, 0);
}

- (void)testParseNilAndEmpty {
    XCTAssertNil([self.bridge parseDateString:nil]);
    XCTAssertNil([self.bridge parseDateString:@""]);
}

- (void)testParseGarbage {
    XCTAssertNil([self.bridge parseDateString:@"not a date"]);
    XCTAssertNil([self.bridge parseDateString:@"14/05/2026"]);
    XCTAssertNil([self.bridge parseDateString:@"2026-13-99"]);
}

- (void)testFormatTimedHasTimeAndYear {
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.year = 2026; c.month = 5; c.day = 14; c.hour = 14; c.minute = 30;
    c.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDate *d = c.date;
    NSString *s = [self.bridge formatDate:d allDay:NO];
    XCTAssertTrue([s containsString:@"2026"], @"got: %@", s);
    XCTAssertTrue([s containsString:@"·"],   @"got: %@", s);
    // Should contain a colon for the time component
    XCTAssertTrue([s containsString:@":"],    @"got: %@", s);
}

- (void)testFormatAllDayOmitsTime {
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.year = 2026; c.month = 5; c.day = 14;
    c.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDate *d = c.date;
    NSString *s = [self.bridge formatDate:d allDay:YES];
    XCTAssertTrue([s containsString:@"2026"], @"got: %@", s);
    XCTAssertFalse([s containsString:@"·"],   @"got: %@", s);
    XCTAssertFalse([s containsString:@":"],   @"got: %@", s);
}

@end
