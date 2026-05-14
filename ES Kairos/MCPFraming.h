//
//  MCPFraming.h
//  Kairos
//
//  JSON-RPC envelope helpers. Verbatim from ES UITest/MCPFraming.h,
//  which was adapted from ES-Memory-Bridge/main.m.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *_Nullable MCPEncodeJSON(NSDictionary *obj);
NSString *_Nullable MCPJSONRPCResult(id _Nullable rpcId, NSDictionary *result);
NSString *_Nullable MCPJSONRPCError(id _Nullable rpcId, NSInteger code, NSString *message);

NS_ASSUME_NONNULL_END
