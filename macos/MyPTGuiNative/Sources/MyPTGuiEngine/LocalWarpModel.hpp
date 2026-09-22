#pragma once

#include <array>
#include <string>
#include <vector>

namespace panolume {

constexpr int kLocalWarpColumns = 6;
constexpr int kLocalWarpRows = 4;
constexpr int kLocalWarpNodeCount = kLocalWarpColumns * kLocalWarpRows;

struct LocalWarpImageModel {
    std::array<double, kLocalWarpNodeCount> dx{};
    std::array<double, kLocalWarpNodeCount> dy{};
};

struct LocalWarpModel {
    int columns = kLocalWarpColumns;
    int rows = kLocalWarpRows;
    int referenceImage = -1;
    std::vector<LocalWarpImageModel> images;
};

struct LocalWarpLinearObservation {
    int sourceImage = -1;
    int targetImage = -1;
    double sourceU = 0.0;
    double sourceV = 0.0;
    double targetU = 0.0;
    double targetV = 0.0;
    double baseResidualX = 0.0;
    double baseResidualY = 0.0;
    std::array<double, 4> sourceJacobian = {1.0, 0.0, 0.0, 1.0};
};

struct LocalWarpFitReport {
    bool attempted = false;
    bool solverSucceeded = false;
    bool accepted = false;
    int observations = 0;
    double maxNormalizedDisplacement = 0.0;
    double minimumJacobianDeterminant = 1.0;
    double amplitudeRegularization = 0.0;
    double firstDifferenceRegularization = 0.0;
    double curvatureRegularization = 0.0;
    double worstPairImprovement = 0.0;
    double worstGridImprovement = 0.0;
    std::string reason;
};

std::array<double, 2> sample_local_warp(
    const LocalWarpImageModel &image,
    double u,
    double v
);

bool fit_local_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    int referenceImage,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
);

bool fit_shared_lens_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
);

bool fit_zero_mean_per_image_affine_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
);

double minimum_local_warp_jacobian(const LocalWarpModel &model);

bool local_warp_characterization_self_test();

} // namespace panolume
