//
//  MCPFramingTests.m
//

#import <XCTest/XCTest.h>
#import "MCPFraming.h"

@interface MCPFramingTests : XCTestCase
@end

@implementation MCPFramingTests

- (id)decode:(NSString *)json {
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

- (void)testEncodeRoundTripsNestedStructures {
    NSDictionary *in = @{
        @"a": @1,
        @"b": @[@"x", @"y", @{ @"k": @YES }],
        @"c": [NSNull null]
    };
    NSString *s = MCPEncodeJSON(in);
    XCTAssertNotNil(s);
    NSDictionary *out = [self decode:s];
    XCTAssertEqualObjects(out, in);
}

- (void)testResultEnvelopeWithNumericId {
    NSString *s = MCPJSONRPCResult(@42, @{ @"ok": @YES });
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"jsonrpc"], @"2.0");
    XCTAssertEqualObjects(d[@"id"], @42);
    XCTAssertEqualObjects(d[@"result"], (@{ @"ok": @YES }));
    XCTAssertNil(d[@"error"]);
}

- (void)testResultEnvelopeWithStringId {
    NSString *s = MCPJSONRPCResult(@"req-1", @{});
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"id"], @"req-1");
    XCTAssertEqualObjects(d[@"result"], @{});
}

- (void)testResultEnvelopeWithNilIdEmitsNull {
    NSString *s = MCPJSONRPCResult(nil, @{ @"x": @1 });
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"id"], [NSNull null]);
}

- (void)testResultEnvelopeWithNilResultEmitsEmptyDict {
    NSString *s = MCPJSONRPCResult(@1, nil);
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"result"], @{});
}

- (void)testErrorEnvelopeCarriesCodeAndMessage {
    NSString *s = MCPJSONRPCError(@7, -32601, @"Method not found");
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"jsonrpc"], @"2.0");
    XCTAssertEqualObjects(d[@"id"], @7);
    XCTAssertEqualObjects(d[@"error"][@"code"], @(-32601));
    XCTAssertEqualObjects(d[@"error"][@"message"], @"Method not found");
    XCTAssertNil(d[@"result"]);
}

- (void)testErrorEnvelopeWithNilMessageHasDefault {
    NSString *s = MCPJSONRPCError(@1, -1, nil);
    NSDictionary *d = [self decode:s];
    XCTAssertEqualObjects(d[@"error"][@"message"], @"Error");
}

@end
