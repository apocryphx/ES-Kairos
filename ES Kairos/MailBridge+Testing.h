//
//  MailBridge+Testing.h
//  Kairos
//
//  Test-target-only header exposing the pure metadata helpers so XCTest can
//  validate sorting, formatting, and semantic-key resolution against
//  synthetic metadata dictionaries — no Apple Events, no Automation TCC.
//  Not imported by the app target.
//
//  A synthetic meta dictionary has the shape produced by
//  fetchMetaForMailbox:  { subjects: [NSString], senders: [NSString],
//  dates: [NSDate|NSNull], reads: [NSNumber], count: NSNumber }.
//

#import "MailBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface MailBridge (Testing)

+ (NSString *)formatDate:(NSDate *)date;

/// Pure — strips U+FFFC placeholders and NBSPs, collapses blank-line runs.
+ (NSString *)normalizeBody:(NSString *)body;

/// Pure — YES for move targets that behave like deletion (Trash/Junk and
/// their provider aliases); these require the native confirmation dialog.
+ (BOOL)isDeletionLikeMailboxName:(NSString *)name;

/// Pure — first address failing the minimal sanity check, or nil.
+ (nullable NSString *)firstInvalidAddress:(NSArray<NSString *> *)addresses;

/// Pure — message indices of `meta`, newest first (missing dates last).
- (NSArray<NSNumber *> *)indicesByDateDescending:(NSDictionary *)meta;

/// Pure — one list/search result row from `meta` at index `i`.
- (NSDictionary *)summaryFromMeta:(NSDictionary *)meta index:(NSUInteger)i;

/// Pure — semantic-key resolution: exact (case-insensitive, trimmed) subject
/// match preferred with substring fallback, optional sender substring and
/// date ±2 min narrowing. Returns matching indices, newest first.
- (NSArray<NSNumber *> *)resolveCandidatesInMeta:(NSDictionary *)meta
                                         subject:(NSString *)subject
                                          sender:(nullable NSString *)sender
                                            date:(nullable NSDate *)date;

@end

NS_ASSUME_NONNULL_END
