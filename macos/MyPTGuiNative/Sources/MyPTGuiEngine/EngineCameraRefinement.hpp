// PanoLume internal implementation module. This file is included exactly once
// by MyPTGuiEngine.mm to preserve the pre-split translation-unit semantics.

#if MYPTGUI_HAS_OPENCV_HEADERS
static cv::Mat scaled_translation(cv::Mat transform, int &width, int &height, int maxOutputPixels, int maxOutputSide) {
    const int rawWidth = width;
    const int rawHeight = height;
    double scale = 1.0;
    const double maxPixels = static_cast<double>(maxOutputPixels > 0 ? maxOutputPixels : 32000000);
    if (rawWidth > 0 && rawHeight > 0 && static_cast<double>(rawWidth) * static_cast<double>(rawHeight) > maxPixels) {
        scale = std::min(scale, std::sqrt(maxPixels / (static_cast<double>(rawWidth) * static_cast<double>(rawHeight))));
    }
    const int maxSide = maxOutputSide > 0 ? maxOutputSide : 9000;
    if (std::max(rawWidth, rawHeight) > maxSide) {
        scale = std::min(scale, static_cast<double>(maxSide) / static_cast<double>(std::max(rawWidth, rawHeight)));
    }
    if (scale < 1.0) {
        cv::Mat S = (cv::Mat_<double>(3, 3) << scale, 0.0, 0.0, 0.0, scale, 0.0, 0.0, 0.0, 1.0);
        transform = S * transform;
        width = std::max(1, static_cast<int>(std::ceil(static_cast<double>(width) * scale)));
        height = std::max(1, static_cast<int>(std::ceil(static_cast<double>(height) * scale)));
    }
    return transform;
}

static double estimate_initial_focal(
    const std::vector<NativeImage> &images,
    const panolume::EngineRequest &request,
    std::string *source = nullptr
) {
    if (request.has("focalLengthGuess")) {
        if (source) {
            *source = "request_focalLengthGuess";
        }
        return std::max(50.0, request.number("focalLengthGuess", 1000.0));
    }
    std::vector<double> focalPixels;
    for (const NativeImage &image : images) {
        if (image.width > 0 && image.height > 0 && image.focalLength35mm > 0.0) {
            // EXIF's 35 mm equivalent is orientation independent.  Using the
            // decoded image width silently treats a portrait frame's short
            // side as the 36 mm sensor side and underestimates focal length by
            // 1.5x for a 3:2 image.  Diagonal conversion is invariant under
            // orientation and remains valid for non-3:2 crops.
            constexpr double fullFrameDiagonal = 43.266615305567875; // hypot(36, 24)
            const double imageDiagonal = std::hypot(
                static_cast<double>(image.width),
                static_cast<double>(image.height)
            );
            focalPixels.push_back(imageDiagonal * image.focalLength35mm / fullFrameDiagonal);
        }
    }
    if (!focalPixels.empty()) {
        if (source) {
            *source = "exif_35mm_equivalent_focal_length";
        }
        return std::max(50.0, median_value(focalPixels));
    }

    std::vector<double> widths;
    for (const NativeImage &image : images) {
        if (image.width > 0) {
            widths.push_back(static_cast<double>(image.width));
        }
    }
    double fallback = 1000.0;
    if (!widths.empty()) {
        fallback = std::max(100.0, median_value(widths) * 0.85);
    }
    if (source) {
        *source = "fallback_median_image_width_0.85_no_exif_35mm";
    }
    return std::max(50.0, fallback);
}

static double native_camera_principal_x(const NativeCameraParams &camera, const NativeImage &image) {
    return static_cast<double>(image.width) * (0.5 + camera.principalOffsetX);
}

static double native_camera_principal_y(const NativeCameraParams &camera, const NativeImage &image) {
    return static_cast<double>(image.height) * (0.5 + camera.principalOffsetY);
}

static cv::Mat make_intrinsics(
    double focal,
    int width,
    int height,
    double principalOffsetX = 0.0,
    double principalOffsetY = 0.0
) {
    return (cv::Mat_<double>(3, 3) <<
        focal, 0.0, static_cast<double>(width) * (0.5 + principalOffsetX),
        0.0, focal, static_cast<double>(height) * (0.5 + principalOffsetY),
        0.0, 0.0, 1.0
    );
}

static bool rotation_from_homography(
    const cv::Mat &H,
    const NativeImage &image,
    const NativeImage &reference,
    double focal,
    std::array<double, 3> &rotation
) {
    if (H.empty() || H.rows != 3 || H.cols != 3 || image.width <= 0 || image.height <= 0) {
        return false;
    }
    cv::Mat H64;
    H.convertTo(H64, CV_64F);
    const cv::Mat kImage = make_intrinsics(focal, image.width, image.height);
    const cv::Mat kReference = make_intrinsics(focal, reference.width, reference.height);
    cv::Mat approx;
    if (!cv::invert(kReference, approx)) {
        return false;
    }
    approx = approx * H64 * kImage;
    cv::SVD svd(approx);
    cv::Mat R = svd.u * svd.vt;
    if (cv::determinant(R) < 0.0) {
        for (int row = 0; row < svd.u.rows; ++row) {
            svd.u.at<double>(row, 2) *= -1.0;
        }
        R = svd.u * svd.vt;
    }
    if (!cv::checkRange(R)) {
        return false;
    }
    cv::Mat rotvec;
    cv::Rodrigues(R, rotvec);
    rotation = {
        rotvec.at<double>(0, 0),
        rotvec.at<double>(1, 0),
        rotvec.at<double>(2, 0)
    };
    return true;
}

static cv::Mat rotation_matrix_x(double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return (cv::Mat_<double>(3, 3) <<
        1.0, 0.0, 0.0,
        0.0, c, -s,
        0.0, s, c
    );
}

static cv::Mat rotation_matrix_y(double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return (cv::Mat_<double>(3, 3) <<
        c, 0.0, s,
        0.0, 1.0, 0.0,
        -s, 0.0, c
    );
}

static cv::Mat rotation_matrix_z(double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return (cv::Mat_<double>(3, 3) <<
        c, -s, 0.0,
        s, c, 0.0,
        0.0, 0.0, 1.0
    );
}

static void apply_pose_adjustment_to_cameras(
    std::vector<NativeCameraParams> &cameras,
    double pitchDegrees,
    double yawDegrees,
    double rollDegrees
) {
    const double degreesToRadians = M_PI / 180.0;
    const double pitch = pitchDegrees * degreesToRadians;
    const double yaw = yawDegrees * degreesToRadians;
    const double roll = rollDegrees * degreesToRadians;
    if (std::abs(pitch) < 1e-12 && std::abs(yaw) < 1e-12 && std::abs(roll) < 1e-12) {
        return;
    }
    const cv::Mat adjustment = rotation_matrix_z(roll) * rotation_matrix_y(yaw) * rotation_matrix_x(pitch);
    for (NativeCameraParams &camera : cameras) {
        cv::Mat rotvec = (cv::Mat_<double>(3, 1) <<
            camera.rotation[0],
            camera.rotation[1],
            camera.rotation[2]
        );
        cv::Mat cameraRotation;
        cv::Rodrigues(rotvec, cameraRotation);
        cv::Mat adjustedRotation = adjustment * cameraRotation;
        cv::Mat adjustedRotvec;
        cv::Rodrigues(adjustedRotation, adjustedRotvec);
        camera.rotation = {
            adjustedRotvec.at<double>(0, 0),
            adjustedRotvec.at<double>(1, 0),
            adjustedRotvec.at<double>(2, 0)
        };
    }
}

static std::vector<NativeCameraParams> initialize_camera_params(
    const std::vector<NativeImage> &images,
    const std::vector<cv::Mat> &imageToPanorama,
    const panolume::EngineRequest &request,
    double focal
) {
    std::vector<NativeCameraParams> cameras;
    cameras.reserve(images.size());
    const NativeImage &reference = images.front();
    const double refCx = static_cast<double>(reference.width) / 2.0;
    const double refCy = static_cast<double>(reference.height) / 2.0;
    for (size_t idx = 0; idx < images.size(); ++idx) {
        NativeCameraParams camera;
        camera.focalLength = focal;
        camera.k1 = request.number("initialK1", 0.0);
        camera.k2 = request.number("initialK2", 0.0);
        camera.k3 = request.number("initialK3", 0.0);
        camera.p1 = request.number("initialP1", 0.0);
        camera.p2 = request.number("initialP2", 0.0);
        std::array<double, 3> rotation = {0.0, 0.0, 0.0};
        const bool rotated = idx < imageToPanorama.size()
            && rotation_from_homography(imageToPanorama[idx], images[idx], reference, focal, rotation);
        if (!rotated && idx < imageToPanorama.size() && !imageToPanorama[idx].empty()) {
            const NativeImage &image = images[idx];
            std::vector<cv::Point2f> center = {
                cv::Point2f(static_cast<float>(image.width) * 0.5f, static_cast<float>(image.height) * 0.5f)
            };
            std::vector<cv::Point2f> mapped;
            cv::perspectiveTransform(center, mapped, imageToPanorama[idx]);
            if (!mapped.empty() && std::isfinite(mapped[0].x) && std::isfinite(mapped[0].y)) {
                const double dx = static_cast<double>(mapped[0].x) - refCx;
                const double dy = static_cast<double>(mapped[0].y) - refCy;
                rotation[0] = std::max(-M_PI * 0.45, std::min(M_PI * 0.45, -dy / focal));
                rotation[1] = std::max(-M_PI * 0.75, std::min(M_PI * 0.75, dx / focal));
                const cv::Mat linear = imageToPanorama[idx](cv::Rect(0, 0, 2, 2));
                rotation[2] = std::atan2(linear.at<double>(1, 0), linear.at<double>(0, 0));
            }
        }
        camera.rotation = rotation;
        cameras.push_back(camera);
    }
    if (!cameras.empty()) {
        cameras[0].rotation = {0.0, 0.0, 0.0};
    }
    return cameras;
}

static void rotate_angle_axis_point_double(
    const std::array<double, 3> &rotation,
    const double point[3],
    double result[3]
) {
    const double theta2 = rotation[0] * rotation[0] + rotation[1] * rotation[1] + rotation[2] * rotation[2];
    if (theta2 > 1e-24) {
        const double theta = std::sqrt(theta2);
        const double wx = rotation[0] / theta;
        const double wy = rotation[1] / theta;
        const double wz = rotation[2] / theta;
        const double costheta = std::cos(theta);
        const double sintheta = std::sin(theta);
        const double dot = wx * point[0] + wy * point[1] + wz * point[2];
        const double crossX = wy * point[2] - wz * point[1];
        const double crossY = wz * point[0] - wx * point[2];
        const double crossZ = wx * point[1] - wy * point[0];
        result[0] = point[0] * costheta + crossX * sintheta + wx * dot * (1.0 - costheta);
        result[1] = point[1] * costheta + crossY * sintheta + wy * dot * (1.0 - costheta);
        result[2] = point[2] * costheta + crossZ * sintheta + wz * dot * (1.0 - costheta);
    } else {
        const double crossX = rotation[1] * point[2] - rotation[2] * point[1];
        const double crossY = rotation[2] * point[0] - rotation[0] * point[2];
        const double crossZ = rotation[0] * point[1] - rotation[1] * point[0];
        result[0] = point[0] + crossX;
        result[1] = point[1] + crossY;
        result[2] = point[2] + crossZ;
    }
}

static std::array<double, 5> camera_distortion_values(const NativeCameraParams &camera) {
    return {camera.k1, camera.k2, camera.k3, camera.p1, camera.p2};
}

static void apply_brown_conrady_distortion_double(
    double x,
    double y,
    const std::array<double, 5> &distortion,
    double &distortedX,
    double &distortedY
) {
    const double k1 = distortion[0];
    const double k2 = distortion[1];
    const double k3 = distortion[2];
    const double p1 = distortion[3];
    const double p2 = distortion[4];
    const double r2 = x * x + y * y;
    const double r4 = r2 * r2;
    const double r6 = r4 * r2;
    const double radial = 1.0 + k1 * r2 + k2 * r4 + k3 * r6;
    const double tangentialX = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x);
    const double tangentialY = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y;
    distortedX = x * radial + tangentialX;
    distortedY = y * radial + tangentialY;
}

static double native_camera_reprojection_error(
    const NativeCameraParams &cameraA,
    const NativeCameraParams &cameraB,
    const NativeImage &imageA,
    const NativeImage &imageB,
    const NativeControlPoint &point
) {
    const double observedSourceX =
        (point.xA - native_camera_principal_x(cameraA, imageA)) / cameraA.focalLength;
    const double observedSourceY =
        (point.yA - native_camera_principal_y(cameraA, imageA)) / cameraA.focalLength;
    double sourceX = observedSourceX;
    double sourceY = observedSourceY;
    const std::array<double, 5> sourceDistortion = camera_distortion_values(cameraA);
    // The measured source pixel is distorted too. Keep the held-out evaluator
    // symmetric with the Ceres residual and native_pixel_to_world_ray; treating
    // only the target as distorted systematically rejects every shared lens
    // candidate even when it improves the actual two-image geometry.
    for (int iteration = 0; iteration < 8; ++iteration) {
        double predictedX = sourceX;
        double predictedY = sourceY;
        apply_brown_conrady_distortion_double(
            sourceX,
            sourceY,
            sourceDistortion,
            predictedX,
            predictedY
        );
        sourceX += observedSourceX - predictedX;
        sourceY += observedSourceY - predictedY;
    }
    double rayA[3] = {sourceX, sourceY, 1.0};
    double rayWorld[3] = {0.0, 0.0, 0.0};
    rotate_angle_axis_point_double(cameraA.rotation, rayA, rayWorld);

    const std::array<double, 3> inverseRotationB = {
        -cameraB.rotation[0],
        -cameraB.rotation[1],
        -cameraB.rotation[2]
    };
    double rayB[3] = {0.0, 0.0, 0.0};
    rotate_angle_axis_point_double(inverseRotationB, rayWorld, rayB);
    if (std::abs(rayB[2]) < 1e-12) {
        return std::numeric_limits<double>::infinity();
    }
    const double x = rayB[0] / rayB[2];
    const double y = rayB[1] / rayB[2];
    double distortedX = x;
    double distortedY = y;
    apply_brown_conrady_distortion_double(x, y, camera_distortion_values(cameraB), distortedX, distortedY);
    const double px = distortedX * cameraB.focalLength + native_camera_principal_x(cameraB, imageB);
    const double py = distortedY * cameraB.focalLength + native_camera_principal_y(cameraB, imageB);
    const double dx = px - point.xB;
    const double dy = py - point.yB;
    return std::sqrt(dx * dx + dy * dy);
}

static double camera_rms_error(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &points
) {
    if (points.empty()) {
        return 0.0;
    }
    double sumSquared = 0.0;
    int count = 0;
    for (const NativeControlPoint &point : points) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(cameras.size())
            || point.imageBIndex >= static_cast<int>(cameras.size())) {
            continue;
        }
        const double error = native_camera_reprojection_error(
            cameras[static_cast<size_t>(point.imageAIndex)],
            cameras[static_cast<size_t>(point.imageBIndex)],
            images[static_cast<size_t>(point.imageAIndex)],
            images[static_cast<size_t>(point.imageBIndex)],
            point
        );
        if (!std::isfinite(error)) {
            continue;
        }
        sumSquared += error * error;
        count += 1;
    }
    if (count == 0) {
        return 0.0;
    }
    return std::sqrt(sumSquared / static_cast<double>(count));
}

static bool native_project_ray(
    const double ray[3],
    const std::string &projection,
    double &u,
    double &v
);

static bool native_pixel_to_world_ray(
    const NativeCameraParams &camera,
    const NativeImage &image,
    double x,
    double y,
    double rayWorld[3]
) {
    if (camera.focalLength <= 0.0 || image.width <= 0 || image.height <= 0) {
        return false;
    }
    const cv::Mat intrinsics = make_intrinsics(
        camera.focalLength,
        image.width,
        image.height,
        camera.principalOffsetX,
        camera.principalOffsetY
    );
    const cv::Mat distortion = (cv::Mat_<double>(1, 5) <<
        camera.k1,
        camera.k2,
        camera.p1,
        camera.p2,
        camera.k3
    );
    const std::vector<cv::Point2d> pixel = {cv::Point2d(x, y)};
    std::vector<cv::Point2d> undistorted;
    cv::undistortPoints(pixel, undistorted, intrinsics, distortion);
    if (undistorted.empty()
        || !std::isfinite(undistorted[0].x)
        || !std::isfinite(undistorted[0].y)) {
        return false;
    }
    const double rayCamera[3] = {undistorted[0].x, undistorted[0].y, 1.0};
    rotate_angle_axis_point_double(camera.rotation, rayCamera, rayWorld);
    return std::isfinite(rayWorld[0])
        && std::isfinite(rayWorld[1])
        && std::isfinite(rayWorld[2]);
}

static double camera_projection_rms_error(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &points,
    const std::string &projection
) {
    std::vector<double> focals;
    focals.reserve(cameras.size());
    for (const NativeCameraParams &camera : cameras) {
        if (std::isfinite(camera.focalLength) && camera.focalLength > 0.0) {
            focals.push_back(camera.focalLength);
        }
    }
    if (focals.empty()) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    const double scale = median_value(focals);
    double sumSquared = 0.0;
    int count = 0;
    const std::string mode = lower_string(projection);
    for (const NativeControlPoint &point : points) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(cameras.size())
            || point.imageBIndex >= static_cast<int>(cameras.size())
            || point.imageAIndex >= static_cast<int>(images.size())
            || point.imageBIndex >= static_cast<int>(images.size())) {
            continue;
        }
        double rayA[3] = {0.0, 0.0, 0.0};
        double rayB[3] = {0.0, 0.0, 0.0};
        if (!native_pixel_to_world_ray(
                cameras[static_cast<size_t>(point.imageAIndex)],
                images[static_cast<size_t>(point.imageAIndex)],
                point.xA,
                point.yA,
                rayA
            )
            || !native_pixel_to_world_ray(
                cameras[static_cast<size_t>(point.imageBIndex)],
                images[static_cast<size_t>(point.imageBIndex)],
                point.xB,
                point.yB,
                rayB
            )) {
            continue;
        }
        double uA = 0.0;
        double vA = 0.0;
        double uB = 0.0;
        double vB = 0.0;
        if (!native_project_ray(rayA, projection, uA, vA)
            || !native_project_ray(rayB, projection, uB, vB)) {
            continue;
        }
        double deltaU = uA - uB;
        if (mode == "equirectangular" || mode == "cylindrical") {
            deltaU = std::atan2(std::sin(deltaU), std::cos(deltaU));
        }
        const double deltaV = vA - vB;
        const double error = std::sqrt(deltaU * deltaU + deltaV * deltaV) * scale;
        if (!std::isfinite(error)) {
            continue;
        }
        sumSquared += error * error;
        count += 1;
    }
    return count > 0
        ? std::sqrt(sumSquared / static_cast<double>(count))
        : std::numeric_limits<double>::quiet_NaN();
}

#if MYPTGUI_HAS_CERES_HEADERS
struct NativeCameraResidual {
    NativeControlPoint point;
    double sourceWidth = 0.0;
    double sourceHeight = 0.0;
    double targetWidth = 0.0;
    double targetHeight = 0.0;

    template <typename T>
    bool operator()(
        const T *const rotationA,
        const T *const rotationB,
        const T *const focal,
        const T *const distortion,
        const T *const principal,
        T *residuals
    ) const {
        const T sourceCx = T(sourceWidth) * (T(0.5) + principal[0]);
        const T sourceCy = T(sourceHeight) * (T(0.5) + principal[1]);
        const T targetCx = T(targetWidth) * (T(0.5) + principal[0]);
        const T targetCy = T(targetHeight) * (T(0.5) + principal[1]);
        auto undistort = [&](const T &observedX, const T &observedY, T &idealX, T &idealY) {
            idealX = observedX;
            idealY = observedY;
            for (int iteration = 0; iteration < 8; ++iteration) {
                const T r2 = idealX * idealX + idealY * idealY;
                const T r4 = r2 * r2;
                const T r6 = r4 * r2;
                const T radial = T(1.0)
                    + distortion[0] * r2
                    + distortion[1] * r4
                    + distortion[2] * r6;
                const T tangentX = T(2.0) * distortion[3] * idealX * idealY
                    + distortion[4] * (r2 + T(2.0) * idealX * idealX);
                const T tangentY = distortion[3] * (r2 + T(2.0) * idealY * idealY)
                    + T(2.0) * distortion[4] * idealX * idealY;
                idealX += observedX - (idealX * radial + tangentX);
                idealY += observedY - (idealY * radial + tangentY);
            }
        };
        T sourceX;
        T sourceY;
        T targetX;
        T targetY;
        undistort(
            (T(point.xA) - sourceCx) / focal[0],
            (T(point.yA) - sourceCy) / focal[0],
            sourceX,
            sourceY
        );
        undistort(
            (T(point.xB) - targetCx) / focal[0],
            (T(point.yB) - targetCy) / focal[0],
            targetX,
            targetY
        );
        const T cameraRayA[3] = {sourceX, sourceY, T(1.0)};
        const T cameraRayB[3] = {targetX, targetY, T(1.0)};
        T worldRayA[3];
        T worldRayB[3];
        ceres::AngleAxisRotatePoint(rotationA, cameraRayA, worldRayA);
        ceres::AngleAxisRotatePoint(rotationB, cameraRayB, worldRayB);
        const T normA = ceres::sqrt(
            worldRayA[0] * worldRayA[0]
            + worldRayA[1] * worldRayA[1]
            + worldRayA[2] * worldRayA[2]
            + T(1e-18)
        );
        const T normB = ceres::sqrt(
            worldRayB[0] * worldRayB[0]
            + worldRayB[1] * worldRayB[1]
            + worldRayB[2] * worldRayB[2]
            + T(1e-18)
        );
        // A shared tangent-space chord is invariant to whether the canonical
        // edge happened to be stored A→B or B→A. Scaling by focal keeps the
        // robust loss and legacy quality thresholds in pixel units.
        for (int axis = 0; axis < 3; ++axis) {
            residuals[axis] = focal[0]
                * (worldRayA[axis] / normA - worldRayB[axis] / normB);
        }
        return true;
    }
};

struct NativePrincipalPointPrior {
    std::array<double, 2> center = {0.0, 0.0};
    double weight = 1.0;

    template <typename T>
    bool operator()(const T *const principal, T *residuals) const {
        const T scale = T(std::sqrt(std::max(weight, 1e-6)) / 0.01);
        residuals[0] = (principal[0] - T(center[0])) * scale;
        residuals[1] = (principal[1] - T(center[1])) * scale;
        return true;
    }
};

struct NativeDistortionPrior {
    std::array<double, 5> center = {0.0, 0.0, 0.0, 0.0, 0.0};
    double weight = 1.0;

    template <typename T>
    bool operator()(const T *const distortion, T *residuals) const {
        const T scale = T(std::sqrt(std::max(weight, 1e-6)));
        residuals[0] = scale * (distortion[0] - T(center[0])) / T(0.12);
        residuals[1] = scale * (distortion[1] - T(center[1])) / T(0.12);
        residuals[2] = scale * (distortion[2] - T(center[2])) / T(0.08);
        residuals[3] = scale * (distortion[3] - T(center[3])) / T(0.02);
        residuals[4] = scale * (distortion[4] - T(center[4])) / T(0.02);
        return true;
    }
};

static std::vector<NativeControlPoint> spatially_limit_ceres_points_per_pair(
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &points,
    int maxPointsPerPair
) {
    const int limit = std::max(4, maxPointsPerPair);
    constexpr int gridSize = 8;
    using Pair = std::pair<int, int>;
    std::map<Pair, std::vector<NativeControlPoint>> grouped;
    for (const NativeControlPoint &point : points) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(images.size())
            || point.imageBIndex >= static_cast<int>(images.size())
            || point.imageAIndex == point.imageBIndex) {
            continue;
        }
        grouped[{std::min(point.imageAIndex, point.imageBIndex),
                 std::max(point.imageAIndex, point.imageBIndex)}].push_back(point);
    }

    std::vector<NativeControlPoint> limited;
    limited.reserve(std::min(points.size(), grouped.size() * static_cast<size_t>(limit)));
    for (auto &entry : grouped) {
        std::vector<NativeControlPoint> &pairPoints = entry.second;
        std::stable_sort(pairPoints.begin(), pairPoints.end(), [](const NativeControlPoint &lhs, const NativeControlPoint &rhs) {
            if (lhs.isManual != rhs.isManual) {
                return lhs.isManual;
            }
            const double lhsError = std::isfinite(lhs.error) ? lhs.error : std::numeric_limits<double>::infinity();
            const double rhsError = std::isfinite(rhs.error) ? rhs.error : std::numeric_limits<double>::infinity();
            return lhsError < rhsError;
        });
        if (static_cast<int>(pairPoints.size()) <= limit) {
            limited.insert(limited.end(), pairPoints.begin(), pairPoints.end());
            continue;
        }

        const int lowIndex = entry.first.first;
        const int highIndex = entry.first.second;
        const NativeImage &lowImage = images[static_cast<size_t>(lowIndex)];
        const NativeImage &highImage = images[static_cast<size_t>(highIndex)];
        using Cell = std::array<int, 4>;
        std::map<Cell, std::vector<size_t>> cells;
        for (size_t idx = 0; idx < pairPoints.size(); ++idx) {
            const NativeControlPoint &point = pairPoints[idx];
            const bool forward = point.imageAIndex == lowIndex;
            const double lowX = forward ? point.xA : point.xB;
            const double lowY = forward ? point.yA : point.yB;
            const double highX = forward ? point.xB : point.xA;
            const double highY = forward ? point.yB : point.yA;
            auto cellCoordinate = [](double value, int extent) {
                if (!std::isfinite(value) || extent <= 0) {
                    return 0;
                }
                return std::max(0, std::min(
                    gridSize - 1,
                    static_cast<int>(std::floor(value * static_cast<double>(gridSize) / static_cast<double>(extent)))
                ));
            };
            cells[{
                cellCoordinate(lowX, lowImage.width),
                cellCoordinate(lowY, lowImage.height),
                cellCoordinate(highX, highImage.width),
                cellCoordinate(highY, highImage.height)
            }].push_back(idx);
        }

        std::vector<bool> selected(pairPoints.size(), false);
        int selectedForPair = 0;
        // User-authored points participate in the same robust fit, but they are
        // never silently displaced by a denser automatic feature cluster.
        for (size_t idx = 0; idx < pairPoints.size() && selectedForPair < limit; ++idx) {
            if (!pairPoints[idx].isManual) {
                continue;
            }
            limited.push_back(pairPoints[idx]);
            selected[idx] = true;
            selectedForPair += 1;
        }
        for (size_t depth = 0; selectedForPair < limit; ++depth) {
            bool hadDepthEntries = false;
            for (const auto &cell : cells) {
                if (depth >= cell.second.size()) {
                    continue;
                }
                hadDepthEntries = true;
                const size_t index = cell.second[depth];
                if (!selected[index]) {
                    limited.push_back(pairPoints[index]);
                    selected[index] = true;
                    selectedForPair += 1;
                    if (selectedForPair >= limit) {
                        break;
                    }
                }
            }
            if (selectedForPair >= limit || !hadDepthEntries) {
                break;
            }
        }
    }
    return limited;
}

static bool run_ceres_camera_adjustment(
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &points,
    bool optimizeFocal,
    bool optimizeDistortion,
    int maxIterations,
    std::vector<NativeCameraParams> &cameras,
    std::string &solverSummary,
    double fixedInitialFocal = 0.0,
    bool optimizePrincipalPoint = false,
    const NativeLensCalibrationPrior *lensPrior = nullptr
) {
    const std::vector<NativeControlPoint> solverPoints = spatially_limit_ceres_points_per_pair(images, points, 128);
    if (images.size() < 2 || solverPoints.size() < 3 || cameras.size() != images.size()) {
        solverSummary = "not enough images or control points";
        return false;
    }

    std::vector<std::array<double, 3>> rotations;
    rotations.reserve(cameras.size());
    for (const NativeCameraParams &camera : cameras) {
        rotations.push_back(camera.rotation);
    }
    const double focalReference = std::max(
        50.0,
        std::isfinite(fixedInitialFocal) && fixedInitialFocal > 0.0
            ? fixedInitialFocal
            : cameras.front().focalLength
    );
    std::array<double, 1> focal = {std::max(50.0, cameras.front().focalLength)};
    std::array<double, 5> distortion = camera_distortion_values(cameras.front());
    std::array<double, 2> principal = {
        cameras.front().principalOffsetX,
        cameras.front().principalOffsetY
    };

    ceres::Problem problem;
    for (std::array<double, 3> &rotation : rotations) {
        problem.AddParameterBlock(rotation.data(), 3);
    }
    problem.SetParameterBlockConstant(rotations.front().data());
    problem.AddParameterBlock(focal.data(), 1);
    if (!optimizeFocal) {
        problem.SetParameterBlockConstant(focal.data());
    } else {
        const double focalLowerBound = std::max(50.0, focalReference * 0.25);
        const double focalUpperBound = focalReference * 4.0;
        if (focal[0] < focalLowerBound || focal[0] > focalUpperBound) {
            std::ostringstream reason;
            reason << "initial focal " << focal[0]
                   << " is outside fixed bounds [" << focalLowerBound
                   << ", " << focalUpperBound << "]";
            solverSummary = reason.str();
            return false;
        }
        problem.SetParameterLowerBound(focal.data(), 0, focalLowerBound);
        problem.SetParameterUpperBound(focal.data(), 0, focalUpperBound);
    }
    problem.AddParameterBlock(distortion.data(), static_cast<int>(distortion.size()));
    if (!optimizeDistortion) {
        problem.SetParameterBlockConstant(distortion.data());
    } else {
        problem.SetParameterLowerBound(distortion.data(), 0, -0.25);
        problem.SetParameterUpperBound(distortion.data(), 0, 0.25);
        problem.SetParameterLowerBound(distortion.data(), 1, -0.15);
        problem.SetParameterUpperBound(distortion.data(), 1, 0.15);
        problem.SetParameterLowerBound(distortion.data(), 2, -0.10);
        problem.SetParameterUpperBound(distortion.data(), 2, 0.10);
        problem.SetParameterLowerBound(distortion.data(), 3, -0.05);
        problem.SetParameterUpperBound(distortion.data(), 3, 0.05);
        problem.SetParameterLowerBound(distortion.data(), 4, -0.05);
        problem.SetParameterUpperBound(distortion.data(), 4, 0.05);
        NativeDistortionPrior distortionPrior;
        if (lensPrior != nullptr && lensPrior->available) {
            distortionPrior.center = lensPrior->distortion;
            distortionPrior.weight = lensPrior->priorWeight;
        }
        ceres::CostFunction *prior = new ceres::AutoDiffCostFunction<NativeDistortionPrior, 5, 5>(
            new NativeDistortionPrior(distortionPrior)
        );
        problem.AddResidualBlock(prior, nullptr, distortion.data());
    }
    problem.AddParameterBlock(principal.data(), static_cast<int>(principal.size()));
    if (!optimizePrincipalPoint) {
        problem.SetParameterBlockConstant(principal.data());
    } else {
        problem.SetParameterLowerBound(principal.data(), 0, -0.05);
        problem.SetParameterUpperBound(principal.data(), 0, 0.05);
        problem.SetParameterLowerBound(principal.data(), 1, -0.05);
        problem.SetParameterUpperBound(principal.data(), 1, 0.05);
        NativePrincipalPointPrior principalPrior;
        if (lensPrior != nullptr && lensPrior->available) {
            principalPrior.center = lensPrior->principal;
            principalPrior.weight = lensPrior->priorWeight;
        }
        ceres::CostFunction *prior = new ceres::AutoDiffCostFunction<NativePrincipalPointPrior, 2, 2>(
            new NativePrincipalPointPrior(principalPrior)
        );
        problem.AddResidualBlock(prior, nullptr, principal.data());
    }

    for (const NativeControlPoint &point : solverPoints) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(images.size())
            || point.imageBIndex >= static_cast<int>(images.size())) {
            continue;
        }
        const NativeImage &imageA = images[static_cast<size_t>(point.imageAIndex)];
        const NativeImage &imageB = images[static_cast<size_t>(point.imageBIndex)];
        NativeCameraResidual *residual = new NativeCameraResidual{
            point,
            static_cast<double>(imageA.width),
            static_cast<double>(imageA.height),
            static_cast<double>(imageB.width),
            static_cast<double>(imageB.height)
        };
        ceres::CostFunction *cost = new ceres::AutoDiffCostFunction<NativeCameraResidual, 3, 3, 3, 1, 5, 2>(residual);
        problem.AddResidualBlock(
            cost,
            new ceres::HuberLoss(3.0),
            rotations[static_cast<size_t>(point.imageAIndex)].data(),
            rotations[static_cast<size_t>(point.imageBIndex)].data(),
            focal.data(),
            distortion.data(),
            principal.data()
        );
    }

    ceres::Solver::Options options;
    options.max_num_iterations = std::max(1, maxIterations);
    options.linear_solver_type = ceres::DENSE_QR;
    options.minimizer_progress_to_stdout = false;
    ceres::Solver::Summary summary;
    ceres::Solve(options, &problem, &summary);
    solverSummary = summary.BriefReport();
    if (!summary.IsSolutionUsable() || summary.termination_type == ceres::NO_CONVERGENCE) {
        if (summary.termination_type == ceres::NO_CONVERGENCE) {
            solverSummary += "; rejected termination=NO_CONVERGENCE";
        }
        return false;
    }

    for (size_t idx = 0; idx < cameras.size(); ++idx) {
        cameras[idx].rotation = rotations[idx];
        cameras[idx].focalLength = focal[0];
        cameras[idx].k1 = distortion[0];
        cameras[idx].k2 = distortion[1];
        cameras[idx].k3 = distortion[2];
        cameras[idx].p1 = distortion[3];
        cameras[idx].p2 = distortion[4];
        cameras[idx].principalOffsetX = principal[0];
        cameras[idx].principalOffsetY = principal[1];
    }
    return true;
}
#endif

static void apply_camera_errors_to_control_points(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    std::vector<NativeControlPoint> &points
) {
    for (NativeControlPoint &point : points) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(cameras.size())
            || point.imageBIndex >= static_cast<int>(cameras.size())) {
            continue;
        }
        point.error = native_camera_reprojection_error(
            cameras[static_cast<size_t>(point.imageAIndex)],
            cameras[static_cast<size_t>(point.imageBIndex)],
            images[static_cast<size_t>(point.imageAIndex)],
            images[static_cast<size_t>(point.imageBIndex)],
            point
        );
    }
}

static int manual_control_point_count(const std::vector<NativeControlPoint> &points) {
    return static_cast<int>(std::count_if(
        points.begin(),
        points.end(),
        [](const NativeControlPoint &point) { return point.isManual; }
    ));
}

static NativeManualPointFilteringReport manual_point_filtering_report(
    const std::vector<NativeControlPoint> &input,
    const std::vector<NativeControlPoint> &accepted,
    const std::string &reason
) {
    NativeManualPointFilteringReport report;
    report.available = true;
    report.input = manual_control_point_count(input);
    report.accepted = manual_control_point_count(accepted);
    report.rejected = std::max(0, report.input - report.accepted);
    if (report.input == 0) {
        report.reason = "no manual control points were supplied";
    } else if (report.rejected == 0) {
        report.reason = "all manual control points passed robust filtering";
    } else {
        report.reason = reason;
    }
    return report;
}

static std::vector<NativeControlPoint> dedupe_edited_control_points(
    std::vector<NativeControlPoint> points,
    double tolerance
) {
    std::stable_sort(points.begin(), points.end(), [](const NativeControlPoint &lhs, const NativeControlPoint &rhs) {
        if (lhs.isManual != rhs.isManual) {
            return lhs.isManual;
        }
        const double lhsError = std::isfinite(lhs.error)
            ? lhs.error
            : std::numeric_limits<double>::infinity();
        const double rhsError = std::isfinite(rhs.error)
            ? rhs.error
            : std::numeric_limits<double>::infinity();
        return lhsError < rhsError;
    });
    const double toleranceSquared = tolerance * tolerance;
    std::vector<NativeControlPoint> deduped;
    deduped.reserve(points.size());
    for (const NativeControlPoint &point : points) {
        const bool duplicate = std::any_of(deduped.begin(), deduped.end(), [&](const NativeControlPoint &existing) {
            const bool sameDirection = point.imageAIndex == existing.imageAIndex
                && point.imageBIndex == existing.imageBIndex;
            const bool reverseDirection = point.imageAIndex == existing.imageBIndex
                && point.imageBIndex == existing.imageAIndex;
            if (!sameDirection && !reverseDirection) {
                return false;
            }
            const double sourceDx = point.xA - (sameDirection ? existing.xA : existing.xB);
            const double sourceDy = point.yA - (sameDirection ? existing.yA : existing.yB);
            const double targetDx = point.xB - (sameDirection ? existing.xB : existing.xA);
            const double targetDy = point.yB - (sameDirection ? existing.yB : existing.yA);
            return sourceDx * sourceDx + sourceDy * sourceDy <= toleranceSquared
                && targetDx * targetDx + targetDy * targetDy <= toleranceSquared;
        });
        if (!duplicate) {
            deduped.push_back(point);
        }
    }
    return deduped;
}

static bool valid_edited_control_point_observation(
    const NativeControlPoint &point,
    const std::vector<NativeImage> &images
) {
    if (point.imageAIndex < 0 || point.imageBIndex < 0
        || point.imageAIndex >= static_cast<int>(images.size())
        || point.imageBIndex >= static_cast<int>(images.size())
        || point.imageAIndex == point.imageBIndex) {
        return false;
    }
    if (!std::isfinite(point.xA) || !std::isfinite(point.yA)
        || !std::isfinite(point.xB) || !std::isfinite(point.yB)) {
        return false;
    }
    const NativeImage &imageA = images[static_cast<size_t>(point.imageAIndex)];
    const NativeImage &imageB = images[static_cast<size_t>(point.imageBIndex)];
    return point.xA >= 0.0 && point.yA >= 0.0
        && point.xB >= 0.0 && point.yB >= 0.0
        && point.xA <= static_cast<double>(std::max(0, imageA.width - 1))
        && point.yA <= static_cast<double>(std::max(0, imageA.height - 1))
        && point.xB <= static_cast<double>(std::max(0, imageB.width - 1))
        && point.yB <= static_cast<double>(std::max(0, imageB.height - 1));
}

#if MYPTGUI_HAS_CERES_HEADERS
static bool native_project_point_between_cameras(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    int sourceIndex,
    int targetIndex,
    const NativeStar &point,
    cv::Point2d &projected
) {
    if (sourceIndex < 0 || targetIndex < 0
        || sourceIndex >= static_cast<int>(cameras.size())
        || targetIndex >= static_cast<int>(cameras.size())
        || sourceIndex >= static_cast<int>(images.size())
        || targetIndex >= static_cast<int>(images.size())) {
        return false;
    }
    const NativeCameraParams &sourceCamera = cameras[static_cast<size_t>(sourceIndex)];
    const NativeCameraParams &targetCamera = cameras[static_cast<size_t>(targetIndex)];
    const NativeImage &sourceImage = images[static_cast<size_t>(sourceIndex)];
    const NativeImage &targetImage = images[static_cast<size_t>(targetIndex)];
    if (sourceCamera.focalLength <= 0.0 || targetCamera.focalLength <= 0.0) {
        return false;
    }

    cv::Mat sourceK = make_intrinsics(
        sourceCamera.focalLength,
        sourceImage.width,
        sourceImage.height,
        sourceCamera.principalOffsetX,
        sourceCamera.principalOffsetY
    );
    cv::Mat sourceDist = (cv::Mat_<double>(1, 5) <<
        sourceCamera.k1,
        sourceCamera.k2,
        sourceCamera.p1,
        sourceCamera.p2,
        sourceCamera.k3
    );
    std::vector<cv::Point2d> sourcePoint = {cv::Point2d(point.x, point.y)};
    std::vector<cv::Point2d> undistorted;
    cv::undistortPoints(sourcePoint, undistorted, sourceK, sourceDist);
    if (undistorted.empty() || !std::isfinite(undistorted[0].x) || !std::isfinite(undistorted[0].y)) {
        return false;
    }

    const double raySource[3] = {undistorted[0].x, undistorted[0].y, 1.0};
    double rayWorld[3] = {0.0, 0.0, 0.0};
    rotate_angle_axis_point_double(sourceCamera.rotation, raySource, rayWorld);
    const std::array<double, 3> inverseTargetRotation = {
        -targetCamera.rotation[0],
        -targetCamera.rotation[1],
        -targetCamera.rotation[2]
    };
    double rayTarget[3] = {0.0, 0.0, 0.0};
    rotate_angle_axis_point_double(inverseTargetRotation, rayWorld, rayTarget);
    if (std::abs(rayTarget[2]) < 1e-12) {
        return false;
    }

    const double x = rayTarget[0] / rayTarget[2];
    const double y = rayTarget[1] / rayTarget[2];
    double distortedX = x;
    double distortedY = y;
    apply_brown_conrady_distortion_double(x, y, camera_distortion_values(targetCamera), distortedX, distortedY);
    projected.x = distortedX * targetCamera.focalLength + native_camera_principal_x(targetCamera, targetImage);
    projected.y = distortedY * targetCamera.focalLength + native_camera_principal_y(targetCamera, targetImage);
    return std::isfinite(projected.x) && std::isfinite(projected.y);
}

static bool point_inside_image(const cv::Point2d &point, const NativeImage &image) {
    return point.x >= 0.0
        && point.y >= 0.0
        && point.x < static_cast<double>(image.width)
        && point.y < static_cast<double>(image.height);
}

static NativeResidualSummary residual_summary(const std::vector<double> &values) {
    NativeResidualSummary summary;
    if (values.empty()) {
        return summary;
    }
    double sumSquared = 0.0;
    std::vector<double> finite;
    finite.reserve(values.size());
    for (double value : values) {
        if (std::isfinite(value)) {
            sumSquared += value * value;
            finite.push_back(value);
        }
    }
    if (finite.empty()) {
        return summary;
    }
    summary.count = static_cast<int>(finite.size());
    summary.rms = std::sqrt(sumSquared / static_cast<double>(finite.size()));
    summary.p95 = percentile_value(finite, 95.0);
    return summary;
}

static std::string residual_summary_json(const NativeResidualSummary &summary) {
    std::ostringstream out;
    out << "{";
    out << "\"count\":" << summary.count << ",";
    out << "\"rms\":" << number_json(summary.rms) << ",";
    out << "\"p95\":" << number_json(summary.p95);
    out << "}";
    return out.str();
}

static NativeStarProjectionAlignmentReport native_star_projection_alignment_report(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<std::vector<NativeStar>> &starSources,
    const std::vector<NativeSelectedEdge> &selectedEdges,
    const panolume::EngineRequest &request
) {
    NativeStarProjectionAlignmentReport report;
    std::vector<double> nearestResiduals;
    std::vector<double> mutualResiduals;
    std::vector<double> highConfidenceResiduals;
    const double nearestRadius = 24.0;
    const double mutualRadius = std::max(
        0.5,
        request.number("cameraModelMaxMutualStarP95Px", 12.0)
    );
    // A point cannot be called high-confidence at a wider radius than the
    // quality gate that evaluates that set.  The old hard-coded 5 px radius
    // followed by a 4 px P95 gate made a valid dense star field fail solely
    // because 4...5 px observations had first been labelled high-confidence.
    const double highConfidenceRadius = std::max(
        0.5,
        request.number("cameraModelMaxHighConfidenceStarP95Px", 4.0)
    );
    if (cameras.size() != images.size() || starSources.size() != images.size() || selectedEdges.empty()) {
        report.available = false;
        report.reason = "camera/star inputs unavailable";
        return report;
    }
    report.available = true;

    for (const NativeSelectedEdge &edge : selectedEdges) {
        if (edge.i < 0 || edge.j < 0
            || edge.i >= static_cast<int>(starSources.size())
            || edge.j >= static_cast<int>(starSources.size())) {
            continue;
        }
        const std::vector<NativeStar> sourceStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(edge.i)], 1200, 5);
        const std::vector<NativeStar> targetStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(edge.j)], 1200, 5);
        if (sourceStars.empty() || targetStars.empty()) {
            continue;
        }
        NativePointIndex targetIndex(targetStars, nearestRadius);
        NativePointIndex sourceIndex(sourceStars, mutualRadius);
        for (int sourceIdx = 0; sourceIdx < static_cast<int>(sourceStars.size()); ++sourceIdx) {
            report.attemptedStars += 1;
            cv::Point2d projected;
            if (!native_project_point_between_cameras(
                    cameras,
                    images,
                    edge.i,
                    edge.j,
                    sourceStars[static_cast<size_t>(sourceIdx)],
                    projected
                )
                || !point_inside_image(projected, images[static_cast<size_t>(edge.j)])) {
                continue;
            }
            report.projectedInBounds += 1;
            int targetIdx = -1;
            double nearestDistance = 0.0;
            if (!targetIndex.nearest(projected, nearestRadius, targetIdx, nearestDistance)) {
                continue;
            }
            nearestResiduals.push_back(nearestDistance);

            cv::Point2d projectedBack;
            if (!native_project_point_between_cameras(
                    cameras,
                    images,
                    edge.j,
                    edge.i,
                    targetStars[static_cast<size_t>(targetIdx)],
                    projectedBack
                )
                || !point_inside_image(projectedBack, images[static_cast<size_t>(edge.i)])) {
                continue;
            }
            int nearestSourceIdx = -1;
            double backDistance = 0.0;
            if (!sourceIndex.nearest(projectedBack, mutualRadius, nearestSourceIdx, backDistance)
                || nearestSourceIdx != sourceIdx
                || nearestDistance > mutualRadius
                || backDistance > mutualRadius) {
                continue;
            }
            mutualResiduals.push_back(nearestDistance);
            if (nearestDistance <= highConfidenceRadius && backDistance <= highConfidenceRadius) {
                highConfidenceResiduals.push_back(nearestDistance);
            }
        }
    }
    report.nearest = residual_summary(nearestResiduals);
    report.mutual = residual_summary(mutualResiduals);
    report.highConfidence = residual_summary(highConfidenceResiduals);
    return report;
}

static std::string native_star_projection_alignment_json(const NativeStarProjectionAlignmentReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"available\":" << bool_json(report.available);
    if (!report.available) {
        out << ",\"reason\":\"" << json_escape(report.reason) << "\"";
    } else {
        out << ",";
        out << "\"attempted_stars\":" << report.attemptedStars << ",";
        out << "\"projected_in_bounds\":" << report.projectedInBounds << ",";
        out << "\"nearest\":" << residual_summary_json(report.nearest) << ",";
        out << "\"mutual\":" << residual_summary_json(report.mutual) << ",";
        out << "\"high_confidence\":" << residual_summary_json(report.highConfidence);
    }
    out << "}";
    return out.str();
}

static bool duplicate_control_point(
    const NativeControlPoint &candidate,
    const std::vector<NativeControlPoint> &existing,
    double tolerance
) {
    const double toleranceSq = tolerance * tolerance;
    for (const NativeControlPoint &point : existing) {
        if (candidate.imageAIndex == point.imageAIndex && candidate.imageBIndex == point.imageBIndex) {
            const double dax = candidate.xA - point.xA;
            const double day = candidate.yA - point.yA;
            const double dbx = candidate.xB - point.xB;
            const double dby = candidate.yB - point.yB;
            if (dax * dax + day * day <= toleranceSq && dbx * dbx + dby * dby <= toleranceSq) {
                return true;
            }
        }
        if (candidate.imageAIndex == point.imageBIndex && candidate.imageBIndex == point.imageAIndex) {
            const double dax = candidate.xA - point.xB;
            const double day = candidate.yA - point.yB;
            const double dbx = candidate.xB - point.xA;
            const double dby = candidate.yB - point.yA;
            if (dax * dax + day * day <= toleranceSq && dbx * dbx + dby * dby <= toleranceSq) {
                return true;
            }
        }
    }
    return false;
}

static std::pair<int, int> guided_point_cell(double x, double y, const NativeImage &image, int gridSize) {
    if (image.width <= 0 || image.height <= 0 || gridSize <= 1) {
        return {0, 0};
    }
    int col = static_cast<int>(std::floor((x / static_cast<double>(image.width)) * static_cast<double>(gridSize)));
    int row = static_cast<int>(std::floor((y / static_cast<double>(image.height)) * static_cast<double>(gridSize)));
    col = std::max(0, std::min(gridSize - 1, col));
    row = std::max(0, std::min(gridSize - 1, row));
    return {row, col};
}

static std::vector<NativeControlPoint> limit_guided_points_spatially(
    std::vector<NativeControlPoint> points,
    const NativeImage &sourceImage,
    const NativeImage &targetImage,
    int maxPoints,
    int gridSize
) {
    if (points.empty()) {
        return points;
    }
    maxPoints = std::max(1, maxPoints);
    gridSize = std::max(1, gridSize);
    std::sort(points.begin(), points.end(), [](const NativeControlPoint &a, const NativeControlPoint &b) {
        return a.error < b.error;
    });
    if (static_cast<int>(points.size()) <= maxPoints) {
        return points;
    }

    const int perCell = std::max(1, static_cast<int>(std::ceil(static_cast<double>(maxPoints) / static_cast<double>(gridSize * gridSize))));
    std::map<std::pair<int, int>, int> sourceCounts;
    std::map<std::pair<int, int>, int> targetCounts;
    std::vector<bool> selected(points.size(), false);
    std::vector<NativeControlPoint> limited;
    limited.reserve(static_cast<size_t>(maxPoints));

    auto addPoint = [&](size_t idx) {
        const NativeControlPoint &point = points[idx];
        const std::pair<int, int> sourceCell = guided_point_cell(point.xA, point.yA, sourceImage, gridSize);
        const std::pair<int, int> targetCell = guided_point_cell(point.xB, point.yB, targetImage, gridSize);
        limited.push_back(point);
        selected[idx] = true;
        sourceCounts[sourceCell] += 1;
        targetCounts[targetCell] += 1;
    };

    for (size_t idx = 0; idx < points.size() && static_cast<int>(limited.size()) < maxPoints; ++idx) {
        const NativeControlPoint &point = points[idx];
        const std::pair<int, int> sourceCell = guided_point_cell(point.xA, point.yA, sourceImage, gridSize);
        const std::pair<int, int> targetCell = guided_point_cell(point.xB, point.yB, targetImage, gridSize);
        if (sourceCounts[sourceCell] >= perCell || targetCounts[targetCell] >= perCell) {
            continue;
        }
        addPoint(idx);
    }
    for (size_t idx = 0; idx < points.size() && static_cast<int>(limited.size()) < maxPoints; ++idx) {
        if (selected[idx]) {
            continue;
        }
        const NativeControlPoint &point = points[idx];
        const std::pair<int, int> sourceCell = guided_point_cell(point.xA, point.yA, sourceImage, gridSize);
        const std::pair<int, int> targetCell = guided_point_cell(point.xB, point.yB, targetImage, gridSize);
        if (sourceCounts[sourceCell] == 0 || targetCounts[targetCell] == 0) {
            addPoint(idx);
        }
    }
    for (size_t idx = 0; idx < points.size() && static_cast<int>(limited.size()) < maxPoints; ++idx) {
        if (!selected[idx]) {
            addPoint(idx);
        }
    }
    return limited;
}

static std::vector<NativeControlPoint> dedupe_control_points(std::vector<NativeControlPoint> points, double tolerance) {
    std::stable_sort(points.begin(), points.end(), [](const NativeControlPoint &a, const NativeControlPoint &b) {
        if (a.isManual != b.isManual) {
            return a.isManual;
        }
        const double aError = std::isfinite(a.error)
            ? a.error
            : std::numeric_limits<double>::infinity();
        const double bError = std::isfinite(b.error)
            ? b.error
            : std::numeric_limits<double>::infinity();
        return aError < bError;
    });
    std::vector<NativeControlPoint> deduped;
    deduped.reserve(points.size());
    for (const NativeControlPoint &point : points) {
        if (!duplicate_control_point(point, deduped, tolerance)) {
            deduped.push_back(point);
        }
    }
    return deduped;
}

static std::vector<NativeControlPoint> guided_star_points_for_pair(
    int i,
    int j,
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<std::vector<NativeStar>> &starSources,
    const std::vector<NativeControlPoint> &existingPoints,
    double threshold,
    int maxPoints,
    NativeGuidedPairReport &report
) {
    report.i = i;
    report.j = j;
    report.thresholdPx = threshold;
    if (i < 0 || j < 0 || i >= static_cast<int>(starSources.size()) || j >= static_cast<int>(starSources.size())) {
        report.reason = "star detections unavailable for pair";
        return {};
    }

    const std::vector<NativeStar> sourceStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(i)], 4000, 5);
    const std::vector<NativeStar> targetStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(j)], 4000, 5);
    report.sourceStars = static_cast<int>(sourceStars.size());
    report.targetStars = static_cast<int>(targetStars.size());
    if (sourceStars.empty() || targetStars.empty()) {
        report.reason = "not enough stars for guided matching";
        return {};
    }

    const double backThreshold = threshold * 1.5;
    NativePointIndex targetIndex(targetStars, threshold);
    NativePointIndex sourceIndex(sourceStars, backThreshold);
    struct GuidedCandidate {
        double distance = 0.0;
        int sourceIdx = 0;
        int targetIdx = 0;
    };
    std::vector<GuidedCandidate> candidates;
    for (int sourceIdx = 0; sourceIdx < static_cast<int>(sourceStars.size()); ++sourceIdx) {
        cv::Point2d projected;
        if (!native_project_point_between_cameras(cameras, images, i, j, sourceStars[static_cast<size_t>(sourceIdx)], projected)
            || !point_inside_image(projected, images[static_cast<size_t>(j)])) {
            continue;
        }
        int targetIdx = -1;
        double distance = 0.0;
        if (!targetIndex.nearest(projected, threshold, targetIdx, distance)) {
            continue;
        }
        cv::Point2d projectedBack;
        if (!native_project_point_between_cameras(cameras, images, j, i, targetStars[static_cast<size_t>(targetIdx)], projectedBack)
            || !point_inside_image(projectedBack, images[static_cast<size_t>(i)])) {
            continue;
        }
        int nearestSourceIdx = -1;
        double backDistance = 0.0;
        if (!sourceIndex.nearest(projectedBack, backThreshold, nearestSourceIdx, backDistance) || nearestSourceIdx != sourceIdx) {
            continue;
        }
        GuidedCandidate candidate;
        candidate.distance = distance;
        candidate.sourceIdx = sourceIdx;
        candidate.targetIdx = targetIdx;
        candidates.push_back(candidate);
    }
    report.candidateMatches = static_cast<int>(candidates.size());
    if (candidates.empty()) {
        report.reason = "guided camera projection found no mutual star matches";
        return {};
    }
    std::sort(candidates.begin(), candidates.end(), [](const GuidedCandidate &a, const GuidedCandidate &b) {
        return a.distance < b.distance;
    });

    std::set<int> usedSources;
    std::set<int> usedTargets;
    std::vector<NativeControlPoint> points;
    points.reserve(candidates.size());
    for (const GuidedCandidate &candidate : candidates) {
        if (usedSources.count(candidate.sourceIdx) > 0 || usedTargets.count(candidate.targetIdx) > 0) {
            continue;
        }
        NativeControlPoint cp;
        cp.imageAIndex = i;
        cp.imageBIndex = j;
        cp.xA = sourceStars[static_cast<size_t>(candidate.sourceIdx)].x;
        cp.yA = sourceStars[static_cast<size_t>(candidate.sourceIdx)].y;
        cp.xB = targetStars[static_cast<size_t>(candidate.targetIdx)].x;
        cp.yB = targetStars[static_cast<size_t>(candidate.targetIdx)].y;
        cp.error = candidate.distance;
        native_copy_psf_to_control_point(
            cp,
            sourceStars[static_cast<size_t>(candidate.sourceIdx)],
            targetStars[static_cast<size_t>(candidate.targetIdx)]
        );
        if (duplicate_control_point(cp, existingPoints, 2.0) || duplicate_control_point(cp, points, 2.0)) {
            continue;
        }
        usedSources.insert(candidate.sourceIdx);
        usedTargets.insert(candidate.targetIdx);
        points.push_back(cp);
    }
    points = limit_guided_points_spatially(
        std::move(points),
        images[static_cast<size_t>(i)],
        images[static_cast<size_t>(j)],
        maxPoints,
        4
    );
    report.addedControlPoints = static_cast<int>(points.size());
    if (points.empty()) {
        report.reason = "all guided matches were duplicates or failed spatial selection";
    } else {
        report.reason = "guided star points selected";
    }
    return points;
}

static NativeStarMatch native_star_match_from_guided_points(
    const std::vector<NativeControlPoint> &points,
    const std::vector<NativeStar> &referenceA,
    const std::vector<NativeStar> &referenceB,
    const NativeStarSettings &settings
) {
    NativeStarMatch match;
    for (const NativeControlPoint &point : points) {
        NativeStar a;
        a.x = point.xA;
        a.y = point.yA;
        a.sigma = std::max(point.sourceFWHM / 2.354820045, 0.5);
        NativeStar b;
        b.x = point.xB;
        b.y = point.yB;
        b.sigma = std::max(point.targetFWHM / 2.354820045, 0.5);
        match.pointsA.push_back(a);
        match.pointsB.push_back(b);
        match.errors.push_back(point.error);
    }
    if (static_cast<int>(match.pointsA.size()) < settings.minInliers
        || !estimate_affine_transform(match.pointsA, match.pointsB, match.affine)) {
        match.reason = "camera-guided full-resolution stars are insufficient";
        return match;
    }
    NativeMatchedStars matched;
    matched.pointsA = match.pointsA;
    matched.pointsB = match.pointsB;
    matched.errors = match.errors;
    const NativeCoverageQualityValues coverage = native_coverage_quality(
        matched,
        referenceA,
        referenceB,
        std::max(1, settings.spatialGridSize)
    );
    match.coverageBBoxAreaA = coverage.bboxAreaA;
    match.coverageBBoxAreaB = coverage.bboxAreaB;
    match.coverageGridOccupancyA = coverage.gridOccupancyA;
    match.coverageGridOccupancyB = coverage.gridOccupancyB;
    match.adaptiveBBoxAreaA = coverage.bboxAreaA;
    match.adaptiveBBoxAreaB = coverage.bboxAreaB;
    match.adaptiveGridOccupancyA = coverage.gridOccupancyA;
    match.adaptiveGridOccupancyB = coverage.gridOccupancyB;
    match.coverageInliers = static_cast<int>(match.pointsA.size());
    match.adaptiveCoverageAttempted = true;
    match.adaptiveCoverageAccepted = true;
    match.adaptiveCoverageInliers = match.coverageInliers;
    match.success = true;
    return match;
}

struct NativeLocalCandidate {
    int sourceIdx = 0;
    int targetIdx = 0;
    double distance = 0.0;
    double offsetX = 0.0;
    double offsetY = 0.0;
    double score = 0.0;
    double patchScore = 0.0;
};

static std::vector<double> native_star_flux_ranks(const std::vector<NativeStar> &stars) {
    std::vector<int> order(stars.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        return stars[static_cast<size_t>(a)].flux > stars[static_cast<size_t>(b)].flux;
    });
    std::vector<double> ranks(stars.size(), 0.0);
    const double denom = std::max(1.0, static_cast<double>(stars.size() - 1));
    for (int rank = 0; rank < static_cast<int>(order.size()); ++rank) {
        ranks[static_cast<size_t>(order[static_cast<size_t>(rank)])] = static_cast<double>(rank) / denom;
    }
    return ranks;
}

static std::vector<std::array<double, 3>> native_star_neighbor_signatures(const std::vector<NativeStar> &stars) {
    std::vector<std::array<double, 3>> signatures(stars.size(), {1.0, 1.0, 1.0});
    if (stars.size() < 4) {
        return signatures;
    }
    for (size_t idx = 0; idx < stars.size(); ++idx) {
        std::array<double, 4> nearest = {
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity()
        };
        for (size_t other = 0; other < stars.size(); ++other) {
            if (idx == other) {
                continue;
            }
            const double dx = stars[other].x - stars[idx].x;
            const double dy = stars[other].y - stars[idx].y;
            const double distance = std::sqrt(dx * dx + dy * dy);
            for (size_t slot = 0; slot < nearest.size(); ++slot) {
                if (distance < nearest[slot]) {
                    for (size_t move = nearest.size() - 1; move > slot; --move) {
                        nearest[move] = nearest[move - 1];
                    }
                    nearest[slot] = distance;
                    break;
                }
            }
        }
        const double scale = std::max(nearest[3], 1e-6);
        signatures[idx] = {
            std::isfinite(nearest[0]) ? nearest[0] / scale : 1.0,
            std::isfinite(nearest[1]) ? nearest[1] / scale : 1.0,
            std::isfinite(nearest[2]) ? nearest[2] / scale : 1.0
        };
    }
    return signatures;
}

static double native_signature_score(
    const std::array<double, 3> &source,
    const std::array<double, 3> &target
) {
    const double delta =
        std::abs(source[0] - target[0])
        + std::abs(source[1] - target[1])
        + std::abs(source[2] - target[2]);
    return 1.0 - std::min(1.0, delta / 0.85);
}

static bool native_best_star_identity(
    const cv::Point2d &projected,
    double sourceFluxRank,
    const std::array<double, 3> &sourceSignature,
    const std::vector<NativeStar> &candidates,
    const std::vector<double> &candidateFluxRanks,
    const std::vector<std::array<double, 3>> &candidateSignatures,
    double radius,
    int &bestIndex,
    double &bestDistance
) {
    bestIndex = -1;
    bestDistance = std::numeric_limits<double>::infinity();
    double bestScore = std::numeric_limits<double>::infinity();
    for (int index = 0; index < static_cast<int>(candidates.size()); ++index) {
        const NativeStar &candidate = candidates[static_cast<size_t>(index)];
        const double dx = candidate.x - projected.x;
        const double dy = candidate.y - projected.y;
        const double distance = std::sqrt(dx * dx + dy * dy);
        if (!std::isfinite(distance) || distance > radius) {
            continue;
        }
        const double rankDelta = std::abs(
            sourceFluxRank - candidateFluxRanks[static_cast<size_t>(index)]
        );
        const double signature = native_signature_score(
            sourceSignature,
            candidateSignatures[static_cast<size_t>(index)]
        );
        if (rankDelta > 0.45 || signature < 0.20) {
            continue;
        }
        const double score = distance / std::max(radius, 1e-9)
            + 0.45 * rankDelta
            + 0.55 * (1.0 - signature);
        if (score < bestScore) {
            bestScore = score;
            bestDistance = distance;
            bestIndex = index;
        }
    }
    return bestIndex >= 0;
}

static double native_patch_similarity_score(
    const NativeImage &imageA,
    const NativeStar &pointA,
    const NativeImage &imageB,
    const NativeStar &pointB,
    int radius
);

static std::vector<unsigned char> native_smooth_camera_identity_inliers(
    const std::vector<NativeStar> &sources,
    const std::vector<NativeStar> &targets,
    const std::vector<cv::Point2d> &predictedTargets,
    std::vector<double> &finalResiduals,
    double &finalCutoff
) {
    constexpr int fieldBasisCount = 10;
    const size_t count = std::min({sources.size(), targets.size(), predictedTargets.size()});
    std::vector<unsigned char> inliers(count, 0);
    finalResiduals.assign(count, std::numeric_limits<double>::infinity());
    finalCutoff = std::numeric_limits<double>::quiet_NaN();
    if (count < 8) return inliers;
    double minX = sources.front().x;
    double maxX = sources.front().x;
    double minY = sources.front().y;
    double maxY = sources.front().y;
    for (const NativeStar &source : sources) {
        minX = std::min(minX, source.x);
        maxX = std::max(maxX, source.x);
        minY = std::min(minY, source.y);
        maxY = std::max(maxY, source.y);
    }
    const double spanX = std::max(maxX - minX, 1.0);
    const double spanY = std::max(maxY - minY, 1.0);
    std::vector<double> weights(count, 1.0);
    cv::Mat coefficients;
    std::vector<double> residuals(count, std::numeric_limits<double>::infinity());
    auto solve = [&]() {
        cv::Mat design(static_cast<int>(count), fieldBasisCount, CV_64F);
        cv::Mat values(static_cast<int>(count), 2, CV_64F);
        for (size_t index = 0; index < count; ++index) {
            const double x = 2.0 * (sources[index].x - minX) / spanX - 1.0;
            const double y = 2.0 * (sources[index].y - minY) / spanY - 1.0;
            const double scale = std::sqrt(std::max(weights[index], 1e-6));
            design.at<double>(static_cast<int>(index), 0) = scale;
            design.at<double>(static_cast<int>(index), 1) = scale * x;
            design.at<double>(static_cast<int>(index), 2) = scale * y;
            design.at<double>(static_cast<int>(index), 3) = scale * x * x;
            design.at<double>(static_cast<int>(index), 4) = scale * x * y;
            design.at<double>(static_cast<int>(index), 5) = scale * y * y;
            design.at<double>(static_cast<int>(index), 6) = scale * x * x * x;
            design.at<double>(static_cast<int>(index), 7) = scale * x * x * y;
            design.at<double>(static_cast<int>(index), 8) = scale * x * y * y;
            design.at<double>(static_cast<int>(index), 9) = scale * y * y * y;
            values.at<double>(static_cast<int>(index), 0) = scale * (
                targets[index].x - predictedTargets[index].x
            );
            values.at<double>(static_cast<int>(index), 1) = scale * (
                targets[index].y - predictedTargets[index].y
            );
        }
        if (!cv::solve(design, values, coefficients, cv::DECOMP_SVD)) return false;
        for (size_t index = 0; index < count; ++index) {
            const double x = 2.0 * (sources[index].x - minX) / spanX - 1.0;
            const double y = 2.0 * (sources[index].y - minY) / spanY - 1.0;
            const std::array<double, fieldBasisCount> basis = {
                1.0, x, y, x * x, x * y, y * y,
                x * x * x, x * x * y, x * y * y, y * y * y
            };
            double predictedDX = 0.0;
            double predictedDY = 0.0;
            for (int column = 0; column < fieldBasisCount; ++column) {
                predictedDX += basis[static_cast<size_t>(column)] * coefficients.at<double>(column, 0);
                predictedDY += basis[static_cast<size_t>(column)] * coefficients.at<double>(column, 1);
            }
            residuals[index] = std::hypot(
                targets[index].x - predictedTargets[index].x - predictedDX,
                targets[index].y - predictedTargets[index].y - predictedDY
            );
        }
        return true;
    };
    for (int iteration = 0; iteration < 5; ++iteration) {
        if (!solve()) return inliers;
        const double median = median_value(residuals);
        std::vector<double> deviations;
        deviations.reserve(residuals.size());
        for (double residual : residuals) deviations.push_back(std::abs(residual - median));
        const double robustScale = std::max(0.25, 1.4826 * median_value(deviations));
        const double huber = std::min(3.0, std::max(1.0, median + 2.5 * robustScale));
        for (size_t index = 0; index < count; ++index) {
            weights[index] = residuals[index] <= huber
                ? 1.0 : huber / std::max(residuals[index], 1e-9);
        }
    }
    if (!solve()) return inliers;
    const double median = median_value(residuals);
    std::vector<double> deviations;
    deviations.reserve(residuals.size());
    for (double residual : residuals) deviations.push_back(std::abs(residual - median));
    const double robustScale = std::max(0.25, 1.4826 * median_value(deviations));
    // A cubic field absorbs smooth pose/lens initialization error without the
    // degrees of freedom needed to chase isolated neighbouring-star jumps. The
    // hard 1.50 px ceiling prevents neighbouring-star impostors from becoming
    // many output pixels in high-Jacobian projection regions. This is an
    // identity-consensus threshold, fixed before partitioning and independent
    // of validation/final Camera residuals.
    const double cutoff = std::min(1.50, std::max(0.75, median + 3.0 * robustScale));
    finalResiduals = residuals;
    finalCutoff = cutoff;
    for (size_t index = 0; index < count; ++index) {
        inliers[index] = residuals[index] <= cutoff ? 1 : 0;
    }
    return inliers;
}

static NativeStarMatch match_native_stars_by_camera_identity(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    int i,
    int j,
    const std::vector<NativeStar> &inputStarsA,
    const std::vector<NativeStar> &inputStarsB,
    const NativeStarSettings &settings,
    double radius
) {
    NativeStarMatch match;
    // Use the spatially balanced high-confidence population configured by the
    // user instead of flooding correspondence discovery with every faint
    // full-resolution local maximum. raw_2 has thousands of low-SNR peaks;
    // admitting 1,200 of them produced many mutually plausible but incorrect
    // identities and inflated an otherwise independent held-out P95. This cap
    // is chosen before the train/held-out split and never from residuals.
    const int identityLimit = std::max(64, settings.maxStars);
    const std::vector<NativeStar> starsA = select_spatially_balanced_stars(
        inputStarsA, identityLimit, 5
    );
    const std::vector<NativeStar> starsB = select_spatially_balanced_stars(
        inputStarsB, identityLimit, 5
    );
    if (starsA.empty() || starsB.empty()) {
        match.reason = "camera identity matching has no stars";
        return match;
    }
    const std::vector<double> ranksA = native_star_flux_ranks(starsA);
    const std::vector<double> ranksB = native_star_flux_ranks(starsB);
    std::vector<panolume::IdentityStar> identityStarsA;
    std::vector<panolume::IdentityStar> identityStarsB;
    identityStarsA.reserve(starsA.size());
    identityStarsB.reserve(starsB.size());
    for (const NativeStar &star : starsA) {
        identityStarsA.push_back({star.x, star.y, star.flux, star.sigma});
    }
    for (const NativeStar &star : starsB) {
        identityStarsB.push_back({star.x, star.y, star.flux, star.sigma});
    }
    const std::vector<panolume::IdentityDescriptor> descriptorsA =
        panolume::build_identity_descriptors(identityStarsA, 6);
    const std::vector<panolume::IdentityDescriptor> descriptorsB =
        panolume::build_identity_descriptors(identityStarsB, 6);

    struct CandidateEvidence {
        int source = -1;
        int target = -1;
        double descriptorDistance = 1.0;
        int triangleVotes = 0;
        double forwardDistance = 0.0;
        double reverseDistance = 0.0;
        double patchScore = 0.0;
        double rankDelta = 0.0;
        double fwhmRatio = 1.0;
        double cost = 1.0;
    };
    std::vector<cv::Point2d> projectedA(starsA.size());
    std::vector<bool> projectedAValid(starsA.size(), false);
    std::vector<cv::Point2d> projectedB(starsB.size());
    std::vector<bool> projectedBValid(starsB.size(), false);
    for (int source = 0; source < static_cast<int>(starsA.size()); ++source) {
        projectedAValid[static_cast<size_t>(source)] = native_project_point_between_cameras(
            cameras, images, i, j, starsA[static_cast<size_t>(source)], projectedA[static_cast<size_t>(source)]
        );
        if (!projectedAValid[static_cast<size_t>(source)]) {
            match.identityRejectedBoundary += 1;
        }
    }
    for (int target = 0; target < static_cast<int>(starsB.size()); ++target) {
        projectedBValid[static_cast<size_t>(target)] = native_project_point_between_cameras(
            cameras, images, j, i, starsB[static_cast<size_t>(target)], projectedB[static_cast<size_t>(target)]
        );
    }

    std::vector<CandidateEvidence> evidence;
    for (int source = 0; source < static_cast<int>(starsA.size()); ++source) {
        if (!projectedAValid[static_cast<size_t>(source)]) {
            continue;
        }
        bool foundPrediction = false;
        for (int target = 0; target < static_cast<int>(starsB.size()); ++target) {
            const NativeStar &sourceStar = starsA[static_cast<size_t>(source)];
            const NativeStar &targetStar = starsB[static_cast<size_t>(target)];
            const double forwardDistance = std::hypot(
                targetStar.x - projectedA[static_cast<size_t>(source)].x,
                targetStar.y - projectedA[static_cast<size_t>(source)].y
            );
            if (!std::isfinite(forwardDistance) || forwardDistance > radius) {
                continue;
            }
            foundPrediction = true;
            match.identityCandidates += 1;
            if (!projectedBValid[static_cast<size_t>(target)]) {
                match.identityRejectedBoundary += 1;
                continue;
            }
            const double reverseDistance = std::hypot(
                sourceStar.x - projectedB[static_cast<size_t>(target)].x,
                sourceStar.y - projectedB[static_cast<size_t>(target)].y
            );
            if (!std::isfinite(reverseDistance) || reverseDistance > radius * 1.5) {
                match.identityRejectedPrediction += 1;
                continue;
            }
            const panolume::IdentityDescriptorScore descriptorScore =
                panolume::score_identity_descriptors(
                    descriptorsA[static_cast<size_t>(source)],
                    descriptorsB[static_cast<size_t>(target)]
                );
            const double rankDelta = std::abs(
                ranksA[static_cast<size_t>(source)] - ranksB[static_cast<size_t>(target)]
            );
            if (rankDelta > 0.25) {
                match.identityRejectedFlux += 1;
                continue;
            }
            const double sourceFWHM = std::max(sourceStar.sigma * 2.354820045, 1e-6);
            const double targetFWHM = std::max(targetStar.sigma * 2.354820045, 1e-6);
            const double fwhmRatio = targetFWHM / sourceFWHM;
            if (fwhmRatio < 0.5 || fwhmRatio > 2.0) {
                match.identityRejectedFWHM += 1;
                continue;
            }
            const double patchScore = native_patch_similarity_score(
                images[static_cast<size_t>(i)], sourceStar,
                images[static_cast<size_t>(j)], targetStar,
                5
            );
            if (patchScore < 0.80) {
                match.identityRejectedPatch += 1;
                continue;
            }
            CandidateEvidence candidate;
            candidate.source = source;
            candidate.target = target;
            candidate.descriptorDistance = descriptorScore.distance;
            candidate.triangleVotes = descriptorScore.triangleVotes;
            candidate.forwardDistance = forwardDistance;
            candidate.reverseDistance = reverseDistance;
            candidate.patchScore = patchScore;
            candidate.rankDelta = rankDelta;
            candidate.fwhmRatio = fwhmRatio;
            const double predictionCost = std::min(1.0, std::max(forwardDistance, reverseDistance) / radius);
            const double fwhmCost = std::min(1.0, std::abs(std::log(fwhmRatio)) / std::log(2.0));
            // Nearest-neighbour triangle descriptors are only a soft signal:
            // overlap boundaries change which neighbours are present, so a
            // hard vote requirement rejects real identities. Smooth camera
            // residual-field consensus below is the hard anti-impostor gate.
            const double descriptorCost = descriptorScore.triangleVotes >= 3
                ? descriptorScore.distance : 0.55;
            candidate.cost = 0.42 * predictionCost
                + 0.08 * descriptorCost
                + 0.10 * (rankDelta / 0.25)
                + 0.10 * fwhmCost
                + 0.30 * (1.0 - patchScore);
            evidence.push_back(candidate);
        }
        if (!foundPrediction) {
            match.identityRejectedPrediction += 1;
        }
    }

    auto compositeRatioPasses = [](double best, double second) {
        if (!std::isfinite(best)) return false;
        if (!std::isfinite(second)) return true;
        return best / std::max(second, 1e-9) <= 0.88;
    };
    std::vector<double> sourceBest(starsA.size(), std::numeric_limits<double>::infinity());
    std::vector<double> sourceSecond(starsA.size(), std::numeric_limits<double>::infinity());
    std::vector<int> sourceBestTarget(starsA.size(), -1);
    std::vector<double> targetBest(starsB.size(), std::numeric_limits<double>::infinity());
    std::vector<double> targetSecond(starsB.size(), std::numeric_limits<double>::infinity());
    std::vector<int> targetBestSource(starsB.size(), -1);
    auto updateBest = [](double value, int identity, double &best, double &second, int &bestIdentity) {
        if (value < best) {
            second = best;
            best = value;
            bestIdentity = identity;
        } else if (value < second) {
            second = value;
        }
    };
    for (const CandidateEvidence &candidate : evidence) {
        updateBest(candidate.cost, candidate.target,
            sourceBest[static_cast<size_t>(candidate.source)], sourceSecond[static_cast<size_t>(candidate.source)],
            sourceBestTarget[static_cast<size_t>(candidate.source)]);
        updateBest(candidate.cost, candidate.source,
            targetBest[static_cast<size_t>(candidate.target)], targetSecond[static_cast<size_t>(candidate.target)],
            targetBestSource[static_cast<size_t>(candidate.target)]);
    }
    std::vector<panolume::IdentityAssignmentCandidate> assignmentCandidates;
    std::map<std::pair<int, int>, CandidateEvidence> acceptedEvidence;
    for (const CandidateEvidence &candidate : evidence) {
        const bool mutualBest = sourceBestTarget[static_cast<size_t>(candidate.source)] == candidate.target
            && targetBestSource[static_cast<size_t>(candidate.target)] == candidate.source;
        const bool ratioPassed = compositeRatioPasses(
                sourceBest[static_cast<size_t>(candidate.source)], sourceSecond[static_cast<size_t>(candidate.source)]
            ) && compositeRatioPasses(
                targetBest[static_cast<size_t>(candidate.target)], targetSecond[static_cast<size_t>(candidate.target)]
            );
        if (!mutualBest || !ratioPassed) {
            match.identityRejectedRatio += 1;
            continue;
        }
        assignmentCandidates.push_back({candidate.source, candidate.target, candidate.cost});
        acceptedEvidence[{candidate.source, candidate.target}] = candidate;
    }
    const std::vector<panolume::IdentityAssignment> assignments =
        panolume::minimum_cost_identity_assignment(
            static_cast<int>(starsA.size()),
            static_cast<int>(starsB.size()),
            assignmentCandidates,
            0.95
        );
    match.identityRejectedConflict = static_cast<int>(assignmentCandidates.size() - assignments.size());
    std::vector<NativeStar> assignedA;
    std::vector<NativeStar> assignedB;
    std::vector<cv::Point2d> assignedPredictions;
    std::vector<double> assignedErrors;
    for (const panolume::IdentityAssignment &assignment : assignments) {
        const auto found = acceptedEvidence.find({assignment.source, assignment.target});
        if (found == acceptedEvidence.end()) {
            continue;
        }
        const CandidateEvidence &candidate = found->second;
        assignedA.push_back(starsA[static_cast<size_t>(assignment.source)]);
        assignedB.push_back(starsB[static_cast<size_t>(assignment.target)]);
        assignedPredictions.push_back(projectedA[static_cast<size_t>(assignment.source)]);
        assignedErrors.push_back(std::max(candidate.forwardDistance, candidate.reverseDistance));
    }
    std::vector<double> fieldResiduals;
    double fieldCutoff = std::numeric_limits<double>::quiet_NaN();
    const std::vector<unsigned char> fieldInliers = native_smooth_camera_identity_inliers(
        assignedA, assignedB, assignedPredictions, fieldResiduals, fieldCutoff
    );
    match.identityFieldCutoff = fieldCutoff;
    std::vector<double> acceptedFieldResiduals;
    for (size_t index = 0; index < assignedA.size(); ++index) {
        if (index >= fieldInliers.size() || fieldInliers[index] == 0) {
            match.identityRejectedField += 1;
            continue;
        }
        match.pointsA.push_back(assignedA[index]);
        match.pointsB.push_back(assignedB[index]);
        const double fieldResidual = index < fieldResiduals.size()
            ? fieldResiduals[index] : assignedErrors[index];
        match.errors.push_back(fieldResidual);
        acceptedFieldResiduals.push_back(fieldResidual);
    }
    if (!acceptedFieldResiduals.empty()) {
        match.identityFieldMedian = median_value(acceptedFieldResiduals);
        match.identityFieldP95 = percentile_value(acceptedFieldResiduals, 95.0);
    }
    match.identityAccepted = static_cast<int>(match.pointsA.size());
    if (static_cast<int>(match.pointsA.size()) < settings.minInliers
        || !estimate_affine_transform(match.pointsA, match.pointsB, match.affine)) {
        std::ostringstream reason;
        reason << "camera identity matching accepted " << match.pointsA.size()
               << " stars after descriptor/patch/assignment validation";
        match.reason = reason.str();
        return match;
    }
    NativeMatchedStars matched;
    matched.pointsA = match.pointsA;
    matched.pointsB = match.pointsB;
    matched.errors = match.errors;
    const NativeCoverageQualityValues coverage = native_coverage_quality(
        matched, inputStarsA, inputStarsB, std::max(1, settings.spatialGridSize)
    );
    match.coverageBBoxAreaA = coverage.bboxAreaA;
    match.coverageBBoxAreaB = coverage.bboxAreaB;
    match.coverageGridOccupancyA = coverage.gridOccupancyA;
    match.coverageGridOccupancyB = coverage.gridOccupancyB;
    match.adaptiveBBoxAreaA = coverage.bboxAreaA;
    match.adaptiveBBoxAreaB = coverage.bboxAreaB;
    match.adaptiveGridOccupancyA = coverage.gridOccupancyA;
    match.adaptiveGridOccupancyB = coverage.gridOccupancyB;
    match.coverageInliers = static_cast<int>(match.pointsA.size());
    match.adaptiveCoverageAttempted = true;
    match.adaptiveCoverageAccepted = true;
    match.adaptiveCoverageInliers = match.coverageInliers;
    match.success = true;
    match.reason = "camera identity matching passed descriptor, patch, ratio, and assignment gates";
    return match;
}

static double native_patch_similarity_score(
    const NativeImage &imageA,
    const NativeStar &pointA,
    const NativeImage &imageB,
    const NativeStar &pointB,
    int radius = 5
) {
    if (imageA.width <= 0 || imageA.height <= 0 || imageB.width <= 0 || imageB.height <= 0
        || imageA.pixels.empty() || imageB.pixels.empty()) {
        return 0.0;
    }
    const int ax = static_cast<int>(std::llround(pointA.x));
    const int ay = static_cast<int>(std::llround(pointA.y));
    const int bx = static_cast<int>(std::llround(pointB.x));
    const int by = static_cast<int>(std::llround(pointB.y));
    if (ax - radius < 0 || ay - radius < 0 || ax + radius >= imageA.width || ay + radius >= imageA.height
        || bx - radius < 0 || by - radius < 0 || bx + radius >= imageB.width || by + radius >= imageB.height) {
        return 0.0;
    }

    std::vector<double> valuesA;
    std::vector<double> valuesB;
    valuesA.reserve(static_cast<size_t>((radius * 2 + 1) * (radius * 2 + 1)));
    valuesB.reserve(valuesA.capacity());
    auto sampleGray = [](const NativeImage &image, int x, int y) {
        const size_t offset = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * static_cast<size_t>(image.channels);
        if (image.channels >= 3) {
            return (static_cast<double>(image.pixels[offset])
                + static_cast<double>(image.pixels[offset + 1])
                + static_cast<double>(image.pixels[offset + 2])) / 3.0;
        }
        return static_cast<double>(image.pixels[offset]);
    };
    double meanA = 0.0;
    double meanB = 0.0;
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            const double a = sampleGray(imageA, ax + dx, ay + dy);
            const double b = sampleGray(imageB, bx + dx, by + dy);
            valuesA.push_back(a);
            valuesB.push_back(b);
            meanA += a;
            meanB += b;
        }
    }
    const double count = static_cast<double>(valuesA.size());
    meanA /= count;
    meanB /= count;
    double varA = 0.0;
    double varB = 0.0;
    double covariance = 0.0;
    for (size_t idx = 0; idx < valuesA.size(); ++idx) {
        const double da = valuesA[idx] - meanA;
        const double db = valuesB[idx] - meanB;
        varA += da * da;
        varB += db * db;
        covariance += da * db;
    }
    if (varA <= 1e-12 || varB <= 1e-12) {
        return 0.0;
    }
    const double ncc = covariance / std::sqrt(varA * varB);
    return std::max(0.0, std::min(1.0, (ncc + 1.0) * 0.5));
}

static NativeStarMatch match_full_resolution_stars_from_draft_identities(
    int i,
    int j,
    const NativeImage &imageA,
    const NativeImage &imageB,
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const std::vector<NativeControlPoint> &scaledDraftPoints,
    const NativeStarSettings &settings,
    double snapRadius
) {
    NativeStarMatch match;
    if (starsA.empty() || starsB.empty() || scaledDraftPoints.empty()) {
        match.reason = "draft identity anchors or full-resolution stars are unavailable";
        return match;
    }
    NativePointIndex indexA(starsA, snapRadius);
    NativePointIndex indexB(starsB, snapRadius);
    const std::vector<double> ranksA = native_star_flux_ranks(starsA);
    const std::vector<double> ranksB = native_star_flux_ranks(starsB);
    std::vector<panolume::IdentityStar> identityStarsA;
    std::vector<panolume::IdentityStar> identityStarsB;
    identityStarsA.reserve(starsA.size());
    identityStarsB.reserve(starsB.size());
    for (const NativeStar &star : starsA) identityStarsA.push_back({star.x, star.y, star.flux, star.sigma});
    for (const NativeStar &star : starsB) identityStarsB.push_back({star.x, star.y, star.flux, star.sigma});

    struct RawAnchor {
        int source = -1;
        int target = -1;
        double sourceDistance = 0.0;
        double targetDistance = 0.0;
    };
    struct AnchorEvidence {
        int source = -1;
        int target = -1;
        double sourceDistance = 0.0;
        double targetDistance = 0.0;
        double cost = 1.0;
    };
    std::vector<RawAnchor> rawAnchors;
    std::vector<int> anchoredSources;
    std::vector<int> anchoredTargets;
    for (const NativeControlPoint &point : scaledDraftPoints) {
        const bool forward = point.imageAIndex == i && point.imageBIndex == j;
        const bool reverse = point.imageAIndex == j && point.imageBIndex == i;
        if (!forward && !reverse) {
            continue;
        }
        const cv::Point2d expectedA(
            forward ? point.xA : point.xB,
            forward ? point.yA : point.yB
        );
        const cv::Point2d expectedB(
            forward ? point.xB : point.xA,
            forward ? point.yB : point.yA
        );
        int source = -1;
        int target = -1;
        double sourceDistance = 0.0;
        double targetDistance = 0.0;
        if (!indexA.nearest(expectedA, snapRadius, source, sourceDistance)
            || !indexB.nearest(expectedB, snapRadius, target, targetDistance)) {
            match.identityRejectedPrediction += 1;
            continue;
        }
        match.identityCandidates += 1;
        rawAnchors.push_back({source, target, sourceDistance, targetDistance});
        anchoredSources.push_back(source);
        anchoredTargets.push_back(target);
    }
    std::sort(anchoredSources.begin(), anchoredSources.end());
    anchoredSources.erase(std::unique(anchoredSources.begin(), anchoredSources.end()), anchoredSources.end());
    std::sort(anchoredTargets.begin(), anchoredTargets.end());
    anchoredTargets.erase(std::unique(anchoredTargets.begin(), anchoredTargets.end()), anchoredTargets.end());
    const auto descriptorsA = panolume::build_identity_descriptors_for_indices(
        identityStarsA, anchoredSources, 6
    );
    const auto descriptorsB = panolume::build_identity_descriptors_for_indices(
        identityStarsB, anchoredTargets, 6
    );
    std::map<int, size_t> descriptorIndexA;
    std::map<int, size_t> descriptorIndexB;
    for (size_t index = 0; index < anchoredSources.size(); ++index) {
        descriptorIndexA[anchoredSources[index]] = index;
    }
    for (size_t index = 0; index < anchoredTargets.size(); ++index) {
        descriptorIndexB[anchoredTargets[index]] = index;
    }

    std::map<std::pair<int, int>, AnchorEvidence> evidenceByPair;
    for (const RawAnchor &anchor : rawAnchors) {
        const int source = anchor.source;
        const int target = anchor.target;
        const double sourceDistance = anchor.sourceDistance;
        const double targetDistance = anchor.targetDistance;
        const NativeStar &sourceStar = starsA[static_cast<size_t>(source)];
        const NativeStar &targetStar = starsB[static_cast<size_t>(target)];
        const auto descriptor = panolume::score_identity_descriptors(
            descriptorsA[descriptorIndexA[source]],
            descriptorsB[descriptorIndexB[target]]
        );
        // A draft correspondence is only a search seed. Full-resolution PSF
        // centroids establish a new identity and must satisfy the same hard
        // descriptor evidence as an anonymous camera-guided match. Merely
        // recording this failure admitted neighbouring stars into sealed
        // validation/final partitions and let a few impostors dominate P95.
        if (descriptor.triangleVotes < 3 || descriptor.distance > 0.55) {
            match.identityRejectedDescriptor += 1;
            continue;
        }
        const double rankDelta = std::abs(ranksA[static_cast<size_t>(source)] - ranksB[static_cast<size_t>(target)]);
        if (rankDelta > 0.25) {
            match.identityRejectedFlux += 1;
            continue;
        }
        const double fwhmRatio = std::max(targetStar.sigma, 1e-6) / std::max(sourceStar.sigma, 1e-6);
        if (fwhmRatio < 0.5 || fwhmRatio > 2.0) {
            match.identityRejectedFWHM += 1;
            continue;
        }
        const double patchScore = native_patch_similarity_score(imageA, sourceStar, imageB, targetStar, 5);
        if (patchScore < 0.80) {
            match.identityRejectedPatch += 1;
            continue;
        }
        AnchorEvidence candidate;
        candidate.source = source;
        candidate.target = target;
        candidate.sourceDistance = sourceDistance;
        candidate.targetDistance = targetDistance;
        candidate.cost = 0.35 * std::min(1.0, std::max(sourceDistance, targetDistance) / snapRadius)
            + 0.30 * descriptor.distance
            + 0.15 * (rankDelta / 0.25)
            + 0.20 * (1.0 - patchScore);
        const std::pair<int, int> key = {source, target};
        auto existing = evidenceByPair.find(key);
        if (existing == evidenceByPair.end() || candidate.cost < existing->second.cost) {
            evidenceByPair[key] = candidate;
        }
    }
    if (evidenceByPair.empty()) {
        match.reason = "full-resolution draft identity anchors failed descriptor/patch validation";
        return match;
    }
    std::vector<int> sourceIdentities;
    std::vector<int> targetIdentities;
    for (const auto &entry : evidenceByPair) {
        sourceIdentities.push_back(entry.second.source);
        targetIdentities.push_back(entry.second.target);
    }
    std::sort(sourceIdentities.begin(), sourceIdentities.end());
    sourceIdentities.erase(std::unique(sourceIdentities.begin(), sourceIdentities.end()), sourceIdentities.end());
    std::sort(targetIdentities.begin(), targetIdentities.end());
    targetIdentities.erase(std::unique(targetIdentities.begin(), targetIdentities.end()), targetIdentities.end());
    std::vector<panolume::IdentityAssignmentCandidate> candidates;
    std::map<std::pair<int, int>, AnchorEvidence> compactEvidence;
    for (const auto &entry : evidenceByPair) {
        const int compactSource = static_cast<int>(std::lower_bound(
            sourceIdentities.begin(), sourceIdentities.end(), entry.second.source
        ) - sourceIdentities.begin());
        const int compactTarget = static_cast<int>(std::lower_bound(
            targetIdentities.begin(), targetIdentities.end(), entry.second.target
        ) - targetIdentities.begin());
        candidates.push_back({compactSource, compactTarget, entry.second.cost});
        compactEvidence[{compactSource, compactTarget}] = entry.second;
    }
    const auto assignments = panolume::minimum_cost_identity_assignment(
        static_cast<int>(sourceIdentities.size()),
        static_cast<int>(targetIdentities.size()),
        candidates,
        0.95
    );
    match.identityRejectedConflict = static_cast<int>(candidates.size() - assignments.size());
    for (const auto &assignment : assignments) {
        const auto found = compactEvidence.find({assignment.source, assignment.target});
        if (found == compactEvidence.end()) continue;
        const AnchorEvidence &candidate = found->second;
        match.pointsA.push_back(starsA[static_cast<size_t>(candidate.source)]);
        match.pointsB.push_back(starsB[static_cast<size_t>(candidate.target)]);
        match.errors.push_back(std::max(candidate.sourceDistance, candidate.targetDistance));
    }
    match.identityAccepted = static_cast<int>(match.pointsA.size());
    if (match.identityAccepted < std::max(12, settings.minInliers)
        || !estimate_affine_transform(match.pointsA, match.pointsB, match.affine)) {
        std::ostringstream reason;
        reason << "full-resolution draft identity anchors accepted only " << match.identityAccepted << " stars";
        match.reason = reason.str();
        return match;
    }
    NativeMatchedStars matched;
    matched.pointsA = match.pointsA;
    matched.pointsB = match.pointsB;
    matched.errors = match.errors;
    const NativeCoverageQualityValues coverage = native_coverage_quality(
        matched, starsA, starsB, std::max(1, settings.spatialGridSize)
    );
    match.coverageBBoxAreaA = coverage.bboxAreaA;
    match.coverageBBoxAreaB = coverage.bboxAreaB;
    match.coverageGridOccupancyA = coverage.gridOccupancyA;
    match.coverageGridOccupancyB = coverage.gridOccupancyB;
    match.adaptiveBBoxAreaA = coverage.bboxAreaA;
    match.adaptiveBBoxAreaB = coverage.bboxAreaB;
    match.adaptiveGridOccupancyA = coverage.gridOccupancyA;
    match.adaptiveGridOccupancyB = coverage.gridOccupancyB;
    match.adaptiveCoverageAttempted = true;
    match.adaptiveCoverageAccepted = true;
    match.adaptiveCoverageInliers = match.identityAccepted;
    match.coverageInliers = match.identityAccepted;
    match.success = true;
    match.reason = "full-resolution centroids retained draft star identities through independent evidence and one-to-one assignment";
    return match;
}

static NativeStarMatch expand_draft_identity_anchors_from_pair_seed(
    NativeStarMatch anchors,
    const NativeImage &imageA,
    const NativeImage &imageB,
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarSettings &settings
) {
    if (!anchors.success || anchors.affine.empty() || anchors.pointsA.size() >= 64) {
        return anchors;
    }
    NativeStarSettings recoverySettings = settings;
    recoverySettings.maxStars = std::max(700, settings.maxStars * 2);
    recoverySettings.pixelTolerance = std::max(4.0, settings.pixelTolerance);
    const NativeStarMatch recovered = match_native_stars_from_sift_seed(
        starsA,
        starsB,
        affine_to_homography(anchors.affine),
        recoverySettings
    );
    if (!recovered.success) {
        anchors.reason += "; pair-seed identity expansion failed: " + recovered.reason;
        return anchors;
    }
    auto duplicate = [&anchors](const NativeStar &pointA, const NativeStar &pointB) {
        for (size_t index = 0; index < anchors.pointsA.size(); ++index) {
            if (std::hypot(anchors.pointsA[index].x - pointA.x, anchors.pointsA[index].y - pointA.y) <= 1.5
                || std::hypot(anchors.pointsB[index].x - pointB.x, anchors.pointsB[index].y - pointB.y) <= 1.5) {
                return true;
            }
        }
        return false;
    };
    for (size_t index = 0; index < recovered.pointsA.size(); ++index) {
        const NativeStar &pointA = recovered.pointsA[index];
        const NativeStar &pointB = recovered.pointsB[index];
        anchors.identityCandidates += 1;
        if (duplicate(pointA, pointB)) {
            anchors.identityRejectedConflict += 1;
            continue;
        }
        const double fwhmRatio = std::max(pointB.sigma, 1e-6) / std::max(pointA.sigma, 1e-6);
        if (fwhmRatio < 0.5 || fwhmRatio > 2.0) {
            anchors.identityRejectedFWHM += 1;
            continue;
        }
        const double patchScore = native_patch_similarity_score(imageA, pointA, imageB, pointB, 5);
        if (patchScore < 0.80) {
            anchors.identityRejectedPatch += 1;
            continue;
        }
        anchors.pointsA.push_back(pointA);
        anchors.pointsB.push_back(pointB);
        anchors.errors.push_back(recovered.errors[index]);
    }
    anchors.identityAccepted = static_cast<int>(anchors.pointsA.size());
    cv::Mat expandedAffine;
    if (estimate_affine_transform(anchors.pointsA, anchors.pointsB, expandedAffine)) {
        anchors.affine = std::move(expandedAffine);
    }
    NativeMatchedStars matched;
    matched.pointsA = anchors.pointsA;
    matched.pointsB = anchors.pointsB;
    matched.errors = anchors.errors;
    const NativeCoverageQualityValues coverage = native_coverage_quality(
        matched, starsA, starsB, std::max(1, settings.spatialGridSize)
    );
    anchors.coverageBBoxAreaA = coverage.bboxAreaA;
    anchors.coverageBBoxAreaB = coverage.bboxAreaB;
    anchors.coverageGridOccupancyA = coverage.gridOccupancyA;
    anchors.coverageGridOccupancyB = coverage.gridOccupancyB;
    anchors.adaptiveBBoxAreaA = coverage.bboxAreaA;
    anchors.adaptiveBBoxAreaB = coverage.bboxAreaB;
    anchors.adaptiveGridOccupancyA = coverage.gridOccupancyA;
    anchors.adaptiveGridOccupancyB = coverage.gridOccupancyB;
    anchors.coverageInliers = anchors.identityAccepted;
    anchors.adaptiveCoverageInliers = anchors.identityAccepted;
    anchors.reason = "draft anchors expanded by pair-seeded, patch-validated full-resolution identities";
    return anchors;
}

static std::vector<NativeLocalCandidate> select_native_local_offset_cluster(
    const std::vector<NativeLocalCandidate> &candidates,
    NativeLocalPairReport &report,
    double tolerance = 2.5
) {
    report.clusterCandidates = static_cast<int>(candidates.size());
    if (candidates.empty()) {
        report.clusterSelected = 0;
        return {};
    }

    std::vector<int> bestIndices;
    double bestScore = -std::numeric_limits<double>::infinity();
    for (size_t idx = 0; idx < candidates.size(); ++idx) {
        std::vector<int> keep;
        double scoreSum = 0.0;
        for (size_t other = 0; other < candidates.size(); ++other) {
            const double dx = candidates[other].offsetX - candidates[idx].offsetX;
            const double dy = candidates[other].offsetY - candidates[idx].offsetY;
            if (std::sqrt(dx * dx + dy * dy) <= tolerance) {
                keep.push_back(static_cast<int>(other));
                scoreSum += candidates[other].score;
            }
        }
        const double key = static_cast<double>(keep.size()) * 1000.0 + scoreSum;
        if (key > bestScore) {
            bestScore = key;
            bestIndices = std::move(keep);
        }
    }
    if (bestIndices.empty()) {
        report.clusterSelected = 0;
        return {};
    }

    std::vector<double> offsetsX;
    std::vector<double> offsetsY;
    offsetsX.reserve(bestIndices.size());
    offsetsY.reserve(bestIndices.size());
    for (int idx : bestIndices) {
        offsetsX.push_back(candidates[static_cast<size_t>(idx)].offsetX);
        offsetsY.push_back(candidates[static_cast<size_t>(idx)].offsetY);
    }
    const double centerX = median_value(offsetsX);
    const double centerY = median_value(offsetsY);
    std::vector<NativeLocalCandidate> selected;
    for (const NativeLocalCandidate &candidate : candidates) {
        const double dx = candidate.offsetX - centerX;
        const double dy = candidate.offsetY - centerY;
        if (std::sqrt(dx * dx + dy * dy) <= tolerance) {
            selected.push_back(candidate);
        }
    }
    report.clusterSelected = static_cast<int>(selected.size());
    report.offsetX = centerX;
    report.offsetY = centerY;
    return selected;
}

static std::vector<NativeControlPoint> local_star_points_for_pair(
    int i,
    int j,
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<std::vector<NativeStar>> &starSources,
    const std::vector<NativeControlPoint> &existingPoints,
    double searchRadius,
    int maxPoints,
    double evidenceThreshold,
    NativeLocalPairReport &report
) {
    report.i = i;
    report.j = j;
    report.searchRadiusPx = searchRadius;
    report.evidenceThreshold = evidenceThreshold;
    if (i < 0 || j < 0 || i >= static_cast<int>(starSources.size()) || j >= static_cast<int>(starSources.size())) {
        report.reason = "star detections unavailable for pair";
        return {};
    }

    const std::vector<NativeStar> sourceStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(i)], 2200, 5);
    const std::vector<NativeStar> targetStars = select_spatially_balanced_stars(starSources[static_cast<size_t>(j)], 2200, 5);
    report.sourceStars = static_cast<int>(sourceStars.size());
    report.targetStars = static_cast<int>(targetStars.size());
    if (sourceStars.empty() || targetStars.empty()) {
        report.reason = "not enough stars for local refinement";
        return {};
    }

    const std::vector<double> sourceRanks = native_star_flux_ranks(sourceStars);
    const std::vector<double> targetRanks = native_star_flux_ranks(targetStars);
    const std::vector<std::array<double, 3>> sourceSignatures = native_star_neighbor_signatures(sourceStars);
    const std::vector<std::array<double, 3>> targetSignatures = native_star_neighbor_signatures(targetStars);
    NativePointIndex targetIndex(targetStars, searchRadius);
    NativePointIndex sourceIndex(sourceStars, searchRadius * 1.5);

    std::vector<NativeLocalCandidate> candidates;
    for (int sourceIdx = 0; sourceIdx < static_cast<int>(sourceStars.size()); ++sourceIdx) {
        cv::Point2d projected;
        if (!native_project_point_between_cameras(cameras, images, i, j, sourceStars[static_cast<size_t>(sourceIdx)], projected)
            || !point_inside_image(projected, images[static_cast<size_t>(j)])) {
            continue;
        }
        report.eligibleSources += 1;
        int targetIdx = -1;
        double distance = 0.0;
        if (!targetIndex.nearest(projected, searchRadius, targetIdx, distance)) {
            continue;
        }
        cv::Point2d projectedBack;
        if (!native_project_point_between_cameras(cameras, images, j, i, targetStars[static_cast<size_t>(targetIdx)], projectedBack)
            || !point_inside_image(projectedBack, images[static_cast<size_t>(i)])) {
            continue;
        }
        int nearestSourceIdx = -1;
        double backDistance = 0.0;
        if (!sourceIndex.nearest(projectedBack, searchRadius * 1.5, nearestSourceIdx, backDistance) || nearestSourceIdx != sourceIdx) {
            continue;
        }

        const double patchScore = native_patch_similarity_score(
            images[static_cast<size_t>(i)],
            sourceStars[static_cast<size_t>(sourceIdx)],
            images[static_cast<size_t>(j)],
            targetStars[static_cast<size_t>(targetIdx)]
        );
        const double signatureScore = native_signature_score(
            sourceSignatures[static_cast<size_t>(sourceIdx)],
            targetSignatures[static_cast<size_t>(targetIdx)]
        );
        const double rankDelta = std::abs(sourceRanks[static_cast<size_t>(sourceIdx)] - targetRanks[static_cast<size_t>(targetIdx)]);
        const double rankScore = 1.0 - std::min(1.0, rankDelta / 0.65);
        const double distanceScore = 1.0 - std::min(1.0, distance / std::max(searchRadius, 1e-6));
        const double score = 0.34 * patchScore + 0.26 * signatureScore + 0.24 * distanceScore + 0.16 * rankScore;
        if (patchScore < 0.12 || signatureScore < 0.08 || score < evidenceThreshold) {
            report.rejectedLowEvidence += 1;
            continue;
        }

        NativeLocalCandidate candidate;
        candidate.sourceIdx = sourceIdx;
        candidate.targetIdx = targetIdx;
        candidate.distance = distance;
        candidate.offsetX = targetStars[static_cast<size_t>(targetIdx)].x - projected.x;
        candidate.offsetY = targetStars[static_cast<size_t>(targetIdx)].y - projected.y;
        candidate.score = score;
        candidate.patchScore = patchScore;
        candidates.push_back(candidate);
    }
    report.candidateMatches = static_cast<int>(candidates.size());
    if (candidates.empty()) {
        report.reason = "local refinement found no high-evidence candidates";
        return {};
    }

    std::vector<NativeLocalCandidate> clustered = select_native_local_offset_cluster(candidates, report);
    std::sort(clustered.begin(), clustered.end(), [](const NativeLocalCandidate &a, const NativeLocalCandidate &b) {
        if (a.score != b.score) {
            return a.score > b.score;
        }
        return a.distance < b.distance;
    });

    std::set<int> usedSources;
    std::set<int> usedTargets;
    std::vector<NativeControlPoint> points;
    for (const NativeLocalCandidate &candidate : clustered) {
        if (usedSources.count(candidate.sourceIdx) > 0 || usedTargets.count(candidate.targetIdx) > 0) {
            continue;
        }
        NativeControlPoint cp;
        cp.imageAIndex = i;
        cp.imageBIndex = j;
        cp.xA = sourceStars[static_cast<size_t>(candidate.sourceIdx)].x;
        cp.yA = sourceStars[static_cast<size_t>(candidate.sourceIdx)].y;
        cp.xB = targetStars[static_cast<size_t>(candidate.targetIdx)].x;
        cp.yB = targetStars[static_cast<size_t>(candidate.targetIdx)].y;
        cp.error = candidate.distance;
        if (duplicate_control_point(cp, existingPoints, 2.0) || duplicate_control_point(cp, points, 2.0)) {
            report.rejectedDuplicate += 1;
            continue;
        }
        usedSources.insert(candidate.sourceIdx);
        usedTargets.insert(candidate.targetIdx);
        points.push_back(cp);
    }
    points = limit_guided_points_spatially(
        std::move(points),
        images[static_cast<size_t>(i)],
        images[static_cast<size_t>(j)],
        maxPoints,
        4
    );
    report.addedControlPoints = static_cast<int>(points.size());
    if (points.empty()) {
        report.reason = "local refinement candidates were duplicates or failed spatial selection";
    } else {
        report.reason = "local star points selected";
    }
    return points;
}

static std::vector<NativeControlPoint> texture_sift_points_for_pair(
    int i,
    int j,
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeFeatureSet> &features,
    const std::vector<NativeControlPoint> &existingPoints,
    double threshold,
    int maxPoints,
    NativeTexturePairReport &report
) {
    report.i = i;
    report.j = j;
    report.thresholdPx = threshold;
    if (i < 0 || j < 0 || i >= static_cast<int>(features.size()) || j >= static_cast<int>(features.size())) {
        report.reason = "texture features unavailable for pair";
        return {};
    }
    const NativeFeatureSet &featuresA = features[static_cast<size_t>(i)];
    const NativeFeatureSet &featuresB = features[static_cast<size_t>(j)];
    report.sourceFeatures = static_cast<int>(featuresA.keypoints.size());
    report.targetFeatures = static_cast<int>(featuresB.keypoints.size());
    if (featuresA.descriptors.rows < 8 || featuresB.descriptors.rows < 8) {
        report.reason = "not enough SIFT texture features";
        return {};
    }

    cv::FlannBasedMatcher matcher;
    std::vector<std::vector<cv::DMatch>> knn;
    matcher.knnMatch(featuresA.descriptors, featuresB.descriptors, knn, 2);
    struct TextureMatch {
        double forwardError = 0.0;
        cv::Point2d pointA;
        cv::Point2d pointB;
    };
    std::vector<TextureMatch> candidates;
    for (const auto &pair : knn) {
        if (pair.size() < 2) {
            continue;
        }
        const cv::DMatch &match = pair[0];
        const cv::DMatch &next = pair[1];
        if (match.distance >= 0.75f * next.distance) {
            continue;
        }
        report.rawMatches += 1;
        const cv::Point2f &ptA = featuresA.keypoints[static_cast<size_t>(match.queryIdx)].pt;
        const cv::Point2f &ptB = featuresB.keypoints[static_cast<size_t>(match.trainIdx)].pt;
        NativeStar sourcePoint;
        sourcePoint.x = ptA.x;
        sourcePoint.y = ptA.y;
        NativeStar targetPoint;
        targetPoint.x = ptB.x;
        targetPoint.y = ptB.y;
        cv::Point2d projectedForward;
        cv::Point2d projectedBackward;
        if (!native_project_point_between_cameras(cameras, images, i, j, sourcePoint, projectedForward)
            || !native_project_point_between_cameras(cameras, images, j, i, targetPoint, projectedBackward)
            || !point_inside_image(projectedForward, images[static_cast<size_t>(j)])
            || !point_inside_image(projectedBackward, images[static_cast<size_t>(i)])) {
            continue;
        }
        const double forwardDx = projectedForward.x - static_cast<double>(ptB.x);
        const double forwardDy = projectedForward.y - static_cast<double>(ptB.y);
        const double backwardDx = projectedBackward.x - static_cast<double>(ptA.x);
        const double backwardDy = projectedBackward.y - static_cast<double>(ptA.y);
        const double forwardError = std::sqrt(forwardDx * forwardDx + forwardDy * forwardDy);
        const double backwardError = std::sqrt(backwardDx * backwardDx + backwardDy * backwardDy);
        if (!std::isfinite(forwardError) || !std::isfinite(backwardError)) {
            continue;
        }
        if (forwardError > threshold || backwardError > threshold * 1.5) {
            continue;
        }
        TextureMatch textureMatch;
        textureMatch.forwardError = forwardError;
        textureMatch.pointA = cv::Point2d(ptA.x, ptA.y);
        textureMatch.pointB = cv::Point2d(ptB.x, ptB.y);
        candidates.push_back(textureMatch);
    }
    report.geometryConsistentMatches = static_cast<int>(candidates.size());
    if (candidates.empty()) {
        report.reason = "all SIFT texture matches failed geometry checks";
        return {};
    }
    std::sort(candidates.begin(), candidates.end(), [](const TextureMatch &a, const TextureMatch &b) {
        return a.forwardError < b.forwardError;
    });

    std::vector<NativeControlPoint> points;
    points.reserve(candidates.size());
    for (const TextureMatch &match : candidates) {
        NativeControlPoint cp;
        cp.imageAIndex = i;
        cp.imageBIndex = j;
        cp.xA = match.pointA.x;
        cp.yA = match.pointA.y;
        cp.xB = match.pointB.x;
        cp.yB = match.pointB.y;
        cp.error = match.forwardError;
        if (duplicate_control_point(cp, existingPoints, 2.0) || duplicate_control_point(cp, points, 2.0)) {
            continue;
        }
        points.push_back(cp);
    }
    report.candidateControlPoints = static_cast<int>(points.size());
    points = limit_guided_points_spatially(
        std::move(points),
        images[static_cast<size_t>(i)],
        images[static_cast<size_t>(j)],
        maxPoints,
        4
    );
    report.addedControlPoints = static_cast<int>(points.size());
    if (points.empty()) {
        report.reason = "all SIFT texture matches were duplicates or failed spatial selection";
    } else {
        report.reason = "texture SIFT points selected";
    }
    return points;
}

static void split_alternating_control_points(
    std::vector<NativeControlPoint> points,
    std::vector<NativeControlPoint> &train,
    std::vector<NativeControlPoint> &validation
) {
    std::sort(points.begin(), points.end(), [](const NativeControlPoint &a, const NativeControlPoint &b) {
        if (a.imageAIndex != b.imageAIndex) {
            return a.imageAIndex < b.imageAIndex;
        }
        if (a.imageBIndex != b.imageBIndex) {
            return a.imageBIndex < b.imageBIndex;
        }
        if (a.xB != b.xB) {
            return a.xB < b.xB;
        }
        if (a.yB != b.yB) {
            return a.yB < b.yB;
        }
        return a.error < b.error;
    });
    for (size_t idx = 0; idx < points.size(); ++idx) {
        if (idx % 2 == 0) {
            train.push_back(points[idx]);
        } else {
            validation.push_back(points[idx]);
        }
    }
}

static std::vector<NativeControlPoint> native_control_points_with_reserved_holdout(
    const NativeResult &result
) {
    std::vector<NativeControlPoint> reserved = result.controlPoints;
    for (const NativeSelectedEdge &edge : result.selectedEdges) {
        reserved.insert(
            reserved.end(),
            edge.validationControlPoints.begin(),
            edge.validationControlPoints.end()
        );
        reserved.insert(
            reserved.end(),
            edge.heldOutControlPoints.begin(),
            edge.heldOutControlPoints.end()
        );
    }
    return reserved;
}

static void try_native_local_star_refinement(
    NativeResult &result,
    const std::vector<NativeImage> &images,
    const std::vector<std::vector<NativeStar>> &starSources,
    bool optimizeFocal,
    bool optimizeDistortion,
    int maxIterations,
    double fixedInitialFocal,
    std::vector<NativeCameraParams> &cameras,
    std::string &summary,
    const panolume::EngineRequest &request
) {
    NativeLocalRefinementReport report;
    const bool enableLocalRefinement = request.boolean("cameraModelLocalRefinement", true);
    report.enabled = enableLocalRefinement
        && starSources.size() == images.size()
        && !result.selectedEdges.empty();
    report.inputControlPoints = static_cast<int>(result.controlPoints.size());
    report.outputControlPoints = static_cast<int>(result.controlPoints.size());
    if (!enableLocalRefinement) {
        report.reason = "local star refinement disabled";
        result.localRefinementReport = report;
        return;
    }
    if (starSources.size() != images.size()) {
        report.reason = "star detections unavailable";
        result.localRefinementReport = report;
        return;
    }
    if (result.selectedEdges.empty()) {
        report.reason = "selected edges unavailable";
        result.localRefinementReport = report;
        return;
    }

    const double searchRadius = std::max(1.0, request.number("cameraModelLocalSearchPx", 12.0));
    const int maxLocalPointsPerPair = std::max(1, request.integer("cameraModelLocalMaxPointsPerPair", 36));
    const double evidenceThreshold = std::max(0.0, std::min(1.0, request.number("cameraModelLocalEvidenceThreshold", 0.48)));
    std::vector<NativeControlPoint> localPoints;
    const std::vector<NativeControlPoint> reservedPoints = native_control_points_with_reserved_holdout(result);
    for (const NativeSelectedEdge &edge : result.selectedEdges) {
        NativeLocalPairReport pairReport;
        std::vector<NativeControlPoint> pairPoints = local_star_points_for_pair(
            edge.i,
            edge.j,
            cameras,
            images,
            starSources,
            reservedPoints,
            searchRadius,
            maxLocalPointsPerPair,
            evidenceThreshold,
            pairReport
        );
        localPoints.insert(localPoints.end(), pairPoints.begin(), pairPoints.end());
        report.pairs.push_back(pairReport);
    }
    localPoints = dedupe_control_points(std::move(localPoints), 1.5);
    report.addedControlPoints = static_cast<int>(localPoints.size());
    if (localPoints.size() < 6) {
        report.reason = "local star refinement found too few validated points";
        result.localRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> trainPoints;
    std::vector<NativeControlPoint> validationPoints;
    split_alternating_control_points(localPoints, trainPoints, validationPoints);
    report.trainControlPoints = static_cast<int>(trainPoints.size());
    report.validationControlPoints = static_cast<int>(validationPoints.size());
    if (validationPoints.size() < 3) {
        report.reason = "local star refinement has too few validation points";
        result.localRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> trainSet = result.controlPoints;
    trainSet.insert(trainSet.end(), trainPoints.begin(), trainPoints.end());
    trainSet = dedupe_control_points(std::move(trainSet), 1.5);
    std::vector<NativeCameraParams> candidateCameras = cameras;
    std::string candidateSummary;
    if (!run_ceres_camera_adjustment(images, trainSet, optimizeFocal, optimizeDistortion, maxIterations, candidateCameras, candidateSummary, fixedInitialFocal)) {
        report.reason = "Ceres solver failed on local train points";
        result.localRefinementReport = report;
        return;
    }

    report.currentValidationRms = camera_projection_rms_error(
        cameras,
        images,
        validationPoints,
        result.projection
    );
    report.candidateValidationRms = camera_projection_rms_error(
        candidateCameras,
        images,
        validationPoints,
        result.projection
    );
    report.currentBaseRms = camera_rms_error(cameras, images, result.controlPoints);
    report.candidateBaseRms = camera_rms_error(candidateCameras, images, result.controlPoints);
    if (!std::isfinite(report.currentValidationRms) || !std::isfinite(report.candidateValidationRms)) {
        report.reason = "local validation RMS is not finite";
        result.localRefinementReport = report;
        return;
    }
    if (report.candidateValidationRms > report.currentValidationRms * 0.90) {
        report.reason = "local refinement did not improve held-out visible star residual enough";
        result.localRefinementReport = report;
        return;
    }
    if (std::isfinite(report.currentBaseRms)
        && std::isfinite(report.candidateBaseRms)
        && report.candidateBaseRms > report.currentBaseRms * 1.06 + 1e-6) {
        report.reason = "local refinement worsened base control-point RMS";
        result.localRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> finalPoints = result.controlPoints;
    finalPoints.insert(finalPoints.end(), localPoints.begin(), localPoints.end());
    finalPoints = dedupe_control_points(std::move(finalPoints), 1.5);
    std::vector<NativeCameraParams> finalCameras = candidateCameras;
    std::string finalSummary;
    if (!run_ceres_camera_adjustment(images, finalPoints, optimizeFocal, optimizeDistortion, maxIterations, finalCameras, finalSummary, fixedInitialFocal)) {
        report.reason = "Ceres solver failed on final local points";
        result.localRefinementReport = report;
        return;
    }
    report.finalBaseRms = camera_rms_error(finalCameras, images, result.controlPoints);
    if (std::isfinite(report.currentBaseRms)
        && std::isfinite(report.finalBaseRms)
        && report.finalBaseRms > report.currentBaseRms * 1.07 + 1e-6) {
        report.reason = "final local refinement worsened base control-point RMS";
        result.localRefinementReport = report;
        return;
    }

    apply_camera_errors_to_control_points(finalCameras, images, finalPoints);
    report.accepted = true;
    report.reason = "local star refinement accepted";
    report.outputControlPoints = static_cast<int>(finalPoints.size());
    cameras = std::move(finalCameras);
    result.controlPoints = std::move(finalPoints);
    summary = finalSummary.empty() ? candidateSummary : finalSummary;
    result.localRefinementReport = report;
}

static void try_native_texture_sift_refinement(
    NativeResult &result,
    const std::vector<NativeImage> &images,
    bool optimizeFocal,
    bool optimizeDistortion,
    int maxIterations,
    double fixedInitialFocal,
    std::vector<NativeCameraParams> &cameras,
    std::string &summary,
    const panolume::EngineRequest &request
) {
    NativeTextureRefinementReport report;
    const bool enableTextureRefinement = request.boolean("cameraModelTextureRefinement", true);
    report.enabled = enableTextureRefinement && !result.selectedEdges.empty();
    report.inputControlPoints = static_cast<int>(result.controlPoints.size());
    report.outputControlPoints = static_cast<int>(result.controlPoints.size());
    if (!enableTextureRefinement) {
        report.reason = "texture SIFT refinement disabled";
        result.textureRefinementReport = report;
        return;
    }
    if (result.selectedEdges.empty()) {
        report.reason = "no selected pairs for texture refinement";
        result.textureRefinementReport = report;
        return;
    }

    std::vector<NativeFeatureSet> features;
    features.reserve(images.size());
    for (const NativeImage &image : images) {
        features.push_back(detect_native_texture_sift_features(image));
        report.featureCounts.push_back(static_cast<int>(features.back().keypoints.size()));
    }

    const double threshold = std::max(1.0, request.number("cameraModelTextureReprojectionPx", 8.0));
    const int maxTexturePointsPerPair = std::max(1, request.integer("cameraModelTextureMaxPointsPerPair", 48));
    std::vector<NativeControlPoint> texturePoints;
    const std::vector<NativeControlPoint> reservedPoints = native_control_points_with_reserved_holdout(result);
    for (const NativeSelectedEdge &edge : result.selectedEdges) {
        NativeTexturePairReport pairReport;
        std::vector<NativeControlPoint> pairPoints = texture_sift_points_for_pair(
            edge.i,
            edge.j,
            cameras,
            images,
            features,
            reservedPoints,
            threshold,
            maxTexturePointsPerPair,
            pairReport
        );
        texturePoints.insert(texturePoints.end(), pairPoints.begin(), pairPoints.end());
        report.pairs.push_back(pairReport);
    }
    texturePoints = dedupe_control_points(std::move(texturePoints), 1.5);
    report.addedControlPoints = static_cast<int>(texturePoints.size());
    if (static_cast<int>(texturePoints.size()) < std::max(8, static_cast<int>(images.size()) * 2)) {
        report.reason = "texture refinement found too few geometry-consistent points";
        result.textureRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> trainPoints;
    std::vector<NativeControlPoint> validationPoints;
    split_alternating_control_points(texturePoints, trainPoints, validationPoints);
    report.trainControlPoints = static_cast<int>(trainPoints.size());
    report.validationControlPoints = static_cast<int>(validationPoints.size());
    if (validationPoints.size() < 4) {
        report.reason = "texture refinement has too few validation points";
        result.textureRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> trainSet = result.controlPoints;
    trainSet.insert(trainSet.end(), trainPoints.begin(), trainPoints.end());
    trainSet = dedupe_control_points(std::move(trainSet), 1.5);
    std::vector<NativeCameraParams> candidateCameras = cameras;
    std::string candidateSummary;
    if (!run_ceres_camera_adjustment(images, trainSet, optimizeFocal, optimizeDistortion, maxIterations, candidateCameras, candidateSummary, fixedInitialFocal)) {
        report.reason = "Ceres solver failed on texture train points";
        result.textureRefinementReport = report;
        return;
    }

    report.currentValidationRms = camera_rms_error(cameras, images, validationPoints);
    report.candidateValidationRms = camera_rms_error(candidateCameras, images, validationPoints);
    report.currentBaseRms = camera_rms_error(cameras, images, result.controlPoints);
    report.candidateBaseRms = camera_rms_error(candidateCameras, images, result.controlPoints);
    if (!std::isfinite(report.currentValidationRms) || !std::isfinite(report.candidateValidationRms)) {
        report.reason = "texture validation RMS is not finite";
        result.textureRefinementReport = report;
        return;
    }
    if (report.candidateValidationRms > report.currentValidationRms * 0.92) {
        report.reason = "texture refinement did not improve held-out texture residual";
        result.textureRefinementReport = report;
        return;
    }
    if (std::isfinite(report.currentBaseRms)
        && std::isfinite(report.candidateBaseRms)
        && report.candidateBaseRms > report.currentBaseRms * 1.03 + 1e-6) {
        report.reason = "texture refinement worsened base control-point RMS";
        result.textureRefinementReport = report;
        return;
    }

    std::vector<NativeControlPoint> finalPoints = result.controlPoints;
    finalPoints.insert(finalPoints.end(), texturePoints.begin(), texturePoints.end());
    finalPoints = dedupe_control_points(std::move(finalPoints), 1.5);
    std::vector<NativeCameraParams> finalCameras = candidateCameras;
    std::string finalSummary;
    if (!run_ceres_camera_adjustment(images, finalPoints, optimizeFocal, optimizeDistortion, maxIterations, finalCameras, finalSummary, fixedInitialFocal)) {
        report.reason = "Ceres solver failed on final texture points";
        result.textureRefinementReport = report;
        return;
    }
    const double finalBaseRms = camera_rms_error(finalCameras, images, result.controlPoints);
    if (std::isfinite(report.currentBaseRms) && std::isfinite(finalBaseRms) && finalBaseRms > report.currentBaseRms * 1.03 + 1e-6) {
        report.reason = "final texture refinement worsened base control-point RMS";
        result.textureRefinementReport = report;
        return;
    }

    apply_camera_errors_to_control_points(finalCameras, images, finalPoints);
    report.accepted = true;
    report.reason = "texture SIFT refinement accepted";
    report.outputControlPoints = static_cast<int>(finalPoints.size());
    cameras = std::move(finalCameras);
    result.controlPoints = std::move(finalPoints);
    summary = finalSummary.empty() ? candidateSummary : finalSummary;
    result.textureRefinementReport = report;
}

static bool native_camera_params_are_finite(const std::vector<NativeCameraParams> &cameras) {
    for (const NativeCameraParams &camera : cameras) {
        if (!std::isfinite(camera.focalLength) || camera.focalLength <= 0.0
            || !std::isfinite(camera.k1)
            || !std::isfinite(camera.k2)
            || !std::isfinite(camera.k3)
            || !std::isfinite(camera.p1)
            || !std::isfinite(camera.p2)
            || !std::isfinite(camera.principalOffsetX)
            || !std::isfinite(camera.principalOffsetY)
            || std::abs(camera.principalOffsetX) > 0.050001
            || std::abs(camera.principalOffsetY) > 0.050001) {
            return false;
        }
        for (double value : camera.rotation) {
            if (!std::isfinite(value)) {
                return false;
            }
        }
        for (double value : camera.translation) {
            if (!std::isfinite(value)) {
                return false;
            }
        }
    }
    return true;
}

static int finite_control_point_error_count(const std::vector<NativeControlPoint> &points) {
    int count = 0;
    for (const NativeControlPoint &point : points) {
        if (std::isfinite(point.error)) {
            count += 1;
        }
    }
    return count;
}

static bool native_control_point_matches_edge(
    const NativeControlPoint &point,
    const NativeSelectedEdge &edge
) {
    return (point.imageAIndex == edge.i && point.imageBIndex == edge.j)
        || (point.imageAIndex == edge.j && point.imageBIndex == edge.i);
}

static bool native_control_point_is_selected_edge(
    const NativeControlPoint &point,
    const std::vector<NativeSelectedEdge> &selectedEdges
) {
    if (selectedEdges.empty()) {
        return true;
    }
    for (const NativeSelectedEdge &edge : selectedEdges) {
        if (native_control_point_matches_edge(point, edge)) {
            return true;
        }
    }
    return false;
}

static std::vector<NativeControlPoint> native_selected_edge_control_points(
    const std::vector<NativeControlPoint> &points,
    const std::vector<NativeSelectedEdge> &selectedEdges
) {
    if (selectedEdges.empty()) {
        return points;
    }
    std::vector<NativeControlPoint> selected;
    selected.reserve(points.size());
    for (const NativeControlPoint &point : points) {
        if (native_control_point_is_selected_edge(point, selectedEdges)) {
            selected.push_back(point);
        }
    }
    return selected;
}

static std::vector<NativeControlPoint> native_camera_reprojection_inliers(
    const std::vector<NativeControlPoint> &points,
    const std::vector<NativeSelectedEdge> &selectedEdges,
    double threshold,
    int minPairInliers
) {
    if (points.empty()) {
        return {};
    }

    std::vector<bool> keep(points.size(), false);
    for (size_t idx = 0; idx < points.size(); ++idx) {
        const NativeControlPoint &point = points[idx];
        keep[idx] = native_control_point_is_selected_edge(point, selectedEdges)
            && std::isfinite(point.error)
            && point.error <= threshold;
    }

    const int requiredPerPair = std::max(0, minPairInliers);
    if (requiredPerPair > 0) {
        for (const NativeSelectedEdge &edge : selectedEdges) {
            std::vector<size_t> indices;
            for (size_t idx = 0; idx < points.size(); ++idx) {
                if (native_control_point_matches_edge(points[idx], edge)) {
                    indices.push_back(idx);
                }
            }
            if (indices.empty()) {
                continue;
            }

            const int required = std::min(requiredPerPair, static_cast<int>(indices.size()));
            int kept = 0;
            for (size_t idx : indices) {
                if (keep[idx]) {
                    kept += 1;
                }
            }
            if (kept >= required) {
                continue;
            }

            std::sort(indices.begin(), indices.end(), [&](size_t lhs, size_t rhs) {
                const double lhsError = std::isfinite(points[lhs].error)
                    ? points[lhs].error
                    : std::numeric_limits<double>::infinity();
                const double rhsError = std::isfinite(points[rhs].error)
                    ? points[rhs].error
                    : std::numeric_limits<double>::infinity();
                return lhsError < rhsError;
            });
            for (int idx = 0; idx < required; ++idx) {
                keep[indices[static_cast<size_t>(idx)]] = true;
            }
        }
    }

    std::vector<NativeControlPoint> inliers;
    inliers.reserve(points.size());
    for (size_t idx = 0; idx < points.size(); ++idx) {
        if (keep[idx]) {
            inliers.push_back(points[idx]);
        }
    }
    return inliers;
}

static double selected_pair_p95_error(
    const std::vector<NativeControlPoint> &points,
    const std::vector<NativeSelectedEdge> &selectedEdges,
    int &worstEdgeI,
    int &worstEdgeJ
) {
    worstEdgeI = -1;
    worstEdgeJ = -1;
    if (selectedEdges.empty()) {
        std::vector<double> errors;
        for (const NativeControlPoint &point : points) {
            if (std::isfinite(point.error)) {
                errors.push_back(point.error);
            }
        }
        return errors.empty() ? std::numeric_limits<double>::infinity() : percentile_value(errors, 95.0);
    }

    double worstP95 = -std::numeric_limits<double>::infinity();
    for (const NativeSelectedEdge &edge : selectedEdges) {
        std::vector<double> errors;
        for (const NativeControlPoint &point : points) {
            if (native_control_point_matches_edge(point, edge) && std::isfinite(point.error)) {
                errors.push_back(point.error);
            }
        }
        const double pairP95 = errors.empty()
            ? std::numeric_limits<double>::infinity()
            : percentile_value(errors, 95.0);
        if (pairP95 > worstP95) {
            worstP95 = pairP95;
            worstEdgeI = edge.i;
            worstEdgeJ = edge.j;
        }
    }
    return worstP95;
}

static cv::Point2d native_local_warp_inverse_pixel(
    const panolume::LocalWarpImageModel &warp,
    const NativeImage &image,
    double actualX,
    double actualY
) {
    const double width = std::max(1, image.width - 1);
    const double height = std::max(1, image.height - 1);
    const double actualU = actualX / width;
    const double actualV = actualY / height;
    double idealU = actualU;
    double idealV = actualV;
    for (int iteration = 0; iteration < 8; ++iteration) {
        const auto displacement = panolume::sample_local_warp(warp, idealU, idealV);
        idealU = actualU - displacement[0];
        idealV = actualV - displacement[1];
    }
    return {idealU * width, idealV * height};
}

static cv::Point2d native_local_warp_forward_pixel(
    const panolume::LocalWarpImageModel &warp,
    const NativeImage &image,
    double idealX,
    double idealY
) {
    const double width = std::max(1, image.width - 1);
    const double height = std::max(1, image.height - 1);
    const double u = idealX / width;
    const double v = idealY / height;
    const auto displacement = panolume::sample_local_warp(warp, u, v);
    return {(u + displacement[0]) * width, (v + displacement[1]) * height};
}

static double native_local_warp_reprojection_error(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const panolume::LocalWarpModel &warp,
    const NativeControlPoint &point
) {
    if (warp.images.size() != images.size()
        || point.imageAIndex < 0 || point.imageBIndex < 0
        || point.imageAIndex >= static_cast<int>(images.size())
        || point.imageBIndex >= static_cast<int>(images.size())) {
        return std::numeric_limits<double>::infinity();
    }
    const int a = point.imageAIndex;
    const int b = point.imageBIndex;
    const cv::Point2d sourceIdeal = native_local_warp_inverse_pixel(
        warp.images[static_cast<size_t>(a)], images[static_cast<size_t>(a)], point.xA, point.yA
    );
    NativeStar source;
    source.x = sourceIdeal.x;
    source.y = sourceIdeal.y;
    cv::Point2d targetIdeal;
    if (!native_project_point_between_cameras(cameras, images, a, b, source, targetIdeal)) {
        return std::numeric_limits<double>::infinity();
    }
    const cv::Point2d targetActual = native_local_warp_forward_pixel(
        warp.images[static_cast<size_t>(b)], images[static_cast<size_t>(b)], targetIdeal.x, targetIdeal.y
    );
    return std::hypot(targetActual.x - point.xB, targetActual.y - point.yB);
}

static bool native_local_warp_residual_vector(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const panolume::LocalWarpModel &warp,
    const NativeControlPoint &point,
    cv::Point2d &residual
) {
    if (warp.images.size() != images.size()
        || point.imageAIndex < 0 || point.imageBIndex < 0
        || point.imageAIndex >= static_cast<int>(images.size())
        || point.imageBIndex >= static_cast<int>(images.size())) {
        return false;
    }
    const int a = point.imageAIndex;
    const int b = point.imageBIndex;
    const cv::Point2d sourceIdeal = native_local_warp_inverse_pixel(
        warp.images[static_cast<size_t>(a)], images[static_cast<size_t>(a)], point.xA, point.yA
    );
    NativeStar source;
    source.x = sourceIdeal.x;
    source.y = sourceIdeal.y;
    cv::Point2d targetIdeal;
    if (!native_project_point_between_cameras(cameras, images, a, b, source, targetIdeal)) {
        return false;
    }
    const cv::Point2d targetActual = native_local_warp_forward_pixel(
        warp.images[static_cast<size_t>(b)], images[static_cast<size_t>(b)], targetIdeal.x, targetIdeal.y
    );
    residual = {targetActual.x - point.xB, targetActual.y - point.yB};
    return std::isfinite(residual.x) && std::isfinite(residual.y);
}

static bool native_validation_has_stable_per_image_residual(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeSelectedEdge> &edges,
    const panolume::LocalWarpModel &sharedGrid,
    std::string &reason
) {
    struct ResidualBucket {
        int count = 0;
        double sumX = 0.0;
        double sumY = 0.0;
        double sumMagnitude = 0.0;
    };
    std::vector<ResidualBucket> buckets(images.size());
    auto add = [&](int imageIndex, const cv::Point2d &residual) {
        if (imageIndex < 0 || imageIndex >= static_cast<int>(buckets.size())) return;
        ResidualBucket &bucket = buckets[static_cast<size_t>(imageIndex)];
        bucket.count += 1;
        bucket.sumX += residual.x;
        bucket.sumY += residual.y;
        bucket.sumMagnitude += std::hypot(residual.x, residual.y);
    };
    for (const NativeSelectedEdge &edge : edges) {
        for (const NativeControlPoint &point : edge.validationControlPoints) {
            cv::Point2d forward;
            if (native_local_warp_residual_vector(cameras, images, sharedGrid, point, forward)) {
                add(point.imageBIndex, forward);
            }
            NativeControlPoint reverse = point;
            std::swap(reverse.imageAIndex, reverse.imageBIndex);
            std::swap(reverse.xA, reverse.xB);
            std::swap(reverse.yA, reverse.yB);
            cv::Point2d backward;
            if (native_local_warp_residual_vector(cameras, images, sharedGrid, reverse, backward)) {
                add(reverse.imageBIndex, backward);
            }
        }
    }
    int stableImages = 0;
    std::ostringstream details;
    for (size_t image = 0; image < buckets.size(); ++image) {
        const ResidualBucket &bucket = buckets[image];
        if (bucket.count < 6 || bucket.sumMagnitude <= 1e-9) continue;
        const double meanX = bucket.sumX / bucket.count;
        const double meanY = bucket.sumY / bucket.count;
        const double meanMagnitude = bucket.sumMagnitude / bucket.count;
        const double coherence = std::hypot(meanX, meanY) / meanMagnitude;
        const bool stable = meanMagnitude >= 0.15 && coherence >= 0.55;
        if (stable) stableImages += 1;
        if (details.tellp() > 0) details << "; ";
        details << "image " << image << " n=" << bucket.count
                << " mean=" << meanMagnitude << " coherence=" << coherence;
    }
    const bool eligible = stableImages >= 2;
    reason = eligible
        ? "validation shows coherent per-image systematic residuals in "
            + std::to_string(stableImages) + " images (" + details.str() + ")"
        : "validation does not show coherent per-image systematic residuals in at least two images ("
            + details.str() + ")";
    return eligible;
}

static bool native_fit_shared_lens_warp_model(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &trainingPoints,
    panolume::LocalWarpModel &model,
    panolume::LocalWarpFitReport &report,
    bool perImageAffine = false,
    const panolume::LocalWarpModel *baseModel = nullptr
) {
    std::vector<std::array<int, 2>> dimensions;
    dimensions.reserve(images.size());
    for (const NativeImage &image : images) dimensions.push_back({image.width, image.height});
    std::vector<panolume::LocalWarpLinearObservation> observations;
    observations.reserve(trainingPoints.size());
    for (const NativeControlPoint &point : trainingPoints) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(images.size())
            || point.imageBIndex >= static_cast<int>(images.size())) continue;
        const bool hasBase = baseModel != nullptr
            && baseModel->images.size() == images.size();
        const NativeImage &sourceImage = images[static_cast<size_t>(point.imageAIndex)];
        const NativeImage &targetImage = images[static_cast<size_t>(point.imageBIndex)];
        const cv::Point2d sourceIdeal = hasBase
            ? native_local_warp_inverse_pixel(
                baseModel->images[static_cast<size_t>(point.imageAIndex)],
                sourceImage,
                point.xA,
                point.yA
            )
            : cv::Point2d(point.xA, point.yA);
        NativeStar source;
        source.x = sourceIdeal.x;
        source.y = sourceIdeal.y;
        cv::Point2d predicted;
        cv::Point2d predictedX;
        cv::Point2d predictedY;
        NativeStar sourceX = source;
        NativeStar sourceY = source;
        sourceX.x += 1.0;
        sourceY.y += 1.0;
        if (!native_project_point_between_cameras(cameras, images, point.imageAIndex, point.imageBIndex, source, predicted)
            || !native_project_point_between_cameras(cameras, images, point.imageAIndex, point.imageBIndex, sourceX, predictedX)
            || !native_project_point_between_cameras(cameras, images, point.imageAIndex, point.imageBIndex, sourceY, predictedY)) {
            continue;
        }
        const cv::Point2d predictedActual = hasBase
            ? native_local_warp_forward_pixel(
                baseModel->images[static_cast<size_t>(point.imageBIndex)],
                targetImage,
                predicted.x,
                predicted.y
            )
            : predicted;
        const cv::Point2d predictedXActual = hasBase
            ? native_local_warp_forward_pixel(
                baseModel->images[static_cast<size_t>(point.imageBIndex)],
                targetImage,
                predictedX.x,
                predictedX.y
            )
            : predictedX;
        const cv::Point2d predictedYActual = hasBase
            ? native_local_warp_forward_pixel(
                baseModel->images[static_cast<size_t>(point.imageBIndex)],
                targetImage,
                predictedY.x,
                predictedY.y
            )
            : predictedY;
        panolume::LocalWarpLinearObservation observation;
        observation.sourceImage = point.imageAIndex;
        observation.targetImage = point.imageBIndex;
        observation.sourceU = sourceIdeal.x / std::max(1, sourceImage.width - 1);
        observation.sourceV = sourceIdeal.y / std::max(1, sourceImage.height - 1);
        observation.targetU = predicted.x / std::max(1, targetImage.width - 1);
        observation.targetV = predicted.y / std::max(1, targetImage.height - 1);
        observation.baseResidualX = predictedActual.x - point.xB;
        observation.baseResidualY = predictedActual.y - point.yB;
        observation.sourceJacobian = {
            predictedXActual.x - predictedActual.x,
            predictedYActual.x - predictedActual.x,
            predictedXActual.y - predictedActual.y,
            predictedYActual.y - predictedActual.y
        };
        if (std::isfinite(observation.baseResidualX) && std::isfinite(observation.baseResidualY)) {
            observations.push_back(observation);
        }
    }
    return perImageAffine
        ? panolume::fit_zero_mean_per_image_affine_warp_linearized(
            dimensions, observations, model, report
        )
        : panolume::fit_shared_lens_warp_linearized(
            dimensions, observations, model, report
        );
}

static bool native_compose_local_warp_models(
    const panolume::LocalWarpModel &sharedGrid,
    const panolume::LocalWarpModel &perImageAffine,
    panolume::LocalWarpModel &combined,
    panolume::LocalWarpFitReport &report
) {
    if (sharedGrid.images.empty()
        || sharedGrid.images.size() != perImageAffine.images.size()) {
        report.reason = "shared grid and per-image affine image counts differ";
        return false;
    }
    combined = sharedGrid;
    combined.referenceImage = -1;
    constexpr double displacementLimit = 0.004;
    report.maxNormalizedDisplacement = 0.0;
    for (size_t image = 0; image < combined.images.size(); ++image) {
        for (int node = 0; node < panolume::kLocalWarpNodeCount; ++node) {
            const size_t index = static_cast<size_t>(node);
            const double dx = sharedGrid.images[image].dx[index]
                + perImageAffine.images[image].dx[index];
            const double dy = sharedGrid.images[image].dy[index]
                + perImageAffine.images[image].dy[index];
            combined.images[image].dx[index] = std::max(
                -displacementLimit, std::min(displacementLimit, dx)
            );
            combined.images[image].dy[index] = std::max(
                -displacementLimit, std::min(displacementLimit, dy)
            );
            report.maxNormalizedDisplacement = std::max(
                report.maxNormalizedDisplacement,
                std::max(
                    std::abs(combined.images[image].dx[index]),
                    std::abs(combined.images[image].dy[index])
                )
            );
        }
    }
    report.minimumJacobianDeterminant = panolume::minimum_local_warp_jacobian(combined);
    report.solverSucceeded = report.minimumJacobianDeterminant >= 0.7
        && report.maxNormalizedDisplacement <= displacementLimit + 1e-9;
    if (!report.solverSucceeded) {
        report.reason = "combined shared-grid and per-image affine warp violates displacement or Jacobian bounds";
    }
    return report.solverSucceeded;
}

enum class NativeAstroEvaluationPartition {
    validation,
    finalHeldOut
};

static bool native_camera_projection_plan(
    const std::vector<NativeImage> &images,
    const std::vector<NativeCameraParams> &cameras,
    const std::string &projection,
    NativeOutputBoundsReport &bounds,
    double &offsetX,
    double &offsetY,
    double &projectionScale,
    std::string &failureReason
);

static bool native_project_observed_pixel(
    const NativeCameraParams &camera,
    const NativeImage &image,
    const std::string &projection,
    const panolume::LocalWarpImageModel *localWarp,
    double x,
    double y,
    double &u,
    double &v
) {
    if (localWarp != nullptr) {
        const cv::Point2d ideal = native_local_warp_inverse_pixel(*localWarp, image, x, y);
        x = ideal.x;
        y = ideal.y;
    }
    double ray[3] = {0.0, 0.0, 0.0};
    return native_pixel_to_world_ray(camera, image, x, y, ray)
        && native_project_ray(ray, projection, u, v);
}

static double native_periodic_delta(double value, const std::string &projection) {
    const std::string mode = lower_string(projection);
    return mode == "equirectangular" || mode == "cylindrical"
        ? std::atan2(std::sin(value), std::cos(value))
        : value;
}

static double native_directional_mapped_fwhm(
    const NativeCameraParams &camera,
    const NativeImage &image,
    const std::string &projection,
    const panolume::LocalWarpImageModel *localWarp,
    double x,
    double y,
    double covarianceXX,
    double covarianceXY,
    double covarianceYY,
    double directionX,
    double directionY,
    double projectionScale,
    double fallbackFWHM
) {
    constexpr double epsilon = 0.25;
    double ux0 = 0.0;
    double vx0 = 0.0;
    double ux1 = 0.0;
    double vx1 = 0.0;
    double uy0 = 0.0;
    double vy0 = 0.0;
    double uy1 = 0.0;
    double vy1 = 0.0;
    if (!native_project_observed_pixel(camera, image, projection, localWarp, x - epsilon, y, ux0, vx0)
        || !native_project_observed_pixel(camera, image, projection, localWarp, x + epsilon, y, ux1, vx1)
        || !native_project_observed_pixel(camera, image, projection, localWarp, x, y - epsilon, uy0, vy0)
        || !native_project_observed_pixel(camera, image, projection, localWarp, x, y + epsilon, uy1, vy1)) {
        return std::max(0.25, fallbackFWHM);
    }
    const double j00 = native_periodic_delta(ux1 - ux0, projection)
        * projectionScale / (2.0 * epsilon);
    const double j10 = (vx1 - vx0) * projectionScale / (2.0 * epsilon);
    const double j01 = native_periodic_delta(uy1 - uy0, projection)
        * projectionScale / (2.0 * epsilon);
    const double j11 = (vy1 - vy0) * projectionScale / (2.0 * epsilon);
    if (!(covarianceXX > 0.0) || !(covarianceYY > 0.0)
        || covarianceXX * covarianceYY - covarianceXY * covarianceXY <= 0.0) {
        const double sigma = std::max(fallbackFWHM / 2.354820045, 0.1);
        covarianceXX = sigma * sigma;
        covarianceXY = 0.0;
        covarianceYY = sigma * sigma;
    }
    const double mappedXX = j00 * j00 * covarianceXX
        + 2.0 * j00 * j01 * covarianceXY + j01 * j01 * covarianceYY;
    const double mappedXY = j00 * j10 * covarianceXX
        + (j00 * j11 + j01 * j10) * covarianceXY + j01 * j11 * covarianceYY;
    const double mappedYY = j10 * j10 * covarianceXX
        + 2.0 * j10 * j11 * covarianceXY + j11 * j11 * covarianceYY;
    const double directionNorm = std::hypot(directionX, directionY);
    double variance = 0.5 * (mappedXX + mappedYY);
    if (directionNorm > 1e-9) {
        const double nx = directionX / directionNorm;
        const double ny = directionY / directionNorm;
        variance = nx * nx * mappedXX + 2.0 * nx * ny * mappedXY + ny * ny * mappedYY;
    }
    return std::max(0.25, 2.354820045 * std::sqrt(std::max(variance, 1e-12)));
}

static NativeAstroRefinementReport native_evaluate_heldout_pairs(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeSelectedEdge> &selectedEdges,
    const std::string &projection,
    const std::vector<std::vector<NativeStar>> *starSources = nullptr,
    const panolume::LocalWarpModel *localWarp = nullptr,
    NativeAstroEvaluationPartition partition = NativeAstroEvaluationPartition::finalHeldOut
) {
    (void)starSources;
    struct Observation {
        size_t pairIndex = 0;
        double error = 0.0;
        double fwhm = 0.0;
        double u = 0.0;
        double v = 0.0;
        double errorX = 0.0;
        double errorY = 0.0;
        double sourceX = 0.0;
        double sourceY = 0.0;
        double targetX = 0.0;
        double targetY = 0.0;
        double sourcePSFSignalToNoise = std::numeric_limits<double>::quiet_NaN();
        double targetPSFSignalToNoise = std::numeric_limits<double>::quiet_NaN();
        double sourcePSFNormalizedRMS = std::numeric_limits<double>::quiet_NaN();
        double targetPSFNormalizedRMS = std::numeric_limits<double>::quiet_NaN();
        double identityAssociationResidual = std::numeric_limits<double>::quiet_NaN();
    };

    NativeAstroRefinementReport report;
    report.state = "draft_heldout_validation";
    report.evaluationPartition = partition == NativeAstroEvaluationPartition::validation
        ? "validation" : "final_held_out";
    if (cameras.size() != images.size() || selectedEdges.empty()) {
        report.reason = "held-out validation requires matching cameras and selected edges";
        return report;
    }
    report.pairs.reserve(selectedEdges.size());
    std::vector<Observation> observations;
    for (const NativeSelectedEdge &edge : selectedEdges) {
        NativeHeldOutPairReport pair;
        pair.i = edge.i;
        pair.j = edge.j;
        pair.identityCandidates = edge.identityCandidates;
        pair.identityAccepted = edge.identityAccepted;
        pair.identityRejectedDescriptor = edge.identityRejectedDescriptor;
        pair.identityRejectedPatch = edge.identityRejectedPatch;
        pair.identityRejectedFWHM = edge.identityRejectedFWHM;
        pair.identityRejectedFlux = edge.identityRejectedFlux;
        pair.identityRejectedRatio = edge.identityRejectedRatio;
        pair.identityRejectedConflict = edge.identityRejectedConflict;
        pair.identityRejectedPrediction = edge.identityRejectedPrediction;
        pair.identityRejectedBoundary = edge.identityRejectedBoundary;
        pair.identityRejectedField = edge.identityRejectedField;
        pair.identityFieldCutoff = edge.identityFieldCutoff;
        pair.identityFieldMedian = edge.identityFieldMedian;
        pair.identityFieldP95 = edge.identityFieldP95;
        report.pairs.push_back(std::move(pair));
    }

    NativeOutputBoundsReport outputBounds;
    double outputOffsetX = 0.0;
    double outputOffsetY = 0.0;
    double projectionScale = 1.0;
    std::string projectionFailure;
    if (!native_camera_projection_plan(
            images,
            cameras,
            projection,
            outputBounds,
            outputOffsetX,
            outputOffsetY,
            projectionScale,
            projectionFailure
        )) {
        report.reason = "final projection-space validation failed: " + projectionFailure;
        return report;
    }
    (void)outputOffsetX;
    (void)outputOffsetY;
    for (size_t pairIndex = 0; pairIndex < selectedEdges.size(); ++pairIndex) {
        const NativeSelectedEdge &edge = selectedEdges[pairIndex];
        report.fitObservations += edge.fitObservationCount;
        report.validationObservations += static_cast<int>(edge.validationControlPoints.size());
        report.finalHeldOutObservations += static_cast<int>(edge.heldOutControlPoints.size());
        const std::vector<NativeControlPoint> &partitionPoints =
            partition == NativeAstroEvaluationPartition::validation
                ? edge.validationControlPoints : edge.heldOutControlPoints;
        // Every edge freezes correspondence identities before the
        // deterministic train/held-out split. Candidate Camera/lens models
        // only evaluate these observations; they may never select a friendlier
        // test set by re-associating stars under their own pose.
        for (const NativeControlPoint &point : partitionPoints) {
            if (point.imageAIndex < 0 || point.imageBIndex < 0
                || point.imageAIndex >= static_cast<int>(images.size())
                || point.imageBIndex >= static_cast<int>(images.size())) {
                continue;
            }
            const int a = point.imageAIndex;
            const int b = point.imageBIndex;
            const panolume::LocalWarpImageModel *warpA = localWarp != nullptr
                && localWarp->images.size() == images.size()
                ? &localWarp->images[static_cast<size_t>(a)] : nullptr;
            const panolume::LocalWarpImageModel *warpB = localWarp != nullptr
                && localWarp->images.size() == images.size()
                ? &localWarp->images[static_cast<size_t>(b)] : nullptr;
            double uA = 0.0;
            double vA = 0.0;
            double uB = 0.0;
            double vB = 0.0;
            if (!native_project_observed_pixel(
                    cameras[static_cast<size_t>(a)], images[static_cast<size_t>(a)],
                    projection, warpA, point.xA, point.yA, uA, vA
                )
                || !native_project_observed_pixel(
                    cameras[static_cast<size_t>(b)], images[static_cast<size_t>(b)],
                    projection, warpB, point.xB, point.yB, uB, vB
                )) {
                continue;
            }
            const double deltaU = native_periodic_delta(uA - uB, projection);
            const double deltaV = vA - vB;
            const double errorX = deltaU * projectionScale;
            const double errorY = deltaV * projectionScale;
            const double error = std::hypot(errorX, errorY);
            const double sourceFWHM = native_directional_mapped_fwhm(
                cameras[static_cast<size_t>(a)], images[static_cast<size_t>(a)],
                projection, warpA, point.xA, point.yA,
                point.sourceCovarianceXX, point.sourceCovarianceXY, point.sourceCovarianceYY,
                errorX, errorY, projectionScale, point.sourceFWHM
            );
            const double targetFWHM = native_directional_mapped_fwhm(
                cameras[static_cast<size_t>(b)], images[static_cast<size_t>(b)],
                projection, warpB, point.xB, point.yB,
                point.targetCovarianceXX, point.targetCovarianceXY, point.targetCovarianceYY,
                errorX, errorY, projectionScale, point.targetFWHM
            );
            const double adjustedUA = uB + deltaU;
            observations.push_back({
                pairIndex,
                error,
                std::max(0.25, 0.5 * (sourceFWHM + targetFWHM)),
                0.5 * (adjustedUA + uB),
                0.5 * (vA + vB),
                errorX,
                errorY,
                point.xA,
                point.yA,
                point.xB,
                point.yB,
                point.sourcePSFSignalToNoise,
                point.targetPSFSignalToNoise,
                point.sourcePSFNormalizedRMS,
                point.targetPSFNormalizedRMS,
                point.identityAssociationResidual
            });
        }
    }
    if (observations.empty()) {
        report.reason = "selected edges contain no independent held-out observations";
        return report;
    }

    double minU = observations.front().u;
    double maxU = observations.front().u;
    double minV = observations.front().v;
    double maxV = observations.front().v;
    for (const Observation &observation : observations) {
        minU = std::min(minU, observation.u);
        maxU = std::max(maxU, observation.u);
        minV = std::min(minV, observation.v);
        maxV = std::max(maxV, observation.v);
    }
    const double spanU = std::max(maxU - minU, 1e-9);
    const double spanV = std::max(maxV - minV, 1e-9);
    constexpr int gridColumns = 16;
    constexpr int gridRows = 8;
    struct GridValues {
        std::vector<double> errors;
        std::vector<double> fwhm;
        std::vector<double> riskRatios;
    };
    std::vector<std::map<std::pair<int, int>, GridValues>> grids(selectedEdges.size());
    std::vector<std::vector<double>> pairErrors(selectedEdges.size());
    std::vector<std::vector<double>> pairFWHM(selectedEdges.size());
    std::vector<std::vector<double>> pairRiskRatios(selectedEdges.size());
    std::vector<std::vector<size_t>> pairObservationIndices(selectedEdges.size());
    for (size_t observationIndex = 0; observationIndex < observations.size(); ++observationIndex) {
        const Observation &observation = observations[observationIndex];
        const int column = std::max(0, std::min(
            gridColumns - 1,
            static_cast<int>(std::floor((observation.u - minU) * gridColumns / spanU))
        ));
        const int row = std::max(0, std::min(
            gridRows - 1,
            static_cast<int>(std::floor((observation.v - minV) * gridRows / spanV))
        ));
        pairErrors[observation.pairIndex].push_back(observation.error);
        pairFWHM[observation.pairIndex].push_back(observation.fwhm);
        pairRiskRatios[observation.pairIndex].push_back(
            observation.error / std::max(0.75 * observation.fwhm, 1e-9)
        );
        pairObservationIndices[observation.pairIndex].push_back(observationIndex);
        GridValues &cell = grids[observation.pairIndex][{row, column}];
        cell.errors.push_back(observation.error);
        cell.fwhm.push_back(observation.fwhm);
        cell.riskRatios.push_back(
            observation.error / std::max(observation.fwhm, 1e-9)
        );
    }

    bool allPassed = true;
    for (size_t pairIndex = 0; pairIndex < report.pairs.size(); ++pairIndex) {
        NativeHeldOutPairReport &pair = report.pairs[pairIndex];
        pair.count = static_cast<int>(pairErrors[pairIndex].size());
        pair.occupiedCells = static_cast<int>(grids[pairIndex].size());
        if (!pairErrors[pairIndex].empty()) {
            pair.p95 = percentile_value(pairErrors[pairIndex], 95.0);
            pair.mappedFWHM = median_value(pairFWHM[pairIndex]);
            // Every PSF is mapped through its own local projection Jacobian.
            // Preserve that pairing before taking P95; dividing an error P95
            // by a global median FWHM incorrectly penalizes legitimate
            // high-Jacobian observations near projection poles/seams.
            pair.pairRiskRatio = percentile_value(pairRiskRatios[pairIndex], 95.0);
        }
        std::vector<size_t> worst = pairObservationIndices[pairIndex];
        std::sort(worst.begin(), worst.end(), [&observations](size_t lhs, size_t rhs) {
            if (observations[lhs].error != observations[rhs].error) {
                return observations[lhs].error > observations[rhs].error;
            }
            if (observations[lhs].sourceY != observations[rhs].sourceY) {
                return observations[lhs].sourceY < observations[rhs].sourceY;
            }
            return observations[lhs].sourceX < observations[rhs].sourceX;
        });
        for (size_t index = 0; index < std::min<size_t>(3, worst.size()); ++index) {
            const Observation &observation = observations[worst[index]];
            pair.worstObservations.push_back({
                observation.error,
                observation.fwhm,
                observation.sourceX,
                observation.sourceY,
                observation.targetX,
                observation.targetY,
                observation.sourcePSFSignalToNoise,
                observation.targetPSFSignalToNoise,
                observation.sourcePSFNormalizedRMS,
                observation.targetPSFNormalizedRMS,
                observation.identityAssociationResidual
            });
        }
        struct DirectionValues {
            const char *name;
            std::vector<double> radial;
            std::vector<double> tangential;
        };
        std::array<DirectionValues, 3> directionValues = {{
            {"inner", {}, {}},
            {"middle", {}, {}},
            {"outer", {}, {}}
        }};
        const double centerU = 0.5 * (minU + maxU);
        const double centerV = 0.5 * (minV + maxV);
        for (size_t observationIndex : pairObservationIndices[pairIndex]) {
            const Observation &observation = observations[observationIndex];
            const double normalizedX = 2.0 * (observation.u - centerU) / spanU;
            const double normalizedY = 2.0 * (observation.v - centerV) / spanV;
            const double normalizedRadius = std::hypot(normalizedX, normalizedY);
            const size_t bucket = normalizedRadius <= 1.0 / 3.0
                ? 0 : (normalizedRadius <= 2.0 / 3.0 ? 1 : 2);
            const double radialPixelsX = (observation.u - centerU) * projectionScale;
            const double radialPixelsY = (observation.v - centerV) * projectionScale;
            const double radialNorm = std::hypot(radialPixelsX, radialPixelsY);
            double radialResidual = 0.0;
            double tangentialResidual = observation.error;
            if (radialNorm > 1e-9) {
                const double radialUnitX = radialPixelsX / radialNorm;
                const double radialUnitY = radialPixelsY / radialNorm;
                radialResidual = std::abs(
                    observation.errorX * radialUnitX + observation.errorY * radialUnitY
                );
                tangentialResidual = std::abs(
                    -observation.errorX * radialUnitY + observation.errorY * radialUnitX
                );
            }
            directionValues[bucket].radial.push_back(radialResidual);
            directionValues[bucket].tangential.push_back(tangentialResidual);
        }
        for (DirectionValues &values : directionValues) {
            NativeResidualDirectionBucketReport bucket;
            bucket.band = values.name;
            bucket.count = static_cast<int>(values.radial.size());
            if (!values.radial.empty()) {
                bucket.radialP95 = percentile_value(values.radial, 95.0);
                bucket.tangentialP95 = percentile_value(values.tangential, 95.0);
            }
            pair.residualDirectionBuckets.push_back(std::move(bucket));
        }
        pair.worstGridRiskRatio = 0.0;
        for (const auto &entry : grids[pairIndex]) {
            NativeHeldOutGridReport grid;
            grid.row = entry.first.first;
            grid.column = entry.first.second;
            grid.count = static_cast<int>(entry.second.errors.size());
            grid.p95 = percentile_value(entry.second.errors, 95.0);
            grid.mappedFWHM = median_value(entry.second.fwhm);
            grid.riskRatio = percentile_value(entry.second.riskRatios, 95.0);
            grid.effective = grid.count >= 3;
            if (grid.effective) {
                pair.effectiveCells += 1;
                pair.worstGridRiskRatio = std::max(pair.worstGridRiskRatio, grid.riskRatio);
            } else {
                pair.lowSupportCells += 1;
            }
            pair.grids.push_back(std::move(grid));
        }
        const bool finalGate = partition == NativeAstroEvaluationPartition::finalHeldOut;
        const int minimumStars = finalGate ? 12 : 4;
        const int minimumOccupiedCells = finalGate ? 4 : 2;
        const int minimumEffectiveCells = finalGate ? 2 : 0;
        if (pair.count < minimumStars) {
            pair.reason = finalGate
                ? "fewer than 12 independent final held-out stars"
                : "fewer than four independent validation stars";
        } else if (pair.occupiedCells < minimumOccupiedCells) {
            pair.reason = finalGate
                ? "final held-out stars occupy fewer than four output cells"
                : "validation stars occupy fewer than two output cells";
        } else if (pair.effectiveCells < minimumEffectiveCells) {
            pair.reason = "fewer than two output cells contain at least three final held-out stars";
        } else if (!std::isfinite(pair.pairRiskRatio) || pair.pairRiskRatio > 1.0) {
            pair.reason = "pair P95 exceeds 0.75x mapped star FWHM";
        } else if (!std::isfinite(pair.worstGridRiskRatio) || pair.worstGridRiskRatio > 1.0) {
            pair.reason = "worst output cell exceeds mapped star FWHM";
        } else {
            pair.passed = true;
            pair.reason = finalGate
                ? "independent final held-out pair and grid gates passed"
                : "independent validation pair and grid metrics passed";
        }
        allPassed = allPassed && pair.passed;
    }
    report.qualityGatePassed = allPassed;
    report.reason = allPassed
        ? (partition == NativeAstroEvaluationPartition::finalHeldOut
            ? "final projection-space held-out geometry passed"
            : "validation projection-space geometry passed")
        : (partition == NativeAstroEvaluationPartition::finalHeldOut
            ? "one or more selected edges failed final projection-space held-out validation"
            : "one or more selected edges failed model-selection validation");
    return report;
}

static double native_heldout_worst_pair_p95(const NativeAstroRefinementReport &report) {
    double value = -std::numeric_limits<double>::infinity();
    for (const NativeHeldOutPairReport &pair : report.pairs) {
        if (std::isfinite(pair.p95)) {
            value = std::max(value, pair.p95);
        }
    }
    return value == -std::numeric_limits<double>::infinity()
        ? std::numeric_limits<double>::quiet_NaN()
        : value;
}

static double native_heldout_worst_grid_risk(const NativeAstroRefinementReport &report) {
    double value = -std::numeric_limits<double>::infinity();
    for (const NativeHeldOutPairReport &pair : report.pairs) {
        if (std::isfinite(pair.worstGridRiskRatio)) {
            value = std::max(value, pair.worstGridRiskRatio);
        }
    }
    return value == -std::numeric_limits<double>::infinity()
        ? std::numeric_limits<double>::quiet_NaN()
        : value;
}

static bool native_heldout_pairs_do_not_regress(
    const NativeAstroRefinementReport &baseline,
    const NativeAstroRefinementReport &candidate,
    double tolerance = 1.05
) {
    for (const NativeHeldOutPairReport &basePair : baseline.pairs) {
        const auto found = std::find_if(
            candidate.pairs.begin(),
            candidate.pairs.end(),
            [&basePair](const NativeHeldOutPairReport &pair) {
                return native_edge_key(pair.i, pair.j) == native_edge_key(basePair.i, basePair.j);
            }
        );
        if (found == candidate.pairs.end()
            || !std::isfinite(basePair.p95)
            || !std::isfinite(found->p95)
            || found->p95 > basePair.p95 * tolerance + 1e-9) {
            return false;
        }
        if (basePair.effectiveCells >= 2 && found->effectiveCells >= 2
            && std::isfinite(basePair.worstGridRiskRatio)
            && std::isfinite(found->worstGridRiskRatio)
            && found->worstGridRiskRatio > basePair.worstGridRiskRatio * tolerance + 1e-9) {
            return false;
        }
    }
    return true;
}

static NativeAstroRefinementReport native_select_lens_model_by_heldout(
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &trainingPoints,
    const std::vector<NativeControlPoint> &refitPoints,
    const std::vector<NativeSelectedEdge> &selectedEdges,
    const std::string &projection,
    bool optimizeFocal,
    int maxIterations,
    double fixedInitialFocal,
    std::vector<NativeCameraParams> &cameras,
    std::string &solverSummary,
    bool &fitPlusValidationRefitSucceeded,
    const std::vector<std::vector<NativeStar>> *starSources = nullptr,
    const NativeLensCalibrationPrior *lensPrior = nullptr
) {
    fitPlusValidationRefitSucceeded = false;
    NativeAstroRefinementReport chosen = native_evaluate_heldout_pairs(
        cameras,
        images,
        selectedEdges,
        projection,
        starSources,
        nullptr,
        NativeAstroEvaluationPartition::validation
    );
    chosen.lensModel = "rotation_shared_focal";
    if (lensPrior != nullptr && lensPrior->available) {
        chosen.lensPriorAvailable = true;
        chosen.lensPriorSHA256 = lensPrior->sha256;
        chosen.lensPriorWarning = lensPrior->warning;
        chosen.lensPriorWeight = lensPrior->priorWeight;
        chosen.lensPriorConversionMaxErrorPixels = lensPrior->conversionMaxErrorPixels;
    }
    const double baseP95 = native_heldout_worst_pair_p95(chosen);
    const double baseGridRisk = native_heldout_worst_grid_risk(chosen);
    NativeLensModelCandidateReport baseCandidate;
    baseCandidate.model = chosen.lensModel;
    baseCandidate.solverSucceeded = true;
    baseCandidate.accepted = true;
    baseCandidate.worstPairP95 = baseP95;
    baseCandidate.worstGridRiskRatio = baseGridRisk;
    baseCandidate.reason = "baseline lens model";
    chosen.lensModels.push_back(baseCandidate);

    struct CandidateOptions { const char *name; bool distortion; bool principal; };
    const std::array<CandidateOptions, 1> options = {{
        {"shared_brown_conrady_k1_k2_k3_p1_p2_principal", true, true}
    }};
    double bestP95 = baseP95;
    std::vector<NativeCameraParams> bestCameras = cameras;
    std::string bestSummary = solverSummary;
    NativeAstroRefinementReport bestReport = chosen;
    bool bestDistortion = false;
    bool bestPrincipal = false;

    for (const CandidateOptions &option : options) {
        NativeLensModelCandidateReport model;
        model.model = option.name;
        std::vector<NativeCameraParams> candidateCameras = cameras;
        for (NativeCameraParams &camera : candidateCameras) {
            const std::array<double, 5> initialDistortion = lensPrior != nullptr && lensPrior->available
                ? lensPrior->distortion
                : std::array<double, 5>{0.0, 0.0, 0.0, 0.0, 0.0};
            camera.k1 = initialDistortion[0];
            camera.k2 = initialDistortion[1];
            camera.k3 = initialDistortion[2];
            camera.p1 = initialDistortion[3];
            camera.p2 = initialDistortion[4];
            if (lensPrior != nullptr && lensPrior->available) {
                camera.focalLength *= lensPrior->focalScale;
            }
            camera.principalOffsetX = lensPrior != nullptr && lensPrior->available
                ? lensPrior->principal[0] : 0.0;
            camera.principalOffsetY = lensPrior != nullptr && lensPrior->available
                ? lensPrior->principal[1] : 0.0;
        }
        std::string candidateSummary;
        model.solverSucceeded = run_ceres_camera_adjustment(
            images,
            trainingPoints,
            optimizeFocal,
            option.distortion,
            maxIterations,
            candidateCameras,
            candidateSummary,
            fixedInitialFocal,
            option.principal,
            lensPrior
        );
        if (!model.solverSucceeded) {
            model.reason = "candidate solver failed: " + candidateSummary;
            chosen.lensModels.push_back(std::move(model));
            continue;
        }
        NativeAstroRefinementReport candidateReport = native_evaluate_heldout_pairs(
            candidateCameras,
            images,
            selectedEdges,
            projection,
            starSources,
            nullptr,
            NativeAstroEvaluationPartition::validation
        );
        model.worstPairP95 = native_heldout_worst_pair_p95(candidateReport);
        model.worstGridRiskRatio = native_heldout_worst_grid_risk(candidateReport);
        if (std::isfinite(baseP95) && baseP95 > 0.0 && std::isfinite(model.worstPairP95)) {
            model.heldOutImprovement = (baseP95 - model.worstPairP95) / baseP95;
        }
        const bool gridStable = std::isfinite(model.worstGridRiskRatio)
            && (!std::isfinite(baseGridRisk) || model.worstGridRiskRatio <= baseGridRisk * 1.05 + 1e-9);
        model.accepted = model.heldOutImprovement >= 0.10
            && gridStable
            && native_heldout_pairs_do_not_regress(chosen, candidateReport, 1.05);
        if (!model.accepted) {
            model.reason = model.heldOutImprovement < 0.10
                ? "validation P95 improvement is below 10%"
                : "a validation pair/grid regressed by more than 5%";
        } else {
            model.reason = "validation improvement and pair/grid stability gates passed";
            if (!std::isfinite(bestP95) || model.worstPairP95 < bestP95) {
                bestP95 = model.worstPairP95;
                bestCameras = candidateCameras;
                bestSummary = candidateSummary;
                bestReport = candidateReport;
                bestReport.lensModel = option.name;
                bestDistortion = option.distortion;
                bestPrincipal = option.principal;
            }
        }
        chosen.lensModels.push_back(model);
    }

    // Once complexity is frozen, refit exactly once with fit+validation (60%).
    // No final-held-out observation has been evaluated by this function.
    std::vector<NativeCameraParams> refittedCameras = bestCameras;
    std::string refitSummary;
    if (!refitPoints.empty() && run_ceres_camera_adjustment(
            images,
            refitPoints,
            optimizeFocal,
            bestDistortion,
            maxIterations,
            refittedCameras,
            refitSummary,
            fixedInitialFocal,
            bestPrincipal,
            lensPrior
        )) {
        cameras = std::move(refittedCameras);
        solverSummary = refitSummary + "; refit_partition=fit_plus_validation";
        fitPlusValidationRefitSucceeded = true;
    } else {
        cameras = std::move(bestCameras);
        solverSummary = bestSummary + "; fit_plus_validation refit failed: " + refitSummary;
        bestReport.qualityGatePassed = false;
        bestReport.reason = "selected lens model could not be refit on fit+validation";
    }
    bestReport.lensModels = chosen.lensModels;
    bestReport.lensPriorAvailable = chosen.lensPriorAvailable;
    bestReport.lensPriorSHA256 = chosen.lensPriorSHA256;
    bestReport.lensPriorWarning = chosen.lensPriorWarning;
    bestReport.lensPriorWeight = chosen.lensPriorWeight;
    bestReport.lensPriorConversionMaxErrorPixels = chosen.lensPriorConversionMaxErrorPixels;
    return bestReport;
}

static std::string native_camera_quality_failure_reason(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    const std::vector<NativeControlPoint> &points,
    double optimizedRms,
    double selectedPairP95,
    int worstSelectedEdgeI,
    int worstSelectedEdgeJ,
    double fixedInitialFocal,
    const NativeStarProjectionAlignmentReport &starProjectionReport,
    const NativeAstroRefinementReport &heldOutReport,
    const panolume::EngineRequest &request
) {
    if (cameras.size() != images.size() || cameras.empty()) {
        return "camera quality gate rejected: camera parameter count does not match images";
    }
    if (!native_camera_params_are_finite(cameras)) {
        return "camera quality gate rejected: non-finite camera parameters";
    }
    const double focalLowerBound = std::max(50.0, fixedInitialFocal * 0.25);
    const double focalUpperBound = fixedInitialFocal * 4.0;
    for (const NativeCameraParams &camera : cameras) {
        if (camera.focalLength < focalLowerBound - 1e-6
            || camera.focalLength > focalUpperBound + 1e-6) {
            std::ostringstream reason;
            reason << "camera quality gate rejected: focal length " << camera.focalLength
                   << " is outside fixed initial-focal bounds [" << focalLowerBound
                   << ", " << focalUpperBound << "]";
            return reason.str();
        }
    }
    const int finiteErrors = finite_control_point_error_count(points);
    const int minFiniteErrors = std::max(8, static_cast<int>(images.size()) * 4);
    if (finiteErrors < minFiniteErrors) {
        return "camera quality gate rejected: too few finite reprojection errors";
    }
    if (!std::isfinite(optimizedRms) || optimizedRms < 0.0) {
        return "camera quality gate rejected: optimized RMS is not finite or is negative";
    }
    if (!std::isfinite(selectedPairP95)) {
        return "camera quality gate rejected: selected-pair P95 is not finite";
    }
    const double maxOptimizedRms = std::max(0.25, request.number("cameraModelMaxOptimizedRMSPx", 5.0));
    const double maxSelectedPairP95 = std::max(0.5, request.number("cameraModelMaxSelectedPairP95Px", 8.0));
    if (optimizedRms > maxOptimizedRms) {
        std::ostringstream reason;
        reason << "camera quality gate rejected: optimized RMS " << optimizedRms
               << " exceeds " << maxOptimizedRms << " px";
        return reason.str();
    }
    if (selectedPairP95 > maxSelectedPairP95) {
        std::ostringstream reason;
        reason << "camera quality gate rejected: selected edge "
               << worstSelectedEdgeI << "-" << worstSelectedEdgeJ
               << " P95 " << selectedPairP95 << " exceeds " << maxSelectedPairP95 << " px";
        return reason.str();
    }
    // nearest/high-confidence/mutual are compatibility diagnostics only. They
    // are radius-truncated samples and therefore cannot independently prove
    // geometry quality. Selected-edge held-out observations below never enter
    // pair fitting, tree selection, Ceres, or refinement.
    (void)starProjectionReport;
    if (heldOutReport.pairs.empty()) {
        return "camera quality gate rejected: independent held-out pair evidence is unavailable";
    }
    // The working-resolution pass is deliberately a draft. It rejects gross
    // untruncated held-out failures and weak spatial evidence, then delegates
    // the FWHM-relative 0.75x/1.0x gate to the independently decoded full-
    // resolution refinement. Applying that final gate here disconnected an
    // otherwise sub-pixel boundary image before refinement could run.
    const auto draftPairFailed = [maxSelectedPairP95](const NativeHeldOutPairReport &pair) {
        return pair.count < 8
            || pair.occupiedCells < 4
            || !std::isfinite(pair.p95)
            || pair.p95 > maxSelectedPairP95;
    };
    const auto imageLabel = [&images](int index) {
        std::ostringstream label;
        label << "C" << (index + 1);
        if (index >= 0 && index < static_cast<int>(images.size())) {
            const std::string &path = images[static_cast<size_t>(index)].path;
            const size_t slash = path.find_last_of("/\\");
            label << " " << (slash == std::string::npos ? path : path.substr(slash + 1));
        }
        return label.str();
    };
    const auto draftPairFailureReason = [maxSelectedPairP95, &imageLabel](const NativeHeldOutPairReport &pair) {
        std::ostringstream reason;
        reason << "camera quality gate rejected: " << imageLabel(pair.i)
               << " ↔ " << imageLabel(pair.j) << ": ";
        if (pair.count < 8) {
            reason << "only " << pair.count << " independent draft held-out stars; 8 required";
        } else if (pair.occupiedCells < 4) {
            reason << "held-out stars occupy " << pair.occupiedCells << " spatial cells; 4 required";
        } else if (!std::isfinite(pair.p95)) {
            reason << "draft held-out P95 is not finite";
        } else {
            reason << "untruncated draft held-out P95 " << pair.p95
                   << " px exceeds " << maxSelectedPairP95 << " px";
        }
        return reason.str();
    };
    // Keep the diagnostic edge and the edge removed by the retry loop bound to
    // the same failing observation.  The final FWHM-relative report marks many
    // otherwise usable draft edges as not-passed by design; it must not choose
    // which draft edge is removed.
    for (const NativeHeldOutPairReport &pair : heldOutReport.pairs) {
        if (native_edge_key(pair.i, pair.j) == native_edge_key(worstSelectedEdgeI, worstSelectedEdgeJ)
            && draftPairFailed(pair)) {
            return draftPairFailureReason(pair);
        }
    }
    for (const NativeHeldOutPairReport &pair : heldOutReport.pairs) {
        if (draftPairFailed(pair)) {
            return draftPairFailureReason(pair);
        }
    }
    return "";
}

static bool native_camera_candidate_is_renderable(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &images,
    double fixedInitialFocal
) {
    if (cameras.size() != images.size() || cameras.empty() || !native_camera_params_are_finite(cameras)) {
        return false;
    }
    const double lower = std::max(50.0, fixedInitialFocal * 0.25);
    const double upper = fixedInitialFocal * 4.0;
    for (const NativeCameraParams &camera : cameras) {
        if (camera.focalLength < lower - 1e-6 || camera.focalLength > upper + 1e-6
            || std::abs(camera.principalOffsetX) > 0.05 + 1e-9
            || std::abs(camera.principalOffsetY) > 0.05 + 1e-9) {
            return false;
        }
    }
    return true;
}
#endif

static void try_native_camera_model(
    NativeResult &result,
    const std::vector<NativeImage> &images,
    const std::vector<cv::Mat> &imageToPanorama,
    const std::vector<std::vector<NativeStar>> &starSources,
    const panolume::EngineRequest &request
) {
    NativeCameraModelReport report;
    NativeLensCalibrationPrior lensPrior = native_lens_calibration_prior_from_request(
        request.root()
    );
    if (lensPrior.available && !images.empty() && !images.front().cameraMake.empty()) {
        auto normalizeMake = [](const std::string &value) {
            std::string normalized;
            for (unsigned char character : value) {
                if (std::isalpha(character)) normalized.push_back(static_cast<char>(std::toupper(character)));
            }
            return normalized;
        };
        const std::string profileMake = normalizeMake(lensPrior.cameraMake);
        const std::string imageMake = normalizeMake(images.front().cameraMake);
        if (!profileMake.empty() && !imageMake.empty()
            && profileMake.find(imageMake) == std::string::npos
            && imageMake.find(profileMake) == std::string::npos) {
            lensPrior.cameraMakeMismatch = true;
            lensPrior.priorWeight = std::min(lensPrior.priorWeight, 0.15);
            lensPrior.warning = "Profile body " + lensPrior.cameraMake
                + " does not match source body " + images.front().cameraMake
                + "; coefficients remain a weak initialization only.";
        }
    }
    report.attempted = true;
    report.robustThreshold = std::max(1.0, request.number("cameraModelRobustReprojectionPx", 5.0));
    const int minPoints = std::max(8, static_cast<int>(images.size()) * 4);
    std::vector<NativeControlPoint> optimizationPoints = native_selected_edge_control_points(
        result.controlPoints,
        result.selectedEdges
    );
    if (static_cast<int>(optimizationPoints.size()) < minPoints) {
        optimizationPoints = result.controlPoints;
    }
    const std::vector<NativeControlPoint> submittedOptimizationPoints = optimizationPoints;
    report.inputControlPoints = static_cast<int>(optimizationPoints.size());
    if (images.size() < 2 || static_cast<int>(optimizationPoints.size()) < minPoints) {
        report.success = false;
        report.reason = "not enough control points for camera adjustment";
        result.cameraModelReport = report;
        return;
    }
    if (!dependency_available("ceres")) {
        report.success = false;
        report.reason = "Ceres dependency is not available";
        result.cameraModelReport = report;
        return;
    }

    const double initialFocal = estimate_initial_focal(images, request, &report.focalSource);
    std::vector<NativeCameraParams> cameras = initialize_camera_params(images, imageToPanorama, request, initialFocal);
    for (NativeCameraParams &camera : cameras) {
        camera.k1 = 0.0;
        camera.k2 = 0.0;
        camera.k3 = 0.0;
        camera.p1 = 0.0;
        camera.p2 = 0.0;
        camera.principalOffsetX = 0.0;
        camera.principalOffsetY = 0.0;
    }
    report.initialFocal = initialFocal;
    report.initialDistortion = cameras.empty() ? report.initialDistortion : camera_distortion_values(cameras.front());
    report.optimizedDistortion = report.initialDistortion;
    report.initialRms = camera_rms_error(cameras, images, optimizationPoints);
#if MYPTGUI_HAS_CERES_HEADERS
    std::string summary;
    const bool optimizeFocal = request.boolean("optimizeFocal", true);
    const bool optimizeDistortion = false;
    const int maxIterations = std::max(10, request.integer("optimizerMaxIterations", 200));
    const int maxRobustRounds = std::max(1, std::min(5, request.integer("cameraModelRobustRounds", 3)));
    const int minRobustPairInliers = std::max(0, request.integer("cameraModelRobustMinPairInliers", 5));
    report.distortionOptimized = false;
    report.robustMaxRounds = maxRobustRounds;
    if (!run_ceres_camera_adjustment(images, optimizationPoints, optimizeFocal, optimizeDistortion, maxIterations, cameras, summary, initialFocal)) {
        report.success = false;
        report.reason = "Ceres solver failed";
        report.solverSummary = summary;
        result.cameraModelReport = report;
        return;
    }
    report.solverSucceeded = true;

    std::vector<NativeControlPoint> workingPoints = std::move(optimizationPoints);
    for (int round = 0; round < maxRobustRounds; ++round) {
        report.robustRounds = round + 1;
        apply_camera_errors_to_control_points(cameras, images, workingPoints);
        std::vector<NativeControlPoint> robustPoints = native_camera_reprojection_inliers(
            workingPoints,
            result.selectedEdges,
            report.robustThreshold,
            minRobustPairInliers
        );

        if (static_cast<int>(robustPoints.size()) < minPoints) {
            report.robustStopReason = "filtered control point count would fall below the minimum";
            break;
        }
        if (robustPoints.size() == workingPoints.size()) {
            report.robustStopReason = "all remaining control points are within threshold";
            break;
        }

        std::vector<NativeCameraParams> robustCameras = cameras;
        std::string robustSummary;
        if (run_ceres_camera_adjustment(images, robustPoints, optimizeFocal, optimizeDistortion, maxIterations, robustCameras, robustSummary, initialFocal)) {
            cameras = robustCameras;
            workingPoints = std::move(robustPoints);
            summary = robustSummary;
            report.robustStopReason = "accepted filtered control points";
        } else {
            report.robustStopReason = "Ceres solver failed on filtered control points";
            break;
        }
    }
    if (report.robustStopReason.empty()) {
        report.robustStopReason = "reached maximum robust rounds";
    }
    result.controlPoints = std::move(workingPoints);
    apply_camera_errors_to_control_points(cameras, images, result.controlPoints);
    const int robustOutputControlPoints = static_cast<int>(result.controlPoints.size());
    report.robustRejected = report.inputControlPoints - robustOutputControlPoints;

    NativeGuidedRefinementReport guidedReport;
    const bool enableGuidedRefinement = request.boolean("cameraModelGuidedRefinement", true);
    guidedReport.enabled = enableGuidedRefinement
        && starSources.size() == images.size()
        && !result.selectedEdges.empty();
    guidedReport.inputControlPoints = robustOutputControlPoints;
    guidedReport.outputControlPoints = robustOutputControlPoints;
    if (!enableGuidedRefinement) {
        guidedReport.reason = "guided star refinement disabled";
    } else if (starSources.size() != images.size()) {
        guidedReport.reason = "star detections unavailable";
    } else if (result.selectedEdges.empty()) {
        guidedReport.reason = "selected edges unavailable";
    } else {
        const double guidedThreshold = std::min(std::max(report.robustThreshold, 1.5), 3.0);
        const int maxGuidedPointsPerPair = std::max(1, request.integer("cameraModelGuidedMaxPointsPerPair", 64));
        std::vector<NativeControlPoint> guidedPoints;
        const std::vector<NativeControlPoint> reservedPoints = native_control_points_with_reserved_holdout(result);
        for (const NativeSelectedEdge &edge : result.selectedEdges) {
            NativeGuidedPairReport pairReport;
            std::vector<NativeControlPoint> pairPoints = guided_star_points_for_pair(
                edge.i,
                edge.j,
                cameras,
                images,
                starSources,
                reservedPoints,
                guidedThreshold,
                maxGuidedPointsPerPair,
                pairReport
            );
            guidedPoints.insert(guidedPoints.end(), pairPoints.begin(), pairPoints.end());
            guidedReport.pairs.push_back(pairReport);
        }

        if (guidedPoints.empty()) {
            guidedReport.reason = "guided star matching found no additional clean points";
        } else {
            std::vector<NativeControlPoint> candidatePoints = result.controlPoints;
            candidatePoints.insert(candidatePoints.end(), guidedPoints.begin(), guidedPoints.end());
            candidatePoints = dedupe_control_points(std::move(candidatePoints), 1.5);
            guidedReport.addedControlPoints = static_cast<int>(candidatePoints.size()) - robustOutputControlPoints;
            guidedReport.outputControlPoints = static_cast<int>(candidatePoints.size());
            if (guidedReport.addedControlPoints <= 0) {
                guidedReport.reason = "guided star points duplicated existing robust points";
            } else if (static_cast<int>(candidatePoints.size()) < minPoints) {
                guidedReport.reason = "guided point set is too small for camera optimization";
            } else {
                std::vector<NativeCameraParams> guidedCameras = cameras;
                std::string guidedSummary;
                if (!run_ceres_camera_adjustment(images, candidatePoints, optimizeFocal, optimizeDistortion, maxIterations, guidedCameras, guidedSummary, initialFocal)) {
                    guidedReport.reason = "Ceres solver failed on guided star points";
                } else {
                    apply_camera_errors_to_control_points(guidedCameras, images, candidatePoints);
                    guidedReport.currentRms = camera_rms_error(cameras, images, result.controlPoints);
                    guidedReport.candidateRms = camera_rms_error(guidedCameras, images, result.controlPoints);
                    const double maxAllowedRms = guidedReport.currentRms + 1e-6;
                    if (!std::isfinite(guidedReport.candidateRms)) {
                        guidedReport.reason = "guided optimization produced no finite RMS";
                    } else if (std::isfinite(guidedReport.currentRms) && guidedReport.currentRms > 0.0 && guidedReport.candidateRms > maxAllowedRms) {
                        guidedReport.reason = "guided optimization worsened robust RMS";
                    } else {
                        guidedReport.accepted = true;
                        guidedReport.reason = "guided star points accepted";
                        cameras = std::move(guidedCameras);
                        result.controlPoints = std::move(candidatePoints);
                        summary = guidedSummary;
                    }
                }
            }
        }
    }
    if (guidedReport.accepted) {
        apply_camera_errors_to_control_points(cameras, images, result.controlPoints);
        guidedReport.outputControlPoints = static_cast<int>(result.controlPoints.size());
    } else {
        guidedReport.outputControlPoints = robustOutputControlPoints;
    }
    result.guidedRefinementReport = guidedReport;

    try_native_local_star_refinement(
        result,
        images,
        starSources,
        optimizeFocal,
        optimizeDistortion,
        maxIterations,
        initialFocal,
        cameras,
        summary,
        request
    );
    if (result.localRefinementReport.accepted) {
        apply_camera_errors_to_control_points(cameras, images, result.controlPoints);
    }

    try_native_texture_sift_refinement(
        result,
        images,
        optimizeFocal,
        optimizeDistortion,
        maxIterations,
        initialFocal,
        cameras,
        summary,
        request
    );
    if (result.textureRefinementReport.accepted) {
        apply_camera_errors_to_control_points(cameras, images, result.controlPoints);
    }

    std::vector<NativeControlPoint> fitPlusValidation = result.controlPoints;
    for (const NativeSelectedEdge &edge : result.selectedEdges) {
        fitPlusValidation.insert(
            fitPlusValidation.end(),
            edge.validationControlPoints.begin(),
            edge.validationControlPoints.end()
        );
    }
    bool previewFitPlusValidationRefitSucceeded = false;
    NativeAstroRefinementReport previewSelection = native_select_lens_model_by_heldout(
        images,
        result.controlPoints,
        fitPlusValidation,
        result.selectedEdges,
        result.projection,
        optimizeFocal,
        maxIterations,
        initialFocal,
        cameras,
        summary,
        previewFitPlusValidationRefitSucceeded,
        &starSources,
        lensPrior.available ? &lensPrior : nullptr
    );
    if (!previewFitPlusValidationRefitSucceeded) {
        report.success = false;
        report.reason = "Camera model failed mandatory fit+validation refit: " + summary;
        report.solverSummary = summary;
        result.cameraModelReport = report;
        return;
    }
    result.astroRefinementReport = native_evaluate_heldout_pairs(
        cameras,
        images,
        result.selectedEdges,
        result.projection,
        &starSources,
        nullptr,
        NativeAstroEvaluationPartition::finalHeldOut
    );
    result.astroRefinementReport.lensModel = previewSelection.lensModel;
    result.astroRefinementReport.lensModels = previewSelection.lensModels;
    result.astroRefinementReport.lensPriorAvailable = previewSelection.lensPriorAvailable;
    result.astroRefinementReport.lensPriorSHA256 = previewSelection.lensPriorSHA256;
    result.astroRefinementReport.lensPriorWarning = previewSelection.lensPriorWarning;
    result.astroRefinementReport.lensPriorWeight = previewSelection.lensPriorWeight;
    result.astroRefinementReport.lensPriorConversionMaxErrorPixels = previewSelection.lensPriorConversionMaxErrorPixels;
    report.distortionOptimized = result.astroRefinementReport.lensModel.find("brown_conrady") != std::string::npos;

    apply_camera_errors_to_control_points(cameras, images, result.controlPoints);
    report.outputControlPoints = static_cast<int>(result.controlPoints.size());
    report.optimizedFocal = cameras.empty() ? initialFocal : cameras.front().focalLength;
    report.optimizedDistortion = cameras.empty() ? report.initialDistortion : camera_distortion_values(cameras.front());
    report.optimizedRms = camera_rms_error(cameras, images, result.controlPoints);
    report.selectedPairP95 = selected_pair_p95_error(
        result.controlPoints,
        result.selectedEdges,
        report.worstSelectedEdgeI,
        report.worstSelectedEdgeJ
    );
    report.solverSummary = summary;
    const NativeStarProjectionAlignmentReport starProjectionReport = native_star_projection_alignment_report(
        cameras,
        images,
        starSources,
        result.selectedEdges,
        request
    );
    result.starProjectionAlignmentReport = starProjectionReport;
    result.starProjectionAlignmentJson = native_star_projection_alignment_json(starProjectionReport);
    result.manualPointFilteringReport = manual_point_filtering_report(
        submittedOptimizationPoints,
        result.controlPoints,
        "manual control points were rejected as duplicates, invalid observations, or robust reprojection outliers"
    );
    if (result.astroRefinementReport.pairs.empty()) {
        result.astroRefinementReport = native_evaluate_heldout_pairs(
            cameras,
            images,
            result.selectedEdges,
            result.projection,
            &starSources
        );
    }
    const double draftMaxSelectedPairP95 = std::max(
        0.5,
        request.number("cameraModelMaxSelectedPairP95Px", 8.0)
    );
    bool foundDraftFailureEdge = false;
    double worstDraftFailureSeverity = -std::numeric_limits<double>::infinity();
    double largestHeldOutP95 = -std::numeric_limits<double>::infinity();
    int largestHeldOutP95I = report.worstSelectedEdgeI;
    int largestHeldOutP95J = report.worstSelectedEdgeJ;
    for (const NativeHeldOutPairReport &pair : result.astroRefinementReport.pairs) {
        if (std::isfinite(pair.p95) && pair.p95 > largestHeldOutP95) {
            largestHeldOutP95 = pair.p95;
            largestHeldOutP95I = pair.i;
            largestHeldOutP95J = pair.j;
        }
        const bool draftPairFailed = pair.count < 8
            || pair.occupiedCells < 4
            || !std::isfinite(pair.p95)
            || pair.p95 > draftMaxSelectedPairP95;
        if (!draftPairFailed) {
            continue;
        }
        const double severity = !std::isfinite(pair.p95)
            ? std::numeric_limits<double>::infinity()
            : pair.p95
                + std::max(0, 8 - pair.count) * draftMaxSelectedPairP95
                + std::max(0, 4 - pair.occupiedCells) * draftMaxSelectedPairP95;
        if (!foundDraftFailureEdge || severity > worstDraftFailureSeverity) {
            foundDraftFailureEdge = true;
            worstDraftFailureSeverity = severity;
            report.worstSelectedEdgeI = pair.i;
            report.worstSelectedEdgeJ = pair.j;
        }
    }
    if (!foundDraftFailureEdge
        && report.optimizedRms > std::max(0.25, request.number("cameraModelMaxOptimizedRMSPx", 5.0))
        && std::isfinite(largestHeldOutP95)) {
        report.worstSelectedEdgeI = largestHeldOutP95I;
        report.worstSelectedEdgeJ = largestHeldOutP95J;
    }

    const std::string qualityFailure = native_camera_quality_failure_reason(
        cameras,
        images,
        result.controlPoints,
        report.optimizedRms,
        report.selectedPairP95,
        report.worstSelectedEdgeI,
        report.worstSelectedEdgeJ,
        initialFocal,
        starProjectionReport,
        result.astroRefinementReport,
        request
    );
    if (native_camera_candidate_is_renderable(cameras, images, initialFocal)) {
        // Preserve a finite, bounded Camera solution even when independent
        // held-out evidence rejects it. It may drive a clearly marked draft
        // projection and full-resolution recovery, but never opens export or
        // clears dirty state.
        result.cameraParams = cameras;
        result.baseCameraParams = cameras;
    } else {
        result.cameraParams.clear();
        result.baseCameraParams.clear();
    }
    if (!qualityFailure.empty()) {
        report.success = false;
        report.qualityGatePassed = false;
        report.qualityGateReason = qualityFailure;
        report.reason = qualityFailure;
        result.cameraModelReport = report;
        return;
    }

    report.success = true;
    report.qualityGatePassed = true;
    report.qualityGateReason = "camera quality gate passed";
    if (result.textureRefinementReport.accepted) {
        report.reason = optimizeDistortion
            ? "Ceres rotation/focal/distortion adjustment completed with robust filtering, guided/local star refinement, and texture SIFT refinement"
            : "Ceres rotation/focal adjustment completed with robust filtering, guided/local star refinement, and texture SIFT refinement";
    } else if (result.localRefinementReport.accepted) {
        report.reason = optimizeDistortion
            ? "Ceres rotation/focal/distortion adjustment completed with multi-round robust filtering and local star refinement"
            : "Ceres rotation/focal adjustment completed with multi-round robust filtering and local star refinement";
    } else if (guidedReport.accepted) {
        report.reason = optimizeDistortion
            ? "Ceres rotation/focal/distortion adjustment completed with multi-round robust filtering and guided star refinement"
            : "Ceres rotation/focal adjustment completed with multi-round robust filtering and guided star refinement";
    } else {
        report.reason = optimizeDistortion
            ? "Ceres rotation/focal/distortion adjustment completed with multi-round robust filtering"
            : "Ceres rotation/focal adjustment completed with multi-round robust filtering";
    }
    result.cameraParams = std::move(cameras);
    result.baseCameraParams = result.cameraParams;
#else
    report.success = false;
    report.reason = "Ceres headers are not available to this build";
#endif
    result.cameraModelReport = report;
}

static bool native_project_ray(
    const double ray[3],
    const std::string &projection,
    double &u,
    double &v
) {
    const std::string mode = lower_string(projection);
    if (mode == "equirectangular") {
        const double hyp = std::sqrt(ray[0] * ray[0] + ray[2] * ray[2]);
        u = std::atan2(ray[0], ray[2]);
        v = std::atan2(ray[1], hyp);
        return std::isfinite(u) && std::isfinite(v);
    }
    if (mode == "cylindrical") {
        const double r = std::sqrt(ray[0] * ray[0] + ray[2] * ray[2]);
        if (r <= 1e-12) {
            return false;
        }
        u = std::atan2(ray[0], ray[2]);
        v = ray[1] / r;
        return std::isfinite(u) && std::isfinite(v);
    }
    if (ray[2] <= 1e-12) {
        return false;
    }
    u = ray[0] / ray[2];
    v = ray[1] / ray[2];
    return std::isfinite(u) && std::isfinite(v);
}

static bool native_unproject_point(
    double u,
    double v,
    const std::string &projection,
    double ray[3]
) {
    const std::string mode = lower_string(projection);
    if (mode == "equirectangular") {
        const double cosLat = std::cos(v);
        ray[0] = cosLat * std::sin(u);
        ray[1] = std::sin(v);
        ray[2] = cosLat * std::cos(u);
    } else if (mode == "cylindrical") {
        ray[0] = std::sin(u);
        ray[1] = v;
        ray[2] = std::cos(u);
    } else {
        ray[0] = u;
        ray[1] = v;
        ray[2] = 1.0;
    }
    return std::isfinite(ray[0]) && std::isfinite(ray[1]) && std::isfinite(ray[2]);
}

static void native_unwrap_periodic_projection(std::vector<double> &values) {
    if (values.size() < 2) {
        return;
    }
    constexpr double period = 2.0 * M_PI;
    std::vector<double> normalized;
    normalized.reserve(values.size());
    for (double value : values) {
        double wrapped = std::fmod(value + M_PI, period);
        if (wrapped < 0.0) {
            wrapped += period;
        }
        normalized.push_back(wrapped - M_PI);
    }
    std::vector<double> sorted = normalized;
    std::sort(sorted.begin(), sorted.end());
    double largestGap = sorted.front() + period - sorted.back();
    double cut = sorted.front();
    for (size_t index = 1; index < sorted.size(); ++index) {
        const double gap = sorted[index] - sorted[index - 1];
        if (gap > largestGap) {
            largestGap = gap;
            cut = sorted[index];
        }
    }
    for (size_t index = 0; index < values.size(); ++index) {
        values[index] = normalized[index] < cut ? normalized[index] + period : normalized[index];
    }
}

static bool native_camera_projection_plan(
    const std::vector<NativeImage> &images,
    const std::vector<NativeCameraParams> &cameras,
    const std::string &projection,
    NativeOutputBoundsReport &bounds,
    double &offsetX,
    double &offsetY,
    double &projectionScale,
    std::string &failureReason
) {
    if (images.empty() || images.size() != cameras.size()) {
        failureReason = "camera projection requires matching images and camera params";
        return false;
    }

    std::vector<double> projectedU;
    std::vector<double> projectedV;
    std::vector<double> focalLengths;
    constexpr int samplesPerEdge = 128;
    projectedU.reserve(images.size() * samplesPerEdge * 4);
    projectedV.reserve(images.size() * samplesPerEdge * 4);
    focalLengths.reserve(cameras.size());

    for (size_t i = 0; i < images.size(); ++i) {
        const NativeImage &image = images[i];
        const NativeCameraParams &camera = cameras[i];
        if (image.status != "loaded" || image.width <= 0 || image.height <= 0 || camera.focalLength <= 1e-6) {
            continue;
        }
        focalLengths.push_back(camera.focalLength);
        const double maxX = static_cast<double>(std::max(0, image.width - 1));
        const double maxY = static_cast<double>(std::max(0, image.height - 1));
        for (int sampleIndex = 0; sampleIndex <= samplesPerEdge; ++sampleIndex) {
            const double t = static_cast<double>(sampleIndex) / static_cast<double>(samplesPerEdge);
            const std::array<std::array<double, 2>, 4> samples = {{
                {{maxX * t, 0.0}},
                {{maxX, maxY * t}},
                {{maxX * (1.0 - t), maxY}},
                {{0.0, maxY * (1.0 - t)}}
            }};
            for (const auto &sample : samples) {
                double rayWorld[3] = {0.0, 0.0, 0.0};
                if (!native_pixel_to_world_ray(camera, image, sample[0], sample[1], rayWorld)) {
                    continue;
                }
                double u = 0.0;
                double v = 0.0;
                if (native_project_ray(rayWorld, projection, u, v)) {
                    projectedU.push_back(u);
                    projectedV.push_back(v);
                }
            }
        }
    }

    if (projectedU.empty() || focalLengths.empty()) {
        failureReason = "camera projection produced no finite output bounds";
        return false;
    }

    const std::string projectionMode = lower_string(projection);
    if (projectionMode == "equirectangular" || projectionMode == "cylindrical") {
        native_unwrap_periodic_projection(projectedU);
    }
    const auto minMaxU = std::minmax_element(projectedU.begin(), projectedU.end());
    const auto minMaxV = std::minmax_element(projectedV.begin(), projectedV.end());
    bounds.minU = *minMaxU.first;
    bounds.maxU = *minMaxU.second;
    bounds.minV = *minMaxV.first;
    bounds.maxV = *minMaxV.second;
    if (!std::isfinite(bounds.minU) || !std::isfinite(bounds.minV)
        || !std::isfinite(bounds.maxU) || !std::isfinite(bounds.maxV)
        || bounds.maxU <= bounds.minU || bounds.maxV <= bounds.minV) {
        failureReason = "camera projection output bounds are invalid";
        return false;
    }

    const double baseScale = std::max(1.0, median_value(focalLengths));
    bounds.rawWidth = static_cast<int>(std::ceil((bounds.maxU - bounds.minU) * baseScale));
    bounds.rawHeight = static_cast<int>(std::ceil((bounds.maxV - bounds.minV) * baseScale));
    if (bounds.rawWidth <= 0 || bounds.rawHeight <= 0) {
        failureReason = "camera projection output size is invalid";
        return false;
    }

    double canvasScale = 1.0;
    const double rawPixels = static_cast<double>(bounds.rawWidth) * static_cast<double>(bounds.rawHeight);
    if (rawPixels > static_cast<double>(bounds.maxOutputPixels)) {
        canvasScale = std::min(canvasScale, std::sqrt(static_cast<double>(bounds.maxOutputPixels) / rawPixels));
    }
    const int longestSide = std::max(bounds.rawWidth, bounds.rawHeight);
    if (longestSide > bounds.maxOutputSide) {
        canvasScale = std::min(canvasScale, static_cast<double>(bounds.maxOutputSide) / static_cast<double>(longestSide));
    }
    canvasScale = std::max(1e-6, canvasScale);
    projectionScale = baseScale * canvasScale;
    bounds.scale = canvasScale;
    bounds.projectionScale = projectionScale;
    const int unpaddedWidth = std::max(1, static_cast<int>(std::ceil((bounds.maxU - bounds.minU) * projectionScale)));
    const int unpaddedHeight = std::max(1, static_cast<int>(std::ceil((bounds.maxV - bounds.minV) * projectionScale)));
    bounds.width = unpaddedWidth;
    bounds.height = unpaddedHeight;
    // Keep one neutral guard pixel on every side for interpolation without
    // biasing the content toward a corner of the canvas.
    const int guardPaddingPx = 1;
    const int paddedWidth = bounds.width + guardPaddingPx * 2;
    const int paddedHeight = bounds.height + guardPaddingPx * 2;
    const double paddedPixels = static_cast<double>(paddedWidth) * static_cast<double>(paddedHeight);
    int appliedPaddingPx = 0;
    if (paddedWidth <= bounds.maxOutputSide
        && paddedHeight <= bounds.maxOutputSide
        && paddedPixels <= static_cast<double>(bounds.maxOutputPixels)) {
        bounds.rawWidth += guardPaddingPx * 2;
        bounds.rawHeight += guardPaddingPx * 2;
        bounds.width = paddedWidth;
        bounds.height = paddedHeight;
        appliedPaddingPx = guardPaddingPx;
    }
    bounds.pixels = bounds.width * bounds.height;
    bounds.valid = true;
    offsetX = -bounds.minU * projectionScale + static_cast<double>(appliedPaddingPx);
    offsetY = -bounds.minV * projectionScale + static_cast<double>(appliedPaddingPx);
    return true;
}

static bool native_camera_fixed_canvas_plan(
    const std::vector<NativeCameraParams> &cameras,
    const NativeOutputBoundsReport &reference,
    NativeOutputBoundsReport &bounds,
    double &offsetX,
    double &offsetY,
    double &projectionScale,
    std::string &failureReason
) {
    if (cameras.empty()
        || !reference.valid
        || !std::isfinite(reference.minU)
        || !std::isfinite(reference.maxU)
        || !std::isfinite(reference.minV)
        || !std::isfinite(reference.maxV)
        || reference.maxU <= reference.minU
        || reference.maxV <= reference.minV) {
        failureReason = "fixed projection canvas has no valid committed bounds";
        return false;
    }
    std::vector<double> focalLengths;
    focalLengths.reserve(cameras.size());
    for (const NativeCameraParams &camera : cameras) {
        if (std::isfinite(camera.focalLength) && camera.focalLength > 1e-6) {
            focalLengths.push_back(camera.focalLength);
        }
    }
    if (focalLengths.empty()) {
        failureReason = "fixed projection canvas has no valid camera focal length";
        return false;
    }

    bounds = reference;
    const double spanU = reference.maxU - reference.minU;
    const double spanV = reference.maxV - reference.minV;
    const double baseScale = std::max(1.0, median_value(focalLengths));
    const int unscaledWidth = std::max(1, static_cast<int>(std::ceil(spanU * baseScale)));
    const int unscaledHeight = std::max(1, static_cast<int>(std::ceil(spanV * baseScale)));
    bounds.rawWidth = unscaledWidth;
    bounds.rawHeight = unscaledHeight;

    const int maxOutputPixels = bounds.maxOutputPixels > 0 ? bounds.maxOutputPixels : 32000000;
    const int maxOutputSide = bounds.maxOutputSide > 0 ? bounds.maxOutputSide : 9000;
    double canvasScale = 1.0;
    const double rawPixels = static_cast<double>(unscaledWidth) * static_cast<double>(unscaledHeight);
    if (rawPixels > static_cast<double>(maxOutputPixels)) {
        canvasScale = std::min(canvasScale, std::sqrt(static_cast<double>(maxOutputPixels) / rawPixels));
    }
    if (std::max(unscaledWidth, unscaledHeight) > maxOutputSide) {
        canvasScale = std::min(
            canvasScale,
            static_cast<double>(maxOutputSide) / static_cast<double>(std::max(unscaledWidth, unscaledHeight))
        );
    }
    canvasScale = std::max(1e-6, canvasScale);
    projectionScale = baseScale * canvasScale;
    bounds.scale = canvasScale;
    bounds.projectionScale = projectionScale;
    const int unpaddedWidth = std::max(1, static_cast<int>(std::ceil(spanU * projectionScale)));
    const int unpaddedHeight = std::max(1, static_cast<int>(std::ceil(spanV * projectionScale)));
    bounds.width = unpaddedWidth;
    bounds.height = unpaddedHeight;
    constexpr int leadingPaddingPx = 2;
    const int paddedWidth = unpaddedWidth + leadingPaddingPx;
    const int paddedHeight = unpaddedHeight + leadingPaddingPx;
    if (paddedWidth <= maxOutputSide
        && paddedHeight <= maxOutputSide
        && static_cast<double>(paddedWidth) * static_cast<double>(paddedHeight)
            <= static_cast<double>(maxOutputPixels)) {
        bounds.rawWidth += leadingPaddingPx;
        bounds.rawHeight += leadingPaddingPx;
        bounds.width = paddedWidth;
        bounds.height = paddedHeight;
    }
    bounds.pixels = bounds.width * bounds.height;
    bounds.valid = true;
    offsetX = -bounds.minU * projectionScale + static_cast<double>(bounds.width - unpaddedWidth);
    offsetY = -bounds.minV * projectionScale + static_cast<double>(bounds.height - unpaddedHeight);
    return true;
}

static void native_camera_build_warp_maps(
    const NativeImage &image,
    const NativeCameraParams &camera,
    const std::string &projection,
    int outWidth,
    int outHeight,
    double offsetX,
    double offsetY,
    double projectionScale,
    cv::Mat &mapX,
    cv::Mat &mapY,
    cv::Mat &mask,
    const panolume::LocalWarpImageModel *localWarp = nullptr
) {
    mapX = cv::Mat(outHeight, outWidth, CV_32FC1, cv::Scalar(-1.0f));
    mapY = cv::Mat(outHeight, outWidth, CV_32FC1, cv::Scalar(-1.0f));
    mask = cv::Mat(outHeight, outWidth, CV_32FC1, cv::Scalar(0.0f));
    if (image.width <= 0 || image.height <= 0 || camera.focalLength <= 1e-6 || projectionScale <= 1e-12) {
        return;
    }

    const double cx = native_camera_principal_x(camera, image);
    const double cy = native_camera_principal_y(camera, image);
    const std::array<double, 3> inverseRotation = {
        -camera.rotation[0],
        -camera.rotation[1],
        -camera.rotation[2]
    };
    for (int y = 0; y < outHeight; ++y) {
        float *mapXRow = mapX.ptr<float>(y);
        float *mapYRow = mapY.ptr<float>(y);
        float *maskRow = mask.ptr<float>(y);
        const double v = (static_cast<double>(y) - offsetY) / projectionScale;
        for (int x = 0; x < outWidth; ++x) {
            const double u = (static_cast<double>(x) - offsetX) / projectionScale;
            double rayWorld[3] = {0.0, 0.0, 0.0};
            if (!native_unproject_point(u, v, projection, rayWorld)) {
                continue;
            }
            double rayCamera[3] = {0.0, 0.0, 0.0};
            rotate_angle_axis_point_double(inverseRotation, rayWorld, rayCamera);
            if (rayCamera[2] <= 0.01) {
                continue;
            }
            const double xNorm = rayCamera[0] / rayCamera[2];
            const double yNorm = rayCamera[1] / rayCamera[2];
            const double r2 = xNorm * xNorm + yNorm * yNorm;
            const double r4 = r2 * r2;
            const double r6 = r4 * r2;
            const double radial = 1.0 + camera.k1 * r2 + camera.k2 * r4 + camera.k3 * r6;
            const double dx = 2.0 * camera.p1 * xNorm * yNorm + camera.p2 * (r2 + 2.0 * xNorm * xNorm);
            const double dy = camera.p1 * (r2 + 2.0 * yNorm * yNorm) + 2.0 * camera.p2 * xNorm * yNorm;
            double srcX = (xNorm * radial + dx) * camera.focalLength + cx;
            double srcY = (yNorm * radial + dy) * camera.focalLength + cy;
            if (localWarp != nullptr) {
                const cv::Point2d actual = native_local_warp_forward_pixel(
                    *localWarp, image, srcX, srcY
                );
                srcX = actual.x;
                srcY = actual.y;
            }
            if (!std::isfinite(srcX) || !std::isfinite(srcY)
                || srcX < 0.0 || srcY < 0.0
                || srcX >= static_cast<double>(image.width)
                || srcY >= static_cast<double>(image.height)) {
                continue;
            }
            mapXRow[x] = static_cast<float>(srcX);
            mapYRow[x] = static_cast<float>(srcY);
            maskRow[x] = 1.0f;
        }
    }
}

static void native_camera_build_warp_maps_strip(
    const NativeImage &image,
    const NativeCameraParams &camera,
    const std::string &projection,
    int outWidth,
    int stripY,
    int stripHeight,
    double offsetX,
    double offsetY,
    double projectionScale,
    cv::Mat &mapX,
    cv::Mat &mapY,
    cv::Mat &mask,
    const panolume::LocalWarpImageModel *localWarp = nullptr
) {
    mapX = cv::Mat(stripHeight, outWidth, CV_32FC1, cv::Scalar(-1.0f));
    mapY = cv::Mat(stripHeight, outWidth, CV_32FC1, cv::Scalar(-1.0f));
    mask = cv::Mat(stripHeight, outWidth, CV_32FC1, cv::Scalar(0.0f));
    if (image.width <= 0 || image.height <= 0 || camera.focalLength <= 1e-6 || projectionScale <= 1e-12) {
        return;
    }

    const double cx = native_camera_principal_x(camera, image);
    const double cy = native_camera_principal_y(camera, image);
    const std::array<double, 3> inverseRotation = {
        -camera.rotation[0],
        -camera.rotation[1],
        -camera.rotation[2]
    };
    for (int localY = 0; localY < stripHeight; ++localY) {
        float *mapXRow = mapX.ptr<float>(localY);
        float *mapYRow = mapY.ptr<float>(localY);
        float *maskRow = mask.ptr<float>(localY);
        const double v = (static_cast<double>(stripY + localY) - offsetY) / projectionScale;
        for (int x = 0; x < outWidth; ++x) {
            const double u = (static_cast<double>(x) - offsetX) / projectionScale;
            double rayWorld[3] = {0.0, 0.0, 0.0};
            if (!native_unproject_point(u, v, projection, rayWorld)) {
                continue;
            }
            double rayCamera[3] = {0.0, 0.0, 0.0};
            rotate_angle_axis_point_double(inverseRotation, rayWorld, rayCamera);
            if (rayCamera[2] <= 0.01) {
                continue;
            }
            const double xNorm = rayCamera[0] / rayCamera[2];
            const double yNorm = rayCamera[1] / rayCamera[2];
            double distortedX = xNorm;
            double distortedY = yNorm;
            apply_brown_conrady_distortion_double(xNorm, yNorm, camera_distortion_values(camera), distortedX, distortedY);
            double srcX = distortedX * camera.focalLength + cx;
            double srcY = distortedY * camera.focalLength + cy;
            if (localWarp != nullptr) {
                const cv::Point2d actual = native_local_warp_forward_pixel(
                    *localWarp, image, srcX, srcY
                );
                srcX = actual.x;
                srcY = actual.y;
            }
            if (!std::isfinite(srcX) || !std::isfinite(srcY)
                || srcX < 0.0 || srcY < 0.0
                || srcX >= static_cast<double>(image.width)
                || srcY >= static_cast<double>(image.height)) {
                continue;
            }
            mapXRow[x] = static_cast<float>(srcX);
            mapYRow[x] = static_cast<float>(srcY);
            maskRow[x] = 1.0f;
        }
    }
}

#endif  // MYPTGUI_HAS_OPENCV_HEADERS
