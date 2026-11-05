// A separate, additive playback metadata bridge. This file never replaces
// Amazon's MPNowPlayingInfoCenter data or alters Timbre's DSP callbacks.
// It is compiled into future source builds; it is NOT present in the preserved
// Build 19 dylib unless an explicitly experimental packaging path loads it.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <string.h>
#import "fishhook.h"

static void (*TBOriginalSetNowPlayingInfo)(id, SEL, NSDictionary *);
static NSString *const TBSharedGroup = @"group.com.soum91.amazon.timbre";
static NSDictionary *TBLatestPlayerState;
static NSObject *TBStateLock;
static dispatch_source_t TBLocalServer;
static IMP TBPreviousOpenURL;
static BOOL TBInstalledURLHook;
static IMP TBPreviousSceneOpenURL;
static Class TBHookedSceneClass;
static Boolean (*TBRemoteSend)(int, id);

// Timbre 19's original keychain hook understands the original Amazon bundle
// group, but its allowlist predates our side-by-side Lab bundle ID. Route only
// denied access-group lookups into this Lab app's *own* signing-granted default
// group. This never reads the stable app's keychain or its account data.
typedef OSStatus (*TBKeyCopy)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*TBKeyAdd)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*TBKeyUpdate)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*TBKeyDelete)(CFDictionaryRef);
static TBKeyCopy TBRealKeyCopy;
static TBKeyAdd TBRealKeyAdd;
static TBKeyUpdate TBRealKeyUpdate;
static TBKeyDelete TBRealKeyDelete;
static NSString *const TBAmazonGroup = @"J7P34ALZ5R.com.amazon.mp3.AmazonCloudPlayer";
static NSString *const TBLabSuffix = @".com.soum91.amazonmusictimbre.experimental";

static NSDictionary *TBLabKeychainRetry(CFDictionaryRef query) {
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return nil;
    NSDictionary *q = (__bridge NSDictionary *)query;
    NSString *group = q[@"agrp"];
    if (![group isKindOfClass:NSString.class]) return nil;
    BOOL lab = [group hasSuffix:TBLabSuffix];
    BOOL original = [group isEqualToString:TBAmazonGroup];
    BOOL shared = [group isEqualToString:[TBAmazonGroup stringByAppendingString:@".Shared"]];
    BOOL locale = [group isEqualToString:@"group.amazonmusic.prod.notificationlocale"];
    if (!lab && !original && !shared && !locale) return nil;
    NSMutableDictionary *mapped = [q mutableCopy];
    [mapped removeObjectForKey:@"agrp"]; // default group is granted by the signer
    if (shared || locale) {
        if (![q[@"class"] isEqualToString:@"genp"]) return nil;
        NSString *service = q[@"svce"];
        if (!service && locale) service = @"";
        if (![service isKindOfClass:NSString.class]) return nil;
        mapped[@"svce"] = [NSString stringWithFormat:@"Timbre.%@::%@",
                            shared ? @"shared" : @"notification-locale", service];
    }
    return mapped;
}

static OSStatus TBLabCopy(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status = TBRealKeyCopy ? TBRealKeyCopy(query, result) : -4;
    if (status != -34018) return status;
    NSDictionary *retry = TBLabKeychainRetry(query);
    return retry && TBRealKeyCopy ? TBRealKeyCopy((__bridge CFDictionaryRef)retry, result) : status;
}
static OSStatus TBLabAdd(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status = TBRealKeyAdd ? TBRealKeyAdd(query, result) : -4;
    if (status != -34018) return status;
    NSDictionary *retry = TBLabKeychainRetry(query);
    return retry && TBRealKeyAdd ? TBRealKeyAdd((__bridge CFDictionaryRef)retry, result) : status;
}
static OSStatus TBLabUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    OSStatus status = TBRealKeyUpdate ? TBRealKeyUpdate(query, attrs) : -4;
    if (status != -34018) return status;
    NSDictionary *retry = TBLabKeychainRetry(query);
    return retry && TBRealKeyUpdate ? TBRealKeyUpdate((__bridge CFDictionaryRef)retry, attrs) : status;
}
static OSStatus TBLabDelete(CFDictionaryRef query) {
    OSStatus status = TBRealKeyDelete ? TBRealKeyDelete(query) : -4;
    if (status != -34018) return status;
    NSDictionary *retry = TBLabKeychainRetry(query);
    return retry && TBRealKeyDelete ? TBRealKeyDelete((__bridge CFDictionaryRef)retry) : status;
}

static void TBLabObserveImage(const struct mach_header *header, intptr_t slide) {
    if (!TBRealKeyCopy || !TBRealKeyAdd || !TBRealKeyUpdate || !TBRealKeyDelete) return;
    Dl_info info = {0};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "/AmazonCloudPlayer.app/") ||
        strstr(info.dli_fname, "TimbreNative-FlareStore.dylib") ||
        strstr(info.dli_fname, "TimbrePlaybackBridge.dylib")) return;
    struct rebinding hooks[] = {
        {"SecItemCopyMatching", (void *)TBLabCopy, NULL},
        {"SecItemAdd", (void *)TBLabAdd, NULL},
        {"SecItemUpdate", (void *)TBLabUpdate, NULL},
        {"SecItemDelete", (void *)TBLabDelete, NULL}
    };
    rebind_symbols_image((void *)header, slide, hooks, 4);
}

static void TBInstallLabKeychainCompatibility(void) {
    TBRealKeyCopy = (TBKeyCopy)dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    TBRealKeyAdd = (TBKeyAdd)dlsym(RTLD_DEFAULT, "SecItemAdd");
    TBRealKeyUpdate = (TBKeyUpdate)dlsym(RTLD_DEFAULT, "SecItemUpdate");
    TBRealKeyDelete = (TBKeyDelete)dlsym(RTLD_DEFAULT, "SecItemDelete");
    // Install after Timbre 19's own add-image hook so our Lab-specific
    // fallback takes precedence without touching the old dylib's code.
    _dyld_register_func_for_add_image(TBLabObserveImage);
}

// ---------------------------------------------------------------------------
// Amazon identity for Amazon's own code (Lab login fix).
//
// Stable logs in because it keeps com.amazon.mp3.AmazonCloudPlayer. The Lab
// copy has its own bundle ID so it can sit beside stable, and Amazon's MAP
// sign-in sends that ID to Amazon's servers, which reject it ("Exception #47,
// MAP Error Code 0"). Keychain groups and URL schemes were never the cause.
//
// Here Amazon's code (the app executable and its embedded frameworks) is told
// the original Amazon bundle ID. iOS, UIKit, Foundation, WidgetKit and our own
// dylibs keep seeing the real Lab ID, so the separate container, defaults,
// widget and side-by-side install are unchanged. Inactive in stable builds.
// ---------------------------------------------------------------------------
static NSString *const TBAmazonBundleID = @"com.amazon.mp3.AmazonCloudPlayer";
#define TB_MAX_AMAZON_IMAGES 512
static uintptr_t TBAmazonTextStart[TB_MAX_AMAZON_IMAGES];
static uintptr_t TBAmazonTextEnd[TB_MAX_AMAZON_IMAGES];
static _Atomic int TBAmazonImageCount;
static NSBundle *TBMainBundle;
static CFBundleRef TBMainCFBundle;
static NSDictionary *TBAmazonInfo;
static NSString *(*TBOrigBundleIdentifier)(id, SEL);
static NSDictionary *(*TBOrigInfoDictionary)(id, SEL);
static id (*TBOrigObjectForInfoKey)(id, SEL, NSString *);
static CFStringRef (*TBRealCFBundleGetIdentifier)(CFBundleRef);
static CFDictionaryRef (*TBRealCFBundleGetInfoDictionary)(CFBundleRef);
static CFTypeRef (*TBRealCFBundleGetValue)(CFBundleRef, CFStringRef);

static BOOL TBIsAmazonImagePath(const char *path) {
    return path && strstr(path, "/AmazonCloudPlayer.app/") &&
        !strstr(path, "/PlugIns/") &&
        !strstr(path, "TimbreNative-FlareStore.dylib") &&
        !strstr(path, "TimbrePlaybackBridge.dylib");
}

static BOOL TBCallerIsAmazon(const void *address) {
    uintptr_t a = (uintptr_t)address;
    int count = atomic_load_explicit(&TBAmazonImageCount, memory_order_acquire);
    for (int i = 0; i < count; i++) {
        if (a >= TBAmazonTextStart[i] && a < TBAmazonTextEnd[i]) return YES;
    }
    return NO;
}

static NSDictionary *TBAmazonInfoDictionary(NSDictionary *real) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *info = [real mutableCopy] ?: [NSMutableDictionary dictionary];
        info[@"CFBundleIdentifier"] = TBAmazonBundleID;
        TBAmazonInfo = [info copy];
    });
    return TBAmazonInfo;
}

static NSString *TBBundleIdentifier(id bundle, SEL selector) {
    if (bundle == TBMainBundle && TBCallerIsAmazon(__builtin_return_address(0)))
        return TBAmazonBundleID;
    return TBOrigBundleIdentifier(bundle, selector);
}

static NSDictionary *TBInfoDictionary(id bundle, SEL selector) {
    NSDictionary *real = TBOrigInfoDictionary(bundle, selector);
    if (bundle == TBMainBundle && TBCallerIsAmazon(__builtin_return_address(0)))
        return TBAmazonInfoDictionary(real);
    return real;
}

static id TBObjectForInfoKey(id bundle, SEL selector, NSString *key) {
    if (bundle == TBMainBundle && [key isEqualToString:@"CFBundleIdentifier"] &&
        TBCallerIsAmazon(__builtin_return_address(0)))
        return TBAmazonBundleID;
    return TBOrigObjectForInfoKey(bundle, selector, key);
}

// The C variants are rebound only inside Amazon images, so no caller check.
static CFStringRef TBCFBundleGetIdentifier(CFBundleRef bundle) {
    if (bundle && bundle == TBMainCFBundle) return (__bridge CFStringRef)TBAmazonBundleID;
    return TBRealCFBundleGetIdentifier(bundle);
}

static CFDictionaryRef TBCFBundleGetInfoDictionary(CFBundleRef bundle) {
    CFDictionaryRef real = TBRealCFBundleGetInfoDictionary(bundle);
    if (bundle && bundle == TBMainCFBundle)
        return (__bridge CFDictionaryRef)TBAmazonInfoDictionary((__bridge NSDictionary *)real);
    return real;
}

static CFTypeRef TBCFBundleGetValue(CFBundleRef bundle, CFStringRef key) {
    if (bundle && bundle == TBMainCFBundle && key &&
        CFEqual(key, kCFBundleIdentifierKey))
        return (__bridge CFTypeRef)TBAmazonBundleID;
    return TBRealCFBundleGetValue(bundle, key);
}

static void TBObserveAmazonIdentityImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info = {0};
    if (!dladdr(header, &info) || !TBIsAmazonImagePath(info.dli_fname)) return;
    if (header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                int index = atomic_load_explicit(&TBAmazonImageCount, memory_order_relaxed);
                if (index < TB_MAX_AMAZON_IMAGES) {
                    TBAmazonTextStart[index] = (uintptr_t)(seg->vmaddr + slide);
                    TBAmazonTextEnd[index] = (uintptr_t)(seg->vmaddr + seg->vmsize + slide);
                    atomic_store_explicit(&TBAmazonImageCount, index + 1, memory_order_release);
                }
                break;
            }
        }
        cursor += lc->cmdsize;
    }
    struct rebinding hooks[] = {
        {"CFBundleGetIdentifier", (void *)TBCFBundleGetIdentifier, NULL},
        {"CFBundleGetInfoDictionary", (void *)TBCFBundleGetInfoDictionary, NULL},
        {"CFBundleGetValueForInfoDictionaryKey", (void *)TBCFBundleGetValue, NULL}
    };
    rebind_symbols_image((void *)header, slide, hooks, 3);
}

static void TBSwap(SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(NSBundle.class, selector);
    if (!method) return;
    *original = method_setImplementation(method, replacement);
}

static void TBInstallAmazonIdentity(void) {
    TBMainBundle = NSBundle.mainBundle;
    TBMainCFBundle = CFBundleGetMainBundle();
    NSString *real = TBMainBundle.bundleIdentifier;
    // Stable already is Amazon's bundle ID; only the side-by-side Lab needs this.
    if (!real || [real isEqualToString:TBAmazonBundleID]) return;
    TBRealCFBundleGetIdentifier = CFBundleGetIdentifier;
    TBRealCFBundleGetInfoDictionary = CFBundleGetInfoDictionary;
    TBRealCFBundleGetValue = CFBundleGetValueForInfoDictionaryKey;
    TBSwap(@selector(bundleIdentifier), (IMP)TBBundleIdentifier, (IMP *)&TBOrigBundleIdentifier);
    TBSwap(@selector(infoDictionary), (IMP)TBInfoDictionary, (IMP *)&TBOrigInfoDictionary);
    TBSwap(@selector(objectForInfoDictionaryKey:), (IMP)TBObjectForInfoKey, (IMP *)&TBOrigObjectForInfoKey);
    // Called immediately for every image already loaded, then for later ones.
    _dyld_register_func_for_add_image(TBObserveAmazonIdentityImage);
}

static void TBResolveMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                                 RTLD_LAZY | RTLD_LOCAL);
        TBRemoteSend = framework ? (Boolean (*)(int, id))dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
    });
}

// Local-only widget endpoint on 127.0.0.1. The WidgetKit extension reads playback, EQ and spectrum state here
// (it works even when the signing profile grants no App Group) and sends button commands. Requests must carry
// the per-install token the packager writes into both Info.plists, so other apps on the phone cannot drive it.
// No stream URLs, cookies, account identifiers or tokens of Amazon's are ever exposed.
static BOOL TBSendMediaCommand(NSInteger command);
static void TBRequestWidgetReload(NSString *kind);

static NSString *TBLocalToken(void) {
    static NSString *token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = NSBundle.mainBundle.infoDictionary[@"TimbreLocalToken"];
        token = [value isKindOfClass:NSString.class] && [value length] >= 16 ? [value copy] : nil;
    });
    return token;
}

static id TBOnMain(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static NSDictionary *TBEQState(void) {
    NSDictionary *(*snapshot)(void) = (NSDictionary *(*)(void))dlsym(RTLD_DEFAULT, "TBEmbeddedWidgetSnapshot");
    if (!snapshot) return @{};
    return TBOnMain(^id { return snapshot() ?: @{}; });
}

static NSDictionary *TBSpectrumState(void) {
    NSDictionary *(*snapshot)(void) = (NSDictionary *(*)(void))dlsym(RTLD_DEFAULT, "TimbreSpectrumSnapshot");
    return snapshot ? (snapshot() ?: @{}) : @{};
}

static NSDictionary *TBWidgetState(void) {
    NSDictionary *player;
    @synchronized(TBStateLock) { player = [TBLatestPlayerState copy] ?: @{}; }
    return @{@"player": player, @"eq": TBEQState(), @"spectrum": TBSpectrumState(),
             @"time": @([NSDate date].timeIntervalSince1970)};
}

static BOOL TBRunWidgetCommand(NSString *command) {
    if ([command isEqualToString:@"player/toggle"]) return TBSendMediaCommand(2);
    if ([command isEqualToString:@"player/next"]) return TBSendMediaCommand(4);
    if ([command isEqualToString:@"player/previous"]) return TBSendMediaCommand(5);
    BOOL (*run)(NSString *) = (BOOL (*)(NSString *))dlsym(RTLD_DEFAULT, "TBEmbeddedWidgetCommand");
    if (!run) return NO;
    NSNumber *ok = TBOnMain(^id { return @(run(command)); });
    if (ok.boolValue) TBRequestWidgetReload(@"com.soum91.timbre.eq");
    return ok.boolValue;
}

static void TBSendResponse(int client, int status, NSData *body) {
    NSString *reason = status == 200 ? @"OK" : status == 403 ? @"Forbidden" : @"Not Found";
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        status, reason, (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    const unsigned char *bytes = response.bytes;
    size_t remaining = response.length;
    while (remaining) {
        ssize_t sent = send(client, bytes, remaining, 0);
        if (sent <= 0) break;
        bytes += sent;
        remaining -= (size_t)sent;
    }
}

static void TBRespondToLocalClient(int client) {
    struct timeval timeout = {1, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    char request[2049] = {0};
    ssize_t count = recv(client, request, sizeof(request) - 1, 0);
    NSString *text = count > 0 ? [[NSString alloc] initWithBytes:request length:(NSUInteger)count encoding:NSUTF8StringEncoding] : nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *first = [lines.firstObject componentsSeparatedByString:@" "];
    if (first.count < 2 || ![first[0] isEqualToString:@"GET"]) {
        TBSendResponse(client, 404, [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
        close(client);
        return;
    }
    NSString *path = first[1];
    NSString *token = TBLocalToken();
    if (token) {
        NSString *sent = nil;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"x-timbre-token:"])
                sent = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        if (![sent isEqualToString:token]) {
            TBSendResponse(client, 403, [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
            close(client);
            return;
        }
    }
    id body = nil;
    if ([path isEqualToString:@"/player"]) {
        @synchronized(TBStateLock) { body = [TBLatestPlayerState copy] ?: @{}; }
    } else if ([path isEqualToString:@"/state"]) {
        body = TBWidgetState();
    } else if ([path hasPrefix:@"/command/"]) {
        NSString *command = [path substringFromIndex:9];
        BOOL ok = TBRunWidgetCommand(command);
        // Give Amazon a moment to apply a transport change before reporting state back.
        if (ok && [command hasPrefix:@"player/"]) usleep(350000);
        NSMutableDictionary *state = [TBWidgetState() mutableCopy];
        state[@"ok"] = @(ok);
        body = state;
    }
    NSData *json = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    TBSendResponse(client, json ? 200 : 404, json ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
    close(client);
}

static void TBStartLocalServer(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(43819);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 4) != 0) {
        close(fd);
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("com.soum91.timbre.widget.local", DISPATCH_QUEUE_SERIAL);
    TBLocalServer = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
    dispatch_source_set_event_handler(TBLocalServer, ^{
        int client = accept(fd, NULL, NULL);
        if (client >= 0) TBRespondToLocalClient(client);
    });
    dispatch_source_set_cancel_handler(TBLocalServer, ^{ close(fd); });
    dispatch_resume(TBLocalServer);
}

static BOOL TBSendMediaCommand(NSInteger command) {
    // This private framework is optional and has no influence on Timbre DSP.
    // If the OS removes it or rejects the request, let iOS open the music app.
    TBResolveMediaRemote();
    return TBRemoteSend ? (TBRemoteSend((int)command, nil) != 0) : NO;
}

static BOOL TBHandlePlayerURL(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"timbre-amazon-lab"]) return NO;
    if ([url.host.lowercaseString isEqualToString:@"player"]) {
        NSString *action = url.path.lowercaseString;
        if ([action isEqualToString:@"/toggle"]) TBSendMediaCommand(2);
        if ([action isEqualToString:@"/next"]) TBSendMediaCommand(4);
        if ([action isEqualToString:@"/previous"]) TBSendMediaCommand(5);
    }
    // For both "open" and transport actions, activating the URL foregrounds
    // Amazon Music. Do not intercept Amazon's original amznmp3 URLs.
    return YES;
}

static BOOL TBApplicationOpenURL(id delegate, SEL selector, UIApplication *app,
                                 NSURL *url, NSDictionary *options) {
    if (TBHandlePlayerURL(url)) return YES;
    if (TBPreviousOpenURL) {
        return ((BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))TBPreviousOpenURL)
            (delegate, selector, app, url, options);
    }
    return NO;
}

static void TBSceneOpenURLs(id delegate, SEL selector, UIScene *scene,
                            NSSet<UIOpenURLContext *> *contexts) {
    NSMutableSet<UIOpenURLContext *> *unhandled = [NSMutableSet set];
    for (UIOpenURLContext *context in contexts) {
        if (!TBHandlePlayerURL(context.URL)) [unhandled addObject:context];
    }
    if (unhandled.count && TBPreviousSceneOpenURL) {
        ((void (*)(id, SEL, UIScene *, NSSet *))TBPreviousSceneOpenURL)
            (delegate, selector, scene, unhandled);
    }
}

static void TBInstallURLHook(void) {
    id delegate = UIApplication.sharedApplication.delegate;
    if (delegate && !TBInstalledURLHook) {
        Class cls = object_getClass(delegate);
        SEL selector = @selector(application:openURL:options:);
        Method existing = class_getInstanceMethod(cls, selector);
        if (existing) {
            TBPreviousOpenURL = method_getImplementation(existing);
            class_addMethod(cls, selector, (IMP)TBApplicationOpenURL,
                            method_getTypeEncoding(existing));
            if (class_getMethodImplementation(cls, selector) != (IMP)TBApplicationOpenURL) {
                method_setImplementation(class_getInstanceMethod(cls, selector),
                                         (IMP)TBApplicationOpenURL);
            }
        } else {
            class_addMethod(cls, selector, (IMP)TBApplicationOpenURL, "c@:@@@");
        }
        TBInstalledURLHook = YES;
    }
    // Amazon declares a UIWindowSceneDelegate. On iOS 13+ its URL callback
    // normally bypasses application:openURL:options: completely.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        id sceneDelegate = scene.delegate;
        if (!sceneDelegate) continue;
        Class cls = object_getClass(sceneDelegate);
        if (TBHookedSceneClass) continue;
        SEL selector = @selector(scene:openURLContexts:);
        Method method = class_getInstanceMethod(cls, selector);
        TBPreviousSceneOpenURL = method ? method_getImplementation(method) : NULL;
        if (method) {
            class_addMethod(cls, selector, (IMP)TBSceneOpenURLs, method_getTypeEncoding(method));
            if (class_getMethodImplementation(cls, selector) != (IMP)TBSceneOpenURLs) {
                method_setImplementation(class_getInstanceMethod(cls, selector),
                                         (IMP)TBSceneOpenURLs);
            }
        } else {
            class_addMethod(cls, selector, (IMP)TBSceneOpenURLs, "v@:@@");
        }
        TBHookedSceneClass = cls;
    }
}

static void TBRequestWidgetReload(NSString *kind) {
    static void (*reload)(const char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ reload = (void (*)(const char *))dlsym(RTLD_DEFAULT, "TBReloadWidgetTimelines"); });
    if (!reload) return;
    // WidgetKit does not charge reload budget while the app has an active audio session.
    dispatch_async(dispatch_get_main_queue(), ^{ reload(kind.UTF8String); });
}

static NSString *TBLastTrackKey;
static NSNumber *TBLastPlaying;
static dispatch_source_t TBVisualizerTimer;

static void TBStartWidgetRefresh(void) {
    // Spectrum widget: refresh every 15 s while music plays. Track/EQ changes reload the other widgets at once.
    TBVisualizerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(TBVisualizerTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 3 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(TBVisualizerTimer, ^{
        if (TBLastPlaying.boolValue) TBRequestWidgetReload(@"com.soum91.timbre.visualizer");
    });
    dispatch_resume(TBVisualizerTimer);
    __block CFAbsoluteTime lastEQ = 0;
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastEQ < 1.5) return;
        lastEQ = now;
        TBRequestWidgetReload(@"com.soum91.timbre.eq");
    }];
}

static void TBPublishNowPlaying(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return;
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || title.length == 0) return;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"title"] = title;
    NSString *artist = info[MPMediaItemPropertyArtist];
    NSString *album = info[MPMediaItemPropertyAlbumTitle];
    state[@"artist"] = [artist isKindOfClass:NSString.class] ? artist : @"";
    state[@"album"] = [album isKindOfClass:NSString.class] ? album : @"";
    state[@"playing"] = @([info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0.01);
    state[@"duration"] = @([info[MPMediaItemPropertyPlaybackDuration] doubleValue]);
    state[@"elapsed"] = @([info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]);
    state[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
    TBResolveMediaRemote();
    state[@"controlsReady"] = @(TBRemoteSend != NULL);

    // One modest, compressed cover image only. Never share stream URLs,
    // cookies, account identifiers, tokens, or license information.
    MPMediaItemArtwork *art = info[MPMediaItemPropertyArtwork];
    if ([art isKindOfClass:MPMediaItemArtwork.class]) {
        UIImage *cover = [art imageWithSize:CGSizeMake(160, 160)];
        NSData *jpeg = cover ? UIImageJPEGRepresentation(cover, 0.60) : nil;
        if (jpeg.length > 0 && jpeg.length < 131072) {
            state[@"artworkJPEG"] = [jpeg base64EncodedStringWithOptions:0];
        }
    }
    @synchronized(TBStateLock) { TBLatestPlayerState = [state copy]; }
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:TBSharedGroup];
    [shared setObject:state forKey:@"TimbreWidget.nowPlaying.v1"];
    NSString *trackKey = [NSString stringWithFormat:@"%@\n%@\n%@", state[@"title"], state[@"artist"], state[@"album"]];
    if (![trackKey isEqualToString:TBLastTrackKey] || ![state[@"playing"] isEqual:TBLastPlaying]) {
        TBLastTrackKey = trackKey;
        TBLastPlaying = state[@"playing"];
        TBRequestWidgetReload(@"com.soum91.timbre.player");
        TBRequestWidgetReload(@"com.soum91.timbre.visualizer");
    }
}

static void TBSetNowPlayingInfo(id center, SEL selector, NSDictionary *info) {
    // Apple's player ownership and remote-command targets remain unchanged.
    TBOriginalSetNowPlayingInfo(center, selector, info);
    NSDictionary *snapshot = [info copy];
    if ([NSThread isMainThread]) {
        TBPublishNowPlaying(snapshot);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ TBPublishNowPlaying(snapshot); });
    }
}

__attribute__((constructor))
static void TBInitializePlaybackBridge(void) {
    // Login may hit the keychain before UIKit processes the main queue.
    // Register this after the preserved Timbre 19 constructor, at load time.
    TBInstallLabKeychainCompatibility();
    // Must be live before Amazon's sign-in code first asks for its identity.
    TBInstallAmazonIdentity();
    dispatch_async(dispatch_get_main_queue(), ^{
        TBStateLock = [NSObject new];
        TBStartLocalServer();
        TBStartWidgetRefresh();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            TBInstallURLHook();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            TBInstallURLHook();
        }];
        TBInstallURLHook();
        Method method = class_getInstanceMethod(MPNowPlayingInfoCenter.class,
                                                @selector(setNowPlayingInfo:));
        if (!method) return;
        IMP current = method_getImplementation(method);
        if (current == (IMP)TBSetNowPlayingInfo) return;
        TBOriginalSetNowPlayingInfo = (void (*)(id, SEL, NSDictionary *))current;
        method_setImplementation(method, (IMP)TBSetNowPlayingInfo);
        NSDictionary *existing = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (existing.count) TBPublishNowPlaying(existing);
    });
}
