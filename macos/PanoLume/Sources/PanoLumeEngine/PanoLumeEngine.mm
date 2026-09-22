#include "PanoLumeEngine.h"
#include "AstroIdentityMatcher.hpp"
#include "AstroPSFModel.hpp"
#include "AstroSkyMask.hpp"
#include "LocalWarpModel.hpp"
#include "NativeJSONRequest.hpp"
#include "SharedImageStorage.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CommonCrypto/CommonDigest.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <chrono>
#include <deque>
#include <dlfcn.h>
#include <fcntl.h>
#include <iomanip>
#include <fstream>
#include <limits.h>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <random>
#include <sstream>
#include <set>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#if __has_include(<sys/resource.h>)
#define PANOLUME_HAS_RUSAGE 1
#include <sys/resource.h>
#else
#define PANOLUME_HAS_RUSAGE 0
#endif

#if __has_include(<opencv2/core.hpp>)
#define PANOLUME_HAS_OPENCV_HEADERS 1
#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgproc.hpp>
#pragma push_macro("NO")
#undef NO
#include <opencv2/stitching/detail/seam_finders.hpp>
#pragma pop_macro("NO")
#else
#define PANOLUME_HAS_OPENCV_HEADERS 0
#endif

#if __has_include(<libraw/libraw.h>) || __has_include(<libraw.h>)
#define PANOLUME_HAS_LIBRAW_HEADERS 1
#if __has_include(<libraw/libraw.h>)
#include <libraw/libraw.h>
#else
#include <libraw.h>
#endif
#else
#define PANOLUME_HAS_LIBRAW_HEADERS 0
#endif

#if __has_include(<ceres/ceres.h>)
#define PANOLUME_HAS_CERES_HEADERS 1
#include <ceres/ceres.h>
#include <ceres/rotation.h>
#else
#define PANOLUME_HAS_CERES_HEADERS 0
#endif

#if __has_include(<Eigen/Core>) || __has_include(<eigen3/Eigen/Core>)
#define PANOLUME_HAS_EIGEN_HEADERS 1
#else
#define PANOLUME_HAS_EIGEN_HEADERS 0
#endif

#if __has_include(<tiffio.h>)
#define PANOLUME_HAS_LIBTIFF_HEADERS 1
#include <tiffio.h>
#else
#define PANOLUME_HAS_LIBTIFF_HEADERS 0
#endif

#if __has_include(<Metal/Metal.h>)
#define PANOLUME_HAS_METAL_HEADERS 1
#else
#define PANOLUME_HAS_METAL_HEADERS 0
#endif

struct NativeImage {
    std::string handle;
    std::string path;
    // width/height are the decoded working dimensions used by alignment and
    // control-point coordinates. originalWidth/originalHeight preserve the
    // oriented source dimensions before RAW half-size and preview downscaling.
    int width = 0;
    int height = 0;
    int originalWidth = 0;
    int originalHeight = 0;
    int channels = 3;
    int bitDepth = 8;
    double focalLength35mm = 0.0;
    double focalLengthMM = 0.0;
    double apertureFNumber = 0.0;
    std::string cameraMake;
    std::string cameraModel;
    std::string lensName;
    std::string focalMetadataSource;
    std::string captureDateTimeOriginal;
    std::string captureMetadataSource;
    std::string status = "not_loaded";
    std::string unsupportedReason;
    panolume::SharedFloatPixels pixels;
    // Full-resolution RAW export keeps LibRaw's native 16-bit RGB storage
    // until it is written into a temporary spool.  Preview code continues to
    // use normalized float pixels, so the two representations never coexist
    // for a full source image.
    std::shared_ptr<void> native16Storage;
    const uint16_t *native16Pixels = nullptr;
    std::string native16SpoolPath;
};

static std::string native_base64_encode(const std::vector<unsigned char> &bytes) {
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string encoded;
    encoded.reserve(((bytes.size() + 2) / 3) * 4);
    for (size_t index = 0; index < bytes.size(); index += 3) {
        const uint32_t first = bytes[index];
        const uint32_t second = index + 1 < bytes.size() ? bytes[index + 1] : 0;
        const uint32_t third = index + 2 < bytes.size() ? bytes[index + 2] : 0;
        const uint32_t packed = (first << 16) | (second << 8) | third;
        encoded.push_back(alphabet[(packed >> 18) & 0x3f]);
        encoded.push_back(alphabet[(packed >> 12) & 0x3f]);
        encoded.push_back(index + 1 < bytes.size() ? alphabet[(packed >> 6) & 0x3f] : '=');
        encoded.push_back(index + 2 < bytes.size() ? alphabet[packed & 0x3f] : '=');
    }
    return encoded;
}

static std::string native_worst_star_patch_data_url(
    const NativeImage &image,
    double centerX,
    double centerY
) {
    constexpr int side = 15;
    constexpr int radius = side / 2;
    if (image.width <= 0 || image.height <= 0 || image.channels < 3
        || image.pixels.size() < static_cast<size_t>(image.width * image.height * image.channels)
        || !std::isfinite(centerX) || !std::isfinite(centerY)) {
        return "";
    }
    const int roundedX = static_cast<int>(std::llround(centerX));
    const int roundedY = static_cast<int>(std::llround(centerY));
    std::array<double, side * side> luminance{};
    std::vector<double> valid;
    valid.reserve(side * side);
    for (int patchY = 0; patchY < side; ++patchY) {
        for (int patchX = 0; patchX < side; ++patchX) {
            const int x = roundedX + patchX - radius;
            const int y = roundedY + patchY - radius;
            if (x < 0 || y < 0 || x >= image.width || y >= image.height) continue;
            const size_t offset = (
                static_cast<size_t>(y) * static_cast<size_t>(image.width)
                + static_cast<size_t>(x)
            ) * static_cast<size_t>(image.channels);
            const double value =
                0.2126 * static_cast<double>(image.pixels[offset])
                + 0.7152 * static_cast<double>(image.pixels[offset + 1])
                + 0.0722 * static_cast<double>(image.pixels[offset + 2]);
            if (!std::isfinite(value)) continue;
            luminance[static_cast<size_t>(patchY * side + patchX)] = value;
            valid.push_back(value);
        }
    }
    if (valid.size() < 9) return "";
    std::sort(valid.begin(), valid.end());
    const double black = valid[static_cast<size_t>(std::floor((valid.size() - 1) * 0.05))];
    const double white = valid[static_cast<size_t>(std::floor((valid.size() - 1) * 0.995))];
    const double range = std::max(white - black, 1e-9);
    const std::string header = "P5\n15 15\n255\n";
    std::vector<unsigned char> pgm(header.begin(), header.end());
    pgm.reserve(header.size() + side * side);
    for (double value : luminance) {
        const double normalized = std::max(0.0, std::min(1.0, (value - black) / range));
        pgm.push_back(static_cast<unsigned char>(std::llround(normalized * 255.0)));
    }
    return "data:image/x-portable-graymap;base64," + native_base64_encode(pgm);
}

struct NativeControlPoint {
    int imageAIndex = 0;
    int imageBIndex = 0;
    double xA = 0.0;
    double yA = 0.0;
    double xB = 0.0;
    double yB = 0.0;
    double error = 0.0;
    bool isManual = false;
    double sourceFWHM = 0.0;
    double targetFWHM = 0.0;
    double sourceCovarianceXX = 0.0;
    double sourceCovarianceXY = 0.0;
    double sourceCovarianceYY = 0.0;
    double targetCovarianceXX = 0.0;
    double targetCovarianceXY = 0.0;
    double targetCovarianceYY = 0.0;
    double sourcePSFSignalToNoise = 0.0;
    double targetPSFSignalToNoise = 0.0;
    double sourcePSFNormalizedRMS = 0.0;
    double targetPSFNormalizedRMS = 0.0;
    double identityAssociationResidual = std::numeric_limits<double>::quiet_NaN();
};

struct NativeSelectedEdge {
    int i = 0;
    int j = 0;
    double score = 0.0;
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
    int fitObservationCount = 0;
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

struct NativeCameraParams {
    std::array<double, 3> rotation = {0.0, 0.0, 0.0};
    std::array<double, 3> translation = {0.0, 0.0, 0.0};
    double focalLength = 1000.0;
    double k1 = 0.0;
    double k2 = 0.0;
    double k3 = 0.0;
    double p1 = 0.0;
    double p2 = 0.0;
    // Normalized offsets from the image center. Zero preserves results from
    // older schemas; +/-0.05 is the optimization bound for new lens models.
    double principalOffsetX = 0.0;
    double principalOffsetY = 0.0;
};

struct NativeLensCalibrationPrior {
    bool available = false;
    std::string profileName;
    std::string cameraMake;
    std::string lensName;
    std::string sha256;
    std::string warning;
    bool cameraMakeMismatch = false;
    double priorWeight = 0.0;
    double focalScale = 1.0;
    std::array<double, 5> distortion = {0.0, 0.0, 0.0, 0.0, 0.0};
    std::array<double, 2> principal = {0.0, 0.0};
    double conversionMaxErrorPixels = std::numeric_limits<double>::quiet_NaN();
};

static NativeLensCalibrationPrior native_lens_calibration_prior_from_request(
    const panolume::JSONRequest &request
) {
    panolume::JSONRequest settings = request.object("settings");
    panolume::JSONRequest prior = settings.valid()
        ? settings.object("lensCalibrationPrior")
        : request.object("lensCalibrationPrior");
    NativeLensCalibrationPrior result;
    if (!prior.valid() || prior.integer("schemaVersion", 0) != 1) return result;
    result.profileName = prior.string("profileName");
    result.cameraMake = prior.string("cameraMake");
    result.lensName = prior.string("lensName");
    result.sha256 = prior.string("sha256");
    result.warning = prior.string("warning");
    result.cameraMakeMismatch = prior.boolean("cameraMakeMismatch", false);
    result.priorWeight = std::max(0.0, std::min(1.0, prior.number("priorWeight", 0.0)));
    result.focalScale = prior.number("convertedFocalScale", 1.0);
    result.distortion = {
        prior.number("convertedK1", 0.0),
        prior.number("convertedK2", 0.0),
        prior.number("convertedK3", 0.0),
        prior.number("convertedP1", 0.0),
        prior.number("convertedP2", 0.0)
    };
    result.principal = {
        prior.number("convertedPrincipalOffsetX", 0.0),
        prior.number("convertedPrincipalOffsetY", 0.0)
    };
    result.conversionMaxErrorPixels = prior.number(
        "conversionMaxErrorPixels", std::numeric_limits<double>::quiet_NaN()
    );
    result.available = !result.profileName.empty()
        && result.sha256.size() == 64
        && std::isfinite(result.focalScale) && result.focalScale > 0.5 && result.focalScale < 2.0
        && std::isfinite(result.conversionMaxErrorPixels)
        && result.conversionMaxErrorPixels <= 0.05 + 1e-9
        && std::all_of(result.distortion.begin(), result.distortion.end(), [](double value) {
            return std::isfinite(value);
        })
        && std::all_of(result.principal.begin(), result.principal.end(), [](double value) {
            return std::isfinite(value) && std::abs(value) <= 0.05 + 1e-9;
        });
    return result;
}

struct NativeCameraModelReport {
    bool attempted = false;
    bool solverSucceeded = false;
    bool success = false;
    bool qualityGatePassed = false;
    std::string reason;
    std::string focalSource;
    std::string qualityGateReason;
    int inputControlPoints = 0;
    int outputControlPoints = 0;
    double initialFocal = 0.0;
    double optimizedFocal = 0.0;
    bool distortionOptimized = false;
    std::array<double, 5> initialDistortion = {0.0, 0.0, 0.0, 0.0, 0.0};
    std::array<double, 5> optimizedDistortion = {0.0, 0.0, 0.0, 0.0, 0.0};
    double initialRms = 0.0;
    double optimizedRms = 0.0;
    double selectedPairP95 = 0.0;
    int worstSelectedEdgeI = -1;
    int worstSelectedEdgeJ = -1;
    double robustThreshold = 5.0;
    int robustRounds = 0;
    int robustMaxRounds = 0;
    int robustRejected = 0;
    std::string robustStopReason;
    std::string solverSummary;
};

struct NativeCameraTreeAttemptReport {
    int attempt = 0;
    bool success = false;
    double optimizedRms = 0.0;
    double selectedPairP95 = 0.0;
    int worstEdgeI = -1;
    int worstEdgeJ = -1;
    std::string reason;
    std::vector<std::pair<int, int>> selectedEdges;
};

struct NativeManualPointFilteringReport {
    bool available = false;
    int input = 0;
    int accepted = 0;
    int rejected = 0;
    std::string reason;
};

struct StretchParams {
    bool valid = false;
    double black = 0.0;
    double white = 1.0;
    double gamma = 0.45;
};

struct NativeDisplayStretchCache {
    bool computed = false;
    double blackPercentile = 0.5;
    double whitePercentile = 99.7;
    double gamma = 0.45;
    StretchParams params;
};

struct NativeResidualSummary {
    int count = 0;
    double rms = std::numeric_limits<double>::quiet_NaN();
    double p95 = std::numeric_limits<double>::quiet_NaN();
};

struct NativeStarProjectionAlignmentReport {
    bool available = false;
    std::string reason;
    int attemptedStars = 0;
    int projectedInBounds = 0;
    NativeResidualSummary nearest;
    NativeResidualSummary mutual;
    NativeResidualSummary highConfidence;
};

struct NativeHeldOutGridReport {
    int column = 0;
    int row = 0;
    int count = 0;
    double p95 = std::numeric_limits<double>::quiet_NaN();
    double mappedFWHM = std::numeric_limits<double>::quiet_NaN();
    double riskRatio = std::numeric_limits<double>::quiet_NaN();
    bool effective = false;
};

struct NativeResidualDirectionBucketReport {
    std::string band;
    int count = 0;
    double radialP95 = std::numeric_limits<double>::quiet_NaN();
    double tangentialP95 = std::numeric_limits<double>::quiet_NaN();
};

struct NativeWorstAstroObservationReport {
    double error = std::numeric_limits<double>::quiet_NaN();
    double mappedFWHM = std::numeric_limits<double>::quiet_NaN();
    double sourceX = std::numeric_limits<double>::quiet_NaN();
    double sourceY = std::numeric_limits<double>::quiet_NaN();
    double targetX = std::numeric_limits<double>::quiet_NaN();
    double targetY = std::numeric_limits<double>::quiet_NaN();
    double sourcePSFSignalToNoise = std::numeric_limits<double>::quiet_NaN();
    double targetPSFSignalToNoise = std::numeric_limits<double>::quiet_NaN();
    double sourcePSFNormalizedRMS = std::numeric_limits<double>::quiet_NaN();
    double targetPSFNormalizedRMS = std::numeric_limits<double>::quiet_NaN();
    double identityAssociationResidual = std::numeric_limits<double>::quiet_NaN();
    int patchSide = 0;
    std::string sourcePatchDataURL;
    std::string targetPatchDataURL;
};

struct NativeHeldOutPairReport {
    int i = 0;
    int j = 0;
    int count = 0;
    int occupiedCells = 0;
    int effectiveCells = 0;
    int lowSupportCells = 0;
    double p95 = std::numeric_limits<double>::quiet_NaN();
    double mappedFWHM = std::numeric_limits<double>::quiet_NaN();
    double pairRiskRatio = std::numeric_limits<double>::quiet_NaN();
    double worstGridRiskRatio = std::numeric_limits<double>::quiet_NaN();
    bool passed = false;
    std::string reason;
    std::vector<NativeHeldOutGridReport> grids;
    std::vector<NativeResidualDirectionBucketReport> residualDirectionBuckets;
    std::vector<NativeWorstAstroObservationReport> worstObservations;
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

struct NativePSFFitAudit {
    int imageIndex = -1;
    int preliminaryCandidates = 0;
    int selectedForFit = 0;
    int accepted = 0;
    double signalToNoiseP05 = std::numeric_limits<double>::quiet_NaN();
    double signalToNoiseMedian = std::numeric_limits<double>::quiet_NaN();
    double normalizedRMSMedian = std::numeric_limits<double>::quiet_NaN();
    double normalizedRMSP95 = std::numeric_limits<double>::quiet_NaN();
    std::map<std::string, int> rejectedReasons;
};

struct NativeLensModelCandidateReport {
    std::string model;
    bool solverSucceeded = false;
    bool accepted = false;
    double worstPairP95 = std::numeric_limits<double>::quiet_NaN();
    double worstGridRiskRatio = std::numeric_limits<double>::quiet_NaN();
    double heldOutImprovement = 0.0;
    std::string reason;
};

struct NativeAstroRefinementReport {
    std::string state = "not_required";
    bool qualityGatePassed = false;
    std::string reason;
    std::string lensModel = "rotation_shared_focal";
    std::string evaluationPartition = "final_held_out";
    std::string residualFrame = "final_projection_pixels_symmetric";
    int fitObservations = 0;
    int validationObservations = 0;
    int finalHeldOutObservations = 0;
    bool lensPriorAvailable = false;
    bool lensPriorRequired = false;
    std::string lensPriorSHA256;
    std::string lensPriorWarning;
    double lensPriorWeight = 0.0;
    double lensPriorConversionMaxErrorPixels = std::numeric_limits<double>::quiet_NaN();
    std::vector<NativeHeldOutPairReport> pairs;
    std::vector<NativeLensModelCandidateReport> lensModels;
    std::vector<NativePSFFitAudit> psfFits;
    panolume::LocalWarpFitReport localWarp;
};

struct NativeGuidedPairReport {
    int i = 0;
    int j = 0;
    int sourceStars = 0;
    int targetStars = 0;
    int candidateMatches = 0;
    int addedControlPoints = 0;
    double thresholdPx = 0.0;
    std::string reason;
};

struct NativeGuidedRefinementReport {
    bool enabled = false;
    bool accepted = false;
    int inputControlPoints = 0;
    int outputControlPoints = 0;
    int addedControlPoints = 0;
    double currentRms = 0.0;
    double candidateRms = 0.0;
    std::string reason;
    std::vector<NativeGuidedPairReport> pairs;
};

struct NativeLocalPairReport {
    int i = 0;
    int j = 0;
    int sourceStars = 0;
    int targetStars = 0;
    int eligibleSources = 0;
    int candidateMatches = 0;
    int addedControlPoints = 0;
    int rejectedLowEvidence = 0;
    int rejectedDuplicate = 0;
    int clusterCandidates = 0;
    int clusterSelected = 0;
    double searchRadiusPx = 0.0;
    double evidenceThreshold = 0.0;
    double offsetX = 0.0;
    double offsetY = 0.0;
    std::string reason;
};

struct NativeLocalRefinementReport {
    bool enabled = false;
    bool accepted = false;
    int inputControlPoints = 0;
    int outputControlPoints = 0;
    int addedControlPoints = 0;
    int trainControlPoints = 0;
    int validationControlPoints = 0;
    double currentValidationRms = 0.0;
    double candidateValidationRms = 0.0;
    double currentBaseRms = 0.0;
    double candidateBaseRms = 0.0;
    double finalBaseRms = 0.0;
    std::string reason;
    std::vector<NativeLocalPairReport> pairs;
};

struct NativeTexturePairReport {
    int i = 0;
    int j = 0;
    int sourceFeatures = 0;
    int targetFeatures = 0;
    int rawMatches = 0;
    int geometryConsistentMatches = 0;
    int candidateControlPoints = 0;
    int addedControlPoints = 0;
    double thresholdPx = 0.0;
    std::string reason;
};

struct NativeTextureRefinementReport {
    bool enabled = false;
    bool accepted = false;
    int inputControlPoints = 0;
    int outputControlPoints = 0;
    int addedControlPoints = 0;
    int trainControlPoints = 0;
    int validationControlPoints = 0;
    double currentValidationRms = 0.0;
    double candidateValidationRms = 0.0;
    double currentBaseRms = 0.0;
    double candidateBaseRms = 0.0;
    std::string reason;
    std::vector<int> featureCounts;
    std::vector<NativeTexturePairReport> pairs;
};

struct NativeOutputBoundsReport {
    bool valid = false;
    int rawWidth = 0;
    int rawHeight = 0;
    int width = 0;
    int height = 0;
    int pixels = 0;
    double scale = 1.0;
    double projectionScale = 1.0;
    double minU = 0.0;
    double minV = 0.0;
    double maxU = 0.0;
    double maxV = 0.0;
    int maxOutputPixels = 32000000;
    int maxOutputSide = 9000;
};

struct NativeCameraProjectionReport {
    bool attempted = false;
    bool success = false;
    bool primaryPreview = false;
    std::string reason;
};

struct NativeResult {
    std::string handle;
    std::vector<std::string> paths;
    std::vector<std::string> imageHandles;
    int width = 0;
    int height = 0;
    int bitDepth = 0;
    std::string projection = "equirectangular";
    std::string geometry = "unimplemented";
    std::vector<float> panoramaPixels;
    std::vector<unsigned char> panoramaCoverage;
    std::vector<NativeControlPoint> controlPoints;
    std::vector<NativeSelectedEdge> selectedEdges;
    std::vector<NativeCameraParams> cameraParams;
    std::vector<NativeCameraParams> baseCameraParams;
    NativeCameraModelReport cameraModelReport;
    NativeGuidedRefinementReport guidedRefinementReport;
    NativeLocalRefinementReport localRefinementReport;
    NativeTextureRefinementReport textureRefinementReport;
    NativeOutputBoundsReport outputBounds;
    NativeCameraProjectionReport cameraProjectionReport;
    NativeManualPointFilteringReport manualPointFilteringReport;
    NativeStarProjectionAlignmentReport starProjectionAlignmentReport;
    std::string starProjectionAlignmentJson;
    NativeAstroRefinementReport astroRefinementReport;
    panolume::LocalWarpModel localWarpModel;
    std::string astroRefinementJsonOverride;
    std::vector<int> starCounts;
    std::string previewStatus = "not_run";
    std::string projectionGeometryState = "homography_diagnostic";
    std::string previewFailureReason;
    std::string alignmentFamily;
    std::string astroSkyMode = "auto_sky";
    bool geometryGatePassed = false;
    std::string geometryGateReason = "geometry has not been evaluated";
    std::string reoptimizationMethod;
    int starRecoveryAttempts = 0;
    int starRecoveryAccepted = 0;
    std::vector<std::string> starRecoveryDiagnostics;
    std::vector<std::pair<int, int>> rejectedCameraEdges;
    std::vector<NativeCameraTreeAttemptReport> cameraTreeAttempts;
    std::string blendMode = "feather";
    std::string blendEngine;
    std::string sourceOwnershipJson;
    std::string previewRendererRequested = "auto";
    std::string previewRendererUsed = "opencv_cpu";
    bool previewRendererFallback = false;
    std::string previewRendererFallbackReason;
    std::string exportProfileJson;
    std::string inputOrderUsed = "original";
    bool inputOrderAutoCorrected = false;
    std::string inputOrderCandidatesJson;
    std::string inputOrderCanonicalJson;
    bool hasProjectionAdjustment = false;
    std::array<double, 3> projectionAdjustmentDegrees = {0.0, 0.0, 0.0};
    NativeDisplayStretchCache displayStretchCache;
};

struct PanoLumeContext {
    std::atomic<unsigned long long> nextJobId{1};
    std::atomic<unsigned long long> nextResultId{1};
    std::atomic<unsigned long long> nextImageId{1};
    std::atomic<unsigned long long> projectionPreviewVersion{1};
    std::mutex operationMutex;
    std::mutex cancellationMutex;
    std::map<unsigned long long, bool> cancelledJobs;
    std::map<std::string, NativeImage> images;
    std::map<std::string, NativeResult> results;
    std::set<std::string> transientProjectionResultHandles;
    std::map<std::string, std::vector<NativeImage>> dragPreviewImageCache;
    std::map<std::string, std::vector<NativeImage>> dragPreviewSourceMetadataCache;
    std::map<std::string, std::vector<NativeCameraParams>> dragPreviewCameraCache;
};

struct DependencyProbe {
    std::string kind;
    std::string displayName;
    bool headerAvailable = false;
    bool runtimeAvailable = false;
    bool runtimeRequired = true;
    bool requiredForParity = true;
    std::vector<std::string> headerCandidates;
    std::vector<std::string> runtimeCandidates;
    std::string notes;

    bool available() const {
        return headerAvailable && (!runtimeRequired || runtimeAvailable);
    }
};

static std::string json_escape(const std::string &value) {
    std::ostringstream out;
    for (char ch : value) {
        switch (ch) {
            case '\\': out << "\\\\"; break;
            case '"': out << "\\\""; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (static_cast<unsigned char>(ch) < 0x20) {
                    out << "\\u00";
                    const char *hex = "0123456789abcdef";
                    out << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
                } else {
                    out << ch;
                }
        }
    }
    return out.str();
}

static char *copy_json(const std::string &json) {
    char *result = static_cast<char *>(std::malloc(json.size() + 1));
    if (!result) {
        return nullptr;
    }
    std::memcpy(result, json.c_str(), json.size() + 1);
    return result;
}

static void emit_progress(PanoLumeProgressCallback progress, void *userData, const char *stage, double fraction) {
    if (progress) {
        progress(stage, fraction, userData);
    }
}

static std::string bool_json(bool value) {
    return value ? "true" : "false";
}

static std::string number_json(double value) {
    if (!std::isfinite(value)) {
        return "null";
    }
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<double>::max_digits10) << value;
    return out.str();
}

static double current_peak_memory_mb() {
#if PANOLUME_HAS_RUSAGE
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss <= 0) {
        return -1.0;
    }
#if defined(__APPLE__)
    return static_cast<double>(usage.ru_maxrss) / (1024.0 * 1024.0);
#else
    return static_cast<double>(usage.ru_maxrss) / 1024.0;
#endif
#else
    return -1.0;
#endif
}

static double current_resident_memory_mb() {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(
            mach_task_self(),
            MACH_TASK_BASIC_INFO,
            reinterpret_cast<task_info_t>(&info),
            &count
        ) != KERN_SUCCESS) {
        return -1.0;
    }
    return static_cast<double>(info.resident_size) / (1024.0 * 1024.0);
#else
    return -1.0;
#endif
}

struct NativeWorkingSetStats {
    double startResidentMB = current_resident_memory_mb();
    double sampledPeakResidentMB = startResidentMB;
    uint64_t spoolBytes = 0;
    uint64_t mappedSourceBytes = 0;
    uint64_t peakMappedSourceBytes = 0;
    uint64_t activeSourceLeases = 0;
    uint64_t peakActiveSourceLeases = 0;
    uint64_t sourceCacheHits = 0;
    uint64_t sourceCacheMisses = 0;
    uint64_t requestedBudgetBytes = 0;
    uint64_t effectiveBudgetBytes = 0;
    std::string cleanupOutcome = "not_required";

    void sample() {
        const double resident = current_resident_memory_mb();
        if (std::isfinite(resident) && resident > sampledPeakResidentMB) {
            sampledPeakResidentMB = resident;
        }
    }

    void acquireSource(uint64_t bytes, bool cacheHit = false) {
        mappedSourceBytes += bytes;
        peakMappedSourceBytes = std::max(peakMappedSourceBytes, mappedSourceBytes);
        activeSourceLeases += 1;
        peakActiveSourceLeases = std::max(peakActiveSourceLeases, activeSourceLeases);
        if (cacheHit) {
            sourceCacheHits += 1;
        } else {
            sourceCacheMisses += 1;
        }
        sample();
    }

    void releaseSource(uint64_t bytes) {
        mappedSourceBytes = bytes > mappedSourceBytes ? 0 : mappedSourceBytes - bytes;
        if (activeSourceLeases > 0) {
            activeSourceLeases -= 1;
        }
        sample();
    }
};

class NativeSourceLease {
public:
    NativeSourceLease(NativeWorkingSetStats *stats, uint64_t bytes, bool cacheHit = false)
        : stats_(stats), bytes_(bytes) {
        if (stats_ && bytes_ > 0) {
            stats_->acquireSource(bytes_, cacheHit);
        }
    }

    NativeSourceLease(const NativeSourceLease &) = delete;
    NativeSourceLease &operator=(const NativeSourceLease &) = delete;

    ~NativeSourceLease() {
        if (stats_ && bytes_ > 0) {
            stats_->releaseSource(bytes_);
        }
    }

private:
    NativeWorkingSetStats *stats_ = nullptr;
    uint64_t bytes_ = 0;
};

static uint64_t native_image_storage_bytes(const NativeImage &image) {
    if (image.width <= 0 || image.height <= 0 || image.channels <= 0) {
        return 0;
    }
    const uint64_t samples = static_cast<uint64_t>(image.width)
        * static_cast<uint64_t>(image.height)
        * static_cast<uint64_t>(image.channels);
    return image.native16Pixels != nullptr
        ? samples * sizeof(uint16_t)
        : static_cast<uint64_t>(image.pixels.size()) * sizeof(float);
}

static void append_working_set_profile_json(
    std::string &profileJson,
    NativeWorkingSetStats &stats
) {
    stats.sample();
    if (profileJson.empty() || profileJson.back() != '}') {
        return;
    }
    profileJson.pop_back();
    std::ostringstream fields;
    fields << ",\"operation_start_rss_mb\":" << number_json(stats.startResidentMB);
    fields << ",\"operation_peak_rss_mb\":" << number_json(stats.sampledPeakResidentMB);
    const double delta = std::isfinite(stats.startResidentMB) && std::isfinite(stats.sampledPeakResidentMB)
        ? std::max(0.0, stats.sampledPeakResidentMB - stats.startResidentMB)
        : std::numeric_limits<double>::quiet_NaN();
    fields << ",\"operation_peak_rss_delta_mb\":" << number_json(delta);
    fields << ",\"spool_bytes_peak\":" << stats.spoolBytes;
    fields << ",\"mapped_source_bytes_peak\":" << stats.peakMappedSourceBytes;
    fields << ",\"active_source_leases_peak\":" << stats.peakActiveSourceLeases;
    fields << ",\"source_cache_hits\":" << stats.sourceCacheHits;
    fields << ",\"source_cache_misses\":" << stats.sourceCacheMisses;
    fields << ",\"working_set_budget_requested_mb\":"
        << static_cast<double>(stats.requestedBudgetBytes) / (1024.0 * 1024.0);
    fields << ",\"working_set_budget_effective_mb\":"
        << static_cast<double>(stats.effectiveBudgetBytes) / (1024.0 * 1024.0);
    fields << ",\"cleanup_outcome\":\"" << json_escape(stats.cleanupOutcome) << "\"}";
    profileJson += fields.str();
}

static uint64_t native_effective_working_set_budget_bytes(int requestedMB) {
    constexpr uint64_t mib = 1024ULL * 1024ULL;
    if (requestedMB > 0) {
        return static_cast<uint64_t>(requestedMB) * mib;
    }
    uint64_t physicalBytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
    size_t physicalSize = sizeof(physicalBytes);
    if (sysctlbyname("hw.memsize", &physicalBytes, &physicalSize, nullptr, 0) != 0 || physicalBytes == 0) {
        physicalBytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
    }
    const uint64_t automaticMB = std::max<uint64_t>(512, std::min<uint64_t>(2048, physicalBytes / mib / 8));
    return automaticMB * mib;
}

static void append_peak_memory_json(std::ostringstream &out, double peakMemoryMB) {
    out << "\"peak_memory_mb\":";
    if (std::isfinite(peakMemoryMB) && peakMemoryMB > 0.0) {
        out << peakMemoryMB;
    } else {
        out << "null";
    }
}

static bool can_dlopen_any(const std::vector<std::string> &candidates) {
    for (const std::string &candidate : candidates) {
        void *handle = dlopen(candidate.c_str(), RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            dlclose(handle);
            return true;
        }
    }
    return false;
}

static std::string json_string_array(const std::vector<std::string> &values) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < values.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << "\"" << json_escape(values[i]) << "\"";
    }
    out << "]";
    return out.str();
}

static std::vector<DependencyProbe> dependency_probes() {
    std::vector<DependencyProbe> probes;

    DependencyProbe opencv;
    opencv.kind = "opencv";
    opencv.displayName = "OpenCV";
    opencv.headerAvailable = PANOLUME_HAS_OPENCV_HEADERS;
    opencv.headerCandidates = {"opencv2/core.hpp"};
    opencv.runtimeCandidates = {
        "libopencv_core.dylib",
        "/opt/homebrew/lib/libopencv_core.dylib",
        "/usr/local/lib/libopencv_core.dylib"
    };
    // OpenCV, LibRaw, Ceres and libtiff are direct link dependencies of the
    // engine target. If one is missing, dyld prevents the process from
    // reaching this probe. Do not dlopen Homebrew candidates here: a
    // relocatable app already contains its own closure, and loading a second
    // OpenBLAS/OpenMP closure aborts during library initialization.
    opencv.runtimeAvailable = PANOLUME_HAS_OPENCV_HEADERS;
    opencv.notes = "Directly linked runtime used for SIFT/FLANN feature matching, homography, and warp parity.";
    probes.push_back(opencv);

    DependencyProbe libraw;
    libraw.kind = "libraw";
    libraw.displayName = "LibRaw";
    libraw.headerAvailable = PANOLUME_HAS_LIBRAW_HEADERS;
    libraw.headerCandidates = {"libraw/libraw.h", "libraw.h"};
    libraw.runtimeCandidates = {
        "libraw.dylib",
        "/opt/homebrew/lib/libraw.dylib",
        "/usr/local/lib/libraw.dylib"
    };
    libraw.runtimeAvailable = PANOLUME_HAS_LIBRAW_HEADERS;
    libraw.notes = "Directly linked runtime used for RAW decode and color/linear handling.";
    probes.push_back(libraw);

    DependencyProbe ceres;
    ceres.kind = "ceres";
    ceres.displayName = "Ceres Solver";
    ceres.headerAvailable = PANOLUME_HAS_CERES_HEADERS;
    ceres.headerCandidates = {"ceres/ceres.h"};
    ceres.runtimeCandidates = {
        "libceres.dylib",
        "/opt/homebrew/lib/libceres.dylib",
        "/usr/local/lib/libceres.dylib"
    };
    ceres.runtimeAvailable = PANOLUME_HAS_CERES_HEADERS;
    ceres.notes = "Directly linked runtime used for camera bundle adjustment and robust reprojection refinement parity.";
    probes.push_back(ceres);

    DependencyProbe eigen;
    eigen.kind = "eigen";
    eigen.displayName = "Eigen";
    eigen.headerAvailable = PANOLUME_HAS_EIGEN_HEADERS;
    eigen.runtimeRequired = false;
    eigen.runtimeAvailable = true;
    eigen.headerCandidates = {"Eigen/Core", "eigen3/Eigen/Core"};
    eigen.notes = "Header-only dependency used by optimization and camera math.";
    probes.push_back(eigen);

    DependencyProbe libtiff;
    libtiff.kind = "libtiff";
    libtiff.displayName = "libtiff";
    libtiff.headerAvailable = PANOLUME_HAS_LIBTIFF_HEADERS;
    libtiff.headerCandidates = {"tiffio.h"};
    libtiff.runtimeCandidates = {
        "libtiff.dylib",
        "/opt/homebrew/lib/libtiff.dylib",
        "/usr/local/lib/libtiff.dylib"
    };
    libtiff.runtimeAvailable = PANOLUME_HAS_LIBTIFF_HEADERS;
    libtiff.notes = "Directly linked runtime used for streaming full-resolution TIFF strip export parity.";
    probes.push_back(libtiff);

    DependencyProbe metal;
    metal.kind = "metal";
    metal.displayName = "Metal";
    metal.headerAvailable = PANOLUME_HAS_METAL_HEADERS;
    metal.requiredForParity = false;
    metal.headerCandidates = {"Metal/Metal.h"};
    metal.runtimeCandidates = {
        "/System/Library/Frameworks/Metal.framework/Metal"
    };
    metal.runtimeAvailable = can_dlopen_any(metal.runtimeCandidates);
    metal.notes = "Target renderer path for performance; CPU fallback remains required until Metal quality parity is proven.";
    probes.push_back(metal);

    return probes;
}

static std::string dependency_status_json(const DependencyProbe &probe) {
    std::ostringstream out;
    out << "{";
    out << "\"kind\":\"" << json_escape(probe.kind) << "\",";
    out << "\"display_name\":\"" << json_escape(probe.displayName) << "\",";
    out << "\"header_available\":" << bool_json(probe.headerAvailable) << ",";
    out << "\"runtime_available\":" << bool_json(probe.runtimeAvailable) << ",";
    out << "\"runtime_required\":" << bool_json(probe.runtimeRequired) << ",";
    out << "\"available\":" << bool_json(probe.available()) << ",";
    out << "\"required_for_parity\":" << bool_json(probe.requiredForParity) << ",";
    out << "\"header_candidates\":" << json_string_array(probe.headerCandidates) << ",";
    out << "\"runtime_candidates\":" << json_string_array(probe.runtimeCandidates) << ",";
    out << "\"notes\":\"" << json_escape(probe.notes) << "\"";
    out << "}";
    return out.str();
}

static std::string dependency_report_json() {
    const std::vector<DependencyProbe> probes = dependency_probes();
    bool allRequiredAvailable = true;
    std::vector<std::string> requiredKinds;
    for (const DependencyProbe &probe : probes) {
        if (probe.requiredForParity) {
            requiredKinds.push_back(probe.kind);
            if (!probe.available()) {
                allRequiredAvailable = false;
            }
        }
    }

    std::ostringstream out;
    out << "{";
    out << "\"schema_version\":1,";
    out << "\"status\":\"" << (allRequiredAvailable ? "ready_for_native_algorithm_build" : "missing_required_dependencies") << "\",";
    out << "\"all_required_available\":" << bool_json(allRequiredAvailable) << ",";
    out << "\"required_for_parity\":" << json_string_array(requiredKinds) << ",";
    out << "\"dependencies\":[";
    for (size_t i = 0; i < probes.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << dependency_status_json(probes[i]);
    }
    out << "]";
    out << "}";
    return out.str();
}

static bool dependency_available(const std::string &kind) {
    for (const DependencyProbe &probe : dependency_probes()) {
        if (probe.kind == kind) {
            return probe.available();
        }
    }
    return false;
}

static std::string lower_string(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

static std::string extension_for_path(const std::string &path) {
    const size_t slash = path.find_last_of("/\\");
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) {
        return "";
    }
    return lower_string(path.substr(dot));
}

static bool is_raw_extension(const std::string &path) {
    const std::string ext = extension_for_path(path);
    return ext == ".cr2" || ext == ".nef" || ext == ".arw" || ext == ".raf"
        || ext == ".orf" || ext == ".rw2" || ext == ".dng" || ext == ".pef";
}

static bool is_tiff_path(const std::string &path) {
    const std::string ext = extension_for_path(path);
    return ext == ".tif" || ext == ".tiff";
}

static std::string temporary_export_path(const std::string &outputPath) {
    return outputPath + ".panolume-partial";
}

static bool commit_temporary_export(const std::string &temporaryPath, const std::string &outputPath, std::string &errorMessage) {
    if (std::rename(temporaryPath.c_str(), outputPath.c_str()) != 0) {
        errorMessage = "failed to atomically publish TIFF output";
        std::remove(temporaryPath.c_str());
        return false;
    }
    return true;
}

static unsigned long long request_job_id(
    const panolume::EngineRequest &request,
    PanoLumeContext *context
) {
    const double parsed = request.number("jobId", 0.0);
    if (std::isfinite(parsed)
        && parsed > 0.0
        && parsed <= static_cast<double>(std::numeric_limits<unsigned long long>::max())) {
        return static_cast<unsigned long long>(std::llround(parsed));
    }
    return context->nextJobId.fetch_add(1);
}

class NativeOperationScope;
static thread_local NativeOperationScope *active_native_operation = nullptr;

class NativeOperationScope {
public:
    NativeOperationScope(
        PanoLumeContext *context,
        const panolume::EngineRequest &request
    )
        : context_(context),
          jobID_(request_job_id(request, context)) {
        {
            std::lock_guard<std::mutex> lock(context_->cancellationMutex);
            if (context_->cancelledJobs.find(jobID_) == context_->cancelledJobs.end()) {
                context_->cancelledJobs[jobID_] = false;
            }
        }
        operationLock_ = std::unique_lock<std::mutex>(context_->operationMutex);
        previous_ = active_native_operation;
        active_native_operation = this;
    }

    ~NativeOperationScope() {
        active_native_operation = previous_;
        std::lock_guard<std::mutex> lock(context_->cancellationMutex);
        context_->cancelledJobs.erase(jobID_);
    }

    bool cancelled() const {
        std::lock_guard<std::mutex> lock(context_->cancellationMutex);
        auto found = context_->cancelledJobs.find(jobID_);
        return found != context_->cancelledJobs.end() && found->second;
    }

private:
    PanoLumeContext *context_;
    unsigned long long jobID_;
    std::unique_lock<std::mutex> operationLock_;
    NativeOperationScope *previous_ = nullptr;
};

static bool active_native_operation_cancelled() {
    return active_native_operation != nullptr && active_native_operation->cancelled();
}

static std::string error_json(const std::string &operation, const std::string &message);

static char *cancelled_operation_json(const char *operation) {
    return copy_json(error_json(operation, "Operation cancelled."));
}

static bool parse_control_points(
    const panolume::EngineRequest &request,
    std::vector<NativeControlPoint> &points
) {
    if (!request.has("controlPoints")) {
        return false;
    }
    points.clear();
    for (const panolume::JSONRequest &object : request.object_array("controlPoints")) {
        NativeControlPoint point;
        point.imageAIndex = object.integer("imageAIndex", 0);
        point.imageBIndex = object.integer("imageBIndex", 0);
        point.xA = object.number("xA", 0.0);
        point.yA = object.number("yA", 0.0);
        point.xB = object.number("xB", 0.0);
        point.yB = object.number("yB", 0.0);
        point.error = object.number("error", 0.0);
        point.isManual = object.boolean("isManual", false);
        points.push_back(point);
    }
    return true;
}

static std::string image_info_json(const NativeImage &image) {
    std::ostringstream out;
    out << "{";
    out << "\"handle\":\"" << json_escape(image.handle) << "\",";
    out << "\"path\":\"" << json_escape(image.path) << "\",";
    out << "\"width\":" << image.width << ",";
    out << "\"height\":" << image.height << ",";
    out << "\"original_width\":" << (image.originalWidth > 0 ? image.originalWidth : image.width) << ",";
    out << "\"original_height\":" << (image.originalHeight > 0 ? image.originalHeight : image.height) << ",";
    out << "\"channels\":" << image.channels << ",";
    out << "\"bit_depth\":" << image.bitDepth << ",";
    out << "\"focal_length_35mm\":" << number_json(image.focalLength35mm) << ",";
    out << "\"focal_length_mm\":" << number_json(image.focalLengthMM) << ",";
    out << "\"aperture_f_number\":" << number_json(image.apertureFNumber) << ",";
    out << "\"camera_make\":\"" << json_escape(image.cameraMake) << "\",";
    out << "\"camera_model\":\"" << json_escape(image.cameraModel) << "\",";
    out << "\"lens_name\":\"" << json_escape(image.lensName) << "\",";
    out << "\"focal_metadata_source\":\"" << json_escape(image.focalMetadataSource) << "\",";
    out << "\"capture_datetime_original\":\"" << json_escape(image.captureDateTimeOriginal) << "\",";
    out << "\"capture_metadata_source\":\"" << json_escape(image.captureMetadataSource) << "\",";
    out << "\"status\":\"" << json_escape(image.status) << "\",";
    if (!image.unsupportedReason.empty()) {
        out << "\"unsupported_reason\":\"" << json_escape(image.unsupportedReason) << "\"";
    } else {
        out << "\"unsupported_reason\":null";
    }
    out << "}";
    return out.str();
}

static std::string image_infos_json(const std::vector<NativeImage> &images) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < images.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << image_info_json(images[i]);
    }
    out << "]";
    return out.str();
}

static std::string source_images_json(const PanoLumeContext *context, const NativeResult &result) {
    std::vector<NativeImage> images;
    images.reserve(result.paths.size());
    for (size_t i = 0; i < result.paths.size(); ++i) {
        NativeImage image;
        image.path = result.paths[i];
        if (i < result.imageHandles.size()) {
            auto found = context->images.find(result.imageHandles[i]);
            if (found != context->images.end()) {
                image = found->second;
            }
        }
        images.push_back(image);
    }
    return image_infos_json(images);
}

static std::string raw_status() {
    return dependency_available("libraw") ? "libraw_available" : "unsupported_until_libraw";
}

struct NativeMetalRuntimeStatus {
    bool dylibLoaded = false;
    bool apiCompatible = false;
    bool deviceAvailable = false;
    bool fastAvailable = false;
    bool qualityAvailable = false;
    int apiVersion = 0;
    std::string path;
    std::string sha256;
    std::string reason;
};

// This is the C bridge layout understood by the current engine. Certification
// identity is generated from the promoted manifest and validated separately;
// it must never be hard-coded into this fingerprinted algorithm source.
#if __has_include("Private/EnvironmentCompatibility.hpp")
#include "Private/EnvironmentCompatibility.hpp"
#endif

static constexpr int kPanoLumeMetalBridgeAPIVersion = 6;
extern "C" const char *panolume_build_engine_source_fingerprint(void) __attribute__((weak_import));
extern "C" const char *panolume_build_certified_engine_source_fingerprint(void) __attribute__((weak_import));
extern "C" const char *panolume_build_certified_source_commit(void) __attribute__((weak_import));
extern "C" const char *panolume_build_certified_release_report_sha256(void) __attribute__((weak_import));
extern "C" const char *panolume_build_certified_metal_dylib_sha256(void) __attribute__((weak_import));
extern "C" int32_t panolume_build_certified_metal_api_version(void) __attribute__((weak_import));

static std::string native_engine_source_fingerprint() {
    if (panolume_build_engine_source_fingerprint != nullptr) {
        const char *value = panolume_build_engine_source_fingerprint();
        if (value != nullptr && value[0] != '\0') {
            return value;
        }
    }
    return "uncertified";
}

static std::string native_certified_engine_source_fingerprint() {
    if (panolume_build_certified_engine_source_fingerprint != nullptr) {
        const char *value = panolume_build_certified_engine_source_fingerprint();
        if (value != nullptr && value[0] != '\0') {
            return value;
        }
    }
    return "uncertified";
}

static std::string native_certified_source_commit() {
    if (panolume_build_certified_source_commit != nullptr) {
        const char *value = panolume_build_certified_source_commit();
        if (value != nullptr && value[0] != '\0') {
            return value;
        }
    }
    return "";
}

static std::string native_certified_release_report_sha256() {
    if (panolume_build_certified_release_report_sha256 != nullptr) {
        const char *value = panolume_build_certified_release_report_sha256();
        if (value != nullptr && value[0] != '\0') {
            return value;
        }
    }
    return "";
}

static std::string native_certified_metal_dylib_sha256() {
    if (panolume_build_certified_metal_dylib_sha256 != nullptr) {
        const char *value = panolume_build_certified_metal_dylib_sha256();
        if (value != nullptr && value[0] != '\0') {
            return value;
        }
    }
    return "";
}

static int native_certified_metal_api_version() {
    return panolume_build_certified_metal_api_version != nullptr
        ? static_cast<int>(panolume_build_certified_metal_api_version())
        : 0;
}

static bool valid_lowercase_hex_identity(const std::string &value, size_t expectedLength) {
    return value.size() == expectedLength
        && std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9')
                || (character >= 'a' && character <= 'f');
        });
}
typedef int (*PanoLumeMetalAPIVersionFn)(void);
typedef int (*PanoLumeMetalIsAvailableFn)(void);
typedef const char *(*PanoLumeMetalLastErrorFn)(void);
typedef int (*PanoLumeMetalRenderFn)(const void *);
typedef void (*PanoLumeMetalResetInteractiveCacheFn)(void);
typedef void (*PanoLumeMetalBeginInteractiveSessionFn)(uint64_t);
typedef void (*PanoLumeMetalEndInteractiveSessionFn)(uint64_t);

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

static void *g_nativeMetalHandle = nullptr;
static PanoLumeMetalRenderFn g_nativeMetalRenderFast = nullptr;
static PanoLumeMetalRenderFn g_nativeMetalRenderQuality = nullptr;
static PanoLumeMetalLastErrorFn g_nativeMetalLastError = nullptr;
static PanoLumeMetalResetInteractiveCacheFn g_nativeMetalResetInteractiveCache = nullptr;
static PanoLumeMetalBeginInteractiveSessionFn g_nativeMetalBeginInteractiveSession = nullptr;
static PanoLumeMetalEndInteractiveSessionFn g_nativeMetalEndInteractiveSession = nullptr;

static void append_unique_path(std::vector<std::string> &paths, const std::string &path) {
    if (path.empty() || std::find(paths.begin(), paths.end(), path) != paths.end()) {
        return;
    }
    paths.push_back(path);
}

static std::string path_join(const std::string &directory, const std::string &component) {
    if (directory.empty()) {
        return component;
    }
    return directory.back() == '/'
        ? directory + component
        : directory + "/" + component;
}

static std::string parent_directory(const std::string &path) {
    const size_t separator = path.find_last_of('/');
    if (separator == std::string::npos) {
        return ".";
    }
    return separator == 0 ? "/" : path.substr(0, separator);
}

static std::string filesystem_path(CFURLRef url) {
    if (url == nullptr) {
        return "";
    }
    std::array<UInt8, PATH_MAX> buffer{};
    if (!CFURLGetFileSystemRepresentation(url, true, buffer.data(), buffer.size())) {
        return "";
    }
    return reinterpret_cast<const char *>(buffer.data());
}

static std::string process_executable_path() {
    uint32_t requiredSize = 0;
    if (_NSGetExecutablePath(nullptr, &requiredSize) == 0 || requiredSize == 0) {
        return "";
    }
    std::vector<char> buffer(requiredSize + 1, '\0');
    if (_NSGetExecutablePath(buffer.data(), &requiredSize) != 0) {
        return "";
    }
    std::array<char, PATH_MAX> resolved{};
    if (realpath(buffer.data(), resolved.data()) != nullptr) {
        return resolved.data();
    }
    return buffer.data();
}

static std::vector<std::string> native_metal_dylib_candidates_for_locations(
    const std::string &bundleRoot,
    const std::string &resourcesDirectory,
    const std::string &frameworksDirectory,
    const std::vector<std::string> &executablePaths
) {
    std::vector<std::string> candidates;
    const char *envPath = std::getenv("PANOLUME_METAL_DYLIB");
#if __has_include("Private/EnvironmentCompatibility.hpp")
    if (!envPath) envPath = private_metal_environment_path();
#endif
    if (envPath && envPath[0] != '\0') {
        append_unique_path(candidates, envPath);
    }
    if (!resourcesDirectory.empty()) {
        append_unique_path(candidates, path_join(resourcesDirectory, "libpanolume_metal.dylib"));
    } else if (!bundleRoot.empty()) {
        append_unique_path(candidates, path_join(bundleRoot, "Contents/Resources/libpanolume_metal.dylib"));
    }
    if (!frameworksDirectory.empty()) {
        append_unique_path(candidates, path_join(frameworksDirectory, "libpanolume_metal.dylib"));
    } else if (!bundleRoot.empty()) {
        append_unique_path(candidates, path_join(bundleRoot, "Contents/Frameworks/libpanolume_metal.dylib"));
    }
    for (const std::string &executablePath : executablePaths) {
        if (!executablePath.empty()) {
            append_unique_path(
                candidates,
                path_join(parent_directory(executablePath), "libpanolume_metal.dylib")
            );
        }
    }
    append_unique_path(candidates, "build/native/libpanolume_metal.dylib");
    append_unique_path(candidates, "../build/native/libpanolume_metal.dylib");
    append_unique_path(candidates, "../../build/native/libpanolume_metal.dylib");
    append_unique_path(candidates, "../../../build/native/libpanolume_metal.dylib");
    append_unique_path(candidates, "../../../../build/native/libpanolume_metal.dylib");
    append_unique_path(candidates, "native/metal_renderer/libpanolume_metal.dylib");
    append_unique_path(candidates, "../native/metal_renderer/libpanolume_metal.dylib");
    append_unique_path(candidates, "../../native/metal_renderer/libpanolume_metal.dylib");
    return candidates;
}

static std::vector<std::string> native_metal_dylib_candidates_for_paths(
    const std::string &bundleRoot,
    const std::string &executablePath
) {
    const std::string resourcesDirectory = bundleRoot.empty()
        ? ""
        : path_join(bundleRoot, "Contents/Resources");
    const std::string frameworksDirectory = bundleRoot.empty()
        ? ""
        : path_join(bundleRoot, "Contents/Frameworks");
    return native_metal_dylib_candidates_for_locations(
        bundleRoot,
        resourcesDirectory,
        frameworksDirectory,
        {executablePath}
    );
}

static std::vector<std::string> native_metal_dylib_candidates() {
    std::string bundleRoot;
    std::string resourcesDirectory;
    std::string frameworksDirectory;
    std::vector<std::string> executablePaths;
    if (CFBundleRef bundle = CFBundleGetMainBundle()) {
        if (CFURLRef bundleURL = CFBundleCopyBundleURL(bundle)) {
            bundleRoot = filesystem_path(bundleURL);
            CFRelease(bundleURL);
        }
        if (CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(bundle)) {
            resourcesDirectory = filesystem_path(resourcesURL);
            CFRelease(resourcesURL);
        }
        if (CFURLRef frameworksURL = CFBundleCopyPrivateFrameworksURL(bundle)) {
            frameworksDirectory = filesystem_path(frameworksURL);
            CFRelease(frameworksURL);
        }
        if (CFURLRef executableURL = CFBundleCopyExecutableURL(bundle)) {
            append_unique_path(executablePaths, filesystem_path(executableURL));
            CFRelease(executableURL);
        }
    }
    append_unique_path(executablePaths, process_executable_path());
    return native_metal_dylib_candidates_for_locations(
        bundleRoot,
        resourcesDirectory,
        frameworksDirectory,
        executablePaths
    );
}

static std::string join_string_vector(const std::vector<std::string> &values, const std::string &separator) {
    std::ostringstream out;
    for (size_t idx = 0; idx < values.size(); ++idx) {
        if (idx) {
            out << separator;
        }
        out << values[idx];
    }
    return out.str();
}

static std::string sha256_file(const std::string &path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return "";
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    std::array<char, 64 * 1024> buffer{};
    while (input) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const std::streamsize count = input.gcount();
        if (count > 0) {
            CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(count));
        }
    }
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256_Final(digest.data(), &context);
    std::ostringstream value;
    value << std::hex << std::setfill('0');
    for (unsigned char byte : digest) {
        value << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return value.str();
}

static NativeMetalRuntimeStatus native_metal_runtime_status() {
    static bool probed = false;
    static NativeMetalRuntimeStatus cached;
    if (probed) {
        return cached;
    }
    probed = true;
    std::vector<std::string> errors;
    for (const std::string &candidate : native_metal_dylib_candidates()) {
        void *handle = dlopen(candidate.c_str(), RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            const char *error = dlerror();
            if (error) {
                errors.push_back(candidate + ": " + error);
            }
            continue;
        }
        PanoLumeMetalAPIVersionFn apiVersionFn = reinterpret_cast<PanoLumeMetalAPIVersionFn>(
            dlsym(handle, "panolume_metal_api_version")
        );
        const int apiVersion = apiVersionFn ? apiVersionFn() : 0;
        if (apiVersion != kPanoLumeMetalBridgeAPIVersion) {
            errors.push_back(
                candidate + ": incompatible Metal renderer API version "
                + std::to_string(apiVersion) + ", expected "
                + std::to_string(kPanoLumeMetalBridgeAPIVersion) + "; rebuild the Metal renderer dylib"
            );
            dlclose(handle);
            continue;
        }
        cached.dylibLoaded = true;
        cached.apiCompatible = true;
        cached.apiVersion = apiVersion;
        cached.path = candidate;
        cached.sha256 = sha256_file(candidate);
        PanoLumeMetalIsAvailableFn isAvailable = reinterpret_cast<PanoLumeMetalIsAvailableFn>(
            dlsym(handle, "panolume_metal_is_available")
        );
        PanoLumeMetalLastErrorFn lastError = reinterpret_cast<PanoLumeMetalLastErrorFn>(
            dlsym(handle, "panolume_metal_last_error")
        );
        PanoLumeMetalRenderFn fastRender = reinterpret_cast<PanoLumeMetalRenderFn>(
            dlsym(handle, "panolume_metal_render_camera_strip")
        );
        PanoLumeMetalRenderFn qualityRender = reinterpret_cast<PanoLumeMetalRenderFn>(
            dlsym(handle, "panolume_metal_render_camera_strip_quality")
        );
        PanoLumeMetalResetInteractiveCacheFn resetInteractiveCache =
            reinterpret_cast<PanoLumeMetalResetInteractiveCacheFn>(
                dlsym(handle, "panolume_metal_reset_interactive_cache")
            );
        PanoLumeMetalBeginInteractiveSessionFn beginInteractiveSession =
            reinterpret_cast<PanoLumeMetalBeginInteractiveSessionFn>(
                dlsym(handle, "panolume_metal_begin_interactive_session")
            );
        PanoLumeMetalEndInteractiveSessionFn endInteractiveSession =
            reinterpret_cast<PanoLumeMetalEndInteractiveSessionFn>(
                dlsym(handle, "panolume_metal_end_interactive_session")
            );
        g_nativeMetalHandle = handle;
        g_nativeMetalRenderFast = fastRender;
        g_nativeMetalRenderQuality = qualityRender;
        g_nativeMetalLastError = lastError;
        g_nativeMetalResetInteractiveCache = resetInteractiveCache;
        g_nativeMetalBeginInteractiveSession = beginInteractiveSession;
        g_nativeMetalEndInteractiveSession = endInteractiveSession;
        cached.fastAvailable = fastRender != nullptr;
        cached.qualityAvailable = qualityRender != nullptr
            && resetInteractiveCache != nullptr
            && beginInteractiveSession != nullptr
            && endInteractiveSession != nullptr;
        cached.deviceAvailable = isAvailable != nullptr && isAvailable() == 1;
        if (!cached.deviceAvailable) {
            const char *message = lastError ? lastError() : nullptr;
            cached.reason = (message && message[0] != '\0')
                ? message
                : "Metal renderer dylib loaded, but no Metal device/runtime is available";
        } else if (!cached.fastAvailable) {
            cached.reason = "Metal renderer dylib does not export panolume_metal_render_camera_strip";
        } else if (resetInteractiveCache == nullptr
            || beginInteractiveSession == nullptr
            || endInteractiveSession == nullptr) {
            cached.reason = "Metal renderer API v5 does not export the complete interactive projection-session lifecycle";
        } else if (!cached.qualityAvailable) {
            cached.reason = "Metal renderer dylib does not export panolume_metal_render_camera_strip_quality";
        } else {
            cached.reason = "Metal renderer dylib and quality kernel are available";
        }
        return cached;
    }
    cached.reason = errors.empty()
        ? "Metal renderer dylib was not found"
        : join_string_vector(errors, "; ");
    return cached;
}

static void angle_axis_to_row_major_matrix(const std::array<double, 3> &rotation, float matrix[9]) {
    const double theta2 = rotation[0] * rotation[0] + rotation[1] * rotation[1] + rotation[2] * rotation[2];
    double m[9] = {
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    };
    if (theta2 > 1e-24) {
        const double theta = std::sqrt(theta2);
        const double x = rotation[0] / theta;
        const double y = rotation[1] / theta;
        const double z = rotation[2] / theta;
        const double c = std::cos(theta);
        const double s = std::sin(theta);
        const double t = 1.0 - c;
        m[0] = t * x * x + c;
        m[1] = t * x * y - s * z;
        m[2] = t * x * z + s * y;
        m[3] = t * x * y + s * z;
        m[4] = t * y * y + c;
        m[5] = t * y * z - s * x;
        m[6] = t * x * z - s * y;
        m[7] = t * y * z + s * x;
        m[8] = t * z * z + c;
    }
    for (int idx = 0; idx < 9; ++idx) {
        matrix[idx] = static_cast<float>(m[idx]);
    }
}

static bool render_camera_strip_with_metal(
    const NativeResult &result,
    const std::vector<NativeImage> &images,
    const NativeOutputBoundsReport &bounds,
    int y0,
    int stripHeight,
    double offsetX,
    double offsetY,
    double projectionScale,
    bool quality,
    std::vector<uint16_t> &output,
    std::vector<uint8_t> &coverage,
    std::string &errorMessage
) {
    NativeMetalRuntimeStatus metalStatus = native_metal_runtime_status();
    if (!metalStatus.dylibLoaded || !metalStatus.deviceAvailable) {
        errorMessage = metalStatus.reason.empty() ? "Metal renderer is unavailable" : metalStatus.reason;
        return false;
    }
    PanoLumeMetalRenderFn renderFn = quality ? g_nativeMetalRenderQuality : g_nativeMetalRenderFast;
    if (!renderFn) {
        errorMessage = quality
            ? "Metal quality render symbol is unavailable"
            : "Metal fast render symbol is unavailable";
        return false;
    }
    if (images.size() != result.cameraParams.size() || images.empty()) {
        errorMessage = "Metal renderer requires matching images and camera params";
        return false;
    }
    if (g_nativeMetalBeginInteractiveSession != nullptr) {
        uint64_t sessionID = 1469598103934665603ULL;
        for (unsigned char character : result.handle) {
            sessionID = (sessionID ^ static_cast<uint64_t>(character)) * 1099511628211ULL;
        }
        g_nativeMetalBeginInteractiveSession(sessionID == 0 ? 1 : sessionID);
    }
    output.assign(static_cast<size_t>(stripHeight) * static_cast<size_t>(bounds.width) * 3, 0);
    coverage.assign(static_cast<size_t>(stripHeight) * static_cast<size_t>(bounds.width), 0);
    std::vector<const float *> imagePointers;
    std::vector<const uint16_t *> imagePointersU16;
    std::vector<int32_t> widths;
    std::vector<int32_t> heights;
    std::vector<float> rotations;
    std::vector<float> focals;
    std::vector<float> distortions;
    std::vector<float> principalOffsets;
    std::vector<float> localWarpOffsets;
    imagePointers.reserve(images.size());
    imagePointersU16.reserve(images.size());
    widths.reserve(images.size());
    heights.reserve(images.size());
    rotations.resize(images.size() * 9);
    focals.resize(images.size());
    distortions.resize(images.size() * 5);
    principalOffsets.resize(images.size() * 2);
    if (result.localWarpModel.images.size() == images.size()) {
        localWarpOffsets.resize(images.size() * panolume::kLocalWarpNodeCount * 2, 0.0f);
    }
    const bool useNative16 = images.front().native16Pixels != nullptr;
    for (size_t idx = 0; idx < images.size(); ++idx) {
        const NativeImage &image = images[idx];
        const NativeCameraParams &camera = result.cameraParams[idx];
        const bool imageUsesNative16 = image.native16Pixels != nullptr;
        if (imageUsesNative16 != useNative16) {
            errorMessage = "Metal renderer does not accept mixed float32 and 16-bit image sources";
            return false;
        }
        const bool hasExpectedPixels = useNative16
            ? image.native16Pixels != nullptr
            : !image.pixels.empty();
        if (!hasExpectedPixels || image.width <= 1 || image.height <= 1 || camera.focalLength <= 1e-6) {
            errorMessage = "Metal renderer received invalid image or camera params";
            return false;
        }
        if (useNative16) {
            imagePointersU16.push_back(image.native16Pixels);
        } else {
            imagePointers.push_back(image.pixels.data());
        }
        widths.push_back(static_cast<int32_t>(image.width));
        heights.push_back(static_cast<int32_t>(image.height));
        std::array<double, 3> inverseRotation = {
            -camera.rotation[0],
            -camera.rotation[1],
            -camera.rotation[2]
        };
        angle_axis_to_row_major_matrix(inverseRotation, rotations.data() + idx * 9);
        focals[idx] = static_cast<float>(camera.focalLength);
        distortions[idx * 5 + 0] = static_cast<float>(camera.k1);
        distortions[idx * 5 + 1] = static_cast<float>(camera.k2);
        distortions[idx * 5 + 2] = static_cast<float>(camera.k3);
        distortions[idx * 5 + 3] = static_cast<float>(camera.p1);
        distortions[idx * 5 + 4] = static_cast<float>(camera.p2);
        principalOffsets[idx * 2 + 0] = static_cast<float>(camera.principalOffsetX);
        principalOffsets[idx * 2 + 1] = static_cast<float>(camera.principalOffsetY);
        if (!localWarpOffsets.empty()) {
            for (int node = 0; node < panolume::kLocalWarpNodeCount; ++node) {
                const size_t base = (idx * panolume::kLocalWarpNodeCount + static_cast<size_t>(node)) * 2;
                localWarpOffsets[base] = static_cast<float>(result.localWarpModel.images[idx].dx[static_cast<size_t>(node)]);
                localWarpOffsets[base + 1] = static_cast<float>(result.localWarpModel.images[idx].dy[static_cast<size_t>(node)]);
            }
        }
    }
    PanoLumeMetalRenderRequest request;
    std::memset(&request, 0, sizeof(request));
    request.image_count = static_cast<int32_t>(images.size());
    request.images = useNative16 ? nullptr : imagePointers.data();
    request.images_u16 = useNative16 ? imagePointersU16.data() : nullptr;
    request.image_sample_type = useNative16 ? 1 : 0;
    request.widths = widths.data();
    request.heights = heights.data();
    request.rotations = rotations.data();
    request.focals = focals.data();
    request.distortions = distortions.data();
    request.principal_offsets = principalOffsets.data();
    request.local_warp_offsets = localWarpOffsets.empty() ? nullptr : localWarpOffsets.data();
    request.local_warp_columns = panolume::kLocalWarpColumns;
    request.local_warp_rows = panolume::kLocalWarpRows;
    request.out_width = static_cast<int32_t>(bounds.width);
    request.strip_height = static_cast<int32_t>(stripHeight);
    request.global_y0 = static_cast<int32_t>(y0);
    request.offset_x = static_cast<float>(offsetX);
    request.offset_y = static_cast<float>(offsetY);
    request.scale = static_cast<float>(projectionScale);
    request.feather_radius = quality ? 30.0f : 64.0f;
    request.output = output.data();
    request.coverage = coverage.data();
    const int ok = renderFn(&request);
    if (ok != 1) {
        const char *message = g_nativeMetalLastError ? g_nativeMetalLastError() : nullptr;
        errorMessage = (message && message[0] != '\0') ? message : "Metal render failed";
        return false;
    }
    return true;
}

static void set_preview_renderer_status(NativeResult &result, const std::string &rendererUsed) {
    const std::string existingFallbackReason = result.previewRendererFallbackReason;
    result.previewRendererUsed = rendererUsed;
    result.previewRendererFallback = false;
    result.previewRendererFallbackReason.clear();
    const std::string requested = lower_string(result.previewRendererRequested.empty() ? "auto" : result.previewRendererRequested);
    if ((requested == "metal_fast" || requested == "metal_quality") && rendererUsed.find("metal") == std::string::npos) {
        result.previewRendererFallback = true;
        if (!existingFallbackReason.empty()) {
            result.previewRendererFallbackReason = existingFallbackReason + "; preview is using the OpenCV CPU renderer";
        } else {
            NativeMetalRuntimeStatus metalStatus = native_metal_runtime_status();
            result.previewRendererFallbackReason = metalStatus.reason.empty()
                ? "preview GPU renderer is not active; using the OpenCV CPU renderer"
                : metalStatus.reason + "; preview is using the OpenCV CPU renderer";
        }
    }
}

static bool native_engine_source_is_certified() {
    const std::string engineFingerprint = native_engine_source_fingerprint();
    const std::string certifiedFingerprint = native_certified_engine_source_fingerprint();
    return valid_lowercase_hex_identity(engineFingerprint, 64)
        && valid_lowercase_hex_identity(certifiedFingerprint, 64)
        && engineFingerprint == certifiedFingerprint;
}

static bool native_release_identity_is_certified() {
    return valid_lowercase_hex_identity(native_certified_source_commit(), 40)
        && valid_lowercase_hex_identity(native_certified_release_report_sha256(), 64)
        && valid_lowercase_hex_identity(native_certified_metal_dylib_sha256(), 64)
        && native_certified_metal_api_version() == kPanoLumeMetalBridgeAPIVersion;
}

static bool native_parity_runtime_available() {
    const bool nativeDependenciesAvailable = dependency_available("opencv")
        && dependency_available("libraw")
        && dependency_available("ceres")
        && dependency_available("eigen")
        && dependency_available("libtiff");
    const NativeMetalRuntimeStatus metalRuntime = native_metal_runtime_status();
    const std::string certifiedMetalSHA256 = native_certified_metal_dylib_sha256();
    const int certifiedMetalAPIVersion = native_certified_metal_api_version();
    const bool nativeMetalQualityAvailable = metalRuntime.dylibLoaded
        && metalRuntime.apiCompatible
        && metalRuntime.deviceAvailable
        && metalRuntime.fastAvailable
        && metalRuntime.qualityAvailable
        && valid_lowercase_hex_identity(certifiedMetalSHA256, 64)
        && certifiedMetalAPIVersion > 0
        && metalRuntime.apiVersion == certifiedMetalAPIVersion
        && metalRuntime.sha256 == certifiedMetalSHA256;
    return nativeDependenciesAvailable
        && nativeMetalQualityAvailable
        && native_engine_source_is_certified()
        && native_release_identity_is_certified();
}

static std::string missing_algorithms_json(bool requireSuccessfulStitch = false) {
    std::vector<std::string> missing;
    if (!dependency_available("libraw")) {
        missing.push_back("libraw_raw_decode");
    }
    if (!dependency_available("opencv")) {
        missing.push_back("opencv_sift_flann_warp");
        missing.push_back("star_asterism_matching");
    }
    if (!dependency_available("ceres")) {
        missing.push_back("ceres_bundle_adjustment");
        missing.push_back("robust_reprojection_filter");
    }
    if (!dependency_available("libtiff")) {
        missing.push_back("production_full_resolution_export_parity");
    }
    const NativeMetalRuntimeStatus metalRuntime = native_metal_runtime_status();
    const bool metalRuntimeReady = metalRuntime.dylibLoaded
        && metalRuntime.apiCompatible
        && metalRuntime.deviceAvailable
        && metalRuntime.fastAvailable
        && metalRuntime.qualityAvailable;
    if (!metalRuntimeReady) {
        missing.push_back("metal_quality_renderer_runtime");
    }
    const std::string certifiedMetalSHA256 = native_certified_metal_dylib_sha256();
    const int certifiedMetalAPIVersion = native_certified_metal_api_version();
    if (!valid_lowercase_hex_identity(certifiedMetalSHA256, 64)
        || certifiedMetalAPIVersion <= 0
        || certifiedMetalAPIVersion != kPanoLumeMetalBridgeAPIVersion
        || (metalRuntimeReady
            && (metalRuntime.sha256 != certifiedMetalSHA256
                || metalRuntime.apiVersion != certifiedMetalAPIVersion))) {
        missing.push_back("certified_metal_quality_renderer_binary");
    }
    if (!native_engine_source_is_certified()) {
        missing.push_back("certified_engine_source_fingerprint");
    }
    if (!valid_lowercase_hex_identity(native_certified_source_commit(), 40)
        || !valid_lowercase_hex_identity(native_certified_release_report_sha256(), 64)) {
        missing.push_back("certified_release_manifest_identity");
    }
    if (requireSuccessfulStitch) {
        missing.push_back("successful_camera_or_homography_stitch_result");
    }
    return json_string_array(missing);
}

static std::string capabilities_json() {
    const bool opencv = dependency_available("opencv");
    const bool libraw = dependency_available("libraw");
    const bool ceres = dependency_available("ceres");
    const bool eigen = dependency_available("eigen");
    const bool libtiff = dependency_available("libtiff");
    const bool metal = dependency_available("metal");
    const NativeMetalRuntimeStatus metalRuntime = native_metal_runtime_status();
    const bool nativeMetalRendererAvailable = metalRuntime.dylibLoaded
        && metalRuntime.apiCompatible
        && metalRuntime.deviceAvailable
        && metalRuntime.fastAvailable;
    const bool nativeMetalQualityAvailable = nativeMetalRendererAvailable
        && metalRuntime.qualityAvailable;
    const bool nativePreviewGPUAvailable = nativeMetalRendererAvailable;
    const bool nativeDependenciesAvailable = opencv && libraw && ceres && eigen && libtiff;
    const bool nativeQualityGateAvailable = opencv && ceres;
    const bool nativeParity = native_parity_runtime_available();
    return std::string("{")
        + "\"swiftui_shell\":true,"
        + "\"c_abi_facade\":true,"
        + "\"standard_image_io\":true,"
        + "\"display_stretch\":true,"
        + "\"opencv_sift_homography_preview\":" + bool_json(opencv) + ","
        + "\"star_asterism_preview\":" + bool_json(opencv) + ","
        + "\"ceres_rotation_camera_adjustment_preview\":" + bool_json(ceres) + ","
        + "\"native_brown_conrady_distortion_adjustment_preview\":" + bool_json(ceres) + ","
        + "\"native_guided_star_refinement_preview\":" + bool_json(opencv && ceres) + ","
        + "\"native_local_star_refinement_preview\":" + bool_json(opencv && ceres) + ","
        + "\"native_texture_sift_refinement_preview\":" + bool_json(opencv && ceres) + ","
        + "\"native_camera_projection_preview\":" + bool_json(opencv) + ","
        + "\"native_cpu_multiband_blending_preview\":" + bool_json(opencv) + ","
        + "\"native_preview_tiff_export_diagnostic\":" + bool_json(libtiff) + ","
        + "\"native_preview_camera_strip_tiff_export_diagnostic\":" + bool_json(libtiff && opencv) + ","
        + "\"native_fullres_camera_strip_tiff_export_diagnostic\":" + bool_json(libtiff && opencv && libraw) + ","
        + "\"native_export_peak_memory_diagnostic\":" + bool_json(PANOLUME_HAS_RUSAGE) + ","
        + "\"native_export_overlap_seam_diagnostic\":" + bool_json(libtiff && opencv) + ","
        + "\"native_multi_round_robust_camera_filter\":" + bool_json(ceres) + ","
        + "\"native_dependencies_available\":" + bool_json(nativeDependenciesAvailable) + ","
        + "\"native_quality_gate_available\":" + bool_json(nativeQualityGateAvailable) + ","
        + "\"native_metal_renderer_available\":" + bool_json(nativeMetalRendererAvailable) + ","
        + "\"native_metal_quality_available\":" + bool_json(nativeMetalQualityAvailable) + ","
        + "\"native_metal_renderer_api_compatible\":" + bool_json(metalRuntime.apiCompatible) + ","
        + "\"native_metal_renderer_api_version\":" + std::to_string(metalRuntime.apiVersion) + ","
        + "\"native_preview_gpu_available\":" + bool_json(nativePreviewGPUAvailable) + ","
        + "\"python_runtime_dependency\":false,"
        + "\"pyside_reference_required\":false,"
        + "\"native_algorithm_parity\":" + bool_json(nativeParity) + ","
        + "\"native_parity_certified_source_commit\":\"" + json_escape(native_certified_source_commit()) + "\","
        + "\"native_parity_release_report_sha256\":\"" + json_escape(native_certified_release_report_sha256()) + "\","
        + "\"native_parity_metal_dylib_sha256\":\"" + json_escape(native_certified_metal_dylib_sha256()) + "\","
        + "\"native_parity_metal_api_version\":" + std::to_string(native_certified_metal_api_version()) + ","
        + "\"native_parity_release_identity_available\":" + bool_json(native_release_identity_is_certified()) + ","
        + "\"native_engine_source_fingerprint\":\"" + json_escape(native_engine_source_fingerprint()) + "\","
        + "\"native_parity_certified_engine_source_fingerprint\":\"" + json_escape(native_certified_engine_source_fingerprint()) + "\","
        + "\"dependencies\":{"
        + "\"opencv\":" + bool_json(opencv) + ","
        + "\"libraw\":" + bool_json(libraw) + ","
        + "\"ceres\":" + bool_json(ceres) + ","
        + "\"eigen\":" + bool_json(eigen) + ","
        + "\"libtiff\":" + bool_json(libtiff) + ","
        + "\"metal\":" + bool_json(metal) + ","
        + "\"metal_dylib_bridge\":" + bool_json(metalRuntime.dylibLoaded) + ","
        + "\"metal_renderer_device\":" + bool_json(metalRuntime.deviceAvailable) + ","
        + "\"metal_renderer_fast\":" + bool_json(nativeMetalRendererAvailable) + ","
        + "\"metal_renderer_quality\":" + bool_json(nativeMetalQualityAvailable)
        + "},"
        + "\"metal_renderer\":{"
        + "\"dylib_loaded\":" + bool_json(metalRuntime.dylibLoaded) + ","
        + "\"api_compatible\":" + bool_json(metalRuntime.apiCompatible) + ","
        + "\"api_version\":" + std::to_string(metalRuntime.apiVersion) + ","
        + "\"device_available\":" + bool_json(metalRuntime.deviceAvailable) + ","
        + "\"fast_available\":" + bool_json(metalRuntime.fastAvailable) + ","
        + "\"quality_available\":" + bool_json(metalRuntime.qualityAvailable) + ","
        + "\"sha256\":\"" + json_escape(metalRuntime.sha256) + "\","
        + "\"path\":\"" + json_escape(metalRuntime.path) + "\","
        + "\"reason\":\"" + json_escape(metalRuntime.reason) + "\""
        + "},"
        + "\"dependency_report\":" + dependency_report_json() + ","
        + "\"missing_algorithms\":" + missing_algorithms_json()
        + "}";
}

class RawDecodeBackend {
public:
    virtual ~RawDecodeBackend() = default;
    virtual NativeImage loadRaw(
        PanoLumeContext *context,
        const std::string &path,
        int maxSide,
        bool halfSize,
        bool retainNative16
    ) = 0;
};

// Behavior-bearing implementation modules remain in one Objective-C++ translation
// unit for this pure layout migration. Their ordering matches the frozen baseline.
#include "EngineImageIO.hpp"
#include "EngineRegistration.hpp"
#include "EngineCameraRefinement.hpp"
#include "EngineRendering.hpp"
#include "EngineSerialization.hpp"
#include "EnginePTSReconstruction.hpp"

static bool native_astro_geometry_characterization_self_test(void) {
#if !PANOLUME_HAS_CERES_HEADERS || !PANOLUME_HAS_OPENCV_HEADERS
    return false;
#else
    // Exercise the production Brown-Conrady coefficient order, including both
    // radial and tangential terms. This guards against accidentally treating
    // an Adobe/LCP coefficient vector as OpenCV's differently ordered vector.
    double distortedX = 0.0;
    double distortedY = 0.0;
    apply_brown_conrady_distortion_double(
        0.4,
        -0.3,
        {0.08, -0.03, 0.01, 0.004, -0.006},
        distortedX,
        distortedY
    );
    if (std::abs(distortedX - 0.4029325) > 1e-12
        || std::abs(distortedY + 0.302324375) > 1e-12) {
        return false;
    }

    // The actual Ceres residual must be invariant to canonical edge direction:
    // swapping A/B produces the same chord with the opposite sign.
    NativeControlPoint point;
    point.imageAIndex = 0;
    point.imageBIndex = 1;
    point.xA = 713.25;
    point.yA = 311.75;
    point.xB = 428.5;
    point.yB = 547.125;
    const double rotationA[3] = {0.01, -0.035, 0.004};
    const double rotationB[3] = {-0.018, 0.027, -0.006};
    const double focal[1] = {920.0};
    const double distortion[5] = {0.012, -0.004, 0.001, 0.0007, -0.0009};
    const double principal[2] = {0.012, -0.018};
    double forward[3] = {0.0, 0.0, 0.0};
    NativeCameraResidual{
        point,
        1200.0,
        800.0,
        1000.0,
        900.0
    }(rotationA, rotationB, focal, distortion, principal, forward);

    NativeControlPoint reversedPoint = point;
    std::swap(reversedPoint.imageAIndex, reversedPoint.imageBIndex);
    std::swap(reversedPoint.xA, reversedPoint.xB);
    std::swap(reversedPoint.yA, reversedPoint.yB);
    double reversed[3] = {0.0, 0.0, 0.0};
    NativeCameraResidual{
        reversedPoint,
        1000.0,
        900.0,
        1200.0,
        800.0
    }(rotationB, rotationA, focal, distortion, principal, reversed);
    double residualNormSquared = 0.0;
    for (int axis = 0; axis < 3; ++axis) {
        residualNormSquared += forward[axis] * forward[axis];
        if (std::abs(forward[axis] + reversed[axis]) > 1e-10) {
            return false;
        }
    }
    if (residualNormSquared < 1e-6) {
        return false;
    }

    // Exercise the production spatial splitter. The sealed final partition is
    // deterministic, disjoint from model selection, and exactly 45/15/40 for
    // a 100-observation fixture.
    NativeStarMatch match;
    std::vector<NativeStar> reference;
    for (int row = 0; row < 10; ++row) {
        for (int column = 0; column < 10; ++column) {
            NativeStar source;
            source.x = 40.0 + static_cast<double>(column) * 100.0;
            source.y = 30.0 + static_cast<double>(row) * 80.0;
            source.flux = 1000.0 + static_cast<double>(row * 10 + column);
            NativeStar target = source;
            target.x += 17.0 + 0.03 * source.y;
            target.y -= 9.0 - 0.02 * source.x;
            match.pointsA.push_back(source);
            match.pointsB.push_back(target);
            reference.push_back(source);
        }
    }
    std::vector<int> fit;
    std::vector<int> validation;
    std::vector<int> heldOut;
    native_split_star_matches_for_holdout(match, reference, fit, validation, heldOut);
    if (fit.size() != 45 || validation.size() != 15 || heldOut.size() != 40) {
        return false;
    }
    std::vector<int> fitAgain;
    std::vector<int> validationAgain;
    std::vector<int> heldOutAgain;
    native_split_star_matches_for_holdout(
        match, reference, fitAgain, validationAgain, heldOutAgain
    );
    if (fit != fitAgain || validation != validationAgain || heldOut != heldOutAgain) {
        return false;
    }
    std::set<int> allIndices;
    allIndices.insert(fit.begin(), fit.end());
    allIndices.insert(validation.begin(), validation.end());
    allIndices.insert(heldOut.begin(), heldOut.end());
    if (allIndices.size() != 100) {
        return false;
    }
    NativeStarMatch sparseMatch;
    std::vector<NativeStar> sparseReference;
    for (int index = 0; index < 10; ++index) {
        sparseMatch.pointsA.push_back(match.pointsA[static_cast<size_t>(index)]);
        sparseMatch.pointsB.push_back(match.pointsB[static_cast<size_t>(index)]);
        sparseReference.push_back(reference[static_cast<size_t>(index)]);
    }
    native_split_star_matches_for_holdout(
        sparseMatch, sparseReference, fit, validation, heldOut
    );
    if (fit.size() != 4 || validation.size() != 2 || heldOut.size() != 4) {
        return false;
    }
    allIndices.clear();
    allIndices.insert(fit.begin(), fit.end());
    allIndices.insert(validation.begin(), validation.end());
    allIndices.insert(heldOut.begin(), heldOut.end());
    if (allIndices.size() != 10) {
        return false;
    }

    // Shared grid and optional per-image affine terms are baked into the same
    // existing 4x6 node representation while retaining displacement/Jacobian
    // constraints used by CPU and Metal sampling.
    panolume::LocalWarpModel sharedGrid;
    panolume::LocalWarpModel perImageAffine;
    sharedGrid.images.resize(2);
    perImageAffine.images.resize(2);
    for (size_t image = 0; image < 2; ++image) {
        for (int node = 0; node < panolume::kLocalWarpNodeCount; ++node) {
            const size_t index = static_cast<size_t>(node);
            sharedGrid.images[image].dx[index] = 0.0010;
            sharedGrid.images[image].dy[index] = -0.0005;
            perImageAffine.images[image].dx[index] = image == 0 ? 0.0002 : -0.0002;
            perImageAffine.images[image].dy[index] = image == 0 ? 0.0003 : -0.0003;
        }
    }
    panolume::LocalWarpModel combined;
    panolume::LocalWarpFitReport composeReport;
    if (!native_compose_local_warp_models(
            sharedGrid, perImageAffine, combined, composeReport
        )
        || combined.images.size() != 2
        || std::abs(combined.images[0].dx[0] - 0.0012) > 1e-12
        || std::abs(combined.images[0].dy[0] + 0.0002) > 1e-12
        || std::abs(combined.images[1].dx[0] - 0.0008) > 1e-12
        || std::abs(combined.images[1].dy[0] + 0.0008) > 1e-12
        || composeReport.minimumJacobianDeterminant < 0.7
        || composeReport.maxNormalizedDisplacement > 0.004 + 1e-12) {
        return false;
    }
    NativeImage patchImage;
    patchImage.width = 15;
    patchImage.height = 15;
    patchImage.channels = 3;
    patchImage.pixels.assign(15 * 15 * 3, 0.01f);
    float *patchPixels = patchImage.pixels.data();
    for (int y = 0; y < 15; ++y) {
        for (int x = 0; x < 15; ++x) {
            const double dx = static_cast<double>(x - 7);
            const double dy = static_cast<double>(y - 7);
            const float value = static_cast<float>(0.01 + 0.8 * std::exp(
                -0.5 * (dx * dx / 2.25 + dy * dy / 3.24)
            ));
            const size_t offset = static_cast<size_t>((y * 15 + x) * 3);
            patchPixels[offset] = value;
            patchPixels[offset + 1] = value;
            patchPixels[offset + 2] = value;
        }
    }
    const std::string patchURL = native_worst_star_patch_data_url(patchImage, 7.0, 7.0);
    if (patchURL.rfind("data:image/x-portable-graymap;base64,", 0) != 0
        || patchURL.size() < 200) {
        return false;
    }
    return true;
#endif
}

#include "EngineCABI.hpp"
