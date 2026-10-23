#pragma once

/* The iPad Settings pane chooses a picture mode, a frame-rate cap and which of the two overlays show; these map
   each to the environment the runtime reads at launch. Kept free of UIKit so tests/test_ios_settings.py checks the
   table on a Mac. */
typedef struct {
    const char *drawable;        /* TOTK_IOS_DRAWABLE_H: rows, "0" = the panel's native pixels */
    const char *scene_upscale;   /* TOTK_MFX_UPSCALE: MetalFX spatial scaling of the 3D scene into the canvas */
    const char *output_upscale;  /* TOTK_MFX_OUTPUT: MetalFX spatial scaling of the canvas into the drawable */
    const char *native_canvas;   /* TOTK_IOS_OUTPUT_FULL: the export-baked 2K canvas instead of 1080p */
} totk_picture_env;

typedef struct {
    const char *present_hz;      /* DM_PRESENT_HZ, NULL: leave unset */
    const char *fps;             /* DM_FPS, NULL: leave unset */
} totk_frame_env;

typedef struct {
    const char *hud_mode;        /* TOTK_HUD_MODE: "all" while either overlay is on, else "off" */
    const char *fps_overlay;     /* TOTK_FPS_OVERLAY: the status line in the picture's top-right corner */
    const char *shader_overlay;  /* TOTK_SHADER_OVERLAY: the shader and pipeline counts in the bottom-left */
} totk_hud_env;

/* mode is one of the pane's picture values; scene_upscale is the pane's own MetalFX switch and is not tied to the
   mode (the native canvas ignores it: there the game's scaler fills the canvas). 0 when mode is unknown (out is
   untouched). */
int totk_picture_env_build(const char *mode, int scene_upscale, totk_picture_env *out);
/* cap is "30", "60" or "120", the pane's only frame-rate choice. 0 when cap is not a pane value (out is untouched).
   MetalFX interpolation is not offered: it costs more GPU than the 60 fps it replaces on this class of device
   (measured here and in T5eng/nxnative_totk), and a downscaled output is not accepted by the interpolator. */
int totk_frame_env_build(const char *cap, totk_frame_env *out);
/* One switch per overlay. The runtime gates both with a single mode and draws the counts only in its "all" mode, so
   the mode follows the switches: "all" while either one is on, "off" when both are. */
void totk_hud_env_build(int status_line, int shader_counts, totk_hud_env *out);

const char *totk_picture_mode_default(void);
const char *totk_frame_cap_default(void);
