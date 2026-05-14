//
//  CNBridge.h
//  Kairos
//
//  Read-only Contacts wrapper. Follows the same singleton+queue pattern
//  as EKBridge. CNContact objects do not cross the queue boundary.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CNBridge : NSObject

+ (instancetype)shared;

/// Request Contacts access. Call once at app launch.
- (void)requestAccessWithCompletion:(void (^)(BOOL granted, NSError *_Nullable error))completion;

@property (readonly, atomic) BOOL isAuthorized;

/// Case-insensitive name search (given, family, or organization).
/// Returns: [ { name, phones[], emails[], organization } ]
- (NSArray<NSDictionary *> *)searchContactsMatchingName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
