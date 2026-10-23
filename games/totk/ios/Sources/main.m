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
static NSString *g_no_game_data;   // set when there is no RomFS image to play from (didFinishLaunching)
static NSString *g_seed_pack, *g_seed_unpack_to;   // a pushed shader pack to unpack before the game starts (seed_unpack)

/* The startup shaders arrive as one stream cut into 1 GiB parts (<folder>.pack.000, .001, ...; ios/tools/install_device.py
   push_seed): devicectl stops after ~25,000 of the seed's 128,000 files when it copies a folder (2026-10-23). Stream:
   "TOTKPACK1", then per file a little-endian u16 name length, the name, a u64 size and the bytes; a zero name length
   ends it. Unpacked into <folder>.tmp, renamed to <folder> when complete, the parts removed. Returns nil or the reason. */
static NSString *seed_unpack(NSString *base, NSString *dest, void (^progress)(uint64_t done, uint64_t total)) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *parts = [NSMutableArray array]; uint64_t total = 0;
    for (int i = 0;; i++) {
        NSString *p = [base stringByAppendingFormat:@".%03d", i];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil]; if (!a) break;
        [parts addObject:p]; total += a.fileSize;
    }
    if (!parts.count) return @"no pack";
    __block NSUInteger at = 0; __block FILE *f = fopen(parts[0].fileSystemRepresentation, "rb"); __block uint64_t done = 0;
    BOOL (^take)(void *, size_t) = ^BOOL(void *out, size_t n) {   // n bytes of the stream, across part boundaries
        uint8_t *o = out;
        while (n) {
            if (!f) return NO;
            size_t got = fread(o, 1, n, f); o += got; n -= got; done += got;
            if (n) { fclose(f); f = ++at < parts.count ? fopen(parts[at].fileSystemRepresentation, "rb") : NULL; }
        }
        return YES;
    };
    NSString *tmp = [dest stringByAppendingString:@".tmp"]; [fm removeItemAtPath:tmp error:nil];
    if (![fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil]) { if (f) fclose(f); return @"cannot make the folder"; }
    char magic[9]; NSString *why = nil; size_t cap = 1 << 20; uint8_t *buf = malloc(cap); uint64_t files = 0, last = 0;
    if (!take(magic, 9) || memcmp(magic, "TOTKPACK1", 9)) why = @"not a shader pack";
    while (!why) {
        uint16_t nl; if (!take(&nl, 2)) { why = @"truncated"; break; }
        if (!nl) break;
        char name[256]; uint64_t size;
        if (nl >= sizeof name || !take(name, nl)) { why = @"bad name"; break; }
        name[nl] = 0;
        if (strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..") || !take(&size, 8)) { why = @"bad entry"; break; }
        FILE *o = fopen([tmp stringByAppendingPathComponent:@(name)].fileSystemRepresentation, "wb"); if (!o) { why = @"cannot write"; break; }
        while (size && !why) { size_t n = size < cap ? (size_t)size : cap; if (!take(buf, n) || fwrite(buf, 1, n, o) != n) why = @"truncated or disk full"; size -= n; }
        fclose(o); files++;
        if (progress && done - last > (32u << 20)) { last = done; progress(done, total); }
    }
    free(buf); if (f) fclose(f);
    if (why) { [fm removeItemAtPath:tmp error:nil]; return why; }
    [fm removeItemAtPath:dest error:nil];
    if (![fm moveItemAtPath:tmp toPath:dest error:nil]) return @"cannot rename";
    for (NSString *p in parts) [fm removeItemAtPath:p error:nil];
    fprintf(stderr, "[totk] shader pack unpacked: %llu files, %.0f MB\n", (unsigned long long)files, total / 1048576.0);
    return nil;
}
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
    if (g_no_game_data) {
        UILabel *say = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        say.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        say.text = g_no_game_data; say.textColor = UIColor.whiteColor; say.numberOfLines = 0; say.textAlignment = NSTextAlignmentCenter;
        [self.view addSubview:say];
        return;
    }
    /* The backup folder (and a fresh install's restore) is settled before the game thread starts: the game opens its
       save as it boots, and restoring under it would race that. Without a bookmark the player picks the folder now.
       The shader pack of a fresh install is unpacked after that, on screen and off the main thread. */
    [TOTKSaveBackup prepareFrom:self completion:^{
        if (g_seed_pack) {   // shaders installed as a pack: unpack once, on screen, then start (not on the main thread: a long launch is killed)
            BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
            UILabel *say = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
            say.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            say.textColor = UIColor.whiteColor; say.numberOfLines = 0; say.textAlignment = NSTextAlignmentCenter;
            say.text = zh ? @"正在准备着色器（更新后只做一次）…" : @"Preparing the shaders (once after an update)…";
            [self.view addSubview:say];
            NSString *pack = g_seed_pack, *to = g_seed_unpack_to; g_seed_pack = nil;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                NSString *why = seed_unpack(pack, to, ^(uint64_t done, uint64_t total) {
                    dispatch_async(dispatch_get_main_queue(), ^{ say.text = [NSString stringWithFormat:zh ? @"正在准备着色器（更新后只做一次）… %d%%" : @"Preparing the shaders (once after an update)… %d%%", (int)(done * 100 / (total ? total : 1))]; });
                });
                fprintf(stderr, "[totk] shader pack: %s in %.1f s\n", why ? why.UTF8String : "ready", CFAbsoluteTimeGetCurrent() - t0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (why) { say.text = zh ? [NSString stringWithFormat:@"着色器准备失败（%@）。请在 Mac 上用 ios/tools/install_device.py 重新安装。", why]
                                             : [NSString stringWithFormat:@"Could not prepare the shaders (%@). Install again from the Mac with ios/tools/install_device.py.", why]; return; }
                    [say removeFromSuperview]; [self startGame];
                });
            });
            return;
        }
        [self startGame];
    }];
}
- (void)startGame {
    /* Playback category (PR #97): plays with the ring / silent switch off and routes to the speaker. Without an
       active session the game's CoreAudio output stays on a null sink on iOS 27 ("no device sink in use"); activating
       it in didFinishLaunching blocked the main thread before the log file was opened. Activated here, after the
       backup prompt, so a picker left open does not interrupt the player's music. Interruptions: audio_observe. */
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

/* The Settings app pane is the single source of defaults: every TOTK_* row with a DefaultValue is registered, so the
   game sees the same defaults before the player changes anything, then handed to the runtime as an environment
   variable. Plain keys use overwrite=0, so devicectl can still supply them; the picture and frame modes then overwrite
   the keys they own, because one mode must own the whole pipeline. */
static void apply_settings(void) {
    NSBundle *settings = [NSBundle bundleWithPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Settings.bundle"]];
    NSString *path = [settings pathForResource:@"Root" ofType:@"plist"];
    NSDictionary *root = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (NSDictionary *item in root[@"PreferenceSpecifiers"] ?: @[]) {
        NSString *key = item[@"Key"]; id value = item[@"DefaultValue"];
        if (key.length && [key hasPrefix:@"TOTK_"] && value) defaults[key] = value;
    }
    /* A package without the pane is broken; do not keep a second, hand-copied copy of the defaults here. Each
       consumer falls back to its own documented default (backup stays on, the picture and frame maps have theirs). */
    if (!defaults.count) fprintf(stderr, "[totk] settings: no Settings.bundle defaults; using the runtime defaults\n");
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
        /* overwrite=0: a devicectl value for a plain key still wins. The picture and frame blocks below own their keys
           and replace them. */
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
    /* The picture mode owns the canvas and the drawable; the scene upscale is its own switch, so 960x540 can be
       sharpened into 720p without changing the mode. The keys a mode owns are overwritten, never merely defaulted. */
    NSString *picture = [d stringForKey:@"TOTK_IOS_PICTURE_MODE"];
    BOOL scene_upscale_on = [d boolForKey:@"TOTK_MFX_UPSCALE"];
    totk_picture_env penv;
    totk_picture_env_build(totk_picture_mode_default(), (int)scene_upscale_on, &penv);   // fallback if the value is stale
    if (!totk_picture_env_build(picture.UTF8String, (int)scene_upscale_on, &penv)) {
        fprintf(stderr, "[totk] settings: picture mode \"%s\" is not a pane value; using %s\n",
                picture.UTF8String ?: "", totk_picture_mode_default());
        picture = [NSString stringWithUTF8String:totk_picture_mode_default()];
    }
    if (penv.native_canvas[0] == '1' && !native_canvas_supported()) {
        CGSize s = panel_size();
        fprintf(stderr, "[totk] settings: native 2K is baked for another panel (this one is %.0fx%.0f); using MetalFX 2K\n",
                s.width, s.height);
        picture = @"mfx";
        totk_picture_env_build(picture.UTF8String, (int)scene_upscale_on, &penv);
    }
    setenv("TOTK_IOS_DRAWABLE_H", penv.drawable, 1);
    setenv("TOTK_MFX_UPSCALE", penv.scene_upscale, 1);
    setenv("TOTK_MFX_OUTPUT", penv.output_upscale, 1);
    setenv("TOTK_IOS_OUTPUT_FULL", penv.native_canvas, 1);
    /* Frame rate is one choice: the cap. MetalFX interpolation is not offered on iOS (see settings_map.h). */
    NSString *cap = [d stringForKey:@"TOTK_FPS_CAP"];
    /* Older builds stored a frame mode here; "interp" was one of them. Adopt the default instead of an unknown value. */
    if ([cap isEqualToString:@"interp"]) {
        cap = [NSString stringWithUTF8String:totk_frame_cap_default()];
        [d setObject:cap forKey:@"TOTK_FPS_CAP"];
        fprintf(stderr, "[totk] settings: old frame mode interp -> %s fps\n", cap.UTF8String);
    }
    totk_frame_env fenv;
    if (!totk_frame_env_build(cap.UTF8String, &fenv)) {
        fprintf(stderr, "[totk] settings: frame cap \"%s\" is not a pane value; using %s\n",
                cap.UTF8String ?: "", totk_frame_cap_default());
        cap = [NSString stringWithUTF8String:totk_frame_cap_default()];
        [d setObject:cap forKey:@"TOTK_FPS_CAP"];
        totk_frame_env_build(cap.UTF8String, &fenv);
    }
    /* The 120 cap needs a 120 Hz panel; on a 60 Hz one run 60. */
    if (fenv.present_hz && !strcmp(fenv.present_hz, "120") && panel_max_hz() < 120) {
        fprintf(stderr, "[totk] settings: %s fps needs 120 Hz; this panel is %ld Hz, using 60\n",
                cap.UTF8String, (long)panel_max_hz());
        cap = [NSString stringWithUTF8String:totk_frame_cap_default()];
        [d setObject:cap forKey:@"TOTK_FPS_CAP"];
        totk_frame_env_build(cap.UTF8String, &fenv);
    }
    if (fenv.present_hz) setenv("DM_PRESENT_HZ", fenv.present_hz, 1); else unsetenv("DM_PRESENT_HZ");
    if (fenv.fps) setenv("DM_FPS", fenv.fps, 1); else unsetenv("DM_FPS");
    /* Interpolation stays off for players; a devicectl TOTK_MFX still wins for a measurement (overwrite 0). */
    setenv("TOTK_MFX", "0", 0);
    /* A scene stored by the old free-form pane may not be one of the pane's values any more; adopt its default
       instead of leaving a value the pane cannot represent. A valid devicectl value still wins: the loop above left
       the environment alone, so use the effective value and only overwrite an invalid one. */
    NSDictionary *scene_row = pref_row(root, @"TOTK_RENDER_RES");
    NSArray *scene_values = scene_row[@"Values"] ?: @[];
    NSString *fallback = scene_row[@"DefaultValue"] ?: @"960x540";
    NSString *storedScene = [d stringForKey:@"TOTK_RENDER_RES"];
    if (!storedScene.length) storedScene = fallback;
    const char *from_env = getenv("TOTK_RENDER_RES");
    NSString *scene = from_env && *from_env ? @(from_env) : storedScene;
    BOOL pane_values = scene_values.count > 0, env_valid = !pane_values || [scene_values containsObject:scene];
    if (!env_valid) {
        fprintf(stderr, "[totk] settings: scene \"%s\" is not a pane value; using %s\n", scene.UTF8String ?: "", storedScene.UTF8String);
        scene = storedScene;
    }
    if (pane_values && ![scene_values containsObject:scene]) {
        fprintf(stderr, "[totk] settings: stored scene \"%s\" is not a pane value; using %s\n", scene.UTF8String ?: "", fallback.UTF8String);
        scene = fallback;
        [d setObject:scene forKey:@"TOTK_RENDER_RES"];
    }
    setenv("TOTK_RENDER_RES", scene.UTF8String, env_valid ? 0 : 1);
    /* One switch per overlay: the status line in the top-right corner and the shader/pipeline counts in the bottom-left.
       The runtime gates both with one mode and draws the counts only in "all", so the mode follows the switches. */
    if (!stored[@"TOTK_FPS_OVERLAY"] && !stored[@"TOTK_SHADER_OVERLAY"] && [stored[@"TOTK_HUD_MODE"] isEqualToString:@"off"]) {
        [d setBool:NO forKey:@"TOTK_FPS_OVERLAY"];
        [d setBool:NO forKey:@"TOTK_SHADER_OVERLAY"];
        fprintf(stderr, "[totk] settings: the old status line was off -> both overlays off\n");
    }
    totk_hud_env henv;
    totk_hud_env_build((int)[d boolForKey:@"TOTK_FPS_OVERLAY"], (int)[d boolForKey:@"TOTK_SHADER_OVERLAY"], &henv);
    setenv("TOTK_HUD_MODE", henv.hud_mode, 1);
    setenv("TOTK_FPS_OVERLAY", henv.fps_overlay, 1);
    setenv("TOTK_SHADER_OVERLAY", henv.shader_overlay, 1);
    /* The keep-alive spin kernels hold the GPU clock up between frames. On a fanless iPad that buys nothing the game
       can use and only adds heat (measured: replay CPU 11-12 ms with it, 6.8-7.5 ms without), so the app starts with
       it off; a devicectl TOTK_GPU_KEEPALIVE still overrides for a measurement. */
    setenv("TOTK_GPU_KEEPALIVE", "0", 0);
    NSString *drawable = [NSString stringWithUTF8String:penv.drawable];
    /* getenv, not the stored switches: the picture mode may have overridden them. */
    fprintf(stderr, "[totk] settings: picture %s, display %s, scene %s, fps %s (hz %s, fps %s, mfx %s), aspect %s, hud %s/%s, taa %d, mfx %s/%s, full %s, keyboard %s, touch-with-keyboard %d, backup %d\n",
            picture.UTF8String ?: "mfx",
            drawable.UTF8String ?: "?",
            scene.UTF8String ?: "?",
            cap.UTF8String ?: "60",
            getenv("DM_PRESENT_HZ") ?: "-", getenv("DM_FPS") ?: "-", getenv("TOTK_MFX") ?: "-",
            [[d stringForKey:@"TOTK_ASPECT"] UTF8String] ?: "?",
            getenv("TOTK_FPS_OVERLAY") ?: "1", getenv("TOTK_SHADER_OVERLAY") ?: "1",
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
    /* The 17 GB image may live in Documents/GameData instead of the app (romfs.bin or romfs.bin.000, ...; ios/tools/
       install_device.py --game-data puts it there): a new build then installs without it, and reinstalling keeps it.
       Excluded from iCloud backups. The runtime still hashes it once against the build's pin (TOTK_ROMFS_PROOF_DIR). */
    NSString *gameData = [docs stringByAppendingPathComponent:@"GameData"];
    BOOL image = [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin"]] ||
                 [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin.000"]];
    NSString *mark = [NSString stringWithContentsOfFile:[gameData stringByAppendingPathComponent:@"romfs.sha256"] encoding:NSUTF8StringEncoding error:nil];
    BOOL copying = mark && [mark stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length != 64;   // install_device.py writes the hash last
    if (image && !copying) {
        [[NSURL fileURLWithPath:gameData isDirectory:YES] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        setenv("TOTK_ROMFS_DATA",gameData.fileSystemRepresentation,1);
    } else if (![fm fileExistsAtPath:[res stringByAppendingPathComponent:@"romfs/romfs.bin"]]) {
        /* No image to play from: said on the screen instead of the game ending at once (runtime_fail exits). */
        BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
        NSString *app = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"TOTK";   // the Files app's folder name
        g_no_game_data = copying || image
            ? [NSString stringWithFormat:(zh ? @"游戏数据还在复制到“文件 › 我的 iPhone › %@ › GameData”，复制完再打开游戏。"
                                             : @"The game data is still being copied to Files › On My iPhone › %@ › GameData. Open the game again when it is done."), app]
            : [NSString stringWithFormat:(zh ? @"没有游戏数据。请在 Mac 上用 ios/tools/install_device.py --game-data 把它复制到“文件 › 我的 iPhone › %@ › GameData”。"
                                             : @"No game data. On the Mac, copy it to Files › On My iPhone › %@ › GameData with ios/tools/install_device.py --game-data."), app];
        fprintf(stderr, "[totk] no game image: %s\n", g_no_game_data.UTF8String);
    }
    /* The startup shaders likewise (build_app.py --ios-game-data documents): install_device.py puts the seed into its own
       folder in Documents/GameData once per content and writes shader-seed.txt last ("<folder>\n<fingerprint>"), so the app
       carries none and a new build installs in seconds. Read in place like the app's own (totk_shader_seed.h); folders of
       earlier seeds are removed in the background. Without either seed the game has no shaders: said on the screen. */
    NSString *seedDir = [res stringByAppendingPathComponent:@"shader-seed"];
    NSArray<NSString *> *seedMark = [[NSString stringWithContentsOfFile:[gameData stringByAppendingPathComponent:@"shader-seed.txt"] encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
    NSString *pushedName = seedMark.count >= 2 && seedMark[1].length == 64 && [seedMark[0] hasPrefix:@"shader-seed-"] && ![seedMark[0] containsString:@"/"] ? seedMark[0] : nil;
    NSString *pushed = pushedName ? [gameData stringByAppendingPathComponent:pushedName] : nil;
    BOOL packed = pushed && ![fm fileExistsAtPath:[pushed stringByAppendingPathComponent:@"seed-manifest.json"]] &&
                  [fm fileExistsAtPath:[pushed stringByAppendingString:@".pack.000"]];
    if (packed) { g_seed_pack = [pushed stringByAppendingString:@".pack"]; g_seed_unpack_to = pushed; }   // unpacked in viewDidAppear
    if (pushed && (packed || [fm fileExistsAtPath:[pushed stringByAppendingPathComponent:@"seed-manifest.json"]])) {
        seedDir = pushed; setenv("TOTK_SHADER_SEED_PUSHED", pushed.fileSystemRepresentation, 1);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSFileManager *files = [NSFileManager new];
            for (NSString *name in [files contentsOfDirectoryAtPath:gameData error:nil] ?: @[])
                if ([name hasPrefix:@"shader-seed-"] && ![name hasPrefix:pushedName]) [files removeItemAtPath:[gameData stringByAppendingPathComponent:name] error:nil];
        });
    } else if (!g_no_game_data && ![fm fileExistsAtPath:[seedDir stringByAppendingPathComponent:@"seed-manifest.json"]]) {
        BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
        g_no_game_data = zh ? @"没有着色器。请在 Mac 上用 ios/tools/install_device.py 重新安装（会把着色器复制到手机上）。"
                            : @"No shaders. Install the game again from the Mac with ios/tools/install_device.py (it copies them to the device).";
        fprintf(stderr, "[totk] no shader seed: %s\n", g_no_game_data.UTF8String);
    }
    setenv("TOTK_OPERATION_MODE","handheld",1);
    setenv("TOTK_ROMFS_PATCHES",[res stringByAppendingPathComponent:@"romfs-patches"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PATCHES_OUT",[res stringByAppendingPathComponent:@"romfs-patches-out"].fileSystemRepresentation,1);
    setenv("TOTK_SHARED_FONTS",[res stringByAppendingPathComponent:@"shared-fonts"].fileSystemRepresentation,1);
    setenv("TOTK_SHADER_SEED_DIR",seedDir.fileSystemRepresentation,1);
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
    setenv("DM_NVN_SHMAP",[seedDir stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation,1);
    setenv("DM_MSL_DIR",seedDir.fileSystemRepresentation,1);
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
