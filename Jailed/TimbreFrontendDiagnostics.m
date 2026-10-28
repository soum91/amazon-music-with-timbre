#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#include <string.h>

// Bounded local report. Never records response bodies, headers, query strings,
// cookies, credentials, callback argument dumps or exception extraData.
static os_unfair_lock frontLock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray *events;
static NSMutableArray *policyEvents;
static NSMutableSet *hooks;
static NSUInteger loads,loadFailures,callbackErrors,jsonResponses;
static NSString *clean(id value,NSUInteger limit) {
    if(![value isKindOfClass:NSString.class])return @"";
    NSString *s=value;
    NSArray *patterns=@[@"(?i)https?://[^\\s<>]+",@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",@"(?i)(bearer\\s+|(?:token|password|authorization|cookie|secret|session|customerId|accountId)\\s*[:=]\\s*)[^\\s,;]+",@"[A-Za-z0-9_+/=-]{48,}"];
    for(NSString *pattern in patterns){NSRegularExpression *r=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];s=[r stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0,s.length) withTemplate:@"[redacted]"];}
    return s.length>limit?[[s substringToIndex:limit] stringByAppendingString:@"…"]:s;
}
static void note(NSString *text) {
    if(!text.length)return;
    NSString *entry=[NSString stringWithFormat:@"%@ %@",[NSISO8601DateFormatter.new stringFromDate:NSDate.date],text];
    os_unfair_lock_lock(&frontLock);
    if(!events)events=[NSMutableArray array];
    if(events.count>=40)[events removeObjectAtIndex:0];
    [events addObject:entry];
    NSArray *snapshot=[events copy];
    os_unfair_lock_unlock(&frontLock);
    // Exceptions survive a fatal termination; this list is intentionally small.
    [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:@"Timbre.frontend.previous.v1"];
}
static void policyNote(NSString *text){
    NSString *entry=[NSString stringWithFormat:@"%@ %@",[NSISO8601DateFormatter.new stringFromDate:NSDate.date],text];
    os_unfair_lock_lock(&frontLock);if(!policyEvents)policyEvents=[NSMutableArray array];if(policyEvents.count>=24)[policyEvents removeObjectAtIndex:0];[policyEvents addObject:entry];os_unfair_lock_unlock(&frontLock);
}
static NSString *stackText(id stack) {
    if(![stack isKindOfClass:NSArray.class])return @"(no JS stack)";
    NSMutableArray *out=[NSMutableArray array];
    for(id frame in stack){
        if(![frame isKindOfClass:NSDictionary.class])continue;
        id line=frame[@"lineNumber"],column=frame[@"column"];
        NSString *file=[frame[@"file"] isKindOfClass:NSString.class]?[frame[@"file"] lastPathComponent]:@"?";
        [out addObject:[NSString stringWithFormat:@"%@ (%@:%@:%@)",clean(frame[@"methodName"],120),clean(file,80),[line isKindOfClass:NSNumber.class]?line:@"?",[column isKindOfClass:NSNumber.class]?column:@"?"]];
        if(out.count==12)break;
    }
    return [out componentsJoinedByString:@"\n"];
}
static void exception(NSString *kind,id message,id stack) {
    note([NSString stringWithFormat:@"%@\n%@\n%@",kind,clean(message,700),stackText(stack)]);
}
// Validate exact argument ABI before replacing a method. In particular, never
// interpret reportException:'s C++ ExceptionData reference as an ObjC object.
static BOOL signature(Method m,const char *types) {
    if(!m)return NO;
    unsigned n=method_getNumberOfArguments(m);if(n!=strlen(types)+2)return NO;
    for(unsigned i=2;i<n;i++){char *t=method_copyArgumentType(m,i);BOOL ok=t&&t[0]==types[i-2];free(t);if(!ok)return NO;}
    char *ret=method_copyReturnType(m);BOOL ok=ret&&ret[0]=='v';free(ret);return ok;
}
static void mark(NSString *name){os_unfair_lock_lock(&frontLock);if(!hooks)hooks=[NSMutableSet set];[hooks addObject:name];os_unfair_lock_unlock(&frontLock);}

static BOOL matches(Method method,const char *args,char result) {
    if(!method||method_getNumberOfArguments(method)!=strlen(args)+2)return NO;
    char *r=method_copyReturnType(method);BOOL ok=r&&r[0]==result;free(r);if(!ok)return NO;
    for(unsigned i=0;i<strlen(args);i++){char *t=method_copyArgumentType(method,i+2);ok=t&&t[0]==args[i];free(t);if(!ok)return NO;}return YES;
}
static BOOL installed(NSString *key){os_unfair_lock_lock(&frontLock);BOOL done=[hooks containsObject:key];os_unfair_lock_unlock(&frontLock);return done;}
static NSString *urlStatus(id value) {
    if(![value isKindOfClass:NSURL.class])return @"bundle URL is nil or not an NSURL";
    NSURL *url=value;
    if(url.isFileURL){NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];return [NSString stringWithFormat:@"local %@ exists=%@ bytes=%@",clean(url.lastPathComponent,100),a?@"yes":@"no",a[NSFileSize]?:@0];}
    return [NSString stringWithFormat:@"remote scheme=%@ host=%@ (path/query omitted)",clean(url.scheme,20),clean(url.host,120)];
}
static void startupSnapshot(id object,NSString *event) {
    NSMutableArray *states=[NSMutableArray array];
    // Read only actual Objective-C object ivars, never Swift struct/actor memory.
    for(NSString *name in @[@"reactHostView",@"reactNativeViewManager",@"setupActor",@"_reactHostView",@"_reactHost",@"_rootViewFactory"]){
        Ivar iv=class_getInstanceVariable([object class],name.UTF8String);const char *type=iv?ivar_getTypeEncoding(iv):NULL;
        if(type&&type[0]=='@'){id value=object_getIvar(object,iv);[states addObject:[NSString stringWithFormat:@"%@=%@",name,value?NSStringFromClass([value class]):@"nil"]];}
    }
    note([NSString stringWithFormat:@"Startup %@ [%@] %@",event,NSStringFromClass([object class]),[states componentsJoinedByString:@", "]]);
}
// WebKit callbacks have a separate process/network stack from URLSession.
static NSString *webHost(id web){
    if(![web respondsToSelector:NSSelectorFromString(@"URL")])return @"?";
    id url=((id(*)(id,SEL))objc_msgSend)(web,NSSelectorFromString(@"URL"));
    return [url isKindOfClass:NSURL.class]?[url host]?:@"(no host)":@"(no URL)";
}
// Exception #160 is the base controller's rejected-navigation branch.
// Restore the bundled Amazon host policy only during this controller's original
// synchronous navigation decision. TLS and all original auth/result handlers run.
static __thread const void *tbAuthNavigationURL;
static NSArray *bundledAmazonDomains(void){
    static NSArray *domains;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSString *path=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"configurations/configuration.json"];
        NSData *data=[NSData dataWithContentsOfFile:path];
        id config=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSMutableArray *found=[NSMutableArray array];
        NSArray *approved=@[@".amazon.com",@".amazon.co.uk",@".amazon.fr",@".amazon.de",@".amazon.it",@".amazon.es",@".amazon.co.jp",@".amazon.in",@".amazon.ca",@".amazon.com.au",@".amazon.com.mx",@".amazon.com.br"];
        id rows=[config isKindOfClass:NSDictionary.class]?config[@"licensed_trusted_domains"]:nil;
        for(id row in [rows isKindOfClass:NSArray.class]?rows:@[]){
            if(![row isKindOfClass:NSDictionary.class]||![row[@"regions"] isKindOfClass:NSArray.class]||![row[@"regions"] containsObject:@"ALL"])continue;
            id values=row[@"value"];for(id value in [values isKindOfClass:NSArray.class]?values:@[])if([approved containsObject:value])[found addObject:value];
        }
        domains=[found copy];
    });return domains;
}
static BOOL bundledAmazonURL(NSURL *url){
    if(![url isKindOfClass:NSURL.class]||![url.scheme.lowercaseString isEqual:@"https"]||url.user.length||url.password.length||(url.port&&url.port.integerValue!=443))return NO;
    NSString *host=url.host.lowercaseString;if(!host.length)return NO;
    for(NSString *domain in bundledAmazonDomains())if([host hasSuffix:domain])return YES;
    return NO;
}
static void installAuthDomainCompatibility(void){
    SEL selector=NSSelectorFromString(@"isTrustedDomain");Method method=class_getInstanceMethod(NSURL.class,selector);
    NSString *key=@"DeviceAuthorization.bundledDomainCompatibility";
    if(installed(key)||(!matches(method,"",'B')&&!matches(method,"",'c')))return;
    IMP original=method_getImplementation(method);
    IMP replacement=imp_implementationWithBlock(^BOOL(NSURL *url){
        BOOL trusted=((BOOL(*)(id,SEL))original)(url,selector);
        if(tbAuthNavigationURL&&[url isEqual:(__bridge NSURL *)tbAuthNavigationURL])policyNote([NSString stringWithFormat:@"Trust host=%@ scheme=%@ original=%d bundledMatch=%d",url.host?:@"nil",url.scheme?:@"nil",trusted,bundledAmazonURL(url)]);
        if(trusted)return trusted;
        NSURL *navigationURL=(__bridge NSURL *)tbAuthNavigationURL;
        if(navigationURL&&[url isEqual:navigationURL]&&bundledAmazonURL(url)){
            note([NSString stringWithFormat:@"Device authorization: restored bundled HTTPS host policy for %@",url.host.lowercaseString]);return YES;
        }return trusted;
    });
    class_replaceMethod(NSURL.class,selector,replacement,method_getTypeEncoding(method));mark(key);
}
static void watchAuthNavigationPolicy(Class cls){
    if(cls!=NSClassFromString(@"AMLicensedMusicDeviceAuthorizationViewController"))return;
    SEL selector=NSSelectorFromString(@"webView:decidePolicyForNavigationAction:decisionHandler:");
    Method method=class_getInstanceMethod(cls,selector);NSString *key=@"DeviceAuthorization.originalNavigationPolicy";
    if(installed(key)||!matches(method,"@@@",'v'))return;
    IMP original=method_getImplementation(method);
    IMP replacement=imp_implementationWithBlock(^(id object,id web,id action,id handler){
        id request=[action respondsToSelector:NSSelectorFromString(@"request")]?((id(*)(id,SEL))objc_msgSend)(action,NSSelectorFromString(@"request")):nil;
        NSURL *url=[request isKindOfClass:NSURLRequest.class]?[request URL]:nil;
        policyNote([NSString stringWithFormat:@"Navigation owner=%@ host=%@ scheme=%@",NSStringFromClass([object class]),url.host?:@"nil",url.scheme?:@"nil"]);
        void (^originalHandler)(NSInteger)=handler;
        void (^recordingHandler)(NSInteger)=^(NSInteger decision){policyNote([NSString stringWithFormat:@"Decision host=%@ policy=%ld",url.host?:@"nil",(long)decision]);originalHandler(decision);};
        const void *previous=tbAuthNavigationURL;
        tbAuthNavigationURL=[object class]==cls?(__bridge const void *)url:NULL;
        @try{((void(*)(id,SEL,id,id,id))original)(object,selector,web,action,recordingHandler);}
        @finally{tbAuthNavigationURL=previous;}
    });
    if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));mark(key);
}
static void watchWebDelegate(id delegate){
    if(!delegate)return;
    @synchronized(NSProcessInfo.class){
        Class cls=[delegate class];
        watchAuthNavigationPolicy(cls);
        for(NSString *name in @[@"webView:didStartProvisionalNavigation:",@"webView:didCommitNavigation:",@"webView:didFinishNavigation:",@"webView:didFailProvisionalNavigation:withError:",@"webView:didFailNavigation:withError:"]){
            SEL sel=NSSelectorFromString(name);NSString *key=[NSString stringWithFormat:@"WebDelegate.%@.%@",NSStringFromClass(cls),name];Method m=class_getInstanceMethod(cls,sel);BOOL failure=[name containsString:@"withError"];
            if(installed(key)||!matches(m,failure?"@@@":"@@",'v'))continue;
            IMP original=method_getImplementation(m),replacement;
            if(failure)replacement=imp_implementationWithBlock(^(id object,id web,id navigation,NSError *error){note([NSString stringWithFormat:@"WebKit %@ owner=%@ host=%@ error=%@ %ld",name,NSStringFromClass([object class]),webHost(web),[error isKindOfClass:NSError.class]?error.domain:@"?",[error isKindOfClass:NSError.class]?(long)error.code:0L]);((void(*)(id,SEL,id,id,id))original)(object,sel,web,navigation,error);});
            else replacement=imp_implementationWithBlock(^(id object,id web,id navigation){note([NSString stringWithFormat:@"WebKit %@ owner=%@ host=%@",name,NSStringFromClass([object class]),webHost(web)]);((void(*)(id,SEL,id,id))original)(object,sel,web,navigation);});
            if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m)))class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);
        }
    }
}
// The device-authorization subclass in 26.37.1 returns mode 0. The base
// reload method handles only 1 (Amazon cookie refresh) and 2 (nonce request),
// so mode 0 hides the web view and starts the spinner without loading anything.
// Use Amazon's existing authenticated cookie flow for this exact controller.
// Server authorization and its original completion/error callbacks remain intact.
static void installDeviceAuthorizationLoadingFix(void){
    Class cls=NSClassFromString(@"AMLicensedMusicDeviceAuthorizationViewController");
    SEL selector=NSSelectorFromString(@"webViewAuth");Method method=class_getInstanceMethod(cls,selector);
    NSString *key=@"DeviceAuthorization.cookieLoadingCompatibility";
    if(installed(key)||!matches(method,"",'q'))return;
    IMP original=method_getImplementation(method);
    IMP replacement=imp_implementationWithBlock(^NSInteger(id object){
        NSInteger mode=((NSInteger(*)(id,SEL))original)(object,selector);
        if(mode!=0||[object class]!=cls)return mode;
        SEL baseSelector=NSSelectorFromString(@"baseURL");
        if(![object respondsToSelector:baseSelector])return mode;
        id url=((id(*)(id,SEL))objc_msgSend)(object,baseSelector);
        if(![url isKindOfClass:NSURL.class]||![[url scheme].lowercaseString isEqual:@"https"])return mode;
        // Hosts and paths come from the app's bundled url_device_auth config.
        NSArray *hosts=@[@"www.amazon.es",@"www.amazon.it",@"www.amazon.com",@"www.amazon.co.uk",@"www.amazon.co.jp",@"www.amazon.de",@"www.amazon.fr"];
        BOOL standard=[hosts containsObject:[url host].lowercaseString]&&[[url path] isEqual:@"/gp/dmusic/device/manage/device_auth"];
        BOOL regional=[[url host].lowercaseString isEqual:@"music.amazon.com"]&&[@[@"/FE/BMWV/device_auth",@"/EU/BMWV/device_auth",@"/NA/BMWV/device_auth"] containsObject:[url path]];
        if(!standard&&!regional)return mode;
        note(@"Device authorization loading compatibility: mode 0 -> Amazon cookie refresh. Server authorization unchanged.");
        return (NSInteger)1;
    });
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));mark(key);
}
static void installNativePageHooks(void){
    installDeviceAuthorizationLoadingFix();
    installAuthDomainCompatibility();
    Class web=NSClassFromString(@"WKWebView");SEL sel=NSSelectorFromString(@"setNavigationDelegate:");Method m=class_getInstanceMethod(web,sel);NSString *key=@"WKWebView.setNavigationDelegate:";
    if(!installed(key)&&matches(m,"@",'v')){IMP original=method_getImplementation(m);IMP replacement=imp_implementationWithBlock(^(id object,id delegate){watchWebDelegate(delegate);((void(*)(id,SEL,id))original)(object,sel,delegate);});class_replaceMethod(web,sel,replacement,method_getTypeEncoding(m));mark(key);}
    sel=NSSelectorFromString(@"loadRequest:");m=class_getInstanceMethod(web,sel);key=@"WKWebView.loadRequest:";
    if(!installed(key)&&matches(m,"@",'@')){IMP original=method_getImplementation(m);IMP replacement=imp_implementationWithBlock(^id(id object,NSURLRequest *request){note([NSString stringWithFormat:@"WebKit loadRequest host=%@",[request isKindOfClass:NSURLRequest.class]?request.URL.host?:@"(no host)":@"(no request)"]);return ((id(*)(id,SEL,id))original)(object,sel,request);});class_replaceMethod(web,sel,replacement,method_getTypeEncoding(m));mark(key);}
    Class owner=NSClassFromString(@"AMLicensedMusicBaseViewController");
    for(NSString *name in @[@"webViewTimeOut",@"reloadWebView",@"startLoadingWebViewWithCookies"]){sel=NSSelectorFromString(name);m=class_getInstanceMethod(owner,sel);key=[@"LicensedMusic." stringByAppendingString:name];if(installed(key)||!matches(m,"",'v'))continue;IMP original=method_getImplementation(m);IMP replacement=imp_implementationWithBlock(^(id object){note([NSString stringWithFormat:@"Native page %@ owner=%@",name,NSStringFromClass([object class])]);((void(*)(id,SEL))original)(object,sel);});class_replaceMethod(owner,sel,replacement,method_getTypeEncoding(m));mark(key);}
    sel=NSSelectorFromString(@"startLoadingWebViewWithNonce:");m=class_getInstanceMethod(owner,sel);key=@"LicensedMusic.startLoadingWebViewWithNonce:";
    if(!installed(key)&&matches(m,"@",'v')){IMP original=method_getImplementation(m);IMP replacement=imp_implementationWithBlock(^(id object,id nonce){note([NSString stringWithFormat:@"Native page nonce callback owner=%@ value=%@ (contents omitted)",NSStringFromClass([object class]),nonce?@"present":@"nil"]);((void(*)(id,SEL,id))original)(object,sel,nonce);});class_replaceMethod(owner,sel,replacement,method_getTypeEncoding(m));mark(key);}
}

static void installStartupHooks(void) {
    NSArray *void0=@[@[@"_TtC26AlcatrazReactNativeModules22NotificationModuleImpl",@"navigationSystemReady"],@[@"RCTHost",@"start"],@[@"RCTInstance",@"_start"],@[@"RCTAppDelegate",@"initializeReactNativeSetup"],@[@"_TtC23AlcatrazReactNativeCore25ReactNativeViewController",@"viewDidLoad"]];
    for(NSArray *spec in void0){Class cls=NSClassFromString(spec[0]);SEL sel=NSSelectorFromString(spec[1]);NSString *key=[spec componentsJoinedByString:@"."];Method m=class_getInstanceMethod(cls,sel);if(installed(key)||!matches(m,"",'v'))continue;IMP original=method_getImplementation(m);
        IMP replacement=imp_implementationWithBlock(^(id object){startupSnapshot(object,[key stringByAppendingString:@" entered"]);((void(*)(id,SEL))original)(object,sel);startupSnapshot(object,[key stringByAppendingString:@" returned"]);});
        class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);
    }
    {
        Class cls=NSClassFromString(@"_TtC26AlcatrazReactNativeModules22NotificationModuleImpl");SEL sel=NSSelectorFromString(@"onPropsReceived:");NSString *key=@"NotificationModuleImpl.onPropsReceived:";Method m=class_getInstanceMethod(cls,sel);
        if(!installed(key)&&matches(m,"@",'v')){IMP original=method_getImplementation(m);IMP replacement=imp_implementationWithBlock(^(id object,id propID){note(@"Page props acknowledged by JavaScript (identifier omitted)");((void(*)(id,SEL,id))original)(object,sel,propID);note(@"Page-props acknowledgement forwarded to native delegate");});class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);}
    }
    for(NSString *methodName in @[@"_loadJSBundle:",@"_loadScriptFromSource:",@"handleBundleLoadingError:"]){Class cls=NSClassFromString(@"RCTInstance");SEL sel=NSSelectorFromString(methodName);NSString *key=[@"RCTInstance." stringByAppendingString:methodName];Method m=class_getInstanceMethod(cls,sel);if(installed(key)||!matches(m,"@",'v'))continue;IMP original=method_getImplementation(m);
        IMP replacement=imp_implementationWithBlock(^(id object,id arg){
            if([methodName isEqual:@"handleBundleLoadingError:"]&&[arg isKindOfClass:NSError.class]){NSError *e=arg;exception(key,[NSString stringWithFormat:@"%@ %ld %@",e.domain,(long)e.code,e.localizedDescription],nil);}
            else if([methodName isEqual:@"_loadJSBundle:"])note([NSString stringWithFormat:@"%@ %@",key,urlStatus(arg)]);
            else note([key stringByAppendingString:@" reached (source bytes not recorded)"]);
            ((void(*)(id,SEL,id))original)(object,sel,arg);
        });class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);
    }
    for(NSString *className in @[@"_TtC23AlcatrazReactNativeCore30AlcatrazReactNativeAppDelegate",@"RCTRootViewFactory"]){Class cls=NSClassFromString(className);SEL sel=NSSelectorFromString(@"bundleURL");NSString *key=[className stringByAppendingString:@".bundleURL"];Method m=class_getInstanceMethod(cls,sel);if(installed(key)||!matches(m,"",'@'))continue;IMP original=method_getImplementation(m);
        IMP replacement=imp_implementationWithBlock(^id(id object){id result=((id(*)(id,SEL))original)(object,sel);note([NSString stringWithFormat:@"%@ %@",key,urlStatus(result)]);return result;});class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);
    }
    Class factory=NSClassFromString(@"RCTRootViewFactory");SEL create=NSSelectorFromString(@"viewWithModuleName:initialProperties:launchOptions:");NSString *factoryKey=@"RCTRootViewFactory.viewWithModuleName:initialProperties:launchOptions:";Method cm=class_getInstanceMethod(factory,create);
    if(!installed(factoryKey)&&matches(cm,"@@@",'@')){IMP original=method_getImplementation(cm);IMP replacement=imp_implementationWithBlock(^id(id object,id name,id props,id options){note(@"Root-view creation entered (props omitted)");id result=((id(*)(id,SEL,id,id,id))original)(object,create,name,props,options);note([NSString stringWithFormat:@"Root-view creation returned %@",result?NSStringFromClass([result class]):@"nil"]);return result;});class_replaceMethod(factory,create,replacement,method_getTypeEncoding(cm));mark(factoryKey);}
    // Bridgeless errors are already marshalled into ObjC values at this boundary.
    // Preserve the delegate's BOOL result and exact NSUInteger/BOOL ABI.
    Class host=NSClassFromString(@"RCTHost");SEL errorSel=NSSelectorFromString(@"instance:didReceiveJSErrorStack:message:originalMessage:name:componentStack:exceptionId:isFatal:extraData:");NSString *errorKey=@"RCTHost.bridgelessJSError";Method em=class_getInstanceMethod(host,errorSel);
    if(!installed(errorKey)&&matches(em,"@@@@@@QB@",'B')){IMP original=method_getImplementation(em);
        IMP replacement=imp_implementationWithBlock(^BOOL(id object,id instance,id stack,id message,id originalMessage,id name,id componentStack,NSUInteger eid,BOOL fatal,id extra){
            exception(fatal?@"Bridgeless fatal JS error":@"Bridgeless JS error",message,stack);
            return ((BOOL(*)(id,SEL,id,id,id,id,id,id,NSUInteger,BOOL,id))original)(object,errorSel,instance,stack,message,originalMessage,name,componentStack,eid,fatal,extra);
        });class_replaceMethod(host,errorSel,replacement,method_getTypeEncoding(em));mark(errorKey);
    }
}
static void installHooks(void) {
    @synchronized(NSProcessInfo.class){
        installStartupHooks();
        installNativePageHooks();
        Class cls=NSClassFromString(@"RCTExceptionsManager");
        for(NSString *name in @[@"reportFatalException:stack:exceptionId:",@"reportSoftException:stack:exceptionId:",@"reportFatal:stack:exceptionId:extraDataAsJSON:",@"reportSoft:stack:exceptionId:extraDataAsJSON:"]){
            NSString *key=[@"RCTExceptionsManager." stringByAppendingString:name];
            os_unfair_lock_lock(&frontLock);BOOL done=[hooks containsObject:key];os_unfair_lock_unlock(&frontLock);if(done)continue;
            SEL sel=NSSelectorFromString(name);Method m=class_getInstanceMethod(cls,sel);BOOL extra=[name containsString:@"extraDataAsJSON"];
            if(!signature(m,extra?"@@d@":"@@d"))continue;
            IMP original=method_getImplementation(m),replacement;
            if(extra)replacement=imp_implementationWithBlock(^(id object,NSString *message,NSArray *stack,double eid,NSString *extraData){exception(name,message,stack);((void(*)(id,SEL,id,id,double,id))original)(object,sel,message,stack,eid,extraData);});
            else replacement=imp_implementationWithBlock(^(id object,NSString *message,NSArray *stack,double eid){exception(name,message,stack);((void(*)(id,SEL,id,id,double))original)(object,sel,message,stack,eid);});
            class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));mark(key);
        }
        for(NSString *className in @[@"RCTCxxBridge",@"RCTBatchedBridge"]){
            Class bridge=NSClassFromString(className);
            NSString *key=[className stringByAppendingString:@".handleError:"];SEL sel=NSSelectorFromString(@"handleError:");Method m=class_getInstanceMethod(bridge,sel);
            os_unfair_lock_lock(&frontLock);BOOL done=[hooks containsObject:key];os_unfair_lock_unlock(&frontLock);
            if(!done&&signature(m,"@")){
                IMP original=method_getImplementation(m);
                IMP replacement=imp_implementationWithBlock(^(id object,NSError *error){if([error isKindOfClass:NSError.class])exception(key,error.localizedDescription,error.userInfo[@"RCTJSStackTraceKey"]);((void(*)(id,SEL,id))original)(object,sel,error);});
                class_replaceMethod(bridge,sel,replacement,method_getTypeEncoding(m));mark(key);
            }
            key=[className stringByAppendingString:@".enqueueCallback:args:"];sel=NSSelectorFromString(@"enqueueCallback:args:");m=class_getInstanceMethod(bridge,sel);
            os_unfair_lock_lock(&frontLock);done=[hooks containsObject:key];os_unfair_lock_unlock(&frontLock);
            if(!done&&signature(m,"@@")){
                IMP original=method_getImplementation(m);
                IMP replacement=imp_implementationWithBlock(^(id object,NSNumber *cb,NSArray *args){
                    if([args isKindOfClass:NSArray.class]&&args.count&&[args[0] isKindOfClass:NSDictionary.class]){
                        NSDictionary *e=args[0];
                        if([e[@"message"] isKindOfClass:NSString.class]&&(e[@"code"]||e[@"nativeStackIOS"])){
                            os_unfair_lock_lock(&frontLock);callbackErrors++;os_unfair_lock_unlock(&frontLock);
                            exception(@"Native callback error (may be a promise rejection)", [NSString stringWithFormat:@"code=%@ %@",clean(e[@"code"],100),clean(e[@"message"],700)],nil);
                        }
                    }
                    ((void(*)(id,SEL,id,id))original)(object,sel,cb,args);
                });
                class_replaceMethod(bridge,sel,replacement,method_getTypeEncoding(m));mark(key);
            }
        }
    }
}
void TBInstallFrontendDiagnostics(void) {
    NSNotificationCenter *n=NSNotificationCenter.defaultCenter;
    [n addObserverForName:@"RCTInstanceDidLoadBundle" object:nil queue:nil usingBlock:^(NSNotification *notification){os_unfair_lock_lock(&frontLock);loads++;os_unfair_lock_unlock(&frontLock);note(@"Bridgeless RCTInstanceDidLoadBundle received");}];
    [n addObserverForName:@"RCTJavaScriptDidLoadNotification" object:nil queue:nil usingBlock:^(NSNotification *notification){os_unfair_lock_lock(&frontLock);loads++;os_unfair_lock_unlock(&frontLock);note(@"React Native JavaScript loaded");}];
    [n addObserverForName:@"RCTJavaScriptDidFailToLoadNotification" object:nil queue:nil usingBlock:^(NSNotification *notification){os_unfair_lock_lock(&frontLock);loadFailures++;os_unfair_lock_unlock(&frontLock);NSError *e=notification.userInfo[@"error"];exception(@"React Native bundle failed",[e isKindOfClass:NSError.class]?e.localizedDescription:@"No error description",[e isKindOfClass:NSError.class]?e.userInfo[@"RCTJSStackTraceKey"]:nil);}];
    installHooks();
    dispatch_async(dispatch_get_main_queue(),^{installHooks();[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){installHooks();}];});
}
static NSString *codeValue(id value) {
    if([value isKindOfClass:NSNumber.class])return [value stringValue];
    if(![value isKindOfClass:NSString.class]||[value length]>96)return nil;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"];
    return [value length]&&[value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound?value:nil;
}
void TBInspectAPIResponse(NSData *data,NSURLResponse *response) {
    if(!data.length||data.length>1048576)return;
    // Never retain or export payloads. Extract explicit error codes only.
    NSString *mime=response.MIMEType.lowercaseString;
    if(mime&&![mime containsString:@"json"])return;
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![json isKindOfClass:NSDictionary.class])return;
    os_unfair_lock_lock(&frontLock);jsonResponses++;os_unfair_lock_unlock(&frontLock);
    NSMutableArray *codes=[NSMutableArray array];NSDictionary *d=json;
    for(NSString *key in @[@"errorCode",@"errorType",@"__type"]){NSString *v=codeValue(d[key]);if(v)[codes addObject:[NSString stringWithFormat:@"%@=%@",key,v]];}
    id error=d[@"error"];NSMutableArray *errors=[NSMutableArray array];
    if([error isKindOfClass:NSDictionary.class])[errors addObject:error];
    else {NSString *v=codeValue(error);if(v)[codes addObject:[@"error=" stringByAppendingString:v]];}
    if([d[@"errors"] isKindOfClass:NSArray.class])for(id e in d[@"errors"]){if([e isKindOfClass:NSDictionary.class]&&errors.count<8)[errors addObject:e];}
    for(NSDictionary *e in errors){
        for(NSString *key in @[@"code",@"errorCode",@"errorType",@"type"]){NSString *v=codeValue(e[key]);if(v)[codes addObject:[NSString stringWithFormat:@"%@=%@",key,v]];}
        if([e[@"extensions"] isKindOfClass:NSDictionary.class]){NSString *v=codeValue(e[@"extensions"][@"code"]);if(v)[codes addObject:[@"extensions.code=" stringByAppendingString:v]];}
    }
    BOOL errorPresent=errors.count||([d[@"errors"] isKindOfClass:NSArray.class]&&[d[@"errors"] count])||(error&&error!=NSNull.null)||codes.count;
    if(errorPresent&&!(error==NSNull.null&&!codes.count&&!errors.count))note([NSString stringWithFormat:@"API error envelope · %@ · %@ · error entries=%lu (messages omitted)",response.URL.host?:@"?",codes.count?[codes componentsJoinedByString:@", "]:@"no explicit code",(unsigned long)errors.count]);
}
NSString *TBFrontendDiagnosticsText(void) {
    os_unfair_lock_lock(&frontLock);NSArray *current=[events copy],*policies=[policyEvents copy],*installed=[[hooks allObjects] sortedArrayUsingSelector:@selector(compare:)];NSUInteger l=loads,f=loadFailures,c=callbackErrors,j=jsonResponses;os_unfair_lock_unlock(&frontLock);
    NSMutableArray *out=[NSMutableArray arrayWithObjects:@"Frontend diagnostics 19",[NSString stringWithFormat:@"JS load notifications (legacy + bridgeless): %lu · load failures: %lu · native callback errors: %lu · JSON dictionaries inspected: %lu",(unsigned long)l,(unsigned long)f,(unsigned long)c,(unsigned long)j],@"Installed hooks:",[installed componentsJoinedByString:@"\n"]?:@"",@"This launch:",nil];
    [out addObject:@"Authorization policy decisions (separate bounded buffer):"];[out addObjectsFromArray:policies?:@[@"No navigation policy callback observed."]];
    [out addObjectsFromArray:current?:@[@"No frontend events captured yet."]];
    if(!current.count){NSArray *previous=[NSUserDefaults.standardUserDefaults arrayForKey:@"Timbre.frontend.previous.v1"];if(previous.count){[out addObject:@"Saved events from an earlier launch (check timestamps):"];[out addObjectsFromArray:previous];}}
    [out addObject:@"Coverage: native navigation-ready/props acknowledgements, verified bridgeless RCTHost error callback, RCTInstance startup/load stages, bundle resolution, root-view creation, legacy exception methods and callback errors. C++ internals and errors handled entirely in JavaScript remain outside coverage. JSON inspection covers buffered URLSession completion handlers and implemented data delegate callbacks, up to 1 MiB per response."];
    return [out componentsJoinedByString:@"\n"];
}

void TBRecordNativePageEvent(NSString *event){note(event);}
