//
//  MCPServerToolsListTests.m
//

#import <XCTest/XCTest.h>
#import "MCPServer+Testing.h"

@interface MCPServerToolsListTests : XCTestCase
@end

@implementation MCPServerToolsListTests

- (NSArray *)tools {
    return [[MCPServer shared] toolDefinitions];
}

- (NSDictionary *)toolNamed:(NSString *)name {
    for (NSDictionary *t in [self tools]) {
        if ([t[@"name"] isEqualToString:name]) return t;
    }
    return nil;
}

- (void)testAllToolsExposed {
    NSArray *expected = @[
        @"calendar_list", @"events_in_range", @"event_search",
        @"event_create",  @"event_update",    @"event_delete",
        @"contact_search", @"ask_user",
        @"reminder_lists", @"reminders_today", @"reminders_in_range",
        @"reminder_search", @"reminder_create", @"reminder_update",
        @"reminder_complete", @"reminder_delete"
    ];
    NSArray *names = [[self tools] valueForKey:@"name"];
    XCTAssertEqual(names.count, expected.count);
    XCTAssertEqualObjects([NSSet setWithArray:names], [NSSet setWithArray:expected]);
}

- (void)testEverySchemaIsAnObjectWithPropertiesAndRequired {
    for (NSDictionary *t in [self tools]) {
        XCTAssertTrue([t[@"name"] isKindOfClass:NSString.class],        @"%@", t);
        XCTAssertTrue([t[@"description"] isKindOfClass:NSString.class], @"%@", t);

        NSDictionary *schema = t[@"inputSchema"];
        XCTAssertTrue([schema isKindOfClass:NSDictionary.class],        @"%@", t);
        XCTAssertEqualObjects(schema[@"type"], @"object",               @"%@", t);
        XCTAssertTrue([schema[@"properties"] isKindOfClass:NSDictionary.class], @"%@", t);
        XCTAssertTrue([schema[@"required"]   isKindOfClass:NSArray.class],      @"%@", t);
    }
}

- (void)testRequiredFieldsMatchReadmeContract {
    NSDictionary *expectedRequired = @{
        @"calendar_list":   @[],
        @"events_in_range": @[@"start", @"end"],
        @"event_search":    @[@"query"],
        @"event_create":    @[@"title", @"calendar", @"start", @"end"],
        @"event_update":    @[@"title", @"calendar", @"start", @"changes"],
        @"event_delete":    @[@"title", @"calendar", @"start"],
        @"contact_search":  @[@"name"],
        @"ask_user":        @[@"question"],
        @"reminder_lists":    @[],
        @"reminders_today":   @[],
        @"reminders_in_range":@[@"start", @"end"],
        @"reminder_search":   @[@"query"],
        @"reminder_create":   @[@"title", @"list"],
        @"reminder_update":   @[@"title", @"list", @"changes"],
        @"reminder_complete": @[@"title", @"list"],
        @"reminder_delete":   @[@"title", @"list"],
    };
    for (NSString *name in expectedRequired) {
        NSDictionary *t = [self toolNamed:name];
        XCTAssertNotNil(t, @"missing tool: %@", name);
        NSSet *got      = [NSSet setWithArray:t[@"inputSchema"][@"required"]];
        NSSet *expected = [NSSet setWithArray:expectedRequired[name]];
        XCTAssertEqualObjects(got, expected, @"tool %@ required mismatch", name);
    }
}

- (void)testEveryToolHasAnnotations {
    for (NSDictionary *t in [self tools]) {
        NSDictionary *a = t[@"annotations"];
        XCTAssertTrue([a isKindOfClass:NSDictionary.class],
                      @"tool %@ missing annotations dict", t[@"name"]);
        XCTAssertTrue([a[@"title"] isKindOfClass:NSString.class],
                      @"tool %@ missing annotations.title", t[@"name"]);
        for (NSString *key in @[@"readOnlyHint", @"destructiveHint",
                                 @"idempotentHint", @"openWorldHint"]) {
            XCTAssertTrue([a[key] isKindOfClass:NSNumber.class],
                          @"tool %@ missing annotations.%@", t[@"name"], key);
        }
    }
}

- (void)testAnnotationContract {
    // Locks in the safety contract. If you flip one of these without
    // thinking carefully about Claude's autonomous-call behavior, this
    // test fails — and the failure forces you to update both the tool
    // metadata and your reasoning about what client-side guardrails go
    // away.
    NSDictionary *expectedAnnotations = @{
        // Read-only, safe, no UI side effects.
        @"calendar_list":   @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"events_in_range": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"event_search":    @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"contact_search":  @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },

        // Additive write. Not destructive but also not idempotent.
        @"event_create":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @NO,
                               @"idempotentHint": @NO,  @"openWorldHint": @NO },

        // Destructive (overwrites). Idempotent in end-state.
        @"event_update":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @YES,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },

        // The truly dangerous one. Native confirmation dialog mitigates.
        @"event_delete":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @YES,
                               @"idempotentHint": @YES, @"openWorldHint": @NO },

        // Side effect (modal popup) but no data mutation.
        @"ask_user":        @{ @"readOnlyHint": @NO,  @"destructiveHint": @NO,
                               @"idempotentHint": @NO,  @"openWorldHint": @NO },

        // Reminders — read-only set.
        @"reminder_lists":     @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"reminders_today":    @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"reminders_in_range": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
        @"reminder_search":    @{ @"readOnlyHint": @YES, @"destructiveHint": @NO,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },

        // Reminders — write set.
        // Additive create — not destructive but not idempotent (duplicates).
        @"reminder_create":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @NO,
                                  @"idempotentHint": @NO,  @"openWorldHint": @NO },
        // Update overwrites prior values.
        @"reminder_update":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @YES,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
        // Complete is reversible (just sets completed=YES); not destructive.
        @"reminder_complete":  @{ @"readOnlyHint": @NO,  @"destructiveHint": @NO,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
        // Delete is permanent — mitigated by native NSAlert.
        @"reminder_delete":    @{ @"readOnlyHint": @NO,  @"destructiveHint": @YES,
                                  @"idempotentHint": @YES, @"openWorldHint": @NO },
    };
    for (NSString *name in expectedAnnotations) {
        NSDictionary *a = [self toolNamed:name][@"annotations"];
        XCTAssertNotNil(a, @"%@: missing annotations", name);
        for (NSString *key in expectedAnnotations[name]) {
            XCTAssertEqualObjects(a[key], expectedAnnotations[name][key],
                @"tool %@ annotation %@ mismatch", name, key);
        }
    }
}

@end
