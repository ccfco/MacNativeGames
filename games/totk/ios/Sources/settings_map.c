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

static const struct { const char *mode; totk_frame_env env; } FRAME[] = {
    {"30",     {NULL, "30", "0"}},
    {"60",     {"60", NULL, "0"}},
    {"120",    {"120", NULL, "0"}},
    {"interp", {"120", NULL, "interp"}},
};

int totk_picture_env_parse(const char *mode, totk_picture_env *out) {
    if (!mode) return 0;
    for (unsigned i = 0; i < sizeof PICTURE / sizeof PICTURE[0]; i++)
        if (!strcmp(PICTURE[i].mode, mode)) { *out = PICTURE[i].env; return 1; }
    return 0;
}

int totk_frame_env_parse(const char *mode, totk_frame_env *out) {
    if (!mode) return 0;
    for (unsigned i = 0; i < sizeof FRAME / sizeof FRAME[0]; i++)
        if (!strcmp(FRAME[i].mode, mode)) { *out = FRAME[i].env; return 1; }
    return 0;
}

const char *totk_picture_mode_default(void) { return "mfx"; }
const char *totk_frame_mode_default(void) { return "60"; }
