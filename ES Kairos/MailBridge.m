//
//  MailBridge.m
//  Kairos
//

#import "MailBridge.h"
#import "Mail.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <ScriptingBridge/ScriptingBridge.h>

static NSString *const kMailBundleID   = @"com.apple.mail";
static const NSInteger kDefaultLimit   = 20;
static const NSInteger kMaxLimit       = 50;
static const NSUInteger kBodyMaxChars  = 50000;
static const NSTimeInterval kDateSlack = 120;   // ±2 min, same as event identity
static const long kEventTimeoutTicks   = 10 * 60;  // 10 s in AE ticks (1/60 s)
static const NSTimeInterval kLaunchWait = 10;

static NSDictionary *ErrDict(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return @{ @"error": msg };
}

/// Apple Event lists batch-fetched via SBElementArray can contain NSNull
/// for messages whose property is missing. Normalize to a typed value.
static NSString *StrAt(NSArray *a, NSUInteger i) {
    id v = i < a.count ? a[i] : nil;
    return [v isKindOfClass:[NSString class]] ? v : @"";
}
static NSDate *DateAt(NSArray *a, NSUInteger i) {
    id v = i < a.count ? a[i] : nil;
    return [v isKindOfClass:[NSDate class]] ? v : nil;
}
static BOOL BoolAt(NSArray *a, NSUInteger i) {
    id v = i < a.count ? a[i] : nil;
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}

@interface MailBridge () <SBApplicationDelegate>
@property (strong) dispatch_queue_t queue;
@property (strong, nullable) MailApplication *mail;
@property (copy, nullable) NSString *lastEventError;
@end

@implementation MailBridge

+ (instancetype)shared {
    static MailBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MailBridge alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.elarity.kairos.mailbridge", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - SBApplicationDelegate

// Scripting Bridge reports send failures here; returning nil makes the
// failed call yield nil/empty instead of raising.
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
    self.lastEventError = error.localizedDescription;
    fprintf(stderr, "[Kairos] MailBridge event failed: %s\n",
            error.localizedDescription.UTF8String ?: "(unknown)");
    return nil;
}

#pragma mark - Authorization (Automation TCC)

static OSStatus MailAutomationPermission(BOOL askUser) {
    NSAppleEventDescriptor *target =
        [NSAppleEventDescriptor descriptorWithBundleIdentifier:kMailBundleID];
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard,
                                                 typeWildCard, askUser);
}

- (BOOL)isAuthorized {
    // Non-prompting. procNotFound (Mail not running) reads as NO — the
    // real request happens lazily in ensureReadyReturningError:.
    return MailAutomationPermission(NO) == noErr;
}

/// Launch Mail in the background (no activation) and wait until Scripting
/// Bridge sees it running. Sending any Apple Event would launch it too, but
/// doing it explicitly keeps the permission flow deterministic.
- (BOOL)launchMailAndWait {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSURL *url = [ws URLForApplicationWithBundleIdentifier:kMailBundleID];
    if (!url) return NO;

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = NO;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL launched = NO;
    [ws openApplicationAtURL:url configuration:cfg
           completionHandler:^(NSRunningApplication *app, NSError *error) {
        launched = (app != nil);
        if (error) fprintf(stderr, "[Kairos] MailBridge launch error: %s\n",
                           error.localizedDescription.UTF8String);
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(kLaunchWait * NSEC_PER_SEC)));
    if (!launched) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kLaunchWait];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (self.mail.running) return YES;
        usleep(250000);
    }
    return self.mail.running;
}

/// Must be called on self.queue. Creates the SBApplication lazily, launches
/// Mail if needed, and settles the Automation permission (this is where the
/// one-time system prompt appears). Returns nil error string on success.
- (nullable NSString *)ensureReadyReturningError {
    if (!self.mail) {
        MailApplication *app =
            [SBApplication applicationWithBundleIdentifier:kMailBundleID];
        if (!app) return @"Apple Mail is not installed.";
        app.delegate = self;
        app.timeout = kEventTimeoutTicks;
        self.mail = app;
    }

    OSStatus st = MailAutomationPermission(YES);
    if (st == procNotFound) {
        if (![self launchMailAndWait])
            return @"Could not launch Mail.app to query it.";
        st = MailAutomationPermission(YES);
    }
    if (st == noErr) return nil;

    return @"Mail automation permission is denied. Grant it in System Settings "
           @"→ Privacy & Security → Automation → allow ES Kairos to control "
           @"Mail, then retry. To re-trigger the prompt: "
           @"tccutil reset AppleEvents com.elarity.ES-Kairos";
}

#pragma mark - Mailbox resolution

/// Must be called on self.queue, after ensureReadyReturningError.
/// nil name → unified inbox. Special names map to the top-level unified
/// mailboxes; anything else is matched case-insensitively against mailbox
/// names, within one account when given, across all accounts otherwise.
- (nullable MailMailbox *)resolveMailboxNamed:(nullable NSString *)name
                                      account:(nullable NSString *)accountName
                                        error:(NSString *_Nullable *_Nonnull)err {
    *err = nil;
    NSString *wanted = [name stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;

    if (!accountName.length) {
        if (!wanted.length || [wanted isEqualToString:@"inbox"]) return self.mail.inbox;
        if ([wanted isEqualToString:@"sent"])   return self.mail.sentMailbox;
        if ([wanted isEqualToString:@"drafts"]) return self.mail.draftsMailbox;
        if ([wanted isEqualToString:@"trash"])  return self.mail.trashMailbox;
        if ([wanted isEqualToString:@"junk"])   return self.mail.junkMailbox;
        if ([wanted isEqualToString:@"outbox"]) return self.mail.outbox;
    }

    NSArray *accountNames = @[];
    @try {
        accountNames = [[self.mail accounts]
                        arrayByApplyingSelector:@selector(name)] ?: @[];
    } @catch (NSException *e) {
        *err = [NSString stringWithFormat:@"Could not list Mail accounts: %@", e.reason];
        return nil;
    }

    NSMutableArray<NSNumber *> *accountIdx = [NSMutableArray array];
    if (accountName.length) {
        for (NSUInteger i = 0; i < accountNames.count; i++) {
            if ([StrAt(accountNames, i) caseInsensitiveCompare:accountName] == NSOrderedSame)
                [accountIdx addObject:@(i)];
        }
        if (!accountIdx.count) {
            *err = [NSString stringWithFormat:
                    @"No Mail account named \"%@\". Accounts: %@",
                    accountName, [accountNames componentsJoinedByString:@", "]];
            return nil;
        }
        if (!wanted.length) {
            // Account given, no mailbox: that account's inbox-equivalent is
            // ambiguous across providers, so require an explicit name.
            wanted = @"inbox";
        }
    } else {
        for (NSUInteger i = 0; i < accountNames.count; i++) [accountIdx addObject:@(i)];
    }

    for (NSNumber *idx in accountIdx) {
        MailAccount *acct = [[self.mail accounts] objectAtIndex:idx.unsignedIntegerValue];
        NSArray *boxNames = @[];
        @try {
            boxNames = [[acct mailboxes] arrayByApplyingSelector:@selector(name)] ?: @[];
        } @catch (NSException *e) { continue; }
        for (NSUInteger i = 0; i < boxNames.count; i++) {
            if ([StrAt(boxNames, i).lowercaseString isEqualToString:wanted])
                return [[acct mailboxes] objectAtIndex:i];
        }
    }

    *err = [NSString stringWithFormat:
            @"No mailbox named \"%@\"%@. Use mailbox_list to see available mailboxes.",
            name, accountName.length ?
                [NSString stringWithFormat:@" in account \"%@\"", accountName] : @""];
    return nil;
}

#pragma mark - Metadata fetch

/// Must be called on self.queue. Batch-fetches parallel property arrays for
/// every message in the mailbox — one Apple Event per property, regardless of
/// message count (dragon N.9: never touch properties per-message). Mail
/// serves these from its envelope database without loading message bodies.
/// Returns nil on failure. The arrays are index-aligned with the mailbox's
/// `messages` element array at fetch time; `count` is the safe common length.
- (nullable NSDictionary *)fetchMetaForMailbox:(MailMailbox *)box {
    self.lastEventError = nil;
    NSArray *subjects, *senders, *dates, *reads;
    @try {
        SBElementArray<MailMessage *> *msgs = [box messages];
        subjects = [msgs arrayByApplyingSelector:@selector(subject)];
        senders  = [msgs arrayByApplyingSelector:@selector(sender)];
        dates    = [msgs arrayByApplyingSelector:@selector(dateReceived)];
        reads    = [msgs valueForKey:@"readStatus"];
    } @catch (NSException *e) {
        fprintf(stderr, "[Kairos] MailBridge meta fetch raised: %s\n",
                e.reason.UTF8String ?: "(unknown)");
        return nil;
    }
    if (!subjects || !senders || !dates || !reads) return nil;

    NSUInteger n = MIN(MIN(subjects.count, senders.count),
                       MIN(dates.count, reads.count));
    return @{ @"subjects": subjects, @"senders": senders,
              @"dates": dates, @"reads": reads, @"count": @(n) };
}

/// Message indices of `meta`, newest first (nil dates sort last).
- (NSArray<NSNumber *> *)indicesByDateDescending:(NSDictionary *)meta {
    NSArray *dates = meta[@"dates"];
    NSUInteger n = [meta[@"count"] unsignedIntegerValue];
    NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [idx addObject:@(i)];
    [idx sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSDate *da = DateAt(dates, a.unsignedIntegerValue) ?: NSDate.distantPast;
        NSDate *db = DateAt(dates, b.unsignedIntegerValue) ?: NSDate.distantPast;
        return [db compare:da];
    }];
    return idx;
}

- (NSDictionary *)summaryFromMeta:(NSDictionary *)meta index:(NSUInteger)i {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *subject = StrAt(meta[@"subjects"], i);
    d[@"subject"] = subject.length ? subject : @"(no subject)";
    NSString *from = StrAt(meta[@"senders"], i);
    if (from.length) d[@"from"] = from;
    NSDate *date = DateAt(meta[@"dates"], i);
    if (date) d[@"date"] = [MailBridge formatDate:date];
    d[@"read"] = @(BoolAt(meta[@"reads"], i));
    return [d copy];
}

#pragma mark - Public: mailbox_list

- (NSDictionary *)listMailboxes {
    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        NSMutableArray *accountsOut = [NSMutableArray array];
        NSArray *accountNames = @[];
        @try {
            accountNames = [[self.mail accounts]
                            arrayByApplyingSelector:@selector(name)] ?: @[];
        } @catch (NSException *e) {
            result = ErrDict(@"Could not list Mail accounts: %@", e.reason);
            return;
        }

        for (NSUInteger i = 0; i < accountNames.count; i++) {
            MailAccount *acct = [[self.mail accounts] objectAtIndex:i];
            NSArray *names = @[], *unread = @[];
            @try {
                names  = [[acct mailboxes] arrayByApplyingSelector:@selector(name)] ?: @[];
                unread = [[acct mailboxes] valueForKey:@"unreadCount"] ?: @[];
            } @catch (NSException *e) { /* account offline — list it empty */ }

            NSMutableArray *boxesOut = [NSMutableArray array];
            NSUInteger n = MIN(names.count, unread.count);
            for (NSUInteger j = 0; j < n; j++) {
                NSMutableDictionary *b = [NSMutableDictionary dictionary];
                b[@"name"] = StrAt(names, j);
                NSInteger u = [unread[j] respondsToSelector:@selector(integerValue)]
                              ? [unread[j] integerValue] : 0;
                if (u > 0) b[@"unread"] = @(u);
                [boxesOut addObject:b];
            }
            [accountsOut addObject:@{ @"name": StrAt(accountNames, i),
                                      @"mailboxes": boxesOut }];
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"accounts"] = accountsOut;
        // Mail's mailbox-level unreadCount tracks the badge, which only
        // counts the Primary category when mailbox categorization is on —
        // it reported 0 while three Promotions-category messages sat
        // unread (dragon N.12). Per-message readStatus is ground truth;
        // one batched fetch over the unified inbox (dragon N.9).
        @try {
            NSArray *reads = [[self.mail.inbox messages]
                              valueForKey:@"readStatus"] ?: @[];
            NSUInteger unread = 0;
            for (id v in reads) {
                if ([v respondsToSelector:@selector(boolValue)] && ![v boolValue])
                    unread++;
            }
            out[@"inbox_unread"] = @(unread);
        } @catch (NSException *e) { /* cosmetic — omit */ }
        result = [out copy];
    });
    return result;
}

#pragma mark - Public: mail_list

- (NSDictionary *)listMessagesInMailbox:(nullable NSString *)mailboxName
                                account:(nullable NSString *)accountName
                             unreadOnly:(BOOL)unreadOnly
                                  limit:(NSInteger)limit {
    NSInteger cap = limit > 0 ? MIN(limit, kMaxLimit) : kDefaultLimit;
    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        MailMailbox *box = [self resolveMailboxNamed:mailboxName
                                             account:accountName error:&err];
        if (!box) { result = ErrDict(@"%@", err); return; }

        NSDictionary *meta = [self fetchMetaForMailbox:box];
        if (!meta) {
            result = ErrDict(@"Could not read mailbox \"%@\"%@%@.",
                             mailboxName ?: @"inbox",
                             self.lastEventError ? @": " : @"",
                             self.lastEventError ?: @"");
            return;
        }

        NSMutableArray *messages = [NSMutableArray array];
        NSUInteger total = [meta[@"count"] unsignedIntegerValue];
        NSUInteger matched = 0;
        for (NSNumber *idx in [self indicesByDateDescending:meta]) {
            NSUInteger i = idx.unsignedIntegerValue;
            if (unreadOnly && BoolAt(meta[@"reads"], i)) continue;
            matched++;
            if ((NSInteger)messages.count < cap)
                [messages addObject:[self summaryFromMeta:meta index:i]];
        }

        result = @{ @"mailbox": mailboxName.length ? mailboxName : @"inbox",
                    @"total": @(unreadOnly ? matched : total),
                    @"returned": @(messages.count),
                    @"messages": messages };
    });
    return result;
}

#pragma mark - Public: mail_search

- (NSDictionary *)searchMessagesMatching:(NSString *)query
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                    from:(nullable NSDate *)from
                                      to:(nullable NSDate *)to
                                   limit:(NSInteger)limit {
    if (!query.length) return ErrDict(@"query must not be empty.");
    NSInteger cap = limit > 0 ? MIN(limit, kMaxLimit) : kDefaultLimit;
    NSString *needle = query.lowercaseString;

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        MailMailbox *box = [self resolveMailboxNamed:mailboxName
                                             account:accountName error:&err];
        if (!box) { result = ErrDict(@"%@", err); return; }

        NSDictionary *meta = [self fetchMetaForMailbox:box];
        if (!meta) {
            result = ErrDict(@"Could not read mailbox \"%@\"%@%@.",
                             mailboxName ?: @"inbox",
                             self.lastEventError ? @": " : @"",
                             self.lastEventError ?: @"");
            return;
        }

        NSMutableArray *messages = [NSMutableArray array];
        NSUInteger matched = 0;
        for (NSNumber *idx in [self indicesByDateDescending:meta]) {
            NSUInteger i = idx.unsignedIntegerValue;
            NSDate *date = DateAt(meta[@"dates"], i);
            if (from && (!date || [date compare:from] == NSOrderedAscending)) continue;
            if (to   && (!date || [date compare:to]   == NSOrderedDescending)) continue;
            BOOL hit = [StrAt(meta[@"subjects"], i).lowercaseString containsString:needle]
                    || [StrAt(meta[@"senders"],  i).lowercaseString containsString:needle];
            if (!hit) continue;
            matched++;
            if ((NSInteger)messages.count < cap)
                [messages addObject:[self summaryFromMeta:meta index:i]];
        }

        result = @{ @"mailbox": mailboxName.length ? mailboxName : @"inbox",
                    @"matched": @(matched),
                    @"returned": @(messages.count),
                    @"messages": messages };
    });
    return result;
}

#pragma mark - Public: mail_read

/// Must be called on self.queue. Shared front-end for mail_read and every
/// phase-2 write: resolves the mailbox, fetches metadata, resolves exactly
/// one message by semantic key (ambiguity → candidates dict, `index` picks),
/// and verifies the proxy is not stale. On any failure returns nil with
/// *problem set to the error/ambiguous dictionary to hand back as-is.
- (nullable MailMessage *)targetMessageWithSubject:(NSString *)subject
                                            sender:(nullable NSString *)sender
                                              date:(nullable NSDate *)date
                                           mailbox:(nullable NSString *)mailboxName
                                           account:(nullable NSString *)accountName
                                             index:(NSInteger)index
                                           summary:(NSDictionary *_Nullable *_Nullable)outSummary
                                           problem:(NSDictionary *_Nullable *_Nonnull)problem {
    *problem = nil;
    NSString *err = [self ensureReadyReturningError];
    if (err) { *problem = ErrDict(@"%@", err); return nil; }

    MailMailbox *box = [self resolveMailboxNamed:mailboxName
                                         account:accountName error:&err];
    if (!box) { *problem = ErrDict(@"%@", err); return nil; }

    NSDictionary *meta = [self fetchMetaForMailbox:box];
    if (!meta) {
        *problem = ErrDict(@"Could not read mailbox \"%@\"%@%@.",
                           mailboxName ?: @"inbox",
                           self.lastEventError ? @": " : @"",
                           self.lastEventError ?: @"");
        return nil;
    }

    NSArray<NSNumber *> *candidates =
        [self resolveCandidatesInMeta:meta subject:subject
                               sender:sender date:date];

    if (!candidates.count) {
        *problem = ErrDict(@"No message matching \"%@\" in \"%@\". "
                           @"Try mail_search first.",
                           subject, mailboxName ?: @"inbox");
        return nil;
    }
    if (candidates.count > 1 && index < 1) {
        NSMutableArray *list = [NSMutableArray array];
        [candidates enumerateObjectsUsingBlock:^(NSNumber *idx, NSUInteger k, BOOL *stop) {
            NSMutableDictionary *d = [[self summaryFromMeta:meta
                                      index:idx.unsignedIntegerValue] mutableCopy];
            d[@"index"] = @(k + 1);
            [list addObject:d];
        }];
        *problem = @{ @"ambiguous": @YES,
                      @"message": @"Multiple messages match. Call again with "
                                  @"the index of the intended one.",
                      @"candidates": list };
        return nil;
    }
    NSUInteger pick = (candidates.count > 1) ? (NSUInteger)(index - 1) : 0;
    if (pick >= candidates.count) {
        *problem = ErrDict(@"index %ld is out of range (1–%lu).",
                           (long)index, (unsigned long)candidates.count);
        return nil;
    }

    NSUInteger msgIdx = candidates[pick].unsignedIntegerValue;
    MailMessage *msg = [[box messages] objectAtIndex:msgIdx];

    // The mailbox may have changed since the metadata fetch; verify the
    // proxy still points at the message we resolved.
    NSString *wanted = [subject stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       .lowercaseString;
    NSString *liveSubject = @"";
    @try { liveSubject = msg.subject ?: @""; } @catch (NSException *e) {}
    if (![liveSubject.lowercaseString containsString:wanted] &&
        ![wanted containsString:liveSubject.lowercaseString]) {
        *problem = ErrDict(@"Mailbox changed while resolving; please retry.");
        return nil;
    }

    if (outSummary) *outSummary = [self summaryFromMeta:meta index:msgIdx];
    return msg;
}

- (NSDictionary *)readMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index {
    if (!subject.length) return ErrDict(@"subject must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSDictionary *problem = nil, *summary = nil;
        MailMessage *msg = [self targetMessageWithSubject:subject sender:sender
                                                     date:date mailbox:mailboxName
                                                  account:accountName index:index
                                                  summary:&summary problem:&problem];
        if (!msg) { result = problem; return; }

        result = [self formatFullMessage:msg
                             withSummary:summary
                             mailboxName:mailboxName.length ? mailboxName : @"inbox"];
    });
    return result;
}

/// Semantic-key resolution, mirroring event identity: exact
/// (case-insensitive, trimmed) subject match preferred, substring fallback;
/// optional sender substring and date ±2 min narrow the field. Pure —
/// operates on a meta dictionary only, no Apple Events.
- (NSArray<NSNumber *> *)resolveCandidatesInMeta:(NSDictionary *)meta
                                         subject:(NSString *)subject
                                          sender:(nullable NSString *)sender
                                            date:(nullable NSDate *)date {
    NSString *wanted = [subject stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       .lowercaseString;
    NSArray<NSNumber *> *exact = [self candidatesInMeta:meta wanted:wanted
                                                 sender:sender.lowercaseString
                                                   date:date exact:YES];
    if (exact.count) return exact;
    return [self candidatesInMeta:meta wanted:wanted
                           sender:sender.lowercaseString date:date exact:NO];
}

- (NSArray<NSNumber *> *)candidatesInMeta:(NSDictionary *)meta
                                   wanted:(NSString *)wanted
                                   sender:(nullable NSString *)senderNeedle
                                     date:(nullable NSDate *)date
                                    exact:(BOOL)exact {
    NSMutableArray<NSNumber *> *hits = [NSMutableArray array];
    for (NSNumber *idx in [self indicesByDateDescending:meta]) {
        NSUInteger i = idx.unsignedIntegerValue;
        NSString *subj = StrAt(meta[@"subjects"], i).lowercaseString;
        if (exact ? ![subj isEqualToString:wanted]
                  : ![subj containsString:wanted]) continue;
        if (senderNeedle.length &&
            ![StrAt(meta[@"senders"], i).lowercaseString
              containsString:senderNeedle]) continue;
        if (date) {
            NSDate *d = DateAt(meta[@"dates"], i);
            if (!d || fabs([d timeIntervalSinceDate:date]) > kDateSlack)
                continue;
        }
        [hits addObject:idx];
    }
    return hits;
}

/// Must be called on self.queue.
- (NSDictionary *)formatFullMessage:(MailMessage *)msg
                        withSummary:(NSDictionary *)summary
                        mailboxName:(NSString *)mailboxName {
    NSMutableDictionary *d = [summary mutableCopy];
    d[@"mailbox"] = mailboxName;

    @try {
        NSArray *to = [[msg toRecipients] arrayByApplyingSelector:@selector(address)];
        if (to.count) d[@"to"] = to;
        NSArray *cc = [[msg ccRecipients] arrayByApplyingSelector:@selector(address)];
        if (cc.count) d[@"cc"] = cc;
        NSString *replyTo = msg.replyTo;
        NSString *from = d[@"from"];
        if (replyTo.length && ![replyTo isEqualToString:from])
            d[@"reply_to"] = replyTo;
        NSDate *sent = msg.dateSent;
        if (sent) d[@"date_sent"] = [MailBridge formatDate:sent];
        NSArray *att = [[msg mailAttachments] arrayByApplyingSelector:@selector(name)];
        if (att.count) d[@"attachments"] = att;
    } @catch (NSException *e) {
        fprintf(stderr, "[Kairos] MailBridge header fetch raised: %s\n",
                e.reason.UTF8String ?: "(unknown)");
    }

    // `content` is declared as rich text, which has no string property in
    // the scripting model. Evaluating the reference with -get makes Mail
    // return the coerced text — at runtime this is an NSString (dragon N.9).
    NSString *body = nil;
    @try {
        id raw = [[msg content] get];
        if ([raw isKindOfClass:[NSString class]]) body = raw;
    } @catch (NSException *e) {}
    if (!body) {
        d[@"body"] = @"(body unavailable)";
        return [d copy];
    }
    body = [MailBridge normalizeBody:body];
    if (body.length > kBodyMaxChars) {
        NSRange safe = [body rangeOfComposedCharacterSequenceAtIndex:kBodyMaxChars];
        d[@"body"] = [body substringToIndex:safe.location];
        d[@"body_truncated"] = [NSString stringWithFormat:
            @"Body truncated at %lu of %lu characters.",
            (unsigned long)safe.location, (unsigned long)body.length];
    } else {
        d[@"body"] = body;
    }
    return [d copy];
}

/// HTML mail coerced to plain text arrives littered with U+FFFC object
/// replacement characters (inline-image placeholders) and non-breaking
/// spaces, often producing long runs of visually blank lines. Normalize so
/// the LLM doesn't pay tokens for layout artifacts.
+ (NSString *)normalizeBody:(NSString *)body {
    static NSRegularExpression *trailingWS = nil;
    static NSRegularExpression *blankRuns  = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trailingWS = [NSRegularExpression regularExpressionWithPattern:@"[ \\t]+\\n"
                                                               options:0 error:nil];
        blankRuns  = [NSRegularExpression regularExpressionWithPattern:@"\\n{3,}"
                                                               options:0 error:nil];
    });
    NSString *s = [body stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\u00A0" withString:@" "];
    s = [trailingWS stringByReplacingMatchesInString:s options:0
                                               range:NSMakeRange(0, s.length)
                                        withTemplate:@"\n"];
    s = [blankRuns stringByReplacingMatchesInString:s options:0
                                              range:NSMakeRange(0, s.length)
                                       withTemplate:@"\n\n"];
    return [s stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

#pragma mark - Write operations (phase 2)

/// Pure — deletion-like move targets require confirmation. Matches the
/// special names plus the provider-specific server folder names that
/// appear in mailbox_list output.
+ (BOOL)isDeletionLikeMailboxName:(NSString *)name {
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"trash", @"junk", @"deleted messages",
                                      @"deleted items", @"junk e-mail",
                                      @"spam", @"bulk mail"]];
    });
    NSString *k = [name stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    return [names containsObject:k];
}

/// Pure — returns the first address that fails a minimal sanity check
/// (one @ with non-empty local and domain parts, no whitespace), or nil
/// if all pass. Real validation is Mail's job; this catches echo mistakes.
+ (nullable NSString *)firstInvalidAddress:(NSArray<NSString *> *)addresses {
    for (id a in addresses) {
        if (![a isKindOfClass:[NSString class]]) return [a description];
        NSArray *parts = [a componentsSeparatedByString:@"@"];
        if (parts.count != 2 ||
            [parts[0] length] == 0 || [parts[1] length] == 0 ||
            [a rangeOfCharacterFromSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
            return a;
    }
    return nil;
}

- (NSDictionary *)markMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index
                                    read:(BOOL)read {
    if (!subject.length) return ErrDict(@"subject must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSDictionary *problem = nil, *summary = nil;
        MailMessage *msg = [self targetMessageWithSubject:subject sender:sender
                                                     date:date mailbox:mailboxName
                                                  account:accountName index:index
                                                  summary:&summary problem:&problem];
        if (!msg) { result = problem; return; }

        @try {
            msg.readStatus = read;
        } @catch (NSException *e) {
            result = ErrDict(@"Could not change read status: %@", e.reason);
            return;
        }
        BOOL now = read;
        @try { now = msg.readStatus; } @catch (NSException *e) {}
        result = @{ @"marked": summary[@"subject"] ?: subject, @"read": @(now) };
    });
    return result;
}

- (NSDictionary *)moveMessageWithSubject:(NSString *)subject
                                  sender:(nullable NSString *)sender
                                    date:(nullable NSDate *)date
                                 mailbox:(nullable NSString *)mailboxName
                                 account:(nullable NSString *)accountName
                                   index:(NSInteger)index
                               toMailbox:(NSString *)targetName
                               toAccount:(nullable NSString *)targetAccountName
                               confirmed:(BOOL)confirmed {
    if (!subject.length)    return ErrDict(@"subject must not be empty.");
    if (!targetName.length) return ErrDict(@"to_mailbox must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        MailMailbox *target = [self resolveMailboxNamed:targetName
                                                account:targetAccountName error:&err];
        if (!target) { result = ErrDict(@"%@", err); return; }

        NSDictionary *problem = nil, *summary = nil;
        MailMessage *msg = [self targetMessageWithSubject:subject sender:sender
                                                     date:date mailbox:mailboxName
                                                  account:accountName index:index
                                                  summary:&summary problem:&problem];
        if (!msg) { result = problem; return; }

        if ([MailBridge isDeletionLikeMailboxName:targetName] && !confirmed) {
            result = @{ @"needs_confirmation": @YES,
                        @"target": targetName,
                        @"message": summary ?: @{} };
            return;
        }

        self.lastEventError = nil;
        @try {
            [msg moveTo:target];
        } @catch (NSException *e) {
            result = ErrDict(@"Move failed: %@", e.reason);
            return;
        }
        if (self.lastEventError) {
            result = ErrDict(@"Move failed: %@", self.lastEventError);
            return;
        }
        result = @{ @"moved": summary[@"subject"] ?: subject, @"to": targetName };
    });
    return result;
}

/// Must be called on self.queue. Composition core shared by draft and
/// send — Apple's SBSendEmail idiom: instantiate the scripting class with
/// properties (content accepts plain text in the make-event's record),
/// add to outgoingMessages, then append typed recipients.
- (nullable MailOutgoingMessage *)composeTo:(NSArray<NSString *> *)to
                                         cc:(nullable NSArray<NSString *> *)cc
                                    subject:(NSString *)subject
                                       body:(NSString *)body
                                       from:(nullable NSString *)from
                                    problem:(NSDictionary *_Nullable *_Nonnull)problem {
    *problem = nil;
    NSArray *all = cc.count ? [to arrayByAddingObjectsFromArray:cc] : to;
    NSString *bad = [MailBridge firstInvalidAddress:all];
    if (bad) { *problem = ErrDict(@"Invalid email address: \"%@\"", bad); return nil; }

    self.lastEventError = nil;
    MailOutgoingMessage *out = nil;
    @try {
        out = [[[self.mail classForScriptingClass:@"outgoing message"] alloc]
               initWithProperties:@{ @"subject": subject ?: @"",
                                     @"content": body ?: @"",
                                     @"visible": @NO }];
        [[self.mail outgoingMessages] addObject:out];
        if (from.length) out.sender = from;

        for (NSString *addr in to) {
            MailToRecipient *r =
                [[[self.mail classForScriptingClass:@"to recipient"] alloc]
                 initWithProperties:@{ @"address": addr }];
            [[out toRecipients] addObject:r];
        }
        for (NSString *addr in cc ?: @[]) {
            MailCcRecipient *r =
                [[[self.mail classForScriptingClass:@"cc recipient"] alloc]
                 initWithProperties:@{ @"address": addr }];
            [[out ccRecipients] addObject:r];
        }
    } @catch (NSException *e) {
        *problem = ErrDict(@"Could not compose message: %@", e.reason);
        return nil;
    }
    if (self.lastEventError) {
        *problem = ErrDict(@"Could not compose message: %@", self.lastEventError);
        return nil;
    }
    return out;
}

- (NSDictionary *)draftMessageTo:(NSArray<NSString *> *)to
                              cc:(nullable NSArray<NSString *> *)cc
                         subject:(NSString *)subject
                            body:(NSString *)body
                            from:(nullable NSString *)from {
    if (!to.count)         return ErrDict(@"to must contain at least one address.");
    if (!subject.length)   return ErrDict(@"subject must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        NSDictionary *problem = nil;
        MailOutgoingMessage *out = [self composeTo:to cc:cc subject:subject
                                              body:body from:from problem:&problem];
        if (!out) { result = problem; return; }

        // AppleScript draft idiom: "close ... saving yes" files the unsent
        // message in Drafts.
        self.lastEventError = nil;
        @try {
            [out closeSaving:MailSaveOptionsYes savingIn:nil];
        } @catch (NSException *e) {
            result = ErrDict(@"Could not save draft: %@", e.reason);
            return;
        }
        if (self.lastEventError) {
            result = ErrDict(@"Could not save draft: %@", self.lastEventError);
            return;
        }
        result = @{ @"drafted": subject, @"to": to,
                    @"note": @"Saved to Drafts — review and send from Mail." };
    });
    return result;
}

- (NSDictionary *)sendMessageTo:(NSArray<NSString *> *)to
                             cc:(nullable NSArray<NSString *> *)cc
                        subject:(NSString *)subject
                           body:(NSString *)body
                           from:(nullable NSString *)from {
    if (!to.count)       return ErrDict(@"to must contain at least one address.");
    if (!subject.length) return ErrDict(@"subject must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSString *err = [self ensureReadyReturningError];
        if (err) { result = ErrDict(@"%@", err); return; }

        NSDictionary *problem = nil;
        MailOutgoingMessage *out = [self composeTo:to cc:cc subject:subject
                                              body:body from:from problem:&problem];
        if (!out) { result = problem; return; }

        self.lastEventError = nil;
        BOOL ok = NO;
        @try {
            ok = [out send];
        } @catch (NSException *e) {
            result = ErrDict(@"Send failed: %@", e.reason);
            return;
        }
        if (!ok || self.lastEventError) {
            result = ErrDict(@"Send failed%@%@.",
                             self.lastEventError ? @": " : @"",
                             self.lastEventError ?: @"");
            return;
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"sent"] = subject;
        d[@"to"] = to;
        if (cc.count) d[@"cc"] = cc;
        result = [d copy];
    });
    return result;
}

- (NSDictionary *)replyToMessageWithSubject:(NSString *)subject
                                     sender:(nullable NSString *)sender
                                       date:(nullable NSDate *)date
                                    mailbox:(nullable NSString *)mailboxName
                                    account:(nullable NSString *)accountName
                                      index:(NSInteger)index
                                       body:(NSString *)body
                                   replyAll:(BOOL)replyAll
                                  confirmed:(BOOL)confirmed {
    if (!subject.length) return ErrDict(@"subject must not be empty.");
    if (!body.length)    return ErrDict(@"body must not be empty.");

    __block NSDictionary *result;
    dispatch_sync(self.queue, ^{
        NSDictionary *problem = nil, *summary = nil;
        MailMessage *msg = [self targetMessageWithSubject:subject sender:sender
                                                     date:date mailbox:mailboxName
                                                  account:accountName index:index
                                                  summary:&summary problem:&problem];
        if (!msg) { result = problem; return; }

        self.lastEventError = nil;
        MailOutgoingMessage *reply = nil;
        @try {
            reply = [msg replyOpeningWindow:NO replyToAll:replyAll];
        } @catch (NSException *e) {}
        if (!reply || self.lastEventError) {
            result = ErrDict(@"Could not create reply%@%@.",
                             self.lastEventError ? @": " : @"",
                             self.lastEventError ?: @"");
            return;
        }

        // Recipients as Mail actually resolved them (to + cc combined).
        NSArray *recipients = @[];
        NSString *replySubject = @"";
        @try {
            recipients = [[reply recipients]
                          arrayByApplyingSelector:@selector(address)] ?: @[];
            replySubject = reply.subject ?: @"";
        } @catch (NSException *e) {}

        if (!confirmed) {
            // Preview phase: discard the throwaway reply unsent.
            @try { [reply closeSaving:MailSaveOptionsNo savingIn:nil]; }
            @catch (NSException *e) {}
            result = @{ @"needs_confirmation": @YES,
                        @"reply_subject": replySubject,
                        @"recipients": recipients,
                        @"message": summary ?: @{} };
            return;
        }

        // Mail may have pre-filled the body with the quoted original
        // (depends on the "quote original message" preference). Put our
        // text above it; otherwise the body stands alone.
        NSString *quote = nil;
        @try {
            id q = [[reply content] get];
            if ([q isKindOfClass:[NSString class]] && [q length]) quote = q;
        } @catch (NSException *e) {}
        NSString *full = quote
            ? [NSString stringWithFormat:@"%@\n\n%@", body, quote] : body;
        @try {
            // Setter is typed MailRichText*, but SB marshals a plain string
            // into the set-data event exactly as AppleScript's
            // "set content to" does (dragon N.11).
            reply.content = (MailRichText *)full;
        } @catch (NSException *e) {
            result = ErrDict(@"Could not set reply body: %@", e.reason);
            return;
        }

        self.lastEventError = nil;
        BOOL ok = NO;
        @try {
            ok = [reply send];
        } @catch (NSException *e) {}
        if (!ok || self.lastEventError) {
            result = ErrDict(@"Reply send failed%@%@.",
                             self.lastEventError ? @": " : @"",
                             self.lastEventError ?: @"");
            return;
        }
        result = @{ @"replied": summary[@"subject"] ?: subject,
                    @"to": recipients };
    });
    return result;
}

#pragma mark - Dates

+ (NSString *)formatDate:(NSDate *)date {
    // Same human format the event/reminder tools emit.
    static NSDateFormatter *timed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timed = [[NSDateFormatter alloc] init];
        timed.dateFormat = @"EEE MMM d, yyyy · h:mm a";
    });
    return [timed stringFromDate:date];
}

@end
