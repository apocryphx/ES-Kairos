//
//  ES_KairosUITests.m
//  ES KairosUITests
//
//  Created by Kolja Wawrowsky on 5/14/26.
//

#import <XCTest/XCTest.h>

@interface ES_KairosUITests : XCTestCase

@end

@implementation ES_KairosUITests

- (void)setUp {
    // Put setup code here. This method is called before the invocation of each test method in the class.

    // In UI tests it is usually best to stop immediately when a failure occurs.
    self.continueAfterFailure = NO;

    // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)testExample {
    // UI tests must launch the application that they test.
    XCUIApplication *app = [[XCUIApplication alloc] init];
    [app launch];

    // Use XCTAssert and related functions to verify your tests produce the correct results.
    // XCUIAutomation Documentation
    // https://developer.apple.com/documentation/xcuiautomation
}

- (void)testLaunchPerformance {
    // This measures how long it takes to launch your application.
    [self measureWithMetrics:@[[[XCTApplicationLaunchMetric alloc] init]] block:^{
        [[[XCUIApplication alloc] init] launch];
    }];
}

@end
