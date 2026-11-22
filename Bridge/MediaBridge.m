// MediaBridge — tiny helper loaded by /usr/bin/perl (an Apple-signed binary that
// is still allowed to talk to the private MediaRemote framework on macOS 15.4+).
// It streams all active Now Playing clients as JSON lines on stdout and executes
// targeted commands read line by line from stdin. Exits as soon as the parent app
// goes away.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRSetTimeFn)(double);

@interface NSObject (MRPrivateBridge)
+ (id)localOrigin;
- (id)initWithBundleIdentifier:(NSString *)bundleIdentifier;
- (id)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (id)initWithPlayerPath:(id)playerPath;
- (NSString *)bundleIdentifier;
- (NSString *)parentApplicationBundleIdentifier;
- (NSString *)representedBundleID;
- (NSString *)displayName;
- (int)processIdentifier;
- (void)requestNowPlayingInfoOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSDictionary *info, NSError *error))completion;
- (void)requestNowPlayingItemArtworkOnQueue:(dispatch_queue_t)queue completion:(void (^)(id artwork, NSError *error))completion;
- (NSData *)imageData;
- (void)requestIsPlayingOnQueue:(dispatch_queue_t)queue completion:(void (^)(BOOL isPlaying, NSError *error))completion;
- (void)requestLastPlayingDateOnQueue:(dispatch_queue_t)queue completion:(void (^)(NSDate *date, NSError *error))completion;
- (void)sendCommand:(unsigned int)command options:(NSDictionary *)options queue:(dispatch_queue_t)queue completion:(void (^)(NSError *error))completion;
@end

static MRGetInfoFn MRGetInfo;
static MRGetBoolFn MRGetIsPlaying;
static MRGetPIDFn MRGetPID;
static MRGetClientsFn MRGetClients;
static MRRegisterFn MRRegister;
static MRSendFn MRSend;
static MRSetTimeFn MRSetTime;

static dispatch_queue_t queue;
static dispatch_block_t pending;
static dispatch_source_t stdinSource;
static dispatch_source_t parentTimer;
static NSMutableData *stdinBuffer;
static NSMutableDictionary<NSString *, NSString *> *lastArtworkKeys;
static NSDictionary<NSString *, id> *activePaths;
static uint64_t refreshGeneration;
static pid_t parentPID;

static void scheduleRefresh(void);

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id orNull(id value) { return value ?: [NSNull null]; }

static NSString *nonEmpty(NSString *value) {
    return ([value isKindOfClass:NSString.class] && value.length > 0) ? value : nil;
}

// Live streams in browsers report an infinite duration, which JSON can't hold.
static id finiteOrNull(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : [NSNull null];
}

// Full-size covers can be megabytes: send a 192 px JPEG instead.
static NSData *thumbnail(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @192,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.85});
        if (!CGImageDestinationFinalize(dest)) out = nil;
        CFRelease(dest);
    }
    CGImageRelease(image);
    return out.length > 0 ? out : nil;
}

static NSMutableDictionary *buildItem(NSString *clientKey,
                                      int pid,
                                      NSString *bundleID,
                                      NSString *rawBundleID,
                                      NSString *appName,
                                      NSDictionary *info,
                                      NSData *artworkOverride,
                                      BOOL playing,
                                      NSDate *lastPlayingDate,
                                      BOOL isGlobal,
                                      NSMutableSet<NSString *> *seenClientKeys) {
    NSString *title = nonEmpty(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (!title) return nil;

    NSString *artist = nonEmpty(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSDate *stamp = [info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] isKindOfClass:NSDate.class]
        ? info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] : nil;
    NSString *mediaType = nonEmpty(info[@"kMRMediaRemoteNowPlayingInfoMediaType"]);
    BOOL isMusicApp = [info[@"kMRMediaRemoteNowPlayingInfoIsMusicApp"] respondsToSelector:@selector(boolValue)]
        && [info[@"kMRMediaRemoteNowPlayingInfoIsMusicApp"] boolValue];

    NSMutableDictionary *item = [@{
        @"clientKey": clientKey,
        @"pid": @(pid),
        @"bundleID": orNull(bundleID),
        @"rawBundleID": orNull(rawBundleID),
        @"appName": orNull(appName),
        @"title": title,
        @"artist": orNull(artist),
        @"album": orNull(nonEmpty(info[@"kMRMediaRemoteNowPlayingInfoAlbum"])),
        @"duration": finiteOrNull(info[@"kMRMediaRemoteNowPlayingInfoDuration"]),
        @"elapsed": finiteOrNull(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]),
        @"rate": finiteOrNull(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]),
        @"timestamp": stamp ? @([stamp timeIntervalSince1970]) : [NSNull null],
        @"playing": @(playing),
        @"lastPlayingDate": lastPlayingDate ? @([lastPlayingDate timeIntervalSince1970]) : [NSNull null],
        @"mediaType": orNull(mediaType),
        @"isMusicApp": @(isMusicApp),
        @"isGlobal": @(isGlobal),
    } mutableCopy];

    [seenClientKeys addObject:clientKey];

    // Artwork is large: only send base64 when it changes for this client, but
    // always include artworkKey so the app can reuse its local cache.
    NSData *artwork = ([artworkOverride isKindOfClass:NSData.class] && artworkOverride.length > 0)
        ? artworkOverride : info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
        NSString *artKey = [NSString stringWithFormat:@"%@|%@|%lu", title, artist ?: @"", (unsigned long)artwork.length];
        item[@"artworkKey"] = artKey;
        if (![artKey isEqualToString:lastArtworkKeys[clientKey]]) {
            lastArtworkKeys[clientKey] = artKey;
            item[@"artwork"] = [(thumbnail(artwork) ?: artwork) base64EncodedStringWithOptions:0];
        }
    } else {
        [lastArtworkKeys removeObjectForKey:clientKey];
        item[@"artworkKey"] = [NSNull null];
    }
    return item;
}

static void pruneArtworkKeys(NSSet<NSString *> *seenClientKeys) {
    NSArray<NSString *> *existing = lastArtworkKeys.allKeys;
    for (NSString *key in existing) {
        if (![seenClientKeys containsObject:key]) {
            [lastArtworkKeys removeObjectForKey:key];
        }
    }
}

static void refreshLegacy(uint64_t gen) {
    MRGetInfo(queue, ^(CFDictionaryRef raw) {
        if (gen != refreshGeneration) return;
        NSDictionary *info = raw ? [(__bridge NSDictionary *)raw copy] : nil;
        MRGetIsPlaying(queue, ^(Boolean playing) {
            if (gen != refreshGeneration) return;
            MRGetPID(queue, ^(int pid) {
                if (gen != refreshGeneration) return;
                @autoreleasepool {
                    NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                    NSString *bundleID = nonEmpty(app.bundleIdentifier);
                    NSString *appName = nonEmpty(app.localizedName);
                    NSString *clientKey = [NSString stringWithFormat:@"%d|%@", pid, bundleID ?: @""];
                    NSMutableSet<NSString *> *seen = [NSMutableSet set];
                    NSMutableArray *items = [NSMutableArray array];
                    NSMutableDictionary *item = buildItem(clientKey, pid, bundleID, bundleID, appName,
                                                          info, nil, playing, nil, YES, seen);
                    if (item) [items addObject:item];
                    activePaths = @{};
                    pruneArtworkKeys(seen);
                    emit(@{@"type": @"clients", @"items": items});
                }
            });
        });
    });
}

static void refresh(void) {
    uint64_t gen = ++refreshGeneration;
    Class MROrigin = NSClassFromString(@"MROrigin");
    Class MRPlayerPath = NSClassFromString(@"MRPlayerPath");
    Class MRNowPlayingRequest = NSClassFromString(@"MRNowPlayingRequest");
    id origin = [MROrigin respondsToSelector:@selector(localOrigin)] ? [MROrigin localOrigin] : nil;

    if (!MRGetClients || !origin || !MRPlayerPath || !MRNowPlayingRequest) {
        refreshLegacy(gen);
        return;
    }

    MRGetPID(queue, ^(int globalPID) {
        if (gen != refreshGeneration) return;
        MRGetClients(queue, ^(CFArrayRef rawClients) {
            if (gen != refreshGeneration) return;
            NSArray *clients = rawClients ? [(__bridge NSArray *)rawClients copy] : @[];
            if (clients.count == 0) {
                refreshLegacy(gen);
                return;
            }

            NSMutableDictionary<NSString *, id> *newPaths = [NSMutableDictionary dictionaryWithCapacity:clients.count];
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:clients.count];
            NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:clients.count];
            dispatch_group_t group = dispatch_group_create();

            for (id client in clients) {
                int pid = [client respondsToSelector:@selector(processIdentifier)] ? [client processIdentifier] : 0;
                NSString *rawBundleID = [client respondsToSelector:@selector(bundleIdentifier)] ? nonEmpty([client bundleIdentifier]) : nil;
                NSString *parentBundleID = [client respondsToSelector:@selector(parentApplicationBundleIdentifier)] ? nonEmpty([client parentApplicationBundleIdentifier]) : nil;
                NSString *repBundleID = [client respondsToSelector:@selector(representedBundleID)] ? nonEmpty([client representedBundleID]) : nil;
                NSString *displayName = [client respondsToSelector:@selector(displayName)] ? nonEmpty([client displayName]) : nil;

                NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                NSString *bundleID = repBundleID ?: parentBundleID ?: rawBundleID ?: nonEmpty(app.bundleIdentifier);
                NSString *appName = displayName ?: nonEmpty(app.localizedName);
                NSString *clientKey = [NSString stringWithFormat:@"%d|%@", pid, rawBundleID ?: (bundleID ?: @"")];

                id path = [[MRPlayerPath alloc] initWithOrigin:origin client:client player:nil];
                if (!path) continue;
                newPaths[clientKey] = path;

                id req = [[MRNowPlayingRequest alloc] initWithPlayerPath:path];
                if (!req || ![req respondsToSelector:@selector(requestNowPlayingInfoOnQueue:completion:)]) continue;

                dispatch_group_enter(group);
                [req requestNowPlayingInfoOnQueue:queue completion:^(NSDictionary *info, NSError *err) {
                    if (gen != refreshGeneration || !nonEmpty(info[@"kMRMediaRemoteNowPlayingInfoTitle"])) {
                        dispatch_group_leave(group);
                        return;
                    }
                    void (^finish)(BOOL, NSDate *, NSData *) = ^(BOOL playing, NSDate *lastDate, NSData *artData) {
                        if (gen == refreshGeneration) {
                            @autoreleasepool {
                                NSMutableDictionary *item = buildItem(clientKey, pid, bundleID, rawBundleID, appName,
                                                                      info, artData, playing, lastDate,
                                                                      (pid > 0 && pid == globalPID), seen);
                                if (item) [items addObject:item];
                            }
                        }
                        dispatch_group_leave(group);
                    };

                    void (^queryArtwork)(BOOL, NSDate *) = ^(BOOL playing, NSDate *lastDate) {
                        NSData *inlineArt = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                        if ([inlineArt isKindOfClass:NSData.class] && inlineArt.length > 0) {
                            finish(playing, lastDate, inlineArt);
                            return;
                        }
                        if ([req respondsToSelector:@selector(requestNowPlayingItemArtworkOnQueue:completion:)]) {
                            [req requestNowPlayingItemArtworkOnQueue:queue completion:^(id art, NSError *artErr) {
                                NSData *data = [art respondsToSelector:@selector(imageData)] ? [art imageData] : nil;
                                finish(playing, lastDate, data);
                            }];
                        } else {
                            finish(playing, lastDate, nil);
                        }
                    };

                    void (^queryDate)(BOOL) = ^(BOOL playing) {
                        if ([req respondsToSelector:@selector(requestLastPlayingDateOnQueue:completion:)]) {
                            [req requestLastPlayingDateOnQueue:queue completion:^(NSDate *lastDate, NSError *err3) {
                                queryArtwork(playing, lastDate);
                            }];
                        } else {
                            queryArtwork(playing, nil);
                        }
                    };

                    if ([req respondsToSelector:@selector(requestIsPlayingOnQueue:completion:)]) {
                        [req requestIsPlayingOnQueue:queue completion:^(BOOL playing, NSError *err2) {
                            queryDate(playing);
                        }];
                    } else {
                        BOOL playing = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue] > 0;
                        queryDate(playing);
                    }
                }];
            }

            dispatch_group_notify(group, queue, ^{
                if (gen != refreshGeneration) return;
                activePaths = [newPaths copy];
                pruneArtworkKeys(seen);
                emit(@{@"type": @"clients", @"items": items});
            });
        });
    });
}

static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
        if (pending) dispatch_block_cancel(pending);
        pending = dispatch_block_create(0, ^{ refresh(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), queue, pending);
    });
}

static void sendToPath(id path, unsigned int command, NSDictionary *options) {
    Class MRNowPlayingRequest = NSClassFromString(@"MRNowPlayingRequest");
    if (path && MRNowPlayingRequest) {
        id req = [[MRNowPlayingRequest alloc] initWithPlayerPath:path];
        if ([req respondsToSelector:@selector(sendCommand:options:queue:completion:)]) {
            [req sendCommand:command options:options queue:queue completion:^(NSError *err) {
                scheduleRefresh();
            }];
            return;
        }
    }
    if (command == 24 && options[@"kMRMediaRemoteOptionPlaybackPosition"]) {
        MRSetTime([options[@"kMRMediaRemoteOptionPlaybackPosition"] doubleValue]);
    } else {
        MRSend((int)command, (__bridge CFDictionaryRef)options);
    }
    scheduleRefresh();
}

static void sendTargeted(unsigned int command, NSDictionary *options, NSString *clientKey) {
    id path = clientKey.length ? activePaths[clientKey] : nil;
    if (clientKey.length && !path) {
        // Never fall back to global when a specific client was requested, so we
        // don't accidentally resume a paused browser video.
        return;
    }
    sendToPath(path, command, options);
}

static void sendToBundleID(unsigned int command, NSString *bundleID) {
    if (!bundleID.length) {
        MRSend((int)command, NULL);
        return;
    }
    Class MROrigin = NSClassFromString(@"MROrigin");
    Class MRClient = NSClassFromString(@"MRClient");
    Class MRPlayerPath = NSClassFromString(@"MRPlayerPath");
    if (MROrigin && MRClient && MRPlayerPath) {
        id origin = [MROrigin localOrigin];
        id client = [[MRClient alloc] initWithBundleIdentifier:bundleID];
        id path = (origin && client) ? [[MRPlayerPath alloc] initWithOrigin:origin client:client player:nil] : nil;
        if (path) {
            sendToPath(path, command, nil);
            return;
        }
    }
    MRSend((int)command, NULL);
}

static void runCommand(NSString *line) {
    NSRange firstSpace = [line rangeOfString:@" "];
    NSString *cmd = firstSpace.location == NSNotFound ? line : [line substringToIndex:firstSpace.location];
    NSString *rest = firstSpace.location == NSNotFound ? @"" : [[line substringFromIndex:firstSpace.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    // Explicit play/pause instead of toggle: web wrappers (e.g. YouTube Music
    // WKWebView apps) often register only the play and pause remote commands.
    if ([cmd isEqualToString:@"play"]) sendTargeted(0, nil, rest);
    else if ([cmd isEqualToString:@"pause"]) sendTargeted(1, nil, rest);
    else if ([cmd isEqualToString:@"toggle"]) sendTargeted(2, nil, rest);
    else if ([cmd isEqualToString:@"next"]) sendTargeted(4, nil, rest);
    else if ([cmd isEqualToString:@"previous"]) sendTargeted(5, nil, rest);
    else if ([cmd isEqualToString:@"playBundle"]) sendToBundleID(0, rest);
    else if ([cmd isEqualToString:@"seek"] && rest.length > 0) {
        NSRange secondSpace = [rest rangeOfString:@" "];
        NSString *secStr = secondSpace.location == NSNotFound ? rest : [rest substringToIndex:secondSpace.location];
        NSString *clientKey = secondSpace.location == NSNotFound ? @"" : [[rest substringFromIndex:secondSpace.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        double seconds = secStr.doubleValue;
        sendTargeted(24, @{@"kMRMediaRemoteOptionPlaybackPosition": @(seconds)}, clientKey);
    }
    else if ([cmd isEqualToString:@"refresh"]) scheduleRefresh();
}

static void readStdin(void) {
    char buffer[512];
    ssize_t count;
    while ((count = read(STDIN_FILENO, buffer, sizeof buffer)) > 0) {
        [stdinBuffer appendBytes:buffer length:(NSUInteger)count];
    }
    if (count == 0) exit(0); // parent closed the pipe

    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSRange range;
    while ((range = [stdinBuffer rangeOfData:newline options:0 range:NSMakeRange(0, stdinBuffer.length)]).location != NSNotFound) {
        NSData *lineData = [stdinBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [stdinBuffer replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) runCommand(line);
    }
}

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) return NO;
    MRGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
    MRRegister = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSend = (MRSendFn)dlsym(handle, "MRMediaRemoteSendCommand");
    MRSetTime = (MRSetTimeFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    return MRGetInfo && MRGetIsPlaying && MRGetPID && MRRegister && MRSend && MRSetTime;
}

// Entry point called from media.pl.
void notchlite_run(void) {
    signal(SIGPIPE, SIG_IGN);
    if (!loadMediaRemote()) {
        fprintf(stderr, "MediaRemote unavailable\n");
        exit(2);
    }
    queue = dispatch_queue_create("notchlite.media", DISPATCH_QUEUE_SERIAL);
    stdinBuffer = [NSMutableData data];
    lastArtworkKeys = [NSMutableDictionary dictionary];
    activePaths = @{};

    parentPID = getppid();
    parentTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(parentTimer, DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(parentTimer, ^{
        if (getppid() != parentPID) exit(0);
    });
    dispatch_resume(parentTimer);

    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(stdinSource, ^{ @autoreleasepool { readStdin(); } });
    dispatch_resume(stdinSource);

    MRRegister(queue);
    for (NSString *name in @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemotePlayerPlaybackStateDidChangeNotification",
        @"kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteOriginNowPlayingApplicationDidChangeNotification",
    ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }
    scheduleRefresh();
    CFRunLoopRun();
}
