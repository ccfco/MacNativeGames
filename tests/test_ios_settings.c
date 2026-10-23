/* The Settings pane's mode -> environment mapping (games/totk/ios/Sources/settings_map.c) without UIKit. */
#include "settings_map.h"
#include <stdio.h>
#include <string.h>

static int failures;

static void picture(const char *mode, int upscale, const char *drawable, const char *scene, const char *output,
                    const char *native) {
    totk_picture_env e;
    if (!totk_picture_env_build(mode, upscale, &e)) {
        failures++; fprintf(stderr, "picture %s/%d: not accepted\n", mode, upscale); return;
    }
    if (strcmp(e.drawable, drawable) || strcmp(e.scene_upscale, scene) || strcmp(e.output_upscale, output) ||
        strcmp(e.native_canvas, native)) {
        failures++;
        fprintf(stderr, "picture %s/%d: %s/%s/%s/%s, want %s/%s/%s/%s\n", mode, upscale,
                e.drawable, e.scene_upscale, e.output_upscale, e.native_canvas, drawable, scene, output, native);
    }
}

static int wants(const char *got, const char *want) {
    if (!want) return got != NULL;
    return !got || strcmp(got, want);
}

static void frame(const char *cap, int interp, const char *hz, const char *fps, const char *mfx) {
    totk_frame_env e;
    if (!totk_frame_env_build(cap, interp, &e)) { failures++; fprintf(stderr, "frame %s/%d: not accepted\n", cap, interp); return; }
    if (wants(e.present_hz, hz) || wants(e.fps, fps) || strcmp(e.interp, mfx)) {
        failures++;
        fprintf(stderr, "frame %s/%d: %s/%s/%s, want %s/%s/%s\n", cap, interp,
                e.present_hz ? e.present_hz : "(unset)", e.fps ? e.fps : "(unset)", e.interp,
                hz ? hz : "(unset)", fps ? fps : "(unset)", mfx);
    }
}

static int picture_accepts(const char *mode) {
    totk_picture_env off, on;
    return totk_picture_env_build(mode, 0, &off) && totk_picture_env_build(mode, 1, &on) &&
           off.drawable && off.scene_upscale && off.output_upscale && off.native_canvas &&
           on.drawable && on.scene_upscale && on.output_upscale && on.native_canvas;
}

static int frame_cap_accepts(const char *cap) {
    totk_frame_env off, on;
    return totk_frame_env_build(cap, 0, &off) && totk_frame_env_build(cap, 1, &on) && off.interp && on.interp;
}

static void hud(int status_line, int counts, const char *mode, const char *fps, const char *shaders) {
    totk_hud_env e;
    totk_hud_env_build(status_line, counts, &e);
    if (strcmp(e.hud_mode, mode) || strcmp(e.fps_overlay, fps) || strcmp(e.shader_overlay, shaders)) {
        failures++;
        fprintf(stderr, "hud %d/%d: %s/%s/%s, want %s/%s/%s\n", status_line, counts,
                e.hud_mode, e.fps_overlay, e.shader_overlay, mode, fps, shaders);
    }
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--picture")) {
        if (picture_accepts(argv[2])) return 0;
        fprintf(stderr, "picture %s: not accepted\n", argv[2]);
        return 1;
    }
    if (argc == 3 && !strcmp(argv[1], "--frame-cap")) {
        if (frame_cap_accepts(argv[2])) return 0;
        fprintf(stderr, "frame cap %s: not accepted\n", argv[2]);
        return 1;
    }
    if (argc == 2 && !strcmp(argv[1], "--defaults")) {
        printf("%s\n%s\n", totk_picture_mode_default(), totk_frame_cap_default());
        return 0;
    }
    if (argc != 1) {
        fprintf(stderr, "usage: %s [--picture MODE | --frame-cap CAP | --defaults]\n", argv[0]);
        return 2;
    }
    /* The scene upscale is the pane's own switch: the mode decides the canvas, the switch decides MetalFX. */
    picture("720", 0, "720", "0", "0", "0");
    picture("720", 1, "720", "1", "0", "0");
    picture("1080", 0, "1080", "0", "0", "0");
    picture("1080", 1, "1080", "1", "0", "0");
    picture("mfx", 0, "0", "0", "1", "0");
    picture("mfx", 1, "0", "1", "1", "0");
    picture("native", 0, "0", "0", "0", "1");
    picture("native", 1, "0", "0", "0", "1");   /* the game's own scaler fills the native canvas: nothing to upscale */
    totk_picture_env p = {"keep", "keep", "keep", "keep"};
    if (totk_picture_env_build("custom", 1, &p) || totk_picture_env_build(NULL, 1, &p) ||
        totk_picture_env_build("", 1, &p) || strcmp(p.drawable, "keep")) {
        failures++; fprintf(stderr, "unknown picture modes must be rejected without touching the result\n");
    }

    frame("30", 0, NULL, "30", "0");
    frame("30", 1, "60", NULL, "interp30");
    frame("60", 0, "60", NULL, "0");
    frame("60", 1, "120", NULL, "interp");
    frame("120", 0, "120", NULL, "0");
    frame("120", 1, "120", NULL, "0");
    totk_frame_env f = {"keep", "keep", "keep"};
    if (totk_frame_env_build("90", 0, &f) || totk_frame_env_build(NULL, 0, &f) || strcmp(f.present_hz, "keep")) {
        failures++; fprintf(stderr, "unknown frame caps must be rejected without touching the result\n");
    }
    /* The runtime draws the counts only in its "all" mode, so any overlay that is on has to raise the mode. */
    hud(1, 1, "all", "1", "1");
    hud(1, 0, "all", "1", "0");
    hud(0, 1, "all", "0", "1");
    hud(0, 0, "off", "0", "0");
    /* The values themselves belong to Root.plist (test_ios_settings.py compares them); here only that the defaults are
       modes the pane can actually produce. */
    if (!picture_accepts(totk_picture_mode_default()) || !frame_cap_accepts(totk_frame_cap_default())) {
        failures++; fprintf(stderr, "defaults %s/%s are not pane values\n",
                            totk_picture_mode_default(), totk_frame_cap_default());
    }
    if (failures) return 1;
    puts("ios settings ok");
    return 0;
}
