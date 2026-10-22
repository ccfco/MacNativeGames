/* The Settings pane's mode -> environment mapping (games/totk/ios/Sources/settings_map.c) without UIKit. */
#include "settings_map.h"
#include <stdio.h>
#include <string.h>

static int failures;

static void picture(const char *mode, const char *drawable, const char *scene, const char *output, const char *native) {
    totk_picture_env e;
    if (!totk_picture_env_parse(mode, &e)) { failures++; fprintf(stderr, "picture %s: not accepted\n", mode); return; }
    if (strcmp(e.drawable, drawable) || strcmp(e.scene_upscale, scene) || strcmp(e.output_upscale, output) ||
        strcmp(e.native_canvas, native)) {
        failures++;
        fprintf(stderr, "picture %s: %s/%s/%s/%s, want %s/%s/%s/%s\n", mode,
                e.drawable, e.scene_upscale, e.output_upscale, e.native_canvas, drawable, scene, output, native);
    }
}

static int wants(const char *got, const char *want) {
    if (!want) return got != NULL;
    return !got || strcmp(got, want);
}

static void frame(const char *mode, const char *hz, const char *fps, const char *interp) {
    totk_frame_env e;
    if (!totk_frame_env_parse(mode, &e)) { failures++; fprintf(stderr, "frame %s: not accepted\n", mode); return; }
    if (wants(e.present_hz, hz) || wants(e.fps, fps) || strcmp(e.interp, interp)) {
        failures++;
        fprintf(stderr, "frame %s: %s/%s/%s, want %s/%s/%s\n", mode,
                e.present_hz ? e.present_hz : "(unset)", e.fps ? e.fps : "(unset)", e.interp,
                hz ? hz : "(unset)", fps ? fps : "(unset)", interp);
    }
}

int main(void) {
    picture("720", "720", "0", "0", "0");
    picture("1080", "1080", "1", "0", "0");
    picture("mfx", "0", "1", "1", "0");
    picture("native", "0", "0", "0", "1");
    totk_picture_env p = {"keep", "keep", "keep", "keep"};
    if (totk_picture_env_parse("custom", &p) || totk_picture_env_parse(NULL, &p) || totk_picture_env_parse("", &p) ||
        strcmp(p.drawable, "keep")) {
        failures++; fprintf(stderr, "unknown picture modes must be rejected without touching the result\n");
    }

    frame("30", NULL, "30", "0");
    frame("60", "60", NULL, "0");
    frame("120", "120", NULL, "0");
    frame("interp", "120", NULL, "interp");
    totk_frame_env f = {"keep", "keep", "keep"};
    if (totk_frame_env_parse("90", &f) || totk_frame_env_parse(NULL, &f) || strcmp(f.present_hz, "keep")) {
        failures++; fprintf(stderr, "unknown frame modes must be rejected without touching the result\n");
    }
    if (strcmp(totk_picture_mode_default(), "mfx") || strcmp(totk_frame_mode_default(), "60")) {
        failures++; fprintf(stderr, "defaults are %s/%s, want mfx/60\n", totk_picture_mode_default(), totk_frame_mode_default());
    }
    if (failures) return 1;
    puts("ios settings ok");
    return 0;
}
