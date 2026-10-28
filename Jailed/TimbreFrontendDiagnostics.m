#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <string.h>

// Bounded local report. Never records response bodies, headers, query strings,
// cookies, credentials, callback argument dumps or exception extraData.
static os_unfair_lock frontLock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray *events;
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
static void installHooks(void) {
    @synchronized(NSProcessInfo.class){
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
    os_unfair_lock_lock(&frontLock);NSArray *current=[events copy],*installed=[[hooks allObjects] sortedArrayUsingSelector:@selector(compare:)];NSUInteger l=loads,f=loadFailures,c=callbackErrors,j=jsonResponses;os_unfair_lock_unlock(&frontLock);
    NSMutableArray *out=[NSMutableArray arrayWithObjects:@"Frontend diagnostics 13",[NSString stringWithFormat:@"JS loaded: %lu · load failures: %lu · native callback errors: %lu · JSON dictionaries inspected: %lu",(unsigned long)l,(unsigned long)f,(unsigned long)c,(unsigned long)j],@"Installed hooks:",[installed componentsJoinedByString:@"\n"]?:@"",@"This launch:",nil];
    [out addObjectsFromArray:current?:@[@"No frontend events captured yet."]];
    if(!current.count){NSArray *previous=[NSUserDefaults.standardUserDefaults arrayForKey:@"Timbre.frontend.previous.v1"];if(previous.count){[out addObject:@"Saved events from an earlier launch (check timestamps):"];[out addObjectsFromArray:previous];}}
    [out addObject:@"Coverage: legacy RN exception methods and bridge callback errors. C++ reportException: is intentionally untouched; errors handled entirely in JavaScript can remain invisible. JSON inspection covers buffered URLSession completion handlers and implemented data delegate callbacks, up to 1 MiB per response."];
    return [out componentsJoinedByString:@"\n"];
}
