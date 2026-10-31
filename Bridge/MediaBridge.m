// MediaBridge — tiny helper loaded by /usr/bin/perl (an Apple-signed binary that
// is still allowed to talk to the private MediaRemote framework on macOS 15.4+).
// It streams Now Playing changes as JSON lines on stdout and executes commands
// read line by line from stdin. Exits as soon as the parent app goes away.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
typedef void (*MRSetTimeFn)(double);

static MRGetInfoFn MRGetInfo;
static MRGetBoolFn MRGetIsPlaying;
static MRGetPIDFn MRGetPID;
static MRRegisterFn MRRegister;
static MRSendFn MRSend;
static MRSetTimeFn MRSetTime;

static dispatch_queue_t queue;
static dispatch_block_t pending;
static dispatch_source_t stdinSource;
static dispatch_source_t parentTimer;
static NSMutableData *stdinBuffer;
static NSString *lastArtworkKey;
static pid_t parentPID;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id orNull(id value) { return value ?: [NSNull null]; }

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

static void publish(NSDictionary *info, BOOL playing, int pid) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (![title isKindOfClass:NSString.class] || title.length == 0) {
        emit(@{@"type": @"none"});
        lastArtworkKey = nil;
        return;
    }
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;

    NSMutableDictionary *out = [@{
        @"type": @"track",
        @"title": title,
        @"artist": orNull(artist),
        @"album": orNull(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]),
        @"duration": orNull(info[@"kMRMediaRemoteNowPlayingInfoDuration"]),
        @"elapsed": orNull(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]),
        @"rate": orNull(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]),
        @"timestamp": stamp ? @([stamp timeIntervalSince1970]) : [NSNull null],
        @"playing": @(playing),
        @"bundleID": orNull(app.bundleIdentifier),
    } mutableCopy];

    // Artwork is large: only send it when it changes for the current track.
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
        NSString *key = [NSString stringWithFormat:@"%@|%@|%lu", title, artist, (unsigned long)artwork.length];
        if (![key isEqualToString:lastArtworkKey]) {
            lastArtworkKey = key;
            out[@"artwork"] = [(thumbnail(artwork) ?: artwork) base64EncodedStringWithOptions:0];
        }
    }
    emit(out);
}

static void refresh(void) {
    MRGetInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = raw ? [(__bridge NSDictionary *)raw copy] : nil;
        MRGetIsPlaying(queue, ^(Boolean playing) {
            MRGetPID(queue, ^(int pid) {
                @autoreleasepool { publish(info, playing, pid); }
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

static void runCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    // Explicit play/pause instead of toggle: web wrappers (e.g. YouTube Music
    // WKWebView apps) often register only the play and pause remote commands.
    if ([cmd isEqualToString:@"play"]) MRSend(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSend(1, NULL);
    else if ([cmd isEqualToString:@"toggle"]) MRSend(2, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSend(4, NULL);
    else if ([cmd isEqualToString:@"previous"]) MRSend(5, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) MRSetTime(parts[1].doubleValue);
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
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }
    scheduleRefresh();
    CFRunLoopRun();
}
