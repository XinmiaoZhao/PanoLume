// PanoLume internal implementation module. This file is included exactly once
// by PanoLumeEngine.mm to preserve the pre-split translation-unit semantics.

#if PANOLUME_HAS_OPENCV_HEADERS
struct NativeFeatureSet {
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
};

struct NativeMatchEdge {
    int i = 0;
    int j = 0;
    double score = 0.0;
    double rmsError = 0.0;
    cv::Mat transform;
    std::vector<NativeControlPoint> controlPoints;
    std::string method = "sift";
    std::string transformModel = "homography";
    std::string transformModelReason;
    double homographyP95 = std::numeric_limits<double>::quiet_NaN();
    double similarityP95 = std::numeric_limits<double>::quiet_NaN();
    double pixelGridP95 = std::numeric_limits<double>::quiet_NaN();
    bool adaptiveCoverageAttempted = false;
    bool adaptiveCoverageAccepted = false;
    int adaptiveCoverageInliers = 0;
    std::string adaptiveCoverageRejectReason;
    double coverageBBoxAreaA = 0.0;
    double coverageBBoxAreaB = 0.0;
    double coverageGridOccupancyA = 0.0;
    double coverageGridOccupancyB = 0.0;
    double adaptiveBBoxAreaA = 0.0;
    double adaptiveBBoxAreaB = 0.0;
    double adaptiveGridOccupancyA = 0.0;
    double adaptiveGridOccupancyB = 0.0;
    std::vector<NativeControlPoint> validationControlPoints;
    std::vector<NativeControlPoint> heldOutControlPoints;
    int heldOutOccupiedCells = 0;
    double heldOutP95 = std::numeric_limits<double>::quiet_NaN();
    int identityCandidates = 0;
    int identityAccepted = 0;
    int identityRejectedDescriptor = 0;
    int identityRejectedPatch = 0;
    int identityRejectedFWHM = 0;
    int identityRejectedFlux = 0;
    int identityRejectedRatio = 0;
    int identityRejectedConflict = 0;
    int identityRejectedPrediction = 0;
    int identityRejectedBoundary = 0;
    int identityRejectedField = 0;
    double identityFieldCutoff = std::numeric_limits<double>::quiet_NaN();
    double identityFieldMedian = std::numeric_limits<double>::quiet_NaN();
    double identityFieldP95 = std::numeric_limits<double>::quiet_NaN();
};

struct NativeStar {
    double x = 0.0;
    double y = 0.0;
    double flux = 0.0;
    double sigma = 1.5;
    double covarianceXX = 2.25;
    double covarianceXY = 0.0;
    double covarianceYY = 2.25;
    double psfSignalToNoise = 0.0;
    double psfNormalizedRMS = 0.0;
};

static void native_copy_psf_to_control_point(
    NativeControlPoint &point,
    const NativeStar &source,
    const NativeStar &target
) {
    point.sourceFWHM = source.sigma * 2.354820045;
    point.targetFWHM = target.sigma * 2.354820045;
    point.sourceCovarianceXX = source.covarianceXX;
    point.sourceCovarianceXY = source.covarianceXY;
    point.sourceCovarianceYY = source.covarianceYY;
    point.targetCovarianceXX = target.covarianceXX;
    point.targetCovarianceXY = target.covarianceXY;
    point.targetCovarianceYY = target.covarianceYY;
    point.sourcePSFSignalToNoise = source.psfSignalToNoise;
    point.targetPSFSignalToNoise = target.psfSignalToNoise;
    point.sourcePSFNormalizedRMS = source.psfNormalizedRMS;
    point.targetPSFNormalizedRMS = target.psfNormalizedRMS;
}

struct NativeStarSettings {
    int maxStars = 350;
    int spatialGridSize = 4;
    double coverageMultiplier = 2.0;
    bool adaptiveCoverage = true;
    double adaptiveCoverageMultiplier = 6.0;
    double adaptiveMinBBoxArea = 0.12;
    double adaptiveMinGridOccupancy = 0.30;
    int nearestNeighbors = 8;
    double triangleRatioTolerance = 0.035;
    double minTriangleScaleRatio = 0.72;
    double maxTriangleScaleRatio = 1.38;
    double pixelTolerance = 5.0;
    int minInliers = 8;
    int maxTriangleCandidates = 4000;
    int candidatesPerTriangle = 4;
    std::string transformModel = "similarity";
};

static NativeStarSettings native_star_settings_from_request(
    const panolume::EngineRequest &request
) {
    NativeStarSettings settings;
    settings.maxStars = std::max(8, request.integer("maxMatchStars", 350));
    settings.pixelTolerance = std::max(1.0, request.number("matchPixelTolerance", 5.0));
    settings.transformModel = lower_string(request.string("starTransformModel", "similarity"));
    settings.coverageMultiplier = std::max(1.0, request.number("starCoverageMultiplier", 2.0));
    settings.adaptiveCoverage = request.boolean("starAdaptiveCoverage", true);
    settings.adaptiveCoverageMultiplier = std::max(
        1.0,
        request.number("starAdaptiveCoverageMultiplier", 6.0)
    );
    settings.adaptiveMinBBoxArea = std::max(
        0.0,
        request.number("starAdaptiveMinBBoxArea", 0.12)
    );
    settings.adaptiveMinGridOccupancy = std::max(
        0.0,
        request.number("starAdaptiveMinGridOccupancy", 0.30)
    );
    return settings;
}

struct NativeTriangleDescriptor {
    double ratioA = 0.0;
    double ratioB = 0.0;
    double scale = 0.0;
    std::array<int, 3> vertices = {0, 0, 0};
    bool clockwise = false;
};

struct NativeStarMatch {
    bool success = false;
    std::string reason;
    cv::Mat affine;
    std::vector<NativeStar> pointsA;
    std::vector<NativeStar> pointsB;
    std::vector<double> errors;
    int hypothesisStarsA = 0;
    int hypothesisStarsB = 0;
    int trianglesA = 0;
    int trianglesB = 0;
    int triangleCandidates = 0;
    int hypothesisInliers = 0;
    int coverageStarsA = 0;
    int coverageStarsB = 0;
    int coverageInliers = 0;
    bool adaptiveCoverageAttempted = false;
    bool adaptiveCoverageAccepted = false;
    int adaptiveCoverageInliers = 0;
    std::string adaptiveCoverageRejectReason;
    double coverageBBoxAreaA = 0.0;
    double coverageBBoxAreaB = 0.0;
    double coverageGridOccupancyA = 0.0;
    double coverageGridOccupancyB = 0.0;
    double adaptiveBBoxAreaA = 0.0;
    double adaptiveBBoxAreaB = 0.0;
    double adaptiveGridOccupancyA = 0.0;
    double adaptiveGridOccupancyB = 0.0;
    int identityCandidates = 0;
    int identityAccepted = 0;
    int identityRejectedDescriptor = 0;
    int identityRejectedPatch = 0;
    int identityRejectedFWHM = 0;
    int identityRejectedFlux = 0;
    int identityRejectedRatio = 0;
    int identityRejectedConflict = 0;
    int identityRejectedPrediction = 0;
    int identityRejectedBoundary = 0;
    int identityRejectedField = 0;
    double identityFieldCutoff = std::numeric_limits<double>::quiet_NaN();
    double identityFieldMedian = std::numeric_limits<double>::quiet_NaN();
    double identityFieldP95 = std::numeric_limits<double>::quiet_NaN();
};

static cv::Mat image_to_rgb_mat(const NativeImage &image) {
    cv::Mat mat(image.height, image.width, CV_32FC3);
    if (!image.pixels.empty()) {
        std::memcpy(
            mat.data,
            image.pixels.data(),
            image.pixels.size() * sizeof(float)
        );
    }
    return mat;
}

// Preserve the 16-bit source while OpenCV remaps an export strip.  Converting
// to float only after remap avoids allocating a full-resolution float32 RGB
// frame merely to render a small output strip.
static cv::Mat image_to_rgb_remap_mat(const NativeImage &image) {
    if (image.native16Pixels && image.width > 0 && image.height > 0 && image.channels == 3) {
        return cv::Mat(
            image.height,
            image.width,
            CV_16UC3,
            const_cast<uint16_t *>(image.native16Pixels)
        );
    }
    if (!image.pixels.empty()) {
        return image_to_rgb_mat(image);
    }
    return cv::Mat();
}

static cv::Mat image_to_gray32(const NativeImage &image) {
    cv::Mat rgb32 = image_to_rgb_mat(image);
    cv::Mat gray;
    cv::cvtColor(rgb32, gray, cv::COLOR_RGB2GRAY);
    return gray;
}

static cv::Mat image_to_gray8(const NativeImage &image) {
    cv::Mat rgb32 = image_to_rgb_mat(image);
    cv::Mat rgb8;
    rgb32.convertTo(rgb8, CV_8UC3, 255.0);
    cv::Mat gray;
    cv::cvtColor(rgb8, gray, cv::COLOR_RGB2GRAY);
    return gray;
}

static NativeFeatureSet detect_native_sift_features(const NativeImage &image) {
    NativeFeatureSet features;
    if (image.status != "loaded" || image.width <= 0 || image.height <= 0 || image.pixels.empty()) {
        return features;
    }
    cv::Mat gray = image_to_gray8(image);
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create(5000);
    sift->detectAndCompute(gray, cv::noArray(), features.keypoints, features.descriptors);
    if (features.descriptors.empty()) {
        features.descriptors = cv::Mat(0, 128, CV_32F);
    } else if (features.descriptors.type() != CV_32F) {
        features.descriptors.convertTo(features.descriptors, CV_32F);
    }
    return features;
}

static double median_value(std::vector<double> values) {
    if (values.empty()) {
        return 0.0;
    }
    const size_t middle = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + static_cast<long>(middle), values.end());
    double med = values[middle];
    if (values.size() % 2 == 0) {
        std::nth_element(values.begin(), values.begin() + static_cast<long>(middle - 1), values.end());
        med = 0.5 * (med + values[middle - 1]);
    }
    return med;
}

static double percentile_value(std::vector<double> values, double percentile) {
    if (values.empty()) {
        return 0.0;
    }
    std::sort(values.begin(), values.end());
    const double clipped = std::min(100.0, std::max(0.0, percentile));
    const double position = (static_cast<double>(values.size()) - 1.0) * clipped / 100.0;
    const size_t lower = static_cast<size_t>(std::floor(position));
    const size_t upper = static_cast<size_t>(std::ceil(position));
    if (lower == upper) {
        return values[lower];
    }
    const double alpha = position - static_cast<double>(lower);
    return values[lower] * (1.0 - alpha) + values[upper] * alpha;
}

static double standard_deviation(const std::vector<double> &values) {
    if (values.empty()) {
        return 0.0;
    }
    double sum = 0.0;
    for (double value : values) {
        sum += value;
    }
    const double mean = sum / static_cast<double>(values.size());
    double sumSquared = 0.0;
    for (double value : values) {
        const double delta = value - mean;
        sumSquared += delta * delta;
    }
    return std::sqrt(sumSquared / static_cast<double>(values.size()));
}

static NativeFeatureSet detect_native_texture_sift_features(const NativeImage &image) {
    NativeFeatureSet features;
    if (image.status != "loaded" || image.width <= 0 || image.height <= 0 || image.pixels.empty()) {
        return features;
    }
    cv::Mat gray = image_to_gray32(image);
    std::vector<double> samples;
    samples.reserve(static_cast<size_t>(gray.rows) * static_cast<size_t>(gray.cols) / 4);
    for (int y = 0; y < gray.rows; y += 2) {
        const float *row = gray.ptr<float>(y);
        for (int x = 0; x < gray.cols; x += 2) {
            const double value = static_cast<double>(row[x]);
            if (std::isfinite(value) && value > 0.0) {
                samples.push_back(value);
            }
        }
    }
    if (samples.empty()) {
        return detect_native_sift_features(image);
    }
    const double black = percentile_value(samples, 0.5);
    const double white = std::max(percentile_value(samples, 99.7), black + 1e-6);
    cv::Mat stretched(gray.rows, gray.cols, CV_8UC1);
    for (int y = 0; y < gray.rows; ++y) {
        const float *src = gray.ptr<float>(y);
        unsigned char *dst = stretched.ptr<unsigned char>(y);
        for (int x = 0; x < gray.cols; ++x) {
            double normalized = (static_cast<double>(src[x]) - black) / (white - black);
            normalized = std::min(1.0, std::max(0.0, normalized));
            normalized = std::pow(normalized, 0.45);
            dst[x] = static_cast<unsigned char>(std::llround(normalized * 255.0));
        }
    }
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create(8000);
    sift->detectAndCompute(stretched, cv::noArray(), features.keypoints, features.descriptors);
    if (features.descriptors.empty()) {
        features.descriptors = cv::Mat(0, 128, CV_32F);
    } else if (features.descriptors.type() != CV_32F) {
        features.descriptors.convertTo(features.descriptors, CV_32F);
    }
    return features;
}

static std::vector<NativeStar> detect_native_stars(
    const NativeImage &image,
    double thresholdSigma,
    int minArea,
    int maxArea,
    const panolume::AstroSkyMask *skyMask = nullptr,
    NativePSFFitAudit *audit = nullptr
) {
    std::vector<NativeStar> stars;
    if (audit != nullptr) {
        *audit = NativePSFFitAudit();
    }
    if (image.status != "loaded" || image.width <= 16 || image.height <= 16 || image.pixels.empty()) {
        return stars;
    }

    cv::Mat gray32 = image_to_gray32(image);
    cv::Mat gray64;
    gray32.convertTo(gray64, CV_64F);
    cv::Mat background;
    cv::blur(gray64, background, cv::Size(50, 50));
    cv::Mat dataSub = gray64 - background;

    std::vector<double> samples;
    samples.reserve(static_cast<size_t>(dataSub.rows) * static_cast<size_t>(dataSub.cols));
    for (int y = 0; y < dataSub.rows; ++y) {
        const double *row = dataSub.ptr<double>(y);
        for (int x = 0; x < dataSub.cols; ++x) {
            if (skyMask != nullptr && !skyMask->contains(x, y)) {
                continue;
            }
            const double value = row[x];
            if (std::isfinite(value)) {
                samples.push_back(value);
            }
        }
    }
    if (samples.empty()) {
        return stars;
    }

    const double median = median_value(samples);
    std::vector<double> deviations;
    deviations.reserve(samples.size());
    for (double value : samples) {
        deviations.push_back(std::abs(value - median));
    }
    double noise = median_value(deviations) * 1.4826;
    if (noise <= 1e-10) {
        const double p90 = percentile_value(samples, 90.0);
        std::vector<double> lowerSamples;
        lowerSamples.reserve(samples.size());
        for (double value : samples) {
            if (value < p90) {
                lowerSamples.push_back(value);
            }
        }
        noise = standard_deviation(lowerSamples);
    }
    if (noise <= 1e-10) {
        noise = standard_deviation(samples);
    }
    if (noise <= 1e-10) {
        noise = 1e-6;
    }

    cv::Mat localMax;
    cv::dilate(dataSub, localMax, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5)));
    const double threshold = thresholdSigma * noise;
    const int radius = 6;
    const int edge = radius + 1;
    struct PreliminaryPSFCandidate {
        int peakX = 0;
        int peakY = 0;
        double flux = 0.0;
    };
    constexpr int candidateGridSize = 8;
    std::array<std::vector<PreliminaryPSFCandidate>, candidateGridSize * candidateGridSize> candidateCells;
    for (int y = edge; y < dataSub.rows - edge; ++y) {
        const double *row = dataSub.ptr<double>(y);
        const double *maxRow = localMax.ptr<double>(y);
        for (int x = edge; x < dataSub.cols - edge; ++x) {
            if (skyMask != nullptr && !skyMask->contains(x, y, edge)) {
                continue;
            }
            const double value = row[x];
            if (value <= threshold || value != maxRow[x]) {
                continue;
            }

            const int x0 = std::max(0, x - radius);
            const int x1 = std::min(dataSub.cols - 1, x + radius);
            const int y0 = std::max(0, y - radius);
            const int y1 = std::min(dataSub.rows - 1, y + radius);
            double total = 0.0;
            double sumX = 0.0;
            double sumY = 0.0;
            for (int py = y0; py <= y1; ++py) {
                const double *patchRow = dataSub.ptr<double>(py);
                for (int px = x0; px <= x1; ++px) {
                    const double weight = std::max(patchRow[px] - noise, 0.0);
                    total += weight;
                    sumX += static_cast<double>(px) * weight;
                    sumY += static_cast<double>(py) * weight;
                }
            }
            if (total <= 0.0) {
                continue;
            }
            const double cx = sumX / total;
            const double cy = sumY / total;
            double momentX = 0.0;
            double momentY = 0.0;
            for (int py = y0; py <= y1; ++py) {
                const double *patchRow = dataSub.ptr<double>(py);
                for (int px = x0; px <= x1; ++px) {
                    const double weight = std::max(patchRow[px] - noise, 0.0);
                    const double dx = static_cast<double>(px) - cx;
                    const double dy = static_cast<double>(py) - cy;
                    momentX += dx * dx * weight;
                    momentY += dy * dy * weight;
                }
            }
            const double sigmaX = std::sqrt(std::max(momentX / total, 0.1));
            const double sigmaY = std::sqrt(std::max(momentY / total, 0.1));
            const double sigma = 0.5 * (sigmaX + sigmaY);
            const double area = sigmaX * sigmaY * M_PI;
            if (sigma <= 0.5 || sigma >= 10.0 || value <= threshold) {
                continue;
            }
            if (area < static_cast<double>(minArea) || area > static_cast<double>(maxArea)) {
                continue;
            }

            const int column = std::max(0, std::min(
                candidateGridSize - 1,
                x * candidateGridSize / std::max(1, dataSub.cols)
            ));
            const int rowIndex = std::max(0, std::min(
                candidateGridSize - 1,
                y * candidateGridSize / std::max(1, dataSub.rows)
            ));
            candidateCells[static_cast<size_t>(rowIndex * candidateGridSize + column)].push_back({
                x, y, value
            });
            if (audit != nullptr) audit->preliminaryCandidates += 1;
        }
    }
    for (auto &cell : candidateCells) {
        std::sort(cell.begin(), cell.end(), [](const auto &lhs, const auto &rhs) {
            if (lhs.flux != rhs.flux) return lhs.flux > rhs.flux;
            if (lhs.peakY != rhs.peakY) return lhs.peakY < rhs.peakY;
            return lhs.peakX < rhs.peakX;
        });
    }
    const size_t maximumPSFFits = std::max(image.width, image.height) > 5000
        ? 2048U : 768U;
    std::vector<PreliminaryPSFCandidate> selectedCandidates;
    selectedCandidates.reserve(maximumPSFFits);
    for (size_t depth = 0; selectedCandidates.size() < maximumPSFFits; ++depth) {
        bool found = false;
        for (const auto &cell : candidateCells) {
            if (depth >= cell.size()) continue;
            found = true;
            selectedCandidates.push_back(cell[depth]);
            if (selectedCandidates.size() >= maximumPSFFits) break;
        }
        if (!found) break;
    }
    for (const PreliminaryPSFCandidate &candidate : selectedCandidates) {
        const int x0 = candidate.peakX - radius;
        const int x1 = candidate.peakX + radius;
        const int y0 = candidate.peakY - radius;
        const int y1 = candidate.peakY + radius;
        std::vector<double> psfPatch;
        psfPatch.reserve(static_cast<size_t>((x1 - x0 + 1) * (y1 - y0 + 1)));
        for (int py = y0; py <= y1; ++py) {
            const double *patchRow = dataSub.ptr<double>(py);
            for (int px = x0; px <= x1; ++px) psfPatch.push_back(patchRow[px]);
        }
        const panolume::EllipticalGaussianPSF psf = panolume::fit_elliptical_gaussian_psf(
            psfPatch, x1 - x0 + 1, y1 - y0 + 1, noise
        );
        // Correspondence identities are frozen only after this independent
        // PSF fit. Moment-only or low-quality centroids never enter fit,
        // validation, or final held-out partitions.
        if (!psf.success) {
            if (audit != nullptr) audit->rejectedReasons[psf.reason] += 1;
            continue;
        }
        NativeStar star;
        star.x = static_cast<double>(x0) + psf.centerX;
        star.y = static_cast<double>(y0) + psf.centerY;
        star.flux = psf.amplitude;
        star.sigma = std::sqrt(std::max(0.1, 0.5 * (
            psf.covarianceXX + psf.covarianceYY
        )));
        star.covarianceXX = psf.covarianceXX;
        star.covarianceXY = psf.covarianceXY;
        star.covarianceYY = psf.covarianceYY;
        star.psfSignalToNoise = psf.signalToNoise;
        star.psfNormalizedRMS = psf.normalizedRMS;
        stars.push_back(star);
    }
    if (audit != nullptr) {
        audit->selectedForFit = static_cast<int>(selectedCandidates.size());
        audit->accepted = static_cast<int>(stars.size());
        std::vector<double> signalToNoise;
        std::vector<double> normalizedRMS;
        signalToNoise.reserve(stars.size());
        normalizedRMS.reserve(stars.size());
        for (const NativeStar &star : stars) {
            signalToNoise.push_back(star.psfSignalToNoise);
            normalizedRMS.push_back(star.psfNormalizedRMS);
        }
        if (!signalToNoise.empty()) {
            audit->signalToNoiseP05 = percentile_value(signalToNoise, 5.0);
            audit->signalToNoiseMedian = percentile_value(signalToNoise, 50.0);
            audit->normalizedRMSMedian = percentile_value(normalizedRMS, 50.0);
            audit->normalizedRMSP95 = percentile_value(normalizedRMS, 95.0);
        }
    }
    return stars;
}

static panolume::AstroSkyMask native_auto_sky_mask(const NativeImage &image) {
    cv::Mat gray = image_to_gray32(image);
    if (gray.empty() || gray.rows != image.height || gray.cols != image.width) {
        return {};
    }
    std::vector<float> luminance(static_cast<size_t>(gray.rows) * static_cast<size_t>(gray.cols));
    for (int y = 0; y < gray.rows; ++y) {
        const float *source = gray.ptr<float>(y);
        std::copy(source, source + gray.cols, luminance.begin() + static_cast<size_t>(y * gray.cols));
    }
    return panolume::make_auto_sky_mask(luminance, gray.cols, gray.rows, 800);
}

static std::vector<NativeStar> detect_native_stars_for_request(
    const NativeImage &image,
    double thresholdSigma,
    const panolume::EngineRequest &request,
    NativePSFFitAudit *audit = nullptr
) {
    const std::string skyMode = lower_string(request.string("astroSkyMode", "auto_sky"));
    if (skyMode == "full_frame" || skyMode == "fullframe") {
        return detect_native_stars(image, thresholdSigma, 1, 500, nullptr, audit);
    }
    const panolume::AstroSkyMask mask = native_auto_sky_mask(image);
    return detect_native_stars(
        image, thresholdSigma, 1, 500, mask.valid() ? &mask : nullptr, audit
    );
}

static std::vector<NativeStar> select_brightest_stars(const std::vector<NativeStar> &stars, int maxStars) {
    if (maxStars <= 0) {
        return {};
    }
    if (static_cast<int>(stars.size()) <= maxStars) {
        return stars;
    }
    std::vector<int> order(stars.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&stars](int a, int b) {
        return stars[static_cast<size_t>(a)].flux > stars[static_cast<size_t>(b)].flux;
    });
    std::vector<NativeStar> selected;
    selected.reserve(static_cast<size_t>(maxStars));
    for (int idx : order) {
        selected.push_back(stars[static_cast<size_t>(idx)]);
        if (static_cast<int>(selected.size()) >= maxStars) {
            break;
        }
    }
    return selected;
}

static std::vector<NativeStar> select_spatially_balanced_stars(
    const std::vector<NativeStar> &stars,
    int maxStars,
    int gridSize
) {
    if (maxStars <= 0) {
        return {};
    }
    if (static_cast<int>(stars.size()) <= maxStars) {
        return stars;
    }
    if (gridSize <= 1) {
        return select_brightest_stars(stars, maxStars);
    }

    double minX = stars[0].x;
    double maxX = stars[0].x;
    double minY = stars[0].y;
    double maxY = stars[0].y;
    for (const NativeStar &star : stars) {
        minX = std::min(minX, star.x);
        maxX = std::max(maxX, star.x);
        minY = std::min(minY, star.y);
        maxY = std::max(maxY, star.y);
    }
    const double spanX = std::max(maxX - minX, 1e-8);
    const double spanY = std::max(maxY - minY, 1e-8);
    std::vector<std::vector<int>> cells(static_cast<size_t>(gridSize * gridSize));
    for (size_t idx = 0; idx < stars.size(); ++idx) {
        int cellX = static_cast<int>(std::floor((stars[idx].x - minX) / spanX * static_cast<double>(gridSize)));
        int cellY = static_cast<int>(std::floor((stars[idx].y - minY) / spanY * static_cast<double>(gridSize)));
        cellX = std::max(0, std::min(gridSize - 1, cellX));
        cellY = std::max(0, std::min(gridSize - 1, cellY));
        cells[static_cast<size_t>(cellY * gridSize + cellX)].push_back(static_cast<int>(idx));
    }

    const int quota = std::max(1, static_cast<int>(std::ceil(static_cast<double>(maxStars) / static_cast<double>(gridSize * gridSize))));
    std::vector<NativeStar> selected;
    std::set<int> selectedIndices;
    selected.reserve(static_cast<size_t>(maxStars));
    for (int cy = 0; cy < gridSize; ++cy) {
        for (int cx = 0; cx < gridSize; ++cx) {
            std::vector<int> &indices = cells[static_cast<size_t>(cy * gridSize + cx)];
            std::sort(indices.begin(), indices.end(), [&stars](int a, int b) {
                return stars[static_cast<size_t>(a)].flux > stars[static_cast<size_t>(b)].flux;
            });
            int taken = 0;
            for (int idx : indices) {
                selected.push_back(stars[static_cast<size_t>(idx)]);
                selectedIndices.insert(idx);
                taken += 1;
                if (taken >= quota || static_cast<int>(selected.size()) >= maxStars) {
                    break;
                }
            }
            if (static_cast<int>(selected.size()) >= maxStars) {
                return selected;
            }
        }
    }

    if (static_cast<int>(selected.size()) < maxStars) {
        std::vector<int> order(stars.size());
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&stars](int a, int b) {
            return stars[static_cast<size_t>(a)].flux > stars[static_cast<size_t>(b)].flux;
        });
        for (int idx : order) {
            if (selectedIndices.count(idx) > 0) {
                continue;
            }
            selected.push_back(stars[static_cast<size_t>(idx)]);
            if (static_cast<int>(selected.size()) >= maxStars) {
                break;
            }
        }
    }
    return selected;
}

static std::vector<NativeStar> merge_unique_stars(
    const std::vector<NativeStar> &first,
    const std::vector<NativeStar> &second
) {
    std::vector<NativeStar> merged;
    std::set<std::pair<long long, long long>> seen;
    for (const std::vector<NativeStar> *stars : {&first, &second}) {
        for (const NativeStar &star : *stars) {
            const long long keyX = static_cast<long long>(std::llround(star.x * 1000000.0));
            const long long keyY = static_cast<long long>(std::llround(star.y * 1000000.0));
            const std::pair<long long, long long> key = {keyX, keyY};
            if (seen.count(key) > 0) {
                continue;
            }
            seen.insert(key);
            merged.push_back(star);
        }
    }
    return merged;
}

static double star_distance(const NativeStar &a, const NativeStar &b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

static bool canonical_triangle(
    const std::vector<NativeStar> &points,
    const std::array<int, 3> &vertices,
    NativeTriangleDescriptor &descriptor
) {
    const NativeStar &p0 = points[static_cast<size_t>(vertices[0])];
    const NativeStar &p1 = points[static_cast<size_t>(vertices[1])];
    const NativeStar &p2 = points[static_cast<size_t>(vertices[2])];
    const double d01 = star_distance(p0, p1);
    const double d12 = star_distance(p1, p2);
    const double d20 = star_distance(p2, p0);
    std::array<double, 3> sides = {d12, d20, d01};
    const double longest = std::max(sides[0], std::max(sides[1], sides[2]));
    if (longest < 1e-6) {
        return false;
    }
    const double v1x = p1.x - p0.x;
    const double v1y = p1.y - p0.y;
    const double v2x = p2.x - p0.x;
    const double v2y = p2.y - p0.y;
    const double area = std::abs(v1x * v2y - v1y * v2x) * 0.5;
    if (area / (longest * longest) < 1e-3) {
        return false;
    }

    std::array<int, 3> sideOrder = {0, 1, 2};
    std::sort(sideOrder.begin(), sideOrder.end(), [&sides](int a, int b) {
        return sides[static_cast<size_t>(a)] < sides[static_cast<size_t>(b)];
    });
    // Canonical order is the vertex opposite the longest, middle, then
    // shortest side.  The ordering has to remain identical in both images so
    // that the chirality test below rejects mirrored fields instead of merely
    // finding a similar-looking triangle.
    descriptor.vertices = {
        vertices[static_cast<size_t>(sideOrder[2])],
        vertices[static_cast<size_t>(sideOrder[1])],
        vertices[static_cast<size_t>(sideOrder[0])]
    };

    std::array<double, 3> sortedSides = sides;
    std::sort(sortedSides.begin(), sortedSides.end());
    descriptor.ratioA = sortedSides[0] / longest;
    descriptor.ratioB = sortedSides[1] / longest;
    descriptor.scale = longest;
    const NativeStar &c0 = points[static_cast<size_t>(descriptor.vertices[0])];
    const NativeStar &c1 = points[static_cast<size_t>(descriptor.vertices[1])];
    const NativeStar &c2 = points[static_cast<size_t>(descriptor.vertices[2])];
    const double cross = (c1.x - c0.x) * (c2.y - c0.y)
        - (c1.y - c0.y) * (c2.x - c0.x);
    descriptor.clockwise = cross < 0.0;
    return true;
}

static std::vector<NativeTriangleDescriptor> build_triangle_descriptors(
    const std::vector<NativeStar> &points,
    int nearestNeighbors
) {
    std::vector<NativeTriangleDescriptor> descriptors;
    const int n = static_cast<int>(points.size());
    if (n < 3) {
        return descriptors;
    }
    const int k = std::min(nearestNeighbors, n - 1);
    std::set<std::array<int, 3>> seen;
    for (int center = 0; center < n; ++center) {
        std::vector<std::pair<double, int>> distances;
        distances.reserve(static_cast<size_t>(n - 1));
        for (int idx = 0; idx < n; ++idx) {
            if (idx == center) {
                continue;
            }
            distances.push_back({star_distance(points[static_cast<size_t>(center)], points[static_cast<size_t>(idx)]), idx});
        }
        std::sort(distances.begin(), distances.end(), [](const auto &a, const auto &b) {
            return a.first < b.first;
        });
        std::vector<int> neighbors;
        neighbors.reserve(static_cast<size_t>(k));
        for (int idx = 0; idx < k; ++idx) {
            neighbors.push_back(distances[static_cast<size_t>(idx)].second);
        }
        for (size_t a = 0; a < neighbors.size(); ++a) {
            for (size_t b = a + 1; b < neighbors.size(); ++b) {
                std::array<int, 3> raw = {center, neighbors[a], neighbors[b]};
                std::sort(raw.begin(), raw.end());
                if (seen.count(raw) > 0) {
                    continue;
                }
                seen.insert(raw);
                NativeTriangleDescriptor descriptor;
                if (canonical_triangle(points, raw, descriptor)) {
                    descriptors.push_back(descriptor);
                }
            }
        }
    }
    return descriptors;
}

struct NativeTriangleCandidate {
    double distance = 0.0;
    int triangleA = 0;
    int triangleB = 0;
};

static std::vector<NativeTriangleCandidate> candidate_triangle_pairs(
    const std::vector<NativeTriangleDescriptor> &descA,
    const std::vector<NativeTriangleDescriptor> &descB,
    const NativeStarSettings &settings
) {
    std::vector<NativeTriangleCandidate> candidates;
    for (size_t i = 0; i < descA.size(); ++i) {
        std::vector<NativeTriangleCandidate> local;
        for (size_t j = 0; j < descB.size(); ++j) {
            if (descA[i].clockwise != descB[j].clockwise) {
                continue;
            }
            const double dx = descA[i].ratioA - descB[j].ratioA;
            const double dy = descA[i].ratioB - descB[j].ratioB;
            const double distance = std::sqrt(dx * dx + dy * dy);
            if (distance > settings.triangleRatioTolerance) {
                continue;
            }
            const double scaleRatio = descB[j].scale / std::max(descA[i].scale, 1e-8);
            if (scaleRatio < settings.minTriangleScaleRatio || scaleRatio > settings.maxTriangleScaleRatio) {
                continue;
            }
            NativeTriangleCandidate candidate;
            candidate.distance = distance;
            candidate.triangleA = static_cast<int>(i);
            candidate.triangleB = static_cast<int>(j);
            local.push_back(candidate);
        }
        std::sort(local.begin(), local.end(), [](const NativeTriangleCandidate &a, const NativeTriangleCandidate &b) {
            return a.distance < b.distance;
        });
        const int take = std::min(settings.candidatesPerTriangle, static_cast<int>(local.size()));
        for (int idx = 0; idx < take; ++idx) {
            candidates.push_back(local[static_cast<size_t>(idx)]);
        }
    }
    std::sort(candidates.begin(), candidates.end(), [](const NativeTriangleCandidate &a, const NativeTriangleCandidate &b) {
        return a.distance < b.distance;
    });
    if (static_cast<int>(candidates.size()) > settings.maxTriangleCandidates) {
        candidates.resize(static_cast<size_t>(settings.maxTriangleCandidates));
    }
    return candidates;
}

static bool estimate_affine_transform(
    const std::vector<NativeStar> &src,
    const std::vector<NativeStar> &dst,
    cv::Mat &transform
) {
    const int n = static_cast<int>(src.size());
    if (n < 3 || static_cast<int>(dst.size()) < n) {
        return false;
    }
    cv::Mat X(n, 3, CV_64F);
    cv::Mat Y(n, 2, CV_64F);
    for (int idx = 0; idx < n; ++idx) {
        X.at<double>(idx, 0) = src[static_cast<size_t>(idx)].x;
        X.at<double>(idx, 1) = src[static_cast<size_t>(idx)].y;
        X.at<double>(idx, 2) = 1.0;
        Y.at<double>(idx, 0) = dst[static_cast<size_t>(idx)].x;
        Y.at<double>(idx, 1) = dst[static_cast<size_t>(idx)].y;
    }
    cv::Mat params;
    if (!cv::solve(X, Y, params, cv::DECOMP_SVD) || params.rows != 3 || params.cols != 2) {
        return false;
    }
    transform = (cv::Mat_<double>(2, 3) <<
        params.at<double>(0, 0), params.at<double>(1, 0), params.at<double>(2, 0),
        params.at<double>(0, 1), params.at<double>(1, 1), params.at<double>(2, 1)
    );
    return cv::checkRange(transform);
}

static cv::Point2d apply_affine_point(const cv::Mat &transform, const NativeStar &point) {
    return cv::Point2d(
        transform.at<double>(0, 0) * point.x + transform.at<double>(0, 1) * point.y + transform.at<double>(0, 2),
        transform.at<double>(1, 0) * point.x + transform.at<double>(1, 1) * point.y + transform.at<double>(1, 2)
    );
}

class NativePointIndex {
public:
    NativePointIndex(const std::vector<NativeStar> &points, double tolerance)
        : points_(points), cellSize_(std::max(tolerance, 1e-6)) {
        for (int idx = 0; idx < static_cast<int>(points_.size()); ++idx) {
            cells_[cell_for(points_[static_cast<size_t>(idx)].x, points_[static_cast<size_t>(idx)].y)].push_back(idx);
        }
    }

    bool nearest(const cv::Point2d &point, double tolerance, int &index, double &distance) const {
        const auto base = cell_for(point.x, point.y);
        const double maxDistanceSq = tolerance * tolerance;
        double bestDistanceSq = maxDistanceSq;
        int bestIndex = -1;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                const std::pair<int, int> key = {base.first + dx, base.second + dy};
                const auto found = cells_.find(key);
                if (found == cells_.end()) {
                    continue;
                }
                for (int idx : found->second) {
                    const NativeStar &candidate = points_[static_cast<size_t>(idx)];
                    const double deltaX = candidate.x - point.x;
                    const double deltaY = candidate.y - point.y;
                    const double distSq = deltaX * deltaX + deltaY * deltaY;
                    if (distSq <= bestDistanceSq) {
                        bestDistanceSq = distSq;
                        bestIndex = idx;
                    }
                }
            }
        }
        if (bestIndex < 0) {
            return false;
        }
        index = bestIndex;
        distance = std::sqrt(bestDistanceSq);
        return true;
    }

private:
    std::pair<int, int> cell_for(double x, double y) const {
        return {
            static_cast<int>(std::floor(x / cellSize_)),
            static_cast<int>(std::floor(y / cellSize_))
        };
    }

    std::vector<NativeStar> points_;
    double cellSize_ = 5.0;
    std::map<std::pair<int, int>, std::vector<int>> cells_;
};

struct NativeMatchedStars {
    std::vector<NativeStar> pointsA;
    std::vector<NativeStar> pointsB;
    std::vector<double> errors;
};

static NativeMatchedStars match_with_transform(
    const cv::Mat &transform,
    const std::vector<NativeStar> &pointsA,
    const std::vector<NativeStar> &pointsB,
    const NativePointIndex &indexB,
    double tolerance
) {
    struct Candidate {
        double distance = 0.0;
        int a = 0;
        int b = 0;
    };
    std::vector<Candidate> candidates;
    candidates.reserve(pointsA.size());
    for (int idx = 0; idx < static_cast<int>(pointsA.size()); ++idx) {
        const cv::Point2d projected = apply_affine_point(transform, pointsA[static_cast<size_t>(idx)]);
        int matchedIndex = -1;
        double distance = 0.0;
        if (indexB.nearest(projected, tolerance, matchedIndex, distance)) {
            candidates.push_back({distance, idx, matchedIndex});
        }
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        return a.distance < b.distance;
    });
    std::vector<bool> usedB(pointsB.size(), false);
    NativeMatchedStars matched;
    for (const Candidate &candidate : candidates) {
        if (candidate.b < 0 || candidate.b >= static_cast<int>(usedB.size()) || usedB[static_cast<size_t>(candidate.b)]) {
            continue;
        }
        usedB[static_cast<size_t>(candidate.b)] = true;
        matched.pointsA.push_back(pointsA[static_cast<size_t>(candidate.a)]);
        matched.pointsB.push_back(pointsB[static_cast<size_t>(candidate.b)]);
        matched.errors.push_back(candidate.distance);
    }
    return matched;
}

static std::vector<NativeStar> stars_for_vertices(
    const std::vector<NativeStar> &stars,
    const std::array<int, 3> &vertices
) {
    return {
        stars[static_cast<size_t>(vertices[0])],
        stars[static_cast<size_t>(vertices[1])],
        stars[static_cast<size_t>(vertices[2])]
    };
}

static bool find_best_star_affine(
    const std::vector<NativeStar> &pointsA,
    const std::vector<NativeStar> &pointsB,
    const std::vector<NativeTriangleDescriptor> &trianglesA,
    const std::vector<NativeTriangleDescriptor> &trianglesB,
    const std::vector<NativeTriangleCandidate> &candidates,
    const NativeStarSettings &settings,
    cv::Mat &transform,
    NativeMatchedStars &matched
) {
    const NativePointIndex indexB(pointsB, settings.pixelTolerance);
    int bestCount = -1;
    double bestMedianScore = std::numeric_limits<double>::infinity();
    cv::Mat bestTransform;
    NativeMatchedStars bestMatched;

    for (const NativeTriangleCandidate &candidate : candidates) {
        const std::vector<NativeStar> src = stars_for_vertices(pointsA, trianglesA[static_cast<size_t>(candidate.triangleA)].vertices);
        const std::vector<NativeStar> dst = stars_for_vertices(pointsB, trianglesB[static_cast<size_t>(candidate.triangleB)].vertices);
        cv::Mat candidateTransform;
        if (!estimate_affine_transform(src, dst, candidateTransform)) {
            continue;
        }
        NativeMatchedStars candidateMatched = match_with_transform(
            candidateTransform,
            pointsA,
            pointsB,
            indexB,
            settings.pixelTolerance
        );
        const int count = static_cast<int>(candidateMatched.pointsA.size());
        const double medianError = median_value(candidateMatched.errors);
        if (count > bestCount || (count == bestCount && medianError < bestMedianScore)) {
            bestCount = count;
            bestMedianScore = medianError;
            bestTransform = candidateTransform;
            bestMatched = std::move(candidateMatched);
        }
    }
    if (bestCount < 0 || bestTransform.empty()) {
        return false;
    }

    if (static_cast<int>(bestMatched.pointsA.size()) >= 3) {
        cv::Mat refined;
        if (estimate_affine_transform(bestMatched.pointsA, bestMatched.pointsB, refined)) {
            NativeMatchedStars refinedMatched = match_with_transform(
                refined,
                pointsA,
                pointsB,
                indexB,
                settings.pixelTolerance
            );
            bestTransform = refined;
            bestMatched = std::move(refinedMatched);
        }
    }
    transform = bestTransform;
    matched = std::move(bestMatched);
    return true;
}

static bool match_and_refine_with_coverage(
    const cv::Mat &transform,
    const NativeMatchedStars &baseline,
    const std::vector<NativeStar> &coverageA,
    const std::vector<NativeStar> &coverageB,
    const NativeStarSettings &settings,
    cv::Mat &outTransform,
    NativeMatchedStars &outMatched
) {
    if (coverageA.size() <= baseline.pointsA.size() || coverageB.size() <= baseline.pointsB.size()) {
        return false;
    }
    const NativePointIndex coverageIndexB(coverageB, settings.pixelTolerance);
    NativeMatchedStars coverage = match_with_transform(
        transform,
        coverageA,
        coverageB,
        coverageIndexB,
        settings.pixelTolerance
    );
    if (coverage.pointsA.size() < baseline.pointsA.size()) {
        return false;
    }
    const double baselineMedian = baseline.errors.empty() ? settings.pixelTolerance : median_value(baseline.errors);
    const double coverageMedian = coverage.errors.empty() ? std::numeric_limits<double>::infinity() : median_value(coverage.errors);
    const double maxAllowedMedian = std::max(baselineMedian * 2.0, settings.pixelTolerance * 0.75);
    if (coverageMedian > maxAllowedMedian) {
        return false;
    }

    cv::Mat refined;
    if (!estimate_affine_transform(coverage.pointsA, coverage.pointsB, refined)) {
        outTransform = transform;
        outMatched = std::move(coverage);
        return true;
    }
    NativeMatchedStars refinedMatched = match_with_transform(
        refined,
        coverageA,
        coverageB,
        coverageIndexB,
        settings.pixelTolerance
    );
    if (refinedMatched.pointsA.size() < std::max(baseline.pointsA.size(), static_cast<size_t>(static_cast<double>(coverage.pointsA.size()) * 0.9))) {
        outTransform = transform;
        outMatched = std::move(coverage);
        return true;
    }
    const double refinedMedian = refinedMatched.errors.empty() ? std::numeric_limits<double>::infinity() : median_value(refinedMatched.errors);
    if (refinedMedian > maxAllowedMedian) {
        outTransform = transform;
        outMatched = std::move(coverage);
        return true;
    }
    outTransform = refined;
    outMatched = std::move(refinedMatched);
    return true;
}

struct NativeCoverageQualityValues {
    double bboxAreaA = 0.0;
    double bboxAreaB = 0.0;
    double gridOccupancyA = 0.0;
    double gridOccupancyB = 0.0;
};

static bool native_star_bounds(
    const std::vector<NativeStar> &points,
    double &minX,
    double &minY,
    double &maxX,
    double &maxY
) {
    if (points.empty()) {
        return false;
    }
    minX = maxX = points.front().x;
    minY = maxY = points.front().y;
    for (const NativeStar &point : points) {
        minX = std::min(minX, point.x);
        minY = std::min(minY, point.y);
        maxX = std::max(maxX, point.x);
        maxY = std::max(maxY, point.y);
    }
    return std::isfinite(minX) && std::isfinite(minY) && std::isfinite(maxX) && std::isfinite(maxY);
}

static double native_bbox_area_ratio(
    const std::vector<NativeStar> &points,
    const std::vector<NativeStar> &reference
) {
    double refMinX = 0.0;
    double refMinY = 0.0;
    double refMaxX = 0.0;
    double refMaxY = 0.0;
    double pointMinX = 0.0;
    double pointMinY = 0.0;
    double pointMaxX = 0.0;
    double pointMaxY = 0.0;
    if (!native_star_bounds(reference, refMinX, refMinY, refMaxX, refMaxY)
        || !native_star_bounds(points, pointMinX, pointMinY, pointMaxX, pointMaxY)) {
        return 0.0;
    }
    const double refArea = std::max(1.0, (refMaxX - refMinX) * (refMaxY - refMinY));
    const double pointArea = std::max(0.0, (pointMaxX - pointMinX) * (pointMaxY - pointMinY));
    return std::min(1.0, std::max(0.0, pointArea / refArea));
}

static double native_grid_occupancy_ratio(
    const std::vector<NativeStar> &points,
    const std::vector<NativeStar> &reference,
    int gridSize
) {
    if (points.empty() || reference.empty() || gridSize <= 0) {
        return 0.0;
    }
    double refMinX = 0.0;
    double refMinY = 0.0;
    double refMaxX = 0.0;
    double refMaxY = 0.0;
    if (!native_star_bounds(reference, refMinX, refMinY, refMaxX, refMaxY)) {
        return 0.0;
    }
    const double width = std::max(1.0, refMaxX - refMinX);
    const double height = std::max(1.0, refMaxY - refMinY);
    std::set<std::pair<int, int>> occupied;
    for (const NativeStar &point : points) {
        const int col = std::max(0, std::min(
            gridSize - 1,
            static_cast<int>(std::floor(((point.x - refMinX) / width) * static_cast<double>(gridSize)))
        ));
        const int row = std::max(0, std::min(
            gridSize - 1,
            static_cast<int>(std::floor(((point.y - refMinY) / height) * static_cast<double>(gridSize)))
        ));
        occupied.insert({row, col});
    }
    return static_cast<double>(occupied.size()) / static_cast<double>(gridSize * gridSize);
}

static NativeCoverageQualityValues native_coverage_quality(
    const NativeMatchedStars &matched,
    const std::vector<NativeStar> &referenceA,
    const std::vector<NativeStar> &referenceB,
    int gridSize
) {
    NativeCoverageQualityValues quality;
    quality.bboxAreaA = native_bbox_area_ratio(matched.pointsA, referenceA);
    quality.bboxAreaB = native_bbox_area_ratio(matched.pointsB, referenceB);
    quality.gridOccupancyA = native_grid_occupancy_ratio(matched.pointsA, referenceA, gridSize);
    quality.gridOccupancyB = native_grid_occupancy_ratio(matched.pointsB, referenceB, gridSize);
    return quality;
}

static double native_min_bbox_area(const NativeCoverageQualityValues &quality) {
    return std::min(quality.bboxAreaA, quality.bboxAreaB);
}

static double native_min_grid_occupancy(const NativeCoverageQualityValues &quality) {
    return std::min(quality.gridOccupancyA, quality.gridOccupancyB);
}

static std::string native_adaptive_coverage_reject_reason(
    const NativeMatchedStars &current,
    const NativeMatchedStars &candidate,
    const NativeCoverageQualityValues &currentQuality,
    const NativeCoverageQualityValues &candidateQuality,
    const NativeStarSettings &settings
) {
    if (candidate.pointsA.size() < current.pointsA.size()) {
        return "adaptive candidate reduced inlier count";
    }
    const double currentMedian = current.errors.empty() ? settings.pixelTolerance : median_value(current.errors);
    const double candidateMedian = candidate.errors.empty() ? std::numeric_limits<double>::infinity() : median_value(candidate.errors);
    const double maxAllowedMedian = std::max(currentMedian * 1.5, settings.pixelTolerance * 0.75);
    if (candidateMedian > maxAllowedMedian) {
        return "adaptive candidate worsened median star error";
    }

    const double currentBBox = native_min_bbox_area(currentQuality);
    const double candidateBBox = native_min_bbox_area(candidateQuality);
    const double currentGrid = native_min_grid_occupancy(currentQuality);
    const double candidateGrid = native_min_grid_occupancy(candidateQuality);
    const bool bboxImproved = candidateBBox >= std::max(settings.adaptiveMinBBoxArea, currentBBox * 1.15)
        && candidateBBox > currentBBox + 1e-6;
    const bool gridImproved = candidateGrid >= std::max(settings.adaptiveMinGridOccupancy, currentGrid * 1.15)
        && candidateGrid > currentGrid + 1e-6;
    if (!bboxImproved && !gridImproved) {
        return "adaptive candidate did not improve bbox or grid coverage";
    }
    return "";
}

static NativeStarMatch match_native_stars_by_asterisms(
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarSettings &settings
) {
    NativeStarMatch result;
    if (static_cast<int>(starsA.size()) < settings.minInliers || static_cast<int>(starsB.size()) < settings.minInliers) {
        result.reason = "not enough detected stars";
        return result;
    }

    const std::vector<NativeStar> hypothesisA = select_brightest_stars(starsA, settings.maxStars);
    const std::vector<NativeStar> hypothesisB = select_brightest_stars(starsB, settings.maxStars);
    result.hypothesisStarsA = static_cast<int>(hypothesisA.size());
    result.hypothesisStarsB = static_cast<int>(hypothesisB.size());

    const std::vector<NativeTriangleDescriptor> trianglesA = build_triangle_descriptors(hypothesisA, settings.nearestNeighbors);
    const std::vector<NativeTriangleDescriptor> trianglesB = build_triangle_descriptors(hypothesisB, settings.nearestNeighbors);
    result.trianglesA = static_cast<int>(trianglesA.size());
    result.trianglesB = static_cast<int>(trianglesB.size());
    if (trianglesA.empty() || trianglesB.empty()) {
        result.reason = "not enough valid star triangles";
        return result;
    }

    const std::vector<NativeTriangleCandidate> candidates = candidate_triangle_pairs(trianglesA, trianglesB, settings);
    result.triangleCandidates = static_cast<int>(candidates.size());
    if (candidates.empty()) {
        result.reason = "no similar triangle asterisms at plausible scale";
        return result;
    }

    cv::Mat transform;
    NativeMatchedStars matched;
    if (!find_best_star_affine(hypothesisA, hypothesisB, trianglesA, trianglesB, candidates, settings, transform, matched)) {
        result.reason = "no affine hypothesis could be estimated";
        return result;
    }
    result.hypothesisInliers = static_cast<int>(matched.pointsA.size());

    const int maxCoverage = std::max(settings.maxStars, static_cast<int>(std::llround(static_cast<double>(settings.maxStars) * std::max(settings.coverageMultiplier, 1.0))));
    const std::vector<NativeStar> coverageA = merge_unique_stars(
        hypothesisA,
        select_spatially_balanced_stars(starsA, maxCoverage, settings.spatialGridSize)
    );
    const std::vector<NativeStar> coverageB = merge_unique_stars(
        hypothesisB,
        select_spatially_balanced_stars(starsB, maxCoverage, settings.spatialGridSize)
    );
    result.coverageStarsA = static_cast<int>(coverageA.size());
    result.coverageStarsB = static_cast<int>(coverageB.size());

    cv::Mat coverageTransform;
    NativeMatchedStars coverageMatched;
    if (match_and_refine_with_coverage(transform, matched, coverageA, coverageB, settings, coverageTransform, coverageMatched)) {
        transform = coverageTransform;
        matched = std::move(coverageMatched);
    }
    result.coverageInliers = static_cast<int>(matched.pointsA.size());
    NativeCoverageQualityValues coverageQuality = native_coverage_quality(
        matched,
        starsA,
        starsB,
        std::max(1, settings.spatialGridSize)
    );
    result.coverageBBoxAreaA = coverageQuality.bboxAreaA;
    result.coverageBBoxAreaB = coverageQuality.bboxAreaB;
    result.coverageGridOccupancyA = coverageQuality.gridOccupancyA;
    result.coverageGridOccupancyB = coverageQuality.gridOccupancyB;
    result.adaptiveBBoxAreaA = coverageQuality.bboxAreaA;
    result.adaptiveBBoxAreaB = coverageQuality.bboxAreaB;
    result.adaptiveGridOccupancyA = coverageQuality.gridOccupancyA;
    result.adaptiveGridOccupancyB = coverageQuality.gridOccupancyB;

    const bool coverageBelowTarget =
        native_min_bbox_area(coverageQuality) < settings.adaptiveMinBBoxArea
        || native_min_grid_occupancy(coverageQuality) < settings.adaptiveMinGridOccupancy;
    if (settings.adaptiveCoverage && coverageBelowTarget) {
        result.adaptiveCoverageAttempted = true;
        const int maxAdaptive = std::max(
            settings.maxStars,
            static_cast<int>(std::llround(static_cast<double>(settings.maxStars) * settings.adaptiveCoverageMultiplier))
        );
        const std::vector<NativeStar> adaptiveA = merge_unique_stars(
            hypothesisA,
            select_spatially_balanced_stars(starsA, maxAdaptive, settings.spatialGridSize)
        );
        const std::vector<NativeStar> adaptiveB = merge_unique_stars(
            hypothesisB,
            select_spatially_balanced_stars(starsB, maxAdaptive, settings.spatialGridSize)
        );
        cv::Mat adaptiveTransform;
        NativeMatchedStars adaptiveMatched;
        if (match_and_refine_with_coverage(transform, matched, adaptiveA, adaptiveB, settings, adaptiveTransform, adaptiveMatched)) {
            NativeCoverageQualityValues adaptiveQuality = native_coverage_quality(
                adaptiveMatched,
                starsA,
                starsB,
                std::max(1, settings.spatialGridSize)
            );
            result.adaptiveCoverageInliers = static_cast<int>(adaptiveMatched.pointsA.size());
            result.adaptiveBBoxAreaA = adaptiveQuality.bboxAreaA;
            result.adaptiveBBoxAreaB = adaptiveQuality.bboxAreaB;
            result.adaptiveGridOccupancyA = adaptiveQuality.gridOccupancyA;
            result.adaptiveGridOccupancyB = adaptiveQuality.gridOccupancyB;
            const std::string adaptiveRejectReason = native_adaptive_coverage_reject_reason(
                matched,
                adaptiveMatched,
                coverageQuality,
                adaptiveQuality,
                settings
            );
            if (adaptiveRejectReason.empty()) {
                result.adaptiveCoverageAccepted = true;
                transform = adaptiveTransform;
                matched = std::move(adaptiveMatched);
                coverageQuality = adaptiveQuality;
            } else {
                result.adaptiveCoverageRejectReason = adaptiveRejectReason;
            }
        } else {
            result.adaptiveCoverageRejectReason = "adaptive coverage matching produced no candidate";
        }
    } else if (!settings.adaptiveCoverage) {
        result.adaptiveCoverageRejectReason = "adaptive coverage disabled";
    } else {
        result.adaptiveCoverageRejectReason = "coverage quality already sufficient";
    }

    result.affine = transform;
    result.pointsA = std::move(matched.pointsA);
    result.pointsB = std::move(matched.pointsB);
    result.errors = std::move(matched.errors);
    if (static_cast<int>(result.pointsA.size()) < settings.minInliers) {
        result.reason = "not enough geometrically consistent stars";
        return result;
    }
    result.success = true;
    return result;
}

// Recovery matcher adapted from AstroX's current triangle-vote registration
// path.  The normal matcher intentionally limits triangles to local
// neighbourhoods; that is efficient, but can miss an adjacent night-sky pair
// when the shared stars occupy different parts of the two frames.  This
// fallback votes over all triangles formed by a small brightest-star subset,
// rejects mirrored fields by chirality, and estimates a deterministic
// similarity before returning any control points.
struct NativeVoteTriangle {
    std::array<int, 3> vertices = {0, 0, 0};
    double u = 0.0; // middle / longest side
    double v = 0.0; // shortest / longest side
    bool clockwise = false;
};

static std::vector<NativeVoteTriangle> build_vote_triangles(
    const std::vector<NativeStar> &stars
) {
    std::vector<NativeVoteTriangle> triangles;
    const int count = static_cast<int>(stars.size());
    if (count < 3) {
        return triangles;
    }
    triangles.reserve(static_cast<size_t>(count * (count - 1) * (count - 2) / 6));
    for (int i = 0; i < count; ++i) {
        for (int j = i + 1; j < count; ++j) {
            for (int k = j + 1; k < count; ++k) {
                NativeTriangleDescriptor descriptor;
                if (!canonical_triangle(stars, {i, j, k}, descriptor)) {
                    continue;
                }
                const double shortest = descriptor.ratioA * descriptor.scale;
                if (descriptor.scale < 10.0 || shortest < 4.0 || descriptor.ratioA < 0.1) {
                    continue;
                }
                NativeVoteTriangle triangle;
                triangle.vertices = descriptor.vertices;
                triangle.u = descriptor.ratioB;
                triangle.v = descriptor.ratioA;
                triangle.clockwise = descriptor.clockwise;
                triangles.push_back(triangle);
            }
        }
    }
    return triangles;
}

static bool estimate_similarity_transform(
    const std::vector<NativeStar> &source,
    const std::vector<NativeStar> &target,
    cv::Mat &transform
) {
    if (source.size() != target.size() || source.size() < 2) {
        return false;
    }
    double sourceMeanX = 0.0;
    double sourceMeanY = 0.0;
    double targetMeanX = 0.0;
    double targetMeanY = 0.0;
    for (size_t idx = 0; idx < source.size(); ++idx) {
        sourceMeanX += source[idx].x;
        sourceMeanY += source[idx].y;
        targetMeanX += target[idx].x;
        targetMeanY += target[idx].y;
    }
    const double count = static_cast<double>(source.size());
    sourceMeanX /= count;
    sourceMeanY /= count;
    targetMeanX /= count;
    targetMeanY /= count;

    double numeratorA = 0.0;
    double numeratorB = 0.0;
    double denominator = 0.0;
    for (size_t idx = 0; idx < source.size(); ++idx) {
        const double sx = source[idx].x - sourceMeanX;
        const double sy = source[idx].y - sourceMeanY;
        const double tx = target[idx].x - targetMeanX;
        const double ty = target[idx].y - targetMeanY;
        numeratorA += sx * tx + sy * ty;
        numeratorB += sx * ty - sy * tx;
        denominator += sx * sx + sy * sy;
    }
    if (denominator < 1e-9) {
        return false;
    }
    const double a = numeratorA / denominator;
    const double b = numeratorB / denominator;
    const double scaleSquared = a * a + b * b;
    if (!std::isfinite(scaleSquared) || scaleSquared < 0.25 || scaleSquared > 4.0) {
        return false;
    }
    const double tx = targetMeanX - (a * sourceMeanX - b * sourceMeanY);
    const double ty = targetMeanY - (b * sourceMeanX + a * sourceMeanY);
    transform = (cv::Mat_<double>(2, 3) << a, -b, tx, b, a, ty);
    return cv::checkRange(transform);
}

static NativeStarMatch match_native_stars_by_triangle_vote(
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarSettings &settings
) {
    NativeStarMatch result;
    if (static_cast<int>(starsA.size()) < settings.minInliers
        || static_cast<int>(starsB.size()) < settings.minInliers) {
        result.reason = "not enough detected stars for triangle-vote recovery";
        return result;
    }

    constexpr int invariantBins = 128;
    constexpr double invariantTolerance = 0.01;
    constexpr size_t maxTrianglesPerBin = 48;
    const int hypothesisLimit = std::min(48, std::max(12, settings.maxStars));
    const std::vector<NativeStar> hypothesisA = select_brightest_stars(starsA, hypothesisLimit);
    const std::vector<NativeStar> hypothesisB = select_brightest_stars(starsB, hypothesisLimit);
    const std::vector<NativeVoteTriangle> trianglesA = build_vote_triangles(hypothesisA);
    const std::vector<NativeVoteTriangle> trianglesB = build_vote_triangles(hypothesisB);
    result.hypothesisStarsA = static_cast<int>(hypothesisA.size());
    result.hypothesisStarsB = static_cast<int>(hypothesisB.size());
    result.trianglesA = static_cast<int>(trianglesA.size());
    result.trianglesB = static_cast<int>(trianglesB.size());
    if (trianglesA.size() < 8 || trianglesB.size() < 8) {
        result.reason = "not enough invariant triangles for recovery";
        return result;
    }

    auto invariantBin = [](double value) {
        const int bin = static_cast<int>(value * static_cast<double>(invariantBins));
        return std::max(0, std::min(invariantBins - 1, bin));
    };
    std::unordered_map<int, std::vector<int>> triangleHash;
    triangleHash.reserve(trianglesA.size() * 2);
    for (int idx = 0; idx < static_cast<int>(trianglesA.size()); ++idx) {
        const NativeVoteTriangle &triangle = trianglesA[static_cast<size_t>(idx)];
        const int key = invariantBin(triangle.u) * invariantBins + invariantBin(triangle.v);
        std::vector<int> &bucket = triangleHash[key];
        if (bucket.size() <= maxTrianglesPerBin) {
            // One extra entry marks a degenerate bucket, which is skipped below.
            bucket.push_back(idx);
        }
    }

    const int countA = static_cast<int>(hypothesisA.size());
    const int countB = static_cast<int>(hypothesisB.size());
    std::vector<uint16_t> votes(static_cast<size_t>(countA) * static_cast<size_t>(countB), 0);
    const int binRadius = static_cast<int>(invariantTolerance * invariantBins) + 1;
    int compatibleTriangles = 0;
    for (const NativeVoteTriangle &triangleB : trianglesB) {
        const int uBin = invariantBin(triangleB.u);
        const int vBin = invariantBin(triangleB.v);
        for (int du = -binRadius; du <= binRadius; ++du) {
            const int candidateU = uBin + du;
            if (candidateU < 0 || candidateU >= invariantBins) {
                continue;
            }
            for (int dv = -binRadius; dv <= binRadius; ++dv) {
                const int candidateV = vBin + dv;
                if (candidateV < 0 || candidateV >= invariantBins) {
                    continue;
                }
                const auto found = triangleHash.find(candidateU * invariantBins + candidateV);
                if (found == triangleHash.end() || found->second.size() > maxTrianglesPerBin) {
                    continue;
                }
                for (int indexA : found->second) {
                    const NativeVoteTriangle &triangleA = trianglesA[static_cast<size_t>(indexA)];
                    if (triangleA.clockwise != triangleB.clockwise
                        || std::abs(triangleA.u - triangleB.u) > invariantTolerance
                        || std::abs(triangleA.v - triangleB.v) > invariantTolerance) {
                        continue;
                    }
                    compatibleTriangles += 1;
                    for (int vertex = 0; vertex < 3; ++vertex) {
                        uint16_t &vote = votes[
                            static_cast<size_t>(triangleA.vertices[static_cast<size_t>(vertex)])
                                * static_cast<size_t>(countB)
                            + static_cast<size_t>(triangleB.vertices[static_cast<size_t>(vertex)])
                        ];
                        if (vote < std::numeric_limits<uint16_t>::max()) {
                            vote += 1;
                        }
                    }
                }
            }
        }
    }
    result.triangleCandidates = compatibleTriangles;

    uint16_t maxVote = 0;
    for (uint16_t vote : votes) {
        maxVote = std::max(maxVote, vote);
    }
    if (maxVote < 3) {
        result.reason = "triangle-vote recovery found no stable correspondence votes";
        return result;
    }
    const uint16_t voteFloor = std::max<uint16_t>(3, maxVote / 8);
    std::vector<std::pair<int, int>> candidates;
    candidates.reserve(static_cast<size_t>(std::min(countA, countB)));
    for (int indexA = 0; indexA < countA; ++indexA) {
        int bestB = -1;
        uint16_t bestVote = 0;
        for (int indexB = 0; indexB < countB; ++indexB) {
            const uint16_t vote = votes[
                static_cast<size_t>(indexA) * static_cast<size_t>(countB)
                    + static_cast<size_t>(indexB)
            ];
            if (vote > bestVote) {
                bestVote = vote;
                bestB = indexB;
            }
        }
        if (bestB < 0 || bestVote < voteFloor) {
            continue;
        }
        bool mutualBest = true;
        for (int otherA = 0; otherA < countA; ++otherA) {
            if (votes[static_cast<size_t>(otherA) * static_cast<size_t>(countB) + static_cast<size_t>(bestB)] > bestVote) {
                mutualBest = false;
                break;
            }
        }
        if (mutualBest) {
            candidates.push_back({indexA, bestB});
        }
    }
    if (candidates.size() < 6) {
        result.reason = "triangle-vote recovery produced fewer than six mutual correspondences";
        return result;
    }

    std::mt19937 random(0x5EED5u);
    std::uniform_int_distribution<int> pick(0, static_cast<int>(candidates.size()) - 1);
    const double scoreTolerance = std::max(1.0, settings.pixelTolerance) * 2.0;
    cv::Mat bestTransform;
    int bestInliers = 0;
    double bestMedianError = std::numeric_limits<double>::infinity();
    for (int iteration = 0; iteration < 400; ++iteration) {
        const int firstIndex = pick(random);
        const int secondIndex = pick(random);
        if (firstIndex == secondIndex) {
            continue;
        }
        const auto &first = candidates[static_cast<size_t>(firstIndex)];
        const auto &second = candidates[static_cast<size_t>(secondIndex)];
        const NativeStar &source0 = hypothesisA[static_cast<size_t>(first.first)];
        const NativeStar &source1 = hypothesisA[static_cast<size_t>(second.first)];
        const NativeStar &target0 = hypothesisB[static_cast<size_t>(first.second)];
        const NativeStar &target1 = hypothesisB[static_cast<size_t>(second.second)];
        const double sourceDX = source1.x - source0.x;
        const double sourceDY = source1.y - source0.y;
        const double sourceDistanceSquared = sourceDX * sourceDX + sourceDY * sourceDY;
        if (sourceDistanceSquared < 400.0) {
            continue;
        }
        const double targetDX = target1.x - target0.x;
        const double targetDY = target1.y - target0.y;
        const double a = (targetDX * sourceDX + targetDY * sourceDY) / sourceDistanceSquared;
        const double b = (targetDY * sourceDX - targetDX * sourceDY) / sourceDistanceSquared;
        const double scaleSquared = a * a + b * b;
        if (scaleSquared < 0.25 || scaleSquared > 4.0) {
            continue;
        }
        const double tx = target0.x - (a * source0.x - b * source0.y);
        const double ty = target0.y - (b * source0.x + a * source0.y);
        cv::Mat candidateTransform = (cv::Mat_<double>(2, 3) << a, -b, tx, b, a, ty);
        int inliers = 0;
        std::vector<double> errors;
        errors.reserve(candidates.size());
        for (const auto &candidate : candidates) {
            const cv::Point2d projected = apply_affine_point(
                candidateTransform,
                hypothesisA[static_cast<size_t>(candidate.first)]
            );
            const NativeStar &target = hypothesisB[static_cast<size_t>(candidate.second)];
            const double dx = projected.x - target.x;
            const double dy = projected.y - target.y;
            const double error = std::sqrt(dx * dx + dy * dy);
            if (error <= scoreTolerance) {
                inliers += 1;
                errors.push_back(error);
            }
        }
        const double medianError = errors.empty()
            ? std::numeric_limits<double>::infinity()
            : median_value(errors);
        if (inliers > bestInliers || (inliers == bestInliers && medianError < bestMedianError)) {
            bestInliers = inliers;
            bestMedianError = medianError;
            bestTransform = candidateTransform;
        }
    }
    if (bestTransform.empty() || bestInliers < 6) {
        result.reason = "deterministic triangle-vote RANSAC did not converge";
        return result;
    }

    std::vector<NativeStar> ransacSource;
    std::vector<NativeStar> ransacTarget;
    for (const auto &candidate : candidates) {
        const NativeStar &source = hypothesisA[static_cast<size_t>(candidate.first)];
        const NativeStar &target = hypothesisB[static_cast<size_t>(candidate.second)];
        const cv::Point2d projected = apply_affine_point(bestTransform, source);
        const double dx = projected.x - target.x;
        const double dy = projected.y - target.y;
        if (dx * dx + dy * dy <= scoreTolerance * scoreTolerance) {
            ransacSource.push_back(source);
            ransacTarget.push_back(target);
        }
    }
    cv::Mat refinedTransform = bestTransform;
    cv::Mat leastSquaresTransform;
    if (estimate_similarity_transform(ransacSource, ransacTarget, leastSquaresTransform)) {
        refinedTransform = leastSquaresTransform;
    }

    const int maxCoverage = std::max(
        settings.maxStars,
        static_cast<int>(std::llround(static_cast<double>(settings.maxStars) * settings.adaptiveCoverageMultiplier))
    );
    const std::vector<NativeStar> coverageA = merge_unique_stars(
        hypothesisA,
        select_spatially_balanced_stars(starsA, maxCoverage, settings.spatialGridSize)
    );
    const std::vector<NativeStar> coverageB = merge_unique_stars(
        hypothesisB,
        select_spatially_balanced_stars(starsB, maxCoverage, settings.spatialGridSize)
    );
    result.coverageStarsA = static_cast<int>(coverageA.size());
    result.coverageStarsB = static_cast<int>(coverageB.size());

    const double looseTolerance = std::max(12.0, settings.pixelTolerance * 2.5);
    const NativePointIndex looseIndex(coverageB, looseTolerance);
    NativeMatchedStars looseMatched = match_with_transform(
        refinedTransform,
        coverageA,
        coverageB,
        looseIndex,
        looseTolerance
    );
    cv::Mat fullRefinedTransform;
    if (estimate_similarity_transform(looseMatched.pointsA, looseMatched.pointsB, fullRefinedTransform)) {
        refinedTransform = fullRefinedTransform;
    }

    const NativePointIndex finalIndex(coverageB, settings.pixelTolerance);
    NativeMatchedStars finalMatched = match_with_transform(
        refinedTransform,
        coverageA,
        coverageB,
        finalIndex,
        settings.pixelTolerance
    );
    result.hypothesisInliers = bestInliers;
    result.coverageInliers = static_cast<int>(finalMatched.pointsA.size());
    if (static_cast<int>(finalMatched.pointsA.size()) < settings.minInliers) {
        result.reason = "triangle-vote transform did not verify enough full-field stars";
        return result;
    }

    const NativeCoverageQualityValues coverageQuality = native_coverage_quality(
        finalMatched,
        starsA,
        starsB,
        std::max(1, settings.spatialGridSize)
    );
    result.coverageBBoxAreaA = coverageQuality.bboxAreaA;
    result.coverageBBoxAreaB = coverageQuality.bboxAreaB;
    result.coverageGridOccupancyA = coverageQuality.gridOccupancyA;
    result.coverageGridOccupancyB = coverageQuality.gridOccupancyB;
    result.adaptiveBBoxAreaA = coverageQuality.bboxAreaA;
    result.adaptiveBBoxAreaB = coverageQuality.bboxAreaB;
    result.adaptiveGridOccupancyA = coverageQuality.gridOccupancyA;
    result.adaptiveGridOccupancyB = coverageQuality.gridOccupancyB;
    result.adaptiveCoverageAttempted = true;
    result.adaptiveCoverageAccepted = true;
    result.adaptiveCoverageInliers = static_cast<int>(finalMatched.pointsA.size());
    result.affine = refinedTransform;
    result.pointsA = std::move(finalMatched.pointsA);
    result.pointsB = std::move(finalMatched.pointsB);
    result.errors = std::move(finalMatched.errors);
    result.success = true;
    return result;
}

static cv::Mat affine_to_homography(const cv::Mat &affine) {
    cv::Mat H = cv::Mat::eye(3, 3, CV_64F);
    affine.convertTo(H(cv::Rect(0, 0, 3, 2)), CV_64F);
    return H;
}

static double reprojection_error(const cv::Mat &H, const NativeStar &source, const NativeStar &target) {
    const double x = H.at<double>(0, 0) * source.x + H.at<double>(0, 1) * source.y + H.at<double>(0, 2);
    const double y = H.at<double>(1, 0) * source.x + H.at<double>(1, 1) * source.y + H.at<double>(1, 2);
    const double z = H.at<double>(2, 0) * source.x + H.at<double>(2, 1) * source.y + H.at<double>(2, 2);
    if (std::abs(z) < 1e-12) {
        return std::numeric_limits<double>::infinity();
    }
    const double px = x / z;
    const double py = y / z;
    const double dx = px - target.x;
    const double dy = py - target.y;
    return std::sqrt(dx * dx + dy * dy);
}

static uint64_t native_holdout_hash(const NativeStar &a, const NativeStar &b) {
    uint64_t hash = 1469598103934665603ULL;
    const std::array<long long, 4> values = {
        static_cast<long long>(std::llround(a.x * 16.0)),
        static_cast<long long>(std::llround(a.y * 16.0)),
        static_cast<long long>(std::llround(b.x * 16.0)),
        static_cast<long long>(std::llround(b.y * 16.0))
    };
    for (long long value : values) {
        uint64_t bits = static_cast<uint64_t>(value);
        for (int byte = 0; byte < 8; ++byte) {
            hash ^= bits & 0xffULL;
            hash *= 1099511628211ULL;
            bits >>= 8;
        }
    }
    return hash;
}

static int native_star_spatial_cell(
    const NativeStar &star,
    const std::vector<NativeStar> &reference,
    int gridSize
) {
    if (reference.empty() || gridSize <= 1) {
        return 0;
    }
    double minX = reference.front().x;
    double minY = reference.front().y;
    double maxX = reference.front().x;
    double maxY = reference.front().y;
    for (const NativeStar &item : reference) {
        minX = std::min(minX, item.x);
        minY = std::min(minY, item.y);
        maxX = std::max(maxX, item.x);
        maxY = std::max(maxY, item.y);
    }
    const double spanX = std::max(maxX - minX, 1.0);
    const double spanY = std::max(maxY - minY, 1.0);
    const int column = std::max(0, std::min(
        gridSize - 1,
        static_cast<int>(std::floor((star.x - minX) * static_cast<double>(gridSize) / spanX))
    ));
    const int row = std::max(0, std::min(
        gridSize - 1,
        static_cast<int>(std::floor((star.y - minY) * static_cast<double>(gridSize) / spanY))
    ));
    return row * gridSize + column;
}

static void native_split_star_matches_for_holdout(
    const NativeStarMatch &match,
    const std::vector<NativeStar> &referenceA,
    std::vector<int> &fitIndices,
    std::vector<int> &validationIndices,
    std::vector<int> &heldOutIndices
) {
    const int count = static_cast<int>(std::min(match.pointsA.size(), match.pointsB.size()));
    fitIndices.clear();
    validationIndices.clear();
    heldOutIndices.clear();
    if (count <= 0) {
        return;
    }
    int targetHeldOut = std::max(
        1, static_cast<int>(std::llround(static_cast<double>(count) * 0.40))
    );
    int targetValidation = std::max(
        1, static_cast<int>(std::llround(static_cast<double>(count) * 0.15))
    );
    // Preserve at least four fit observations for a projective initializer.
    // Small working-resolution overlaps may therefore round one reserved
    // partition down, but they never collapse all observations into fit.
    while (targetHeldOut + targetValidation > std::max(0, count - 4)) {
        if (targetHeldOut > targetValidation && targetHeldOut > 1) {
            targetHeldOut -= 1;
        } else if (targetValidation > 1) {
            targetValidation -= 1;
        } else {
            break;
        }
    }
    constexpr int gridSize = 4;
    std::array<std::vector<std::pair<uint64_t, int>>, gridSize * gridSize> cells;
    for (int index = 0; index < count; ++index) {
        const int cell = native_star_spatial_cell(
            match.pointsA[static_cast<size_t>(index)],
            referenceA,
            gridSize
        );
        cells[static_cast<size_t>(cell)].push_back({
            native_holdout_hash(
                match.pointsA[static_cast<size_t>(index)],
                match.pointsB[static_cast<size_t>(index)]
            ),
            index
        });
    }
    for (auto &cell : cells) {
        std::sort(cell.begin(), cell.end());
    }
    std::vector<unsigned char> partition(static_cast<size_t>(count), 0);
    for (size_t depth = 0; static_cast<int>(heldOutIndices.size()) < targetHeldOut; ++depth) {
        bool foundAtDepth = false;
        for (const auto &cell : cells) {
            if (depth >= cell.size()) {
                continue;
            }
            foundAtDepth = true;
            const int index = cell[depth].second;
            partition[static_cast<size_t>(index)] = 2;
            heldOutIndices.push_back(index);
            if (static_cast<int>(heldOutIndices.size()) >= targetHeldOut) {
                break;
            }
        }
        if (!foundAtDepth) {
            break;
        }
    }
    // Select validation from the next deterministic spatially balanced layer.
    // It is the only withheld partition consulted while choosing model
    // complexity. The final held-out layer above remains sealed until the
    // selected model has been refitted with the complete 60% training set.
    std::array<std::vector<int>, gridSize * gridSize> remaining;
    for (size_t cellIndex = 0; cellIndex < cells.size(); ++cellIndex) {
        for (const auto &entry : cells[cellIndex]) {
            if (partition[static_cast<size_t>(entry.second)] == 0) {
                remaining[cellIndex].push_back(entry.second);
            }
        }
    }
    for (size_t depth = 0; static_cast<int>(validationIndices.size()) < targetValidation; ++depth) {
        bool foundAtDepth = false;
        for (const auto &cell : remaining) {
            if (depth >= cell.size()) continue;
            const int index = cell[depth];
            foundAtDepth = true;
            partition[static_cast<size_t>(index)] = 1;
            validationIndices.push_back(index);
            if (static_cast<int>(validationIndices.size()) >= targetValidation) break;
        }
        if (!foundAtDepth) break;
    }
    for (int index = 0; index < count; ++index) {
        if (partition[static_cast<size_t>(index)] == 0) {
            fitIndices.push_back(index);
        }
    }
}

static bool native_star_match_has_required_coverage(
    const NativeStarMatch &match,
    const NativeStarSettings &settings
) {
    return std::min(match.coverageBBoxAreaA, match.coverageBBoxAreaB) >= settings.adaptiveMinBBoxArea
        && std::min(match.coverageGridOccupancyA, match.coverageGridOccupancyB) >= settings.adaptiveMinGridOccupancy;
}

static cv::Point2d native_apply_homography_point(const cv::Mat &homography, const NativeStar &point) {
    const double x = homography.at<double>(0, 0) * point.x
        + homography.at<double>(0, 1) * point.y
        + homography.at<double>(0, 2);
    const double y = homography.at<double>(1, 0) * point.x
        + homography.at<double>(1, 1) * point.y
        + homography.at<double>(1, 2);
    const double z = homography.at<double>(2, 0) * point.x
        + homography.at<double>(2, 1) * point.y
        + homography.at<double>(2, 2);
    if (std::abs(z) < 1e-12) {
        return {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity()};
    }
    return {x / z, y / z};
}

static std::vector<double> native_star_flux_ranks(const std::vector<NativeStar> &stars);
static std::vector<std::array<double, 3>> native_star_neighbor_signatures(
    const std::vector<NativeStar> &stars
);
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
);

static NativeStarMatch match_native_stars_from_sift_seed(
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const cv::Mat &inputHomography,
    const NativeStarSettings &settings
) {
    NativeStarMatch result;
    if (inputHomography.empty() || starsA.empty() || starsB.empty()) {
        result.reason = "SIFT seed or star detections are unavailable";
        return result;
    }
    cv::Mat homography;
    inputHomography.convertTo(homography, CV_64F);
    cv::Mat inverse = homography.inv();
    if (inverse.empty() || !cv::checkRange(inverse)) {
        result.reason = "SIFT seed homography is singular";
        return result;
    }
    const int limit = std::max(settings.maxStars, settings.maxStars * 2);
    const std::vector<NativeStar> candidatesA = select_spatially_balanced_stars(
        starsA, limit, settings.spatialGridSize
    );
    const std::vector<NativeStar> candidatesB = select_spatially_balanced_stars(
        starsB, limit, settings.spatialGridSize
    );
    // The SIFT homography is allowed to come from foreground structure and is
    // only a coarse seed for the differently projected sky. Brightness rank,
    // local asterism signature, mutual lookup, and the later deterministic
    // train/held-out split decide which star identities survive.
    const double tolerance = std::max(16.0, settings.pixelTolerance * 4.8);
    const std::vector<double> ranksA = native_star_flux_ranks(candidatesA);
    const std::vector<double> ranksB = native_star_flux_ranks(candidatesB);
    const std::vector<std::array<double, 3>> signaturesA = native_star_neighbor_signatures(candidatesA);
    const std::vector<std::array<double, 3>> signaturesB = native_star_neighbor_signatures(candidatesB);
    std::vector<bool> usedB(candidatesB.size(), false);
    for (int index = 0; index < static_cast<int>(candidatesA.size()); ++index) {
        const NativeStar &source = candidatesA[static_cast<size_t>(index)];
        const cv::Point2d projected = native_apply_homography_point(homography, source);
        if (!std::isfinite(projected.x) || !std::isfinite(projected.y)) {
            continue;
        }
        int targetIndex = -1;
        double forwardError = 0.0;
        if (!native_best_star_identity(
                projected,
                ranksA[static_cast<size_t>(index)],
                signaturesA[static_cast<size_t>(index)],
                candidatesB,
                ranksB,
                signaturesB,
                tolerance,
                targetIndex,
                forwardError
            )
            || targetIndex < 0
            || targetIndex >= static_cast<int>(usedB.size())
            || usedB[static_cast<size_t>(targetIndex)]) {
            continue;
        }
        const NativeStar &target = candidatesB[static_cast<size_t>(targetIndex)];
        const cv::Point2d reverseProjected = native_apply_homography_point(inverse, target);
        int reverseIndex = -1;
        double reverseError = 0.0;
        if (!native_best_star_identity(
                reverseProjected,
                ranksB[static_cast<size_t>(targetIndex)],
                signaturesB[static_cast<size_t>(targetIndex)],
                candidatesA,
                ranksA,
                signaturesA,
                tolerance,
                reverseIndex,
                reverseError
            )
            || reverseIndex != index) {
            continue;
        }
        usedB[static_cast<size_t>(targetIndex)] = true;
        result.pointsA.push_back(source);
        result.pointsB.push_back(target);
        result.errors.push_back(std::max(forwardError, reverseError));
    }
    if (static_cast<int>(result.pointsA.size()) < settings.minInliers) {
        result.reason = "SIFT seed produced too few mutual star identities";
        return result;
    }
    if (!estimate_affine_transform(result.pointsA, result.pointsB, result.affine)) {
        result.reason = "SIFT-seeded stars could not form a coarse affine";
        return result;
    }
    NativeMatchedStars matched;
    matched.pointsA = result.pointsA;
    matched.pointsB = result.pointsB;
    matched.errors = result.errors;
    const NativeCoverageQualityValues coverage = native_coverage_quality(
        matched, starsA, starsB, std::max(1, settings.spatialGridSize)
    );
    result.coverageBBoxAreaA = coverage.bboxAreaA;
    result.coverageBBoxAreaB = coverage.bboxAreaB;
    result.coverageGridOccupancyA = coverage.gridOccupancyA;
    result.coverageGridOccupancyB = coverage.gridOccupancyB;
    result.adaptiveBBoxAreaA = coverage.bboxAreaA;
    result.adaptiveBBoxAreaB = coverage.bboxAreaB;
    result.adaptiveGridOccupancyA = coverage.gridOccupancyA;
    result.adaptiveGridOccupancyB = coverage.gridOccupancyB;
    result.coverageInliers = static_cast<int>(result.pointsA.size());
    result.adaptiveCoverageAttempted = true;
    result.adaptiveCoverageAccepted = true;
    result.adaptiveCoverageInliers = result.coverageInliers;
    result.success = true;
    return result;
}

static bool compute_star_pair_edge(
    int i,
    int j,
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarSettings &settings,
    NativeMatchEdge &edge,
    bool *recoveryAttempted = nullptr,
    bool forceTriangleVoteRecovery = false,
    const NativeStarMatch *seededMatch = nullptr,
    bool allowSparseDraftPartitions = false
) {
    if (recoveryAttempted != nullptr) {
        *recoveryAttempted = false;
    }
    NativeStarMatch match;
    bool usedRecovery = forceTriangleVoteRecovery || seededMatch != nullptr;
    if (seededMatch != nullptr) {
        match = *seededMatch;
        if (recoveryAttempted != nullptr) {
            *recoveryAttempted = true;
        }
    } else if (forceTriangleVoteRecovery) {
        if (recoveryAttempted != nullptr) {
            *recoveryAttempted = true;
        }
        match = match_native_stars_by_triangle_vote(starsA, starsB, settings);
    } else {
        match = match_native_stars_by_asterisms(starsA, starsB, settings);
    }
    const bool weakInitialMatch = match.success && !native_star_match_has_required_coverage(match, settings);
    if (seededMatch == nullptr
        && !forceTriangleVoteRecovery
        && (weakInitialMatch || (!match.success && j == i + 1))) {
        if (recoveryAttempted != nullptr) {
            *recoveryAttempted = true;
        }
        NativeStarMatch recovered = match_native_stars_by_triangle_vote(starsA, starsB, settings);
        if (recovered.success && native_star_match_has_required_coverage(recovered, settings)) {
            match = std::move(recovered);
            usedRecovery = true;
        } else if (weakInitialMatch) {
            return false;
        } else {
            match = std::move(recovered);
        }
    } else if (!match.success) {
        return false;
    }
    if (!match.success || !native_star_match_has_required_coverage(match, settings)) {
        return false;
    }

    std::vector<int> trainingIndices;
    std::vector<int> validationIndices;
    std::vector<int> heldOutIndices;
    native_split_star_matches_for_holdout(
        match, starsA, trainingIndices, validationIndices, heldOutIndices
    );
    const size_t minimumValidation = allowSparseDraftPartitions ? 1 : 4;
    const size_t minimumHeldOut = allowSparseDraftPartitions ? 4 : 12;
    const int minimumOccupiedCells = allowSparseDraftPartitions ? 2 : 4;
    if (heldOutIndices.size() < minimumHeldOut
        || validationIndices.size() < minimumValidation
        || trainingIndices.size() < 4) {
        return false;
    }

    std::vector<cv::Point2f> pointsA;
    std::vector<cv::Point2f> pointsB;
    pointsA.reserve(trainingIndices.size());
    pointsB.reserve(trainingIndices.size());
    for (int index : trainingIndices) {
        pointsA.push_back(cv::Point2f(
            static_cast<float>(match.pointsA[static_cast<size_t>(index)].x),
            static_cast<float>(match.pointsA[static_cast<size_t>(index)].y)
        ));
        pointsB.push_back(cv::Point2f(
            static_cast<float>(match.pointsB[static_cast<size_t>(index)].x),
            static_cast<float>(match.pointsB[static_cast<size_t>(index)].y)
        ));
    }

    cv::Mat inlierMask;
    cv::Mat H;
    double inlierRatio = 0.0;
    if (seededMatch != nullptr && pointsA.size() >= 12) {
        // This is not the SIFT model: identities have already been replaced
        // with star centroids, and only the training partition is fitted.
        // The independent held-out stars below prevent a projective overfit.
        H = cv::findHomography(
            pointsA,
            pointsB,
            cv::RANSAC,
            settings.pixelTolerance,
            inlierMask,
            2000,
            0.995
        );
    } else if (settings.transformModel != "homography" && pointsA.size() >= 3) {
        // Camera rotation across a tall wide-angle frame is generally not a
        // 2-D similarity. A six-parameter affine remains a conservative coarse
        // initializer while avoiding the four-point projective overfit that
        // corrupted held-out stars in raw_2.
        cv::Mat affine = cv::estimateAffine2D(
            pointsA,
            pointsB,
            inlierMask,
            cv::RANSAC,
            settings.pixelTolerance,
            2000,
            0.995
        );
        if (!affine.empty()) {
            H = affine_to_homography(affine);
        }
    }
    // A star-field similarity request must never silently expand into an
    // eight-degree homography. With repetitive star patterns a four-point
    // homography can perfectly fit the training subset while sending the
    // independent held-out stars tens of pixels away. Homography remains an
    // explicit diagnostic option; similarity falls back to the independently
    // voted affine hypothesis instead.
    if (settings.transformModel == "homography"
        && (H.empty() || inlierMask.empty())
        && pointsA.size() >= 4) {
        H = cv::findHomography(pointsA, pointsB, cv::RANSAC, settings.pixelTolerance, inlierMask);
    }

    if (!inlierMask.empty()) {
        int inlierCount = 0;
        for (int row = 0; row < inlierMask.rows; ++row) {
            if (inlierMask.at<unsigned char>(row, 0) != 0) {
                inlierCount += 1;
            }
        }
        inlierRatio = static_cast<double>(inlierCount) / std::max<size_t>(pointsA.size(), 1);
    }

    if (H.empty() || inlierRatio < 0.3) {
        H = affine_to_homography(match.affine);
        std::vector<double> sortedErrors;
        sortedErrors.reserve(trainingIndices.size());
        for (int index : trainingIndices) {
            sortedErrors.push_back(match.errors[static_cast<size_t>(index)]);
        }
        const double keepThreshold = percentile_value(sortedErrors, 75.0);
        inlierMask = cv::Mat(static_cast<int>(trainingIndices.size()), 1, CV_8U, cv::Scalar(0));
        for (int row = 0; row < static_cast<int>(trainingIndices.size()); ++row) {
            if (match.errors[static_cast<size_t>(trainingIndices[static_cast<size_t>(row)])] <= keepThreshold) {
                inlierMask.at<unsigned char>(row, 0) = 1;
            }
        }
    }
    H.convertTo(H, CV_64F);

    int usedInliers = 0;
    double sumSquared = 0.0;
    std::vector<NativeControlPoint> controlPoints;
    for (int row = 0; row < static_cast<int>(trainingIndices.size()); ++row) {
        const int idx = trainingIndices[static_cast<size_t>(row)];
        const bool keep = inlierMask.empty() || inlierMask.at<unsigned char>(row, 0) != 0;
        if (!keep) {
            continue;
        }
        const double error = reprojection_error(H, match.pointsA[static_cast<size_t>(idx)], match.pointsB[static_cast<size_t>(idx)]);
        if (!std::isfinite(error)) {
            continue;
        }
        NativeControlPoint cp;
        cp.imageAIndex = i;
        cp.imageBIndex = j;
        cp.xA = match.pointsA[static_cast<size_t>(idx)].x;
        cp.yA = match.pointsA[static_cast<size_t>(idx)].y;
        cp.xB = match.pointsB[static_cast<size_t>(idx)].x;
        cp.yB = match.pointsB[static_cast<size_t>(idx)].y;
        cp.error = error;
        native_copy_psf_to_control_point(
            cp,
            match.pointsA[static_cast<size_t>(idx)],
            match.pointsB[static_cast<size_t>(idx)]
        );
        controlPoints.push_back(cp);
        sumSquared += error * error;
        usedInliers += 1;
    }
    if (usedInliers < 4) {
        return false;
    }

    const double correspondenceAssociationLimit = std::max(2.0, settings.pixelTolerance * 1.6);
    auto buildReservedPartition = [&](const std::vector<int> &indices,
                                      std::vector<double> *errors,
                                      std::set<int> *cellsA,
                                      std::set<int> *cellsB) {
        std::vector<NativeControlPoint> points;
        points.reserve(indices.size());
        for (int idx : indices) {
            const NativeStar &pointA = match.pointsA[static_cast<size_t>(idx)];
            const NativeStar &pointB = match.pointsB[static_cast<size_t>(idx)];
            const double error = reprojection_error(H, pointA, pointB);
            // Identity association may consult only the fit-only coarse model;
            // neither validation nor final-held-out Camera residuals feed back
            // into this frozen correspondence set.
            if (!std::isfinite(error) || error > correspondenceAssociationLimit) continue;
            NativeControlPoint point;
            point.imageAIndex = i;
            point.imageBIndex = j;
            point.xA = pointA.x;
            point.yA = pointA.y;
            point.xB = pointB.x;
            point.yB = pointB.y;
            point.error = error;
            native_copy_psf_to_control_point(point, pointA, pointB);
            points.push_back(point);
            if (errors != nullptr) errors->push_back(error);
            if (cellsA != nullptr) cellsA->insert(native_star_spatial_cell(pointA, starsA, 4));
            if (cellsB != nullptr) cellsB->insert(native_star_spatial_cell(pointB, starsB, 4));
        }
        return points;
    };
    std::vector<NativeControlPoint> validationControlPoints = buildReservedPartition(
        validationIndices, nullptr, nullptr, nullptr
    );
    std::vector<double> heldOutErrors;
    std::set<int> heldOutCellsA;
    std::set<int> heldOutCellsB;
    std::vector<NativeControlPoint> heldOutControlPoints = buildReservedPartition(
        heldOutIndices, &heldOutErrors, &heldOutCellsA, &heldOutCellsB
    );
    const int heldOutOccupiedCells = static_cast<int>(std::min(heldOutCellsA.size(), heldOutCellsB.size()));
    if (validationControlPoints.size() < minimumValidation
        || heldOutControlPoints.size() < minimumHeldOut
        || heldOutOccupiedCells < minimumOccupiedCells) {
        return false;
    }

    edge.i = i;
    edge.j = j;
    edge.score = static_cast<double>(usedInliers) / std::max(1, j - i);
    if (usedRecovery) {
        // A recovered adjacent edge is the exact missing-neighbour case this
        // path is designed to resolve.  Give it enough priority to compete
        // with a weak long-range false edge while the subsequent Camera gate
        // remains the final arbiter.
        edge.score *= 3.0;
    }
    edge.rmsError = std::sqrt(sumSquared / static_cast<double>(usedInliers));
    edge.transform = H;
    edge.controlPoints = std::move(controlPoints);
    edge.method = usedRecovery ? "stars_triangle_vote_recovery" : "stars";
    edge.transformModel = seededMatch != nullptr
        ? "camera_coarse_star_verified_homography"
        : (settings.transformModel == "homography" ? "homography" : "camera_coarse_affine");
    edge.transformModelReason = seededMatch != nullptr
        ? "SIFT-seeded identities replaced by training star centroids and independently held-out star validation"
        : (settings.transformModel == "homography"
        ? "explicit star homography fit"
        : "protected camera-safe affine fit with independent held-out validation");
    edge.adaptiveCoverageAttempted = match.adaptiveCoverageAttempted;
    edge.adaptiveCoverageAccepted = match.adaptiveCoverageAccepted;
    edge.adaptiveCoverageInliers = match.adaptiveCoverageInliers;
    edge.adaptiveCoverageRejectReason = match.adaptiveCoverageRejectReason;
    edge.coverageBBoxAreaA = match.coverageBBoxAreaA;
    edge.coverageBBoxAreaB = match.coverageBBoxAreaB;
    edge.coverageGridOccupancyA = match.coverageGridOccupancyA;
    edge.coverageGridOccupancyB = match.coverageGridOccupancyB;
    edge.adaptiveBBoxAreaA = match.adaptiveBBoxAreaA;
    edge.adaptiveBBoxAreaB = match.adaptiveBBoxAreaB;
    edge.adaptiveGridOccupancyA = match.adaptiveGridOccupancyA;
    edge.adaptiveGridOccupancyB = match.adaptiveGridOccupancyB;
    edge.validationControlPoints = std::move(validationControlPoints);
    edge.heldOutControlPoints = std::move(heldOutControlPoints);
    edge.heldOutOccupiedCells = heldOutOccupiedCells;
    edge.heldOutP95 = percentile_value(heldOutErrors, 95.0);
    return true;
}

static bool compute_pair_edge(
    int i,
    int j,
    const NativeFeatureSet &featuresA,
    const NativeFeatureSet &featuresB,
    NativeMatchEdge &edge
);

static bool compute_star_pair_edge_from_sift_seed(
    int i,
    int j,
    const NativeImage &imageA,
    const NativeImage &imageB,
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarSettings &settings,
    NativeMatchEdge &edge,
    std::string &diagnostic
) {
    // Recovery is allowed to use a stretched texture view for a coarse seed;
    // only freshly re-identified star centroids survive into the returned
    // edge. Ordinary-photo SIFT remains unchanged.
    const NativeFeatureSet siftA = detect_native_texture_sift_features(imageA);
    const NativeFeatureSet siftB = detect_native_texture_sift_features(imageB);
    NativeMatchEdge siftSeed;
    const bool siftSeeded = compute_pair_edge(i, j, siftA, siftB, siftSeed);
    std::ostringstream detail;
    detail << "edge " << i << "-" << j
        << ": sift_features=" << siftA.keypoints.size()
        << "/" << siftB.keypoints.size()
        << ", sift_seed=" << (siftSeeded ? "accepted" : "failed");
    if (!siftSeeded) {
        diagnostic = detail.str();
        return false;
    }
    const NativeStarMatch seededStars = match_native_stars_from_sift_seed(
        starsA,
        starsB,
        siftSeed.transform,
        settings
    );
    detail << ", mutual_seeded_stars=" << seededStars.pointsA.size()
        << " (" << seededStars.reason << ")";
    if (!seededStars.success) {
        diagnostic = detail.str();
        return false;
    }
    bool recoveryAttempted = false;
    const bool recovered = compute_star_pair_edge(
        i,
        j,
        starsA,
        starsB,
        settings,
        edge,
        &recoveryAttempted,
        false,
        &seededStars,
        true
    );
    detail << ", final=" << (recovered ? "accepted" : "failed");
    diagnostic = detail.str();
    if (recovered) {
        edge.method = "stars_sift_seeded_recovery";
    }
    return recovered;
}

static bool compute_camera_guided_star_edge(
    int i,
    int j,
    const NativeImage &imageA,
    const NativeImage &imageB,
    const std::vector<NativeStar> &starsA,
    const std::vector<NativeStar> &starsB,
    const NativeStarMatch &match,
    const NativeStarSettings &settings,
    NativeMatchEdge &edge
) {
    if (!match.success || match.pointsA.size() != match.pointsB.size()) {
        return false;
    }
    std::vector<int> trainingIndices;
    std::vector<int> validationIndices;
    std::vector<int> heldOutIndices;
    native_split_star_matches_for_holdout(
        match, starsA, trainingIndices, validationIndices, heldOutIndices
    );
    if (trainingIndices.size() < 12 || validationIndices.size() < 4 || heldOutIndices.size() < 12) {
        return false;
    }
    std::vector<cv::Point2f> trainingA;
    std::vector<cv::Point2f> trainingB;
    trainingA.reserve(trainingIndices.size());
    trainingB.reserve(trainingIndices.size());
    for (int index : trainingIndices) {
        trainingA.emplace_back(
            static_cast<float>(match.pointsA[static_cast<size_t>(index)].x),
            static_cast<float>(match.pointsA[static_cast<size_t>(index)].y)
        );
        trainingB.emplace_back(
            static_cast<float>(match.pointsB[static_cast<size_t>(index)].x),
            static_cast<float>(match.pointsB[static_cast<size_t>(index)].y)
        );
    }
    const double fullScale = static_cast<double>(std::max({
        imageA.width, imageA.height, imageB.width, imageB.height
    })) / 2400.0;
    const double ransacThreshold = std::max(6.0 * fullScale, settings.pixelTolerance);
    cv::Mat trainingMask;
    cv::Mat trainingModel = cv::findHomography(
        trainingA,
        trainingB,
        cv::RANSAC,
        ransacThreshold,
        trainingMask,
        3000,
        0.997
    );
    if (trainingModel.empty() || trainingMask.empty()) {
        return false;
    }
    trainingModel.convertTo(trainingModel, CV_64F);

    std::vector<NativeControlPoint> training;
    std::vector<double> trainingErrors;
    auto makePoint = [&](int index) {
        NativeControlPoint point;
        point.imageAIndex = i;
        point.imageBIndex = j;
        point.xA = match.pointsA[static_cast<size_t>(index)].x;
        point.yA = match.pointsA[static_cast<size_t>(index)].y;
        point.xB = match.pointsB[static_cast<size_t>(index)].x;
        point.yB = match.pointsB[static_cast<size_t>(index)].y;
        point.error = reprojection_error(
            trainingModel,
            match.pointsA[static_cast<size_t>(index)],
            match.pointsB[static_cast<size_t>(index)]
        );
        native_copy_psf_to_control_point(
            point,
            match.pointsA[static_cast<size_t>(index)],
            match.pointsB[static_cast<size_t>(index)]
        );
        if (static_cast<size_t>(index) < match.errors.size()) {
            point.identityAssociationResidual = match.errors[static_cast<size_t>(index)];
        }
        return point;
    };
    for (int row = 0; row < static_cast<int>(trainingIndices.size()); ++row) {
        const int index = trainingIndices[static_cast<size_t>(row)];
        if (trainingMask.at<unsigned char>(row, 0) == 0) {
            continue;
        }
        NativeControlPoint point = makePoint(index);
        if (std::isfinite(point.error)) {
            trainingErrors.push_back(point.error);
            training.push_back(std::move(point));
        }
    }
    if (training.size() < 12 || trainingErrors.empty()) {
        return false;
    }
    const double trainingP95 = percentile_value(trainingErrors, 95.0);
    std::vector<double> trainingFWHM;
    trainingFWHM.reserve(training.size());
    for (const NativeControlPoint &point : training) {
        trainingFWHM.push_back(0.5 * (point.sourceFWHM + point.targetFWHM));
    }
    const double associationLimit = std::max({
        6.0 * fullScale,
        3.0 * trainingP95,
        2.5 * median_value(trainingFWHM)
    });
    auto buildReservedPartition = [&](const std::vector<int> &indices,
                                      std::vector<double> *errors,
                                      std::set<int> *cellsA,
                                      std::set<int> *cellsB) {
        std::vector<NativeControlPoint> points;
        points.reserve(indices.size());
        for (int index : indices) {
            NativeControlPoint point = makePoint(index);
            if (!std::isfinite(point.error) || point.error > associationLimit) continue;
            if (errors != nullptr) errors->push_back(point.error);
            if (cellsA != nullptr) cellsA->insert(native_star_spatial_cell(
                match.pointsA[static_cast<size_t>(index)], starsA, 4
            ));
            if (cellsB != nullptr) cellsB->insert(native_star_spatial_cell(
                match.pointsB[static_cast<size_t>(index)], starsB, 4
            ));
            points.push_back(std::move(point));
        }
        return points;
    };
    std::vector<NativeControlPoint> validation = buildReservedPartition(
        validationIndices, nullptr, nullptr, nullptr
    );
    std::vector<double> heldOutErrors;
    std::set<int> heldOutCellsA;
    std::set<int> heldOutCellsB;
    std::vector<NativeControlPoint> heldOut = buildReservedPartition(
        heldOutIndices, &heldOutErrors, &heldOutCellsA, &heldOutCellsB
    );
    const int occupiedCells = static_cast<int>(std::min(
        heldOutCellsA.size(), heldOutCellsB.size()
    ));
    if (validation.size() < 4 || heldOut.size() < 12 || occupiedCells < 4) {
        return false;
    }
    edge.i = i;
    edge.j = j;
    edge.score = static_cast<double>(training.size()) / std::max(1, j - i);
    edge.rmsError = std::sqrt(std::inner_product(
        trainingErrors.begin(), trainingErrors.end(), trainingErrors.begin(), 0.0
    ) / std::max<size_t>(trainingErrors.size(), 1));
    edge.transform = trainingModel;
    edge.controlPoints = std::move(training);
    edge.method = "stars_full_resolution_camera_identity";
    edge.transformModel = "camera_identity";
    edge.transformModelReason = "descriptor/patch identities split deterministically; training-only RANSAC validates held-out association without final Camera residuals";
    edge.coverageBBoxAreaA = match.coverageBBoxAreaA;
    edge.coverageBBoxAreaB = match.coverageBBoxAreaB;
    edge.coverageGridOccupancyA = match.coverageGridOccupancyA;
    edge.coverageGridOccupancyB = match.coverageGridOccupancyB;
    edge.adaptiveBBoxAreaA = match.adaptiveBBoxAreaA;
    edge.adaptiveBBoxAreaB = match.adaptiveBBoxAreaB;
    edge.adaptiveGridOccupancyA = match.adaptiveGridOccupancyA;
    edge.adaptiveGridOccupancyB = match.adaptiveGridOccupancyB;
    edge.adaptiveCoverageAttempted = true;
    edge.adaptiveCoverageAccepted = true;
    edge.adaptiveCoverageInliers = static_cast<int>(match.pointsA.size());
    edge.validationControlPoints = std::move(validation);
    edge.heldOutControlPoints = std::move(heldOut);
    edge.heldOutOccupiedCells = occupiedCells;
    edge.heldOutP95 = percentile_value(heldOutErrors, 95.0);
    edge.identityCandidates = match.identityCandidates;
    edge.identityAccepted = match.identityAccepted;
    edge.identityRejectedDescriptor = match.identityRejectedDescriptor;
    edge.identityRejectedPatch = match.identityRejectedPatch;
    edge.identityRejectedFWHM = match.identityRejectedFWHM;
    edge.identityRejectedFlux = match.identityRejectedFlux;
    edge.identityRejectedRatio = match.identityRejectedRatio;
    edge.identityRejectedConflict = match.identityRejectedConflict;
    edge.identityRejectedPrediction = match.identityRejectedPrediction;
    edge.identityRejectedBoundary = match.identityRejectedBoundary;
    edge.identityRejectedField = match.identityRejectedField;
    edge.identityFieldCutoff = match.identityFieldCutoff;
    edge.identityFieldMedian = match.identityFieldMedian;
    edge.identityFieldP95 = match.identityFieldP95;
    return true;
}

static bool compute_pair_edge(
    int i,
    int j,
    const NativeFeatureSet &featuresA,
    const NativeFeatureSet &featuresB,
    NativeMatchEdge &edge
) {
    if (featuresA.descriptors.rows < 4 || featuresB.descriptors.rows < 4) {
        return false;
    }

    cv::FlannBasedMatcher matcher;
    std::vector<std::vector<cv::DMatch>> knn;
    matcher.knnMatch(featuresA.descriptors, featuresB.descriptors, knn, 2);

    std::vector<cv::Point2f> pointsA;
    std::vector<cv::Point2f> pointsB;
    for (const auto &pair : knn) {
        if (pair.size() < 2) {
            continue;
        }
        const cv::DMatch &m = pair[0];
        const cv::DMatch &n = pair[1];
        if (m.distance < 0.70f * n.distance) {
            pointsA.push_back(featuresA.keypoints[static_cast<size_t>(m.queryIdx)].pt);
            pointsB.push_back(featuresB.keypoints[static_cast<size_t>(m.trainIdx)].pt);
        }
    }
    if (pointsA.size() < 4) {
        return false;
    }

    cv::Mat inlierMask;
    cv::Mat H = cv::findHomography(pointsA, pointsB, cv::RANSAC, 5.0, inlierMask);
    if (H.empty() || H.rows != 3 || H.cols != 3) {
        return false;
    }
    H.convertTo(H, CV_64F);

    // The generous first RANSAC threshold establishes overlap reliably, but
    // high-texture crops often contain a very large subpixel-consistent core.
    // Refit from that core when it is well supported so a small 0.5-5 px tail
    // is not exposed as final control points. Noisy real-world pairs retain
    // the original RANSAC solution when fewer than half of its inliers meet
    // the subpixel criterion.
    constexpr double subpixelCoreThreshold = 0.5;
    size_t initialInlierCount = 0;
    std::vector<cv::Point2d> initialPointsA;
    std::vector<cv::Point2d> initialPointsB;
    std::vector<cv::Point2d> subpixelPointsA;
    std::vector<cv::Point2d> subpixelPointsB;
    initialPointsA.reserve(pointsA.size());
    initialPointsB.reserve(pointsB.size());
    subpixelPointsA.reserve(pointsA.size());
    subpixelPointsB.reserve(pointsB.size());
    for (size_t idx = 0; idx < pointsA.size(); ++idx) {
        const bool keep = inlierMask.empty()
            || inlierMask.at<unsigned char>(static_cast<int>(idx), 0) != 0;
        if (!keep) {
            continue;
        }
        initialInlierCount += 1;
        const NativeStar source{
            static_cast<double>(pointsA[idx].x),
            static_cast<double>(pointsA[idx].y),
            0.0,
            1.0
        };
        const NativeStar target{
            static_cast<double>(pointsB[idx].x),
            static_cast<double>(pointsB[idx].y),
            0.0,
            1.0
        };
        const double error = reprojection_error(H, source, target);
        initialPointsA.emplace_back(source.x, source.y);
        initialPointsB.emplace_back(target.x, target.y);
        if (std::isfinite(error) && error <= subpixelCoreThreshold) {
            subpixelPointsA.emplace_back(source.x, source.y);
            subpixelPointsB.emplace_back(target.x, target.y);
        }
    }
    bool usingSubpixelCore = false;
    if (subpixelPointsA.size() >= 8
        && subpixelPointsA.size() * 2 >= initialInlierCount) {
        cv::Mat refined = cv::findHomography(subpixelPointsA, subpixelPointsB, 0);
        if (!refined.empty() && refined.rows == 3 && refined.cols == 3) {
            refined.convertTo(refined, CV_64F);
            const double determinant = cv::determinant(refined);
            if (cv::checkRange(refined)
                && std::isfinite(determinant)
                && std::abs(determinant) > 1e-12) {
                H = std::move(refined);
                usingSubpixelCore = true;
            }
        }
    }

    auto modelP95 = [&](const cv::Mat &model) {
        std::vector<double> errors;
        errors.reserve(initialPointsA.size());
        for (size_t idx = 0; idx < initialPointsA.size(); ++idx) {
            const NativeStar source{
                initialPointsA[idx].x,
                initialPointsA[idx].y,
                0.0,
                1.0
            };
            const NativeStar target{
                initialPointsB[idx].x,
                initialPointsB[idx].y,
                0.0,
                1.0
            };
            const double error = reprojection_error(model, source, target);
            if (std::isfinite(error)) {
                errors.push_back(error);
            }
        }
        return errors.empty()
            ? std::numeric_limits<double>::infinity()
            : percentile_value(errors, 95.0);
    };
    std::string selectedTransformModel = "homography";
    std::string transformModelReason;
    const double evaluatedHomographyP95 = modelP95(H);
    double evaluatedSimilarityP95 = std::numeric_limits<double>::quiet_NaN();
    double evaluatedPixelGridP95 = std::numeric_limits<double>::quiet_NaN();

    // Prefer a simpler similarity transform only when it explains the entire
    // homography-inlier population to subpixel accuracy and is statistically
    // indistinguishable from the projective model. This removes accumulated
    // projective drift for crop/rotation sets while retaining homography for
    // real perspective overlap.
    if (initialPointsA.size() >= 8) {
        cv::Mat similarityMask;
        cv::Mat affinePartial = cv::estimateAffinePartial2D(
            initialPointsA,
            initialPointsB,
            similarityMask,
            cv::RANSAC,
            1.0,
            5000,
            0.995,
            10
        );
        if (!affinePartial.empty() && affinePartial.rows == 2 && affinePartial.cols == 3) {
            affinePartial.convertTo(affinePartial, CV_64F);
            cv::Mat similarity = cv::Mat::eye(3, 3, CV_64F);
            affinePartial.copyTo(similarity(cv::Rect(0, 0, 3, 2)));
            evaluatedSimilarityP95 = modelP95(similarity);
            if (cv::checkRange(similarity)
                && std::isfinite(evaluatedSimilarityP95)
                && evaluatedSimilarityP95 <= subpixelCoreThreshold
                && evaluatedSimilarityP95 <= evaluatedHomographyP95 + 0.02) {
                cv::Mat selectedSimilarity = similarity;
                selectedTransformModel = "similarity";
                {
                    std::ostringstream reason;
                    reason << "selected similarity: P95 " << evaluatedSimilarityP95
                           << " px versus homography " << evaluatedHomographyP95
                           << " px; both satisfy the protected subpixel gate";
                    transformModelReason = reason.str();
                }

                // Crop tools commonly produce exact integer translations and
                // quarter-turn rotations whose fitted matrices differ only by
                // numerical noise. Snap to a signed pixel-grid transform only
                // when the observed correspondences validate the snapped form.
                cv::Mat snapped = similarity.clone();
                bool nearPixelGrid = true;
                for (int row = 0; row < 2; ++row) {
                    for (int column = 0; column < 2; ++column) {
                        const double value = similarity.at<double>(row, column);
                        const double rounded = std::round(value);
                        if (std::abs(value - rounded) > 0.002) {
                            nearPixelGrid = false;
                        }
                        snapped.at<double>(row, column) = rounded;
                    }
                    const double translation = similarity.at<double>(row, 2);
                    const double roundedTranslation = std::round(translation * 2.0) / 2.0;
                    if (std::abs(translation - roundedTranslation) > 0.05) {
                        nearPixelGrid = false;
                    }
                    snapped.at<double>(row, 2) = roundedTranslation;
                }
                const double snappedDeterminant = cv::determinant(snapped);
                if (nearPixelGrid
                    && std::isfinite(snappedDeterminant)
                    && std::abs(std::abs(snappedDeterminant) - 1.0) <= 0.005) {
                    evaluatedPixelGridP95 = modelP95(snapped);
                    if (std::isfinite(evaluatedPixelGridP95)
                        && evaluatedPixelGridP95 <= subpixelCoreThreshold
                        && evaluatedPixelGridP95 <= evaluatedSimilarityP95 + 0.02) {
                        selectedSimilarity = std::move(snapped);
                        selectedTransformModel = "pixel_grid_similarity";
                        std::ostringstream reason;
                        reason << "selected pixel-grid similarity: snapped P95 "
                               << evaluatedPixelGridP95 << " px versus similarity "
                               << evaluatedSimilarityP95
                               << " px; signed-grid coefficients were validated by inliers";
                        transformModelReason = reason.str();
                    }
                }
                H = std::move(selectedSimilarity);
                usingSubpixelCore = true;
            } else {
                std::ostringstream reason;
                reason << "kept homography: similarity P95 "
                       << number_json(evaluatedSimilarityP95)
                       << " px did not satisfy <= " << subpixelCoreThreshold
                       << " px and <= homography P95 + 0.02 (homography "
                       << number_json(evaluatedHomographyP95) << " px)";
                transformModelReason = reason.str();
            }
        } else {
            transformModelReason = "kept homography: protected similarity estimation did not produce a valid 2x3 model";
        }
    } else {
        transformModelReason = "kept homography: fewer than eight robust inliers were available for protected similarity selection";
    }

    std::vector<cv::Point2f> projected;
    cv::perspectiveTransform(pointsA, projected, H);
    double sumSquared = 0.0;
    int inliers = 0;
    std::vector<NativeControlPoint> controlPoints;
    for (size_t idx = 0; idx < pointsA.size(); ++idx) {
        const bool keep = inlierMask.empty() || inlierMask.at<unsigned char>(static_cast<int>(idx), 0) != 0;
        if (!keep) {
            continue;
        }
        const double dx = static_cast<double>(projected[idx].x - pointsB[idx].x);
        const double dy = static_cast<double>(projected[idx].y - pointsB[idx].y);
        const double error = std::sqrt(dx * dx + dy * dy);
        if (!std::isfinite(error)
            || (usingSubpixelCore && error > subpixelCoreThreshold)) {
            continue;
        }
        NativeControlPoint cp;
        cp.imageAIndex = i;
        cp.imageBIndex = j;
        cp.xA = pointsA[idx].x;
        cp.yA = pointsA[idx].y;
        cp.xB = pointsB[idx].x;
        cp.yB = pointsB[idx].y;
        cp.error = error;
        controlPoints.push_back(cp);
        sumSquared += error * error;
        inliers += 1;
    }
    if (inliers < 4) {
        return false;
    }

    edge.i = i;
    edge.j = j;
    edge.score = static_cast<double>(inliers);
    edge.rmsError = std::sqrt(sumSquared / static_cast<double>(inliers));
    edge.transform = H;
    edge.controlPoints = std::move(controlPoints);
    edge.method = "sift";
    edge.transformModel = selectedTransformModel;
    edge.transformModelReason = transformModelReason;
    edge.homographyP95 = evaluatedHomographyP95;
    edge.similarityP95 = evaluatedSimilarityP95;
    edge.pixelGridP95 = evaluatedPixelGridP95;
    return true;
}

static int native_connected_count(const std::vector<NativeMatchEdge> &edges, int n) {
    if (n <= 0) {
        return 0;
    }
    std::vector<int> parent(static_cast<size_t>(n));
    for (int idx = 0; idx < n; ++idx) {
        parent[static_cast<size_t>(idx)] = idx;
    }
    auto findRoot = [&parent](int value) {
        int x = value;
        while (parent[static_cast<size_t>(x)] != x) {
            parent[static_cast<size_t>(x)] = parent[static_cast<size_t>(parent[static_cast<size_t>(x)])];
            x = parent[static_cast<size_t>(x)];
        }
        return x;
    };
    for (const NativeMatchEdge &edge : edges) {
        int rootA = findRoot(edge.i);
        int rootB = findRoot(edge.j);
        if (rootA != rootB) {
            parent[static_cast<size_t>(rootA)] = rootB;
        }
    }
    const int root = findRoot(0);
    int count = 0;
    for (int idx = 0; idx < n; ++idx) {
        if (findRoot(idx) == root) {
            count += 1;
        }
    }
    return count;
}

static std::pair<int, int> native_edge_key(int i, int j) {
    return i <= j ? std::make_pair(i, j) : std::make_pair(j, i);
}

static bool native_build_spanning_tree(
    const std::vector<NativeMatchEdge> &candidateEdges,
    int imageCount,
    const std::set<std::pair<int, int>> &rejectedEdges,
    std::vector<NativeMatchEdge> &selected,
    std::vector<cv::Mat> &imageToPanorama
) {
    selected.clear();
    imageToPanorama.clear();
    if (imageCount <= 0) {
        return false;
    }

    std::vector<const NativeMatchEdge *> ordered;
    ordered.reserve(candidateEdges.size());
    for (const NativeMatchEdge &edge : candidateEdges) {
        if (edge.i < 0 || edge.j < 0 || edge.i >= imageCount || edge.j >= imageCount
            || edge.i == edge.j || edge.transform.empty()
            || rejectedEdges.count(native_edge_key(edge.i, edge.j)) > 0) {
            continue;
        }
        ordered.push_back(&edge);
    }
    std::stable_sort(ordered.begin(), ordered.end(), [](const NativeMatchEdge *lhs, const NativeMatchEdge *rhs) {
        if (std::abs(lhs->score - rhs->score) > 1e-9) {
            return lhs->score > rhs->score;
        }
        const int lhsSpan = std::abs(lhs->j - lhs->i);
        const int rhsSpan = std::abs(rhs->j - rhs->i);
        if (lhsSpan != rhsSpan) {
            return lhsSpan < rhsSpan;
        }
        return native_edge_key(lhs->i, lhs->j) < native_edge_key(rhs->i, rhs->j);
    });

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

    std::vector<std::vector<std::pair<int, cv::Mat>>> adjacency(static_cast<size_t>(imageCount));
    for (const NativeMatchEdge *edge : ordered) {
        const int rootA = findRoot(edge->i);
        const int rootB = findRoot(edge->j);
        if (rootA == rootB) {
            continue;
        }
        cv::Mat inverse = edge->transform.inv();
        if (inverse.empty() || !cv::checkRange(inverse)) {
            continue;
        }
        parent[static_cast<size_t>(rootA)] = rootB;
        adjacency[static_cast<size_t>(edge->i)].push_back({edge->j, edge->transform});
        adjacency[static_cast<size_t>(edge->j)].push_back({edge->i, inverse});
        selected.push_back(*edge);
        if (static_cast<int>(selected.size()) == imageCount - 1) {
            break;
        }
    }
    if (static_cast<int>(selected.size()) != imageCount - 1) {
        selected.clear();
        return false;
    }

    imageToPanorama.resize(static_cast<size_t>(imageCount));
    std::vector<bool> visited(static_cast<size_t>(imageCount), false);
    imageToPanorama[0] = cv::Mat::eye(3, 3, CV_64F);
    visited[0] = true;
    std::vector<int> queue = {0};
    for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
        const int current = queue[cursor];
        for (const auto &neighborAndTransform : adjacency[static_cast<size_t>(current)]) {
            const int neighbor = neighborAndTransform.first;
            if (visited[static_cast<size_t>(neighbor)]) {
                continue;
            }
            imageToPanorama[static_cast<size_t>(neighbor)] =
                imageToPanorama[static_cast<size_t>(current)] * neighborAndTransform.second.inv();
            if (imageToPanorama[static_cast<size_t>(neighbor)].empty()
                || !cv::checkRange(imageToPanorama[static_cast<size_t>(neighbor)])) {
                selected.clear();
                imageToPanorama.clear();
                return false;
            }
            visited[static_cast<size_t>(neighbor)] = true;
            queue.push_back(neighbor);
        }
    }
    return std::find(visited.begin(), visited.end(), false) == visited.end();
}

static void native_apply_selected_edges(
    NativeResult &result,
    const std::vector<NativeMatchEdge> &selected
) {
    result.selectedEdges.clear();
    result.controlPoints.clear();
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
        selectedEdge.adaptiveCoverageAttempted = edge.adaptiveCoverageAttempted;
        selectedEdge.adaptiveCoverageAccepted = edge.adaptiveCoverageAccepted;
        selectedEdge.adaptiveCoverageInliers = edge.adaptiveCoverageInliers;
        selectedEdge.adaptiveCoverageRejectReason = edge.adaptiveCoverageRejectReason;
        selectedEdge.coverageBBoxAreaA = edge.coverageBBoxAreaA;
        selectedEdge.coverageBBoxAreaB = edge.coverageBBoxAreaB;
        selectedEdge.coverageGridOccupancyA = edge.coverageGridOccupancyA;
        selectedEdge.coverageGridOccupancyB = edge.coverageGridOccupancyB;
        selectedEdge.adaptiveBBoxAreaA = edge.adaptiveBBoxAreaA;
        selectedEdge.adaptiveBBoxAreaB = edge.adaptiveBBoxAreaB;
        selectedEdge.adaptiveGridOccupancyA = edge.adaptiveGridOccupancyA;
        selectedEdge.adaptiveGridOccupancyB = edge.adaptiveGridOccupancyB;
        selectedEdge.validationControlPoints = edge.validationControlPoints;
        selectedEdge.heldOutControlPoints = edge.heldOutControlPoints;
        selectedEdge.fitObservationCount = static_cast<int>(edge.controlPoints.size());
        selectedEdge.heldOutOccupiedCells = edge.heldOutOccupiedCells;
        selectedEdge.heldOutP95 = edge.heldOutP95;
        selectedEdge.identityCandidates = edge.identityCandidates;
        selectedEdge.identityAccepted = edge.identityAccepted;
        selectedEdge.identityRejectedDescriptor = edge.identityRejectedDescriptor;
        selectedEdge.identityRejectedPatch = edge.identityRejectedPatch;
        selectedEdge.identityRejectedFWHM = edge.identityRejectedFWHM;
        selectedEdge.identityRejectedFlux = edge.identityRejectedFlux;
        selectedEdge.identityRejectedRatio = edge.identityRejectedRatio;
        selectedEdge.identityRejectedConflict = edge.identityRejectedConflict;
        selectedEdge.identityRejectedPrediction = edge.identityRejectedPrediction;
        selectedEdge.identityRejectedBoundary = edge.identityRejectedBoundary;
        selectedEdge.identityRejectedField = edge.identityRejectedField;
        selectedEdge.identityFieldCutoff = edge.identityFieldCutoff;
        selectedEdge.identityFieldMedian = edge.identityFieldMedian;
        selectedEdge.identityFieldP95 = edge.identityFieldP95;
        result.selectedEdges.push_back(std::move(selectedEdge));
        result.controlPoints.insert(
            result.controlPoints.end(),
            edge.controlPoints.begin(),
            edge.controlPoints.end()
        );
    }
}

#endif  // PANOLUME_HAS_OPENCV_HEADERS
