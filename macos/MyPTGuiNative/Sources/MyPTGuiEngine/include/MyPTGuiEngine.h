#ifndef MYPTGUI_ENGINE_H
#define MYPTGUI_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef struct MyPTGuiNativeContext MyPTGuiNativeContext;

typedef struct MyPTGuiPixelBuffer {
    unsigned char *data;
    size_t byteCount;
    int width;
    int height;
    int bytesPerRow;
} MyPTGuiPixelBuffer;

typedef struct MyPTGuiFloatPixelBuffer {
    float *data;
    size_t valueCount;
    int width;
    int height;
    int channels;
} MyPTGuiFloatPixelBuffer;

typedef void (*MyPTGuiProgressCallback)(
    const char *stage,
    double fraction,
    void *userData
);

MyPTGuiNativeContext *myptgui_create_context(void);
void myptgui_destroy_context(MyPTGuiNativeContext *context);
void myptgui_reset_projection_session(MyPTGuiNativeContext *context);

char *myptgui_engine_capabilities(void);
char *myptgui_dependency_report_json(void);
char *myptgui_metal_dylib_candidates_for_paths_json(
    const char *bundleRoot,
    const char *executablePath
);

char *myptgui_load_images(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_load_source_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_render_contact_sheet_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_run_preview_from_handles(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_run_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_refine_astro_full_resolution(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_apply_astro_refinement(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_rerender_from_control_points(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_render_projection_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_export_full_resolution(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_render_imported_project(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

#if __has_include("../Private/ImportedProjectAPI.h")
#include "../Private/ImportedProjectAPI.h"
#endif

char *myptgui_decode_raw_linear_rgb16_to_file(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);

char *myptgui_compare_tiff_rgb16_streaming(
    const char *firstPath,
    const char *secondPath
);

void myptgui_cancel(MyPTGuiNativeContext *context, unsigned long long jobId);
MyPTGuiPixelBuffer myptgui_copy_image_rgba(
    MyPTGuiNativeContext *context,
    const char *imageHandle,
    const char *requestJson
);
void myptgui_release_image(
    MyPTGuiNativeContext *context,
    const char *imageHandle
);
MyPTGuiFloatPixelBuffer myptgui_copy_image_linear_rgb(
    MyPTGuiNativeContext *context,
    const char *imageHandle
);
MyPTGuiPixelBuffer myptgui_copy_result_rgba(
    MyPTGuiNativeContext *context,
    const char *resultHandle,
    const char *requestJson
);
MyPTGuiPixelBuffer myptgui_render_projection_drag_preview_rgba(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
);
void myptgui_free_pixel_buffer(MyPTGuiPixelBuffer buffer);
void myptgui_free_float_pixel_buffer(MyPTGuiFloatPixelBuffer buffer);
void myptgui_free_string(char *value);
int myptgui_identity_matcher_characterization_self_test(void);
int myptgui_local_warp_characterization_self_test(void);
int myptgui_astro_psf_characterization_self_test(void);
int myptgui_astro_geometry_characterization_self_test(void);
int myptgui_source_ownership_characterization_self_test(void);
int myptgui_typed_request_characterization_self_test(void);
int myptgui_pts_projection_characterization_self_test(void);

#ifdef __cplusplus
}
#endif

#endif
