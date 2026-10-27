#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
// Metadata only. No URLs beyond host, headers, bodies, cookies, tokens or account data.
static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *eventOrder;
static NSMutableDictionary<NSString *,NSNumber *> *eventCounts;
static NSMutableDictionary<NSString *,NSNumber *> *successHosts;
static NSUInteger sessions=0, successes=0;
static BOOL relevant(NSString *host) {
    NSString *h=host.lowercaseString;
    return [h containsString:@"amazon."]||[h hasSuffix:@"amazon.com"]||[h hasSuffix:@"amazonaws.com"]||[h hasSuffix:@"a2z.com"];
}
static void record(NSString *event) {
    os_unfair_lock_lock(&lock);
    if(!eventOrder){eventOrder=[NSMutableArray array];eventCounts=[NSMutableDictionary dictionary];}
    if(!eventCounts[event]){
        if(eventOrder.count>=32){[eventCounts removeObjectForKey:eventOrder.firstObject];[eventOrder removeObjectAtIndex:0];}
        [eventOrder addObject:event];
    }
    eventCounts[event]=@([eventCounts[event] unsignedIntegerValue]+1);
    os_unfair_lock_unlock(&lock);
}
static void completed(NSURLResponse *response,NSError *error) {
    NSString *host=response.URL.host;
    if(!host&&error){id u=error.userInfo[NSURLErrorFailingURLErrorKey];if([u isKindOfClass:NSURL.class])host=[u host];}
    if(!relevant(host))return;
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(!error&&status>=200&&status<400){
        os_unfair_lock_lock(&lock);successes++;
        if(!successHosts)successHosts=[NSMutableDictionary dictionary];
        NSString *key=[NSString stringWithFormat:@"%@ · HTTP %ld",host,(long)status];
        if(successHosts.count<32||successHosts[key])successHosts[key]=@([successHosts[key] unsignedIntegerValue]+1);
        os_unfair_lock_unlock(&lock);return;
    }
    record([NSString stringWithFormat:@"%@ · HTTP %ld · %@ %ld",host,(long)status,error.domain?:@"OK",(long)error.code]);
}
@interface NSURLSession (TBPageDiagnostics)
@end
@implementation NSURLSession (TBPageDiagnostics)
- (NSURLSessionDataTask *)tbpage_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
    if(!completion||!relevant(request.URL.host))return [self tbpage_dataTaskWithRequest:request completionHandler:completion];
    return [self tbpage_dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){completed(response,error);completion(data,response,error);}];
}
- (NSURLSessionDataTask *)tbpage_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
    if(!completion||!relevant(url.host))return [self tbpage_dataTaskWithURL:url completionHandler:completion];
    return [self tbpage_dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){completed(response,error);completion(data,response,error);}];
}
+ (NSURLSession *)tbpage_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    if(delegate){
        os_unfair_lock_lock(&lock);sessions++;os_unfair_lock_unlock(&lock);
        Class cls=[delegate class];SEL sel=@selector(URLSession:task:didCompleteWithError:);
        // Wrap only an implemented callback; preserve optional delegate behavior.
        @synchronized(NSURLSession.class){
            static NSMutableSet *wrapped;if(!wrapped)wrapped=[NSMutableSet set];
            NSString *key=NSStringFromClass(cls);
            Method m=class_getInstanceMethod(cls,sel);
            if(m&&![wrapped containsObject:key]){
                IMP original=method_getImplementation(m);
                IMP replacement=imp_implementationWithBlock(^(id object,NSURLSession *session,NSURLSessionTask *task,NSError *error){completed(task.response,error);((void(*)(id,SEL,NSURLSession *,NSURLSessionTask *,NSError *))original)(object,sel,session,task,error);});
                if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m)))class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));
                [wrapped addObject:key];
            }
        }
    }
    return [self tbpage_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}
@end
@interface NSFileManager (TBPageDiagnostics)
@end
@implementation NSFileManager (TBPageDiagnostics)
- (NSURL *)tbpage_containerURLForSecurityApplicationGroupIdentifier:(NSString *)group {
    NSURL *url=[self tbpage_containerURLForSecurityApplicationGroupIdentifier:group];
    if(!url&&([group containsString:@"amazon"]||[group containsString:@"Amazon"]))record([NSString stringWithFormat:@"App-group container unavailable: %@",group]);
    return url;
}
@end
static void exchange(Class cls,SEL a,SEL b) {Method first=class_getInstanceMethod(cls,a),second=class_getInstanceMethod(cls,b);if(first&&second)method_exchangeImplementations(first,second);}
void TBInstallPageDiagnostics(void) {
    exchange(NSURLSession.class,@selector(dataTaskWithRequest:completionHandler:),@selector(tbpage_dataTaskWithRequest:completionHandler:));
    exchange(NSURLSession.class,@selector(dataTaskWithURL:completionHandler:),@selector(tbpage_dataTaskWithURL:completionHandler:));
    exchange(object_getClass(NSURLSession.class),@selector(sessionWithConfiguration:delegate:delegateQueue:),@selector(tbpage_sessionWithConfiguration:delegate:delegateQueue:));
    exchange(NSFileManager.class,@selector(containerURLForSecurityApplicationGroupIdentifier:),@selector(tbpage_containerURLForSecurityApplicationGroupIdentifier:));
}
NSString *TBPageDiagnosticsText(void) {
    os_unfair_lock_lock(&lock);
    NSMutableArray *lines=[NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Observed delegate sessions: %lu · successful responses: %lu",(unsigned long)sessions,(unsigned long)successes]];
    [lines addObject:@"Distinct failures (repeats grouped):"];
    if(!eventOrder.count)[lines addObject:@"None observed."];
    for(NSString *event in eventOrder)[lines addObject:[NSString stringWithFormat:@"%@ · count %@",event,eventCounts[event]]];
    [lines addObject:@"Successful hosts:"];
    for(NSString *host in [[successHosts allKeys] sortedArrayUsingSelector:@selector(compare:)])[lines addObject:[NSString stringWithFormat:@"%@ · count %@",host,successHosts[host]]];
    [lines addObject:@"Coverage: URLSession completion handlers and implemented delegate completion callbacks. Other network stacks may not appear. HTTP success does not prove the response payload succeeded."];
    NSString *text=[lines componentsJoinedByString:@"\n"];
    os_unfair_lock_unlock(&lock);return text;
}
