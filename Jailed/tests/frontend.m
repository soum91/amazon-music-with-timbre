#import <Foundation/Foundation.h>
extern void TBInstallFrontendDiagnostics(void);
extern void TBInspectAPIResponse(NSData *,NSURLResponse *);
extern NSString *TBFrontendDiagnosticsText(void);
static int fatalCalls,callbackCalls;
@interface RCTExceptionsManager:NSObject
- (void)reportSoftException:(NSString *)message stack:(NSArray *)stack exceptionId:(double)eid;
@end
@implementation RCTExceptionsManager
- (void)reportSoftException:(NSString *)message stack:(NSArray *)stack exceptionId:(double)eid {NSCAssert(eid==7.5,@"ABI changed");fatalCalls++;}
@end
@interface RCTCxxBridge:NSObject
- (void)enqueueCallback:(NSNumber *)cb args:(NSArray *)args;
@end
@implementation RCTCxxBridge
- (void)enqueueCallback:(NSNumber *)cb args:(NSArray *)args {NSCAssert([cb isEqual:@42]&&args.count==1,@"Callback mutated");callbackCalls++;}
@end
static int hostStarts,instanceLoads;
@interface RCTHost:NSObject
- (void)start;
- (BOOL)instance:(id)i didReceiveJSErrorStack:(NSArray *)stack message:(NSString *)message originalMessage:(NSString *)orig name:(NSString *)name componentStack:(NSString *)component exceptionId:(NSUInteger)eid isFatal:(BOOL)fatal extraData:(id)extra;
@end
@implementation RCTHost
- (void)start {hostStarts++;}
- (BOOL)instance:(id)i didReceiveJSErrorStack:(NSArray *)stack message:(NSString *)message originalMessage:(NSString *)orig name:(NSString *)name componentStack:(NSString *)component exceptionId:(NSUInteger)eid isFatal:(BOOL)fatal extraData:(id)extra {NSCAssert(eid==123456789&&fatal&&[extra isEqual:@"NEVER_EXPORT"],@"Bridgeless error ABI changed");return YES;}
@end
@interface RCTInstance:NSObject
- (void)_loadJSBundle:(NSURL *)url;
@end
@implementation RCTInstance
- (void)_loadJSBundle:(NSURL *)url {NSCAssert([url.lastPathComponent isEqual:@"main.jsbundle"],@"Bundle URL changed");instanceLoads++;}
@end
int main(void){@autoreleasepool{
    TBInstallFrontendDiagnostics();
    RCTHost *host=[RCTHost new];[host start];
    BOOL handled=[host instance:nil didReceiveJSErrorStack:@[@{@"methodName":@"renderBridgelessHome",@"file":@"main.jsbundle",@"lineNumber":@81,@"column":@9}] message:@"Bridgeless test exception" originalMessage:@"NEVER_EXPORT" name:@"TypeError" componentStack:@"NEVER_EXPORT" exceptionId:123456789 isFatal:YES extraData:@"NEVER_EXPORT"];
    NSCAssert(handled&&hostStarts==1,@"Host forwarding/return changed");
    [[RCTInstance new] _loadJSBundle:[NSURL fileURLWithPath:@"/nonexistent/main.jsbundle"]];
    [NSNotificationCenter.defaultCenter postNotificationName:@"RCTInstanceDidLoadBundle" object:nil];
    RCTExceptionsManager *manager=[RCTExceptionsManager new];
    [manager reportSoftException:@"TypeError test person@example.com https://example.com/?token=secret" stack:@[@{@"methodName":@"renderHome",@"file":@"/app/main.jsbundle",@"lineNumber":@12,@"column":@34}] exceptionId:7.5];
    RCTCxxBridge *bridge=[RCTCxxBridge new];[bridge enqueueCallback:@42 args:@[@{@"code":@"E_NATIVE",@"message":@"native operation failed"}]];
    NSURLResponse *response=[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://music.amazon.com/private?token=NEVER_EXPORT"] MIMEType:@"application/json" expectedContentLength:0 textEncodingName:@"utf-8"];
    NSData *body=[NSJSONSerialization dataWithJSONObject:@{@"errors":@[@{@"message":@"NEVER_EXPORT",@"extensions":@{@"code":@"UNAUTHORIZED"}}],@"token":@"NEVER_EXPORT"} options:0 error:nil];TBInspectAPIResponse(body,response);
    NSString *text=TBFrontendDiagnosticsText();
    NSCAssert(instanceLoads==1&&[text containsString:@"renderBridgelessHome"]&&[text containsString:@"exists=no"]&&[text containsString:@"Bridgeless RCTInstanceDidLoadBundle received"],@"Bridgeless lifecycle/error capture missing");
    NSCAssert(fatalCalls==1&&callbackCalls==1,@"Original callbacks not preserved");
    NSCAssert([text containsString:@"renderHome (main.jsbundle:12:34)"]&&[text containsString:@"TypeError test"],@"Exception/stack missing");
    NSCAssert([text containsString:@"extensions.code=UNAUTHORIZED"]&&[text containsString:@"E_NATIVE"],@"Codes missing");
    NSCAssert(![text containsString:@"NEVER_EXPORT"]&&![text containsString:@"person@example.com"]&&![text containsString:@"https://example.com"],@"Sensitive fields leaked");
    NSUInteger before=[text componentsSeparatedByString:@"API error envelope"].count;
    TBInspectAPIResponse([@"{\"errors\":[],\"error\":null,\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding],response);
    NSCAssert([TBFrontendDiagnosticsText() componentsSeparatedByString:@"API error envelope"].count==before,@"Empty errors reported as failure");
    puts("Frontend diagnostics: bridgeless host/errors/bundle load, legacy callbacks, ABI, JS stack, API codes and redaction passed");
}return 0;}
