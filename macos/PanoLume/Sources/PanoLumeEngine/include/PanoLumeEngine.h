#ifndef PANOLUME_ENGINE_H
#define PANOLUME_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef struct PanoLumeContext PanoLumeContext;

typedef struct PanoLumePixelBuffer {
    unsigned char *data;
    size_t byteCount;
    int width;
    int height;
    int bytesPerRow;
} PanoLumePixelBuffer;

typedef struct PanoLumeFloatPixelBuffer {
    float *data;
    size_t valueCount;
    int width;
    int height;
    int channels;
} PanoLumeFloatPixelBuffer;

typedef void (*PanoLumeProgressCallback)(
    const char *stage,
    double fraction,
    void *userData
);

PanoLumeContext *panolume_create_context(void);
void panolume_destroy_context(PanoLumeContext *context);
void panolume_reset_projection_session(PanoLumeContext *context);

char *panolume_engine_capabilities(void);
char *panolume_dependency_report_json(void);
char *panolume_metal_dylib_candidates_for_paths_json(
    const char *bundleRoot,
    const char *executablePath
);

char *panolume_load_images(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_load_source_preview(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_render_contact_sheet_preview(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_run_preview_from_handles(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_run_preview(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_refine_astro_full_resolution(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_apply_astro_refinement(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_rerender_from_control_points(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_render_projection_preview(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_export_full_resolution(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_render_imported_project(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

#if __has_include("../Private/ImportedProjectAPI.h")
#include "../Private/ImportedProjectAPI.h"
#endif

char *panolume_decode_raw_linear_rgb16_to_file(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);

char *panolume_compare_tiff_rgb16_streaming(
    const char *firstPath,
    const char *secondPath
);

void panolume_cancel(PanoLumeContext *context, unsigned long long jobId);
PanoLumePixelBuffer panolume_copy_image_rgba(
    PanoLumeContext *context,
    const char *imageHandle,
    const char *requestJson
);
void panolume_release_image(
    PanoLumeContext *context,
    const char *imageHandle
);
PanoLumeFloatPixelBuffer panolume_copy_image_linear_rgb(
    PanoLumeContext *context,
    const char *imageHandle
);
PanoLumePixelBuffer panolume_copy_result_rgba(
    PanoLumeContext *context,
    const char *resultHandle,
    const char *requestJson
);
PanoLumePixelBuffer panolume_render_projection_drag_preview_rgba(
    PanoLumeContext *context,
    const char *requestJson,
    PanoLumeProgressCallback progress,
    void *userData
);
void panolume_free_pixel_buffer(PanoLumePixelBuffer buffer);
void panolume_free_float_pixel_buffer(PanoLumeFloatPixelBuffer buffer);
void panolume_free_string(char *value);
int panolume_identity_matcher_characterization_self_test(void);
int panolume_local_warp_characterization_self_test(void);
int panolume_astro_psf_characterization_self_test(void);
int panolume_astro_geometry_characterization_self_test(void);
int panolume_source_ownership_characterization_self_test(void);
int panolume_typed_request_characterization_self_test(void);
int panolume_pts_projection_characterization_self_test(void);

#ifdef __cplusplus
}
#endif

#endif
