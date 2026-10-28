#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static int navigationCalls,propsCalls;
static void navReady(id self,SEL cmd){navigationCalls++;}
static void propsReceived(id self,SEL cmd,id value){NSCAssert([value isEqual:@"NEVER_EXPORT"],@"Props identifier altered");propsCalls++;}
static int webRequests,webFinishes,webFailures;
@interface WKWebView:NSObject
@property(nonatomic,strong) NSURL *URL;
@property(nonatomic,strong) id navigationDelegate;
- (id)loadRequest:(NSURLRequest *)request;
@end
@implementation WKWebView
- (id)loadRequest:(NSURLRequest *)request {self.URL=request.URL;webRequests++;return @"navigation-token";}
@end
@interface TestWebDelegate:NSObject
- (void)webView:(id)web didFinishNavigation:(id)navigation;
- (void)webView:(id)web didFailProvisionalNavigation:(id)navigation withError:(NSError *)error;
@end
@implementation TestWebDelegate
- (void)webView:(id)web didFinishNavigation:(id)navigation {NSCAssert([navigation isEqual:@"navigation-token"],@"Navigation altered");webFinishes++;}
- (void)webView:(id)web didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {NSCAssert(error.code==-1003,@"Error altered");webFailures++;}
@end
@interface NSURL (TrustFixture)
- (BOOL)isTrustedDomain;
@end
@implementation NSURL (TrustFixture)
- (BOOL)isTrustedDomain{return [self.host isEqual:@"already-trusted.test"];}
@end
@interface TestNavigationAction:NSObject
@property(nonatomic,strong) NSURLRequest *request;
@end
@implementation TestNavigationAction @end
static int policyCalls;
static int cookieLoads,nonceLoads;
@interface AMLicensedMusicBaseViewController:NSObject
@property(nonatomic) NSInteger originalMode;
@property(nonatomic,strong) NSURL *destination;
- (NSInteger)webViewAuth;
- (NSURL *)baseURL;
- (void)reloadWebView;
- (void)startLoadingWebViewWithCookies;
- (void)startLoadingWebViewWithNonce:(id)nonce;
- (void)webView:(id)web decidePolicyForNavigationAction:(TestNavigationAction *)action decisionHandler:(void(^)(NSInteger))handler;
@end
@implementation AMLicensedMusicBaseViewController
- (NSInteger)webViewAuth{return self.originalMode;}
- (NSURL *)baseURL{return self.destination;}
- (void)reloadWebView{NSInteger mode=[self webViewAuth];if(mode==1)[self startLoadingWebViewWithCookies];else if(mode==2)[self startLoadingWebViewWithNonce:nil];}
- (void)webView:(id)web decidePolicyForNavigationAction:(TestNavigationAction *)action decisionHandler:(void(^)(NSInteger))handler{policyCalls++;handler([action.request.URL isTrustedDomain]?1:0);}
- (void)startLoadingWebViewWithCookies{cookieLoads++;}
- (void)startLoadingWebViewWithNonce:(id)nonce{NSCAssert(!nonce,@"Unexpected nonce");nonceLoads++;}
@end
@interface AMLicensedMusicDeviceAuthorizationViewController:AMLicensedMusicBaseViewController @end
@implementation AMLicensedMusicDeviceAuthorizationViewController
- (NSInteger)webViewAuth{return self.originalMode;}
@end
@interface OtherDeviceAuthorization:AMLicensedMusicDeviceAuthorizationViewController @end
@implementation OtherDeviceAuthorization @end
int main(void){@autoreleasepool{
    Class notificationClass=objc_allocateClassPair(NSObject.class,"_TtC26AlcatrazReactNativeModules22NotificationModuleImpl",0);
    class_addMethod(notificationClass,NSSelectorFromString(@"navigationSystemReady"),(IMP)navReady,"v@:");
    class_addMethod(notificationClass,NSSelectorFromString(@"onPropsReceived:"),(IMP)propsReceived,"v@:@");objc_registerClassPair(notificationClass);
    NSString *fixtureDir=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"configurations"];
    [NSFileManager.defaultManager createDirectoryAtPath:fixtureDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *fixture=@{@"licensed_trusted_domains":@[@{@"regions":@[@"ALL"],@"value":@[@".amazon.com",@".amazon.ca",@".evil.test"]}]};
    NSData *fixtureData=[NSJSONSerialization dataWithJSONObject:fixture options:0 error:nil];
    NSCAssert([fixtureData writeToFile:[fixtureDir stringByAppendingPathComponent:@"configuration.json"] atomically:YES],@"Cannot write bundled policy fixture");
    TBInstallFrontendDiagnostics();
    AMLicensedMusicDeviceAuthorizationViewController *auth=[AMLicensedMusicDeviceAuthorizationViewController new];
    auth.destination=[NSURL URLWithString:@"https://www.amazon.com/gp/dmusic/device/manage/device_auth?token=NEVER_EXPORT"];
    [auth reloadWebView];NSCAssert(cookieLoads==1&&nonceLoads==0,@"Stalled device auth did not reach cookie-loading flow");
    auth.originalMode=2;[auth reloadWebView];NSCAssert(cookieLoads==1&&nonceLoads==1,@"Valid nonce mode was changed");
    auth.originalMode=1;[auth reloadWebView];NSCAssert(cookieLoads==2,@"Valid cookie mode changed");
    auth.originalMode=0;
    for(NSString *url in @[@"https://www.amazon.com.evil.test/gp/dmusic/device/manage/device_auth",@"http://www.amazon.com/gp/dmusic/device/manage/device_auth",@"https://www.amazon.com/wrong-path"]){auth.destination=[NSURL URLWithString:url];NSCAssert([auth webViewAuth]==0,@"Unsupported destination modified");}
    auth.destination=nil;NSCAssert([auth webViewAuth]==0,@"Missing destination modified");
    OtherDeviceAuthorization *other=[OtherDeviceAuthorization new];other.destination=[NSURL URLWithString:@"https://www.amazon.com/gp/dmusic/device/manage/device_auth"];NSCAssert([other webViewAuth]==0,@"Other subclass modified");
    AMLicensedMusicBaseViewController *base=[AMLicensedMusicBaseViewController new];base.destination=other.destination;NSCAssert([base webViewAuth]==0,@"Base controller modified");
    WKWebView *authWeb=[WKWebView new];authWeb.navigationDelegate=auth;
    TestNavigationAction *action=[TestNavigationAction new];
    NSArray *allowed=@[@"https://music.amazon.com/NA/BMWV/device_auth?token=NEVER_EXPORT",@"https://www.amazon.ca/ap/signin",@"https://www.amazon.com/done",@"https://already-trusted.test/"];
    NSArray *denied=@[@"http://music.amazon.com/",@"https://music.amazon.com.evil.test/",@"https://evilamazon.com/",@"https://user:NEVER_EXPORT@music.amazon.com/",@"https://music.amazon.com:444/",@"https://www.evil.test/"];
    for(NSString *destination in [allowed arrayByAddingObjectsFromArray:denied]){
        action.request=[NSURLRequest requestWithURL:[NSURL URLWithString:destination]];
        __block int decisions=0;__block NSInteger policy=-1;
        [auth webView:authWeb decidePolicyForNavigationAction:action decisionHandler:^(NSInteger value){decisions++;policy=value;}];
        NSCAssert(decisions==1&&policy==([allowed containsObject:destination]?1:0),@"Wrong policy or repeated decision");
        if(![destination containsString:@"already-trusted"])NSCAssert(![action.request.URL isTrustedDomain],@"Scoped policy escaped into other calls");
    }
    authWeb.navigationDelegate=other;action.request=[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://music.amazon.com/"]];
    __block NSInteger otherPolicy=-1;[other webView:authWeb decidePolicyForNavigationAction:action decisionHandler:^(NSInteger value){otherPolicy=value;}];
    NSCAssert(otherPolicy==0&&policyCalls==allowed.count+denied.count+1,@"Other delegate changed or original policy skipped");
    id notification=[notificationClass new];((void(*)(id,SEL))objc_msgSend)(notification,NSSelectorFromString(@"navigationSystemReady"));
    ((void(*)(id,SEL,id))objc_msgSend)(notification,NSSelectorFromString(@"onPropsReceived:"),@"NEVER_EXPORT");
    WKWebView *web=[WKWebView new];TestWebDelegate *webDelegate=[TestWebDelegate new];web.navigationDelegate=webDelegate;
    id navigation=[web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://music.amazon.com/private?token=NEVER_EXPORT"]]];
    [webDelegate webView:web didFinishNavigation:navigation];
    [webDelegate webView:web didFailProvisionalNavigation:navigation withError:[NSError errorWithDomain:NSURLErrorDomain code:-1003 userInfo:@{NSLocalizedDescriptionKey:@"NEVER_EXPORT"}]];
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
    NSCAssert(webRequests==1&&webFinishes==1&&webFailures==1&&[text containsString:@"WebKit loadRequest host=music.amazon.com"]&&[text containsString:@"NSURLErrorDomain -1003"],@"WebKit capture/forwarding failed");
    NSCAssert(navigationCalls==1&&propsCalls==1&&[text containsString:@"navigationSystemReady entered"]&&[text containsString:@"Page props acknowledged"],@"Navigation handoff capture or forwarding failed");
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
