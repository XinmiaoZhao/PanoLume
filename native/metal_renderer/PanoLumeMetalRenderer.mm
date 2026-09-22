#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#include <stdint.h>
#include <string.h>

typedef struct PanoLumeMetalRenderRequest {
    int32_t image_count;
    const float * const *images;
    const uint16_t * const *images_u16;
    int32_t image_sample_type;
    const int32_t *widths;
    const int32_t *heights;
    const float *rotations;
    const float *focals;
    const float *distortions;
    const float *principal_offsets;
    const float *local_warp_offsets;
    int32_t local_warp_columns;
    int32_t local_warp_rows;
    int32_t out_width;
    int32_t strip_height;
    int32_t global_y0;
    float offset_x;
    float offset_y;
    float scale;
    float feather_radius;
    uint16_t *output;
    uint8_t *coverage;
} PanoLumeMetalRenderRequest;

static constexpr int kPanoLumeMetalAPIVersion = 6;

typedef struct MetalCameraUniform {
    float r_inv[9];
    float focal;
    float k1;
    float k2;
    float k3;
    float p1;
    float p2;
    float principal_x;
    float principal_y;
    int32_t image_width;
    int32_t image_height;
    int32_t out_width;
    int32_t strip_height;
    int32_t global_y0;
    float offset_x;
    float offset_y;
    float scale;
    float feather_radius;
    simd_float2 local_warp[24];
    int32_t has_local_warp;
} MetalCameraUniform;

typedef struct MetalFinalizeUniform {
    int32_t out_width;
    int32_t strip_height;
} MetalFinalizeUniform;

typedef struct MetalJumpFloodUniform {
    int32_t out_width;
    int32_t strip_height;
    int32_t step;
} MetalJumpFloodUniform;

typedef struct MetalQualityAccumulateUniform {
    int32_t out_width;
    int32_t strip_height;
    float no_seed_weight;
} MetalQualityAccumulateUniform;

static NSString *g_last_error = nil;
static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLLibrary> g_library = nil;
static id<MTLComputePipelineState> g_accumulate_pipeline = nil;
static id<MTLComputePipelineState> g_accumulate_u16_pipeline = nil;
static id<MTLComputePipelineState> g_prepare_quality_pipeline = nil;
static id<MTLComputePipelineState> g_prepare_quality_u16_pipeline = nil;
static id<MTLComputePipelineState> g_jump_flood_pipeline = nil;
static id<MTLComputePipelineState> g_accumulate_quality_pipeline = nil;
static id<MTLComputePipelineState> g_finalize_pipeline = nil;
static NSCache<NSString *, id<MTLBuffer>> *g_interactive_input_buffers = nil;
static uint64_t g_interactive_session_id = 0;

static const char *kMetalSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct MetalCameraUniform {
    float r_inv[9];
    float focal;
    float k1;
    float k2;
    float k3;
    float p1;
    float p2;
    float principal_x;
    float principal_y;
    int image_width;
    int image_height;
    int out_width;
    int strip_height;
    int global_y0;
    float offset_x;
    float offset_y;
    float scale;
    float feather_radius;
    float2 local_warp[24];
    int has_local_warp;
};

struct MetalFinalizeUniform {
    int out_width;
    int strip_height;
};

struct MetalJumpFloodUniform {
    int out_width;
    int strip_height;
    int step;
};

struct MetalQualityAccumulateUniform {
    int out_width;
    int strip_height;
    float no_seed_weight;
};

static inline float cubic_weight(int slot, float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    if (slot == 0) return (1.0f - 3.0f * t + 3.0f * t2 - t3) / 6.0f;
    if (slot == 1) return (4.0f - 6.0f * t2 + 3.0f * t3) / 6.0f;
    if (slot == 2) return (1.0f + 3.0f * t + 3.0f * t2 - 3.0f * t3) / 6.0f;
    return t3 / 6.0f;
}

static inline float2 sample_local_warp(constant MetalCameraUniform &u, float x, float y) {
    if (u.has_local_warp == 0) return float2(0.0f);
    float gx = clamp(x / max(float(u.image_width - 1), 1.0f), 0.0f, 1.0f) * 5.0f;
    float gy = clamp(y / max(float(u.image_height - 1), 1.0f), 0.0f, 1.0f) * 3.0f;
    int base_x = int(floor(gx));
    int base_y = int(floor(gy));
    float tx = gx - floor(gx);
    float ty = gy - floor(gy);
    float2 displacement = float2(0.0f);
    for (int row = 0; row < 4; ++row) {
        int node_y = clamp(base_y + row - 1, 0, 3);
        float wy = cubic_weight(row, ty);
        for (int column = 0; column < 4; ++column) {
            int node_x = clamp(base_x + column - 1, 0, 5);
            displacement += u.local_warp[node_y * 6 + node_x] * wy * cubic_weight(column, tx);
        }
    }
    return displacement;
}

static inline float3 sample_rgb(device const float *image, int width, int height, float x, float y) {
    x = clamp(x, 0.0f, float(width - 1));
    y = clamp(y, 0.0f, float(height - 1));
    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int x1 = min(x0 + 1, width - 1);
    int y1 = min(y0 + 1, height - 1);
    float tx = x - float(x0);
    float ty = y - float(y0);

    int idx00 = (y0 * width + x0) * 3;
    int idx10 = (y0 * width + x1) * 3;
    int idx01 = (y1 * width + x0) * 3;
    int idx11 = (y1 * width + x1) * 3;
    float3 c00 = float3(image[idx00], image[idx00 + 1], image[idx00 + 2]);
    float3 c10 = float3(image[idx10], image[idx10 + 1], image[idx10 + 2]);
    float3 c01 = float3(image[idx01], image[idx01 + 1], image[idx01 + 2]);
    float3 c11 = float3(image[idx11], image[idx11 + 1], image[idx11 + 2]);
    return mix(mix(c00, c10, tx), mix(c01, c11, tx), ty);
}

static inline float3 sample_rgb_u16(device const ushort *image, int width, int height, float x, float y) {
    x = clamp(x, 0.0f, float(width - 1));
    y = clamp(y, 0.0f, float(height - 1));
    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int x1 = min(x0 + 1, width - 1);
    int y1 = min(y0 + 1, height - 1);
    float tx = x - float(x0);
    float ty = y - float(y0);

    int idx00 = (y0 * width + x0) * 3;
    int idx10 = (y0 * width + x1) * 3;
    int idx01 = (y1 * width + x0) * 3;
    int idx11 = (y1 * width + x1) * 3;
    constexpr float scale = 1.0f / 65535.0f;
    float3 c00 = float3(image[idx00], image[idx00 + 1], image[idx00 + 2]) * scale;
    float3 c10 = float3(image[idx10], image[idx10 + 1], image[idx10 + 2]) * scale;
    float3 c01 = float3(image[idx01], image[idx01 + 1], image[idx01 + 2]) * scale;
    float3 c11 = float3(image[idx11], image[idx11 + 1], image[idx11 + 2]) * scale;
    return mix(mix(c00, c10, tx), mix(c01, c11, tx), ty);
}

kernel void accumulate_camera(
    device const float *image [[buffer(0)]],
    device float4 *accum [[buffer(1)]],
    device float *weight_sum [[buffer(2)]],
    constant MetalCameraUniform &u [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;

    float proj_u = (float(x) - u.offset_x) / u.scale;
    float proj_v = (float(y + u.global_y0) - u.offset_y) / u.scale;
    float cos_lat = cos(proj_v);
    float3 ray = float3(cos_lat * sin(proj_u), sin(proj_v), cos_lat * cos(proj_u));

    float3 cam_ray = float3(
        u.r_inv[0] * ray.x + u.r_inv[1] * ray.y + u.r_inv[2] * ray.z,
        u.r_inv[3] * ray.x + u.r_inv[4] * ray.y + u.r_inv[5] * ray.z,
        u.r_inv[6] * ray.x + u.r_inv[7] * ray.y + u.r_inv[8] * ray.z
    );
    if (cam_ray.z <= 0.01f) {
        return;
    }

    float x_norm = cam_ray.x / cam_ray.z;
    float y_norm = cam_ray.y / cam_ray.z;
    float r2 = x_norm * x_norm + y_norm * y_norm;
    float r4 = r2 * r2;
    float r6 = r4 * r2;
    float radial = 1.0f + u.k1 * r2 + u.k2 * r4 + u.k3 * r6;
    float dx = 2.0f * u.p1 * x_norm * y_norm + u.p2 * (r2 + 2.0f * x_norm * x_norm);
    float dy = u.p1 * (r2 + 2.0f * y_norm * y_norm) + 2.0f * u.p2 * x_norm * y_norm;
    float map_x = (x_norm * radial + dx) * u.focal + u.principal_x;
    float map_y = (y_norm * radial + dy) * u.focal + u.principal_y;
    float2 local_displacement = sample_local_warp(u, map_x, map_y);
    map_x += local_displacement.x * float(u.image_width - 1);
    map_y += local_displacement.y * float(u.image_height - 1);

    if (map_x < 0.0f || map_x >= float(u.image_width - 1) ||
        map_y < 0.0f || map_y >= float(u.image_height - 1)) {
        return;
    }

    float edge = min(min(map_x, float(u.image_width - 1) - map_x),
                     min(map_y, float(u.image_height - 1) - map_y));
    float radius = max(u.feather_radius, 1.0f);
    float w = clamp(edge / radius, 0.0f, 1.0f);
    w = w * w * (3.0f - 2.0f * w);
    if (w <= 0.0f) {
        return;
    }

    float3 rgb = sample_rgb(image, u.image_width, u.image_height, map_x, map_y);
    accum[idx] += float4(rgb * w, 0.0f);
    weight_sum[idx] += w;
}

kernel void accumulate_camera_u16(
    device const ushort *image [[buffer(0)]],
    device float4 *accum [[buffer(1)]],
    device float *weight_sum [[buffer(2)]],
    constant MetalCameraUniform &u [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;
    float proj_u = (float(x) - u.offset_x) / u.scale;
    float proj_v = (float(y + u.global_y0) - u.offset_y) / u.scale;
    float cos_lat = cos(proj_v);
    float3 ray = float3(cos_lat * sin(proj_u), sin(proj_v), cos_lat * cos(proj_u));
    float3 cam_ray = float3(
        u.r_inv[0] * ray.x + u.r_inv[1] * ray.y + u.r_inv[2] * ray.z,
        u.r_inv[3] * ray.x + u.r_inv[4] * ray.y + u.r_inv[5] * ray.z,
        u.r_inv[6] * ray.x + u.r_inv[7] * ray.y + u.r_inv[8] * ray.z
    );
    if (cam_ray.z <= 0.01f) { return; }
    float x_norm = cam_ray.x / cam_ray.z;
    float y_norm = cam_ray.y / cam_ray.z;
    float r2 = x_norm * x_norm + y_norm * y_norm;
    float radial = 1.0f + u.k1 * r2 + u.k2 * r2 * r2 + u.k3 * r2 * r2 * r2;
    float dx = 2.0f * u.p1 * x_norm * y_norm + u.p2 * (r2 + 2.0f * x_norm * x_norm);
    float dy = u.p1 * (r2 + 2.0f * y_norm * y_norm) + 2.0f * u.p2 * x_norm * y_norm;
    float map_x = (x_norm * radial + dx) * u.focal + u.principal_x;
    float map_y = (y_norm * radial + dy) * u.focal + u.principal_y;
    float2 local_displacement = sample_local_warp(u, map_x, map_y);
    map_x += local_displacement.x * float(u.image_width - 1);
    map_y += local_displacement.y * float(u.image_height - 1);
    if (map_x < 0.0f || map_x >= float(u.image_width - 1) || map_y < 0.0f || map_y >= float(u.image_height - 1)) { return; }
    float edge = min(min(map_x, float(u.image_width - 1) - map_x), min(map_y, float(u.image_height - 1) - map_y));
    float radius = max(u.feather_radius, 1.0f);
    float w = clamp(edge / radius, 0.0f, 1.0f);
    w = w * w * (3.0f - 2.0f * w);
    if (w <= 0.0f) { return; }
    accum[idx] += float4(sample_rgb_u16(image, u.image_width, u.image_height, map_x, map_y) * w, 0.0f);
    weight_sum[idx] += w;
}

kernel void prepare_camera_quality(
    device const float *image [[buffer(0)]],
    device float4 *sampled [[buffer(1)]],
    device int2 *seeds [[buffer(2)]],
    constant MetalCameraUniform &u [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;

    float proj_u = (float(x) - u.offset_x) / u.scale;
    float proj_v = (float(y + u.global_y0) - u.offset_y) / u.scale;
    float cos_lat = cos(proj_v);
    float3 ray = float3(cos_lat * sin(proj_u), sin(proj_v), cos_lat * cos(proj_u));

    float3 cam_ray = float3(
        u.r_inv[0] * ray.x + u.r_inv[1] * ray.y + u.r_inv[2] * ray.z,
        u.r_inv[3] * ray.x + u.r_inv[4] * ray.y + u.r_inv[5] * ray.z,
        u.r_inv[6] * ray.x + u.r_inv[7] * ray.y + u.r_inv[8] * ray.z
    );
    if (cam_ray.z <= 0.01f) {
        sampled[idx] = float4(0.0f);
        seeds[idx] = int2(x, y);
        return;
    }

    float x_norm = cam_ray.x / cam_ray.z;
    float y_norm = cam_ray.y / cam_ray.z;
    float r2 = x_norm * x_norm + y_norm * y_norm;
    float r4 = r2 * r2;
    float r6 = r4 * r2;
    float radial = 1.0f + u.k1 * r2 + u.k2 * r4 + u.k3 * r6;
    float dx = 2.0f * u.p1 * x_norm * y_norm + u.p2 * (r2 + 2.0f * x_norm * x_norm);
    float dy = u.p1 * (r2 + 2.0f * y_norm * y_norm) + 2.0f * u.p2 * x_norm * y_norm;
    float map_x = (x_norm * radial + dx) * u.focal + u.principal_x;
    float map_y = (y_norm * radial + dy) * u.focal + u.principal_y;
    float2 local_displacement = sample_local_warp(u, map_x, map_y);
    map_x += local_displacement.x * float(u.image_width - 1);
    map_y += local_displacement.y * float(u.image_height - 1);

    if (map_x < 0.0f || map_x >= float(u.image_width - 1) ||
        map_y < 0.0f || map_y >= float(u.image_height - 1)) {
        sampled[idx] = float4(0.0f);
        seeds[idx] = int2(x, y);
        return;
    }

    sampled[idx] = float4(sample_rgb(image, u.image_width, u.image_height, map_x, map_y), 1.0f);
    seeds[idx] = int2(-1, -1);
}

kernel void prepare_camera_quality_u16(
    device const ushort *image [[buffer(0)]],
    device float4 *sampled [[buffer(1)]],
    device int2 *seeds [[buffer(2)]],
    constant MetalCameraUniform &u [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) { return; }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;
    float proj_u = (float(x) - u.offset_x) / u.scale;
    float proj_v = (float(y + u.global_y0) - u.offset_y) / u.scale;
    float cos_lat = cos(proj_v);
    float3 ray = float3(cos_lat * sin(proj_u), sin(proj_v), cos_lat * cos(proj_u));
    float3 cam_ray = float3(
        u.r_inv[0] * ray.x + u.r_inv[1] * ray.y + u.r_inv[2] * ray.z,
        u.r_inv[3] * ray.x + u.r_inv[4] * ray.y + u.r_inv[5] * ray.z,
        u.r_inv[6] * ray.x + u.r_inv[7] * ray.y + u.r_inv[8] * ray.z
    );
    if (cam_ray.z <= 0.01f) {
        sampled[idx] = float4(0.0f);
        seeds[idx] = int2(x, y);
        return;
    }
    float x_norm = cam_ray.x / cam_ray.z;
    float y_norm = cam_ray.y / cam_ray.z;
    float r2 = x_norm * x_norm + y_norm * y_norm;
    float radial = 1.0f + u.k1 * r2 + u.k2 * r2 * r2 + u.k3 * r2 * r2 * r2;
    float dx = 2.0f * u.p1 * x_norm * y_norm + u.p2 * (r2 + 2.0f * x_norm * x_norm);
    float dy = u.p1 * (r2 + 2.0f * y_norm * y_norm) + 2.0f * u.p2 * x_norm * y_norm;
    float map_x = (x_norm * radial + dx) * u.focal + u.principal_x;
    float map_y = (y_norm * radial + dy) * u.focal + u.principal_y;
    float2 local_displacement = sample_local_warp(u, map_x, map_y);
    map_x += local_displacement.x * float(u.image_width - 1);
    map_y += local_displacement.y * float(u.image_height - 1);
    if (map_x < 0.0f || map_x >= float(u.image_width - 1) || map_y < 0.0f || map_y >= float(u.image_height - 1)) {
        sampled[idx] = float4(0.0f);
        seeds[idx] = int2(x, y);
        return;
    }
    sampled[idx] = float4(sample_rgb_u16(image, u.image_width, u.image_height, map_x, map_y), 1.0f);
    seeds[idx] = int2(-1, -1);
}

kernel void jump_flood_invalid_seeds(
    device const int2 *input_seeds [[buffer(0)]],
    device int2 *output_seeds [[buffer(1)]],
    constant MetalJumpFloodUniform &u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;
    float2 pos = float2(float(x), float(y));
    int2 best = input_seeds[idx];
    float best_dist = 3.402823e38f;
    if (best.x >= 0 && best.y >= 0) {
        float2 delta = float2(float(best.x), float(best.y)) - pos;
        best_dist = dot(delta, delta);
    }

    int step = max(u.step, 1);
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            int nx = x + ox * step;
            int ny = y + oy * step;
            if (nx < 0 || nx >= u.out_width || ny < 0 || ny >= u.strip_height) {
                continue;
            }
            int2 seed = input_seeds[ny * u.out_width + nx];
            if (seed.x < 0 || seed.y < 0) {
                continue;
            }
            float2 delta = float2(float(seed.x), float(seed.y)) - pos;
            float dist = dot(delta, delta);
            if (dist < best_dist) {
                best_dist = dist;
                best = seed;
            }
        }
    }
    output_seeds[idx] = best;
}

kernel void accumulate_camera_quality(
    device const float4 *sampled [[buffer(0)]],
    device const int2 *seeds [[buffer(1)]],
    device float4 *accum [[buffer(2)]],
    device float *weight_sum [[buffer(3)]],
    constant MetalQualityAccumulateUniform &u [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    int idx = y * u.out_width + x;
    float4 sample = sampled[idx];
    if (sample.w <= 0.5f) {
        return;
    }

    int2 seed = seeds[idx];
    float w = u.no_seed_weight;
    if (seed.x >= 0 && seed.y >= 0) {
        float2 delta = float2(float(seed.x), float(seed.y)) - float2(float(x), float(y));
        w = sqrt(max(dot(delta, delta), 0.0f));
    }
    w = max(w, 1.0e-4f);
    accum[idx] += float4(sample.xyz * w, 0.0f);
    weight_sum[idx] += w;
}

kernel void finalize_camera(
    device const float4 *accum [[buffer(0)]],
    device const float *weight_sum [[buffer(1)]],
    device ushort *output [[buffer(2)]],
    device uchar *coverage [[buffer(3)]],
    constant MetalFinalizeUniform &u [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(u.out_width) || gid.y >= uint(u.strip_height)) {
        return;
    }
    int idx = int(gid.y) * u.out_width + int(gid.x);
    float w = max(weight_sum[idx], 1.0e-8f);
    float3 rgb = clamp(accum[idx].xyz / w, 0.0f, 1.0f);
    int out_idx = idx * 3;
    output[out_idx] = ushort(rgb.x * 65535.0f + 0.5f);
    output[out_idx + 1] = ushort(rgb.y * 65535.0f + 0.5f);
    output[out_idx + 2] = ushort(rgb.z * 65535.0f + 0.5f);
    coverage[idx] = weight_sum[idx] > 1.0e-8f ? uchar(255) : uchar(0);
}
)METAL";

static void set_error(NSString *message) {
    g_last_error = [message copy];
}

static bool ensure_metal(void) {
    @autoreleasepool {
        if (g_device && g_queue && g_library && g_accumulate_pipeline && g_accumulate_u16_pipeline && g_finalize_pipeline) {
            if (!g_interactive_input_buffers) {
                g_interactive_input_buffers = [[NSCache alloc] init];
                g_interactive_input_buffers.countLimit = 24;
                g_interactive_input_buffers.totalCostLimit = 512 * 1024 * 1024;
            }
            return true;
        }
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            set_error(@"No Metal device is available");
            return false;
        }
        g_queue = [g_device newCommandQueue];
        if (!g_queue) {
            set_error(@"Failed to create Metal command queue");
            return false;
        }

        NSError *error = nil;
        NSString *source = [NSString stringWithUTF8String:kMetalSource];
        g_library = [g_device newLibraryWithSource:source options:nil error:&error];
        if (!g_library) {
            set_error([NSString stringWithFormat:@"Failed to compile Metal library: %@", error]);
            return false;
        }
        id<MTLFunction> accumulate = [g_library newFunctionWithName:@"accumulate_camera"];
        id<MTLFunction> accumulate_u16 = [g_library newFunctionWithName:@"accumulate_camera_u16"];
        id<MTLFunction> finalize = [g_library newFunctionWithName:@"finalize_camera"];
        if (!accumulate || !accumulate_u16 || !finalize) {
            set_error(@"Failed to load Metal kernels");
            return false;
        }
        g_accumulate_pipeline = [g_device newComputePipelineStateWithFunction:accumulate error:&error];
        if (!g_accumulate_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create accumulate pipeline: %@", error]);
            return false;
        }
        g_accumulate_u16_pipeline = [g_device newComputePipelineStateWithFunction:accumulate_u16 error:&error];
        if (!g_accumulate_u16_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create native16 accumulate pipeline: %@", error]);
            return false;
        }
        g_finalize_pipeline = [g_device newComputePipelineStateWithFunction:finalize error:&error];
        if (!g_finalize_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create finalize pipeline: %@", error]);
            return false;
        }
        g_interactive_input_buffers = [[NSCache alloc] init];
        g_interactive_input_buffers.countLimit = 24;
        g_interactive_input_buffers.totalCostLimit = 512 * 1024 * 1024;
        g_last_error = nil;
        return true;
    }
}

static bool ensure_metal_quality(void) {
    @autoreleasepool {
        if (g_prepare_quality_pipeline && g_prepare_quality_u16_pipeline && g_jump_flood_pipeline && g_accumulate_quality_pipeline) {
            return true;
        }
        if (!ensure_metal()) {
            return false;
        }

        NSError *error = nil;
        id<MTLFunction> prepare_quality = [g_library newFunctionWithName:@"prepare_camera_quality"];
        id<MTLFunction> prepare_quality_u16 = [g_library newFunctionWithName:@"prepare_camera_quality_u16"];
        id<MTLFunction> jump_flood = [g_library newFunctionWithName:@"jump_flood_invalid_seeds"];
        id<MTLFunction> accumulate_quality = [g_library newFunctionWithName:@"accumulate_camera_quality"];
        if (!prepare_quality || !prepare_quality_u16 || !jump_flood || !accumulate_quality) {
            set_error(@"Failed to load Metal quality kernels");
            return false;
        }

        g_prepare_quality_pipeline = [g_device newComputePipelineStateWithFunction:prepare_quality error:&error];
        if (!g_prepare_quality_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create quality prepare pipeline: %@", error]);
            return false;
        }
        g_prepare_quality_u16_pipeline = [g_device newComputePipelineStateWithFunction:prepare_quality_u16 error:&error];
        if (!g_prepare_quality_u16_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create native16 quality prepare pipeline: %@", error]);
            return false;
        }
        g_jump_flood_pipeline = [g_device newComputePipelineStateWithFunction:jump_flood error:&error];
        if (!g_jump_flood_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create jump-flood pipeline: %@", error]);
            return false;
        }
        g_accumulate_quality_pipeline = [g_device newComputePipelineStateWithFunction:accumulate_quality error:&error];
        if (!g_accumulate_quality_pipeline) {
            set_error([NSString stringWithFormat:@"Failed to create quality accumulate pipeline: %@", error]);
            return false;
        }
        g_last_error = nil;
        return true;
    }
}

extern "C" int panolume_metal_api_version(void) {
    return kPanoLumeMetalAPIVersion;
}

extern "C" int panolume_metal_is_available(void) {
    return ensure_metal() ? 1 : 0;
}

extern "C" const char *panolume_metal_last_error(void) {
    if (!g_last_error) {
        return "";
    }
    return [g_last_error UTF8String];
}

extern "C" void panolume_metal_reset_interactive_cache(void) {
    @synchronized([NSCache class]) {
        [g_interactive_input_buffers removeAllObjects];
    }
}

extern "C" void panolume_metal_begin_interactive_session(uint64_t session_id) {
    @synchronized([NSCache class]) {
        if (g_interactive_session_id != session_id) {
            [g_interactive_input_buffers removeAllObjects];
            g_interactive_session_id = session_id;
        }
    }
}

extern "C" void panolume_metal_end_interactive_session(uint64_t session_id) {
    @synchronized([NSCache class]) {
        if (session_id == 0 || g_interactive_session_id == session_id) {
            [g_interactive_input_buffers removeAllObjects];
            g_interactive_session_id = 0;
        }
    }
}

static id<MTLBuffer> persistent_input_buffer(const void *source, NSUInteger length, int sampleType) {
    if (!source || length == 0) {
        return nil;
    }
    NSString *key = [NSString stringWithFormat:@"%p:%llu:%d", source, (unsigned long long)length, sampleType];
    @synchronized([NSCache class]) {
        id<MTLBuffer> cached = [g_interactive_input_buffers objectForKey:key];
        if (cached) {
            return cached;
        }
        // The engine's shared image storage is not guaranteed to be page aligned,
        // so newBufferWithBytesNoCopy would be undefined for ordinary std::vector
        // allocations. Copy once into a persistent Metal buffer and reuse it across
        // interactive frames; full-resolution buffers bypass the LRU to bound memory.
        id<MTLBuffer> created = [g_device newBufferWithBytes:source
                                                     length:length
                                                    options:MTLResourceStorageModeShared];
        if (created && length <= 64 * 1024 * 1024) {
            [g_interactive_input_buffers setObject:created forKey:key cost:length];
        }
        return created;
    }
}

static int render_camera_strip_impl(const PanoLumeMetalRenderRequest *request, bool quality) {
    @autoreleasepool {
        if (!request) {
            set_error(@"Render request is null");
            return 0;
        }
        if (!ensure_metal()) {
            return 0;
        }
        if (quality && !ensure_metal_quality()) {
            return 0;
        }
        const bool native16 = request->image_sample_type == 1;
        if (request->image_sample_type != 0 && request->image_sample_type != 1) {
            set_error(@"Render request has an unsupported image sample type");
            return 0;
        }
        if (request->image_count <= 0
            || (!native16 && !request->images)
            || (native16 && !request->images_u16)
            || !request->widths
            || !request->heights
            || !request->rotations
            || !request->focals
            || !request->distortions
            || !request->principal_offsets
            || !request->output
            || !request->coverage) {
            set_error(@"Render request has no images or output");
            return 0;
        }
        int pixel_count = request->out_width * request->strip_height;
        if (pixel_count <= 0) {
            set_error(@"Render request has invalid output dimensions");
            return 0;
        }

        NSUInteger accum_length = (NSUInteger)pixel_count * sizeof(simd_float4);
        NSUInteger weight_length = (NSUInteger)pixel_count * sizeof(float);
        id<MTLBuffer> accum = [g_device newBufferWithLength:accum_length options:MTLResourceStorageModeShared];
        id<MTLBuffer> weights = [g_device newBufferWithLength:weight_length options:MTLResourceStorageModeShared];
        if (!accum || !weights) {
            set_error(@"Failed to allocate Metal accumulation buffers");
            return 0;
        }
        memset([accum contents], 0, accum_length);
        memset([weights contents], 0, weight_length);
        [accum didModifyRange:NSMakeRange(0, accum_length)];
        [weights didModifyRange:NSMakeRange(0, weight_length)];

        id<MTLBuffer> sampled = nil;
        id<MTLBuffer> seed_a = nil;
        id<MTLBuffer> seed_b = nil;
        if (quality) {
            sampled = [g_device newBufferWithLength:accum_length options:MTLResourceStorageModeShared];
            NSUInteger seed_length = (NSUInteger)pixel_count * sizeof(simd_int2);
            seed_a = [g_device newBufferWithLength:seed_length options:MTLResourceStorageModeShared];
            seed_b = [g_device newBufferWithLength:seed_length options:MTLResourceStorageModeShared];
            if (!sampled || !seed_a || !seed_b) {
                set_error(@"Failed to allocate Metal quality buffers");
                return 0;
            }
        }

        id<MTLCommandBuffer> command_buffer = [g_queue commandBuffer];
        if (!command_buffer) {
            set_error(@"Failed to create Metal command buffer");
            return 0;
        }

        MTLSize grid = MTLSizeMake((NSUInteger)request->out_width, (NSUInteger)request->strip_height, 1);
        NSUInteger thread_width = 16;
        NSUInteger thread_height = 16;
        MTLSize threads = MTLSizeMake(thread_width, thread_height, 1);

        for (int32_t i = 0; i < request->image_count; i++) {
            int32_t width = request->widths[i];
            int32_t height = request->heights[i];
            const void *source = native16
                ? (const void *)request->images_u16[i]
                : (const void *)request->images[i];
            if (width <= 1 || height <= 1 || !source) {
                continue;
            }
            NSUInteger image_length = (NSUInteger)width * (NSUInteger)height * 3 * (native16 ? sizeof(uint16_t) : sizeof(float));
            id<MTLBuffer> image_buffer = persistent_input_buffer(
                source,
                image_length,
                request->image_sample_type
            );
            if (!image_buffer) {
                set_error(@"Failed to wrap image buffer for Metal");
                return 0;
            }

            MetalCameraUniform uniform = {};
            memset(&uniform, 0, sizeof(uniform));
            memcpy(uniform.r_inv, request->rotations + i * 9, 9 * sizeof(float));
            uniform.focal = request->focals[i];
            uniform.k1 = request->distortions[i * 5 + 0];
            uniform.k2 = request->distortions[i * 5 + 1];
            uniform.k3 = request->distortions[i * 5 + 2];
            uniform.p1 = request->distortions[i * 5 + 3];
            uniform.p2 = request->distortions[i * 5 + 4];
            uniform.principal_x = (0.5f + request->principal_offsets[i * 2 + 0]) * float(width);
            uniform.principal_y = (0.5f + request->principal_offsets[i * 2 + 1]) * float(height);
            uniform.image_width = width;
            uniform.image_height = height;
            uniform.out_width = request->out_width;
            uniform.strip_height = request->strip_height;
            uniform.global_y0 = request->global_y0;
            uniform.offset_x = request->offset_x;
            uniform.offset_y = request->offset_y;
            uniform.scale = request->scale;
            uniform.feather_radius = request->feather_radius;
            uniform.has_local_warp = request->local_warp_offsets != nullptr
                && request->local_warp_columns == 6
                && request->local_warp_rows == 4;
            if (uniform.has_local_warp) {
                const float *warp = request->local_warp_offsets + i * 24 * 2;
                for (int node = 0; node < 24; ++node) {
                    uniform.local_warp[node] = simd_make_float2(warp[node * 2], warp[node * 2 + 1]);
                }
            }

            if (!quality) {
                id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
                [encoder setComputePipelineState:native16 ? g_accumulate_u16_pipeline : g_accumulate_pipeline];
                [encoder setBuffer:image_buffer offset:0 atIndex:0];
                [encoder setBuffer:accum offset:0 atIndex:1];
                [encoder setBuffer:weights offset:0 atIndex:2];
                [encoder setBytes:&uniform length:sizeof(uniform) atIndex:3];
                [encoder dispatchThreads:grid threadsPerThreadgroup:threads];
                [encoder endEncoding];
            } else {
                id<MTLComputeCommandEncoder> prepare_encoder = [command_buffer computeCommandEncoder];
                [prepare_encoder setComputePipelineState:native16 ? g_prepare_quality_u16_pipeline : g_prepare_quality_pipeline];
                [prepare_encoder setBuffer:image_buffer offset:0 atIndex:0];
                [prepare_encoder setBuffer:sampled offset:0 atIndex:1];
                [prepare_encoder setBuffer:seed_a offset:0 atIndex:2];
                [prepare_encoder setBytes:&uniform length:sizeof(uniform) atIndex:3];
                [prepare_encoder dispatchThreads:grid threadsPerThreadgroup:threads];
                [prepare_encoder endEncoding];

                int max_dim = request->out_width > request->strip_height ? request->out_width : request->strip_height;
                int step = 1;
                while (step < max_dim) {
                    step <<= 1;
                }
                step >>= 1;

                bool current_is_a = true;
                for (; step >= 1; step >>= 1) {
                    MetalJumpFloodUniform jump_uniform;
                    jump_uniform.out_width = request->out_width;
                    jump_uniform.strip_height = request->strip_height;
                    jump_uniform.step = step;
                    id<MTLBuffer> source_seeds = current_is_a ? seed_a : seed_b;
                    id<MTLBuffer> dest_seeds = current_is_a ? seed_b : seed_a;

                    id<MTLComputeCommandEncoder> jump_encoder = [command_buffer computeCommandEncoder];
                    [jump_encoder setComputePipelineState:g_jump_flood_pipeline];
                    [jump_encoder setBuffer:source_seeds offset:0 atIndex:0];
                    [jump_encoder setBuffer:dest_seeds offset:0 atIndex:1];
                    [jump_encoder setBytes:&jump_uniform length:sizeof(jump_uniform) atIndex:2];
                    [jump_encoder dispatchThreads:grid threadsPerThreadgroup:threads];
                    [jump_encoder endEncoding];

                    current_is_a = !current_is_a;
                }

                MetalQualityAccumulateUniform quality_uniform;
                quality_uniform.out_width = request->out_width;
                quality_uniform.strip_height = request->strip_height;
                quality_uniform.no_seed_weight = (float)max_dim;
                id<MTLBuffer> final_seeds = current_is_a ? seed_a : seed_b;
                id<MTLComputeCommandEncoder> quality_encoder = [command_buffer computeCommandEncoder];
                [quality_encoder setComputePipelineState:g_accumulate_quality_pipeline];
                [quality_encoder setBuffer:sampled offset:0 atIndex:0];
                [quality_encoder setBuffer:final_seeds offset:0 atIndex:1];
                [quality_encoder setBuffer:accum offset:0 atIndex:2];
                [quality_encoder setBuffer:weights offset:0 atIndex:3];
                [quality_encoder setBytes:&quality_uniform length:sizeof(quality_uniform) atIndex:4];
                [quality_encoder dispatchThreads:grid threadsPerThreadgroup:threads];
                [quality_encoder endEncoding];
            }
        }

        NSUInteger output_length = (NSUInteger)pixel_count * 3 * sizeof(uint16_t);
        id<MTLBuffer> output_buffer = [g_device newBufferWithBytesNoCopy:(void *)request->output
                                                                   length:output_length
                                                                  options:MTLResourceStorageModeShared
                                                              deallocator:nil];
        if (!output_buffer) {
            set_error(@"Failed to wrap output buffer for Metal");
            return 0;
        }
        NSUInteger coverage_length = (NSUInteger)pixel_count * sizeof(uint8_t);
        id<MTLBuffer> coverage_buffer = [g_device newBufferWithBytesNoCopy:(void *)request->coverage
                                                                      length:coverage_length
                                                                     options:MTLResourceStorageModeShared
                                                                 deallocator:nil];
        if (!coverage_buffer) {
            set_error(@"Failed to wrap coverage buffer for Metal");
            return 0;
        }
        MetalFinalizeUniform finalize_uniform;
        finalize_uniform.out_width = request->out_width;
        finalize_uniform.strip_height = request->strip_height;
        id<MTLComputeCommandEncoder> final_encoder = [command_buffer computeCommandEncoder];
        [final_encoder setComputePipelineState:g_finalize_pipeline];
        [final_encoder setBuffer:accum offset:0 atIndex:0];
        [final_encoder setBuffer:weights offset:0 atIndex:1];
        [final_encoder setBuffer:output_buffer offset:0 atIndex:2];
        [final_encoder setBuffer:coverage_buffer offset:0 atIndex:3];
        [final_encoder setBytes:&finalize_uniform length:sizeof(finalize_uniform) atIndex:4];
        [final_encoder dispatchThreads:grid threadsPerThreadgroup:threads];
        [final_encoder endEncoding];

        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        if ([command_buffer status] != MTLCommandBufferStatusCompleted) {
            NSError *error = [command_buffer error];
            set_error([NSString stringWithFormat:@"Metal command buffer failed: %@", error]);
            return 0;
        }
        g_last_error = nil;
        return 1;
    }
}

extern "C" int panolume_metal_render_camera_strip(const PanoLumeMetalRenderRequest *request) {
    return render_camera_strip_impl(request, false);
}

extern "C" int panolume_metal_render_camera_strip_quality(const PanoLumeMetalRenderRequest *request) {
    return render_camera_strip_impl(request, true);
}
