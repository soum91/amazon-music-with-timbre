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

static void TBResolveMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                                 RTLD_LAZY | RTLD_LOCAL);
        TBRemoteSend = framework ? (Boolean (*)(int, id))dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
    });
}

// The local-only endpoint is deliberately read-only. The WidgetKit extension
// can obtain Now Playing data even when a third-party signing profile does not
// provide App Group entitlements. No streaming URL or account data is exposed.
static void TBRespondToLocalClient(int client) {
    struct timeval timeout = {1, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    char request[1025] = {0};
    ssize_t count = recv(client, request, sizeof(request) - 1, 0);
    if (count <= 0 || strncmp(request, "GET /player ", 12) != 0) {
        close(client);
        return;
    }
    NSDictionary *state;
    @synchronized(TBStateLock) { state = [TBLatestPlayerState copy] ?: @{}; }
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (!json) json = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        (unsigned long)json.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:json];
    const unsigned char *bytes = response.bytes;
    size_t remaining = response.length;
    while (remaining) {
        ssize_t sent = send(client, bytes, remaining, 0);
        if (sent <= 0) break;
        bytes += sent;
        remaining -= (size_t)sent;
    }
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
    dispatch_async(dispatch_get_main_queue(), ^{
        TBInstallLabKeychainCompatibility();
        TBStateLock = [NSObject new];
        TBStartLocalServer();
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
