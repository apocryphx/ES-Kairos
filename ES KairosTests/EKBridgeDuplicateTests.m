//
//  EKBridgeDuplicateTests.m
//
//  Round-trip test for the duplicate-index mechanism in formatEventSet:.
//  Creates a throwaway local calendar, writes two events with the same
//  title + calendar at different starts, verifies the `index` field
//  appears on both, deletes one, verifies the surviving event loses its
//  `index` field.
//
//  Skips cleanly if Calendar TCC isn't granted to the test host.
//

#import <XCTest/XCTest.h>
#import "EKBridge+Testing.h"
#import <EventKit/EventKit.h>

@interface EKBridgeDuplicateTests : XCTestCase
@property (strong) EKCalendar *testCalendar;
@property (copy)   NSString   *testCalendarName;
@end

@implementation EKBridgeDuplicateTests

- (void)setUp {
    [super setUp];

    XCTestExpectation *e = [self expectationWithDescription:@"auth"];
    [[EKBridge shared] requestAccessWithCompletion:^(BOOL granted, NSError *err) {
        (void)granted; (void)err;
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:10];

    if (![EKBridge shared].isAuthorized) {
        XCTSkip(@"Calendar TCC not granted to test host; skipping round-trip tests. "
                @"Grant Calendar access in System Settings → Privacy & Security → Calendars "
                @"for the xctest runner, then re-run.");
    }

    EKEventStore *store = [EKBridge shared].underlyingStore;
    EKSource *local = nil;
    for (EKSource *s in store.sources) {
        if (s.sourceType == EKSourceTypeLocal) { local = s; break; }
    }
    if (!local) {
        // iCloud calendars don't honor synchronous removeCalendar: — any
        // fallback to a CloudKit source would pollute the user's iCloud.
        // Skip rather than create remote state we can't reliably clean up.
        XCTSkip(@"No EKSourceTypeLocal available; refusing to create a test "
                @"calendar on a remote source (would leak into iCloud).");
    }

    EKCalendar *cal = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:store];
    cal.title = [NSString stringWithFormat:@"Kairos Test %@", [NSUUID UUID].UUIDString];
    cal.source = local;
    NSError *err = nil;
    XCTAssertTrue([store saveCalendar:cal commit:YES error:&err],
                  @"saveCalendar failed: %@", err);

    self.testCalendar     = cal;
    self.testCalendarName = cal.title;
}

- (void)tearDown {
    if (self.testCalendar) {
        EKEventStore *store = [EKBridge shared].underlyingStore;
        NSError *err = nil;
        @try {
            [store removeCalendar:self.testCalendar commit:YES error:&err];
        } @catch (NSException *e) {
            NSLog(@"[EKBridgeDuplicateTests] tearDown calendar removal threw: %@", e);
        }
        if (err) NSLog(@"[EKBridgeDuplicateTests] tearDown removeCalendar: %@", err);
    }
    [super tearDown];
}

- (NSDictionary *)findEventWithTitle:(NSString *)title in:(NSArray *)events {
    for (NSDictionary *e in events) {
        if ([e[@"title"] isEqualToString:title]) return e;
    }
    return nil;
}

- (void)testDuplicateIndexLifecycle {
    NSCalendar *gregorian = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *base = [gregorian components:
        (NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:[NSDate date]];
    base.calendar = gregorian;
    base.hour = 9; base.minute = 0;

    NSDate *first    = base.date;
    NSDate *firstEnd = [first dateByAddingTimeInterval:1800];
    base.hour = 10;
    NSDate *second    = base.date;
    NSDate *secondEnd = [second dateByAddingTimeInterval:1800];
    base.hour = 12;
    NSDate *lunch     = base.date;
    NSDate *lunchEnd  = [lunch dateByAddingTimeInterval:3600];

    base.hour = 0; base.minute = 0;
    NSDate *dayStart = base.date;
    base.hour = 23; base.minute = 59;
    NSDate *dayEnd = base.date;

    EKBridge *bridge = [EKBridge shared];
    NSError *err = nil;

    XCTAssertNotNil([bridge createEventWithTitle:@"Standup"
                                    calendarName:self.testCalendarName
                                           start:first end:firstEnd allDay:NO
                                        location:nil notes:nil error:&err],
                    @"create #1: %@", err);
    XCTAssertNotNil([bridge createEventWithTitle:@"Standup"
                                    calendarName:self.testCalendarName
                                           start:second end:secondEnd allDay:NO
                                        location:nil notes:nil error:&err],
                    @"create #2: %@", err);
    XCTAssertNotNil([bridge createEventWithTitle:@"Lunch"
                                    calendarName:self.testCalendarName
                                           start:lunch end:lunchEnd allDay:NO
                                        location:nil notes:nil error:&err],
                    @"create lunch: %@", err);

    // 1. Both Standups should carry index 1/2; Lunch should have no index.
    NSArray *day = [bridge eventsFrom:dayStart to:dayEnd
                        calendarNames:@[self.testCalendarName] includeNotes:NO];
    XCTAssertEqual(day.count, 3, @"got: %@", day);

    NSMutableSet *standupIndexes = [NSMutableSet set];
    for (NSDictionary *e in day) {
        if ([e[@"title"] isEqualToString:@"Standup"]) {
            XCTAssertNotNil(e[@"index"], @"both standups should have an index: %@", e);
            [standupIndexes addObject:e[@"index"]];
        } else if ([e[@"title"] isEqualToString:@"Lunch"]) {
            XCTAssertNil(e[@"index"], @"unique title should NOT have an index: %@", e);
        }
    }
    XCTAssertEqualObjects(standupIndexes, ([NSSet setWithArray:@[@1, @2]]),
                          @"indexes should be {1,2}, got %@", standupIndexes);

    // 2. Delete the 10:00 Standup.
    XCTAssertTrue([bridge deleteEventWithTitle:@"Standup"
                                  calendarName:self.testCalendarName
                                         start:second
                                          span:EKSpanThisEvent
                                         error:&err],
                  @"delete: %@", err);

    // 3. Surviving Standup should be unique now → no index field. Lunch unchanged.
    NSArray *after = [bridge eventsFrom:dayStart to:dayEnd
                          calendarNames:@[self.testCalendarName] includeNotes:NO];
    XCTAssertEqual(after.count, 2, @"got: %@", after);

    NSDictionary *survivor = [self findEventWithTitle:@"Standup" in:after];
    XCTAssertNotNil(survivor);
    XCTAssertNil(survivor[@"index"],
                 @"after deleting one of two duplicates, the survivor's index should be gone: %@",
                 survivor);

    // 4. Verify the right one survived (start time should be 09:00, not 10:00).
    NSString *expectedStart = [bridge formatDate:first allDay:NO];
    XCTAssertEqualObjects(survivor[@"start"], expectedStart,
                          @"wrong event survived deletion");

    NSDictionary *lunchEvent = [self findEventWithTitle:@"Lunch" in:after];
    XCTAssertNotNil(lunchEvent);
    XCTAssertNil(lunchEvent[@"index"]);
}

@end
