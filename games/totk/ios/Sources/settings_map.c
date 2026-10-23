#include "settings_map.h"
#include <string.h>

/* The picture mode owns the canvas only: drawable height, output MetalFX and the baked native canvas. Whether the 3D
   scene is upscaled on its way into that canvas is the pane's own switch (TOTK_MFX_UPSCALE), so 960x540 can be
   sharpened into 720p without changing the mode. Native 2K follows the Mac's key 3: the game's own scaler takes the
   scene to the native canvas, so the switch has nothing to do there and stays off. */
static const struct { const char *mode; totk_picture_env env; } PICTURE[] = {
    {"720",    {"720", "0", "0", "0"}},
    {"1080",   {"1080", "0", "0", "0"}},
    {"mfx",    {"0", "0", "1", "0"}},
    {"native", {"0", "0", "0", "1"}},
};

int totk_picture_env_build(const char *mode, int scene_upscale, totk_picture_env *out) {
    if (!mode) return 0;
    for (unsigned i = 0; i < sizeof PICTURE / sizeof PICTURE[0]; i++) {
        if (strcmp(PICTURE[i].mode, mode)) continue;
        totk_picture_env e = PICTURE[i].env;
        e.scene_upscale = !strcmp(e.native_canvas, "1") ? "0" : (scene_upscale ? "1" : "0");
        *out = e;
        return 1;
    }
    return 0;
}

int totk_frame_env_build(const char *cap, int interpolate, totk_frame_env *out) {
    if (!cap) return 0;
    totk_frame_env e;
    if (!strcmp(cap, "30"))
        e = interpolate ? (totk_frame_env){"60", NULL, "interp30"} : (totk_frame_env){NULL, "30", "0"};
    else if (!strcmp(cap, "60"))
        e = interpolate ? (totk_frame_env){"120", NULL, "interp"} : (totk_frame_env){"60", NULL, "0"};
    else if (!strcmp(cap, "120"))
        e = (totk_frame_env){"120", NULL, "0"};   /* one generated frame cannot exceed the panel */
    else return 0;
    *out = e;
    return 1;
}

/* The pane's default: 720p with the 960x540 scene is the only combination that keeps 60 fps for a while on an iPad
   before the SoC throttles, and it is the coolest (measured 2026-10-23: GPU 12.9 ms at 960x540 against 26 ms at
   1280x720 on the same draw count). Must match Root.plist's DefaultValue; tests/test_ios_settings.py checks that. */
const char *totk_picture_mode_default(void) { return "720"; }
const char *totk_frame_cap_default(void) { return "60"; }

/* The runtime gates both overlays with one mode and draws the counts only in "all" (gfx/nvn/fps_overlay.c), so the
   pane's two switches fold back into that mode here instead of leaving a third state the player cannot see. */
void totk_hud_env_build(int status_line, int shader_counts, totk_hud_env *out) {
    out->hud_mode = status_line || shader_counts ? "all" : "off";
    out->fps_overlay = status_line ? "1" : "0";
    out->shader_overlay = shader_counts ? "1" : "0";
}
