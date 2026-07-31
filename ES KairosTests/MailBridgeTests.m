//
//  MailBridgeTests.m
//
//  Pure-logic tests for MailBridge: sorting, summary formatting, semantic-key
//  resolution, and body normalization — all against synthetic metadata
//  dictionaries. No Apple Events are sent and no Automation TCC is needed;
//  Mail.app is never touched.
//

#import <XCTest/XCTest.h>
#import "MailBridge+Testing.h"

@interface MailBridgeTests : XCTestCase
@end

@implementation MailBridgeTests

#pragma mark - Fixtures

/// Meta dict in fetchMetaForMailbox: shape. Dates may contain NSNull.
static NSDictionary *Meta(NSArray *subjects, NSArray *senders,
                          NSArray *dates, NSArray *reads) {
    return @{ @"subjects": subjects, @"senders": senders,
              @"dates": dates, @"reads": reads,
              @"count": @(MIN(MIN(subjects.count, senders.count),
                              MIN(dates.count, reads.count))) };
}

static NSDate *D(NSTimeInterval secondsAgo) {
    return [NSDate dateWithTimeIntervalSince1970:1000000 - secondsAgo];
}

/// Three-message mailbox: index 0 oldest, index 2 newest, index 1 undated.
- (NSDictionary *)sampleMeta {
    return Meta(@[@"Weekly Digest", @"Re: invoice", @"Weekly Digest"],
                @[@"news@list.example", @"mary@example.com", @"news@list.example"],
                @[D(7200), NSNull.null, D(60)],
                @[@YES, @NO, @NO]);
}

#pragma mark - Sorting

- (void)testIndicesByDateDescendingNewestFirstNullsLast {
    NSArray *order = [[MailBridge shared] indicesByDateDescending:[self sampleMeta]];
    XCTAssertEqualObjects(order, (@[@2, @0, @1]));
}

- (void)testIndicesRespectCountOverArrayLength {
    // count is the min common length — extra subjects must not create indices.
    NSDictionary *meta = Meta(@[@"a", @"b", @"c"], @[@"s", @"s"],
                              @[D(10), D(20)], @[@NO, @NO]);
    NSArray *order = [[MailBridge shared] indicesByDateDescending:meta];
    XCTAssertEqualObjects(order, (@[@0, @1]));
}

#pragma mark - Summaries

- (void)testSummaryFields {
    NSDictionary *s = [[MailBridge shared] summaryFromMeta:[self sampleMeta] index:2];
    XCTAssertEqualObjects(s[@"subject"], @"Weekly Digest");
    XCTAssertEqualObjects(s[@"from"], @"news@list.example");
    XCTAssertEqualObjects(s[@"read"], @NO);
    XCTAssertTrue([s[@"date"] isKindOfClass:NSString.class]);
}

- (void)testSummaryFallbacksForMissingValues {
    NSDictionary *meta = Meta(@[@""], @[NSNull.null], @[NSNull.null], @[NSNull.null]);
    NSDictionary *s = [[MailBridge shared] summaryFromMeta:meta index:0];
    XCTAssertEqualObjects(s[@"subject"], @"(no subject)");
    XCTAssertNil(s[@"from"]);
    XCTAssertNil(s[@"date"]);
    XCTAssertEqualObjects(s[@"read"], @NO);
}

#pragma mark - Semantic-key resolution

- (void)testResolveExactMatchBeatsSubstring {
    // "Re: invoice" contains "invoice"; an exact-subject message must win
    // alone when one exists.
    NSDictionary *meta = Meta(@[@"invoice", @"Re: invoice"], @[@"a@x", @"b@x"],
                              @[D(100), D(50)], @[@NO, @NO]);
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:meta
                     subject:@"Invoice" sender:nil date:nil];
    XCTAssertEqualObjects(c, (@[@0]));
}

- (void)testResolveFallsBackToSubstring {
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:[self sampleMeta]
                     subject:@"invoice" sender:nil date:nil];
    XCTAssertEqualObjects(c, (@[@1]));
}

- (void)testResolveTrimsAndIgnoresCase {
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:[self sampleMeta]
                     subject:@"  WEEKLY DIGEST " sender:nil date:nil];
    XCTAssertEqual(c.count, 2u);
}

- (void)testResolveCandidatesNewestFirst {
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:[self sampleMeta]
                     subject:@"Weekly Digest" sender:nil date:nil];
    XCTAssertEqualObjects(c, (@[@2, @0]));
}

- (void)testResolveSenderSubstringNarrows {
    NSDictionary *meta = Meta(@[@"Hello", @"Hello"],
                              @[@"Mary <mary@example.com>", @"Bob <bob@example.com>"],
                              @[D(100), D(50)], @[@NO, @NO]);
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:meta
                     subject:@"Hello" sender:@"mary" date:nil];
    XCTAssertEqualObjects(c, (@[@0]));
}

- (void)testResolveDateWindowIsPlusMinusTwoMinutes {
    NSDictionary *meta = Meta(@[@"Hello", @"Hello", @"Hello"],
                              @[@"a@x", @"a@x", @"a@x"],
                              @[D(0), D(119), D(121)], @[@NO, @NO, @NO]);
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:meta
                     subject:@"Hello" sender:nil date:D(0)];
    // D(0) and D(119) are within ±120 s of D(0); D(121) is out.
    XCTAssertEqualObjects([NSSet setWithArray:c], ([NSSet setWithArray:@[@0, @1]]));
}

- (void)testResolveUndatedMessageExcludedWhenDateGiven {
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:[self sampleMeta]
                     subject:@"Re: invoice" sender:nil date:D(60)];
    XCTAssertEqualObjects(c, @[]);
}

- (void)testResolveNoMatch {
    NSArray *c = [[MailBridge shared] resolveCandidatesInMeta:[self sampleMeta]
                     subject:@"nonexistent" sender:nil date:nil];
    XCTAssertEqualObjects(c, @[]);
}

#pragma mark - Body normalization

- (void)testNormalizeStripsObjectReplacementChars {
    XCTAssertEqualObjects([MailBridge normalizeBody:@"a\uFFFC\uFFFCb"], @"ab");
}

- (void)testNormalizeConvertsNonBreakingSpaces {
    XCTAssertEqualObjects([MailBridge normalizeBody:@"a\u00A0b"], @"a b");
}

- (void)testNormalizeCollapsesBlankLineRuns {
    // Placeholder-only lines vanish, their leftover newlines collapse to
    // one blank line, and edges are trimmed.
    NSString *raw = @"Header\n\uFFFC\n\u00A0\n\n\nBody text\n\n";
    XCTAssertEqualObjects([MailBridge normalizeBody:raw], @"Header\n\nBody text");
}

- (void)testNormalizeLeavesPlainTextAlone {
    NSString *plain = @"Hello,\n\nJust a normal mail.\n\n— Mary";
    XCTAssertEqualObjects([MailBridge normalizeBody:plain], plain);
}

@end
