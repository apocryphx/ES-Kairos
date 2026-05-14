//
//  CNBridge.m
//  Kairos
//

#import "CNBridge.h"
#import <Contacts/Contacts.h>

static const NSInteger kMaxContactResults = 20;

@interface CNBridge ()
@property (strong) CNContactStore *store;
@property (strong) dispatch_queue_t queue;
@property (atomic)  BOOL authorized;
@end

@implementation CNBridge

+ (instancetype)shared {
    static CNBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CNBridge alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.elarity.kairos.cnbridge", DISPATCH_QUEUE_SERIAL);
    _store = [[CNContactStore alloc] init];
    return self;
}

+ (NSString *)stringForStatus:(CNAuthorizationStatus)s {
    switch (s) {
        case CNAuthorizationStatusNotDetermined: return @"notDetermined";
        case CNAuthorizationStatusRestricted:    return @"restricted";
        case CNAuthorizationStatusDenied:        return @"denied";
        case CNAuthorizationStatusAuthorized:    return @"authorized";
        default:                                  return @"unknown";
    }
}

- (void)requestAccessWithCompletion:(void (^)(BOOL, NSError *_Nullable))completion {
    CNAuthorizationStatus pre = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
    fprintf(stderr, "[Kairos] CNBridge pre-request status: %s\n",
            [CNBridge stringForStatus:pre].UTF8String);

    // Already settled — don't re-prompt, which can race other TCC dialogs.
    if (pre == CNAuthorizationStatusAuthorized) {
        self.authorized = YES;
        completion(YES, nil);
        return;
    }
    if (pre == CNAuthorizationStatusDenied || pre == CNAuthorizationStatusRestricted) {
        self.authorized = NO;
        completion(NO, nil);
        return;
    }

    [self.store requestAccessForEntityType:CNEntityTypeContacts
                         completionHandler:^(BOOL granted, NSError *error) {
        CNAuthorizationStatus post = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
        fprintf(stderr, "[Kairos] CNBridge post-request status: %s (callback granted=%s)\n",
                [CNBridge stringForStatus:post].UTF8String,
                granted ? "yes" : "no");
        // The macOS TCC race can report granted=NO even when the actual
        // status is authorized. Trust the status query, not the bool.
        BOOL effective = granted || post == CNAuthorizationStatusAuthorized;
        self.authorized = effective;
        completion(effective, error);
    }];
}

- (BOOL)isAuthorized {
    // Always re-read TCC — covers the case where the user grants access
    // in System Settings while the server is running.
    return [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]
        == CNAuthorizationStatusAuthorized;
}

- (NSArray<NSDictionary *> *)searchContactsMatchingName:(NSString *)name {
    if (!self.isAuthorized || !name.length) return @[];

    __block NSArray *result = @[];
    dispatch_sync(self.queue, ^{
        NSArray<id<CNKeyDescriptor>> *keys = @[
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ];

        CNContactFetchRequest *req =
            [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
        req.predicate = [CNContact predicateForContactsMatchingName:name];

        NSMutableArray *out = [NSMutableArray array];
        NSError *err = nil;
        [self.store enumerateContactsWithFetchRequest:req
                                               error:&err
                                          usingBlock:^(CNContact *c, BOOL *stop) {
            if (out.count >= kMaxContactResults) { *stop = YES; return; }
            [out addObject:[self formatContact:c]];
        }];
        if (err) fprintf(stderr, "[Kairos] CNBridge fetch error: %s\n",
                         err.localizedDescription.UTF8String);
        result = [out copy];
    });
    return result;
}

- (NSDictionary *)formatContact:(CNContact *)c {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    NSString *fullName = [[c.givenName stringByAppendingString:
                           (c.givenName.length && c.familyName.length) ? @" " : @""]
                          stringByAppendingString:c.familyName];
    d[@"name"] = fullName.length ? fullName : (c.organizationName ?: @"(unknown)");

    if (c.organizationName.length) d[@"organization"] = c.organizationName;

    NSMutableArray *phones = [NSMutableArray array];
    for (CNLabeledValue<CNPhoneNumber *> *lv in c.phoneNumbers) {
        [phones addObject:lv.value.stringValue];
    }
    if (phones.count) d[@"phones"] = [phones copy];

    NSMutableArray *emails = [NSMutableArray array];
    for (CNLabeledValue<NSString *> *lv in c.emailAddresses) {
        [emails addObject:lv.value];
    }
    if (emails.count) d[@"emails"] = [emails copy];

    return [d copy];
}

@end
