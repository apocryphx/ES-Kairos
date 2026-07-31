//
//  MailBridge.h
//  Kairos
//
//  Read-only Apple Mail wrapper via Scripting Bridge. Follows the same
//  singleton+queue pattern as EKBridge/CNBridge. SBObject references never
//  cross the queue boundary — all results are plain NSDictionary/NSArray.
//
//  Authorization is Apple Events / Automation TCC (a different animal from
//  Calendar/Contacts/Reminders): the system prompt fires on the first event
//  sent to Mail, and sending an event launches Mail.app if it isn't running.
//  Access is therefore requested lazily on first tool use, not at app launch.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MailBridge : NSObject

+ (instancetype)shared;

/// Non-prompting probe of the Automation permission for com.apple.mail.
/// YES only if TCC has already settled on "authorized".
@property (readonly, atomic) BOOL isAuthorized;

/// Accounts and their mailboxes with unread counts.
/// Returns: { accounts: [ { name, mailboxes: [ { name, unread } ] } ] }
/// or { error } on failure.
- (NSDictionary *)listMailboxes;

/// Recent messages in a mailbox, newest first. `mailboxName` nil = unified
/// inbox; the special names inbox/sent/drafts/trash/junk/outbox resolve to
/// the corresponding top-level mailboxes. `limit` is clamped to [1, 50];
/// pass 0 for the default (20).
/// Returns: { mailbox, total, returned, messages: [ { subject, from, date, read } ] }
- (NSDictionary *)listMessagesInMailbox:(nullable NSString *)mailboxName
                                account:(nullable NSString *)accountName
                             unreadOnly:(BOOL)unreadOnly
                                  limit:(NSInteger)limit;

/// Case-insensitive substring search over subject and sender, scoped to one
/// mailbox (nil = unified inbox), optional received-date window.
/// Returns the same shape as listMessagesInMailbox plus `matched`.
- (NSDictionary *)searchMessagesMatching:(NSString *)query
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                    from:(nullable NSDate *)from
                                      to:(nullable NSDate *)to
                                   limit:(NSInteger)limit;

/// Full message resolved by semantic key (subject [+ sender substring]
/// [+ date ±2 min]) within a mailbox (nil = unified inbox). When several
/// messages match, returns { ambiguous: true, candidates: [...] } with
/// 1-based `index` fields; call again with `index` to disambiguate.
/// Returns: { subject, from, to[], cc[], reply_to?, date_sent, date_received,
///            read, mailbox, attachments[]?, body, body_truncated? }
- (NSDictionary *)readMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
