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
int main(void){@autoreleasepool{
    TBInstallFrontendDiagnostics();
    RCTExceptionsManager *manager=[RCTExceptionsManager new];
    [manager reportSoftException:@"TypeError test person@example.com https://example.com/?token=secret" stack:@[@{@"methodName":@"renderHome",@"file":@"/app/main.jsbundle",@"lineNumber":@12,@"column":@34}] exceptionId:7.5];
    RCTCxxBridge *bridge=[RCTCxxBridge new];[bridge enqueueCallback:@42 args:@[@{@"code":@"E_NATIVE",@"message":@"native operation failed"}]];
    NSURLResponse *response=[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://music.amazon.com/private?token=NEVER_EXPORT"] MIMEType:@"application/json" expectedContentLength:0 textEncodingName:@"utf-8"];
    NSData *body=[NSJSONSerialization dataWithJSONObject:@{@"errors":@[@{@"message":@"NEVER_EXPORT",@"extensions":@{@"code":@"UNAUTHORIZED"}}],@"token":@"NEVER_EXPORT"} options:0 error:nil];TBInspectAPIResponse(body,response);
    NSString *text=TBFrontendDiagnosticsText();
    NSCAssert(fatalCalls==1&&callbackCalls==1,@"Original callbacks not preserved");
    NSCAssert([text containsString:@"renderHome (main.jsbundle:12:34)"]&&[text containsString:@"TypeError test"],@"Exception/stack missing");
    NSCAssert([text containsString:@"extensions.code=UNAUTHORIZED"]&&[text containsString:@"E_NATIVE"],@"Codes missing");
    NSCAssert(![text containsString:@"NEVER_EXPORT"]&&![text containsString:@"person@example.com"]&&![text containsString:@"https://example.com"],@"Sensitive fields leaked");
    NSUInteger before=[text componentsSeparatedByString:@"API error envelope"].count;
    TBInspectAPIResponse([@"{\"errors\":[],\"error\":null,\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding],response);
    NSCAssert([TBFrontendDiagnosticsText() componentsSeparatedByString:@"API error envelope"].count==before,@"Empty errors reported as failure");
    puts("Frontend diagnostics: original callbacks, ABI, JS stack, API codes and redaction passed");
}return 0;}
