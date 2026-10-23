/* Snapshots the game's save data into the app's own Documents/save-backups, one folder per snapshot, and restores the
   newest one when the game starts with no save at all.

   The iOS app must not show prompts (maintainer, 2026-10-23), so there is no folder picker: the Settings pane's
   TOTK_BACKUP switch decides whether snapshots happen, and a fresh install restores silently. These backups survive
   app updates and a corrupted save; uninstalling the app deletes Documents too, so a reinstall-restore would need an
   iCloud container entitlement, which is a separate decision. The folder is visible in the Files app
   (UIFileSharingEnabled), so the player can copy it out by hand.

   Restore runs before the game thread starts (the game opens its save as it boots); snapshots run on app background,
   off the main thread, and never block play. */
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#include "save_backup.h"

static NSString *const kBackupFolder = @"save-backups";
static NSString *const kDirectories[] = {@"save", @"game-slot"};
static const char *const kDirectoryEnvs[] = {"TOTK_PROFILE_DIR", "TOTK_GAME_SLOT_DIR"};   // main.m sets both
enum { kKeepSnapshots = 3 };

static NSFileManager *files(void) { return NSFileManager.defaultManager; }

static NSString *documents(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

/* The live folder the runtime writes: its own environment variable, so this file and the game cannot disagree. */
static NSString *live_directory(NSUInteger i) {
    const char *env = getenv(kDirectoryEnvs[i]);
    return env && *env ? [NSString stringWithUTF8String:env] : [documents() stringByAppendingPathComponent:kDirectories[i]];
}

static BOOL has_files(NSString *folder) {
    for (NSString *name in [files() contentsOfDirectoryAtPath:folder error:nil] ?: @[]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [folder stringByAppendingPathComponent:name];
        if ([files() fileExistsAtPath:path]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *snapshots(void) {
    NSString *root = [documents() stringByAppendingPathComponent:kBackupFolder];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in [files() contentsOfDirectoryAtPath:root error:nil] ?: @[])
        if (![name hasPrefix:@"."]) [names addObject:name];
    return [names sortedArrayUsingSelector:@selector(compare:)];   // timestamp names: lexical order is age order
}

/* A snapshot is complete or absent: the copy lands in a dot-folder first and is renamed when every folder is in. */
static BOOL write_snapshot(NSString *root, NSString *name) {
    NSString *tmp = [root stringByAppendingPathComponent:[@"." stringByAppendingString:name]];
    [files() removeItemAtPath:tmp error:nil];
    NSError *error = nil;
    if (![files() createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "[backup] cannot create %s: %s\n", tmp.UTF8String, error.localizedDescription.UTF8String);
        return NO;
    }
    BOOL copied = NO;
    for (NSUInteger i = 0; i < sizeof kDirectories / sizeof kDirectories[0]; i++) {
        NSString *from = live_directory(i);
        if (!has_files(from)) continue;   // a folder the game has not written yet
        NSString *to = [tmp stringByAppendingPathComponent:kDirectories[i]];
        if (![files() copyItemAtPath:from toPath:to error:&error]) {
            fprintf(stderr, "[backup] copy %s failed: %s\n", from.UTF8String, error.localizedDescription.UTF8String);
            [files() removeItemAtPath:tmp error:nil];
            return NO;
        }
        copied = YES;
    }
    /* Before the first save there is nothing to keep; an empty snapshot would only push a real one out. */
    if (!copied) { [files() removeItemAtPath:tmp error:nil]; return NO; }
    if (![files() moveItemAtPath:tmp toPath:[root stringByAppendingPathComponent:name] error:&error]) {
        fprintf(stderr, "[backup] rename failed: %s\n", error.localizedDescription.UTF8String);
        [files() removeItemAtPath:tmp error:nil];
        return NO;
    }
    return YES;
}

static void prune_snapshots(void) {
    NSArray<NSString *> *all = snapshots();
    NSString *root = [documents() stringByAppendingPathComponent:kBackupFolder];
    for (NSUInteger i = 0; i + kKeepSnapshots < all.count; i++)
        [files() removeItemAtPath:[root stringByAppendingPathComponent:all[i]] error:nil];
}

/* Copies the newest snapshot into the live folders; only called when they hold no save at all. */
static BOOL restore_newest(void) {
    NSArray<NSString *> *all = snapshots();
    NSString *root = [documents() stringByAppendingPathComponent:kBackupFolder];
    NSError *error = nil;
    for (NSString *name in all.reverseObjectEnumerator) {
        NSString *snapshot = [root stringByAppendingPathComponent:name];
        BOOL restored = NO;
        for (NSUInteger i = 0; i < sizeof kDirectories / sizeof kDirectories[0]; i++) {
            NSString *from = [snapshot stringByAppendingPathComponent:kDirectories[i]];
            if (!has_files(from)) continue;
            NSString *to = live_directory(i);
            [files() removeItemAtPath:to error:nil];
            if (![files() copyItemAtPath:from toPath:to error:&error]) {
                fprintf(stderr, "[backup] restore %s failed: %s\n", from.UTF8String, error.localizedDescription.UTF8String);
                return NO;
            }
            restored = YES;
        }
        if (restored) {
            fprintf(stderr, "[backup] restored snapshot %s\n", name.UTF8String);
            return YES;
        }
    }
    return NO;
}

@implementation TOTKSaveBackup

+ (BOOL)enabled {
    const char *value = getenv("TOTK_BACKUP");
    return !value || strcmp(value, "0") != 0;
}

+ (void)prepareWithCompletion:(void (^)(void))ready {
    if (!TOTKSaveBackup.enabled) { ready(); return; }
    BOOL live = NO;
    for (NSUInteger i = 0; i < sizeof kDirectories / sizeof kDirectories[0]; i++) live = live || has_files(live_directory(i));
    if (!live && snapshots().count) restore_newest();
    ready();
}

+ (void)snapshot {
    if (!TOTKSaveBackup.enabled) return;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("totk.save-backup", DISPATCH_QUEUE_SERIAL); });
    /* The app is often suspended right after this call; ask for time to finish the copy. */
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid;
    }];
    dispatch_async(queue, ^{
        NSString *root = [documents() stringByAppendingPathComponent:kBackupFolder];
        NSDateFormatter *stamp = [NSDateFormatter new];
        stamp.dateFormat = @"yyyyMMdd-HHmmss"; stamp.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        NSString *name = [stamp stringFromDate:NSDate.date];
        NSError *error = nil;
        if (![files() createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error])
            fprintf(stderr, "[backup] cannot create %s: %s\n", root.UTF8String, error.localizedDescription.UTF8String);
        else if (write_snapshot(root, name)) {
            fprintf(stderr, "[backup] snapshot %s\n", name.UTF8String);
            prune_snapshots();
        }
        if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
    });
}

@end
