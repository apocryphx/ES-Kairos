//
//  MCPServer.m
//  Kairos
//

#import "MCPServer.h"
#import "MCPFraming.h"
#import "EKBridge.h"
#import "CNBridge.h"
#import "AskUserWindowController.h"
#import <EventKit/EventKit.h>
#import <AppKit/AppKit.h>

static NSString *const kProtocolVersion = @"2024-11-05";
static NSString *const kServerName      = @"kairos";
static NSString *const kServerVersion   = @"1.0.0";

@interface MCPServer ()
@property (strong) dispatch_queue_t readQueue;
@property (strong) dispatch_queue_t writeQueue;
@property (strong) dispatch_queue_t workQueue;
@property (strong) NSFileHandle    *stdinHandle;
@property (strong) NSFileHandle    *stdoutHandle;
@property (strong) NSMutableData   *inputBuffer;
@end

@implementation MCPServer

+ (instancetype)shared {
    static MCPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MCPServer alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _readQueue   = dispatch_queue_create("kairos.mcp.read",  DISPATCH_QUEUE_SERIAL);
    _writeQueue  = dispatch_queue_create("kairos.mcp.write", DISPATCH_QUEUE_SERIAL);
    _workQueue   = dispatch_queue_create("kairos.mcp.work",  DISPATCH_QUEUE_CONCURRENT);
    _stdinHandle  = [NSFileHandle fileHandleWithStandardInput];
    _stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
    _inputBuffer  = [NSMutableData data];
    return self;
}

- (void)start {
    fprintf(stderr, "[Kairos] MCP server starting (pid=%d)\n", getpid());

    __weak typeof(self) weak = self;
    self.stdinHandle.readabilityHandler = ^(NSFileHandle *h) {
        __strong typeof(weak) s = weak;
        if (!s) return;

        NSData *chunk = nil;
        @try { chunk = [h availableData]; }
        @catch (NSException *e) {
            fprintf(stderr, "[Kairos] stdin read exception: %s\n",
                    e.reason.UTF8String ?: "?");
        }

        if (!chunk.length) {
            h.readabilityHandler = nil;
            fprintf(stderr, "[Kairos] stdin EOF — terminating\n");
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            return;
        }

        dispatch_async(s.readQueue, ^{
            [s.inputBuffer appendData:chunk];
            [s drainLines];
        });
    };
}

- (void)drainLines {
    static const uint8_t nl = '\n';
    while (YES) {
        NSRange r = [self.inputBuffer rangeOfData:[NSData dataWithBytes:&nl length:1]
                                          options:0
                                            range:NSMakeRange(0, self.inputBuffer.length)];
        if (r.location == NSNotFound) break;

        NSData *lineData = [self.inputBuffer subdataWithRange:NSMakeRange(0, r.location)];
        [self.inputBuffer replaceBytesInRange:NSMakeRange(0, r.location + 1)
                                    withBytes:NULL length:0];
        if (!lineData.length) continue;

        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) dispatch_async(self.workQueue, ^{ [self handleLine:line]; });
    }
}

#pragma mark - Dispatch

- (void)handleLine:(NSString *)line {
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:
                 [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&err];

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr, "[Kairos] bad JSON: %s\n", line.UTF8String);
        return;
    }

    NSDictionary *msg    = parsed;
    id rpcId             = msg[@"id"];
    NSString *method     = msg[@"method"];
    NSDictionary *params = [msg[@"params"] isKindOfClass:[NSDictionary class]]
                            ? msg[@"params"] : @{};

    if (!method) return;
    fprintf(stderr, "[Kairos] -> %s\n", method.UTF8String);

    if ([method isEqualToString:@"initialize"]) {
        [self write:MCPJSONRPCResult(rpcId, @{
            @"protocolVersion": kProtocolVersion,
            @"capabilities":    @{ @"tools": @{} },
            @"serverInfo":      @{ @"name": kServerName, @"version": kServerVersion }
        })];
        return;
    }

    if ([method hasPrefix:@"notifications/"]) return;

    if ([method isEqualToString:@"tools/list"]) {
        [self write:MCPJSONRPCResult(rpcId, @{ @"tools": [self toolDefinitions] })];
        return;
    }

    if ([method isEqualToString:@"tools/call"]) {
        NSString *name = params[@"name"];
        NSDictionary *args = [params[@"arguments"] isKindOfClass:[NSDictionary class]]
                              ? params[@"arguments"] : @{};
        [self dispatchTool:name args:args rpcId:rpcId];
        return;
    }

    if ([method isEqualToString:@"shutdown"]) {
        [self write:MCPJSONRPCResult(rpcId, @{})];
        return;
    }

    if ([method isEqualToString:@"exit"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        return;
    }

    [self write:MCPJSONRPCError(rpcId, -32601,
        [NSString stringWithFormat:@"Method not found: %@", method])];
}

- (void)dispatchTool:(NSString *)name args:(NSDictionary *)args rpcId:(id)rpcId {
    if      ([name isEqualToString:@"calendar_list"])     [self handleCalendarList:args rpcId:rpcId];
    else if ([name isEqualToString:@"events_in_range"])   [self handleEventsInRange:args rpcId:rpcId];
    else if ([name isEqualToString:@"event_search"])      [self handleEventSearch:args rpcId:rpcId];
    else if ([name isEqualToString:@"event_create"])      [self handleEventCreate:args rpcId:rpcId];
    else if ([name isEqualToString:@"event_update"])      [self handleEventUpdate:args rpcId:rpcId];
    else if ([name isEqualToString:@"event_delete"])      [self handleEventDelete:args rpcId:rpcId];
    else if ([name isEqualToString:@"contact_search"])    [self handleContactSearch:args rpcId:rpcId];
    else if ([name isEqualToString:@"ask_user"])          [self handleAskUser:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_lists"])    [self handleReminderLists:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminders_today"])   [self handleRemindersToday:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminders_in_range"])[self handleRemindersInRange:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_search"])   [self handleReminderSearch:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_create"])   [self handleReminderCreate:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_update"])   [self handleReminderUpdate:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_complete"]) [self handleReminderComplete:args rpcId:rpcId];
    else if ([name isEqualToString:@"reminder_delete"])   [self handleReminderDelete:args rpcId:rpcId];
    else [self write:MCPJSONRPCError(rpcId, -32601,
            [NSString stringWithFormat:@"Unknown tool: %@", name ?: @"(null)"])];
}

#pragma mark - Authorization Check

- (BOOL)requireCalendarAuth:(id)rpcId {
    if (![EKBridge shared].isAuthorized) {
        [self resultText:@"Calendar access not authorized. "
                         @"Grant access in System Settings → Privacy & Security → Calendars."
               forRpcId:rpcId isError:YES];
        return NO;
    }
    return YES;
}

- (BOOL)requireContactsAuth:(id)rpcId {
    if (![CNBridge shared].isAuthorized) {
        [self resultText:@"Contacts access not authorized. "
                         @"Grant access in System Settings → Privacy & Security → Contacts."
               forRpcId:rpcId isError:YES];
        return NO;
    }
    return YES;
}

- (BOOL)requireRemindersAuth:(id)rpcId {
    if (![EKBridge shared].isAuthorizedForReminders) {
        [self resultText:@"Reminders access not authorized. "
                         @"Grant access in System Settings → Privacy & Security → Reminders."
               forRpcId:rpcId isError:YES];
        return NO;
    }
    return YES;
}

#pragma mark - Tool: calendar_list

- (void)handleCalendarList:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSArray *cals = [[EKBridge shared] listCalendars];
    [self resultJSON:cals forRpcId:rpcId];
}

#pragma mark - Tool: events_in_range

- (void)handleEventsInRange:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSDate *start = [[EKBridge shared] parseDateString:args[@"start"]];
    NSDate *end   = [[EKBridge shared] parseDateString:args[@"end"]];

    if (!start || !end) {
        [self resultText:@"Invalid or missing start/end date. Use ISO 8601 (e.g. 2026-05-14T00:00:00)."
               forRpcId:rpcId isError:YES];
        return;
    }

    NSArray<NSString *> *calNames = nil;
    if ([args[@"calendars"] isKindOfClass:[NSArray class]]) {
        calNames = args[@"calendars"];
    }
    BOOL includeNotes = [args[@"include_notes"] boolValue];

    NSArray *events = [[EKBridge shared] eventsFrom:start
                                                 to:end
                                      calendarNames:calNames
                                       includeNotes:includeNotes];
    [self resultJSON:events forRpcId:rpcId];
}

#pragma mark - Tool: event_search

- (void)handleEventSearch:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSString *query = args[@"query"];
    if (![query isKindOfClass:[NSString class]] || !query.length) {
        [self resultText:@"Missing required parameter: query" forRpcId:rpcId isError:YES];
        return;
    }

    NSDate *start = [[EKBridge shared] parseDateString:args[@"start"]];
    NSDate *end   = [[EKBridge shared] parseDateString:args[@"end"]];
    BOOL includeNotes = [args[@"include_notes"] boolValue];

    NSArray *events = [[EKBridge shared] eventsMatchingQuery:query
                                                        from:start
                                                          to:end
                                                includeNotes:includeNotes];
    [self resultJSON:events forRpcId:rpcId];
}

#pragma mark - Tool: event_create

- (void)handleEventCreate:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSString *title    = args[@"title"];
    NSString *calendar = args[@"calendar"];
    NSDate   *start    = [[EKBridge shared] parseDateString:args[@"start"]];
    NSDate   *end      = [[EKBridge shared] parseDateString:args[@"end"]];

    if (![title    isKindOfClass:[NSString class]] || !title.length ||
        ![calendar isKindOfClass:[NSString class]] || !calendar.length ||
        !start || !end) {
        [self resultText:@"Required: title, calendar, start (ISO 8601), end (ISO 8601)"
               forRpcId:rpcId isError:YES];
        return;
    }

    BOOL allDay = [args[@"all_day"] boolValue];
    NSString *location = [args[@"location"] isKindOfClass:[NSString class]] ? args[@"location"] : nil;
    NSString *notes    = [args[@"notes"]    isKindOfClass:[NSString class]] ? args[@"notes"]    : nil;

    NSError *err = nil;
    NSDictionary *created = [[EKBridge shared] createEventWithTitle:title
                                                       calendarName:calendar
                                                              start:start
                                                                end:end
                                                             allDay:allDay
                                                           location:location
                                                              notes:notes
                                                              error:&err];
    if (created) {
        [self resultJSON:created forRpcId:rpcId];
    } else {
        [self resultText:err.localizedDescription ?: @"Create failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: event_update

- (void)handleEventUpdate:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSString *title    = args[@"title"];
    NSString *calendar = args[@"calendar"];
    NSDate   *start    = [[EKBridge shared] parseDateString:args[@"start"]];

    if (![title    isKindOfClass:[NSString class]] || !title.length ||
        ![calendar isKindOfClass:[NSString class]] || !calendar.length || !start) {
        [self resultText:@"Required: title, calendar, start (ISO 8601) — the event identity key"
               forRpcId:rpcId isError:YES];
        return;
    }

    NSDictionary *changes = [args[@"changes"] isKindOfClass:[NSDictionary class]]
                             ? args[@"changes"] : @{};
    if (!changes.count) {
        [self resultText:@"No changes supplied" forRpcId:rpcId isError:YES];
        return;
    }

    EKSpan span = [MCPServer spanFromString:args[@"span"]];

    NSError *err = nil;
    BOOL ok = [[EKBridge shared] updateEventWithTitle:title
                                         calendarName:calendar
                                                start:start
                                              changes:changes
                                                 span:span
                                                error:&err];
    if (ok) {
        [self resultText:[NSString stringWithFormat:@"Updated \"%@\"", title]
               forRpcId:rpcId isError:NO];
    } else {
        [self resultText:err.localizedDescription ?: @"Update failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: event_delete

- (void)handleEventDelete:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireCalendarAuth:rpcId]) return;

    NSString *title    = args[@"title"];
    NSString *calendar = args[@"calendar"];
    NSDate   *start    = [[EKBridge shared] parseDateString:args[@"start"]];

    if (![title    isKindOfClass:[NSString class]] || !title.length ||
        ![calendar isKindOfClass:[NSString class]] || !calendar.length || !start) {
        [self resultText:@"Required: title, calendar, start (ISO 8601)"
               forRpcId:rpcId isError:YES];
        return;
    }

    EKSpan span = [MCPServer spanFromString:args[@"span"]];

    // Confirmation dialog — deletion is irreversible.
    NSString *displayDate = [[EKBridge shared] formatDate:start allDay:NO];
    NSString *spanLabel   = (span == EKSpanThisEvent) ? @"" : @" (this and future occurrences)";
    NSString *prompt      = [NSString stringWithFormat:
        @"Delete \"%@\"\n%@ · %@%@",
        title, displayDate, calendar, spanLabel];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL confirmed = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert       = [[NSAlert alloc] init];
        alert.messageText    = @"Delete Calendar Event";
        alert.informativeText = prompt;
        alert.alertStyle     = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Delete"];
        [alert addButtonWithTitle:@"Cancel"];
        confirmed = ([alert runModal] == NSAlertFirstButtonReturn);
        dispatch_semaphore_signal(sem);
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (!confirmed) {
        [self resultText:@"Deletion cancelled by user." forRpcId:rpcId isError:NO];
        return;
    }

    NSError *err = nil;
    BOOL ok = [[EKBridge shared] deleteEventWithTitle:title
                                         calendarName:calendar
                                                start:start
                                                 span:span
                                                error:&err];
    if (ok) {
        [self resultText:[NSString stringWithFormat:@"Deleted \"%@\" on %@", title, displayDate]
               forRpcId:rpcId isError:NO];
    } else {
        [self resultText:err.localizedDescription ?: @"Delete failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: contact_search

- (void)handleContactSearch:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireContactsAuth:rpcId]) return;

    NSString *name = args[@"name"];
    if (![name isKindOfClass:[NSString class]] || !name.length) {
        [self resultText:@"Missing required parameter: name" forRpcId:rpcId isError:YES];
        return;
    }

    NSArray *contacts = [[CNBridge shared] searchContactsMatchingName:name];
    [self resultJSON:contacts forRpcId:rpcId];
}

#pragma mark - Tool: ask_user

- (void)handleAskUser:(NSDictionary *)args rpcId:(id)rpcId {
    NSString *question = args[@"question"];
    if (![question isKindOfClass:[NSString class]] || !question.length) {
        [self write:MCPJSONRPCError(rpcId, -32602, @"Missing required parameter: question")];
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *answer  = nil;
    __block BOOL accepted     = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        accepted = [AskUserWindowController
            presentQuestion:question
                 completion:^(NSString *a) {
                     answer = a;
                     dispatch_semaphore_signal(sem);
                 }];
        if (!accepted) dispatch_semaphore_signal(sem);
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (!accepted) {
        [self write:MCPJSONRPCError(rpcId, -32000,
            @"A popup is already on screen; only one ask_user at a time.")];
        return;
    }

    if (!answer) {
        [self resultText:@"User cancelled." forRpcId:rpcId isError:NO];
        return;
    }

    [self write:MCPJSONRPCResult(rpcId, @{
        @"content": @[@{ @"type": @"text", @"text": answer }]
    })];
}

#pragma mark - Tool: reminder_lists

- (void)handleReminderLists:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;
    NSArray *lists = [[EKBridge shared] listReminderLists];
    [self resultJSON:lists forRpcId:rpcId];
}

#pragma mark - Tool: reminders_today

- (void)handleRemindersToday:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;
    BOOL includeCompleted = [args[@"include_completed"] boolValue];
    BOOL includeNotes     = [args[@"include_notes"]     boolValue];
    NSArray *result = [[EKBridge shared] remindersDueTodayOrOverdue:includeCompleted
                                                              notes:includeNotes];
    [self resultJSON:result forRpcId:rpcId];
}

#pragma mark - Tool: reminders_in_range

- (void)handleRemindersInRange:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSDate *start = [[EKBridge shared] parseDateString:args[@"start"]];
    NSDate *end   = [[EKBridge shared] parseDateString:args[@"end"]];
    if (!start || !end) {
        [self resultText:@"Invalid or missing start/end date. Use ISO 8601 (e.g. 2026-05-14T00:00:00)."
               forRpcId:rpcId isError:YES];
        return;
    }

    NSArray<NSString *> *listNames = nil;
    if ([args[@"lists"] isKindOfClass:[NSArray class]]) listNames = args[@"lists"];
    BOOL includeCompleted = [args[@"include_completed"] boolValue];
    BOOL includeNotes     = [args[@"include_notes"]     boolValue];

    NSArray *result = [[EKBridge shared] remindersFrom:start to:end
                                              listNames:listNames
                                     includeCompleted:includeCompleted
                                          includeNotes:includeNotes];
    [self resultJSON:result forRpcId:rpcId];
}

#pragma mark - Tool: reminder_search

- (void)handleReminderSearch:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSString *query = args[@"query"];
    if (![query isKindOfClass:[NSString class]] || !query.length) {
        [self resultText:@"Missing required parameter: query" forRpcId:rpcId isError:YES];
        return;
    }
    BOOL includeCompleted = [args[@"include_completed"] boolValue];
    BOOL includeNotes     = [args[@"include_notes"]     boolValue];

    NSArray *result = [[EKBridge shared] remindersMatchingQuery:query
                                              includeCompleted:includeCompleted
                                                  includeNotes:includeNotes];
    [self resultJSON:result forRpcId:rpcId];
}

#pragma mark - Tool: reminder_create

- (void)handleReminderCreate:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSString *title = args[@"title"];
    NSString *list  = args[@"list"];
    if (![title isKindOfClass:[NSString class]] || !title.length ||
        ![list  isKindOfClass:[NSString class]] || !list.length) {
        [self resultText:@"Required: title, list" forRpcId:rpcId isError:YES];
        return;
    }
    NSDate *due = [[EKBridge shared] parseDateString:args[@"due"]]; // optional
    NSString *priority = [args[@"priority"] isKindOfClass:[NSString class]] ? args[@"priority"] : nil;
    NSString *notes    = [args[@"notes"]    isKindOfClass:[NSString class]] ? args[@"notes"]    : nil;

    NSError *err = nil;
    NSDictionary *created = [[EKBridge shared] createReminderWithTitle:title
                                                              listName:list
                                                               dueDate:due
                                                              priority:priority
                                                                 notes:notes
                                                                 error:&err];
    if (created) {
        [self resultJSON:created forRpcId:rpcId];
    } else {
        [self resultText:err.localizedDescription ?: @"Create failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: reminder_update

- (void)handleReminderUpdate:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSString *title = args[@"title"];
    NSString *list  = args[@"list"];
    if (![title isKindOfClass:[NSString class]] || !title.length ||
        ![list  isKindOfClass:[NSString class]] || !list.length) {
        [self resultText:@"Required: title, list" forRpcId:rpcId isError:YES];
        return;
    }
    NSDate *due = [[EKBridge shared] parseDateString:args[@"due"]]; // may be nil

    NSDictionary *changes = [args[@"changes"] isKindOfClass:[NSDictionary class]]
                            ? args[@"changes"] : @{};
    if (!changes.count) {
        [self resultText:@"No changes supplied" forRpcId:rpcId isError:YES];
        return;
    }

    NSError *err = nil;
    BOOL ok = [[EKBridge shared] updateReminderWithTitle:title
                                                listName:list
                                                 dueDate:due
                                                 changes:changes
                                                   error:&err];
    if (ok) {
        [self resultText:[NSString stringWithFormat:@"Updated \"%@\"", title]
               forRpcId:rpcId isError:NO];
    } else {
        [self resultText:err.localizedDescription ?: @"Update failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: reminder_complete

- (void)handleReminderComplete:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSString *title = args[@"title"];
    NSString *list  = args[@"list"];
    if (![title isKindOfClass:[NSString class]] || !title.length ||
        ![list  isKindOfClass:[NSString class]] || !list.length) {
        [self resultText:@"Required: title, list" forRpcId:rpcId isError:YES];
        return;
    }
    NSDate *due = [[EKBridge shared] parseDateString:args[@"due"]];

    NSError *err = nil;
    BOOL ok = [[EKBridge shared] completeReminderWithTitle:title
                                                  listName:list
                                                   dueDate:due
                                                     error:&err];
    if (ok) {
        [self resultText:[NSString stringWithFormat:@"Completed \"%@\"", title]
               forRpcId:rpcId isError:NO];
    } else {
        [self resultText:err.localizedDescription ?: @"Complete failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool: reminder_delete

- (void)handleReminderDelete:(NSDictionary *)args rpcId:(id)rpcId {
    if (![self requireRemindersAuth:rpcId]) return;

    NSString *title = args[@"title"];
    NSString *list  = args[@"list"];
    if (![title isKindOfClass:[NSString class]] || !title.length ||
        ![list  isKindOfClass:[NSString class]] || !list.length) {
        [self resultText:@"Required: title, list" forRpcId:rpcId isError:YES];
        return;
    }
    NSDate *due = [[EKBridge shared] parseDateString:args[@"due"]];

    // Native confirmation, same pattern as event_delete.
    NSString *dueLabel = due ? [[EKBridge shared] formatDate:due allDay:NO] : @"(no due date)";
    NSString *prompt = [NSString stringWithFormat:@"Delete \"%@\"\n%@ · %@", title, dueLabel, list];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL confirmed = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert       = [[NSAlert alloc] init];
        alert.messageText    = @"Delete Reminder";
        alert.informativeText = prompt;
        alert.alertStyle     = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Delete"];
        [alert addButtonWithTitle:@"Cancel"];
        confirmed = ([alert runModal] == NSAlertFirstButtonReturn);
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (!confirmed) {
        [self resultText:@"Deletion cancelled by user." forRpcId:rpcId isError:NO];
        return;
    }

    NSError *err = nil;
    BOOL ok = [[EKBridge shared] deleteReminderWithTitle:title
                                                listName:list
                                                 dueDate:due
                                                   error:&err];
    if (ok) {
        [self resultText:[NSString stringWithFormat:@"Deleted \"%@\"", title]
               forRpcId:rpcId isError:NO];
    } else {
        [self resultText:err.localizedDescription ?: @"Delete failed"
               forRpcId:rpcId isError:YES];
    }
}

#pragma mark - Tool Definitions

// MCP tool annotation hints — see https://modelcontextprotocol.io/specification/server/tools
//
// readOnlyHint     true if the tool does not modify any state
// destructiveHint  true if the tool may perform destructive updates (only relevant when !readOnly)
// idempotentHint   true if repeated calls with the same args produce the same end state
// openWorldHint    true if the tool interacts with the open internet rather than a closed system
//
// These are HINTS to the client (Claude). Claude uses them to decide whether
// to confirm before calling, batch calls, or surface a tool in autonomous
// mode. They are NOT a substitute for server-side enforcement — every
// destructive operation here also pops a native confirmation dialog.

- (NSArray *)toolDefinitions {
    return @[

    @{ @"name": @"calendar_list",
       @"description": @"List all calendars available on this Mac. "
                        @"Returns name, type (local/caldav/exchange/birthday/subscription), "
                        @"source account, and whether the calendar accepts edits. "
                        @"Call this first to know which calendar names to use in other tools.",
       @"annotations": @{
           @"title": @"List Calendars",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{ @"type": @"object", @"properties": @{}, @"required": @[] }
    },

    @{ @"name": @"events_in_range",
       @"description": @"Fetch events within a date range. "
                        @"Events are identified by title + calendar + start — "
                        @"use these three fields to reference an event in update or delete. "
                        @"An index field appears only when multiple events share the same "
                        @"title and calendar within the result set.",
       @"annotations": @{
           @"title": @"Events in Date Range",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"start": @{ @"type": @"string",
                            @"description": @"Range start, ISO 8601 (e.g. 2026-05-14T00:00:00)." },
               @"end":   @{ @"type": @"string",
                            @"description": @"Range end, ISO 8601." },
               @"calendars": @{ @"type": @"array",
                                @"items": @{ @"type": @"string" },
                                @"description": @"Optional: filter to specific calendar names. "
                                                @"Omit for all calendars." },
               @"include_notes": @{ @"type": @"boolean",
                                    @"description": @"Include event notes. Default false." }
           },
           @"required": @[@"start", @"end"]
       }
    },

    @{ @"name": @"event_search",
       @"description": @"Search events by text, matched against title, location, and notes. "
                        @"Default window: ±6 months from today when start/end are omitted.",
       @"annotations": @{
           @"title": @"Search Events",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"query": @{ @"type": @"string",
                            @"description": @"Text to search for (case-insensitive)." },
               @"start": @{ @"type": @"string", @"description": @"Optional window start, ISO 8601." },
               @"end":   @{ @"type": @"string", @"description": @"Optional window end, ISO 8601." },
               @"include_notes": @{ @"type": @"boolean",
                                    @"description": @"Include notes in results. Default false." }
           },
           @"required": @[@"query"]
       }
    },

    @{ @"name": @"event_create",
       @"description": @"Create a new calendar event. "
                        @"Use calendar_list first to confirm the target calendar name and that "
                        @"it allows edits.",
       @"annotations": @{
           @"title": @"Create Calendar Event",
           // Additive write: not read-only, but doesn't destroy anything.
           @"readOnlyHint":    @NO,
           @"destructiveHint": @NO,
           // Not idempotent — repeated calls with identical args produce duplicate events.
           @"idempotentHint":  @NO,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title":    @{ @"type": @"string" },
               @"calendar": @{ @"type": @"string",
                               @"description": @"Calendar name (must be editable)." },
               @"start":    @{ @"type": @"string",
                               @"description": @"ISO 8601. For all-day events use date-only "
                                               @"(e.g. 2026-05-16)." },
               @"end":      @{ @"type": @"string", @"description": @"ISO 8601." },
               @"all_day":  @{ @"type": @"boolean" },
               @"location": @{ @"type": @"string" },
               @"notes":    @{ @"type": @"string" }
           },
           @"required": @[@"title", @"calendar", @"start", @"end"]
       }
    },

    @{ @"name": @"event_update",
       @"description": @"Update an existing event. "
                        @"Identify it by its current title + calendar + start (ISO 8601). "
                        @"Supply only the fields to change in `changes`.",
       @"annotations": @{
           @"title": @"Update Calendar Event",
           @"readOnlyHint":    @NO,
           // Destructive: overwrites prior field values. No native confirmation
           // dialog for update — Claude should surface its own confirmation
           // for unsupervised use.
           @"destructiveHint": @YES,
           // Calling with the same args twice converges on the same end state.
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title":    @{ @"type": @"string",
                               @"description": @"Current title — part of the lookup key." },
               @"calendar": @{ @"type": @"string",
                               @"description": @"Current calendar — part of the lookup key." },
               @"start":    @{ @"type": @"string",
                               @"description": @"Current start, ISO 8601 — part of the lookup key." },
               @"changes":  @{
                   @"type": @"object",
                   @"description": @"Fields to change. All optional.",
                   @"properties": @{
                       @"title":    @{ @"type": @"string" },
                       @"start":    @{ @"type": @"string", @"description": @"New start, ISO 8601." },
                       @"end":      @{ @"type": @"string", @"description": @"New end, ISO 8601." },
                       @"location": @{ @"type": @"string" },
                       @"notes":    @{ @"type": @"string" },
                       @"all_day":  @{ @"type": @"boolean" }
                   }
               },
               @"span": @{ @"type": @"string",
                           @"enum": @[@"this", @"following"],
                           @"description": @"For recurring events: 'this' (default) updates only "
                                           @"this occurrence; 'following' updates this and all "
                                           @"future occurrences." }
           },
           @"required": @[@"title", @"calendar", @"start", @"changes"]
       }
    },

    @{ @"name": @"event_delete",
       @"description": @"Delete a calendar event. "
                        @"A native confirmation dialog will appear before deletion proceeds. "
                        @"For recurring events use span to control scope.",
       @"annotations": @{
           @"title": @"Delete Calendar Event",
           @"readOnlyHint":    @NO,
           // The dangerous one. Server-side mitigation: a blocking native
           // NSAlert pops before the delete commits. Claude should still
           // confirm with the user before invoking, especially with
           // span='following' (which deletes entire recurrence tails).
           @"destructiveHint": @YES,
           // Idempotent in effect — deleting a non-existent event is a no-op
           // error, but the end state (event absent) is reached.
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title":    @{ @"type": @"string" },
               @"calendar": @{ @"type": @"string" },
               @"start":    @{ @"type": @"string", @"description": @"ISO 8601." },
               @"span":     @{ @"type": @"string",
                               @"enum": @[@"this", @"following"],
                               @"description": @"'this' (default) deletes only this occurrence; "
                                               @"'following' deletes this and all future occurrences." }
           },
           @"required": @[@"title", @"calendar", @"start"]
       }
    },

    @{ @"name": @"contact_search",
       @"description": @"Search contacts by name (partial match against given name, "
                        @"family name, or organization). "
                        @"Returns name, phone numbers, email addresses, and organization.",
       @"annotations": @{
           @"title": @"Search Contacts",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"name": @{ @"type": @"string", @"description": @"Name to search for." }
           },
           @"required": @[@"name"]
       }
    },

    @{ @"name": @"ask_user",
       @"description": @"Show a native popup asking the user a question and return their "
                        @"typed answer. Use when you need information not available through "
                        @"other tools — for example, to resolve an ambiguity before creating "
                        @"an event. Returns an error if the user cancels.",
       @"annotations": @{
           @"title": @"Ask the User a Question",
           // Doesn't modify any calendar/contacts state, but it DOES interrupt
           // the user with a modal popup — that's a non-trivial side effect
           // worth flagging via destructiveHint=false but readOnlyHint=false.
           @"readOnlyHint":    @NO,
           @"destructiveHint": @NO,
           // Not idempotent — the user can give different answers each call.
           @"idempotentHint":  @NO,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"question": @{ @"type": @"string",
                               @"description": @"The question to display." }
           },
           @"required": @[@"question"]
       }
    },

    // ── Reminders ────────────────────────────────────────────────────────

    @{ @"name": @"reminder_lists",
       @"description": @"List all reminder lists on this Mac. "
                        @"Returns name, source, and whether the list accepts edits. "
                        @"Call this first to know which list names to use.",
       @"annotations": @{
           @"title": @"List Reminder Lists",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{ @"type": @"object", @"properties": @{}, @"required": @[] }
    },

    @{ @"name": @"reminders_today",
       @"description": @"Reminders due today plus any overdue (uncompleted, due before today). "
                        @"This is the canonical 'daily brief' tool. "
                        @"Reminders are identified by title + list + due — use those three "
                        @"fields to reference one in update/complete/delete.",
       @"annotations": @{
           @"title": @"Today's Reminders",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"include_completed": @{ @"type": @"boolean",
                                        @"description": @"Include completed reminders. Default false." },
               @"include_notes":     @{ @"type": @"boolean",
                                        @"description": @"Include reminder notes. Default false." }
           },
           @"required": @[]
       }
    },

    @{ @"name": @"reminders_in_range",
       @"description": @"Reminders with due dates in a date range. "
                        @"Excludes reminders without a due date.",
       @"annotations": @{
           @"title": @"Reminders in Date Range",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"start": @{ @"type": @"string",
                            @"description": @"Range start, ISO 8601." },
               @"end":   @{ @"type": @"string", @"description": @"Range end, ISO 8601." },
               @"lists": @{ @"type": @"array",
                            @"items": @{ @"type": @"string" },
                            @"description": @"Optional: filter to specific list names. "
                                            @"Omit for all lists." },
               @"include_completed": @{ @"type": @"boolean",
                                        @"description": @"Include completed. Default false." },
               @"include_notes":     @{ @"type": @"boolean",
                                        @"description": @"Include notes. Default false." }
           },
           @"required": @[@"start", @"end"]
       }
    },

    @{ @"name": @"reminder_search",
       @"description": @"Search reminders by text against title and notes (case-insensitive). "
                        @"Searches across all lists. Excludes completed by default.",
       @"annotations": @{
           @"title": @"Search Reminders",
           @"readOnlyHint":    @YES,
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"query": @{ @"type": @"string",
                            @"description": @"Text to search for (case-insensitive)." },
               @"include_completed": @{ @"type": @"boolean",
                                        @"description": @"Include completed in results. Default false." },
               @"include_notes":     @{ @"type": @"boolean",
                                        @"description": @"Include notes in results. Default false." }
           },
           @"required": @[@"query"]
       }
    },

    @{ @"name": @"reminder_create",
       @"description": @"Create a new reminder. "
                        @"Use reminder_lists first to confirm the target list name. "
                        @"priority is 'high', 'medium', 'low', or omitted (none). "
                        @"#-prefixed words anywhere in the title or notes are automatically converted to native Apple Reminder tags (e.g. #in-progress, #backlog).",
       @"annotations": @{
           @"title": @"Create Reminder",
           @"readOnlyHint":    @NO,
           @"destructiveHint": @NO,
           @"idempotentHint":  @NO,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title": @{ @"type": @"string" },
               @"list":  @{ @"type": @"string",
                            @"description": @"Reminder list name (must be editable)." },
               @"due":   @{ @"type": @"string",
                            @"description": @"Optional due date, ISO 8601." },
               @"priority": @{ @"type": @"string",
                               @"enum": @[@"high", @"medium", @"low"],
                               @"description": @"Optional priority." },
               @"notes": @{ @"type": @"string" }
           },
           @"required": @[@"title", @"list"]
       }
    },

    @{ @"name": @"reminder_update",
       @"description": @"Update an existing reminder. "
                        @"Identify it by its current title + list + due (ISO 8601, omit "
                        @"for reminders with no due date). Supply only fields to change "
                        @"in `changes`. Pass null for `due` in changes to clear the due date.",
       @"annotations": @{
           @"title": @"Update Reminder",
           @"readOnlyHint":    @NO,
           @"destructiveHint": @YES,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title": @{ @"type": @"string",
                            @"description": @"Current title — part of the lookup key." },
               @"list":  @{ @"type": @"string",
                            @"description": @"Current list — part of the lookup key." },
               @"due":   @{ @"type": @"string",
                            @"description": @"Current due, ISO 8601 — omit if reminder has no due date." },
               @"changes": @{
                   @"type": @"object",
                   @"description": @"Fields to change. All optional.",
                   @"properties": @{
                       @"title":     @{ @"type": @"string" },
                       @"due":       @{ @"type": @"string", @"description": @"New due, ISO 8601, or null to clear." },
                       @"notes":     @{ @"type": @"string" },
                       @"priority":  @{ @"type": @"string", @"enum": @[@"high", @"medium", @"low"] },
                       @"completed": @{ @"type": @"boolean" }
                   }
               }
           },
           @"required": @[@"title", @"list", @"changes"]
       }
    },

    @{ @"name": @"reminder_complete",
       @"description": @"Mark a reminder as completed. "
                        @"Identify it by title + list + due (omit due if reminder has none). "
                        @"Idempotent — completing an already-completed reminder is a no-op.",
       @"annotations": @{
           @"title": @"Complete Reminder",
           @"readOnlyHint":    @NO,
           // Completing isn't destructive (data is preserved, just flagged).
           // EventKit even keeps a completionDate so it's reversible.
           @"destructiveHint": @NO,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title": @{ @"type": @"string" },
               @"list":  @{ @"type": @"string" },
               @"due":   @{ @"type": @"string", @"description": @"Optional, ISO 8601." }
           },
           @"required": @[@"title", @"list"]
       }
    },

    @{ @"name": @"reminder_delete",
       @"description": @"Delete a reminder permanently. "
                        @"A native confirmation dialog will appear before deletion proceeds. "
                        @"Prefer reminder_complete unless the reminder is truly unwanted.",
       @"annotations": @{
           @"title": @"Delete Reminder",
           @"readOnlyHint":    @NO,
           @"destructiveHint": @YES,
           @"idempotentHint":  @YES,
           @"openWorldHint":   @NO
       },
       @"inputSchema": @{
           @"type": @"object",
           @"properties": @{
               @"title": @{ @"type": @"string" },
               @"list":  @{ @"type": @"string" },
               @"due":   @{ @"type": @"string", @"description": @"Optional, ISO 8601." }
           },
           @"required": @[@"title", @"list"]
       }
    }

    ];
}

#pragma mark - Helpers

+ (EKSpan)spanFromString:(nullable NSString *)s {
    if ([s isEqualToString:@"following"]) return EKSpanFutureEvents;
    return EKSpanThisEvent; // default: "this"
}

/// Serialize result as a JSON text block.
- (void)resultJSON:(id)obj forRpcId:(id)rpcId {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    NSString *json = data
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{}";
    [self write:MCPJSONRPCResult(rpcId, @{
        @"content": @[@{ @"type": @"text", @"text": json }]
    })];
}

/// Return a plain-text result (confirmation messages, errors).
- (void)resultText:(NSString *)text forRpcId:(id)rpcId isError:(BOOL)isError {
    NSDictionary *result = isError
        ? @{ @"isError": @YES, @"content": @[@{ @"type": @"text", @"text": text }] }
        : @{              @"content": @[@{ @"type": @"text", @"text": text }] };
    [self write:MCPJSONRPCResult(rpcId, result)];
}

- (void)write:(NSString *_Nullable)line {
    if (!line) return;
    dispatch_async(self.writeQueue, ^{
        NSData *out = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        @try { [self.stdoutHandle writeData:out]; }
        @catch (NSException *e) {
            fprintf(stderr, "[Kairos] stdout write failed: %s\n",
                    e.reason.UTF8String ?: "?");
        }
    });
}

@end
