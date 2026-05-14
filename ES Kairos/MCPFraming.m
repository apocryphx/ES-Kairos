//
//  MCPFraming.m
//  Kairos
//
//  Verbatim from ES UITest/MCPFraming.m.
//

#import "MCPFraming.h"

NSString *MCPEncodeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString *MCPJSONRPCResult(id rpcId, NSDictionary *result) {
    return MCPEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id":      rpcId ?: [NSNull null],
        @"result":  result ?: @{}
    });
}

NSString *MCPJSONRPCError(id rpcId, NSInteger code, NSString *message) {
    return MCPEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id":      rpcId ?: [NSNull null],
        @"error":   @{ @"code": @(code), @"message": message ?: @"Error" }
    });
}
