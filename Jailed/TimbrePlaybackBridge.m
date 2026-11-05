// A separate, additive playback metadata bridge. This file never replaces
// Amazon's MPNowPlayingInfoCenter data or alters Timbre's DSP callbacks.
// It is compiled into future source builds; it is NOT present in the preserved
// Build 19 dylib unless an explicitly experimental packaging path loads it.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

static void (*TBOriginalSetNowPlayingInfo)(id, SEL, NSDictionary *);
static NSString *const TBSharedGroup = @"group.com.soum91.amazon.timbre";

static void TBPublishNowPlaying(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return;
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || title.length == 0) return;
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:TBSharedGroup];
    if (!shared) return;

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"title"] = title;
    NSString *artist = info[MPMediaItemPropertyArtist];
    NSString *album = info[MPMediaItemPropertyAlbumTitle];
    state[@"artist"] = [artist isKindOfClass:NSString.class] ? artist : @"";
    state[@"album"] = [album isKindOfClass:NSString.class] ? album : @"";
    state[@"playing"] = @([info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0.01);
    state[@"duration"] = @([info[MPMediaItemPropertyPlaybackDuration] doubleValue]);
    state[@"elapsed"] = @([info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]);
    state[@"updatedAt"] = [NSDate date];

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
