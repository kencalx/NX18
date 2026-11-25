// The player's captures (NX18-X2.0 captures-album.md), shared by the iPhone and Mac front ends: where they go and what they are called. The game's own data folder holds them,
// in Captures/: Documents on the iPhone and iPad (so they show in the Files app), DM_ROOT on the Mac (~/Library/Application Support/nxnative/<title ID>). A file is named by
// its local date and time only ("2026-11-25 21.04.17.png", then " 2" and on within the same second), so a name carries nothing about the player. Beam's Album reads the folder.
// The picture itself is the graphics side's (dm.h dm_gfx_capture): the game picture without the touch controls or Vitals
#pragma once
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include "dm.h"

static inline NSString *front_capture_dir(void) {
    const char *root = getenv("DM_ROOT");
    NSString *base = root && *root ? @(root) : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"Captures"];
}

// A free name in dir for a capture taken now, nil when the folder cannot be made
static inline NSString *front_capture_name(NSString *dir, NSString *ext, NSDate *now) {
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.timeZone = NSTimeZone.localTimeZone; f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *stem = [f stringFromDate:now];
    for (int n = 1; n < 100; n++) {
        NSString *name = n == 1 ? stem : [NSString stringWithFormat:@"%@ %d", stem, n];
        NSString *p = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:p] && ![NSFileManager.defaultManager fileExistsAtPath:[p stringByAppendingString:@".part"]]) return p;
    }
    return nil;
}

static void front_capture_done_(void *ctx, const char *path, int ok) {
    void (^done)(NSString *, BOOL) = (__bridge_transfer void (^)(NSString *, BOOL))ctx;
    NSString *p = @(path);
    dispatch_async(dispatch_get_main_queue(), ^{ done(p, ok != 0); });
}

// Asks for a screenshot of the next frame; done(path, ok) on the main queue. NO when one is still being taken or the folder cannot be made (done is not called then)
static inline BOOL front_capture_screenshot(void (^done)(NSString *path, BOOL ok)) {
    NSString *path = front_capture_name(front_capture_dir(), @"png", NSDate.date);
    if (!path) return NO;
    void *ctx = (__bridge_retained void *)[done copy];
    if (dm_gfx_capture(path.fileSystemRepresentation, front_capture_done_, ctx)) return YES;
    (void)(__bridge_transfer id)ctx;
    return NO;
}
