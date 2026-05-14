//
//  EKBridgeMappingTests.m
//

#import <XCTest/XCTest.h>
#import "EKBridge+Testing.h"
#import "MCPServer+Testing.h"
#import <EventKit/EventKit.h>

@interface EKBridgeMappingTests : XCTestCase
@end

@implementation EKBridgeMappingTests

- (void)testCalendarTypeStrings {
    XCTAssertEqualObjects([EKBridge stringForCalendarType:EKCalendarTypeLocal],        @"local");
    XCTAssertEqualObjects([EKBridge stringForCalendarType:EKCalendarTypeCalDAV],       @"caldav");
    XCTAssertEqualObjects([EKBridge stringForCalendarType:EKCalendarTypeExchange],     @"exchange");
    XCTAssertEqualObjects([EKBridge stringForCalendarType:EKCalendarTypeSubscription], @"subscription");
    XCTAssertEqualObjects([EKBridge stringForCalendarType:EKCalendarTypeBirthday],     @"birthday");
    XCTAssertEqualObjects([EKBridge stringForCalendarType:(EKCalendarType)999],        @"unknown");
}

- (void)testSpanFromString {
    XCTAssertEqual([MCPServer spanFromString:nil],          EKSpanThisEvent);
    XCTAssertEqual([MCPServer spanFromString:@""],          EKSpanThisEvent);
    XCTAssertEqual([MCPServer spanFromString:@"this"],      EKSpanThisEvent);
    XCTAssertEqual([MCPServer spanFromString:@"garbage"],   EKSpanThisEvent);
    XCTAssertEqual([MCPServer spanFromString:@"following"], EKSpanFutureEvents);
}

@end
