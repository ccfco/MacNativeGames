/* Keeps the game's save data in a folder the player picks in iCloud Drive (or anywhere in Files), so it outlives the
   app: deleting the app deletes Documents, not that folder. The folder is reached through a security-scoped bookmark
   stored in NSUserDefaults; a fresh install has no bookmark, so the app asks once (before the game thread starts, so a
   restore cannot race the game's own save loading). Every copy is best-effort: a failure only logs, never blocks play. */
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "runtime.h"
#include "save_backup.h"
#include "totk_ui_lang.h"

static NSString *const kBookmark = @"TOTK_BACKUP_BOOKMARK";
static NSString *const kFolderName = @"TOTK";
static NSString *const kDirectories[] = {@"save", @"game-slot"};
static const char *const kDirectoryEnvs[] = {"TOTK_PROFILE_DIR", "TOTK_GAME_SLOT_DIR"};   // main.m sets both

@interface TOTKSaveBackup () <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^pickCompletion)(BOOL);
- (void)prepareFrom:(UIViewController *)host completion:(void (^)(void))ready;
- (void)explain:(UIViewController *)host choose:(void (^)(void))choose later:(void (^)(void))later;
- (void)chooseFrom:(UIViewController *)host completion:(void (^)(BOOL))completion;
- (BOOL)adoptBookmark:(NSData *)bookmark;
- (BOOL)adopt:(NSURL *)url;
- (void)restoreIfFresh;
- (void)restoreIfFreshWithCompletion:(void (^)(void))completion;
- (void)background;
- (void)syncNow;
- (void)syncNowWithCompletion:(void (^)(void))completion;
- (NSUInteger)mirror:(NSURL *)from to:(NSURL *)to overwrite:(BOOL)overwrite;
- (NSURL *)localDirectory:(NSUInteger)i;
@end

@implementation TOTKSaveBackup {
    NSURL *root;                 // <picked folder>/TOTK, scoped for the app's lifetime
    dispatch_queue_t queue;
    volatile int stopping;       // the background task ran out: abandon the copy between files
}

+ (instancetype)shared {
    static TOTKSaveBackup *backup;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ backup = [TOTKSaveBackup new]; });
    return backup;
}

+ (BOOL)enabled {
    const char *value = getenv("TOTK_BACKUP");
    return !value || strcmp(value, "0") != 0;
}

+ (void)prepareFrom:(UIViewController *)host completion:(void (^)(void))ready {
    [[self shared] prepareFrom:host completion:ready];
}

+ (void)sync { [[self shared] syncNow]; }

- (instancetype)init {
    if ((self = [super init])) queue = dispatch_queue_create("totk.save-backup", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)prepareFrom:(UIViewController *)host completion:(void (^)(void))ready {
    if (!TOTKSaveBackup.enabled) { ready(); return; }
    __block BOOL started = NO;
    void (^done)(void) = ^{
        if (started) return;
        started = YES;
        ready();
        [self syncNow];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSTimer scheduledTimerWithTimeInterval:300 repeats:YES block:^(NSTimer *timer) {
            (void)timer; [self syncNow];
        }];
    };
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kBookmark];
    if (bookmark && [self adoptBookmark:bookmark]) {
        fprintf(stderr, "[totk-save] backup folder %s\n", root.path.UTF8String);
        [self restoreIfFreshWithCompletion:done];
        return;
    }
    [self explain:host choose:^{
        [self chooseFrom:host completion:^(BOOL picked) {
            if (picked) [self restoreIfFreshWithCompletion:done]; else done();
        }];
    } later:done];
}

/* One short explanation before the system folder picker; "later" still starts the game (a fresh install without a
   bookmark asks again next launch). */
- (void)explain:(UIViewController *)host choose:(void (^)(void))choose later:(void (^)(void))later {
    if (!host) { later(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@(TOTK_UI("存档自动备份", "Save backup"))
                                                                   message:@(TOTK_UI(
        "选择一个 iCloud Drive 文件夹，存档会自动备份过去。以后删掉这个 App，存档也还在；重装后选中同一个文件夹即可恢复。",
        "Pick a folder in iCloud Drive; saves are backed up there automatically. They survive deleting this app, and a reinstall restores them from the same folder."))
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@(TOTK_UI("选择文件夹", "Choose folder")) style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        /* Presenting while the alert is still dismissing is refused; one run-loop turn after it is gone is enough. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), choose);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@(TOTK_UI("以后再说", "Later")) style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) { (void)action; later(); }]];
    [host presentViewController:alert animated:YES completion:^{
        if (host.presentedViewController != alert) later();   // another presenter won: do not leave the game waiting
    }];
}

- (void)chooseFrom:(UIViewController *)host completion:(void (^)(BOOL))completion {
    if (!host) { completion(NO); return; }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    __block BOOL answered = NO;
    void (^finish)(BOOL) = ^(BOOL ok) {
        if (answered) return;
        answered = YES;
        self.pickCompletion = nil;
        completion(ok);
    };
    self.pickCompletion = finish;
    [host presentViewController:picker animated:YES completion:^{
        if (host.presentedViewController != picker) finish(NO);
    }];
    /* A picker that never calls back (scene torn down, app switched away) must not keep the game from starting. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        fprintf(stderr, "[totk-save] folder picker did not answer in 5 minutes; starting without a backup folder\n");
        [picker dismissViewControllerAnimated:YES completion:nil];
        finish(NO);
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *picked = urls.firstObject;
    BOOL ok = picked && [self adopt:picked];
    if (ok) {
        NSError *error = nil;
        NSData *bookmark = [picked bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                                includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        if (bookmark) [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kBookmark];
        else fprintf(stderr, "[totk-save] bookmark failed: %s\n", error.localizedDescription.UTF8String);
        fprintf(stderr, "[totk-save] backup folder %s\n", root.path.UTF8String);
    }
    void (^completion)(BOOL) = self.pickCompletion; self.pickCompletion = nil;
    if (completion) completion(ok);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    void (^completion)(BOOL) = self.pickCompletion; self.pickCompletion = nil;
    fprintf(stderr, "[totk-save] backup folder not chosen; saves stay in Documents\n");
    if (completion) completion(NO);
}

- (BOOL)adoptBookmark:(NSData *)bookmark {
    BOOL stale = NO; NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI
                                      relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if (!url) { fprintf(stderr, "[totk-save] backup folder unavailable: %s\n", error.localizedDescription.UTF8String); return NO; }
    if (![self adopt:url]) return NO;
    if (stale) {
        NSData *fresh = [url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                      includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (fresh) [NSUserDefaults.standardUserDefaults setObject:fresh forKey:kBookmark];
    }
    return YES;
}

/* The folder the player picked may be TOTK itself (a reinstall) or its parent; both land on the same place. */
- (BOOL)adopt:(NSURL *)url {
    if (![url startAccessingSecurityScopedResource]) fprintf(stderr, "[totk-save] no security scope for %s\n", url.path.UTF8String);
    root = [url.lastPathComponent isEqualToString:kFolderName] ? url : [url URLByAppendingPathComponent:kFolderName isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "[totk-save] cannot create %s: %s\n", root.path.UTF8String, error.localizedDescription.UTF8String);
        root = nil;
        return NO;
    }
    return YES;
}

- (NSURL *)documents {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

/* The game's own directories (main.m exported them): the launcher may point them elsewhere, so backup follows the env. */
- (NSURL *)localDirectory:(NSUInteger)i {
    const char *path = getenv(kDirectoryEnvs[i]);
    if (path && *path) return [NSURL fileURLWithPath:@(path) isDirectory:YES];
    return [[self documents] URLByAppendingPathComponent:kDirectories[i] isDirectory:YES];
}

/* A reinstall has empty Documents folders: copy the backup back before the game starts. Never overwrites anything.
   Off the main thread: a file iCloud has not downloaded yet can take a while, and launch must not watch-dog. */
- (void)restoreIfFreshWithCompletion:(void (^)(void))completion {
    if (!root) { completion(); return; }
    dispatch_async(queue, ^{
        self->stopping = 0;
        [self restoreIfFresh];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)restoreIfFresh {
    if (!root) return;
    for (NSUInteger i = 0; i < sizeof kDirectories / sizeof *kDirectories; i++) {
        NSURL *local = [self localDirectory:i];
        NSArray *existing = [NSFileManager.defaultManager contentsOfDirectoryAtURL:local includingPropertiesForKeys:nil options:0 error:nil];
        if (existing.count) continue;
        NSURL *saved = [root URLByAppendingPathComponent:local.lastPathComponent isDirectory:YES];
        if (![NSFileManager.defaultManager fileExistsAtPath:saved.path]) continue;
        NSUInteger copied = [self mirror:saved to:local overwrite:NO];
        fprintf(stderr, "[totk-save] restored %lu entries of %s from %s\n", (unsigned long)copied, local.lastPathComponent.UTF8String, root.path.UTF8String);
    }
}

- (void)background {
    __block UIBackgroundTaskIdentifier task = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        self->stopping = 1;
        [UIApplication.sharedApplication endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    [self syncNowWithCompletion:^{
        if (task != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)syncNow { [self syncNowWithCompletion:nil]; }

- (void)syncNowWithCompletion:(void (^)(void))completion {
    if (!root || !TOTKSaveBackup.enabled) { if (completion) completion(); return; }
    NSURL *destination = root;
    dispatch_async(queue, ^{
        self->stopping = 0;
        /* A profile the game is still writing (fs_host keeps it flagged for 3 s after the last change) would be stored
           torn; wait for the save to commit, and skip this pass if it takes longer than the wait. */
        for (int i = 0; i < 100 && runtime_fs_save_busy(); i++) usleep(50000);
        if (runtime_fs_save_busy()) {
            fprintf(stderr, "[totk-save] save still in progress; backing up on the next pass\n");
            if (completion) completion();
            return;
        }
        NSUInteger copied = 0;
        for (NSUInteger i = 0; i < sizeof kDirectories / sizeof *kDirectories; i++) {
            NSURL *from = [self localDirectory:i];
            NSURL *to = [destination URLByAppendingPathComponent:from.lastPathComponent isDirectory:YES];
            copied += [self mirror:from to:to overwrite:YES];
        }
        if (copied) fprintf(stderr, "[totk-save] backed up %lu entries to %s\n", (unsigned long)copied, destination.path.UTF8String);
        if (completion) completion();
    });
}

- (NSUInteger)mirror:(NSURL *)from to:(NSURL *)to overwrite:(BOOL)overwrite {
    if (self->stopping) return 0;
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![files fileExistsAtPath:from.path isDirectory:&directory]) return 0;
    NSError *error = nil;
    if (!directory) {
        if (!overwrite && [files fileExistsAtPath:to.path]) return 0;
        if (overwrite) {   // an unchanged file is not copied again every five minutes
            NSDictionary *source = [files attributesOfItemAtPath:from.path error:nil];
            NSDictionary *target = [files attributesOfItemAtPath:to.path error:nil];
            NSDate *sourceDate = source[NSFileModificationDate], *targetDate = target[NSFileModificationDate];
            if (sourceDate && targetDate && [source[NSFileSize] isEqual:target[NSFileSize]] &&
                [sourceDate compare:targetDate] != NSOrderedDescending) return 0;
        }
        /* Copy beside it first: a failed copy must leave the previous backup (or save) in place. */
        NSURL *temporary = [to URLByAppendingPathExtension:@"backup-tmp"];
        [files removeItemAtURL:temporary error:nil];
        if (![files copyItemAtURL:from toURL:temporary error:&error]) {
            fprintf(stderr, "[totk-save] copy %s: %s\n", to.path.UTF8String, error.localizedDescription.UTF8String);
            return 0;
        }
        BOOL ok = [files fileExistsAtPath:to.path]
                ? [files replaceItemAtURL:to withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:nil error:&error]
                : [files moveItemAtURL:temporary toURL:to error:&error];
        if (!ok) {
            fprintf(stderr, "[totk-save] replace %s: %s\n", to.path.UTF8String, error.localizedDescription.UTF8String);
            [files removeItemAtURL:temporary error:nil];
        }
        return ok ? 1 : 0;
    }
    if (![files createDirectoryAtURL:to withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "[totk-save] folder %s: %s\n", to.path.UTF8String, error.localizedDescription.UTF8String);
        return 0;
    }
    NSUInteger copied = 0;
    for (NSURL *item in [files contentsOfDirectoryAtURL:from includingPropertiesForKeys:nil options:0 error:nil] ?: @[])
        copied += [self mirror:item to:[to URLByAppendingPathComponent:item.lastPathComponent] overwrite:overwrite];
    return copied;
}

@end
