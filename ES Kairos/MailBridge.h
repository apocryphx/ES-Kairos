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

#pragma mark - Write operations (phase 2)
//
// All write methods resolve their target message by the same semantic key
// as readMessage (subject [+ sender substring] [+ date ±2 min], `index`
// disambiguation) and share its ambiguity/staleness behavior.
//
// The native confirmation dialogs live in MCPServer, not here. Methods
// that sometimes need confirmation are two-phase: called with
// confirmed:NO they return { needs_confirmation: YES, ... } previews
// without touching anything; the handler shows the dialog and calls
// again with confirmed:YES.

/// Set a message's read and/or flagged status. Pass nil to leave a flag
/// untouched; at least one must be non-nil. Reversible and idempotent.
/// Returns: { marked, read?, flagged? } or { error } / { ambiguous, candidates }.
- (NSDictionary *)markMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index
                                    read:(nullable NSNumber *)read
                                 flagged:(nullable NSNumber *)flagged;

/// Move a message to another mailbox. Deletion-like targets (Trash/Junk
/// and their provider aliases) require confirmed:YES; the first call
/// returns { needs_confirmation, target, message } instead of moving.
/// Returns: { moved, to } on success.
- (NSDictionary *)moveMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index
                               toMailbox:(NSString *)targetName
                               toAccount:(nullable NSString *)targetAccountName
                               confirmed:(BOOL)confirmed;

/// Compose a message into Drafts without sending. Additive and local —
/// nothing leaves the Mac. `from` selects the sending account by one of
/// its configured email addresses; nil uses Mail's default.
/// Returns: { drafted, to } or { error }.
- (NSDictionary *)draftMessageTo:(NSArray<NSString *> *)to
                              cc:(nullable NSArray<NSString *> *)cc
                         subject:(NSString *)subject
                            body:(NSString *)body
                            from:(nullable NSString *)from;

/// Compose and send a message. The caller (MCPServer) MUST have shown the
/// native confirmation dialog before invoking this — the bridge sends
/// unconditionally. Returns: { sent, to } or { error }.
- (NSDictionary *)sendMessageTo:(NSArray<NSString *> *)to
                             cc:(nullable NSArray<NSString *> *)cc
                        subject:(NSString *)subject
                           body:(NSString *)body
                           from:(nullable NSString *)from;

/// Reply to a resolved message via Mail's reply command (preserves
/// threading headers). Two-phase: confirmed:NO resolves, creates a
/// throwaway reply to read the exact recipients Mail would use, discards
/// it, and returns { needs_confirmation, reply_subject, recipients }.
/// confirmed:YES recreates the reply, sets the body (above Mail's quoted
/// original when the quote preference produces one), and sends.
/// Returns: { replied, to } on success.
- (NSDictionary *)replyToMessageWithSubject:(NSString *)subject
                                     sender:(nullable NSString *)sender
                                       date:(nullable NSDate *)date
                                    mailbox:(nullable NSString *)mailboxName
                                    account:(nullable NSString *)accountName
                                      index:(NSInteger)index
                                       body:(NSString *)body
                                   replyAll:(BOOL)replyAll
                                  confirmed:(BOOL)confirmed;

/// Forward a resolved message via Mail's forward command (the original
/// content rides below the supplied body, like reply quoting). Recipients
/// are caller-supplied, never inferred. Two-phase like reply: confirmed:NO
/// returns { needs_confirmation, forward_subject, message } without
/// sending. Returns: { forwarded, to } on success.
- (NSDictionary *)forwardMessageWithSubject:(NSString *)subject
                                     sender:(nullable NSString *)sender
                                       date:(nullable NSDate *)date
                                    mailbox:(nullable NSString *)mailboxName
                                    account:(nullable NSString *)accountName
                                      index:(NSInteger)index
                                         to:(NSArray<NSString *> *)to
                                         cc:(nullable NSArray<NSString *> *)cc
                                       body:(NSString *)body
                                  confirmed:(BOOL)confirmed;

/// Save one attachment of a resolved message to ~/Downloads/Kairos
/// Attachments/ — sanitized filename, collisions auto-suffixed, never
/// overwrites, quarantine xattr set so Gatekeeper treats the file as a
/// download. attachmentName nil (or no exact match) returns the
/// attachment list instead of saving.
/// Returns: { saved, path, bytes } / { attachments: [...] } / { error }.
- (NSDictionary *)saveAttachmentNamed:(nullable NSString *)attachmentName
               fromMessageWithSubject:(NSString *)subject
                               sender:(nullable NSString *)sender
                                 date:(nullable NSDate *)date
                              mailbox:(nullable NSString *)mailboxName
                              account:(nullable NSString *)accountName
                                index:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
