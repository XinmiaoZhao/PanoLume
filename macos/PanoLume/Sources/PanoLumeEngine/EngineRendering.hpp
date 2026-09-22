// PanoLume internal implementation module. This file is included exactly once
// by PanoLumeEngine.mm to preserve the pre-split translation-unit semantics.

#if PANOLUME_HAS_OPENCV_HEADERS
static cv::Mat native_feather_weight_from_mask(const cv::Mat &mask) {
    cv::Mat binary;
    cv::threshold(mask, binary, 0.5, 1.0, cv::THRESH_BINARY);
    cv::Mat binary8;
    binary.convertTo(binary8, CV_8U, 255.0);
    cv::Mat weight;
    cv::distanceTransform(binary8, weight, cv::DIST_L2, 5);
    if (!weight.empty()) {
        cv::GaussianBlur(weight, weight, cv::Size(0, 0), 30.0);
        weight = weight.mul(mask);
    }
    return weight;
}

static void native_store_binary_coverage(
    NativeResult &result,
    const cv::Mat &denominator
) {
    const size_t expected = result.width > 0 && result.height > 0
        ? static_cast<size_t>(result.width) * static_cast<size_t>(result.height)
        : 0;
    result.panoramaCoverage.clear();
    if (expected == 0
        || denominator.empty()
        || denominator.rows != result.height
        || denominator.cols != result.width
        || denominator.type() != CV_32FC1) {
        return;
    }
    result.panoramaCoverage.resize(expected, 0);
    for (int y = 0; y < result.height; ++y) {
        const float *row = denominator.ptr<float>(y);
        unsigned char *coverage = result.panoramaCoverage.data()
            + static_cast<size_t>(y) * static_cast<size_t>(result.width);
        for (int x = 0; x < result.width; ++x) {
            coverage[x] = std::isfinite(row[x]) && row[x] > 1e-8f ? 255 : 0;
        }
    }
}

static cv::Mat native_python_equivalent_feather_blend(
    const std::vector<cv::Mat> &images,
    const std::vector<cv::Mat> &masks,
    double featherRadius = 30.0
) {
    if (images.empty() || masks.empty() || images.size() != masks.size()) {
        return cv::Mat();
    }
    if (images.size() == 1) {
        cv::Mat valid;
        cv::threshold(masks.front(), valid, 0.5, 1.0, cv::THRESH_BINARY);
        std::vector<cv::Mat> channels(3, valid);
        cv::Mat valid3;
        cv::merge(channels, valid3);
        return images.front().mul(valid3);
    }

    const int height = images.front().rows;
    const int width = images.front().cols;
    if (height <= 0 || width <= 0) {
        return cv::Mat();
    }

    std::vector<cv::Mat> validMasks;
    std::vector<cv::Mat> distances;
    validMasks.reserve(masks.size());
    distances.reserve(masks.size());
    cv::Mat totalDistance(height, width, CV_32FC1, cv::Scalar(0.0f));
    for (const cv::Mat &mask : masks) {
        cv::Mat resizedMask = mask;
        if (mask.rows != height || mask.cols != width) {
            cv::resize(mask, resizedMask, cv::Size(width, height), 0.0, 0.0, cv::INTER_NEAREST);
        }
        cv::Mat valid;
        cv::threshold(resizedMask, valid, 0.5, 1.0, cv::THRESH_BINARY);
        cv::Mat binary8;
        valid.convertTo(binary8, CV_8U, 255.0);
        cv::Mat distance;
        cv::distanceTransform(binary8, distance, cv::DIST_L2, 5);
        validMasks.push_back(valid);
        distances.push_back(distance);
        totalDistance += distance;
    }

    cv::Mat safeTotalDistance;
    cv::max(totalDistance, 1e-8, safeTotalDistance);
    cv::Mat covered;
    cv::compare(totalDistance, 1e-8, covered, cv::CMP_GT);

    std::vector<cv::Mat> blurredMasks;
    blurredMasks.reserve(masks.size());
    cv::Mat totalBlurred(height, width, CV_32FC1, cv::Scalar(0.0f));
    for (size_t i = 0; i < distances.size(); ++i) {
        cv::Mat normalized = distances[i] / safeTotalDistance;
        normalized.setTo(0.0f, ~covered);
        if (featherRadius > 0.0) {
            cv::GaussianBlur(normalized, normalized, cv::Size(0, 0), featherRadius);
        }
        normalized = normalized.mul(validMasks[i]);
        blurredMasks.push_back(normalized);
        totalBlurred += normalized;
    }

    cv::Mat safeTotalBlurred;
    cv::max(totalBlurred, 1e-8, safeTotalBlurred);
    cv::Mat result(height, width, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
    for (size_t i = 0; i < images.size(); ++i) {
        cv::Mat image = images[i];
        if (image.rows != height || image.cols != width) {
            cv::resize(image, image, cv::Size(width, height), 0.0, 0.0, cv::INTER_LINEAR);
        }
        cv::Mat normalizedWeight = blurredMasks[i] / safeTotalBlurred;
        std::vector<cv::Mat> weightChannels(3, normalizedWeight);
        cv::Mat weight3;
        cv::merge(weightChannels, weight3);
        result += image.mul(weight3);
    }
    return result;
}

static cv::Mat native_source_ownership_blend(
    const std::vector<cv::Mat> &images,
    const std::vector<cv::Mat> &masks,
    std::string &reportJson
) {
    reportJson.clear();
    if (images.empty() || images.size() != masks.size() || images.size() > 65535) {
        return cv::Mat();
    }
    const int height = images.front().rows;
    const int width = images.front().cols;
    if (width <= 0 || height <= 0) {
        return cv::Mat();
    }
    constexpr double maximumWorkPixels = 2000000.0;
    const double scale = std::min(
        1.0,
        std::sqrt(maximumWorkPixels / (static_cast<double>(width) * static_cast<double>(height)))
    );
    const int workWidth = std::max(1, static_cast<int>(std::llround(static_cast<double>(width) * scale)));
    const int workHeight = std::max(1, static_cast<int>(std::llround(static_cast<double>(height) * scale)));

    std::vector<cv::Mat> workImages;
    std::vector<cv::Mat> workMasks;
    std::vector<cv::Mat> distances;
    workImages.reserve(images.size());
    workMasks.reserve(images.size());
    distances.reserve(images.size());
    for (size_t index = 0; index < images.size(); ++index) {
        if (images[index].empty() || masks[index].empty()) {
            return cv::Mat();
        }
        cv::Mat image;
        cv::Mat mask;
        cv::resize(images[index], image, cv::Size(workWidth, workHeight), 0.0, 0.0, cv::INTER_AREA);
        cv::resize(masks[index], mask, cv::Size(workWidth, workHeight), 0.0, 0.0, cv::INTER_NEAREST);
        cv::threshold(mask, mask, 0.5, 1.0, cv::THRESH_BINARY);
        cv::Mat binary8;
        mask.convertTo(binary8, CV_8U, 255.0);
        cv::Mat distance;
        cv::distanceTransform(binary8, distance, cv::DIST_L2, 5);
        workImages.push_back(image);
        workMasks.push_back(mask);
        distances.push_back(distance);
    }

    cv::Mat workOwner(workHeight, workWidth, CV_16UC1, cv::Scalar(0));
    std::vector<uint64_t> ownerCounts(images.size(), 0);
    uint64_t unownedPixels = 0;
    for (int y = 0; y < workHeight; ++y) {
        uint16_t *ownerRow = workOwner.ptr<uint16_t>(y);
        for (int x = 0; x < workWidth; ++x) {
            std::array<double, 3> mean = {0.0, 0.0, 0.0};
            int validCount = 0;
            double maximumDistance = 0.0;
            for (size_t source = 0; source < images.size(); ++source) {
                if (workMasks[source].at<float>(y, x) <= 0.5f) continue;
                const cv::Vec3f color = workImages[source].at<cv::Vec3f>(y, x);
                mean[0] += color[0];
                mean[1] += color[1];
                mean[2] += color[2];
                maximumDistance = std::max(maximumDistance, static_cast<double>(distances[source].at<float>(y, x)));
                validCount += 1;
            }
            if (validCount == 0) {
                unownedPixels += 1;
                continue;
            }
            mean[0] /= validCount;
            mean[1] /= validCount;
            mean[2] /= validCount;
            size_t selected = 0;
            double bestScore = -std::numeric_limits<double>::infinity();
            for (size_t source = 0; source < images.size(); ++source) {
                if (workMasks[source].at<float>(y, x) <= 0.5f) continue;
                const cv::Vec3f color = workImages[source].at<cv::Vec3f>(y, x);
                const double colorDifference = (
                    std::abs(static_cast<double>(color[0]) - mean[0])
                    + std::abs(static_cast<double>(color[1]) - mean[1])
                    + std::abs(static_cast<double>(color[2]) - mean[2])
                ) / 3.0;
                const double normalizedDistance = maximumDistance > 1e-9
                    ? static_cast<double>(distances[source].at<float>(y, x)) / maximumDistance
                    : 0.0;
                const double score = normalizedDistance - colorDifference;
                if (score > bestScore) {
                    bestScore = score;
                    selected = source;
                }
            }
            ownerRow[x] = static_cast<uint16_t>(selected + 1);
            ownerCounts[selected] += 1;
        }
    }

    cv::Mat owner;
    cv::resize(workOwner, owner, cv::Size(width, height), 0.0, 0.0, cv::INTER_NEAREST);
    cv::Mat numerator(height, width, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
    cv::Mat denominator(height, width, CV_32FC1, cv::Scalar(0.0f));
    for (size_t source = 0; source < images.size(); ++source) {
        cv::Mat selected8;
        cv::compare(owner, static_cast<int>(source + 1), selected8, cv::CMP_EQ);
        cv::Mat weight;
        selected8.convertTo(weight, CV_32FC1, 1.0 / 255.0);
        cv::GaussianBlur(weight, weight, cv::Size(0, 0), 8.0);
        weight = weight.mul(masks[source]);
        denominator += weight;
        std::vector<cv::Mat> channels(3, weight);
        cv::Mat weight3;
        cv::merge(channels, weight3);
        numerator += images[source].mul(weight3);
    }
    cv::Mat safeDenominator;
    cv::max(denominator, 1e-8, safeDenominator);
    std::vector<cv::Mat> denominatorChannels(3, safeDenominator);
    cv::Mat denominator3;
    cv::merge(denominatorChannels, denominator3);
    cv::Mat result = numerator / denominator3;

    std::ostringstream report;
    report << "{";
    report << "\"schema_version\":1,";
    report << "\"status\":\"experimental_cpu_preview\",";
    report << "\"algorithm\":\"normalized_boundary_distance_minus_overlap_mean_color_difference\",";
    report << "\"width\":" << workWidth << ",\"height\":" << workHeight << ",";
    report << "\"source_count\":" << images.size() << ",";
    report << "\"unowned_pixels\":" << unownedPixels << ",";
    report << "\"owner_counts\":[";
    for (size_t source = 0; source < ownerCounts.size(); ++source) {
        if (source) report << ",";
        report << ownerCounts[source];
    }
    report << "],\"transition_sigma_px\":8}";
    reportJson = report.str();
    return result;
}

extern "C" int panolume_source_ownership_characterization_self_test(void) {
#if PANOLUME_HAS_OPENCV_HEADERS
    std::vector<cv::Mat> images = {
        cv::Mat(24, 32, CV_32FC3, cv::Scalar(0.2f, 0.3f, 0.4f)),
        cv::Mat(24, 32, CV_32FC3, cv::Scalar(0.2f, 0.3f, 0.4f)),
    };
    std::vector<cv::Mat> masks = {
        cv::Mat(24, 32, CV_32FC1, cv::Scalar(0.0f)),
        cv::Mat(24, 32, CV_32FC1, cv::Scalar(0.0f)),
    };
    masks[0](cv::Rect(0, 0, 24, 24)).setTo(1.0f);
    masks[1](cv::Rect(8, 0, 24, 24)).setTo(1.0f);
    images[0](cv::Rect(12, 8, 5, 5)).setTo(cv::Scalar(0.9f, 0.1f, 0.1f));
    std::string report;
    const cv::Mat blended = native_source_ownership_blend(images, masks, report);
    if (blended.empty() || blended.rows != 24 || blended.cols != 32 || blended.type() != CV_32FC3) {
        return 0;
    }
    if (report.find("\"source_count\":2") == std::string::npos
        || report.find("\"unowned_pixels\":0") == std::string::npos) {
        return 0;
    }
    return cv::checkRange(blended, true, nullptr, 0.0, 1.000001) ? 1 : 0;
#else
    return 0;
#endif
}

struct NativeOverlapSeamStats {
    uint64_t overlapPixels = 0;
    double absDiffSum = 0.0;
    double maxAbsDiff = 0.0;

    double meanAbsDiff() const {
        if (overlapPixels == 0) {
            return 0.0;
        }
        return absDiffSum / static_cast<double>(overlapPixels);
    }
};

static void accumulate_overlap_seam_stats(
    const std::vector<cv::Mat> &warpedImages,
    const std::vector<cv::Mat> &masks,
    NativeOverlapSeamStats &stats
) {
    if (warpedImages.size() != masks.size() || warpedImages.size() < 2) {
        return;
    }
    for (size_t a = 0; a < warpedImages.size(); ++a) {
        for (size_t b = a + 1; b < warpedImages.size(); ++b) {
            const cv::Mat &imageA = warpedImages[a];
            const cv::Mat &imageB = warpedImages[b];
            const cv::Mat &maskA = masks[a];
            const cv::Mat &maskB = masks[b];
            if (imageA.empty() || imageB.empty() || maskA.empty() || maskB.empty()
                || imageA.rows != imageB.rows || imageA.cols != imageB.cols
                || maskA.rows != imageA.rows || maskA.cols != imageA.cols
                || maskB.rows != imageA.rows || maskB.cols != imageA.cols) {
                continue;
            }
            for (int y = 0; y < imageA.rows; ++y) {
                const float *rowA = imageA.ptr<float>(y);
                const float *rowB = imageB.ptr<float>(y);
                const float *maskRowA = maskA.ptr<float>(y);
                const float *maskRowB = maskB.ptr<float>(y);
                for (int x = 0; x < imageA.cols; ++x) {
                    if (maskRowA[x] <= 0.5f || maskRowB[x] <= 0.5f) {
                        continue;
                    }
                    const int base = x * 3;
                    const double diff = (
                        std::abs(static_cast<double>(rowA[base + 0]) - static_cast<double>(rowB[base + 0]))
                        + std::abs(static_cast<double>(rowA[base + 1]) - static_cast<double>(rowB[base + 1]))
                        + std::abs(static_cast<double>(rowA[base + 2]) - static_cast<double>(rowB[base + 2]))
                    ) / 3.0;
                    stats.absDiffSum += diff;
                    stats.maxAbsDiff = std::max(stats.maxAbsDiff, diff);
                    stats.overlapPixels += 1;
                }
            }
        }
    }
}

class NativeStreamingOverlapStatsAccumulator {
public:
    void append(
        const cv::Mat &warped,
        const cv::Mat &mask,
        NativeOverlapSeamStats &stats
    ) {
        if (warped.empty() || mask.empty() || warped.type() != CV_32FC3
            || mask.type() != CV_32FC1 || warped.size() != mask.size()) {
            return;
        }
        if (colorSum_.empty()) {
            colorSum_ = cv::Mat(warped.rows, warped.cols, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
            coverageCount_ = cv::Mat(warped.rows, warped.cols, CV_32FC1, cv::Scalar(0.0f));
        }
        for (int y = 0; y < warped.rows; ++y) {
            const float *source = warped.ptr<float>(y);
            const float *sourceMask = mask.ptr<float>(y);
            float *sum = colorSum_.ptr<float>(y);
            float *count = coverageCount_.ptr<float>(y);
            for (int x = 0; x < warped.cols; ++x) {
                if (sourceMask[x] <= 0.5f) {
                    continue;
                }
                const int base = x * 3;
                if (count[x] > 0.5f) {
                    const double inverseCount = 1.0 / static_cast<double>(count[x]);
                    const double diff = (
                        std::abs(static_cast<double>(source[base + 0]) - static_cast<double>(sum[base + 0]) * inverseCount)
                        + std::abs(static_cast<double>(source[base + 1]) - static_cast<double>(sum[base + 1]) * inverseCount)
                        + std::abs(static_cast<double>(source[base + 2]) - static_cast<double>(sum[base + 2]) * inverseCount)
                    ) / 3.0;
                    stats.absDiffSum += diff;
                    stats.maxAbsDiff = std::max(stats.maxAbsDiff, diff);
                    stats.overlapPixels += 1;
                }
                sum[base + 0] += source[base + 0];
                sum[base + 1] += source[base + 1];
                sum[base + 2] += source[base + 2];
                count[x] += 1.0f;
            }
        }
    }

private:
    cv::Mat colorSum_;
    cv::Mat coverageCount_;
};

static std::vector<cv::Mat> native_gradient_masks(const std::vector<cv::Mat> &masks) {
    std::vector<cv::Mat> distances;
    distances.reserve(masks.size());
    cv::Mat total;
    for (const cv::Mat &mask : masks) {
        cv::Mat binary;
        cv::threshold(mask, binary, 0.5, 1.0, cv::THRESH_BINARY);
        cv::Mat binary8;
        binary.convertTo(binary8, CV_8U, 255.0);
        cv::Mat distance;
        cv::distanceTransform(binary8, distance, cv::DIST_L2, 5);
        distances.push_back(distance);
        if (total.empty()) {
            total = distance.clone();
        } else {
            total += distance;
        }
    }
    std::vector<cv::Mat> weights;
    weights.reserve(masks.size());
    cv::Mat safeTotal;
    cv::max(total, 1e-8, safeTotal);
    for (size_t idx = 0; idx < masks.size(); ++idx) {
        cv::Mat weight = distances[idx] / safeTotal;
        weight = weight.mul(masks[idx]);
        weights.push_back(weight);
    }
    return weights;
}

static std::vector<cv::Mat> native_gaussian_pyramid(const cv::Mat &image, int levels) {
    std::vector<cv::Mat> pyramid;
    pyramid.reserve(static_cast<size_t>(levels + 1));
    pyramid.push_back(image.clone());
    cv::Mat current = image;
    for (int level = 0; level < levels; ++level) {
        if (current.cols <= 1 || current.rows <= 1) {
            break;
        }
        cv::Mat down;
        cv::pyrDown(current, down);
        pyramid.push_back(down);
        current = down;
    }
    return pyramid;
}

static std::vector<cv::Mat> native_laplacian_pyramid(const cv::Mat &image, int levels) {
    std::vector<cv::Mat> gaussian = native_gaussian_pyramid(image, levels);
    std::vector<cv::Mat> laplacian;
    laplacian.reserve(gaussian.size());
    for (size_t idx = 0; idx + 1 < gaussian.size(); ++idx) {
        cv::Mat up;
        cv::pyrUp(gaussian[idx + 1], up, gaussian[idx].size());
        laplacian.push_back(gaussian[idx] - up);
    }
    laplacian.push_back(gaussian.back());
    return laplacian;
}

static cv::Mat native_collapse_laplacian_pyramid(const std::vector<cv::Mat> &pyramid) {
    cv::Mat current = pyramid.back();
    for (int idx = static_cast<int>(pyramid.size()) - 2; idx >= 0; --idx) {
        cv::Mat up;
        cv::pyrUp(current, up, pyramid[static_cast<size_t>(idx)].size());
        current = up + pyramid[static_cast<size_t>(idx)];
    }
    return current;
}

static cv::Mat native_multiband_blend(
    const std::vector<cv::Mat> &images,
    const std::vector<cv::Mat> &masks,
    int requestedLevels
) {
    if (images.empty()) {
        return cv::Mat();
    }
    if (images.size() == 1) {
        std::vector<cv::Mat> channels(3, masks.front());
        cv::Mat mask3;
        cv::merge(channels, mask3);
        return images.front().mul(mask3);
    }

    std::vector<cv::Mat> validMasks;
    validMasks.reserve(masks.size());
    cv::Mat outputCoverage(masks.front().rows, masks.front().cols, CV_32FC1, cv::Scalar(0.0f));
    for (const cv::Mat &mask : masks) {
        cv::Mat valid;
        cv::threshold(mask, valid, 0.5, 1.0, cv::THRESH_BINARY);
        validMasks.push_back(valid);
        outputCoverage += valid;
    }
    cv::threshold(outputCoverage, outputCoverage, 1.0, 1.0, cv::THRESH_TRUNC);
    std::vector<cv::Mat> smoothMasks = native_gradient_masks(validMasks);

    int levels = std::max(1, requestedLevels);
    int minSide = std::min(images.front().cols, images.front().rows);
    while (levels > 1 && minSide / (1 << levels) < 16) {
        levels -= 1;
    }

    std::vector<std::vector<cv::Mat>> imagePyramids;
    std::vector<std::vector<cv::Mat>> maskPyramids;
    imagePyramids.reserve(images.size());
    maskPyramids.reserve(images.size());
    size_t pyramidLevels = 0;
    for (size_t idx = 0; idx < images.size(); ++idx) {
        imagePyramids.push_back(native_laplacian_pyramid(images[idx], levels));
        maskPyramids.push_back(native_gaussian_pyramid(smoothMasks[idx], levels));
        pyramidLevels = std::max(pyramidLevels, imagePyramids.back().size());
    }
    if (pyramidLevels == 0) {
        return cv::Mat();
    }

    std::vector<cv::Mat> blendedPyramid;
    blendedPyramid.reserve(pyramidLevels);
    for (size_t level = 0; level < pyramidLevels; ++level) {
        cv::Mat numerator;
        cv::Mat denominator;
        for (size_t idx = 0; idx < images.size(); ++idx) {
            const size_t imageLevel = std::min(level, imagePyramids[idx].size() - 1);
            const size_t maskLevel = std::min(level, maskPyramids[idx].size() - 1);
            cv::Mat weight = maskPyramids[idx][maskLevel];
            if (weight.size() != imagePyramids[idx][imageLevel].size()) {
                cv::resize(weight, weight, imagePyramids[idx][imageLevel].size(), 0.0, 0.0, cv::INTER_LINEAR);
            }
            std::vector<cv::Mat> weightChannels(3, weight);
            cv::Mat weight3;
            cv::merge(weightChannels, weight3);
            cv::Mat weighted = imagePyramids[idx][imageLevel].mul(weight3);
            if (numerator.empty()) {
                numerator = weighted.clone();
                denominator = weight.clone();
            } else {
                numerator += weighted;
                denominator += weight;
            }
        }
        cv::Mat safeDenominator;
        cv::max(denominator, 1e-8, safeDenominator);
        std::vector<cv::Mat> denominatorChannels(3, safeDenominator);
        cv::Mat denominator3;
        cv::merge(denominatorChannels, denominator3);
        blendedPyramid.push_back(numerator / denominator3);
    }
    cv::Mat result = native_collapse_laplacian_pyramid(blendedPyramid);
    if (outputCoverage.size() != result.size()) {
        cv::resize(outputCoverage, outputCoverage, result.size(), 0.0, 0.0, cv::INTER_NEAREST);
    }
    std::vector<cv::Mat> coverageChannels(3, outputCoverage);
    cv::Mat coverage3;
    cv::merge(coverageChannels, coverage3);
    return result.mul(coverage3);
}

static void set_native_camera_projection_report(
    NativeResult &result,
    bool success,
    bool primaryPreview,
    const std::string &reason
) {
    result.cameraProjectionReport.attempted = true;
    result.cameraProjectionReport.success = success;
    result.cameraProjectionReport.primaryPreview = primaryPreview;
    result.cameraProjectionReport.reason = reason;
}

static bool render_native_camera_projection_preview(
    const std::vector<NativeImage> &images,
    NativeResult &result,
    const std::string &projection,
    bool primaryPreview,
    PanoLumeProgressCallback progress,
    void *userData,
    std::string &failureReason,
    const std::atomic<unsigned long long> *invalidationVersion = nullptr,
    unsigned long long requestVersion = 0
) {
    auto invalidated = [&]() {
        return active_native_operation_cancelled()
            || (invalidationVersion != nullptr
            && requestVersion > 0
            && invalidationVersion->load() != requestVersion);
    };
    if (result.cameraParams.size() != images.size() || result.cameraParams.empty()) {
        failureReason = "optimized camera parameters are not available";
        set_native_camera_projection_report(result, false, primaryPreview, failureReason);
        return false;
    }

    NativeOutputBoundsReport bounds;
    if (result.outputBounds.maxOutputPixels > 0) {
        bounds.maxOutputPixels = result.outputBounds.maxOutputPixels;
    }
    if (result.outputBounds.maxOutputSide > 0) {
        bounds.maxOutputSide = result.outputBounds.maxOutputSide;
    }
    double offsetX = 0.0;
    double offsetY = 0.0;
    double projectionScale = 1.0;
    const bool planned = native_camera_projection_plan(
        images,
        result.cameraParams,
        projection,
        bounds,
        offsetX,
        offsetY,
        projectionScale,
        failureReason
    );
    if (!planned) {
        set_native_camera_projection_report(result, false, primaryPreview, failureReason);
        return false;
    }
    if (invalidated()) {
        failureReason = "projection preview was superseded by a newer request";
        set_native_camera_projection_report(result, false, primaryPreview, failureReason);
        return false;
    }

    const std::string blendMode = lower_string(result.blendMode);
    const bool fastBlend = blendMode == "fast";
    const bool multibandBlend = blendMode == "multiband";
    const bool sourceOwnershipBlend = blendMode == "source_ownership";
    result.sourceOwnershipJson.clear();
    const std::string requestedPreviewRenderer = lower_string(result.previewRendererRequested.empty()
        ? "auto"
        : result.previewRendererRequested);
    const bool pythonEquivalentFeatherBlend = !fastBlend
        && !multibandBlend
        && !sourceOwnershipBlend
        && images.size() <= 4
        && bounds.pixels <= 12000000;
    bool tryMetalPreview = false;
    bool metalPreviewQuality = false;
    if (requestedPreviewRenderer == "metal_quality") {
        tryMetalPreview = true;
        metalPreviewQuality = true;
    } else if (requestedPreviewRenderer == "metal_fast") {
        tryMetalPreview = true;
        metalPreviewQuality = false;
    } else if (requestedPreviewRenderer == "auto") {
        NativeMetalRuntimeStatus metalStatus = native_metal_runtime_status();
        if ((!primaryPreview || !pythonEquivalentFeatherBlend)
            && metalStatus.dylibLoaded
            && metalStatus.deviceAvailable
            && metalStatus.fastAvailable) {
            tryMetalPreview = true;
            metalPreviewQuality = primaryPreview && metalStatus.qualityAvailable;
        }
    }
    if (tryMetalPreview && lower_string(projection) != "equirectangular") {
        tryMetalPreview = false;
        result.previewRendererFallbackReason = "Metal preview currently supports equirectangular camera projection only";
    }
    if (tryMetalPreview && multibandBlend) {
        tryMetalPreview = false;
        result.previewRendererFallbackReason = "Metal preview currently supports fast/feather camera blending only";
    }
    if (tryMetalPreview && sourceOwnershipBlend) {
        tryMetalPreview = false;
        result.previewRendererFallbackReason = "Source ownership is an experimental CPU preview mode until the shared CPU/Metal contract is certified";
    }
    if (tryMetalPreview) {
        const int stripHeightLimit = primaryPreview ? 64 : 96;
        const size_t panoramaSampleCount = static_cast<size_t>(bounds.width) * static_cast<size_t>(bounds.height) * 3;
        std::vector<float> metalPanorama(panoramaSampleCount, 0.0f);
        std::vector<unsigned char> metalCoverage(
            static_cast<size_t>(bounds.width) * static_cast<size_t>(bounds.height),
            0
        );
        bool metalOK = true;
        std::string metalError;
        size_t coveredPixels = 0;
        const double progressStart = primaryPreview ? 0.965 : 0.20;
        const double progressSpan = primaryPreview ? 0.030 : 0.70;
        for (int y0 = 0; y0 < bounds.height; y0 += stripHeightLimit) {
            if (invalidated()) {
                failureReason = "projection preview was superseded by a newer request";
                set_native_camera_projection_report(result, false, primaryPreview, failureReason);
                return false;
            }
            const int stripHeight = std::min(stripHeightLimit, bounds.height - y0);
            emit_progress(
                progress,
                userData,
                "Warping Metal camera projection preview",
                progressStart + progressSpan * (static_cast<double>(y0) / std::max(bounds.height, 1))
            );
            std::vector<uint16_t> metalStrip;
            std::vector<uint8_t> metalStripCoverage;
            if (!render_camera_strip_with_metal(
                result,
                images,
                bounds,
                y0,
                stripHeight,
                offsetX,
                offsetY,
                projectionScale,
                metalPreviewQuality,
                metalStrip,
                metalStripCoverage,
                metalError
            )) {
                metalOK = false;
                break;
            }
            for (int localY = 0; localY < stripHeight; ++localY) {
                const size_t srcRow = static_cast<size_t>(localY) * static_cast<size_t>(bounds.width) * 3;
                const size_t dstRow = static_cast<size_t>(y0 + localY) * static_cast<size_t>(bounds.width) * 3;
                const size_t srcCoverageRow = static_cast<size_t>(localY) * static_cast<size_t>(bounds.width);
                const size_t dstCoverageRow = static_cast<size_t>(y0 + localY) * static_cast<size_t>(bounds.width);
                for (int x = 0; x < bounds.width * 3; ++x) {
                    const float value = static_cast<float>(
                        static_cast<double>(metalStrip[srcRow + static_cast<size_t>(x)]) / 65535.0
                    );
                    metalPanorama[dstRow + static_cast<size_t>(x)] = value;
                }
                for (int x = 0; x < bounds.width; ++x) {
                    const unsigned char value = metalStripCoverage[srcCoverageRow + static_cast<size_t>(x)];
                    metalCoverage[dstCoverageRow + static_cast<size_t>(x)] = value;
                    coveredPixels += value > 0 ? 1 : 0;
                }
            }
        }
        if (metalOK && coveredPixels > 0) {
            result.projection = projection;
            result.geometry = "camera";
            result.previewStatus = "camera_projection_preview";
            result.previewFailureReason.clear();
            set_preview_renderer_status(result, metalPreviewQuality ? "metal_quality" : "metal_fast");
            result.blendEngine = metalPreviewQuality ? "native_metal_quality" : "native_metal_fast";
            result.outputBounds = bounds;
            result.width = bounds.width;
            result.height = bounds.height;
            result.bitDepth = 0;
            result.panoramaPixels.swap(metalPanorama);
            result.panoramaCoverage.swap(metalCoverage);
            set_native_camera_projection_report(result, true, primaryPreview, "Metal camera projection preview rendered");
            return true;
        }
        if (metalOK) {
            metalError = "Metal camera projection produced no covered pixels";
        }
        result.previewRendererFallbackReason = "Metal preview render failed: " + metalError;
    }

    cv::Mat numerator(bounds.height, bounds.width, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
    cv::Mat denominator(bounds.height, bounds.width, CV_32FC1, cv::Scalar(0.0f));
    std::vector<cv::Mat> warpedImages;
    std::vector<cv::Mat> warpedMasks;
    if (multibandBlend || pythonEquivalentFeatherBlend || sourceOwnershipBlend) {
        warpedImages.reserve(images.size());
        warpedMasks.reserve(images.size());
    }
    const double progressStart = primaryPreview ? 0.965 : 0.20;
    const double progressSpan = primaryPreview ? 0.030 : 0.70;
    for (size_t i = 0; i < images.size(); ++i) {
        if (invalidated()) {
            failureReason = "projection preview was superseded by a newer request";
            set_native_camera_projection_report(result, false, primaryPreview, failureReason);
            return false;
        }
        emit_progress(
            progress,
            userData,
            "Warping camera projection preview",
            progressStart + progressSpan * (static_cast<double>(i) / std::max<size_t>(images.size(), 1))
        );
        cv::Mat mapX;
        cv::Mat mapY;
        cv::Mat mask;
        native_camera_build_warp_maps(
            images[i],
            result.cameraParams[i],
            projection,
            bounds.width,
            bounds.height,
            offsetX,
            offsetY,
            projectionScale,
            mapX,
            mapY,
            mask,
            result.localWarpModel.images.size() == images.size()
                ? &result.localWarpModel.images[i]
                : nullptr
        );
        if (invalidated()) {
            failureReason = "projection preview was superseded by a newer request";
            set_native_camera_projection_report(result, false, primaryPreview, failureReason);
            return false;
        }
        cv::Mat warped;
        cv::remap(
            image_to_rgb_mat(images[i]),
            warped,
            mapX,
            mapY,
            cv::INTER_LINEAR,
            cv::BORDER_CONSTANT,
            cv::Scalar(0.0f, 0.0f, 0.0f)
        );
        if (invalidated()) {
            failureReason = "projection preview was superseded by a newer request";
            set_native_camera_projection_report(result, false, primaryPreview, failureReason);
            return false;
        }
        if (multibandBlend || pythonEquivalentFeatherBlend || sourceOwnershipBlend) {
            warpedImages.push_back(warped);
            warpedMasks.push_back(mask);
            denominator += mask;
        } else {
            cv::Mat weight = fastBlend ? mask : native_feather_weight_from_mask(mask);
            std::vector<cv::Mat> weightChannels(3, weight);
            cv::Mat weight3;
            cv::merge(weightChannels, weight3);
            numerator += warped.mul(weight3);
            denominator += weight;
        }
    }

    const double coverage = cv::sum(denominator)[0];
    if (!std::isfinite(coverage) || coverage <= 0.0) {
        failureReason = "camera projection produced no covered pixels";
        set_native_camera_projection_report(result, false, primaryPreview, failureReason);
        return false;
    }

    cv::Mat panorama;
    if (sourceOwnershipBlend) {
        panorama = native_source_ownership_blend(warpedImages, warpedMasks, result.sourceOwnershipJson);
        result.blendEngine = "native_source_ownership_experimental_cpu";
    } else if (multibandBlend) {
        panorama = native_multiband_blend(warpedImages, warpedMasks, 5);
        result.blendEngine = "native_multiband";
    } else if (pythonEquivalentFeatherBlend) {
        panorama = native_python_equivalent_feather_blend(warpedImages, warpedMasks, 30.0);
        result.blendEngine = "native_python_equivalent_feather";
    } else {
        cv::Mat safeDenominator;
        cv::max(denominator, 1e-8, safeDenominator);
        std::vector<cv::Mat> denominatorChannels(3, safeDenominator);
        cv::Mat denominator3;
        cv::merge(denominatorChannels, denominator3);
        panorama = numerator / denominator3;
        result.blendEngine = fastBlend ? "native_fast" : "native_feather";
    }
    if (panorama.empty()) {
        failureReason = "camera projection blend produced an empty panorama";
        set_native_camera_projection_report(result, false, primaryPreview, failureReason);
        return false;
    }
    cv::min(panorama, 1.0, panorama);
    cv::max(panorama, 0.0, panorama);
    if (!panorama.isContinuous()) {
        panorama = panorama.clone();
    }

    result.projection = projection;
    result.geometry = "camera";
    result.previewStatus = "camera_projection_preview";
    result.previewFailureReason.clear();
    set_preview_renderer_status(result, "opencv_cpu_camera_projection");
    result.outputBounds = bounds;
    result.width = bounds.width;
    result.height = bounds.height;
    result.bitDepth = 0;
    const float *panoramaBegin = panorama.ptr<float>(0);
    const size_t panoramaSampleCount = static_cast<size_t>(bounds.width) * static_cast<size_t>(bounds.height) * 3;
    result.panoramaPixels.assign(panoramaBegin, panoramaBegin + panoramaSampleCount);
    native_store_binary_coverage(result, denominator);
    set_native_camera_projection_report(result, true, primaryPreview, "camera projection preview rendered");
    return true;
}

static bool rerender_native_camera_from_control_points(
    PanoLumeContext *context,
    const NativeResult &source,
    const panolume::EngineRequest &request,
    NativeResult &rerendered,
    PanoLumeProgressCallback progress,
    void *userData,
    std::string &failureReason
) {
    std::vector<NativeControlPoint> editedPoints;
    if (!parse_control_points(request, editedPoints)) {
        failureReason = "edited control points were not provided";
        return false;
    }
    if (editedPoints.empty()) {
        failureReason = "edited control point set is empty";
        return false;
    }
    const std::vector<NativeControlPoint> submittedPoints = editedPoints;
    std::vector<NativeImage> images = images_from_handles(context, source.imageHandles);
    if (images.size() != source.imageHandles.size() || images.size() < 2) {
        failureReason = "source images are unavailable for control-point rerender";
        return false;
    }
    std::vector<NativeControlPoint> validEditedPoints;
    validEditedPoints.reserve(editedPoints.size());
    for (const NativeControlPoint &point : editedPoints) {
        if (valid_edited_control_point_observation(point, images)) {
            validEditedPoints.push_back(point);
        }
    }
    rerendered = source;
    rerendered.handle = source.handle + "-rerender-" + std::to_string(context->nextResultId.fetch_add(1));
    rerendered.controlPoints = dedupe_edited_control_points(std::move(validEditedPoints), 1.5);
    rerendered.cameraParams = !source.baseCameraParams.empty() ? source.baseCameraParams : source.cameraParams;
    if (rerendered.cameraParams.size() != images.size()) {
        failureReason = "camera params are unavailable for control-point rerender";
        return false;
    }

#if PANOLUME_HAS_CERES_HEADERS
    const int minPoints = std::max(8, static_cast<int>(images.size()) * 4);
    if (static_cast<int>(rerendered.controlPoints.size()) < minPoints) {
        failureReason = "not enough edited control points for camera re-optimization";
        return false;
    }
    const bool optimizeFocal = request.boolean("optimizeFocal", true);
    const bool optimizeDistortion = request.boolean("optimizeDistortion", false);
    const int maxIterations = std::max(10, request.integer("optimizerMaxIterations", 200));
    const int maxRobustRounds = std::max(1, std::min(5, request.integer("cameraModelRobustRounds", 3)));
    const double robustThreshold = std::max(1.0, request.number("cameraModelRobustReprojectionPx", 5.0));

    NativeCameraModelReport report;
    report.attempted = true;
    report.inputControlPoints = static_cast<int>(rerendered.controlPoints.size());
    report.initialFocal = std::isfinite(source.cameraModelReport.initialFocal)
            && source.cameraModelReport.initialFocal > 0.0
        ? source.cameraModelReport.initialFocal
        : (rerendered.cameraParams.empty() ? 0.0 : rerendered.cameraParams.front().focalLength);
    report.initialDistortion = rerendered.cameraParams.empty() ? report.initialDistortion : camera_distortion_values(rerendered.cameraParams.front());
    report.initialRms = camera_rms_error(rerendered.cameraParams, images, rerendered.controlPoints);
    report.robustThreshold = robustThreshold;
    report.robustMaxRounds = maxRobustRounds;
    report.distortionOptimized = optimizeDistortion;

    emit_progress(progress, userData, "Re-optimizing edited control points", 0.12);
    std::string summary;
    if (!run_ceres_camera_adjustment(
        images,
        rerendered.controlPoints,
        optimizeFocal,
        optimizeDistortion,
        maxIterations,
        rerendered.cameraParams,
        summary,
        report.initialFocal
    )) {
        failureReason = "Ceres solver failed while re-optimizing edited control points: " + summary;
        return false;
    }

    std::vector<NativeControlPoint> workingPoints = rerendered.controlPoints;
    for (int round = 0; round < maxRobustRounds; ++round) {
        report.robustRounds = round + 1;
        apply_camera_errors_to_control_points(rerendered.cameraParams, images, workingPoints);
        std::vector<NativeControlPoint> robustPoints;
        robustPoints.reserve(workingPoints.size());
        for (const NativeControlPoint &point : workingPoints) {
            if (std::isfinite(point.error) && point.error <= robustThreshold) {
                robustPoints.push_back(point);
            }
        }
        if (static_cast<int>(robustPoints.size()) < minPoints) {
            report.robustStopReason = "filtered control point count would fall below the minimum";
            break;
        }
        if (robustPoints.size() == workingPoints.size()) {
            report.robustStopReason = "all remaining edited control points are within threshold";
            break;
        }
        std::vector<NativeCameraParams> robustCameras = rerendered.cameraParams;
        std::string robustSummary;
        if (run_ceres_camera_adjustment(
            images,
            robustPoints,
            optimizeFocal,
            optimizeDistortion,
            maxIterations,
            robustCameras,
            robustSummary,
            report.initialFocal
        )) {
            rerendered.cameraParams = std::move(robustCameras);
            workingPoints = std::move(robustPoints);
            summary = robustSummary;
            report.robustStopReason = "accepted filtered edited control points";
        } else {
            report.robustStopReason = "Ceres solver failed on filtered edited control points";
            break;
        }
    }
    if (report.robustStopReason.empty()) {
        report.robustStopReason = "reached maximum robust rounds";
    }
    rerendered.controlPoints = std::move(workingPoints);
    apply_camera_errors_to_control_points(rerendered.cameraParams, images, rerendered.controlPoints);
    report.outputControlPoints = static_cast<int>(rerendered.controlPoints.size());
    report.robustRejected = report.inputControlPoints - report.outputControlPoints;
    report.optimizedFocal = rerendered.cameraParams.empty() ? report.initialFocal : rerendered.cameraParams.front().focalLength;
    report.optimizedDistortion = rerendered.cameraParams.empty() ? report.initialDistortion : camera_distortion_values(rerendered.cameraParams.front());
    report.optimizedRms = camera_rms_error(rerendered.cameraParams, images, rerendered.controlPoints);
    report.selectedPairP95 = selected_pair_p95_error(
        rerendered.controlPoints,
        rerendered.selectedEdges,
        report.worstSelectedEdgeI,
        report.worstSelectedEdgeJ
    );
    report.solverSummary = summary;
    const NativeStarProjectionAlignmentReport unavailableStarProjection;
    const double editedStarThreshold = std::max(0.5, request.number("starThreshold", 5.0));
    std::vector<std::vector<NativeStar>> editedStarSources;
    editedStarSources.reserve(images.size());
    for (const NativeImage &image : images) {
        editedStarSources.push_back(detect_native_stars_for_request(
            image, editedStarThreshold, request
        ));
    }
    rerendered.astroRefinementReport = native_evaluate_heldout_pairs(
        rerendered.cameraParams,
        images,
        rerendered.selectedEdges,
        rerendered.projection,
        &editedStarSources
    );
    const std::string qualityFailure = native_camera_quality_failure_reason(
        rerendered.cameraParams,
        images,
        rerendered.controlPoints,
        report.optimizedRms,
        report.selectedPairP95,
        report.worstSelectedEdgeI,
        report.worstSelectedEdgeJ,
        report.initialFocal,
        unavailableStarProjection,
        rerendered.astroRefinementReport,
        request
    );
    if (!qualityFailure.empty()) {
        failureReason = qualityFailure;
        return false;
    }
    report.success = true;
    report.qualityGatePassed = true;
    report.qualityGateReason = "camera quality gate passed";
    report.reason = "control-point rerender re-optimized edited points with Ceres and robust filtering";
    rerendered.cameraModelReport = report;
    rerendered.baseCameraParams = rerendered.cameraParams;
    if (source.hasProjectionAdjustment) {
        apply_pose_adjustment_to_cameras(
            rerendered.cameraParams,
            source.projectionAdjustmentDegrees[0],
            source.projectionAdjustmentDegrees[1],
            source.projectionAdjustmentDegrees[2]
        );
    }
    rerendered.hasProjectionAdjustment = source.hasProjectionAdjustment;
    rerendered.projectionAdjustmentDegrees = source.projectionAdjustmentDegrees;
    rerendered.manualPointFilteringReport = manual_point_filtering_report(
        submittedPoints,
        rerendered.controlPoints,
        "manual control points were rejected as duplicates, invalid observations, or robust reprojection outliers"
    );

    emit_progress(progress, userData, "Rendering re-optimized preview", 0.72);
    if (!render_native_camera_projection_preview(
        images,
        rerendered,
        rerendered.projection,
        true,
        progress,
        userData,
        failureReason
    )) {
        return false;
    }
    return true;
#else
    (void)progress;
    (void)userData;
    failureReason = "Ceres headers are not available to this build";
    return false;
#endif
}

static bool rerender_native_homography_from_control_points(
    PanoLumeContext *context,
    const NativeResult &source,
    const panolume::EngineRequest &request,
    NativeResult &rerendered,
    PanoLumeProgressCallback progress,
    void *userData,
    std::string &failureReason
) {
    std::vector<NativeControlPoint> editedPoints;
    if (!parse_control_points(request, editedPoints)) {
        failureReason = "edited control points were not provided";
        return false;
    }
    if (editedPoints.empty()) {
        failureReason = "edited control point set is empty";
        return false;
    }
    const std::vector<NativeControlPoint> submittedPoints = editedPoints;
    std::vector<NativeImage> images = images_from_handles(context, source.imageHandles);
    if (images.size() != source.imageHandles.size() || images.size() < 2) {
        failureReason = "source images are unavailable for homography control-point rerender";
        return false;
    }

    using Pair = std::pair<int, int>;
    std::map<Pair, std::vector<NativeControlPoint>> groupedPoints;
    for (NativeControlPoint point : editedPoints) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= static_cast<int>(images.size())
            || point.imageBIndex >= static_cast<int>(images.size())
            || point.imageAIndex == point.imageBIndex) {
            failureReason = "edited control point references an invalid image pair";
            return false;
        }
        if (point.imageAIndex > point.imageBIndex) {
            std::swap(point.imageAIndex, point.imageBIndex);
            std::swap(point.xA, point.xB);
            std::swap(point.yA, point.yB);
        }
        const NativeImage &imageA = images[static_cast<size_t>(point.imageAIndex)];
        const NativeImage &imageB = images[static_cast<size_t>(point.imageBIndex)];
        const bool finite = std::isfinite(point.xA) && std::isfinite(point.yA)
            && std::isfinite(point.xB) && std::isfinite(point.yB);
        const bool inBounds = finite
            && point.xA >= 0.0 && point.yA >= 0.0
            && point.xB >= 0.0 && point.yB >= 0.0
            && point.xA <= static_cast<double>(std::max(0, imageA.width - 1))
            && point.yA <= static_cast<double>(std::max(0, imageA.height - 1))
            && point.xB <= static_cast<double>(std::max(0, imageB.width - 1))
            && point.yB <= static_cast<double>(std::max(0, imageB.height - 1));
        if (inBounds) {
            groupedPoints[{point.imageAIndex, point.imageBIndex}].push_back(point);
        }
    }

    const double robustThreshold = std::max(0.25, request.number("homographyReprojectionPx", 3.0));
    auto validHomography = [](const cv::Mat &homography) {
        return !homography.empty()
            && homography.rows == 3
            && homography.cols == 3
            && homography.type() == CV_64F
            && cv::checkRange(homography)
            && std::isfinite(cv::determinant(homography))
            && std::abs(cv::determinant(homography)) > 1e-12;
    };
    std::vector<NativeMatchEdge> fittedEdges;
    std::vector<NativeControlPoint> acceptedPoints;
    emit_progress(progress, userData, "Robustly refitting edited homography pairs", 0.12);
    for (auto &entry : groupedPoints) {
        std::vector<NativeControlPoint> pairPoints = dedupe_edited_control_points(std::move(entry.second), 0.25);
        if (pairPoints.size() < 4) {
            std::ostringstream reason;
            reason << "image pair " << entry.first.first << "-" << entry.first.second
                   << " has " << pairPoints.size() << " valid distinct points; at least four are required";
            failureReason = reason.str();
            return false;
        }
        std::vector<cv::Point2d> pointsA;
        std::vector<cv::Point2d> pointsB;
        pointsA.reserve(pairPoints.size());
        pointsB.reserve(pairPoints.size());
        for (const NativeControlPoint &point : pairPoints) {
            pointsA.emplace_back(point.xA, point.yA);
            pointsB.emplace_back(point.xB, point.yB);
        }
        cv::Mat inlierMask;
        cv::Mat homography = cv::findHomography(
            pointsA,
            pointsB,
            cv::RANSAC,
            robustThreshold,
            inlierMask,
            5000,
            0.995
        );
        if (homography.empty() || homography.rows != 3 || homography.cols != 3) {
            std::ostringstream reason;
            reason << "image pair " << entry.first.first << "-" << entry.first.second
                   << " could not produce a robust homography";
            failureReason = reason.str();
            return false;
        }
        homography.convertTo(homography, CV_64F);
        if (!validHomography(homography)) {
            std::ostringstream reason;
            reason << "image pair " << entry.first.first << "-" << entry.first.second
                   << " produced a non-finite or singular robust homography";
            failureReason = reason.str();
            return false;
        }

        std::vector<cv::Point2d> inlierA;
        std::vector<cv::Point2d> inlierB;
        std::vector<NativeControlPoint> robustPoints;
        for (size_t idx = 0; idx < pairPoints.size(); ++idx) {
            const bool keep = inlierMask.empty()
                || inlierMask.at<unsigned char>(static_cast<int>(idx), 0) != 0;
            if (!keep) {
                continue;
            }
            inlierA.push_back(pointsA[idx]);
            inlierB.push_back(pointsB[idx]);
            robustPoints.push_back(pairPoints[idx]);
        }
        if (robustPoints.size() < 4) {
            std::ostringstream reason;
            reason << "image pair " << entry.first.first << "-" << entry.first.second
                   << " retained only " << robustPoints.size()
                   << " points after robust filtering; at least four are required";
            failureReason = reason.str();
            return false;
        }
        cv::Mat refined = cv::findHomography(inlierA, inlierB, 0);
        if (!refined.empty() && refined.rows == 3 && refined.cols == 3) {
            cv::Mat refined64;
            refined.convertTo(refined64, CV_64F);
            if (validHomography(refined64)) {
                homography = std::move(refined64);
            }
        }

        std::vector<NativeControlPoint> finalPoints;
        double sumSquared = 0.0;
        for (NativeControlPoint point : robustPoints) {
            const NativeStar sourcePoint{point.xA, point.yA, 0.0, 1.0};
            const NativeStar targetPoint{point.xB, point.yB, 0.0, 1.0};
            point.error = reprojection_error(homography, sourcePoint, targetPoint);
            if (std::isfinite(point.error) && point.error <= robustThreshold) {
                sumSquared += point.error * point.error;
                finalPoints.push_back(point);
            }
        }
        if (finalPoints.size() < 4) {
            std::ostringstream reason;
            reason << "image pair " << entry.first.first << "-" << entry.first.second
                   << " retained only " << finalPoints.size()
                   << " points after final residual filtering; at least four are required";
            failureReason = reason.str();
            return false;
        }

        NativeMatchEdge edge;
        edge.i = entry.first.first;
        edge.j = entry.first.second;
        edge.transform = homography;
        edge.controlPoints = finalPoints;
        edge.rmsError = std::sqrt(sumSquared / static_cast<double>(finalPoints.size()));
        edge.score = static_cast<double>(finalPoints.size()) / (1.0 + edge.rmsError);
        edge.method = "homography_refit";
        edge.transformModel = "homography";
        edge.transformModelReason = "selected robust homography for edited control-point re-optimization";
        {
            std::vector<double> finalErrors;
            finalErrors.reserve(finalPoints.size());
            for (const NativeControlPoint &point : finalPoints) {
                if (std::isfinite(point.error)) {
                    finalErrors.push_back(point.error);
                }
            }
            edge.homographyP95 = finalErrors.empty()
                ? std::numeric_limits<double>::quiet_NaN()
                : percentile_value(finalErrors, 95.0);
        }
        fittedEdges.push_back(std::move(edge));
        acceptedPoints.insert(acceptedPoints.end(), finalPoints.begin(), finalPoints.end());
    }
    if (fittedEdges.empty()) {
        failureReason = "no image pair has four valid points for homography re-optimization";
        return false;
    }

    std::sort(fittedEdges.begin(), fittedEdges.end(), [](const NativeMatchEdge &lhs, const NativeMatchEdge &rhs) {
        return lhs.score > rhs.score;
    });
    const int imageCount = static_cast<int>(images.size());
    std::vector<int> parent(static_cast<size_t>(imageCount));
    std::iota(parent.begin(), parent.end(), 0);
    auto findRoot = [&parent](int value) {
        int root = value;
        while (parent[static_cast<size_t>(root)] != root) {
            parent[static_cast<size_t>(root)] = parent[static_cast<size_t>(parent[static_cast<size_t>(root)])];
            root = parent[static_cast<size_t>(root)];
        }
        return root;
    };
    std::vector<NativeMatchEdge> selected;
    std::vector<std::vector<std::pair<int, cv::Mat>>> adjacency(static_cast<size_t>(imageCount));
    for (const NativeMatchEdge &edge : fittedEdges) {
        const int rootA = findRoot(edge.i);
        const int rootB = findRoot(edge.j);
        if (rootA == rootB) {
            continue;
        }
        parent[static_cast<size_t>(rootA)] = rootB;
        adjacency[static_cast<size_t>(edge.i)].push_back({edge.j, edge.transform});
        adjacency[static_cast<size_t>(edge.j)].push_back({edge.i, edge.transform.inv()});
        selected.push_back(edge);
        if (static_cast<int>(selected.size()) == imageCount - 1) {
            break;
        }
    }
    if (static_cast<int>(selected.size()) != imageCount - 1) {
        std::ostringstream reason;
        reason << "edited control-point graph is disconnected: connected "
               << (selected.size() + 1) << " of " << imageCount << " images";
        failureReason = reason.str();
        return false;
    }

    std::vector<cv::Mat> imageToPanorama(static_cast<size_t>(imageCount));
    std::vector<bool> visited(static_cast<size_t>(imageCount), false);
    imageToPanorama[0] = cv::Mat::eye(3, 3, CV_64F);
    visited[0] = true;
    std::vector<int> queue = {0};
    for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
        const int current = queue[cursor];
        for (const auto &neighbor : adjacency[static_cast<size_t>(current)]) {
            if (visited[static_cast<size_t>(neighbor.first)]) {
                continue;
            }
            imageToPanorama[static_cast<size_t>(neighbor.first)] =
                imageToPanorama[static_cast<size_t>(current)] * neighbor.second.inv();
            visited[static_cast<size_t>(neighbor.first)] = true;
            queue.push_back(neighbor.first);
        }
    }
    if (std::find(visited.begin(), visited.end(), false) != visited.end()) {
        failureReason = "edited control-point graph is disconnected after homography reconstruction";
        return false;
    }

    std::vector<cv::Point2f> allCorners;
    for (int idx = 0; idx < imageCount; ++idx) {
        const NativeImage &image = images[static_cast<size_t>(idx)];
        const std::vector<cv::Point2f> corners = {
            {0.0f, 0.0f},
            {static_cast<float>(image.width), 0.0f},
            {static_cast<float>(image.width), static_cast<float>(image.height)},
            {0.0f, static_cast<float>(image.height)}
        };
        std::vector<cv::Point2f> transformed;
        cv::perspectiveTransform(corners, transformed, imageToPanorama[static_cast<size_t>(idx)]);
        for (const cv::Point2f &point : transformed) {
            if (!std::isfinite(point.x) || !std::isfinite(point.y)) {
                failureReason = "edited homographies produced non-finite panorama bounds";
                return false;
            }
            allCorners.push_back(point);
        }
    }
    const auto xBounds = std::minmax_element(allCorners.begin(), allCorners.end(), [](const cv::Point2f &a, const cv::Point2f &b) {
        return a.x < b.x;
    });
    const auto yBounds = std::minmax_element(allCorners.begin(), allCorners.end(), [](const cv::Point2f &a, const cv::Point2f &b) {
        return a.y < b.y;
    });
    const double minX = xBounds.first->x;
    const double maxX = xBounds.second->x;
    const double minY = yBounds.first->y;
    const double maxY = yBounds.second->y;
    const double outputSpanX = maxX - minX;
    const double outputSpanY = maxY - minY;
    if (!std::isfinite(outputSpanX) || !std::isfinite(outputSpanY)
        || outputSpanX <= 0.0 || outputSpanY <= 0.0
        || outputSpanX > static_cast<double>(std::numeric_limits<int>::max() / 2)
        || outputSpanY > static_cast<double>(std::numeric_limits<int>::max() / 2)) {
        failureReason = "edited homographies produced unsafe panorama bounds";
        return false;
    }
    int outputWidth = static_cast<int>(std::ceil(outputSpanX));
    int outputHeight = static_cast<int>(std::ceil(outputSpanY));
    if (outputWidth <= 0 || outputHeight <= 0) {
        failureReason = "edited homographies produced invalid panorama dimensions";
        return false;
    }

    rerendered = source;
    rerendered.handle = source.handle + "-rerender-" + std::to_string(context->nextResultId.fetch_add(1));
    rerendered.geometry = "homography";
    rerendered.previewStatus = "homography_preview";
    rerendered.previewFailureReason.clear();
    // Preserve the source family so a star panorama remains eligible for
    // display stretch and camera promotion after a homography graph refit.
    rerendered.alignmentFamily = source.alignmentFamily.empty()
        ? "homography"
        : source.alignmentFamily;
    rerendered.reoptimizationMethod = "edited_pair_graph_homography_refit";
    rerendered.blendMode = lower_string(request.string("blendMode", source.blendMode));
    rerendered.previewRendererRequested = lower_string(request.string("previewRendererBackend", source.previewRendererRequested));
    set_preview_renderer_status(rerendered, "opencv_cpu_homography");
    rerendered.cameraParams.clear();
    rerendered.baseCameraParams.clear();
    rerendered.cameraModelReport = NativeCameraModelReport();
    rerendered.cameraProjectionReport = NativeCameraProjectionReport();
    rerendered.selectedEdges.clear();
    for (const NativeMatchEdge &edge : selected) {
        NativeSelectedEdge selectedEdge;
        selectedEdge.i = edge.i;
        selectedEdge.j = edge.j;
        selectedEdge.score = edge.score;
        selectedEdge.method = edge.method;
        selectedEdge.transformModel = edge.transformModel;
        selectedEdge.transformModelReason = edge.transformModelReason;
        selectedEdge.homographyP95 = edge.homographyP95;
        selectedEdge.similarityP95 = edge.similarityP95;
        selectedEdge.pixelGridP95 = edge.pixelGridP95;
        selectedEdge.fitObservationCount = static_cast<int>(edge.controlPoints.size());
        rerendered.selectedEdges.push_back(selectedEdge);
    }
    rerendered.controlPoints = std::move(acceptedPoints);
    rerendered.manualPointFilteringReport = manual_point_filtering_report(
        submittedPoints,
        rerendered.controlPoints,
        "manual control points were rejected as duplicates, invalid coordinates, or homography RANSAC outliers"
    );

    rerendered.outputBounds.maxOutputPixels = std::max(
        1,
        request.integer("maxOutputPixels", source.outputBounds.maxOutputPixels > 0
            ? source.outputBounds.maxOutputPixels
            : 32000000)
    );
    rerendered.outputBounds.maxOutputSide = std::max(
        1,
        request.integer("maxOutputSide", source.outputBounds.maxOutputSide > 0
            ? source.outputBounds.maxOutputSide
            : 9000)
    );
    const int rawWidth = outputWidth;
    const int rawHeight = outputHeight;
    cv::Mat translation = (cv::Mat_<double>(3, 3) <<
        1.0, 0.0, -minX,
        0.0, 1.0, -minY,
        0.0, 0.0, 1.0
    );
    translation = scaled_translation(
        translation,
        outputWidth,
        outputHeight,
        rerendered.outputBounds.maxOutputPixels,
        rerendered.outputBounds.maxOutputSide
    );
    rerendered.outputBounds.valid = true;
    rerendered.outputBounds.rawWidth = rawWidth;
    rerendered.outputBounds.rawHeight = rawHeight;
    rerendered.outputBounds.width = outputWidth;
    rerendered.outputBounds.height = outputHeight;
    rerendered.outputBounds.pixels = outputWidth * outputHeight;
    rerendered.outputBounds.scale = rawWidth > 0
        ? static_cast<double>(outputWidth) / static_cast<double>(rawWidth)
        : 1.0;

    cv::Mat numerator(outputHeight, outputWidth, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
    cv::Mat denominator(outputHeight, outputWidth, CV_32FC1, cv::Scalar(0.0f));
    const bool multiband = rerendered.blendMode == "multiband";
    std::vector<cv::Mat> warpedImages;
    std::vector<cv::Mat> warpedMasks;
    if (multiband) {
        warpedImages.reserve(images.size());
        warpedMasks.reserve(images.size());
    }
    emit_progress(progress, userData, "Rendering re-optimized homography preview", 0.65);
    for (int idx = 0; idx < imageCount; ++idx) {
        if (active_native_operation_cancelled()) {
            failureReason = "homography control-point rerender was cancelled";
            return false;
        }
        const cv::Mat finalTransform = translation * imageToPanorama[static_cast<size_t>(idx)];
        cv::Mat warped;
        cv::warpPerspective(
            image_to_rgb_mat(images[static_cast<size_t>(idx)]),
            warped,
            finalTransform,
            cv::Size(outputWidth, outputHeight),
            cv::INTER_LINEAR,
            cv::BORDER_CONSTANT,
            cv::Scalar(0.0f, 0.0f, 0.0f)
        );
        cv::Mat sourceMask(
            images[static_cast<size_t>(idx)].height,
            images[static_cast<size_t>(idx)].width,
            CV_32FC1,
            cv::Scalar(1.0f)
        );
        cv::Mat mask;
        cv::warpPerspective(
            sourceMask,
            mask,
            finalTransform,
            cv::Size(outputWidth, outputHeight),
            cv::INTER_NEAREST,
            cv::BORDER_CONSTANT,
            cv::Scalar(0.0f)
        );
        if (multiband) {
            warpedImages.push_back(warped);
            warpedMasks.push_back(mask);
            denominator += mask;
            continue;
        }
        cv::Mat weight = rerendered.blendMode == "fast" ? mask : native_feather_weight_from_mask(mask);
        std::vector<cv::Mat> weightChannels(3, weight);
        cv::Mat weight3;
        cv::merge(weightChannels, weight3);
        numerator += warped.mul(weight3);
        denominator += weight;
    }

    cv::Mat panorama;
    if (multiband) {
        panorama = native_multiband_blend(warpedImages, warpedMasks, 5);
        rerendered.blendEngine = "native_multiband";
    } else {
        cv::Mat safeDenominator;
        cv::max(denominator, 1e-8, safeDenominator);
        std::vector<cv::Mat> denominatorChannels(3, safeDenominator);
        cv::Mat denominator3;
        cv::merge(denominatorChannels, denominator3);
        panorama = numerator / denominator3;
        rerendered.blendEngine = rerendered.blendMode == "fast" ? "native_fast" : "native_feather";
    }
    if (panorama.empty()) {
        failureReason = "re-optimized homography blend produced an empty panorama";
        return false;
    }
    cv::min(panorama, 1.0, panorama);
    cv::max(panorama, 0.0, panorama);
    if (!panorama.isContinuous()) {
        panorama = panorama.clone();
    }
    rerendered.width = outputWidth;
    rerendered.height = outputHeight;
    rerendered.bitDepth = 0;
    const float *pixels = panorama.ptr<float>(0);
    rerendered.panoramaPixels.assign(
        pixels,
        pixels + static_cast<size_t>(outputWidth) * static_cast<size_t>(outputHeight) * 3
    );
    native_store_binary_coverage(rerendered, denominator);
    // The copied source cache belongs to different pixels. A re-optimized
    // panorama must establish a fresh stretch; projection drag has a separate
    // path that intentionally inherits the committed cache.
    rerendered.displayStretchCache = NativeDisplayStretchCache();

    const std::string requestedGeometry = lower_string(request.string("astroGeometry", "auto"));
    const bool starSource = lower_string(source.alignmentFamily) == "stars";
    const bool shouldPromoteCamera = requestedGeometry == "camera"
        || (requestedGeometry == "auto" && starSource);
    if (shouldPromoteCamera) {
        const double starThreshold = std::max(0.5, request.number("starThreshold", 5.0));
        std::vector<std::vector<NativeStar>> starSources;
        starSources.reserve(images.size());
        rerendered.starCounts.clear();
        for (const NativeImage &image : images) {
            std::vector<NativeStar> stars = detect_native_stars_for_request(image, starThreshold, request);
            rerendered.starCounts.push_back(static_cast<int>(stars.size()));
            starSources.push_back(std::move(stars));
        }
        NativeStarSettings starSettings = native_star_settings_from_request(request);
        for (NativeSelectedEdge &selectedEdge : rerendered.selectedEdges) {
            NativeMatchEdge validationEdge;
            bool recoveryAttempted = false;
            const bool independentlyValidated = compute_star_pair_edge(
                    selectedEdge.i,
                    selectedEdge.j,
                    starSources[static_cast<size_t>(selectedEdge.i)],
                    starSources[static_cast<size_t>(selectedEdge.j)],
                    starSettings,
                    validationEdge,
                    &recoveryAttempted
                );
            if (!independentlyValidated) {
                // Star identities belong to the source observation, not to a
                // later camera fit. Keep the already-reserved automatic
                // validation/final partitions frozen while manual points are
                // refit into the training graph. A fresh all-pairs matcher can
                // be less stable at a narrow overlap and must not silently
                // replace or discard that independent source evidence. The
                // subsequent full-resolution refinement still redetects PSFs,
                // freezes new identities, and evaluates its final partition.
                const auto frozen = std::find_if(
                    source.selectedEdges.begin(),
                    source.selectedEdges.end(),
                    [&](const NativeSelectedEdge &candidate) {
                        return candidate.i == selectedEdge.i && candidate.j == selectedEdge.j;
                    }
                );
                if (frozen == source.selectedEdges.end()
                    || frozen->validationControlPoints.empty()
                    || frozen->heldOutControlPoints.size() < 4
                    || frozen->heldOutOccupiedCells < 2) {
                    std::ostringstream reason;
                    reason << "edited pair " << selectedEdge.i << "-" << selectedEdge.j
                           << " lacks independent spatially distributed star validation"
                           << " and has no complete frozen source partition";
                    failureReason = reason.str();
                    rerendered.geometryGatePassed = false;
                    rerendered.geometryGateReason = failureReason;
                    return false;
                }
                // This partition only carries the edited draft into the
                // full-resolution refiner. It may use the sparse working-size
                // minimum, but can never clear dirty or open export: the
                // subsequent PSF refit still requires the strict production
                // validation/final-held-out counts and output-space gates.
                selectedEdge.method = "stars_manual_graph_frozen_identity_validation";
                selectedEdge.validationControlPoints = frozen->validationControlPoints;
                selectedEdge.heldOutControlPoints = frozen->heldOutControlPoints;
                selectedEdge.heldOutOccupiedCells = frozen->heldOutOccupiedCells;
                selectedEdge.heldOutP95 = frozen->heldOutP95;
                selectedEdge.coverageBBoxAreaA = frozen->coverageBBoxAreaA;
                selectedEdge.coverageBBoxAreaB = frozen->coverageBBoxAreaB;
                selectedEdge.coverageGridOccupancyA = frozen->coverageGridOccupancyA;
                selectedEdge.coverageGridOccupancyB = frozen->coverageGridOccupancyB;
                selectedEdge.identityCandidates = frozen->identityCandidates;
                selectedEdge.identityAccepted = frozen->identityAccepted;
                selectedEdge.identityRejectedDescriptor = frozen->identityRejectedDescriptor;
                selectedEdge.identityRejectedPatch = frozen->identityRejectedPatch;
                selectedEdge.identityRejectedFWHM = frozen->identityRejectedFWHM;
                selectedEdge.identityRejectedFlux = frozen->identityRejectedFlux;
                selectedEdge.identityRejectedRatio = frozen->identityRejectedRatio;
                selectedEdge.identityRejectedConflict = frozen->identityRejectedConflict;
                selectedEdge.identityRejectedPrediction = frozen->identityRejectedPrediction;
                selectedEdge.identityRejectedBoundary = frozen->identityRejectedBoundary;
                selectedEdge.identityRejectedField = frozen->identityRejectedField;
                selectedEdge.identityFieldCutoff = frozen->identityFieldCutoff;
                selectedEdge.identityFieldMedian = frozen->identityFieldMedian;
                selectedEdge.identityFieldP95 = frozen->identityFieldP95;
                continue;
            }
            selectedEdge.method = recoveryAttempted
                ? "stars_manual_graph_triangle_validation"
                : "stars_manual_graph_validation";
            selectedEdge.validationControlPoints = std::move(validationEdge.validationControlPoints);
            selectedEdge.heldOutControlPoints = std::move(validationEdge.heldOutControlPoints);
            selectedEdge.heldOutOccupiedCells = validationEdge.heldOutOccupiedCells;
            selectedEdge.heldOutP95 = validationEdge.heldOutP95;
            selectedEdge.coverageBBoxAreaA = validationEdge.coverageBBoxAreaA;
            selectedEdge.coverageBBoxAreaB = validationEdge.coverageBBoxAreaB;
            selectedEdge.coverageGridOccupancyA = validationEdge.coverageGridOccupancyA;
            selectedEdge.coverageGridOccupancyB = validationEdge.coverageGridOccupancyB;
        }
        emit_progress(progress, userData, "Promoting edited star graph to camera geometry", 0.86);
        try_native_camera_model(rerendered, images, imageToPanorama, starSources, request);
        if (rerendered.cameraParams.size() != images.size() || rerendered.cameraParams.empty()) {
            failureReason = "edited star graph did not pass camera re-optimization: "
                + (rerendered.cameraModelReport.reason.empty()
                    ? std::string("unknown camera failure")
                    : rerendered.cameraModelReport.reason);
            rerendered.geometryGatePassed = false;
            rerendered.geometryGateReason = failureReason;
            return false;
        }
        std::string cameraRenderFailure;
        if (!render_native_camera_projection_preview(
            images,
            rerendered,
            rerendered.projection,
            true,
            progress,
            userData,
            cameraRenderFailure
        )) {
            failureReason = "edited camera graph could not render: " + cameraRenderFailure;
            rerendered.geometryGatePassed = false;
            rerendered.geometryGateReason = failureReason;
            return false;
        }
        rerendered.reoptimizationMethod = "edited_pair_graph_camera_promotion";
        rerendered.projectionGeometryState = "unverified_camera_draft";
        rerendered.previewStatus = rerendered.cameraModelReport.success
            ? "draft_camera_preview"
            : "unverified_camera_draft";
        if (!rerendered.cameraModelReport.success) {
            rerendered.previewFailureReason = "Unverified Camera draft — " + rerendered.cameraModelReport.reason;
        }
        rerendered.astroRefinementReport.state = "draft_pending_full_resolution";
        rerendered.astroRefinementReport.qualityGatePassed = false;
        rerendered.astroRefinementReport.reason = rerendered.cameraModelReport.success
            ? "edited draft passed preview held-out validation; full-resolution refinement is pending"
            : "edited Camera draft is renderable but preview held-out validation failed; full-resolution recovery is pending";
        rerendered.geometryGatePassed = false;
        rerendered.geometryGateReason = rerendered.cameraModelReport.success
            ? "edited camera draft is awaiting full-resolution held-out validation"
            : rerendered.cameraModelReport.reason;
    } else {
        rerendered.geometryGatePassed = true;
        rerendered.geometryGateReason = "edited homography graph passed";
    }
    return true;
}

static NativeResult homography_preview_result(
    PanoLumeContext *context,
    const std::vector<NativeImage> &images,
    const std::string &projection,
    const panolume::EngineRequest &request,
    PanoLumeProgressCallback progress,
    void *userData
) {
    NativeResult result;
    result.handle = "native-result-" + std::to_string(context->nextResultId.fetch_add(1));
    result.projection = projection;
    result.geometry = "homography";
    result.previewStatus = "failed";
    result.blendMode = lower_string(request.string("blendMode", "feather"));
    result.previewRendererRequested = lower_string(request.string("previewRendererBackend", "auto"));
    result.astroSkyMode = lower_string(request.string("astroSkyMode", "auto_sky"));
    set_preview_renderer_status(result, "opencv_cpu_homography");
    result.outputBounds.maxOutputPixels = std::max(1, request.integer("maxOutputPixels", 32000000));
    result.outputBounds.maxOutputSide = std::max(1, request.integer("maxOutputSide", 9000));
    for (const NativeImage &image : images) {
        result.paths.push_back(image.path);
        result.imageHandles.push_back(image.handle);
    }

    const int n = static_cast<int>(images.size());
    if (n < 2) {
        result.previewFailureReason = "homography preview requires at least two images";
        return result;
    }
    for (const NativeImage &image : images) {
        if (image.status != "loaded" || image.width <= 0 || image.height <= 0 || image.pixels.empty()) {
            result.previewFailureReason = "all images must load before homography preview";
            return result;
        }
    }

    std::vector<NativeMatchEdge> edges;
    const std::string alignmentMode = lower_string(request.string("alignmentMode", "auto"));
    const bool allowStars = alignmentMode != "sift";
    const bool requireStars = alignmentMode == "stars";
    const bool allowSift = alignmentMode != "stars";
    const std::string astroGeometry = lower_string(request.string("astroGeometry", "auto"));
    std::vector<std::vector<NativeStar>> starSources;
    bool attemptedStars = false;
    bool skippedStarsForAuto = false;

    if (allowStars) {
        NativeStarSettings starSettings = native_star_settings_from_request(request);
        const double starThreshold = std::max(0.5, request.number("starThreshold", 5.0));

        emit_progress(progress, userData, "Detecting stars", 0.82);
        starSources.reserve(images.size());
        result.starCounts.clear();
        bool enoughStars = true;
        for (const NativeImage &image : images) {
            std::vector<NativeStar> stars = detect_native_stars_for_request(image, starThreshold, request);
            result.starCounts.push_back(static_cast<int>(stars.size()));
            enoughStars = enoughStars && static_cast<int>(stars.size()) >= starSettings.minInliers;
            starSources.push_back(std::move(stars));
        }

        bool darkStarField = enoughStars;
        if (alignmentMode == "auto") {
            for (const NativeImage &image : images) {
                cv::Mat gray = image_to_gray32(image);
                std::vector<double> luminance;
                luminance.reserve(static_cast<size_t>(gray.rows) * static_cast<size_t>(gray.cols) / 8);
                for (int y = 0; y < gray.rows; y += 2) {
                    const float *row = gray.ptr<float>(y);
                    for (int x = 0; x < gray.cols; x += 2) {
                        luminance.push_back(static_cast<double>(row[x]));
                    }
                }
                const double medianLuma = median_value(luminance);
                if (medianLuma > 0.35) {
                    darkStarField = false;
                    break;
                }
            }
            skippedStarsForAuto = !darkStarField;
        }

        if (requireStars || darkStarField) {
            attemptedStars = true;
            emit_progress(progress, userData, "Matching star fields", 0.86);
            for (int i = 0; i < n; ++i) {
                for (int j = i + 1; j < n; ++j) {
                    NativeMatchEdge edge;
                    bool recoveryAttempted = false;
                    bool accepted = compute_star_pair_edge(
                        i,
                        j,
                        starSources[static_cast<size_t>(i)],
                        starSources[static_cast<size_t>(j)],
                        starSettings,
                        edge,
                        &recoveryAttempted,
                        false,
                        nullptr,
                        true
                    );
                    if (!accepted && j == i + 1) {
                        std::string siftRecoveryDiagnostic;
                        accepted = compute_star_pair_edge_from_sift_seed(
                            i,
                            j,
                            images[static_cast<size_t>(i)],
                            images[static_cast<size_t>(j)],
                            starSources[static_cast<size_t>(i)],
                            starSources[static_cast<size_t>(j)],
                            starSettings,
                            edge,
                            siftRecoveryDiagnostic
                        );
                        result.starRecoveryDiagnostics.push_back(std::move(siftRecoveryDiagnostic));
                        recoveryAttempted = true;
                    }
                    if (accepted) {
                        if (recoveryAttempted) {
                            result.starRecoveryAccepted += 1;
                        }
                        edges.push_back(std::move(edge));
                    }
                    if (recoveryAttempted) {
                        result.starRecoveryAttempts += 1;
                    }
                }
            }
        }
        if (requireStars && edges.empty()) {
            result.previewFailureReason = "no reliable star-asterism edges were found";
            return result;
        }
    }

    if ((edges.empty() || (alignmentMode == "auto" && native_connected_count(edges, n) < n)) && allowSift) {
        emit_progress(progress, userData, "Detecting SIFT features", 0.82);
        std::vector<NativeFeatureSet> features;
        features.reserve(images.size());
        for (const NativeImage &image : images) {
            features.push_back(detect_native_sift_features(image));
        }

        emit_progress(progress, userData, "Matching SIFT features", 0.86);
        for (int i = 0; i < n; ++i) {
            for (int j = i + 1; j < n; ++j) {
                NativeMatchEdge edge;
                if (compute_pair_edge(i, j, features[static_cast<size_t>(i)], features[static_cast<size_t>(j)], edge)) {
                    edges.push_back(std::move(edge));
                }
            }
        }
    }
    if (alignmentMode == "auto" && skippedStarsForAuto && !attemptedStars && native_connected_count(edges, n) < n && !starSources.empty()) {
        emit_progress(progress, userData, "Retrying star fields from the SIFT coarse seed", 0.89);
        for (int i = 0; i < n; ++i) {
            for (int j = i + 1; j < n; ++j) {
                NativeMatchEdge edge;
                NativeStarSettings starSettings = native_star_settings_from_request(request);
                bool recoveryAttempted = false;
                if (compute_star_pair_edge(
                    i,
                    j,
                    starSources[static_cast<size_t>(i)],
                    starSources[static_cast<size_t>(j)],
                    starSettings,
                    edge,
                    &recoveryAttempted,
                    false,
                    nullptr,
                    true
                )) {
                    if (recoveryAttempted) {
                        result.starRecoveryAccepted += 1;
                    }
                    edges.push_back(std::move(edge));
                }
                if (recoveryAttempted) {
                    result.starRecoveryAttempts += 1;
                }
            }
        }
    }
    if (edges.empty()) {
        result.previewFailureReason = "no reliable star or SIFT homography edges were found";
        return result;
    }

    std::vector<NativeMatchEdge> selected;
    std::vector<cv::Mat> imageToPanorama;
    const std::set<std::pair<int, int>> noRejectedEdges;
    if (!native_build_spanning_tree(edges, n, noRejectedEdges, selected, imageToPanorama)) {
        result.previewFailureReason = "image set is not fully connected by SIFT homographies";
        return result;
    }

    std::vector<cv::Point2f> allCorners;
    for (int i = 0; i < n; ++i) {
        std::vector<cv::Point2f> corners = {
            {0.0f, 0.0f},
            {static_cast<float>(images[static_cast<size_t>(i)].width), 0.0f},
            {static_cast<float>(images[static_cast<size_t>(i)].width), static_cast<float>(images[static_cast<size_t>(i)].height)},
            {0.0f, static_cast<float>(images[static_cast<size_t>(i)].height)}
        };
        std::vector<cv::Point2f> transformed;
        cv::perspectiveTransform(corners, transformed, imageToPanorama[static_cast<size_t>(i)]);
        allCorners.insert(allCorners.end(), transformed.begin(), transformed.end());
    }
    double minX = allCorners[0].x;
    double minY = allCorners[0].y;
    double maxX = allCorners[0].x;
    double maxY = allCorners[0].y;
    for (const cv::Point2f &point : allCorners) {
        minX = std::min(minX, static_cast<double>(point.x));
        minY = std::min(minY, static_cast<double>(point.y));
        maxX = std::max(maxX, static_cast<double>(point.x));
        maxY = std::max(maxY, static_cast<double>(point.y));
    }
    int outWidth = static_cast<int>(std::ceil(maxX - minX));
    int outHeight = static_cast<int>(std::ceil(maxY - minY));
    if (outWidth <= 0 || outHeight <= 0 || !std::isfinite(minX) || !std::isfinite(minY)) {
        result.previewFailureReason = "invalid homography output bounds";
        return result;
    }

    cv::Mat T = (cv::Mat_<double>(3, 3) << 1.0, 0.0, -minX, 0.0, 1.0, -minY, 0.0, 0.0, 1.0);
    T = scaled_translation(T, outWidth, outHeight, result.outputBounds.maxOutputPixels, result.outputBounds.maxOutputSide);
    cv::Mat numerator(outHeight, outWidth, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
    cv::Mat denominator(outHeight, outWidth, CV_32FC1, cv::Scalar(0.0f));
    const bool homographyMultibandBlend = result.blendMode == "multiband";
    std::vector<cv::Mat> homographyWarpedImages;
    std::vector<cv::Mat> homographyWarpedMasks;
    if (homographyMultibandBlend) {
        homographyWarpedImages.reserve(static_cast<size_t>(n));
        homographyWarpedMasks.reserve(static_cast<size_t>(n));
    }

    emit_progress(progress, userData, "Warping homography preview", 0.92);
    for (int i = 0; i < n; ++i) {
        cv::Mat HFinal = T * imageToPanorama[static_cast<size_t>(i)];
        cv::Mat warped;
        cv::warpPerspective(
            image_to_rgb_mat(images[static_cast<size_t>(i)]),
            warped,
            HFinal,
            cv::Size(outWidth, outHeight),
            cv::INTER_LINEAR,
            cv::BORDER_CONSTANT,
            cv::Scalar(0.0f, 0.0f, 0.0f)
        );
        cv::Mat sourceMask(images[static_cast<size_t>(i)].height, images[static_cast<size_t>(i)].width, CV_32FC1, cv::Scalar(1.0f));
        cv::Mat mask;
        cv::warpPerspective(
            sourceMask,
            mask,
            HFinal,
            cv::Size(outWidth, outHeight),
            cv::INTER_NEAREST,
            cv::BORDER_CONSTANT,
            cv::Scalar(0.0f)
        );
        if (homographyMultibandBlend) {
            homographyWarpedImages.push_back(warped);
            homographyWarpedMasks.push_back(mask);
            denominator += mask;
            continue;
        }
        cv::Mat weight = mask;
        if (result.blendMode == "feather") {
            cv::Mat binary;
            cv::threshold(mask, binary, 0.5, 1.0, cv::THRESH_BINARY);
            cv::Mat binary8;
            binary.convertTo(binary8, CV_8U, 255.0);
            cv::distanceTransform(binary8, weight, cv::DIST_L2, 5);
            if (!weight.empty()) {
                cv::GaussianBlur(weight, weight, cv::Size(0, 0), 30.0);
                weight = weight.mul(mask);
            }
        }
        std::vector<cv::Mat> weightChannels(3, weight);
        cv::Mat weight3;
        cv::merge(weightChannels, weight3);
        numerator += warped.mul(weight3);
        denominator += weight;
    }
    cv::Mat panorama;
    if (homographyMultibandBlend) {
        panorama = native_multiband_blend(homographyWarpedImages, homographyWarpedMasks, 5);
        result.blendEngine = "native_multiband";
    } else {
        cv::Mat safeDenominator;
        cv::max(denominator, 1e-8, safeDenominator);
        std::vector<cv::Mat> denomChannels(3, safeDenominator);
        cv::Mat denom3;
        cv::merge(denomChannels, denom3);
        panorama = numerator / denom3;
        result.blendEngine = result.blendMode == "fast" ? "native_fast" : "native_feather";
    }
    if (panorama.empty()) {
        result.previewFailureReason = "homography blend produced an empty panorama";
        return result;
    }
    cv::min(panorama, 1.0, panorama);
    cv::max(panorama, 0.0, panorama);
    if (!panorama.isContinuous()) {
        panorama = panorama.clone();
    }

    result.width = outWidth;
    result.height = outHeight;
    result.bitDepth = 0;
    result.previewStatus = "homography_preview";
    const float *panoramaBegin = panorama.ptr<float>(0);
    const size_t panoramaSampleCount = static_cast<size_t>(outWidth) * static_cast<size_t>(outHeight) * 3;
    result.panoramaPixels.assign(panoramaBegin, panoramaBegin + panoramaSampleCount);
    native_store_binary_coverage(result, denominator);
    native_apply_selected_edges(result, selected);
    const bool selectedOnlyStars = !result.selectedEdges.empty()
        && std::all_of(result.selectedEdges.begin(), result.selectedEdges.end(), [](const NativeSelectedEdge &edge) {
            return lower_string(edge.method).rfind("stars", 0) == 0;
        });
    const bool selectedOnlySIFT = !result.selectedEdges.empty()
        && std::all_of(result.selectedEdges.begin(), result.selectedEdges.end(), [](const NativeSelectedEdge &edge) {
            return lower_string(edge.method) == "sift";
        });
    result.alignmentFamily = selectedOnlyStars
        ? "stars"
        : (selectedOnlySIFT ? "sift" : "mixed");
    const bool explicitCamera = astroGeometry == "camera";
    const bool automaticStarCamera = astroGeometry == "auto" && selectedOnlyStars;
    const bool shouldAttemptCamera = explicitCamera || automaticStarCamera;
    if (shouldAttemptCamera) {
        emit_progress(progress, userData, "Optimizing camera model", 0.96);
        std::vector<NativeMatchEdge> cameraCandidateEdges;
        cameraCandidateEdges.reserve(edges.size());
        for (const NativeMatchEdge &edge : edges) {
            const bool verifiedStarEdge = lower_string(edge.method).rfind("stars", 0) == 0;
            if (!automaticStarCamera || verifiedStarEdge) {
                cameraCandidateEdges.push_back(edge);
            }
        }

        std::set<std::pair<int, int>> rejectedEdges;
        std::set<std::pair<int, int>> forcedRecoveryEdges;
        constexpr int maxCameraTreeRetries = 4;
        result.cameraTreeAttempts.clear();
        for (int treeAttempt = 0; treeAttempt <= maxCameraTreeRetries; ++treeAttempt) {
            native_apply_selected_edges(result, selected);
            result.cameraParams.clear();
            result.baseCameraParams.clear();
            result.cameraModelReport = NativeCameraModelReport();
            result.cameraProjectionReport = NativeCameraProjectionReport();
            result.guidedRefinementReport = NativeGuidedRefinementReport();
            result.localRefinementReport = NativeLocalRefinementReport();
            result.textureRefinementReport = NativeTextureRefinementReport();
            result.manualPointFilteringReport = NativeManualPointFilteringReport();
            result.starProjectionAlignmentReport = NativeStarProjectionAlignmentReport();
            result.starProjectionAlignmentJson.clear();
            result.rejectedCameraEdges.assign(rejectedEdges.begin(), rejectedEdges.end());

            try_native_camera_model(result, images, imageToPanorama, starSources, request);
            NativeCameraTreeAttemptReport treeReport;
            treeReport.attempt = treeAttempt + 1;
            treeReport.success = result.cameraModelReport.success;
            treeReport.optimizedRms = result.cameraModelReport.optimizedRms;
            treeReport.selectedPairP95 = result.cameraModelReport.selectedPairP95;
            treeReport.worstEdgeI = result.cameraModelReport.worstSelectedEdgeI;
            treeReport.worstEdgeJ = result.cameraModelReport.worstSelectedEdgeJ;
            treeReport.reason = result.cameraModelReport.reason;
            for (const NativeMatchEdge &edge : selected) {
                treeReport.selectedEdges.push_back(native_edge_key(edge.i, edge.j));
            }
            result.cameraTreeAttempts.push_back(std::move(treeReport));
            if (result.cameraModelReport.success) {
                if (!rejectedEdges.empty()) {
                    result.reoptimizationMethod = "camera_tree_rebuilt_after_quality_rejection";
                }
                break;
            }

            const int rejectedI = result.cameraModelReport.worstSelectedEdgeI;
            const int rejectedJ = result.cameraModelReport.worstSelectedEdgeJ;
            const bool selectedEdgeFailure = rejectedI >= 0
                && rejectedJ >= 0
                && (result.cameraModelReport.qualityGateReason.find("selected edge ") != std::string::npos
                    || std::any_of(
                        result.astroRefinementReport.pairs.begin(),
                        result.astroRefinementReport.pairs.end(),
                        [rejectedI, rejectedJ](const NativeHeldOutPairReport &pair) {
                            return !pair.passed
                                && native_edge_key(pair.i, pair.j) == native_edge_key(rejectedI, rejectedJ);
                        }
                    ));
            if (treeAttempt >= maxCameraTreeRetries
                || !selectedEdgeFailure
                || rejectedI < 0
                || rejectedJ < 0) {
                break;
            }
            const std::pair<int, int> rejectedKey = native_edge_key(rejectedI, rejectedJ);
            if (std::abs(rejectedI - rejectedJ) == 1
                && forcedRecoveryEdges.insert(rejectedKey).second) {
                NativeMatchEdge recoveredEdge;
                bool recoveryAttempted = false;
                const NativeStarSettings recoverySettings = native_star_settings_from_request(request);
                bool recovered = compute_star_pair_edge(
                        rejectedI,
                        rejectedJ,
                        starSources[static_cast<size_t>(rejectedI)],
                        starSources[static_cast<size_t>(rejectedJ)],
                        recoverySettings,
                        recoveredEdge,
                        &recoveryAttempted,
                        true,
                        nullptr,
                        true
                    );
                std::ostringstream recoveryDiagnostic;
                recoveryDiagnostic << "edge " << rejectedI << "-" << rejectedJ
                    << ": triangle_vote=" << (recovered ? "accepted" : "failed");
                if (!recovered) {
                    // SIFT is used only to seed correspondence search. Every
                    // point entering the edge and Camera optimizer below is a
                    // freshly re-identified star centroid with independent
                    // train/held-out partitioning.
                    const NativeFeatureSet siftA = detect_native_texture_sift_features(
                        images[static_cast<size_t>(rejectedI)]
                    );
                    const NativeFeatureSet siftB = detect_native_texture_sift_features(
                        images[static_cast<size_t>(rejectedJ)]
                    );
                    NativeMatchEdge siftSeed;
                    const bool siftSeeded = compute_pair_edge(rejectedI, rejectedJ, siftA, siftB, siftSeed);
                    recoveryDiagnostic << ", sift_features=" << siftA.keypoints.size()
                        << "/" << siftB.keypoints.size()
                        << ", sift_seed=" << (siftSeeded ? "accepted" : "failed");
                    if (siftSeeded) {
                        const NativeStarMatch seededStars = match_native_stars_from_sift_seed(
                            starSources[static_cast<size_t>(rejectedI)],
                            starSources[static_cast<size_t>(rejectedJ)],
                            siftSeed.transform,
                            recoverySettings
                        );
                        recoveryDiagnostic << ", mutual_seeded_stars=" << seededStars.pointsA.size()
                            << " (" << seededStars.reason << ")";
                        if (seededStars.success) {
                            recovered = compute_star_pair_edge(
                                rejectedI,
                                rejectedJ,
                                starSources[static_cast<size_t>(rejectedI)],
                                starSources[static_cast<size_t>(rejectedJ)],
                                recoverySettings,
                                recoveredEdge,
                                &recoveryAttempted,
                                false,
                                &seededStars,
                                true
                            );
                            if (recovered) {
                                recoveredEdge.method = "stars_sift_seeded_recovery";
                            }
                        }
                    }
                }
                recoveryDiagnostic << ", final=" << (recovered ? "accepted" : "failed");
                result.starRecoveryDiagnostics.push_back(recoveryDiagnostic.str());
                if (recovered) {
                    cameraCandidateEdges.erase(
                        std::remove_if(
                            cameraCandidateEdges.begin(),
                            cameraCandidateEdges.end(),
                            [rejectedKey](const NativeMatchEdge &candidate) {
                                return native_edge_key(candidate.i, candidate.j) == rejectedKey;
                            }
                        ),
                        cameraCandidateEdges.end()
                    );
                    cameraCandidateEdges.push_back(std::move(recoveredEdge));
                    std::vector<NativeMatchEdge> recoveredTree;
                    std::vector<cv::Mat> recoveredTransforms;
                    if (native_build_spanning_tree(
                            cameraCandidateEdges,
                            n,
                            rejectedEdges,
                            recoveredTree,
                            recoveredTransforms
                        )) {
                        selected = std::move(recoveredTree);
                        imageToPanorama = std::move(recoveredTransforms);
                        result.starRecoveryAttempts += 1;
                        result.starRecoveryAccepted += 1;
                        continue;
                    }
                }
                if (recoveryAttempted) {
                    result.starRecoveryAttempts += 1;
                }
            }
            if (!rejectedEdges.insert(rejectedKey).second) {
                break;
            }
            result.rejectedCameraEdges.assign(rejectedEdges.begin(), rejectedEdges.end());

            std::vector<NativeMatchEdge> replacementTree;
            std::vector<cv::Mat> replacementTransforms;
            if (!native_build_spanning_tree(
                    cameraCandidateEdges,
                    n,
                    rejectedEdges,
                    replacementTree,
                    replacementTransforms
                )) {
                break;
            }
            selected = std::move(replacementTree);
            imageToPanorama = std::move(replacementTransforms);
        }
    }
    if (shouldAttemptCamera && result.cameraParams.size() == images.size() && !result.cameraParams.empty()) {
        std::string cameraRenderFailure;
        const bool renderedCamera = render_native_camera_projection_preview(
            images,
            result,
            projection,
            true,
            progress,
            userData,
            cameraRenderFailure
        );
        result.geometryGatePassed = false;
        result.geometryGateReason = renderedCamera
            ? (result.cameraModelReport.success
                ? "draft camera geometry rendered; full-resolution held-out refinement is pending"
                : result.cameraModelReport.reason)
            : "camera projection failed: " + cameraRenderFailure;
        if (renderedCamera) {
            result.projectionGeometryState = "unverified_camera_draft";
            result.previewStatus = result.cameraModelReport.success
                ? "draft_camera_preview"
                : "unverified_camera_draft";
            result.previewFailureReason = result.cameraModelReport.success
                ? ""
                : "Unverified Camera draft — " + result.cameraModelReport.reason;
            result.astroRefinementReport.state = "draft_pending_full_resolution";
            result.astroRefinementReport.qualityGatePassed = false;
            result.astroRefinementReport.reason = result.cameraModelReport.success
                ? "draft held-out gate passed; full-resolution refinement is pending"
                : "draft Camera is renderable but did not pass working-resolution held-out validation; full-resolution identity recovery is pending";
        }
    } else if (explicitCamera) {
        result.geometry = "camera";
        result.previewStatus = "camera_model_failed";
        result.previewFailureReason = "forced camera geometry failed: "
            + (result.cameraModelReport.reason.empty() ? std::string("unknown failure") : result.cameraModelReport.reason);
        result.geometryGatePassed = false;
        result.geometryGateReason = result.previewFailureReason;
    } else if (automaticStarCamera) {
        // Keep the homography pixels and control points available for diagnosis
        // and manual repair, but do not call a failed automatic star panorama a
        // successful stitch.
        result.geometryGatePassed = false;
        result.geometryGateReason = "automatic star panorama did not pass camera geometry: "
            + (result.cameraModelReport.reason.empty() ? std::string("unknown failure") : result.cameraModelReport.reason);
        result.previewFailureReason = result.geometryGateReason;
    } else {
        result.geometryGatePassed = !result.selectedEdges.empty();
        result.geometryGateReason = result.geometryGatePassed
            ? "explicit or general-photo homography geometry passed"
            : "homography graph is unavailable";
    }
    return result;
}
#endif

static std::string image_filename_key(const NativeImage &image) {
    const std::string &path = image.path;
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

static int natural_compare_ascii(const std::string &lhs, const std::string &rhs) {
    size_t i = 0;
    size_t j = 0;
    while (i < lhs.size() && j < rhs.size()) {
        const unsigned char a = static_cast<unsigned char>(lhs[i]);
        const unsigned char b = static_cast<unsigned char>(rhs[j]);
        if (std::isdigit(a) && std::isdigit(b)) {
            size_t iEnd = i;
            size_t jEnd = j;
            while (iEnd < lhs.size() && std::isdigit(static_cast<unsigned char>(lhs[iEnd]))) {
                ++iEnd;
            }
            while (jEnd < rhs.size() && std::isdigit(static_cast<unsigned char>(rhs[jEnd]))) {
                ++jEnd;
            }
            size_t iSig = i;
            size_t jSig = j;
            while (iSig + 1 < iEnd && lhs[iSig] == '0') {
                ++iSig;
            }
            while (jSig + 1 < jEnd && rhs[jSig] == '0') {
                ++jSig;
            }
            const size_t iDigits = iEnd - iSig;
            const size_t jDigits = jEnd - jSig;
            if (iDigits != jDigits) {
                return iDigits < jDigits ? -1 : 1;
            }
            for (size_t k = 0; k < iDigits; ++k) {
                if (lhs[iSig + k] != rhs[jSig + k]) {
                    return lhs[iSig + k] < rhs[jSig + k] ? -1 : 1;
                }
            }
            const size_t iRun = iEnd - i;
            const size_t jRun = jEnd - j;
            if (iRun != jRun) {
                return iRun < jRun ? -1 : 1;
            }
            i = iEnd;
            j = jEnd;
            continue;
        }
        const char ca = static_cast<char>(std::tolower(a));
        const char cb = static_cast<char>(std::tolower(b));
        if (ca != cb) {
            return ca < cb ? -1 : 1;
        }
        ++i;
        ++j;
    }
    if (i == lhs.size() && j == rhs.size()) {
        return 0;
    }
    return i == lhs.size() ? -1 : 1;
}

static bool same_image_handle_sequence(
    const std::vector<NativeImage> &lhs,
    const std::vector<NativeImage> &rhs
) {
    if (lhs.size() != rhs.size()) {
        return false;
    }
    for (size_t idx = 0; idx < lhs.size(); ++idx) {
        if (lhs[idx].handle != rhs[idx].handle) {
            return false;
        }
    }
    return true;
}

static bool all_images_have_capture_datetime(const std::vector<NativeImage> &images) {
    if (images.empty()) {
        return false;
    }
    for (const NativeImage &image : images) {
        if (image.captureDateTimeOriginal.empty()) {
            return false;
        }
    }
    return true;
}

static std::vector<NativeImage> canonical_images_for_alignment(
    const std::vector<NativeImage> &images,
    std::string &source,
    bool &changed
) {
    std::vector<NativeImage> ordered = images;
    if (all_images_have_capture_datetime(images)) {
        source = "exif_datetime_original";
        std::stable_sort(ordered.begin(), ordered.end(), [](const NativeImage &lhs, const NativeImage &rhs) {
            if (lhs.captureDateTimeOriginal != rhs.captureDateTimeOriginal) {
                return lhs.captureDateTimeOriginal < rhs.captureDateTimeOriginal;
            }
            return natural_compare_ascii(image_filename_key(lhs), image_filename_key(rhs)) < 0;
        });
    } else {
        source = "natural_filename";
        std::stable_sort(ordered.begin(), ordered.end(), [](const NativeImage &lhs, const NativeImage &rhs) {
            return natural_compare_ascii(image_filename_key(lhs), image_filename_key(rhs)) < 0;
        });
    }
    changed = !same_image_handle_sequence(images, ordered);
    if (!changed && source == "natural_filename") {
        bool allNamesEmpty = true;
        for (const NativeImage &image : images) {
            if (!image_filename_key(image).empty()) {
                allNamesEmpty = false;
                break;
            }
        }
        if (allNamesEmpty) {
            source = "import_order";
        }
    }
    return ordered;
}

static std::string input_order_canonical_json(
    const std::vector<NativeImage> &original,
    const std::vector<NativeImage> &canonical,
    const std::string &source,
    bool changed
) {
    std::ostringstream out;
    out << "{";
    out << "\"strategy\":\"canonical_order\",";
    out << "\"source\":\"" << json_escape(source) << "\",";
    out << "\"changed_from_import_order\":" << bool_json(changed) << ",";
    out << "\"import_paths\":[";
    for (size_t idx = 0; idx < original.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "\"" << json_escape(original[idx].path) << "\"";
    }
    out << "],";
    out << "\"canonical_paths\":[";
    for (size_t idx = 0; idx < canonical.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "\"" << json_escape(canonical[idx].path) << "\"";
    }
    out << "],";
    out << "\"capture_datetimes\":[";
    for (size_t idx = 0; idx < canonical.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "\"" << json_escape(canonical[idx].captureDateTimeOriginal) << "\"";
    }
    out << "]";
    out << "}";
    return out.str();
}

static bool camera_candidate_passed(const NativeResult &result) {
    return (result.previewStatus == "camera_projection_preview"
            || result.previewStatus == "draft_camera_preview")
        && result.cameraModelReport.success
        && result.cameraParams.size() == result.imageHandles.size()
        && !result.cameraParams.empty();
}

static double camera_candidate_score(const NativeResult &result) {
    if (!camera_candidate_passed(result)) {
        return std::numeric_limits<double>::infinity();
    }
    const NativeResidualSummary &high = result.starProjectionAlignmentReport.highConfidence;
    const NativeResidualSummary &mutual = result.starProjectionAlignmentReport.mutual;
    if (high.count > 0 && std::isfinite(high.p95)) {
        return high.p95;
    }
    if (mutual.count > 0 && std::isfinite(mutual.p95)) {
        return mutual.p95;
    }
    return result.cameraModelReport.selectedPairP95;
}

static bool camera_candidate_quality_clearly_good(const NativeResult &result) {
    const double score = camera_candidate_score(result);
    if (!std::isfinite(score)) {
        return false;
    }
    // The visible-star gate is 4 px for high-confidence matches. Scores close
    // to that gate are accepted but still weak enough to justify trying an
    // alternate internal order.
    return score <= 3.0;
}

static std::string input_order_candidate_json(
    const std::string &label,
    const NativeResult &result,
    bool selected
) {
    std::ostringstream out;
    out << "{";
    out << "\"label\":\"" << json_escape(label) << "\",";
    out << "\"selected\":" << bool_json(selected) << ",";
    out << "\"passed\":" << bool_json(camera_candidate_passed(result)) << ",";
    out << "\"geometry\":\"" << json_escape(result.geometry) << "\",";
    out << "\"preview_status\":\"" << json_escape(result.previewStatus) << "\",";
    out << "\"camera_success\":" << bool_json(result.cameraModelReport.success) << ",";
    out << "\"camera_rms\":" << number_json(result.cameraModelReport.optimizedRms) << ",";
    out << "\"selected_pair_p95\":" << number_json(result.cameraModelReport.selectedPairP95) << ",";
    out << "\"high_confidence_count\":" << result.starProjectionAlignmentReport.highConfidence.count << ",";
    out << "\"high_confidence_p95\":" << number_json(result.starProjectionAlignmentReport.highConfidence.p95) << ",";
    out << "\"mutual_count\":" << result.starProjectionAlignmentReport.mutual.count << ",";
    out << "\"mutual_p95\":" << number_json(result.starProjectionAlignmentReport.mutual.p95) << ",";
    out << "\"reason\":\"" << json_escape(result.cameraModelReport.reason.empty() ? result.previewFailureReason : result.cameraModelReport.reason) << "\",";
    out << "\"paths\":[";
    for (size_t idx = 0; idx < result.paths.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "\"" << json_escape(result.paths[idx]) << "\"";
    }
    out << "]";
    out << "}";
    return out.str();
}

static std::string input_order_candidates_json(
    const std::vector<std::pair<std::string, NativeResult>> &candidates,
    const std::string &selectedLabel
) {
    std::ostringstream out;
    out << "[";
    for (size_t idx = 0; idx < candidates.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << input_order_candidate_json(candidates[idx].first, candidates[idx].second, candidates[idx].first == selectedLabel);
    }
    out << "]";
    return out.str();
}

static NativeResult native_preview_result(
    PanoLumeContext *context,
    const std::vector<NativeImage> &images,
    const std::string &projection,
    const panolume::EngineRequest &request,
    PanoLumeProgressCallback progress,
    void *userData
) {
#if PANOLUME_HAS_OPENCV_HEADERS
    if (dependency_available("opencv")) {
        std::string canonicalSource;
        bool changedFromImportOrder = false;
        std::vector<NativeImage> canonicalImages = canonical_images_for_alignment(
            images,
            canonicalSource,
            changedFromImportOrder
        );
        emit_progress(progress, userData, "Rendering canonical-order preview", 0.905);
        NativeResult result = homography_preview_result(context, canonicalImages, projection, request, progress, userData);
        result.inputOrderUsed = "canonical_" + canonicalSource;
        result.inputOrderAutoCorrected = changedFromImportOrder;
        result.inputOrderCanonicalJson = input_order_canonical_json(
            images,
            canonicalImages,
            canonicalSource,
            changedFromImportOrder
        );
        result.inputOrderCandidatesJson = input_order_candidates_json({{result.inputOrderUsed, result}}, result.inputOrderUsed);
        if (result.previewStatus == "homography_preview"
            || result.previewStatus == "camera_projection_preview"
            || result.previewStatus == "draft_camera_preview"
            || result.previewStatus == "unverified_camera_draft"
            || result.previewStatus == "camera_model_failed") {
            return result;
        }
        NativeResult fallback = contact_sheet_result(context, canonicalImages, projection);
        fallback.previewFailureReason = result.previewFailureReason;
        fallback.geometryGatePassed = false;
        fallback.geometryGateReason = result.previewFailureReason.empty()
            ? "alignment did not produce a connected preview graph"
            : result.previewFailureReason;
        fallback.astroSkyMode = result.astroSkyMode;
        fallback.starCounts = std::move(result.starCounts);
        fallback.starRecoveryAttempts = result.starRecoveryAttempts;
        fallback.starRecoveryAccepted = result.starRecoveryAccepted;
        fallback.starRecoveryDiagnostics = std::move(result.starRecoveryDiagnostics);
        fallback.inputOrderUsed = result.inputOrderUsed;
        fallback.inputOrderAutoCorrected = result.inputOrderAutoCorrected;
        fallback.inputOrderCanonicalJson = std::move(result.inputOrderCanonicalJson);
        fallback.inputOrderCandidatesJson = std::move(result.inputOrderCandidatesJson);
        return fallback;
    }
#else
    (void)request;
    (void)progress;
    (void)userData;
#endif
    return contact_sheet_result(context, images, projection);
}
