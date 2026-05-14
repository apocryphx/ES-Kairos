//
//  EKBridge.h
//  Kairos
//
//  EventKit wrapper. All EKEventStore operations run on a private serial
//  queue. EKEvent objects never cross the queue boundary — results are
//  converted to NSDictionary before being returned to callers.
//
//  Event identity: (title, calendarName, startDate) — sufficient for
//  unambiguous lookup in personal calendars. An `index` field is added
//  to query results only when multiple events share the same title and
//  calendar within the result set (e.g. consecutive recurrences).
//

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const EKBridgeErrorDomain;

typedef NS_ENUM(NSInteger, EKBridgeError) {
    EKBridgeErrorNotAuthorized   = 1,
    EKBridgeErrorCalendarNotFound = 2,
    EKBridgeErrorCalendarReadOnly = 3,
    EKBridgeErrorEventNotFound   = 4,
    EKBridgeErrorEventAmbiguous  = 5,
    EKBridgeErrorInvalidDate     = 6,
    EKBridgeErrorSaveFailed      = 7,
    EKBridgeErrorReminderListNotFound = 8,
    EKBridgeErrorReminderNotFound     = 9,
    EKBridgeErrorReminderAmbiguous    = 10,
};

@interface EKBridge : NSObject

+ (instancetype)shared;

/// Request full access to events. Call once at app launch.
/// Completion is called on an arbitrary thread.
- (void)requestAccessWithCompletion:(void (^)(BOOL granted, NSError *_Nullable error))completion;

/// Request full access to reminders. Same store, separate TCC entitlement.
- (void)requestRemindersAccessWithCompletion:(void (^)(BOOL granted, NSError *_Nullable error))completion;

@property (readonly, atomic) BOOL isAuthorized;
@property (readonly, atomic) BOOL isAuthorizedForReminders;

// ── Calendars ────────────────────────────────────────────────────────────────

/// Returns: [ { name, type, source, editable } ]
- (NSArray<NSDictionary *> *)listCalendars;

// ── Queries ──────────────────────────────────────────────────────────────────

/// Events in [start, end]. calendarNames = nil → all calendars.
/// includeNotes = NO omits the notes field (saves tokens for large ranges).
- (NSArray<NSDictionary *> *)eventsFrom:(NSDate *)start
                                      to:(NSDate *)end
                           calendarNames:(nullable NSArray<NSString *> *)names
                            includeNotes:(BOOL)includeNotes;

/// Case-insensitive substring search across title, location, and notes.
/// Default window when start/end are nil: ±6 months from today.
- (NSArray<NSDictionary *> *)eventsMatchingQuery:(NSString *)query
                                            from:(nullable NSDate *)start
                                              to:(nullable NSDate *)end
                                    includeNotes:(BOOL)includeNotes;

// ── Mutations ────────────────────────────────────────────────────────────────

/// Create a new event. Returns the formatted event dict on success.
- (nullable NSDictionary *)createEventWithTitle:(NSString *)title
                                   calendarName:(NSString *)calendarName
                                          start:(NSDate *)start
                                            end:(NSDate *)end
                                         allDay:(BOOL)allDay
                                       location:(nullable NSString *)location
                                          notes:(nullable NSString *)notes
                                          error:(NSError **)error;

/// Update event identified by (title, calendarName, start).
/// changes keys: "title", "start", "end", "location", "notes", "all_day"
/// span: EKSpanThisEvent or EKSpanFutureEvents.
- (BOOL)updateEventWithTitle:(NSString *)title
                calendarName:(NSString *)calendarName
                       start:(NSDate *)start
                     changes:(NSDictionary *)changes
                        span:(EKSpan)span
                       error:(NSError **)error;

/// Delete event identified by (title, calendarName, start).
- (BOOL)deleteEventWithTitle:(NSString *)title
                calendarName:(NSString *)calendarName
                       start:(NSDate *)start
                        span:(EKSpan)span
                       error:(NSError **)error;

// ── Reminders ────────────────────────────────────────────────────────────────
//
// Reminder identity: (title, listName, dueDate). When dueDate is nil
// (reminder without a due date), identity falls back to (title, listName)
// and an `index` field disambiguates duplicates.

/// Returns: [ { name, source, editable } ]
- (NSArray<NSDictionary *> *)listReminderLists;

/// Fetches and synchronously returns reminders. EventKit's reminder fetch
/// is async; the bridge wraps it in a semaphore on the bridge queue.

/// All reminders due today + any overdue (uncompleted, due in the past).
/// includeCompleted=NO is the typical morning-brief mode.
- (NSArray<NSDictionary *> *)remindersDueTodayOrOverdue:(BOOL)includeCompleted
                                                  notes:(BOOL)includeNotes;

/// Reminders with due dates in [start, end]. listNames=nil → all lists.
- (NSArray<NSDictionary *> *)remindersFrom:(NSDate *)start
                                        to:(NSDate *)end
                                listNames:(nullable NSArray<NSString *> *)names
                       includeCompleted:(BOOL)includeCompleted
                              includeNotes:(BOOL)includeNotes;

/// Case-insensitive substring search across title and notes.
- (NSArray<NSDictionary *> *)remindersMatchingQuery:(NSString *)query
                                  includeCompleted:(BOOL)includeCompleted
                                      includeNotes:(BOOL)includeNotes;

/// Create a new reminder.
/// priority: "high" (1), "medium" (5), "low" (9), or nil for none.
- (nullable NSDictionary *)createReminderWithTitle:(NSString *)title
                                          listName:(NSString *)listName
                                           dueDate:(nullable NSDate *)dueDate
                                          priority:(nullable NSString *)priority
                                             notes:(nullable NSString *)notes
                                             error:(NSError **)error;

/// Update reminder identified by (title, listName, dueDate).
/// changes keys: "title", "due", "notes", "priority", "completed".
- (BOOL)updateReminderWithTitle:(NSString *)title
                       listName:(NSString *)listName
                        dueDate:(nullable NSDate *)dueDate
                        changes:(NSDictionary *)changes
                          error:(NSError **)error;

/// Mark a reminder complete by (title, listName, dueDate).
- (BOOL)completeReminderWithTitle:(NSString *)title
                         listName:(NSString *)listName
                          dueDate:(nullable NSDate *)dueDate
                            error:(NSError **)error;

/// Delete reminder by (title, listName, dueDate).
- (BOOL)deleteReminderWithTitle:(NSString *)title
                       listName:(NSString *)listName
                        dueDate:(nullable NSDate *)dueDate
                          error:(NSError **)error;

// ── Date utilities (public for MCPServer argument parsing) ───────────────────

/// Parses ISO 8601 with time (timezone-aware) or date-only (local timezone).
/// Returns nil if the string cannot be parsed.
- (nullable NSDate *)parseDateString:(nullable NSString *)str;

/// Human-readable date for MCP output.
/// allDay=YES → "Thu May 16, 2026"
/// allDay=NO  → "Thu May 16, 2026 · 2:00 PM"
- (NSString *)formatDate:(NSDate *)date allDay:(BOOL)allDay;

@end

NS_ASSUME_NONNULL_END
