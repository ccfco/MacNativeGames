#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include "runtime.h"
#include "dmsh_chain.h"
#include "settings_map.h"
#if __has_include("totk_ios_canvas.h")
#include "totk_ios_canvas.h"   // written by ios/tools/build_ipa.py: the canvas baked into this build
#else
#define TOTK_IOS_CANVAS_BAKED 0
#endif
#import "touch_pad.h"
#import "save_backup.h"

int totk_host_main(int argc, char **argv);
void runtime_ios_attach_layer(CAMetalLayer *layer, UIView *host);
static char *host_argv[3];
static void *run_host(void *unused) { (void)unused; return (void *)(intptr_t)totk_host_main(3, host_argv); }
/* The desktop keyboard-overlay shortcut has no counterpart on iOS. */
void runtime_shortcut_help_toggle(void) {}

@interface TOTKMetalView : UIView @end
@implementation TOTKMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface TOTKGameController : UIViewController @property(nonatomic,strong) TOTKMetalView *gameView; @end
@implementation TOTKGameController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.gameView = [[TOTKMetalView alloc] initWithFrame:self.view.bounds];
    self.gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.gameView];
    runtime_ios_attach_layer((CAMetalLayer *)self.gameView.layer, self.gameView);
    TOTKTouchPad *pad=[[TOTKTouchPad alloc] initWithFrame:self.view.bounds];pad.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:pad];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started; if (started) return; started = YES;
    /* The backup folder (and a fresh install's restore) is settled before the game thread starts: the game opens its
       save as it boots, and restoring under it would race that. Without a bookmark the player picks the folder now. */
    [TOTKSaveBackup prepareFrom:self completion:^{
        /* Playback category (PR #97): plays with the ring / silent switch off and routes to the speaker. Without an
           active session the game's CoreAudio output stays on a null sink on iOS 27 ("no device sink in use");
           activating it in didFinishLaunching blocked the main thread before the log file was opened. Activated here,
           after the backup prompt, so a picker left open does not interrupt the player's music. */
        AVAudioSession *audio = AVAudioSession.sharedInstance;
        NSError *catErr = nil, *actErr = nil;
        [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&catErr];
        BOOL activated = [audio setActive:YES error:&actErr];
        fprintf(stderr, "[totk-audio] audio session category=%s active=%d route=%s err=%s%s\n",
                audio.category.UTF8String ?: "?", (int)activated, audio.currentRoute.outputs.firstObject.portType.UTF8String ?: "?",
                catErr ? catErr.localizedDescription.UTF8String : "none", actErr ? actErr.localizedDescription.UTF8String : "");
        pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 64u << 20);
        pthread_t thread; pthread_create(&thread, &attr, run_host, NULL);
        pthread_detach(thread); pthread_attr_destroy(&attr);
    }];
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

/* iOS 27 ends apps linked against its SDK that keep the window in the app delegate (UIKit traps in
   _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption at launch), so the window belongs to a window scene. */
@interface TOTKSceneDelegate : UIResponder <UIWindowSceneDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation TOTKSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [TOTKGameController new]; [self.window makeKeyAndVisible];
}
@end

/* Game audio after interruptions (from nxnative b301431). A call, Siri or an alarm takes the audio session and the
   system stops the game's output unit; a media services reset invalidates it. Nothing started it again, so the game
   stayed silent. When an interruption ends the session is made active again and the output started
   (runtime_audio_output_restart); a reset rebuilds the output. Becoming active does the same, for an interruption
   whose "ended" never came. Becoming active also turns the idle timer off again. */
static BOOL g_audio_interrupted;
static void audio_resume(int recreate, const char *why) {
    NSError *err = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&err]) fprintf(stderr,"[totk-audio] audio session not active again (%s): %s\n",why,err.localizedDescription.UTF8String);
    g_audio_interrupted = NO; runtime_audio_output_restart(recreate);
}
static void audio_observe(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter; NSOperationQueue *main = NSOperationQueue.mainQueue;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        fprintf(stderr,"[totk-audio] audio session interruption %s\n",type == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
        if (type == AVAudioSessionInterruptionTypeBegan) g_audio_interrupted = YES; else audio_resume(0,"interruption ended");
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; fprintf(stderr,"[totk-audio] media services were reset\n"); audio_resume(1,"media services reset");
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; UIApplication.sharedApplication.idleTimerDisabled = YES;
        if (g_audio_interrupted) audio_resume(0,"became active during an interruption");
    }];
}

/* apply_settings runs before the window scene exists, so there is no scene screen to ask yet. */
static CGSize panel_size(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIScreen.mainScreen.nativeBounds.size;
#pragma clang diagnostic pop
}
static NSInteger panel_max_hz(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIScreen.mainScreen.maximumFramesPerSecond;
#pragma clang diagnostic pop
}
static NSDictionary *pref_row(NSDictionary *root, NSString *key) {
    for (NSDictionary *item in root[@"PreferenceSpecifiers"] ?: @[])
        if ([item[@"Key"] isEqual:key]) return item;
    return nil;
}

/* Native 2K is baked into the app's game code at export. Only the panel the build was baked for can show it; another
   device falls back to MetalFX 2K instead of starting a canvas it cannot size. */
static BOOL native_canvas_supported(void) {
#if TOTK_IOS_CANVAS_BAKED
    CGSize s = panel_size();
    return (MAX(s.width, s.height) == TOTK_IOS_CANVAS_W && MIN(s.width, s.height) == TOTK_IOS_CANVAS_H);
#else
    return NO;
#endif
}

/* The Settings app pane is the single source of defaults: register its DefaultValue entries so the game sees the
   same defaults before the player changes anything, then hand every key to the runtime as an environment variable.
   The pane can be edited freely; a new TOTK_* row with a DefaultValue needs no other key list here. Plain defaults are
   exported with overwrite=0, so devicectl --environment-variables still works; the picture and frame modes then
   overwrite the keys they own, because one mode must own the whole pipeline. */
static void apply_settings(void) {
    NSBundle *settings = [NSBundle bundleWithPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Settings.bundle"]];
    NSString *path = [settings pathForResource:@"Root" ofType:@"plist"];
    NSDictionary *root = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (NSDictionary *item in root[@"PreferenceSpecifiers"] ?: @[]) {
        NSString *key = item[@"Key"]; id value = item[@"DefaultValue"];
        if (key.length && [key hasPrefix:@"TOTK_"] && value) defaults[key] = value;
    }
    if (!defaults.count) {   /* packaging lost the pane: keep the display/controller defaults the pane would supply */
        defaults[@"TOTK_IOS_PICTURE_MODE"] = [NSString stringWithUTF8String:totk_picture_mode_default()];
        defaults[@"TOTK_RENDER_RES"] = @"1600x900";
        defaults[@"TOTK_FPS_CAP"] = [NSString stringWithUTF8String:totk_frame_mode_default()];
        defaults[@"TOTK_ASPECT"] = @"display";
        defaults[@"TOTK_TAA"] = @NO;
        defaults[@"TOTK_HUD_MODE"] = @"all";
        defaults[@"TOTK_GYRO"] = @YES;
        defaults[@"TOTK_RUMBLE"] = @YES;
        defaults[@"TOTK_KEYBOARD"] = @"auto";
        defaults[@"TOTK_TOUCH_WITH_KEYBOARD"] = @NO;
        defaults[@"TOTK_BACKUP"] = @YES;
    }
    fprintf(stderr, "[totk] settings: %lu defaults from %s\n", (unsigned long)defaults.count, path.UTF8String ?: "no Settings.bundle");
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:defaults];
    for (NSString *key in defaults) {
        id value = [d objectForKey:key];
        if ([value isKindOfClass:NSNumber.class]) {
            setenv(key.UTF8String, [value boolValue] ? "1" : "0", 0);
        } else if ([value isKindOfClass:NSString.class] && [value length]) {
            if ([value length] < 64) setenv(key.UTF8String, [value UTF8String], 0);
        }
        /* An empty value leaves the environment alone: an inherited devicectl value must still win. */
    }
    /* Before the pane existed, the drawable height was the only display choice. Adopt a stored choice once so an
       upgrade keeps the player's cooler or sharper setting instead of silently starting in the new default mode. */
    NSDictionary *stored = [d persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    if (!stored[@"TOTK_IOS_PICTURE_MODE"]) {
        NSString *old = stored[@"TOTK_IOS_DRAWABLE_H"];
        NSString *migrated = [old isEqualToString:@"720"] ? @"720" : [old isEqualToString:@"1080"] ? @"1080" : old ? @"mfx" : nil;
        if (migrated) {
            [d setObject:migrated forKey:@"TOTK_IOS_PICTURE_MODE"];
            fprintf(stderr, "[totk] settings: old drawable %s -> picture mode %s\n", old.UTF8String, migrated.UTF8String);
        }
    }
    /* One picture mode owns the canvas, the drawable and the two MetalFX stages. It overwrites those keys because a
       mode must not be contradicted by a key it owns. */
    NSString *picture = [d stringForKey:@"TOTK_IOS_PICTURE_MODE"];
    totk_picture_env penv;
    totk_picture_env_parse(totk_picture_mode_default(), &penv);   // a valid fallback if the stored value is stale
    if (!totk_picture_env_parse(picture.UTF8String, &penv)) {
        fprintf(stderr, "[totk] settings: picture mode \"%s\" is not a pane value; using %s\n",
                picture.UTF8String ?: "", totk_picture_mode_default());
        picture = [NSString stringWithUTF8String:totk_picture_mode_default()];
    }
    if (penv.native_canvas[0] == '1' && !native_canvas_supported()) {
        CGSize s = panel_size();
        fprintf(stderr, "[totk] settings: native 2K is baked for another panel (this one is %.0fx%.0f); using MetalFX 2K\n",
                s.width, s.height);
        picture = @"mfx";
        totk_picture_env_parse(picture.UTF8String, &penv);
    }
    setenv("TOTK_IOS_DRAWABLE_H", penv.drawable, 1);
    setenv("TOTK_MFX_UPSCALE", penv.scene_upscale, 1);
    setenv("TOTK_MFX_OUTPUT", penv.output_upscale, 1);
    setenv("TOTK_IOS_OUTPUT_FULL", penv.native_canvas, 1);
    /* Frame rate is one mode too: a mode that does not use a knob must clear it. */
    NSString *fps = [d stringForKey:@"TOTK_FPS_CAP"];
    totk_frame_env fenv;
    totk_frame_env_parse(totk_frame_mode_default(), &fenv);
    if (!totk_frame_env_parse(fps.UTF8String, &fenv)) {
        fprintf(stderr, "[totk] settings: frame mode \"%s\" is not a pane value; using %s\n",
                fps.UTF8String ?: "", totk_frame_mode_default());
        fps = [NSString stringWithUTF8String:totk_frame_mode_default()];
    }
    /* 120 and interpolation both assume a 120 Hz panel. On a 60 Hz iPhone or iPad the display link stays at 60, and
       half-refresh interpolation would run the game at 30 — fall back to the 60 mode instead. */
    if (fenv.present_hz && !strcmp(fenv.present_hz, "120") && panel_max_hz() < 120) {
        fprintf(stderr, "[totk] settings: frame mode %s needs 120 Hz; this panel is %ld Hz, using %s\n",
                fps.UTF8String, (long)panel_max_hz(), totk_frame_mode_default());
        fps = [NSString stringWithUTF8String:totk_frame_mode_default()];
        totk_frame_env_parse(fps.UTF8String, &fenv);
    }
    if (fenv.present_hz) setenv("DM_PRESENT_HZ", fenv.present_hz, 1); else unsetenv("DM_PRESENT_HZ");
    if (fenv.fps) setenv("DM_FPS", fenv.fps, 1); else unsetenv("DM_FPS");
    setenv("TOTK_MFX", fenv.interp, 1);
    /* A scene stored by the old free-form pane may not be one of the pane's values any more; adopt its default
       instead of leaving a value the pane cannot represent. */
    NSDictionary *scene_row = pref_row(root, @"TOTK_RENDER_RES");
    NSArray *scene_values = scene_row[@"Values"] ?: @[];
    NSString *scene = [d stringForKey:@"TOTK_RENDER_RES"];
    if (scene_values.count && ![scene_values containsObject:scene]) {
        NSString *fallback = scene_row[@"DefaultValue"] ?: @"1600x900";
        fprintf(stderr, "[totk] settings: scene \"%s\" is not a pane value; using %s\n", scene.UTF8String ?: "", fallback.UTF8String);
        scene = fallback;
        [d setObject:scene forKey:@"TOTK_RENDER_RES"];
    }
    if (!scene.length) scene = @"1600x900";
    setenv("TOTK_RENDER_RES", scene.UTF8String, 1);
    NSString *drawable = [NSString stringWithUTF8String:penv.drawable];
    /* getenv, not the stored switches: the picture mode may have overridden them. */
    fprintf(stderr, "[totk] settings: picture %s, display %s, scene %s, fps %s (hz %s, fps %s, mfx %s), aspect %s, hud %s, taa %d, mfx %s/%s, full %s, keyboard %s, touch-with-keyboard %d, backup %d\n",
            picture.UTF8String ?: "mfx",
            drawable.UTF8String ?: "?",
            scene.UTF8String ?: "?",
            fps.UTF8String ?: "60",
            getenv("DM_PRESENT_HZ") ?: "-", getenv("DM_FPS") ?: "-", getenv("TOTK_MFX") ?: "-",
            [[d stringForKey:@"TOTK_ASPECT"] UTF8String] ?: "?",
            [[d stringForKey:@"TOTK_HUD_MODE"] UTF8String] ?: "all",
            (int)[d boolForKey:@"TOTK_TAA"],
            getenv("TOTK_MFX_UPSCALE") ?: "1", getenv("TOTK_MFX_OUTPUT") ?: "1",
            getenv("TOTK_IOS_OUTPUT_FULL") ?: "0",
            [[d stringForKey:@"TOTK_KEYBOARD"] UTF8String] ?: "auto",
            (int)[d boolForKey:@"TOTK_TOUCH_WITH_KEYBOARD"],
            (int)[d boolForKey:@"TOTK_BACKUP"]);
}

@interface TOTKApp : UIResponder <UIApplicationDelegate> @end
@implementation TOTKApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = TOTKSceneDelegate.class; return c;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    // Controller input does not reset the idle timer; auto-lock would suspend the game mid-play or mid shader import.
    application.idleTimerDisabled = YES;
    audio_observe();
    /* The Mac launcher passes the preferred language as TOTK_LOCALE (PR #97); "zh-Hans-CN" maps to zh-Hans in services.c. */
    NSString *preferred = NSLocale.preferredLanguages.firstObject;
    if (preferred.length) setenv("TOTK_LOCALE", preferred.UTF8String, 1);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *res = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"GameData"];
    for (NSString *name in @[@"save", @"temp", @"shader-cache", @"game-slot"]) [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *log = [docs stringByAppendingPathComponent:@"log.txt"];
    if (freopen(log.fileSystemRepresentation,"w",stderr)) setvbuf(stderr,NULL,_IOLBF,0);
    apply_settings();
    setenv("TOTK_ROMFS",[res stringByAppendingPathComponent:@"romfs"].fileSystemRepresentation,1);
    setenv("TOTK_OPERATION_MODE","handheld",1);
    setenv("TOTK_ROMFS_PATCHES",[res stringByAppendingPathComponent:@"romfs-patches"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PATCHES_OUT",[res stringByAppendingPathComponent:@"romfs-patches-out"].fileSystemRepresentation,1);
    setenv("TOTK_SHARED_FONTS",[res stringByAppendingPathComponent:@"shared-fonts"].fileSystemRepresentation,1);
    setenv("TOTK_SHADER_SEED_DIR",[res stringByAppendingPathComponent:@"shader-seed"].fileSystemRepresentation,1);
    /* One folder per translation chain, as on the Mac: the runtime refuses translations of another chain, and the seed
       import keeps files that are already there. Builds before the v5 chain (2026-10-20) kept them directly in
       shader-cache; those, and other chains' folders, are only cache and are removed in the background. */
    NSString *cacheRoot = [docs stringByAppendingPathComponent:@"shader-cache"], *chainDir = @"rt-" DMSH_CHAIN;
    NSString *cache = [cacheRoot stringByAppendingPathComponent:chainDir];
    /* Test launches (devicectl --environment-variables '{"TOTK_SHADER_CACHE":"cache-test/1"}') can name another folder
       in Documents, e.g. an empty one to time a first start; it lies outside shader-cache, so the cleanup leaves it. */
    const char *testCache = getenv("TOTK_SHADER_CACHE");
    if (testCache && *testCache && !strstr(testCache, "..")) cache = [docs stringByAppendingPathComponent:@(testCache)];
    [fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("TOTK_SHADER_CACHE",cache.fileSystemRepresentation,1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSFileManager *files = [NSFileManager new]; NSUInteger removed = 0;
        for (NSString *name in [files contentsOfDirectoryAtPath:cacheRoot error:nil] ?: @[]) {
            if ([name isEqualToString:chainDir]) continue;
            if ([files removeItemAtPath:[cacheRoot stringByAppendingPathComponent:name] error:nil]) removed++;
        }
        if (removed) fprintf(stderr,"[shader-cache] removed %lu entries of earlier translation chains\n",(unsigned long)removed);
    });
    // Shaders the shared list lacks (totk_shader_contrib.h), in the Files app for players who want to send them; only the Mac asks.
    setenv("TOTK_SHADER_CONTRIB",[docs stringByAppendingPathComponent:@"shader-list-contribution.txt"].fileSystemRepresentation,1);
    setenv("DM_NVN_SHMAP",[res stringByAppendingPathComponent:@"shader-seed/shader_map.tsv"].fileSystemRepresentation,1);
    setenv("DM_MSL_DIR",[res stringByAppendingPathComponent:@"shader-seed"].fileSystemRepresentation,1);
    NSString *font = [res stringByAppendingPathComponent:@"font"]; setenv("TOTK_FONT_DIR",font.fileSystemRepresentation,1);
    // Same player environment as the Mac launcher (app/launcher.m); the bundle is read-only, so state goes to Documents.
    setenv("TOTK_PROFILE_DIR",[docs stringByAppendingPathComponent:@"save"].fileSystemRepresentation,1);
    setenv("TOTK_GAME_SLOT_DIR",[docs stringByAppendingPathComponent:@"game-slot"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PROOF_DIR",docs.fileSystemRepresentation,1);   // hash the 17 GB RomFS once, not on every launch
    for (NSString *name in @[@"TOTK_GPU_ALLOW_SUBMIT",@"TOTK_GPU_WIDEN",@"TOTK_GPU_BLOCKRT",@"TOTK_GPU_MIDCLEAR"]) setenv(name.UTF8String,"1",1);
    setenv("TOTK_SLOT_OWNER","user",0); setenv("TOTK_SLOT_PURPOSE","player",0);
    unsetenv("TOTK_AUTOLOAD");
    chdir(docs.fileSystemRepresentation);
    host_argv[0] = strdup("TOTK"); host_argv[1] = strdup(res.fileSystemRepresentation); host_argv[2] = strdup("boot");
    return YES;   // the window is made when the window scene connects (TOTKSceneDelegate)
}
@end

int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TOTKApp.class)); } }
