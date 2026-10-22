#pragma once

/* The iPad Settings pane chooses one picture mode and one frame-rate mode; these map each to the environment the
   runtime reads at launch. Kept free of UIKit so tests/test_ios_settings.py checks the table on a Mac. */
typedef struct {
    const char *drawable;        /* TOTK_IOS_DRAWABLE_H: rows, "0" = the panel's native pixels */
    const char *scene_upscale;   /* TOTK_MFX_UPSCALE: MetalFX spatial scaling of the 3D scene into the canvas */
    const char *output_upscale;  /* TOTK_MFX_OUTPUT: MetalFX spatial scaling of the canvas into the drawable */
    const char *native_canvas;   /* TOTK_IOS_OUTPUT_FULL: the export-baked 2K canvas instead of 1080p */
} totk_picture_env;

typedef struct {
    const char *present_hz;      /* DM_PRESENT_HZ, NULL: leave unset */
    const char *fps;             /* DM_FPS, NULL: leave unset */
    const char *interp;          /* TOTK_MFX: "0", or "interp" for half-refresh interpolation */
} totk_frame_env;

/* 1 when mode is one of the pane's values, 0 otherwise (out is untouched). */
int totk_picture_env_parse(const char *mode, totk_picture_env *out);
int totk_frame_env_parse(const char *mode, totk_frame_env *out);

const char *totk_picture_mode_default(void);
const char *totk_frame_mode_default(void);
