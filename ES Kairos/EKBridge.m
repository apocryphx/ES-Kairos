//
//  EKBridge.m
//  Kairos
//

#import "EKBridge.h"

NSString *const EKBridgeErrorDomain = @"com.elarity.kairos.ekbridge";

// Lookup window: ±2 minutes around the supplied start date.
// Tight enough to be unambiguous for personal calendars; wide enough
// to tolerate rounding in how the LLM echoes timestamps.
static const NSTimeInterval kLookupWindow = 120.0;

// Default search span for event_search when no dates are given.
static const NSTimeInterval kDefaultSearchRadius = 60.0 * 60.0 * 24.0 * 180.0; // ±6 months

@interface EKBridge ()
@property (strong) EKEventStore *store;
@property (strong) dispatch_queue_t queue;
@property (atomic)  BOOL authorized;
@property (atomic)  BOOL authorizedForReminders;
@end

@implementation EKBridge

+ (instancetype)shared {
    static EKBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[EKBridge alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create("com.elarity.kairos.ekbridge", DISPATCH_QUEUE_SERIAL);

    // EKEventStore must be created on the thread/queue that will use it.
    dispatch_sync(_queue, ^{
        self->_store = [[EKEventStore alloc] init];
    });

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(storeDidChange:)
               name:EKEventStoreChangedNotification
             object:nil];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)storeDidChange:(NSNotification *)note {
    // Reset on the bridge queue so in-flight queries finish before we reset.
    dispatch_async(self.queue, ^{
        [self.store reset];
        fprintf(stderr, "[Kairos] EKEventStore reset after external change\n");
    });
}

#pragma mark - Authorization

+ (NSString *)stringForEventAuthStatus:(EKAuthorizationStatus)s {
    switch (s) {
        case EKAuthorizationStatusNotDetermined: return @"notDetermined";
        case EKAuthorizationStatusRestricted:    return @"restricted";
        case EKAuthorizationStatusDenied:        return @"denied";
        case EKAuthorizationStatusFullAccess:    return @"fullAccess";
        case EKAuthorizationStatusWriteOnly:     return @"writeOnly";
        default:                                  return @"unknown";
    }
}

- (void)requestAccessWithCompletion:(void (^)(BOOL, NSError *_Nullable))completion {
    EKAuthorizationStatus pre = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    fprintf(stderr, "[Kairos] EKBridge pre-request status: %s\n",
            [EKBridge stringForEventAuthStatus:pre].UTF8String);

    // Already settled — don't re-prompt, which can race other TCC dialogs.
    if (pre == EKAuthorizationStatusFullAccess) {
        self.authorized = YES;
        completion(YES, nil);
        return;
    }
    if (pre == EKAuthorizationStatusDenied || pre == EKAuthorizationStatusRestricted) {
        self.authorized = NO;
        completion(NO, nil);
        return;
    }

    [self.store requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *error) {
        EKAuthorizationStatus post = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
        fprintf(stderr, "[Kairos] EKBridge post-request status: %s (callback granted=%s)\n",
                [EKBridge stringForEventAuthStatus:post].UTF8String,
                granted ? "yes" : "no");
        BOOL effective = granted || post == EKAuthorizationStatusFullAccess;
        self.authorized = effective;
        completion(effective, error);
    }];
}

- (BOOL)isAuthorized {
    // Always re-read TCC — covers grant-in-Settings-while-running.
    return [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent]
        == EKAuthorizationStatusFullAccess;
}

- (EKEventStore *)underlyingStore {
    return _store;
}

- (void)requestRemindersAccessWithCompletion:(void (^)(BOOL, NSError *_Nullable))completion {
    EKAuthorizationStatus pre = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
    fprintf(stderr, "[Kairos] EKBridge reminders pre-request status: %s\n",
            [EKBridge stringForEventAuthStatus:pre].UTF8String);

    if (pre == EKAuthorizationStatusFullAccess) {
        self.authorizedForReminders = YES;
        completion(YES, nil);
        return;
    }
    if (pre == EKAuthorizationStatusDenied || pre == EKAuthorizationStatusRestricted) {
        self.authorizedForReminders = NO;
        completion(NO, nil);
        return;
    }

    [self.store requestFullAccessToRemindersWithCompletion:^(BOOL granted, NSError *error) {
        EKAuthorizationStatus post = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
        fprintf(stderr, "[Kairos] EKBridge reminders post-request status: %s (callback granted=%s)\n",
                [EKBridge stringForEventAuthStatus:post].UTF8String,
                granted ? "yes" : "no");
        BOOL effective = granted || post == EKAuthorizationStatusFullAccess;
        self.authorizedForReminders = effective;
        completion(effective, error);
    }];
}

- (BOOL)isAuthorizedForReminders {
    return [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder]
        == EKAuthorizationStatusFullAccess;
}

#pragma mark - Calendars

- (NSArray<NSDictionary *> *)listCalendars {
    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSArray<EKCalendar *> *cals =
            [self.store calendarsForEntityType:EKEntityTypeEvent];
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:cals.count];
        for (EKCalendar *cal in cals) {
            [out addObject:@{
                @"name":     cal.title ?: @"",
                @"type":     [EKBridge stringForCalendarType:cal.type],
                @"source":   cal.source.title ?: @"",
                @"editable": @(cal.allowsContentModifications)
            }];
        }
        result = [out copy];
    });
    return result;
}

+ (NSString *)stringForCalendarType:(EKCalendarType)type {
    switch (type) {
        case EKCalendarTypeLocal:        return @"local";
        case EKCalendarTypeCalDAV:       return @"caldav";
        case EKCalendarTypeExchange:     return @"exchange";
        case EKCalendarTypeSubscription: return @"subscription";
        case EKCalendarTypeBirthday:     return @"birthday";
        default:                         return @"unknown";
    }
}

#pragma mark - Queries

- (NSArray<NSDictionary *> *)eventsFrom:(NSDate *)start
                                      to:(NSDate *)end
                           calendarNames:(nullable NSArray<NSString *> *)names
                            includeNotes:(BOOL)includeNotes {
    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSArray<EKCalendar *> *cals = [self resolveCalendarNames:names];
        NSPredicate *pred = [self.store predicateForEventsWithStartDate:start
                                                               endDate:end
                                                             calendars:cals];
        NSArray<EKEvent *> *events = [[self.store eventsMatchingPredicate:pred]
            sortedArrayUsingComparator:^NSComparisonResult(EKEvent *a, EKEvent *b) {
                return [a.startDate compare:b.startDate];
            }];
        result = [self formatEventSet:events includeNotes:includeNotes];
    });
    return result;
}

- (NSArray<NSDictionary *> *)eventsMatchingQuery:(NSString *)query
                                            from:(nullable NSDate *)start
                                              to:(nullable NSDate *)end
                                    includeNotes:(BOOL)includeNotes {
    if (!start) start = [NSDate dateWithTimeIntervalSinceNow:-kDefaultSearchRadius];
    if (!end)   end   = [NSDate dateWithTimeIntervalSinceNow:+kDefaultSearchRadius];

    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSPredicate *pred = [self.store predicateForEventsWithStartDate:start
                                                               endDate:end
                                                             calendars:nil];
        NSArray<EKEvent *> *all = [self.store eventsMatchingPredicate:pred];
        NSString *q = query.lowercaseString;

        NSMutableArray<EKEvent *> *matches = [NSMutableArray array];
        for (EKEvent *e in all) {
            if ([e.title.lowercaseString          containsString:q] ||
                [e.location.lowercaseString        containsString:q] ||
                [e.notes.lowercaseString           containsString:q]) {
                [matches addObject:e];
            }
        }
        [matches sortUsingComparator:^NSComparisonResult(EKEvent *a, EKEvent *b) {
            return [a.startDate compare:b.startDate];
        }];
        result = [self formatEventSet:matches includeNotes:includeNotes];
    });
    return result;
}

#pragma mark - Mutations

- (nullable NSDictionary *)createEventWithTitle:(NSString *)title
                                   calendarName:(NSString *)calendarName
                                          start:(NSDate *)start
                                            end:(NSDate *)end
                                         allDay:(BOOL)allDay
                                       location:(nullable NSString *)location
                                          notes:(nullable NSString *)notes
                                          error:(NSError **)error {
    __block NSDictionary *result = nil;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKCalendar *cal = [self calendarNamed:calendarName];
        if (!cal) {
            inner = [self errorCode:EKBridgeErrorCalendarNotFound
                            message:[NSString stringWithFormat:@"Calendar not found: \"%@\"", calendarName]];
            return;
        }
        if (!cal.allowsContentModifications) {
            inner = [self errorCode:EKBridgeErrorCalendarReadOnly
                            message:[NSString stringWithFormat:@"Calendar \"%@\" is read-only", calendarName]];
            return;
        }

        EKEvent *ev = [EKEvent eventWithEventStore:self.store];
        ev.title     = title;
        ev.calendar  = cal;
        ev.startDate = start;
        ev.endDate   = end;
        ev.allDay    = allDay;
        if (location.length > 0) ev.location = location;
        if (notes.length > 0)    ev.notes    = notes;

        NSError *saveErr = nil;
        if ([self.store saveEvent:ev span:EKSpanThisEvent commit:YES error:&saveErr]) {
            result = [self formatEvent:ev includeNotes:YES index:NSNotFound];
        } else {
            inner = saveErr ?: [self errorCode:EKBridgeErrorSaveFailed message:@"Save failed"];
        }
    });

    if (error) *error = inner;
    return result;
}

- (BOOL)updateEventWithTitle:(NSString *)title
                calendarName:(NSString *)calendarName
                       start:(NSDate *)start
                     changes:(NSDictionary *)changes
                        span:(EKSpan)span
                       error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKEvent *ev = [self resolveTitle:title calendarName:calendarName start:start error:&inner];
        if (!ev) return;

        if (changes[@"title"])    ev.title    = changes[@"title"];
        if (changes[@"location"]) ev.location = changes[@"location"];
        if (changes[@"notes"])    ev.notes    = changes[@"notes"];
        if (changes[@"all_day"])  ev.allDay   = [changes[@"all_day"] boolValue];

        if (changes[@"start"]) {
            NSDate *d = [self parseDateString:changes[@"start"]];
            if (!d) { inner = [self errorCode:EKBridgeErrorInvalidDate
                                      message:[NSString stringWithFormat:@"Cannot parse start: %@", changes[@"start"]]];
                      return; }
            ev.startDate = d;
        }
        if (changes[@"end"]) {
            NSDate *d = [self parseDateString:changes[@"end"]];
            if (!d) { inner = [self errorCode:EKBridgeErrorInvalidDate
                                      message:[NSString stringWithFormat:@"Cannot parse end: %@", changes[@"end"]]];
                      return; }
            ev.endDate = d;
        }

        NSError *saveErr = nil;
        success = [self.store saveEvent:ev span:span commit:YES error:&saveErr];
        if (!success) inner = saveErr ?: [self errorCode:EKBridgeErrorSaveFailed message:@"Save failed"];
    });

    if (error) *error = inner;
    return success;
}

- (BOOL)deleteEventWithTitle:(NSString *)title
                calendarName:(NSString *)calendarName
                       start:(NSDate *)start
                        span:(EKSpan)span
                       error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKEvent *ev = [self resolveTitle:title calendarName:calendarName start:start error:&inner];
        if (!ev) return;

        NSError *removeErr = nil;
        success = [self.store removeEvent:ev span:span commit:YES error:&removeErr];
        if (!success) inner = removeErr;
    });

    if (error) *error = inner;
    return success;
}

#pragma mark - Private: Resolution (call on self.queue)

- (nullable EKCalendar *)calendarNamed:(NSString *)name {
    for (EKCalendar *cal in [self.store calendarsForEntityType:EKEntityTypeEvent]) {
        if ([cal.title isEqualToString:name]) return cal;
    }
    return nil;
}

/// Returns nil (all calendars) if names is nil/empty. Logs unknowns but continues.
- (nullable NSArray<EKCalendar *> *)resolveCalendarNames:(nullable NSArray<NSString *> *)names {
    if (!names.count) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *name in names) {
        EKCalendar *cal = [self calendarNamed:name];
        if (cal) [result addObject:cal];
        else fprintf(stderr, "[Kairos] resolveCalendarNames: unknown calendar \"%s\"\n",
                     name.UTF8String);
    }
    return result.count ? result : nil;
}

/// Lookup by semantic key. Returns nil + error on 0 or >1 matches.
- (nullable EKEvent *)resolveTitle:(NSString *)title
                      calendarName:(NSString *)calendarName
                             start:(NSDate *)start
                             error:(NSError **)error {
    NSDate *wStart = [start dateByAddingTimeInterval:-kLookupWindow];
    NSDate *wEnd   = [start dateByAddingTimeInterval:+kLookupWindow];

    EKCalendar *cal = [self calendarNamed:calendarName];
    NSArray<EKCalendar *> *cals = cal ? @[cal] : nil;

    NSPredicate *pred = [self.store predicateForEventsWithStartDate:wStart
                                                           endDate:wEnd
                                                         calendars:cals];
    NSMutableArray<EKEvent *> *matches = [NSMutableArray array];
    for (EKEvent *e in [self.store eventsMatchingPredicate:pred]) {
        if ([e.title isEqualToString:title]) [matches addObject:e];
    }

    if (matches.count == 0) {
        if (error) *error = [self errorCode:EKBridgeErrorEventNotFound
                                    message:[NSString stringWithFormat:
                                        @"No event \"%@\" in \"%@\" at %@",
                                        title, calendarName, [self formatDate:start allDay:NO]]];
        return nil;
    }
    if (matches.count > 1) {
        if (error) *error = [self errorCode:EKBridgeErrorEventAmbiguous
                                    message:[NSString stringWithFormat:
                                        @"%lu events named \"%@\" at %@; narrow the start time",
                                        (unsigned long)matches.count, title,
                                        [self formatDate:start allDay:NO]]];
        return nil;
    }
    return matches.firstObject;
}

#pragma mark - Private: Formatting (call on self.queue)

/// Add index fields only to events that share title+calendar with another event in the set.
- (NSArray<NSDictionary *> *)formatEventSet:(NSArray<EKEvent *> *)events
                               includeNotes:(BOOL)includeNotes {
    // Count occurrences of each title+calendar key
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (EKEvent *e in events) {
        NSString *key = [NSString stringWithFormat:@"%@\t%@", e.title, e.calendar.title];
        counts[key] = @(counts[key].integerValue + 1);
    }

    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:events.count];

    for (EKEvent *e in events) {
        NSString *key = [NSString stringWithFormat:@"%@\t%@", e.title, e.calendar.title];
        NSUInteger total = counts[key].unsignedIntegerValue;

        NSUInteger idx = NSNotFound;
        if (total > 1) {
            NSUInteger n = seen[key].unsignedIntegerValue + 1;
            seen[key] = @(n);
            idx = n;
        }
        [out addObject:[self formatEvent:e includeNotes:includeNotes index:idx]];
    }
    return [out copy];
}

- (NSDictionary *)formatEvent:(EKEvent *)e
                 includeNotes:(BOOL)includeNotes
                        index:(NSUInteger)index {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    if (index != NSNotFound) d[@"index"] = @(index);
    d[@"title"]    = e.title ?: @"(untitled)";
    d[@"calendar"] = e.calendar.title ?: @"";

    if (e.isAllDay) {
        d[@"date"] = [self formatDate:e.startDate allDay:YES];
    } else {
        d[@"start"] = [self formatDate:e.startDate allDay:NO];
        d[@"end"]   = [self formatDate:e.endDate   allDay:NO];
    }

    if (e.location.length > 0)                d[@"location"]  = e.location;
    if (includeNotes && e.notes.length > 0)   d[@"notes"]     = e.notes;
    if (e.hasRecurrenceRules)                  d[@"recurring"] = @YES;

    return [d copy];
}

#pragma mark - Public: Date Utilities

- (nullable NSDate *)parseDateString:(nullable NSString *)str {
    if (!str.length) return nil;

    // Try in order: ISO 8601 with timezone (Z or ±HH:MM) →
    //               local-time ISO without timezone ("2026-05-14T14:30:00") →
    //               date-only ("2026-05-14") interpreted as local midnight.
    static NSISO8601DateFormatter *isoWithTZ = nil;
    static NSDateFormatter *localISO = nil;
    static NSDateFormatter *dateOnly = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isoWithTZ = [[NSISO8601DateFormatter alloc] init];
        isoWithTZ.formatOptions = NSISO8601DateFormatWithInternetDateTime;

        localISO = [[NSDateFormatter alloc] init];
        localISO.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        localISO.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        localISO.timeZone   = [NSTimeZone localTimeZone];

        dateOnly = [[NSDateFormatter alloc] init];
        dateOnly.dateFormat = @"yyyy-MM-dd";
        dateOnly.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dateOnly.timeZone   = [NSTimeZone localTimeZone];
    });

    NSDate *d = [isoWithTZ dateFromString:str];
    if (d) return d;
    d = [localISO dateFromString:str];
    if (d) return d;
    return [dateOnly dateFromString:str];
}

- (NSString *)formatDate:(NSDate *)date allDay:(BOOL)allDay {
    static NSDateFormatter *timed = nil;
    static NSDateFormatter *day   = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timed = [[NSDateFormatter alloc] init];
        timed.dateFormat = @"EEE MMM d, yyyy · h:mm a";

        day = [[NSDateFormatter alloc] init];
        day.dateFormat = @"EEE MMM d, yyyy";
    });
    return allDay ? [day stringFromDate:date] : [timed stringFromDate:date];
}

#pragma mark - Private: Error Construction

- (NSError *)errorCode:(EKBridgeError)code message:(NSString *)msg {
    return [NSError errorWithDomain:EKBridgeErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

#pragma mark - Reminders: Lists

- (NSArray<NSDictionary *> *)listReminderLists {
    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSArray<EKCalendar *> *lists =
            [self.store calendarsForEntityType:EKEntityTypeReminder];
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:lists.count];
        for (EKCalendar *list in lists) {
            [out addObject:@{
                @"name":     list.title ?: @"",
                @"source":   list.source.title ?: @"",
                @"editable": @(list.allowsContentModifications)
            }];
        }
        result = [out copy];
    });
    return result;
}

#pragma mark - Reminders: Queries

/// EventKit's fetchRemindersMatchingPredicate:completion: is async. We
/// block on the bridge queue with a semaphore so callers see a sync API.
- (NSArray<EKReminder *> *)fetchRemindersWithPredicate:(NSPredicate *)pred {
    __block NSArray<EKReminder *> *result = @[];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self.store fetchRemindersMatchingPredicate:pred
                                     completion:^(NSArray<EKReminder *> *r) {
        result = r ?: @[];
        dispatch_semaphore_signal(sem);
    }];
    // 10s ceiling — if EventKit hangs, return empty rather than deadlock.
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

- (NSArray<NSDictionary *> *)remindersDueTodayOrOverdue:(BOOL)includeCompleted
                                                  notes:(BOOL)includeNotes {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDate *now = [NSDate date];
    NSDateComponents *c = [cal components:
        (NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:now];
    c.calendar = cal;
    c.hour = 0; c.minute = 0; c.second = 0;
    NSDate *startOfToday = c.date;
    c.hour = 23; c.minute = 59; c.second = 59;
    NSDate *endOfToday = c.date;
    // Overdue = any uncompleted reminder dated before today.
    NSDate *farPast = [NSDate dateWithTimeIntervalSince1970:0];

    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSPredicate *pred;
        if (includeCompleted) {
            pred = [self.store predicateForRemindersInCalendars:nil];
        } else {
            pred = [self.store predicateForIncompleteRemindersWithDueDateStarting:farPast
                                                                           ending:endOfToday
                                                                        calendars:nil];
        }
        NSArray<EKReminder *> *all = [self fetchRemindersWithPredicate:pred];

        NSMutableArray<EKReminder *> *matches = [NSMutableArray array];
        for (EKReminder *r in all) {
            if (!includeCompleted && r.isCompleted) continue;
            NSDate *due = r.dueDateComponents.date;
            if (!due) continue; // no due date → not today/overdue
            if ([due compare:endOfToday] != NSOrderedDescending) {
                // Due today or earlier
                if (!includeCompleted && [due compare:startOfToday] == NSOrderedAscending && r.isCompleted) {
                    continue;
                }
                [matches addObject:r];
            }
        }
        result = [self formatReminderSet:matches includeNotes:includeNotes];
    });
    return result;
}

- (NSArray<NSDictionary *> *)remindersFrom:(NSDate *)start
                                        to:(NSDate *)end
                                listNames:(nullable NSArray<NSString *> *)names
                       includeCompleted:(BOOL)includeCompleted
                              includeNotes:(BOOL)includeNotes {
    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSArray<EKCalendar *> *lists = [self resolveReminderListNames:names];
        NSPredicate *pred = includeCompleted
            ? [self.store predicateForRemindersInCalendars:lists]
            : [self.store predicateForIncompleteRemindersWithDueDateStarting:start
                                                                      ending:end
                                                                   calendars:lists];
        NSArray<EKReminder *> *all = [self fetchRemindersWithPredicate:pred];

        NSMutableArray<EKReminder *> *matches = [NSMutableArray array];
        for (EKReminder *r in all) {
            NSDate *due = r.dueDateComponents.date;
            if (!due) continue;
            if ([due compare:start] == NSOrderedAscending) continue;
            if ([due compare:end]   == NSOrderedDescending) continue;
            if (!includeCompleted && r.isCompleted) continue;
            [matches addObject:r];
        }
        result = [self formatReminderSet:matches includeNotes:includeNotes];
    });
    return result;
}

- (NSArray<NSDictionary *> *)remindersMatchingQuery:(NSString *)query
                                  includeCompleted:(BOOL)includeCompleted
                                      includeNotes:(BOOL)includeNotes {
    __block NSArray *result;
    dispatch_sync(self.queue, ^{
        NSPredicate *pred = [self.store predicateForRemindersInCalendars:nil];
        NSArray<EKReminder *> *all = [self fetchRemindersWithPredicate:pred];
        NSString *q = query.lowercaseString;

        NSMutableArray<EKReminder *> *matches = [NSMutableArray array];
        for (EKReminder *r in all) {
            if (!includeCompleted && r.isCompleted) continue;
            if ([r.title.lowercaseString containsString:q] ||
                [r.notes.lowercaseString containsString:q]) {
                [matches addObject:r];
            }
        }
        result = [self formatReminderSet:matches includeNotes:includeNotes];
    });
    return result;
}

#pragma mark - Reminders: Mutations

- (nullable NSDictionary *)createReminderWithTitle:(NSString *)title
                                          listName:(NSString *)listName
                                           dueDate:(nullable NSDate *)dueDate
                                          priority:(nullable NSString *)priority
                                             notes:(nullable NSString *)notes
                                             error:(NSError **)error {
    __block NSDictionary *result = nil;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKCalendar *list = [self reminderListNamed:listName];
        if (!list) {
            inner = [self errorCode:EKBridgeErrorReminderListNotFound
                            message:[NSString stringWithFormat:@"Reminder list not found: \"%@\"", listName]];
            return;
        }
        if (!list.allowsContentModifications) {
            inner = [self errorCode:EKBridgeErrorCalendarReadOnly
                            message:[NSString stringWithFormat:@"Reminder list \"%@\" is read-only", listName]];
            return;
        }

        EKReminder *r = [EKReminder reminderWithEventStore:self.store];
        r.title    = title;
        r.calendar = list;
        if (dueDate) {
            NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
            r.dueDateComponents = [cal components:
                (NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|
                 NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:dueDate];
        }
        if (priority) r.priority = [EKBridge intForPriorityString:priority];
        if (notes.length > 0) r.notes = notes;

        NSError *saveErr = nil;
        if ([self.store saveReminder:r commit:YES error:&saveErr]) {
            result = [self formatReminder:r includeNotes:YES index:NSNotFound];
        } else {
            inner = saveErr ?: [self errorCode:EKBridgeErrorSaveFailed message:@"Save failed"];
        }
    });

    if (error) *error = inner;
    return result;
}

- (BOOL)updateReminderWithTitle:(NSString *)title
                       listName:(NSString *)listName
                        dueDate:(nullable NSDate *)dueDate
                        changes:(NSDictionary *)changes
                          error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKReminder *r = [self resolveReminderTitle:title listName:listName dueDate:dueDate error:&inner];
        if (!r) return;

        if (changes[@"title"]) r.title = changes[@"title"];
        if (changes[@"notes"]) r.notes = changes[@"notes"];
        if (changes[@"priority"]) {
            if (changes[@"priority"] == [NSNull null]) {
                r.priority = 0;
            } else {
                r.priority = [EKBridge intForPriorityString:changes[@"priority"]];
            }
        }
        if (changes[@"completed"]) r.completed = [changes[@"completed"] boolValue];

        if (changes[@"due"]) {
            if (changes[@"due"] == [NSNull null]) {
                r.dueDateComponents = nil;
            } else {
                NSDate *d = [self parseDateString:changes[@"due"]];
                if (!d) {
                    inner = [self errorCode:EKBridgeErrorInvalidDate
                                    message:[NSString stringWithFormat:@"Cannot parse due: %@", changes[@"due"]]];
                    return;
                }
                NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
                r.dueDateComponents = [cal components:
                    (NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|
                     NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:d];
            }
        }

        NSError *saveErr = nil;
        success = [self.store saveReminder:r commit:YES error:&saveErr];
        if (!success) inner = saveErr ?: [self errorCode:EKBridgeErrorSaveFailed message:@"Save failed"];
    });

    if (error) *error = inner;
    return success;
}

- (BOOL)completeReminderWithTitle:(NSString *)title
                         listName:(NSString *)listName
                          dueDate:(nullable NSDate *)dueDate
                            error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKReminder *r = [self resolveReminderTitle:title listName:listName dueDate:dueDate error:&inner];
        if (!r) return;
        r.completed = YES;
        NSError *saveErr = nil;
        success = [self.store saveReminder:r commit:YES error:&saveErr];
        if (!success) inner = saveErr ?: [self errorCode:EKBridgeErrorSaveFailed message:@"Save failed"];
    });

    if (error) *error = inner;
    return success;
}

- (BOOL)deleteReminderWithTitle:(NSString *)title
                       listName:(NSString *)listName
                        dueDate:(nullable NSDate *)dueDate
                          error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *inner = nil;

    dispatch_sync(self.queue, ^{
        EKReminder *r = [self resolveReminderTitle:title listName:listName dueDate:dueDate error:&inner];
        if (!r) return;
        NSError *removeErr = nil;
        success = [self.store removeReminder:r commit:YES error:&removeErr];
        if (!success) inner = removeErr;
    });

    if (error) *error = inner;
    return success;
}

#pragma mark - Reminders: Private helpers (call on self.queue)

- (nullable EKCalendar *)reminderListNamed:(NSString *)name {
    for (EKCalendar *list in [self.store calendarsForEntityType:EKEntityTypeReminder]) {
        if ([list.title isEqualToString:name]) return list;
    }
    return nil;
}

- (nullable NSArray<EKCalendar *> *)resolveReminderListNames:(nullable NSArray<NSString *> *)names {
    if (!names.count) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in names) {
        EKCalendar *list = [self reminderListNamed:name];
        if (list) [out addObject:list];
    }
    return out.count ? out : nil;
}

/// Lookup by (title, list, due). Returns nil + error on 0 or >1 matches.
- (nullable EKReminder *)resolveReminderTitle:(NSString *)title
                                     listName:(NSString *)listName
                                      dueDate:(nullable NSDate *)dueDate
                                        error:(NSError **)error {
    EKCalendar *list = [self reminderListNamed:listName];
    NSArray<EKCalendar *> *lists = list ? @[list] : nil;
    NSPredicate *pred = [self.store predicateForRemindersInCalendars:lists];
    NSArray<EKReminder *> *all = [self fetchRemindersWithPredicate:pred];

    NSMutableArray<EKReminder *> *matches = [NSMutableArray array];
    for (EKReminder *r in all) {
        if (![r.title isEqualToString:title]) continue;
        NSDate *due = r.dueDateComponents.date;
        if (dueDate) {
            if (!due) continue;
            // ±2 minute window, mirrors event lookup tolerance.
            if (fabs([due timeIntervalSinceDate:dueDate]) > 120.0) continue;
        } else {
            if (due) continue; // caller specified no due — skip reminders with a due
        }
        [matches addObject:r];
    }

    if (matches.count == 0) {
        if (error) *error = [self errorCode:EKBridgeErrorReminderNotFound
                                    message:[NSString stringWithFormat:
                                        @"No reminder \"%@\" in \"%@\"%@",
                                        title, listName,
                                        dueDate ? [NSString stringWithFormat:@" due %@", [self formatDate:dueDate allDay:NO]] : @" (no due date)"]];
        return nil;
    }
    if (matches.count > 1) {
        if (error) *error = [self errorCode:EKBridgeErrorReminderAmbiguous
                                    message:[NSString stringWithFormat:
                                        @"%lu reminders named \"%@\" matched; narrow the due date",
                                        (unsigned long)matches.count, title]];
        return nil;
    }
    return matches.firstObject;
}

#pragma mark - Reminders: Formatting (call on self.queue)

+ (int)intForPriorityString:(NSString *)s {
    if ([s isEqualToString:@"high"])   return 1;
    if ([s isEqualToString:@"medium"]) return 5;
    if ([s isEqualToString:@"low"])    return 9;
    return 0;
}

+ (nullable NSString *)stringForPriorityInt:(NSInteger)p {
    if (p >= 1 && p <= 4) return @"high";
    if (p == 5)            return @"medium";
    if (p >= 6 && p <= 9) return @"low";
    return nil;
}

- (NSArray<NSDictionary *> *)formatReminderSet:(NSArray<EKReminder *> *)reminders
                                  includeNotes:(BOOL)includeNotes {
    // Sort: overdue/today first by due date, undated last, ties by title.
    NSArray *sorted = [reminders sortedArrayUsingComparator:^NSComparisonResult(EKReminder *a, EKReminder *b) {
        NSDate *ad = a.dueDateComponents.date;
        NSDate *bd = b.dueDateComponents.date;
        if (ad && bd) return [ad compare:bd];
        if (ad && !bd) return NSOrderedAscending;
        if (!ad && bd) return NSOrderedDescending;
        return [a.title compare:b.title];
    }];

    // Duplicate-index: only when ≥2 share title+list.
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (EKReminder *r in sorted) {
        NSString *key = [NSString stringWithFormat:@"%@\t%@", r.title, r.calendar.title];
        counts[key] = @(counts[key].integerValue + 1);
    }
    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:sorted.count];

    for (EKReminder *r in sorted) {
        NSString *key = [NSString stringWithFormat:@"%@\t%@", r.title, r.calendar.title];
        NSUInteger total = counts[key].unsignedIntegerValue;
        NSUInteger idx = NSNotFound;
        if (total > 1) {
            NSUInteger n = seen[key].unsignedIntegerValue + 1;
            seen[key] = @(n);
            idx = n;
        }
        [out addObject:[self formatReminder:r includeNotes:includeNotes index:idx]];
    }
    return [out copy];
}

- (NSDictionary *)formatReminder:(EKReminder *)r
                    includeNotes:(BOOL)includeNotes
                           index:(NSUInteger)index {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    if (index != NSNotFound) d[@"index"] = @(index);
    d[@"title"] = r.title ?: @"(untitled)";
    d[@"list"]  = r.calendar.title ?: @"";

    NSDate *due = r.dueDateComponents.date;
    if (due) d[@"due"] = [self formatDate:due allDay:NO];

    if (r.isCompleted) d[@"completed"] = @YES;

    NSString *priorityLabel = [EKBridge stringForPriorityInt:r.priority];
    if (priorityLabel) d[@"priority"] = priorityLabel;

    if (includeNotes && r.notes.length > 0) d[@"notes"] = r.notes;

    return [d copy];
}

@end
