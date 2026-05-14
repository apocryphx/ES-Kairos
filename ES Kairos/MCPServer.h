//
//  MCPServer.h
//  Kairos
//
//  STDIO MCP server. Same queue architecture as ES UITest/MCPServer.h.
//  Tools: calendar_list, events_in_range, event_search, event_create,
//         event_update, event_delete, contact_search, ask_user.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPServer : NSObject

+ (instancetype)shared;
- (void)start;

@end

NS_ASSUME_NONNULL_END
