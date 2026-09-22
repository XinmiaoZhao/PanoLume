#if __has_include("Private/ImportedProjectImplementation.hpp")
#include "Private/ImportedProjectImplementation.hpp"
#else
// Read-only PTGui v55 reconstruction renderer. Included once by MyPTGuiEngine.mm.

#if MYPTGUI_HAS_OPENCV_HEADERS && MYPTGUI_HAS_LIBTIFF_HEADERS

struct NativePTSVec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 1.0;
};

struct NativePTSCamera {
    std::string path;
    int width = 0;
    int height = 0;
    double focal = 0.0;
    double principalX = 0.0;
    double principalY = 0.0;
    double blendWeight = 100.0;
    std::array<double, 9> worldFromCamera{};
    std::array<double, 3> gainEV = {0.0, 0.0, 0.0};
};

struct NativePTSControlPoint {
    int imageA = -1;
    int imageB = -1;
    double xA = 0.0;
    double yA = 0.0;
    double xB = 0.0;
    double yB = 0.0;
};

struct NativePTSProjectRequest {
    std::string outputPath;
    int outputWidth = 0;
    int outputHeight = 0;
    int ownershipMapSide = 2048;
    bool fullResolutionSources = false;
    double horizontalFOV = 0.0;
    double verticalFOV = 0.0;
    int anchorImage = 0;
    int connectedPairCount = 0;
    int gainObservationCount = 0;
    std::array<double, 3> gainResidualRMSEV = {0.0, 0.0, 0.0};
    std::array<int, 3> gainClampedCameraCount = {0, 0, 0};
    std::vector<NativePTSCamera> cameras;
    std::vector<NativePTSControlPoint> controlPoints;
};

struct NativePTSROI {
    int x0 = 0;
    int y0 = 0;
    int x1 = 0;
    int y1 = 0;
    bool valid = false;
};

static std::array<double, 9> native_pts_rotation_matrix(
    double yawDegrees,
    double pitchDegrees,
    double rollDegrees
) {
    const double yaw = yawDegrees * M_PI / 180.0;
    const double pitch = pitchDegrees * M_PI / 180.0;
    const double roll = rollDegrees * M_PI / 180.0;
    const double cy = std::cos(yaw), sy = std::sin(yaw);
    const double cp = std::cos(pitch), sp = std::sin(pitch);
    const double cr = std::cos(roll), sr = std::sin(roll);
    // Ry(yaw) * Rx(pitch) * Rz(roll), validated against imported control points.
    return {
        cy * cr + sy * sp * sr, -cy * sr + sy * sp * cr, sy * cp,
        cp * sr, cp * cr, -sp,
        -sy * cr + cy * sp * sr, sy * sr + cy * sp * cr, cy * cp,
    };
}

static NativePTSVec3 native_pts_camera_to_world(
    const NativePTSCamera &camera,
    const NativePTSVec3 &value
) {
    return {
        camera.worldFromCamera[0] * value.x + camera.worldFromCamera[1] * value.y + camera.worldFromCamera[2] * value.z,
        camera.worldFromCamera[3] * value.x + camera.worldFromCamera[4] * value.y + camera.worldFromCamera[5] * value.z,
        camera.worldFromCamera[6] * value.x + camera.worldFromCamera[7] * value.y + camera.worldFromCamera[8] * value.z,
    };
}

static NativePTSVec3 native_pts_world_to_camera(
    const NativePTSCamera &camera,
    const NativePTSVec3 &value
) {
    return {
        camera.worldFromCamera[0] * value.x + camera.worldFromCamera[3] * value.y + camera.worldFromCamera[6] * value.z,
        camera.worldFromCamera[1] * value.x + camera.worldFromCamera[4] * value.y + camera.worldFromCamera[7] * value.z,
        camera.worldFromCamera[2] * value.x + camera.worldFromCamera[5] * value.y + camera.worldFromCamera[8] * value.z,
    };
}

static NativePTSVec3 native_pts_output_ray(
    double pixelX,
    double pixelY,
    int width,
    int height,
    double horizontalFOV,
    double verticalFOV
) {
    const double centerX = (static_cast<double>(width) - 1.0) * 0.5;
    const double centerY = (static_cast<double>(height) - 1.0) * 0.5;
    const double scaleX = (static_cast<double>(width) - 1.0)
        / (4.0 * std::tan(horizontalFOV * M_PI / 720.0));
    const double scaleY = (static_cast<double>(height) - 1.0)
        / (4.0 * std::tan(verticalFOV * M_PI / 720.0));
    const double planeX = (pixelX - centerX) / scaleX;
    const double planeY = (pixelY - centerY) / scaleY;
    const double quarterRadiusSquared = (planeX * planeX + planeY * planeY) * 0.25;
    const double denominator = 1.0 + quarterRadiusSquared;
    return {
        planeX / denominator,
        planeY / denominator,
        (1.0 - quarterRadiusSquared) / denominator,
    };
}

static bool native_pts_source_coordinate(
    const NativePTSCamera &camera,
    const NativePTSVec3 &worldRay,
    double &sourceX,
    double &sourceY
) {
    const NativePTSVec3 ray = native_pts_world_to_camera(camera, worldRay);
    if (!std::isfinite(ray.z) || ray.z <= 1e-10) return false;
    sourceX = camera.focal * ray.x / ray.z + camera.principalX;
    sourceY = camera.focal * ray.y / ray.z + camera.principalY;
    return sourceX >= 0.0 && sourceY >= 0.0
        && sourceX <= static_cast<double>(camera.width - 1)
        && sourceY <= static_cast<double>(camera.height - 1);
}

static bool native_pts_forward_project(
    const NativePTSCamera &camera,
    double sourceX,
    double sourceY,
    int width,
    int height,
    double horizontalFOV,
    double verticalFOV,
    double &outputX,
    double &outputY
) {
    NativePTSVec3 ray = {
        (sourceX - camera.principalX) / camera.focal,
        (sourceY - camera.principalY) / camera.focal,
        1.0,
    };
    const double length = std::sqrt(ray.x * ray.x + ray.y * ray.y + 1.0);
    ray.x /= length; ray.y /= length; ray.z /= length;
    const NativePTSVec3 world = native_pts_camera_to_world(camera, ray);
    const double radialLength = std::hypot(world.x, world.y);
    if (1.0 + world.z < 1e-8 || radialLength < 1e-15) {
        if (radialLength < 1e-15 && world.z > 0.0) {
            outputX = (static_cast<double>(width) - 1.0) * 0.5;
            outputY = (static_cast<double>(height) - 1.0) * 0.5;
            return true;
        }
        return false;
    }
    const double planeX = 2.0 * world.x / (1.0 + world.z);
    const double planeY = 2.0 * world.y / (1.0 + world.z);
    const double scaleX = (static_cast<double>(width) - 1.0)
        / (4.0 * std::tan(horizontalFOV * M_PI / 720.0));
    const double scaleY = (static_cast<double>(height) - 1.0)
        / (4.0 * std::tan(verticalFOV * M_PI / 720.0));
    outputX = (static_cast<double>(width) - 1.0) * 0.5 + planeX * scaleX;
    outputY = (static_cast<double>(height) - 1.0) * 0.5 + planeY * scaleY;
    return std::isfinite(outputX) && std::isfinite(outputY);
}

static NativePTSROI native_pts_camera_roi(
    const NativePTSCamera &camera,
    int width,
    int height,
    double horizontalFOV,
    double verticalFOV
) {
    double minimumX = std::numeric_limits<double>::infinity();
    double minimumY = std::numeric_limits<double>::infinity();
    double maximumX = -std::numeric_limits<double>::infinity();
    double maximumY = -std::numeric_limits<double>::infinity();
    bool found = false;
    constexpr int samples = 256;
    auto append = [&](double x, double y) {
        double outputX = 0.0, outputY = 0.0;
        if (!native_pts_forward_project(
                camera, x, y, width, height, horizontalFOV, verticalFOV,
                outputX, outputY
            )) return;
        if (outputX < -width || outputX > 2.0 * width
            || outputY < -height || outputY > 2.0 * height) return;
        minimumX = std::min(minimumX, outputX);
        minimumY = std::min(minimumY, outputY);
        maximumX = std::max(maximumX, outputX);
        maximumY = std::max(maximumY, outputY);
        found = true;
    };
    for (int index = 0; index <= samples; ++index) {
        const double fraction = static_cast<double>(index) / samples;
        const double x = fraction * (camera.width - 1);
        const double y = fraction * (camera.height - 1);
        append(x, 0.0); append(x, camera.height - 1.0);
        append(0.0, y); append(camera.width - 1.0, y);
    }
    append(camera.principalX, camera.principalY);
    if (!found) return {};
    const int padding = std::max(4, static_cast<int>(std::ceil(std::max(width, height) / 2048.0)));
    NativePTSROI result;
    result.x0 = std::max(0, static_cast<int>(std::floor(minimumX)) - padding);
    result.y0 = std::max(0, static_cast<int>(std::floor(minimumY)) - padding);
    result.x1 = std::min(width, static_cast<int>(std::ceil(maximumX)) + padding + 1);
    result.y1 = std::min(height, static_cast<int>(std::ceil(maximumY)) + padding + 1);
    result.valid = result.x1 > result.x0 && result.y1 > result.y0;
    return result;
}

static bool native_pts_parse_request(
    const panolume::EngineRequest &request,
    NativePTSProjectRequest &parsed,
    std::string &error
) {
    if (!request.valid()) {
        error = "invalid request JSON: " + request.error();
        return false;
    }
    if (request.boolean("diagnostics_only", false)
        || request.integer("crop_x", 0) != 0 || request.integer("crop_y", 0) != 0
        || request.string("geometry_refinement_mode", "off") != "off"
        || request.string("owner_selection_mode", "legacy") != "legacy") {
        error = "This renderer supports saved geometry, full canvas, and basic single-source ownership only.";
        return false;
    }
    parsed.outputPath = request.string("output_path");
    parsed.outputWidth = request.integer("output_width", 0);
    parsed.outputHeight = request.integer("output_height", 0);
    parsed.ownershipMapSide = std::max(256, std::min(2048, request.integer("ownership_map_side", 2048)));
    parsed.fullResolutionSources = request.boolean("full_resolution_sources", false);
    const panolume::JSONRequest project = request.object("project");
    if (!project.valid() || parsed.outputPath.empty()
        || parsed.outputWidth < 1 || parsed.outputHeight < 1) {
        error = "PTS render request is missing project, output path, or dimensions";
        return false;
    }
    if (project.string("projection") != "stereographic") {
        error = "native imported-project renderer requires stereographic projection";
        return false;
    }
    parsed.horizontalFOV = project.number("horizontal_fov_degrees", 0.0);
    parsed.verticalFOV = project.number("vertical_fov_degrees", 0.0);
    parsed.anchorImage = project.integer("anchor_image_index", 0);
    parsed.connectedPairCount = project.integer("connected_pair_count", 0);
    const auto imageObjects = project.object_array("images");
    if (imageObjects.empty() || imageObjects.size() > 2048) {
        error = "PTS render request image count is invalid";
        return false;
    }
    parsed.cameras.reserve(imageObjects.size());
    for (const auto &object : imageObjects) {
        NativePTSCamera camera;
        camera.path = object.string("path");
        camera.width = object.integer("width", 0);
        camera.height = object.integer("height", 0);
        camera.focal = object.number("focal_length_pixels", 0.0);
        camera.principalX = object.number("principal_x", camera.width * 0.5);
        camera.principalY = object.number("principal_y", camera.height * 0.5);
        camera.blendWeight = object.number("blend_weight", 100.0);
        camera.worldFromCamera = native_pts_rotation_matrix(
            object.number("yaw_degrees", 0.0),
            object.number("pitch_degrees", 0.0),
            object.number("roll_degrees", 0.0)
        );
        if (camera.path.empty() || camera.width <= 0 || camera.height <= 0
            || !std::isfinite(camera.focal) || camera.focal <= 0.0) {
            error = "PTS render request contains an invalid camera";
            return false;
        }
        parsed.cameras.push_back(std::move(camera));
    }
    for (const auto &object : project.object_array("control_points")) {
        NativePTSControlPoint point;
        point.imageA = object.integer("imageAIndex", -1);
        point.imageB = object.integer("imageBIndex", -1);
        point.xA = object.number("xA", 0.0);
        point.yA = object.number("yA", 0.0);
        point.xB = object.number("xB", 0.0);
        point.yB = object.number("yB", 0.0);
        if (point.imageA < 0 || point.imageB < 0
            || point.imageA >= static_cast<int>(parsed.cameras.size())
            || point.imageB >= static_cast<int>(parsed.cameras.size())) {
            error = "PTS render request contains a control point with an invalid endpoint";
            return false;
        }
        parsed.controlPoints.push_back(point);
    }
    if (parsed.anchorImage < 0 || parsed.anchorImage >= static_cast<int>(parsed.cameras.size())) {
        parsed.anchorImage = 0;
    }
    return true;
}

static cv::Vec3f native_pts_sample_float(
    const NativeImage &image,
    double sourceX,
    double sourceY
) {
    if (image.pixels.empty() || image.width < 1 || image.height < 1) return cv::Vec3f(0, 0, 0);
    const double x = std::max(0.0, std::min(static_cast<double>(image.width - 1), sourceX));
    const double y = std::max(0.0, std::min(static_cast<double>(image.height - 1), sourceY));
    const int x0 = static_cast<int>(std::floor(x));
    const int y0 = static_cast<int>(std::floor(y));
    const int x1 = std::min(image.width - 1, x0 + 1);
    const int y1 = std::min(image.height - 1, y0 + 1);
    const float tx = static_cast<float>(x - x0);
    const float ty = static_cast<float>(y - y0);
    auto pixel = [&](int px, int py, int channel) {
        return image.pixels[(static_cast<size_t>(py) * image.width + px) * image.channels + channel];
    };
    cv::Vec3f result;
    for (int channel = 0; channel < 3; ++channel) {
        const float top = pixel(x0, y0, channel) * (1.0f - tx) + pixel(x1, y0, channel) * tx;
        const float bottom = pixel(x0, y1, channel) * (1.0f - tx) + pixel(x1, y1, channel) * tx;
        result[channel] = top * (1.0f - ty) + bottom * ty;
    }
    return result;
}

static bool native_pts_load_thumbnails(
    MyPTGuiNativeContext *context,
    const NativePTSProjectRequest &request,
    int maxSide,
    std::vector<NativeImage> &images,
    std::string &error,
    MyPTGuiProgressCallback progress,
    void *userData,
    double progressStart,
    double progressEnd
) {
    images.clear();
    images.reserve(request.cameras.size());
    for (size_t index = 0; index < request.cameras.size(); ++index) {
        if (active_native_operation_cancelled()) {
            error = "operation cancelled";
            return false;
        }
        emit_progress(
            progress,
            userData,
            "Loading PTS source thumbnails",
            progressStart + (progressEnd - progressStart) * index / request.cameras.size()
        );
        NativeImage image = load_image_with_native_backends(
            context, request.cameras[index].path, maxSide, false
        );
        if (image.status != "loaded" || image.pixels.empty()) {
            error = "failed to load PTS source " + request.cameras[index].path + ": " + image.unsupportedReason;
            return false;
        }
        images.push_back(std::move(image));
    }
    return true;
}

static void native_pts_solve_gains(
    NativePTSProjectRequest &request,
    const std::vector<NativeImage> &thumbnails
) {
    const int count = static_cast<int>(request.cameras.size());
    if (count < 2 || request.controlPoints.empty()) return;
    struct Observation { int a; int b; std::array<double, 3> value; };
    std::vector<Observation> observations;
    observations.reserve(request.controlPoints.size());
    for (const auto &point : request.controlPoints) {
        const auto &cameraA = request.cameras[point.imageA];
        const auto &cameraB = request.cameras[point.imageB];
        const auto &imageA = thumbnails[point.imageA];
        const auto &imageB = thumbnails[point.imageB];
        const double scaleAX = static_cast<double>(imageA.width) / cameraA.width;
        const double scaleAY = static_cast<double>(imageA.height) / cameraA.height;
        const double scaleBX = static_cast<double>(imageB.width) / cameraB.width;
        const double scaleBY = static_cast<double>(imageB.height) / cameraB.height;
        const cv::Vec3f colorA = native_pts_sample_float(imageA, point.xA * scaleAX, point.yA * scaleAY);
        const cv::Vec3f colorB = native_pts_sample_float(imageB, point.xB * scaleBX, point.yB * scaleBY);
        const double luminanceA = 0.2126 * colorA[0] + 0.7152 * colorA[1] + 0.0722 * colorA[2];
        const double luminanceB = 0.2126 * colorB[0] + 0.7152 * colorB[1] + 0.0722 * colorB[2];
        if (luminanceA < 0.003 || luminanceB < 0.003 || luminanceA > 0.98 || luminanceB > 0.98) continue;
        Observation observation{point.imageA, point.imageB, {}};
        for (int channel = 0; channel < 3; ++channel) {
            observation.value[channel] = std::log2(
                std::max(0.001, static_cast<double>(colorA[channel]))
                / std::max(0.001, static_cast<double>(colorB[channel]))
            );
        }
        observations.push_back(observation);
    }
    // Control points are excellent geometric evidence but often land on stars
    // or very dark texture. Add bounded, dense overlap observations so the
    // solved gains represent the actual sky and foreground overlap areas.
    constexpr int workSide = 512;
    struct Candidate {
        int image = -1;
        cv::Vec3f color;
        double boundary = -1.0;
    };
    std::vector<Candidate> candidates;
    candidates.reserve(12);
    for (int y = 1; y < workSide; y += 2) {
        for (int x = 1; x < workSide; x += 2) {
            const NativePTSVec3 ray = native_pts_output_ray(
                x, y, workSide, workSide,
                request.horizontalFOV, request.verticalFOV
            );
            candidates.clear();
            for (int imageIndex = 0; imageIndex < count; ++imageIndex) {
                const auto &camera = request.cameras[imageIndex];
                double sourceX = 0.0, sourceY = 0.0;
                if (!native_pts_source_coordinate(camera, ray, sourceX, sourceY)) continue;
                const auto &image = thumbnails[imageIndex];
                const cv::Vec3f color = native_pts_sample_float(
                    image,
                    sourceX * static_cast<double>(image.width) / camera.width,
                    sourceY * static_cast<double>(image.height) / camera.height
                );
                const double luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
                if (luminance < 0.008 || luminance > 0.97) continue;
                const double boundary = std::min(
                    std::min(sourceX, camera.width - 1.0 - sourceX),
                    std::min(sourceY, camera.height - 1.0 - sourceY)
                ) / std::max(1.0, static_cast<double>(std::min(camera.width, camera.height)));
                candidates.push_back({imageIndex, color, boundary});
            }
            if (candidates.size() < 2) continue;
            const auto reference = std::max_element(
                candidates.begin(), candidates.end(),
                [](const Candidate &a, const Candidate &b) { return a.boundary < b.boundary; }
            );
            for (const Candidate &candidate : candidates) {
                if (candidate.image == reference->image) continue;
                Observation observation{reference->image, candidate.image, {}};
                for (int channel = 0; channel < 3; ++channel) {
                    observation.value[channel] = std::log2(
                        std::max(0.001, static_cast<double>(reference->color[channel]))
                        / std::max(0.001, static_cast<double>(candidate.color[channel]))
                    );
                }
                observations.push_back(observation);
            }
        }
    }
    request.gainObservationCount = static_cast<int>(observations.size());
    for (int channel = 0; channel < 3; ++channel) {
        cv::Mat solution(count, 1, CV_64F, cv::Scalar(0.0));
        for (int iteration = 0; iteration < 6; ++iteration) {
            cv::Mat normal(count, count, CV_64F, cv::Scalar(0.0));
            cv::Mat rhs(count, 1, CV_64F, cv::Scalar(0.0));
            for (const auto &observation : observations) {
                const double residual = solution.at<double>(observation.b)
                    - solution.at<double>(observation.a) - observation.value[channel];
                const double absolute = std::abs(residual);
                const double weight = absolute <= 0.20 ? 1.0 : 0.20 / absolute;
                normal.at<double>(observation.a, observation.a) += weight;
                normal.at<double>(observation.b, observation.b) += weight;
                normal.at<double>(observation.a, observation.b) -= weight;
                normal.at<double>(observation.b, observation.a) -= weight;
                rhs.at<double>(observation.a) -= weight * observation.value[channel];
                rhs.at<double>(observation.b) += weight * observation.value[channel];
            }
            normal.at<double>(request.anchorImage, request.anchorImage) += 1e6;
            if (!cv::solve(normal, rhs, solution, cv::DECOMP_CHOLESKY)) break;
        }
        for (int index = 0; index < count; ++index) {
            // This target contains daylight/sky and dark foreground in the
            // same overlap graph. A tighter global bound prevents one sparse
            // dark overlap from tinting an entire source; the low-frequency
            // local correction below handles the remaining spatial change.
            const double unconstrained = solution.at<double>(index);
            request.cameras[index].gainEV[channel] = std::max(-0.75, std::min(0.75, unconstrained));
            if (std::abs(unconstrained) > 0.75) {
                request.gainClampedCameraCount[channel] += 1;
            }
        }
        double weightedSquaredResidual = 0.0;
        double totalWeight = 0.0;
        for (const auto &observation : observations) {
            const double residual = request.cameras[observation.b].gainEV[channel]
                - request.cameras[observation.a].gainEV[channel]
                - observation.value[channel];
            const double absolute = std::abs(residual);
            const double weight = absolute <= 0.20 ? 1.0 : 0.20 / absolute;
            weightedSquaredResidual += weight * residual * residual;
            totalWeight += weight;
        }
        request.gainResidualRMSEV[channel] = totalWeight > 0.0
            ? std::sqrt(weightedSquaredResidual / totalWeight)
            : 0.0;
    }
}

static void native_pts_build_secondary_owners(
    const cv::Mat &owners,
    int transitionRadius,
    cv::Mat &secondary,
    cv::Mat &distance
) {
    secondary = cv::Mat(owners.rows, owners.cols, CV_16UC1, cv::Scalar(0));
    distance = cv::Mat(owners.rows, owners.cols, CV_16UC1, cv::Scalar(65535));
    const std::array<std::pair<int, int>, 4> directions = {{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}};
    for (int y = 0; y < owners.rows; ++y) {
        for (int x = 0; x < owners.cols; ++x) {
            const uint16_t owner = owners.at<uint16_t>(y, x);
            if (owner == 0) continue;
            for (const auto &direction : directions) {
                const int xx = x + direction.first, yy = y + direction.second;
                if (xx < 0 || yy < 0 || xx >= owners.cols || yy >= owners.rows) continue;
                const uint16_t other = owners.at<uint16_t>(yy, xx);
                if (other != 0 && other != owner) {
                    secondary.at<uint16_t>(y, x) = other;
                    distance.at<uint16_t>(y, x) = 0;
                    break;
                }
            }
        }
    }
    for (int layer = 1; layer <= transitionRadius; ++layer) {
        for (int y = 0; y < owners.rows; ++y) {
            for (int x = 0; x < owners.cols; ++x) {
                if (distance.at<uint16_t>(y, x) != 65535) continue;
                const uint16_t owner = owners.at<uint16_t>(y, x);
                if (owner == 0) continue;
                for (const auto &direction : directions) {
                    const int xx = x + direction.first, yy = y + direction.second;
                    if (xx < 0 || yy < 0 || xx >= owners.cols || yy >= owners.rows) continue;
                    if (owners.at<uint16_t>(yy, xx) == owner
                        && distance.at<uint16_t>(yy, xx) == layer - 1) {
                        secondary.at<uint16_t>(y, x) = secondary.at<uint16_t>(yy, xx);
                        distance.at<uint16_t>(y, x) = static_cast<uint16_t>(layer);
                        break;
                    }
                }
            }
        }
    }
}

static cv::Vec3f native_pts_corrected_thumbnail_sample(
    const NativePTSProjectRequest &request,
    const std::vector<NativeImage> &thumbnails,
    int cameraIndex,
    const NativePTSVec3 &worldRay,
    double &sourceX,
    double &sourceY,
    bool &valid
) {
    const auto &camera = request.cameras[cameraIndex];
    valid = native_pts_source_coordinate(camera, worldRay, sourceX, sourceY);
    if (!valid) return cv::Vec3f(0, 0, 0);
    const auto &image = thumbnails[cameraIndex];
    cv::Vec3f color = native_pts_sample_float(
        image,
        sourceX * static_cast<double>(image.width) / camera.width,
        sourceY * static_cast<double>(image.height) / camera.height
    );
    for (int channel = 0; channel < 3; ++channel) {
        color[channel] = static_cast<float>(std::max(0.0, std::min(
            1.0,
            static_cast<double>(color[channel]) * std::exp2(camera.gainEV[channel])
        )));
    }
    return color;
}

static bool native_pts_build_ownership_map(
    const NativePTSProjectRequest &request,
    const std::vector<NativeImage> &thumbnails,
    cv::Mat &owners,
    cv::Mat &referenceMean,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    const double aspect = static_cast<double>(request.outputWidth) / request.outputHeight;
    const int ownerWidth = aspect >= 1.0
        ? request.ownershipMapSide
        : std::max(1, static_cast<int>(std::llround(request.ownershipMapSide * aspect)));
    const int ownerHeight = aspect >= 1.0
        ? std::max(1, static_cast<int>(std::llround(request.ownershipMapSide / aspect)))
        : request.ownershipMapSide;
    owners = cv::Mat(ownerHeight, ownerWidth, CV_16UC1, cv::Scalar(0));
    cv::Mat sums(ownerHeight, ownerWidth, CV_32FC3, cv::Scalar(0, 0, 0));
    cv::Mat counts(ownerHeight, ownerWidth, CV_16UC1, cv::Scalar(0));
    std::vector<NativePTSROI> rois;
    rois.reserve(request.cameras.size());
    for (const auto &camera : request.cameras) {
        rois.push_back(native_pts_camera_roi(
            camera, ownerWidth, ownerHeight, request.horizontalFOV, request.verticalFOV
        ));
    }
    for (size_t index = 0; index < request.cameras.size(); ++index) {
        const NativePTSROI &roi = rois[index];
        if (!roi.valid) continue;
        for (int y = roi.y0; y < roi.y1; ++y) {
            cv::Vec3f *sumRow = sums.ptr<cv::Vec3f>(y);
            uint16_t *countRow = counts.ptr<uint16_t>(y);
            for (int x = roi.x0; x < roi.x1; ++x) {
                const auto ray = native_pts_output_ray(
                    x, y, ownerWidth, ownerHeight,
                    request.horizontalFOV, request.verticalFOV
                );
                double sourceX = 0.0, sourceY = 0.0;
                bool valid = false;
                const cv::Vec3f color = native_pts_corrected_thumbnail_sample(
                    request, thumbnails, static_cast<int>(index), ray,
                    sourceX, sourceY, valid
                );
                if (!valid) continue;
                sumRow[x] += color;
                countRow[x] = static_cast<uint16_t>(std::min(65535, static_cast<int>(countRow[x]) + 1));
            }
        }
    }
    cv::Mat best(ownerHeight, ownerWidth, CV_32FC1, cv::Scalar(-1e9f));
    for (size_t index = 0; index < request.cameras.size(); ++index) {
        if (active_native_operation_cancelled()) return false;
        emit_progress(progress, userData, "Selecting PTS ownership seams", 0.25 + 0.20 * index / request.cameras.size());
        const NativePTSROI &roi = rois[index];
        if (!roi.valid) continue;
        const auto &camera = request.cameras[index];
        for (int y = roi.y0; y < roi.y1; ++y) {
            float *bestRow = best.ptr<float>(y);
            uint16_t *ownerRow = owners.ptr<uint16_t>(y);
            const cv::Vec3f *sumRow = sums.ptr<cv::Vec3f>(y);
            const uint16_t *countRow = counts.ptr<uint16_t>(y);
            for (int x = roi.x0; x < roi.x1; ++x) {
                const auto ray = native_pts_output_ray(
                    x, y, ownerWidth, ownerHeight,
                    request.horizontalFOV, request.verticalFOV
                );
                double sourceX = 0.0, sourceY = 0.0;
                bool valid = false;
                const cv::Vec3f color = native_pts_corrected_thumbnail_sample(
                    request, thumbnails, static_cast<int>(index), ray,
                    sourceX, sourceY, valid
                );
                if (!valid || countRow[x] == 0) continue;
                const double boundary = std::min(
                    std::min(sourceX, camera.width - 1.0 - sourceX),
                    std::min(sourceY, camera.height - 1.0 - sourceY)
                ) / std::max(1.0, static_cast<double>(std::min(camera.width, camera.height)));
                const cv::Vec3f mean = sumRow[x] * (1.0f / countRow[x]);
                const double colorDifference = (
                    std::abs(color[0] - mean[0])
                    + std::abs(color[1] - mean[1])
                    + std::abs(color[2] - mean[2])
                ) / 3.0;
                const float score = static_cast<float>(boundary - 0.25 * colorDifference
                    + 1e-6 * camera.blendWeight);
                if (score > bestRow[x]) {
                    bestRow[x] = score;
                    ownerRow[x] = static_cast<uint16_t>(index + 1);
                }
            }
        }
    }
    cv::Mat countFloat;
    counts.convertTo(countFloat, CV_32FC1);
    cv::Mat blurredSums;
    cv::Mat blurredCounts;
    cv::GaussianBlur(sums, blurredSums, cv::Size(0, 0), 8.0);
    cv::GaussianBlur(countFloat, blurredCounts, cv::Size(0, 0), 8.0);
    cv::max(blurredCounts, 1e-6, blurredCounts);
    std::vector<cv::Mat> countChannels(3, blurredCounts);
    cv::Mat blurredCounts3;
    cv::merge(countChannels, blurredCounts3);
    referenceMean = blurredSums / blurredCounts3;
    return true;
}

static void native_pts_build_owner_color_corrections(
    const NativePTSProjectRequest &request,
    const std::vector<NativeImage> &thumbnails,
    const cv::Mat &owners,
    const cv::Mat &secondaryOwners,
    const cv::Mat &referenceMean,
    cv::Mat &primaryCorrection,
    cv::Mat &secondaryCorrection
) {
    primaryCorrection = cv::Mat(owners.rows, owners.cols, CV_32FC3, cv::Scalar(1, 1, 1));
    secondaryCorrection = cv::Mat(owners.rows, owners.cols, CV_32FC3, cv::Scalar(1, 1, 1));
    for (size_t index = 0; index < request.cameras.size(); ++index) {
        const NativePTSROI roi = native_pts_camera_roi(
            request.cameras[index], owners.cols, owners.rows,
            request.horizontalFOV, request.verticalFOV
        );
        if (!roi.valid) continue;
        cv::Mat warped(owners.rows, owners.cols, CV_32FC3, cv::Scalar(0, 0, 0));
        cv::Mat valid(owners.rows, owners.cols, CV_32FC1, cv::Scalar(0));
        for (int y = roi.y0; y < roi.y1; ++y) {
            cv::Vec3f *warpedRow = warped.ptr<cv::Vec3f>(y);
            float *validRow = valid.ptr<float>(y);
            for (int x = roi.x0; x < roi.x1; ++x) {
                const NativePTSVec3 ray = native_pts_output_ray(
                    x, y, owners.cols, owners.rows,
                    request.horizontalFOV, request.verticalFOV
                );
                double sourceX = 0.0, sourceY = 0.0;
                bool isValid = false;
                const cv::Vec3f color = native_pts_corrected_thumbnail_sample(
                    request, thumbnails, static_cast<int>(index), ray,
                    sourceX, sourceY, isValid
                );
                if (!isValid) continue;
                warpedRow[x] = color;
                validRow[x] = 1.0f;
            }
        }
        cv::Mat blurredWarped;
        cv::Mat blurredValid;
        cv::GaussianBlur(warped, blurredWarped, cv::Size(0, 0), 8.0);
        cv::GaussianBlur(valid, blurredValid, cv::Size(0, 0), 8.0);
        for (int y = roi.y0; y < roi.y1; ++y) {
            const cv::Vec3f *referenceRow = referenceMean.ptr<cv::Vec3f>(y);
            const cv::Vec3f *sourceRow = blurredWarped.ptr<cv::Vec3f>(y);
            const float *validRow = blurredValid.ptr<float>(y);
            cv::Vec3f *primaryRow = primaryCorrection.ptr<cv::Vec3f>(y);
            cv::Vec3f *secondaryRow = secondaryCorrection.ptr<cv::Vec3f>(y);
            const uint16_t *ownerRow = owners.ptr<uint16_t>(y);
            const uint16_t *secondaryOwnerRow = secondaryOwners.ptr<uint16_t>(y);
            for (int x = roi.x0; x < roi.x1; ++x) {
                if (validRow[x] < 1e-4f) continue;
                cv::Vec3f correction(1, 1, 1);
                for (int channel = 0; channel < 3; ++channel) {
                    const double source = sourceRow[x][channel] / validRow[x];
                    if (source > 0.003) {
                        // Keep a wider local-only range than the global gain.
                        // The target night panorama contains red flashlight
                        // spill next to neutral sand; limiting the local field
                        // to roughly +/-0.58 EV leaves a visible ownership
                        // polygon even though both sources cover the seam.
                        // Keep local overlap matching bounded. Analysis and
                        // rendering use thumbnails from the same mapped TIFF
                        // sample space, so +/-1 EV is sufficient without
                        // amplifying chroma noise in the darkest sand.
                        correction[channel] = static_cast<float>(std::max(
                            0.5,
                            std::min(2.0, static_cast<double>(referenceRow[x][channel]) / source)
                        ));
                    }
                }
                if (ownerRow[x] == index + 1) primaryRow[x] = correction;
                if (secondaryOwnerRow[x] == index + 1) secondaryRow[x] = correction;
            }
        }
    }
}

class NativePTSMappedTIFF {
public:
    ~NativePTSMappedTIFF() { close(); }
    bool open(const NativePTSCamera &camera, std::string &error) {
        // Lowercase `c` disables libtiff's default virtual strip chopping so
        // the validated one-strip file layout and byte offset remain physical.
        TIFF *tiff = TIFFOpen(camera.path.c_str(), "rc");
        if (!tiff) { error = "failed to open TIFF: " + camera.path; return false; }
        uint32_t width = 0, height = 0, rowsPerStrip = 0;
        uint16_t bits = 0, samples = 0, planar = 0, compression = 0, orientation = 0;
        uint16_t sampleFormat = SAMPLEFORMAT_VOID, photometric = 0;
        TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
        TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_BITSPERSAMPLE, &bits);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLESPERPIXEL, &samples);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_PLANARCONFIG, &planar);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_COMPRESSION, &compression);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_PHOTOMETRIC, &photometric);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_ORIENTATION, &orientation);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLEFORMAT, &sampleFormat);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_ROWSPERSTRIP, &rowsPerStrip);
        if (width != static_cast<uint32_t>(camera.width)
            || height != static_cast<uint32_t>(camera.height)
            || bits != 16 || samples != 3 || planar != PLANARCONFIG_CONTIG
            || compression != COMPRESSION_NONE || photometric != PHOTOMETRIC_RGB
            || orientation != ORIENTATION_TOPLEFT
            || (sampleFormat != SAMPLEFORMAT_UINT && sampleFormat != SAMPLEFORMAT_VOID)
            || TIFFIsByteSwapped(tiff)
            || TIFFNumberOfStrips(tiff) != 1 || rowsPerStrip < height) {
            TIFFClose(tiff);
            error = "full-resolution PTS input is not a native-endian, uncompressed, one-strip, top-left 16-bit RGB TIFF: " + camera.path;
            return false;
        }
        const uint64_t offset = TIFFGetStrileOffset(tiff, 0);
        const uint64_t byteCount = TIFFGetStrileByteCount(tiff, 0);
        uint32_t iccSize = 0;
        void *iccData = nullptr;
        if (TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &iccSize, &iccData) && iccSize > 0 && iccData) {
            icc_.assign(static_cast<uint8_t *>(iccData), static_cast<uint8_t *>(iccData) + iccSize);
        }
        TIFFClose(tiff);
        const uint64_t required = static_cast<uint64_t>(width) * height * 3 * sizeof(uint16_t);
        if (offset == 0 || byteCount < required) {
            error = "TIFF strip is smaller than its declared pixel payload: " + camera.path;
            return false;
        }
        fd_ = ::open(camera.path.c_str(), O_RDONLY);
        if (fd_ < 0) { error = "failed to open TIFF file descriptor: " + camera.path; return false; }
        struct stat status{};
        if (fstat(fd_, &status) != 0 || offset + required > static_cast<uint64_t>(status.st_size)) {
            error = "TIFF strip offset exceeds the source file: " + camera.path;
            close(); return false;
        }
        mappingBytes_ = static_cast<size_t>(status.st_size);
        mapping_ = mmap(nullptr, mappingBytes_, PROT_READ, MAP_PRIVATE, fd_, 0);
        if (mapping_ == MAP_FAILED) {
            mapping_ = nullptr;
            error = "failed to mmap TIFF: " + camera.path;
            close(); return false;
        }
        pixels_ = reinterpret_cast<const uint16_t *>(static_cast<const uint8_t *>(mapping_) + offset);
        width_ = camera.width;
        height_ = camera.height;
        return true;
    }
    cv::Vec3f sample(double x, double y) const {
        const double px = std::max(0.0, std::min(static_cast<double>(width_ - 1), x));
        const double py = std::max(0.0, std::min(static_cast<double>(height_ - 1), y));
        const int x0 = static_cast<int>(std::floor(px)), y0 = static_cast<int>(std::floor(py));
        const int x1 = std::min(width_ - 1, x0 + 1), y1 = std::min(height_ - 1, y0 + 1);
        const float tx = static_cast<float>(px - x0), ty = static_cast<float>(py - y0);
        auto value = [&](int xx, int yy, int channel) {
            return static_cast<float>(pixels_[(static_cast<size_t>(yy) * width_ + xx) * 3 + channel]) / 65535.0f;
        };
        cv::Vec3f result;
        for (int channel = 0; channel < 3; ++channel) {
            const float top = value(x0, y0, channel) * (1 - tx) + value(x1, y0, channel) * tx;
            const float bottom = value(x0, y1, channel) * (1 - tx) + value(x1, y1, channel) * tx;
            result[channel] = top * (1 - ty) + bottom * ty;
        }
        return result;
    }
    NativeImage thumbnail(int maxSide) const {
        NativeImage image;
        image.width = width_;
        image.height = height_;
        if (maxSide > 0 && std::max(width_, height_) > maxSide) {
            const double scale = static_cast<double>(maxSide) / std::max(width_, height_);
            image.width = std::max(1, static_cast<int>(std::llround(width_ * scale)));
            image.height = std::max(1, static_cast<int>(std::llround(height_ * scale)));
        }
        image.originalWidth = width_;
        image.originalHeight = height_;
        image.channels = 3;
        image.bitDepth = 16;
        image.status = "loaded";
        image.pixels.assign(static_cast<size_t>(image.width) * image.height * 3, 0.0f);
        for (int y = 0; y < image.height; ++y) {
            const double sourceY = (static_cast<double>(y) + 0.5) * height_ / image.height - 0.5;
            for (int x = 0; x < image.width; ++x) {
                const double sourceX = (static_cast<double>(x) + 0.5) * width_ / image.width - 0.5;
                const cv::Vec3f color = sample(sourceX, sourceY);
                const size_t offset = (static_cast<size_t>(y) * image.width + x) * 3;
                image.pixels[offset] = color[0];
                image.pixels[offset + 1] = color[1];
                image.pixels[offset + 2] = color[2];
            }
        }
        return image;
    }
    const std::vector<uint8_t> &icc() const { return icc_; }
private:
    void close() {
        pixels_ = nullptr;
        if (mapping_) munmap(mapping_, mappingBytes_);
        mapping_ = nullptr; mappingBytes_ = 0;
        if (fd_ >= 0) ::close(fd_);
        fd_ = -1;
    }
    int fd_ = -1;
    void *mapping_ = nullptr;
    size_t mappingBytes_ = 0;
    const uint16_t *pixels_ = nullptr;
    int width_ = 0, height_ = 0;
    std::vector<uint8_t> icc_;
};

struct NativePTSOwnerBlend {
    std::array<int, 2> indices = {-1, -1};
    std::array<float, 2> weights = {0, 0};
    int count = 0;
};

static NativePTSOwnerBlend native_pts_owner_weights(
    const cv::Mat &owners,
    const cv::Mat &secondary,
    const cv::Mat &distance,
    int transitionRadius,
    double outputX,
    double outputY,
    int outputWidth,
    int outputHeight
) {
    const double mapX = outputWidth > 1 ? outputX * (owners.cols - 1) / (outputWidth - 1.0) : 0.0;
    const double mapY = outputHeight > 1 ? outputY * (owners.rows - 1) / (outputHeight - 1.0) : 0.0;
    NativePTSOwnerBlend result;
    const int mapPixelX = std::max(0, std::min(owners.cols - 1, static_cast<int>(std::llround(mapX))));
    const int mapPixelY = std::max(0, std::min(owners.rows - 1, static_cast<int>(std::llround(mapY))));
    const uint16_t primary = owners.at<uint16_t>(mapPixelY, mapPixelX);
    if (primary == 0) return result;
    result.indices[0] = static_cast<int>(primary - 1);
    result.weights[0] = 1.0f;
    result.count = 1;
    // Preserve single-source pixels for saved zero-overlap projects.
    return result;
}

static std::string native_pts_report_json(
    bool success,
    const std::string &message,
    const NativePTSProjectRequest &request,
    const cv::Mat &owners,
    double elapsed,
    const std::vector<std::string> &warnings
) {
    std::ostringstream out;
    out << "{";
    out << "\"success\":" << bool_json(success) << ",";
    out << "\"operation\":\"renderImportedProject\",";
    out << "\"message\":\"" << json_escape(message) << "\",";
    if (success) {
        out << "\"output_path\":\"" << json_escape(request.outputPath) << "\",";
        out << "\"width\":" << request.outputWidth << ",\"height\":" << request.outputHeight << ",";
        out << "\"bit_depth\":16,\"channels\":4,";
        out << "\"renderer\":\"native_pts_stereographic_cpu_streaming\",";
        out << "\"source_count\":" << request.cameras.size() << ",";
        out << "\"control_point_count\":" << request.controlPoints.size() << ",";
        out << "\"connected_pair_count\":" << request.connectedPairCount << ",";
        out << "\"elapsed_seconds\":" << elapsed << ",";
        out << "\"ownership_map_width\":" << owners.cols << ",";
        out << "\"ownership_map_height\":" << owners.rows << ",";
        out << "\"gain_ev\":[";
        for (size_t index = 0; index < request.cameras.size(); ++index) {
            if (index) out << ",";
            out << "[" << request.cameras[index].gainEV[0] << ","
                << request.cameras[index].gainEV[1] << ","
                << request.cameras[index].gainEV[2] << "]";
        }
        out << "],";
        out << "\"gain_observation_count\":" << request.gainObservationCount << ",";
        out << "\"gain_residual_rms_ev\":["
            << request.gainResidualRMSEV[0] << ","
            << request.gainResidualRMSEV[1] << ","
            << request.gainResidualRMSEV[2] << "],";
        out << "\"gain_clamped_camera_count\":["
            << request.gainClampedCameraCount[0] << ","
            << request.gainClampedCameraCount[1] << ","
            << request.gainClampedCameraCount[2] << "],";
    }
    out << "\"warnings\":[";
    for (size_t index = 0; index < warnings.size(); ++index) {
        if (index) out << ",";
        out << "\"" << json_escape(warnings[index]) << "\"";
    }
    out << "]}";
    return out.str();
}

static bool native_pts_render_to_tiff(
    MyPTGuiNativeContext *context,
    NativePTSProjectRequest &request,
    MyPTGuiProgressCallback progress,
    void *userData,
    std::string &report,
    std::string &error
) {
    const auto started = std::chrono::steady_clock::now();
    (void)context;
    std::vector<std::unique_ptr<NativePTSMappedTIFF>> mapped;
    mapped.reserve(request.cameras.size());
    std::vector<std::string> warnings;
    std::vector<uint8_t> commonICC;
    bool iccConsistent = true;
    for (size_t index = 0; index < request.cameras.size(); ++index) {
        emit_progress(progress, userData, "Mapping 16-bit PTS TIFF sources", 0.02 + 0.04 * index / request.cameras.size());
        auto source = std::make_unique<NativePTSMappedTIFF>();
        if (!source->open(request.cameras[index], error)) return false;
        if (index == 0) commonICC = source->icc();
        else if (source->icc() != commonICC) iccConsistent = false;
        mapped.push_back(std::move(source));
    }
    if (!iccConsistent) {
        commonICC.clear();
        warnings.push_back("Source ICC profiles differ; output ICC profile was omitted.");
    }
    std::vector<NativeImage> thumbnails;
    thumbnails.reserve(mapped.size());
    for (size_t index = 0; index < mapped.size(); ++index) {
        if (active_native_operation_cancelled()) { error = "operation cancelled"; return false; }
        emit_progress(progress, userData, "Sampling PTS analysis thumbnails", 0.06 + 0.14 * index / mapped.size());
        thumbnails.push_back(mapped[index]->thumbnail(512));
    }
    native_pts_solve_gains(request, thumbnails);
    cv::Mat owners;
    cv::Mat referenceMean;
    if (!native_pts_build_ownership_map(
            request, thumbnails, owners, referenceMean, progress, userData
        )) {
        error = active_native_operation_cancelled() ? "operation cancelled" : "failed to build PTS ownership map";
        return false;
    }
    const int transitionRadius = std::max(
        1,
        static_cast<int>(std::llround(
            8.0 * static_cast<double>(owners.cols) / request.outputWidth
        ))
    );
    cv::Mat secondaryOwners;
    cv::Mat ownerDistance;
    native_pts_build_secondary_owners(
        owners, transitionRadius, secondaryOwners, ownerDistance
    );
    cv::Mat primaryCorrection;
    cv::Mat secondaryCorrection;
    native_pts_build_owner_color_corrections(
        request, thumbnails, owners, secondaryOwners, referenceMean,
        primaryCorrection, secondaryCorrection
    );
    thumbnails.clear();

    std::vector<NativeImage> previewImages;
    if (!request.fullResolutionSources) {
        previewImages.reserve(mapped.size());
        for (size_t index = 0; index < mapped.size(); ++index) {
            if (active_native_operation_cancelled()) { error = "operation cancelled"; return false; }
            emit_progress(progress, userData, "Sampling PTS preview thumbnails", 0.46 + 0.04 * index / mapped.size());
            previewImages.push_back(mapped[index]->thumbnail(1536));
        }
    }

    TIFF *output = TIFFOpen(request.outputPath.c_str(), "w8");
    if (!output) { error = "failed to open imported-project TIFF output"; return false; }
    TIFFSetField(output, TIFFTAG_IMAGEWIDTH, static_cast<uint32_t>(request.outputWidth));
    TIFFSetField(output, TIFFTAG_IMAGELENGTH, static_cast<uint32_t>(request.outputHeight));
    TIFFSetField(output, TIFFTAG_SAMPLESPERPIXEL, 4);
    TIFFSetField(output, TIFFTAG_BITSPERSAMPLE, 16);
    TIFFSetField(output, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFSetField(output, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(output, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
    TIFFSetField(output, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    TIFFSetField(output, TIFFTAG_ROWSPERSTRIP, 32);
    TIFFSetField(output, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT);
    uint16_t extraSample = EXTRASAMPLE_UNASSALPHA;
    TIFFSetField(output, TIFFTAG_EXTRASAMPLES, 1, &extraSample);
    if (!commonICC.empty()) {
        TIFFSetField(output, TIFFTAG_ICCPROFILE, static_cast<uint32_t>(commonICC.size()), commonICC.data());
    }
    std::vector<uint16_t> row(static_cast<size_t>(request.outputWidth) * 4);
    bool writeOK = true;
    for (int y = 0; y < request.outputHeight; ++y) {
        if (active_native_operation_cancelled()) { error = "operation cancelled"; writeOK = false; break; }
        if (y % 16 == 0) {
            emit_progress(progress, userData, "Rendering imported PTS panorama", 0.50 + 0.49 * y / request.outputHeight);
        }
        for (int x = 0; x < request.outputWidth; ++x) {
            const NativePTSVec3 ray = native_pts_output_ray(
                x, y, request.outputWidth, request.outputHeight,
                request.horizontalFOV, request.verticalFOV
            );
            const auto weights = native_pts_owner_weights(
                owners, secondaryOwners, ownerDistance, transitionRadius,
                x, y, request.outputWidth, request.outputHeight
            );
            const double correctionMapX = request.outputWidth > 1
                ? static_cast<double>(x) * (owners.cols - 1) / (request.outputWidth - 1.0)
                : 0.0;
            const double correctionMapY = request.outputHeight > 1
                ? static_cast<double>(y) * (owners.rows - 1) / (request.outputHeight - 1.0)
                : 0.0;
            const int correctionX = std::max(0, std::min(
                owners.cols - 1, static_cast<int>(std::llround(correctionMapX))
            ));
            const int correctionY = std::max(0, std::min(
                owners.rows - 1, static_cast<int>(std::llround(correctionMapY))
            ));
            cv::Vec3d color(0, 0, 0);
            double totalWeight = 0.0;
            for (int ownerIndex = 0; ownerIndex < weights.count; ++ownerIndex) {
                const int cameraIndex = weights.indices[ownerIndex];
                const float ownerWeight = weights.weights[ownerIndex];
                if (cameraIndex < 0 || cameraIndex >= static_cast<int>(request.cameras.size())) continue;
                const auto &camera = request.cameras[cameraIndex];
                double sourceX = 0.0, sourceY = 0.0;
                if (!native_pts_source_coordinate(camera, ray, sourceX, sourceY)) continue;
                cv::Vec3f sample;
                if (request.fullResolutionSources) {
                    sample = mapped[cameraIndex]->sample(sourceX, sourceY);
                } else {
                    const auto &image = previewImages[cameraIndex];
                    sample = native_pts_sample_float(
                        image,
                        sourceX * static_cast<double>(image.width) / camera.width,
                        sourceY * static_cast<double>(image.height) / camera.height
                    );
                }
                const cv::Vec3f correction = ownerIndex == 0
                    ? primaryCorrection.at<cv::Vec3f>(correctionY, correctionX)
                    : secondaryCorrection.at<cv::Vec3f>(correctionY, correctionX);
                for (int channel = 0; channel < 3; ++channel) {
                    color[channel] += ownerWeight * std::max(0.0, std::min(
                        1.0,
                        static_cast<double>(sample[channel])
                            * std::exp2(camera.gainEV[channel])
                            * correction[channel]
                    ));
                }
                totalWeight += ownerWeight;
            }
            const size_t offset = static_cast<size_t>(x) * 4;
            if (totalWeight > 1e-8) {
                for (int channel = 0; channel < 3; ++channel) {
                    row[offset + channel] = static_cast<uint16_t>(std::llround(
                        65535.0 * std::max(0.0, std::min(1.0, color[channel] / totalWeight))
                    ));
                }
                row[offset + 3] = 65535;
            } else {
                row[offset] = row[offset + 1] = row[offset + 2] = row[offset + 3] = 0;
            }
        }
        if (TIFFWriteScanline(output, row.data(), static_cast<uint32_t>(y), 0) < 0) {
            error = "failed while writing imported-project TIFF scanline";
            writeOK = false;
            break;
        }
    }
    TIFFClose(output);
    if (!writeOK) {
        std::remove(request.outputPath.c_str());
        return false;
    }
    emit_progress(progress, userData, "Imported PTS panorama complete", 1.0);
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    report = native_pts_report_json(
        true, "Imported PTGui project reconstructed without PTGui.", request,
        owners, elapsed, warnings
    );
    return true;
}

static bool native_pts_projection_characterization_self_test() {
    NativePTSCamera camera;
    camera.width = 7008; camera.height = 4672;
    camera.focal = 3893.397102741032;
    camera.principalX = 3504.0; camera.principalY = 2336.0;
    camera.worldFromCamera = native_pts_rotation_matrix(0, 0, 0);
    double x = 0.0, y = 0.0;
    if (!native_pts_forward_project(camera, camera.principalX, camera.principalY,
            4096, 4096, 270, 270, x, y)
        || std::abs(x - 2047.5) > 1e-9 || std::abs(y - 2047.5) > 1e-9) return false;
    const NativePTSVec3 center = native_pts_output_ray(2047.5, 2047.5, 4096, 4096, 270, 270);
    double sourceX = 0.0, sourceY = 0.0;
    return native_pts_source_coordinate(camera, center, sourceX, sourceY)
        && std::abs(sourceX - camera.principalX) < 1e-9
        && std::abs(sourceY - camera.principalY) < 1e-9;
}

#else

static bool native_pts_projection_characterization_self_test() { return false; }

#endif

#endif
