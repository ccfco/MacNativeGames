#include "settings_map.h"
#include <string.h>

/* 720p is the coolest mode, so it also turns the scene upscale off. Native 2K follows the Mac's key 3: the game's own
   scaler takes the scene to the native canvas, and no MetalFX stage runs (the pane is hottest already). */
static const struct { const char *mode; totk_picture_env env; } PICTURE[] = {
    {"720",    {"720", "0", "0", "0"}},
    {"1080",   {"1080", "1", "0", "0"}},
    {"mfx",    {"0", "1", "1", "0"}},
    {"native", {"0", "0", "0", "1"}},
};

int totk_picture_env_parse(const char *mode, totk_picture_env *out) {
    if (!mode) return 0;
    for (unsigned i = 0; i < sizeof PICTURE / sizeof PICTURE[0]; i++)
        if (!strcmp(PICTURE[i].mode, mode)) { *out = PICTURE[i].env; return 1; }
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

const char *totk_picture_mode_default(void) { return "mfx"; }
const char *totk_frame_cap_default(void) { return "60"; }
