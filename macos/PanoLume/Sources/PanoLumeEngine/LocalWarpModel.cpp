#include "LocalWarpModel.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <utility>

#if __has_include(<Eigen/Dense>)
#include <Eigen/Dense>
#elif __has_include(<eigen3/Eigen/Dense>)
#include <eigen3/Eigen/Dense>
#endif

namespace panolume {
namespace {

using WeightedNode = std::pair<int, double>;

std::array<double, 4> cubic_weights(double fraction) {
    const double t = std::max(0.0, std::min(1.0, fraction));
    const double t2 = t * t;
    const double t3 = t2 * t;
    return {
        (1.0 - 3.0 * t + 3.0 * t2 - t3) / 6.0,
        (4.0 - 6.0 * t2 + 3.0 * t3) / 6.0,
        (1.0 + 3.0 * t + 3.0 * t2 - 3.0 * t3) / 6.0,
        t3 / 6.0
    };
}

std::vector<WeightedNode> local_warp_weights(double u, double v) {
    u = std::max(0.0, std::min(1.0, u));
    v = std::max(0.0, std::min(1.0, v));
    const double gx = u * static_cast<double>(kLocalWarpColumns - 1);
    const double gy = v * static_cast<double>(kLocalWarpRows - 1);
    const int baseX = static_cast<int>(std::floor(gx));
    const int baseY = static_cast<int>(std::floor(gy));
    const auto wx = cubic_weights(gx - std::floor(gx));
    const auto wy = cubic_weights(gy - std::floor(gy));
    std::map<int, double> accumulated;
    for (int row = 0; row < 4; ++row) {
        const int y = std::max(0, std::min(kLocalWarpRows - 1, baseY + row - 1));
        for (int column = 0; column < 4; ++column) {
            const int x = std::max(0, std::min(kLocalWarpColumns - 1, baseX + column - 1));
            accumulated[y * kLocalWarpColumns + x] += wy[static_cast<std::size_t>(row)]
                * wx[static_cast<std::size_t>(column)];
        }
    }
    return {accumulated.begin(), accumulated.end()};
}

int variable_index(int image, int node, int axis, int referenceImage) {
    if (image == referenceImage) return -1;
    const int compactImage = image < referenceImage ? image : image - 1;
    return (compactImage * kLocalWarpNodeCount + node) * 2 + axis;
}

} // namespace

std::array<double, 2> sample_local_warp(
    const LocalWarpImageModel &image,
    double u,
    double v
) {
    std::array<double, 2> displacement = {0.0, 0.0};
    for (const auto &[node, weight] : local_warp_weights(u, v)) {
        displacement[0] += image.dx[static_cast<std::size_t>(node)] * weight;
        displacement[1] += image.dy[static_cast<std::size_t>(node)] * weight;
    }
    return displacement;
}

double minimum_local_warp_jacobian(const LocalWarpModel &model) {
    double minimum = std::numeric_limits<double>::infinity();
    constexpr double epsilon = 1e-4;
    for (const LocalWarpImageModel &image : model.images) {
        for (int row = 0; row <= 20; ++row) {
            for (int column = 0; column <= 30; ++column) {
                const double u = static_cast<double>(column) / 30.0;
                const double v = static_cast<double>(row) / 20.0;
                const auto left = sample_local_warp(image, std::max(0.0, u - epsilon), v);
                const auto right = sample_local_warp(image, std::min(1.0, u + epsilon), v);
                const auto top = sample_local_warp(image, u, std::max(0.0, v - epsilon));
                const auto bottom = sample_local_warp(image, u, std::min(1.0, v + epsilon));
                const double du = std::max(std::min(1.0, u + epsilon) - std::max(0.0, u - epsilon), 1e-9);
                const double dv = std::max(std::min(1.0, v + epsilon) - std::max(0.0, v - epsilon), 1e-9);
                const double j00 = 1.0 + (right[0] - left[0]) / du;
                const double j10 = (right[1] - left[1]) / du;
                const double j01 = (bottom[0] - top[0]) / dv;
                const double j11 = 1.0 + (bottom[1] - top[1]) / dv;
                minimum = std::min(minimum, j00 * j11 - j01 * j10);
            }
        }
    }
    return std::isfinite(minimum) ? minimum : 1.0;
}

bool fit_local_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    int referenceImage,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
) {
    report = LocalWarpFitReport();
    report.attempted = true;
    report.observations = static_cast<int>(observations.size());
    report.amplitudeRegularization = 2.0e5;
    report.firstDifferenceRegularization = 8.0e5;
    report.curvatureRegularization = 2.0e6;
    const int imageCount = static_cast<int>(imageDimensions.size());
    if (imageCount < 2 || referenceImage < 0 || referenceImage >= imageCount
        || observations.size() < 24) {
        report.reason = "local warp requires at least two images and 24 training observations";
        return false;
    }
#if __has_include(<Eigen/Dense>) || __has_include(<eigen3/Eigen/Dense>)
    const int variableCount = (imageCount - 1) * kLocalWarpNodeCount * 2;
    Eigen::MatrixXd normal = Eigen::MatrixXd::Zero(variableCount, variableCount);
    Eigen::VectorXd rhs = Eigen::VectorXd::Zero(variableCount);
    auto addEquation = [&](const std::vector<std::pair<int, double>> &coefficients, double target, double weight) {
        for (const auto &[row, rowValue] : coefficients) {
            if (row < 0) continue;
            rhs[row] += weight * rowValue * target;
            for (const auto &[column, columnValue] : coefficients) {
                if (column < 0) continue;
                normal(row, column) += weight * rowValue * columnValue;
            }
        }
    };
    for (const LocalWarpLinearObservation &observation : observations) {
        if (observation.sourceImage < 0 || observation.targetImage < 0
            || observation.sourceImage >= imageCount || observation.targetImage >= imageCount) continue;
        const double sourceWidth = std::max(1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][0] - 1);
        const double sourceHeight = std::max(1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][1] - 1);
        const double targetWidth = std::max(1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][0] - 1);
        const double targetHeight = std::max(1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][1] - 1);
        const auto sourceWeights = local_warp_weights(observation.sourceU, observation.sourceV);
        const auto targetWeights = local_warp_weights(observation.targetU, observation.targetV);
        std::vector<std::pair<int, double>> xCoefficients;
        std::vector<std::pair<int, double>> yCoefficients;
        for (const auto &[node, weight] : sourceWeights) {
            xCoefficients.push_back({variable_index(observation.sourceImage, node, 0, referenceImage),
                -observation.sourceJacobian[0] * sourceWidth * weight});
            xCoefficients.push_back({variable_index(observation.sourceImage, node, 1, referenceImage),
                -observation.sourceJacobian[1] * sourceHeight * weight});
            yCoefficients.push_back({variable_index(observation.sourceImage, node, 0, referenceImage),
                -observation.sourceJacobian[2] * sourceWidth * weight});
            yCoefficients.push_back({variable_index(observation.sourceImage, node, 1, referenceImage),
                -observation.sourceJacobian[3] * sourceHeight * weight});
        }
        for (const auto &[node, weight] : targetWeights) {
            xCoefficients.push_back({variable_index(observation.targetImage, node, 0, referenceImage), targetWidth * weight});
            yCoefficients.push_back({variable_index(observation.targetImage, node, 1, referenceImage), targetHeight * weight});
        }
        const double residual = std::hypot(observation.baseResidualX, observation.baseResidualY);
        const double robustWeight = residual <= 4.0 ? 1.0 : std::max(0.15, 4.0 / residual);
        addEquation(xCoefficients, -observation.baseResidualX, robustWeight);
        addEquation(yCoefficients, -observation.baseResidualY, robustWeight);
    }
    normal.diagonal().array() += report.amplitudeRegularization;
    auto addRegularizer = [&](int image, const std::vector<std::pair<int, double>> &nodes, int axis, double weight) {
        std::vector<std::pair<int, double>> equation;
        for (const auto &[node, coefficient] : nodes) {
            equation.push_back({variable_index(image, node, axis, referenceImage), coefficient});
        }
        addEquation(equation, 0.0, weight);
    };
    for (int image = 0; image < imageCount; ++image) {
        if (image == referenceImage) continue;
        for (int row = 0; row < kLocalWarpRows; ++row) {
            for (int column = 0; column < kLocalWarpColumns; ++column) {
                const int node = row * kLocalWarpColumns + column;
                for (int axis = 0; axis < 2; ++axis) {
                    if (column + 1 < kLocalWarpColumns) {
                        addRegularizer(image, {{node, -1.0}, {node + 1, 1.0}}, axis, report.firstDifferenceRegularization);
                    }
                    if (row + 1 < kLocalWarpRows) {
                        addRegularizer(image, {{node, -1.0}, {node + kLocalWarpColumns, 1.0}}, axis, report.firstDifferenceRegularization);
                    }
                    if (column + 2 < kLocalWarpColumns) {
                        addRegularizer(image, {{node, 1.0}, {node + 1, -2.0}, {node + 2, 1.0}}, axis, report.curvatureRegularization);
                    }
                    if (row + 2 < kLocalWarpRows) {
                        addRegularizer(image, {{node, 1.0}, {node + kLocalWarpColumns, -2.0}, {node + 2 * kLocalWarpColumns, 1.0}}, axis, report.curvatureRegularization);
                    }
                }
            }
        }
    }
    Eigen::LDLT<Eigen::MatrixXd> decomposition(normal);
    if (decomposition.info() != Eigen::Success) {
        report.reason = "local warp normal equations are singular";
        return false;
    }
    const Eigen::VectorXd solution = decomposition.solve(rhs);
    if (decomposition.info() != Eigen::Success || !solution.allFinite()) {
        report.reason = "local warp solve produced non-finite coefficients";
        return false;
    }
    model = LocalWarpModel();
    model.referenceImage = referenceImage;
    model.images.resize(static_cast<std::size_t>(imageCount));
    constexpr double displacementLimit = 0.004;
    for (int image = 0; image < imageCount; ++image) {
        if (image == referenceImage) continue;
        for (int node = 0; node < kLocalWarpNodeCount; ++node) {
            const int xIndex = variable_index(image, node, 0, referenceImage);
            const int yIndex = variable_index(image, node, 1, referenceImage);
            const double dx = std::max(-displacementLimit, std::min(displacementLimit, solution[xIndex]));
            const double dy = std::max(-displacementLimit, std::min(displacementLimit, solution[yIndex]));
            model.images[static_cast<std::size_t>(image)].dx[static_cast<std::size_t>(node)] = dx;
            model.images[static_cast<std::size_t>(image)].dy[static_cast<std::size_t>(node)] = dy;
            report.maxNormalizedDisplacement = std::max(report.maxNormalizedDisplacement, std::max(std::abs(dx), std::abs(dy)));
        }
    }
    report.minimumJacobianDeterminant = minimum_local_warp_jacobian(model);
    report.solverSucceeded = report.minimumJacobianDeterminant >= 0.7;
    report.reason = report.solverSucceeded
        ? "constrained local warp solved without foldover"
        : "local warp rejected because its minimum Jacobian determinant is below 0.7";
    return report.solverSucceeded;
#else
    (void)model;
    report.reason = "Eigen is unavailable for local warp fitting";
    return false;
#endif
}

bool fit_shared_lens_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
) {
    report = LocalWarpFitReport();
    report.attempted = true;
    report.observations = static_cast<int>(observations.size());
    report.amplitudeRegularization = 2.0e5;
    report.firstDifferenceRegularization = 8.0e5;
    report.curvatureRegularization = 2.0e6;
    const int imageCount = static_cast<int>(imageDimensions.size());
    if (imageCount < 2 || observations.size() < 24) {
        report.reason = "shared lens warp requires at least two images and 24 fit observations";
        return false;
    }
#if __has_include(<Eigen/Dense>) || __has_include(<eigen3/Eigen/Dense>)
    const int variableCount = kLocalWarpNodeCount * 2;
    Eigen::MatrixXd normal = Eigen::MatrixXd::Zero(variableCount, variableCount);
    Eigen::VectorXd rhs = Eigen::VectorXd::Zero(variableCount);
    auto variableIndex = [](int node, int axis) { return node * 2 + axis; };
    auto addEquation = [&](const std::vector<std::pair<int, double>> &coefficients,
                           double target,
                           double weight) {
        for (const auto &[row, rowValue] : coefficients) {
            rhs[row] += weight * rowValue * target;
            for (const auto &[column, columnValue] : coefficients) {
                normal(row, column) += weight * rowValue * columnValue;
            }
        }
    };
    for (const LocalWarpLinearObservation &observation : observations) {
        if (observation.sourceImage < 0 || observation.targetImage < 0
            || observation.sourceImage >= imageCount || observation.targetImage >= imageCount) continue;
        const double sourceWidth = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][0] - 1
        );
        const double sourceHeight = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][1] - 1
        );
        const double targetWidth = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][0] - 1
        );
        const double targetHeight = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][1] - 1
        );
        const auto sourceWeights = local_warp_weights(observation.sourceU, observation.sourceV);
        const auto targetWeights = local_warp_weights(observation.targetU, observation.targetV);
        std::vector<std::pair<int, double>> xCoefficients;
        std::vector<std::pair<int, double>> yCoefficients;
        for (const auto &[node, weight] : sourceWeights) {
            xCoefficients.push_back({variableIndex(node, 0),
                -observation.sourceJacobian[0] * sourceWidth * weight});
            xCoefficients.push_back({variableIndex(node, 1),
                -observation.sourceJacobian[1] * sourceHeight * weight});
            yCoefficients.push_back({variableIndex(node, 0),
                -observation.sourceJacobian[2] * sourceWidth * weight});
            yCoefficients.push_back({variableIndex(node, 1),
                -observation.sourceJacobian[3] * sourceHeight * weight});
        }
        for (const auto &[node, weight] : targetWeights) {
            xCoefficients.push_back({variableIndex(node, 0), targetWidth * weight});
            yCoefficients.push_back({variableIndex(node, 1), targetHeight * weight});
        }
        const double residual = std::hypot(observation.baseResidualX, observation.baseResidualY);
        const double robustWeight = residual <= 4.0 ? 1.0 : std::max(0.15, 4.0 / residual);
        addEquation(xCoefficients, -observation.baseResidualX, robustWeight);
        addEquation(yCoefficients, -observation.baseResidualY, robustWeight);
    }
    normal.diagonal().array() += report.amplitudeRegularization;
    auto addRegularizer = [&](const std::vector<std::pair<int, double>> &nodes,
                              int axis,
                              double weight) {
        std::vector<std::pair<int, double>> equation;
        for (const auto &[node, coefficient] : nodes) {
            equation.push_back({variableIndex(node, axis), coefficient});
        }
        addEquation(equation, 0.0, weight);
    };
    for (int row = 0; row < kLocalWarpRows; ++row) {
        for (int column = 0; column < kLocalWarpColumns; ++column) {
            const int node = row * kLocalWarpColumns + column;
            for (int axis = 0; axis < 2; ++axis) {
                if (column + 1 < kLocalWarpColumns) {
                    addRegularizer({{node, -1.0}, {node + 1, 1.0}}, axis, report.firstDifferenceRegularization);
                }
                if (row + 1 < kLocalWarpRows) {
                    addRegularizer({{node, -1.0}, {node + kLocalWarpColumns, 1.0}}, axis, report.firstDifferenceRegularization);
                }
                if (column + 2 < kLocalWarpColumns) {
                    addRegularizer({{node, 1.0}, {node + 1, -2.0}, {node + 2, 1.0}}, axis, report.curvatureRegularization);
                }
                if (row + 2 < kLocalWarpRows) {
                    addRegularizer({{node, 1.0}, {node + kLocalWarpColumns, -2.0}, {node + 2 * kLocalWarpColumns, 1.0}}, axis, report.curvatureRegularization);
                }
            }
        }
    }
    Eigen::LDLT<Eigen::MatrixXd> decomposition(normal);
    if (decomposition.info() != Eigen::Success) {
        report.reason = "shared lens warp normal equations are singular";
        return false;
    }
    const Eigen::VectorXd solution = decomposition.solve(rhs);
    if (decomposition.info() != Eigen::Success || !solution.allFinite()) {
        report.reason = "shared lens warp solve produced non-finite coefficients";
        return false;
    }
    model = LocalWarpModel();
    model.referenceImage = -1;
    model.images.resize(static_cast<std::size_t>(imageCount));
    constexpr double displacementLimit = 0.004;
    LocalWarpImageModel shared;
    for (int node = 0; node < kLocalWarpNodeCount; ++node) {
        const double dx = std::max(-displacementLimit, std::min(
            displacementLimit, solution[variableIndex(node, 0)]
        ));
        const double dy = std::max(-displacementLimit, std::min(
            displacementLimit, solution[variableIndex(node, 1)]
        ));
        shared.dx[static_cast<std::size_t>(node)] = dx;
        shared.dy[static_cast<std::size_t>(node)] = dy;
        report.maxNormalizedDisplacement = std::max(
            report.maxNormalizedDisplacement, std::max(std::abs(dx), std::abs(dy))
        );
    }
    std::fill(model.images.begin(), model.images.end(), shared);
    report.minimumJacobianDeterminant = minimum_local_warp_jacobian(model);
    report.solverSucceeded = report.minimumJacobianDeterminant >= 0.7;
    report.reason = report.solverSucceeded
        ? "shared lens-coordinate warp solved and baked identically into every image"
        : "shared lens warp rejected because its minimum Jacobian determinant is below 0.7";
    return report.solverSucceeded;
#else
    (void)model;
    report.reason = "Eigen is unavailable for shared lens warp fitting";
    return false;
#endif
}

bool fit_zero_mean_per_image_affine_warp_linearized(
    const std::vector<std::array<int, 2>> &imageDimensions,
    const std::vector<LocalWarpLinearObservation> &observations,
    LocalWarpModel &model,
    LocalWarpFitReport &report
) {
    report = LocalWarpFitReport();
    report.attempted = true;
    report.observations = static_cast<int>(observations.size());
    report.amplitudeRegularization = 5.0e5;
    report.firstDifferenceRegularization = 2.0e6;
    report.curvatureRegularization = 1.0e8; // zero-mean cross-image constraint
    const int imageCount = static_cast<int>(imageDimensions.size());
    if (imageCount < 2 || observations.size() < 24) {
        report.reason = "per-image affine residual requires at least two images and 24 fit observations";
        return false;
    }
#if __has_include(<Eigen/Dense>) || __has_include(<eigen3/Eigen/Dense>)
    constexpr int parametersPerImage = 6;
    const int variableCount = imageCount * parametersPerImage;
    Eigen::MatrixXd normal = Eigen::MatrixXd::Zero(variableCount, variableCount);
    Eigen::VectorXd rhs = Eigen::VectorXd::Zero(variableCount);
    auto variableIndex = [](int image, int axis, int term) {
        return image * parametersPerImage + axis * 3 + term;
    };
    auto addEquation = [&](const std::vector<std::pair<int, double>> &coefficients,
                           double target,
                           double weight) {
        for (const auto &[row, rowValue] : coefficients) {
            rhs[row] += weight * rowValue * target;
            for (const auto &[column, columnValue] : coefficients) {
                normal(row, column) += weight * rowValue * columnValue;
            }
        }
    };
    auto affineBasis = [](double u, double v) {
        return std::array<double, 3>{1.0, u - 0.5, v - 0.5};
    };
    for (const LocalWarpLinearObservation &observation : observations) {
        if (observation.sourceImage < 0 || observation.targetImage < 0
            || observation.sourceImage >= imageCount || observation.targetImage >= imageCount) continue;
        const double sourceWidth = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][0] - 1
        );
        const double sourceHeight = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.sourceImage)][1] - 1
        );
        const double targetWidth = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][0] - 1
        );
        const double targetHeight = std::max(
            1, imageDimensions[static_cast<std::size_t>(observation.targetImage)][1] - 1
        );
        const auto sourceBasis = affineBasis(observation.sourceU, observation.sourceV);
        const auto targetBasis = affineBasis(observation.targetU, observation.targetV);
        std::vector<std::pair<int, double>> xCoefficients;
        std::vector<std::pair<int, double>> yCoefficients;
        for (int term = 0; term < 3; ++term) {
            xCoefficients.push_back({variableIndex(observation.sourceImage, 0, term),
                -observation.sourceJacobian[0] * sourceWidth * sourceBasis[static_cast<std::size_t>(term)]});
            xCoefficients.push_back({variableIndex(observation.sourceImage, 1, term),
                -observation.sourceJacobian[1] * sourceHeight * sourceBasis[static_cast<std::size_t>(term)]});
            yCoefficients.push_back({variableIndex(observation.sourceImage, 0, term),
                -observation.sourceJacobian[2] * sourceWidth * sourceBasis[static_cast<std::size_t>(term)]});
            yCoefficients.push_back({variableIndex(observation.sourceImage, 1, term),
                -observation.sourceJacobian[3] * sourceHeight * sourceBasis[static_cast<std::size_t>(term)]});
            xCoefficients.push_back({variableIndex(observation.targetImage, 0, term),
                targetWidth * targetBasis[static_cast<std::size_t>(term)]});
            yCoefficients.push_back({variableIndex(observation.targetImage, 1, term),
                targetHeight * targetBasis[static_cast<std::size_t>(term)]});
        }
        const double residual = std::hypot(observation.baseResidualX, observation.baseResidualY);
        const double robustWeight = residual <= 4.0 ? 1.0 : std::max(0.15, 4.0 / residual);
        addEquation(xCoefficients, -observation.baseResidualX, robustWeight);
        addEquation(yCoefficients, -observation.baseResidualY, robustWeight);
    }
    for (int image = 0; image < imageCount; ++image) {
        for (int axis = 0; axis < 2; ++axis) {
            normal(variableIndex(image, axis, 0), variableIndex(image, axis, 0))
                += report.amplitudeRegularization;
            for (int term = 1; term < 3; ++term) {
                normal(variableIndex(image, axis, term), variableIndex(image, axis, term))
                    += report.firstDifferenceRegularization;
            }
        }
    }
    for (int axis = 0; axis < 2; ++axis) {
        for (int term = 0; term < 3; ++term) {
            std::vector<std::pair<int, double>> zeroMean;
            for (int image = 0; image < imageCount; ++image) {
                zeroMean.push_back({variableIndex(image, axis, term), 1.0 / imageCount});
            }
            addEquation(zeroMean, 0.0, report.curvatureRegularization);
        }
    }
    Eigen::LDLT<Eigen::MatrixXd> decomposition(normal);
    if (decomposition.info() != Eigen::Success) {
        report.reason = "per-image affine residual normal equations are singular";
        return false;
    }
    const Eigen::VectorXd solution = decomposition.solve(rhs);
    if (decomposition.info() != Eigen::Success || !solution.allFinite()) {
        report.reason = "per-image affine residual solve produced non-finite coefficients";
        return false;
    }
    model = LocalWarpModel();
    model.referenceImage = -1;
    model.images.resize(static_cast<std::size_t>(imageCount));
    constexpr double displacementLimit = 0.004;
    for (int image = 0; image < imageCount; ++image) {
        for (int row = 0; row < kLocalWarpRows; ++row) {
            for (int column = 0; column < kLocalWarpColumns; ++column) {
                const double u = static_cast<double>(column) / (kLocalWarpColumns - 1);
                const double v = static_cast<double>(row) / (kLocalWarpRows - 1);
                const std::array<double, 3> basis = {1.0, u - 0.5, v - 0.5};
                const int node = row * kLocalWarpColumns + column;
                double displacement[2] = {0.0, 0.0};
                for (int axis = 0; axis < 2; ++axis) {
                    for (int term = 0; term < 3; ++term) {
                        displacement[axis] += solution[variableIndex(image, axis, term)]
                            * basis[static_cast<std::size_t>(term)];
                    }
                    displacement[axis] = std::max(-displacementLimit, std::min(
                        displacementLimit, displacement[axis]
                    ));
                }
                model.images[static_cast<std::size_t>(image)].dx[static_cast<std::size_t>(node)] = displacement[0];
                model.images[static_cast<std::size_t>(image)].dy[static_cast<std::size_t>(node)] = displacement[1];
                report.maxNormalizedDisplacement = std::max(
                    report.maxNormalizedDisplacement,
                    std::max(std::abs(displacement[0]), std::abs(displacement[1]))
                );
            }
        }
    }
    report.minimumJacobianDeterminant = minimum_local_warp_jacobian(model);
    report.solverSucceeded = report.minimumJacobianDeterminant >= 0.7;
    report.reason = report.solverSucceeded
        ? "zero-mean strongly regularized per-image affine residual baked into 4x6 nodes"
        : "per-image affine residual rejected because its minimum Jacobian determinant is below 0.7";
    return report.solverSucceeded;
#else
    (void)model;
    report.reason = "Eigen is unavailable for per-image affine residual fitting";
    return false;
#endif
}

bool local_warp_characterization_self_test() {
    std::vector<std::array<int, 2>> dimensions = {{4000, 3000}, {4000, 3000}};
    std::vector<LocalWarpLinearObservation> observations;
    for (int row = 0; row < 10; ++row) {
        for (int column = 0; column < 12; ++column) {
            LocalWarpLinearObservation observation;
            observation.sourceImage = 0;
            observation.targetImage = 1;
            observation.sourceU = static_cast<double>(column) / 11.0;
            observation.sourceV = static_cast<double>(row) / 9.0;
            observation.targetU = observation.sourceU;
            observation.targetV = observation.sourceV;
            observation.baseResidualX = -4.0;
            observation.baseResidualY = 1.5;
            observations.push_back(observation);
        }
    }
    LocalWarpModel model;
    LocalWarpFitReport report;
    if (!fit_local_warp_linearized(dimensions, 0, observations, model, report)
        || model.images.size() != 2 || !report.solverSucceeded
        || report.minimumJacobianDeterminant < 0.7
        || report.maxNormalizedDisplacement > 0.004 + 1e-12) {
        return false;
    }
    const auto displacement = sample_local_warp(model.images[1], 0.5, 0.5);
    if (!(displacement[0] > 0.0005 && displacement[0] <= 0.004
        && displacement[1] < -0.0002 && displacement[1] >= -0.004)) return false;

    std::vector<LocalWarpLinearObservation> sharedObservations;
    for (int row = 0; row < 12; ++row) {
        for (int column = 0; column < 14; ++column) {
            LocalWarpLinearObservation observation;
            observation.sourceImage = 0;
            observation.targetImage = 1;
            observation.sourceU = 0.05 + 0.60 * static_cast<double>(column) / 13.0;
            observation.sourceV = 0.05 + 0.90 * static_cast<double>(row) / 11.0;
            observation.targetU = observation.sourceU + 0.25;
            observation.targetV = observation.sourceV;
            observation.baseResidualX = -3.0 * (observation.targetU - observation.sourceU);
            observation.baseResidualY = 1.5 * (observation.targetV * observation.targetV
                - observation.sourceV * observation.sourceV);
            sharedObservations.push_back(observation);
        }
    }
    LocalWarpModel sharedModel;
    LocalWarpFitReport sharedReport;
    if (!(fit_shared_lens_warp_linearized(
            dimensions, sharedObservations, sharedModel, sharedReport
        )
        && sharedModel.referenceImage == -1
        && sharedModel.images.size() == 2
        && sharedModel.images[0].dx == sharedModel.images[1].dx
        && sharedModel.images[0].dy == sharedModel.images[1].dy
        && sharedReport.minimumJacobianDeterminant >= 0.7
        && sharedReport.maxNormalizedDisplacement <= 0.004 + 1e-12)) return false;

    LocalWarpModel affineModel;
    LocalWarpFitReport affineReport;
    if (!fit_zero_mean_per_image_affine_warp_linearized(
            dimensions, observations, affineModel, affineReport
        )
        || affineModel.images.size() != 2
        || affineReport.minimumJacobianDeterminant < 0.7
        || affineReport.maxNormalizedDisplacement > 0.004 + 1e-12) return false;
    for (int node = 0; node < kLocalWarpNodeCount; ++node) {
        if (std::abs(affineModel.images[0].dx[static_cast<std::size_t>(node)]
            + affineModel.images[1].dx[static_cast<std::size_t>(node)]) > 5e-4) return false;
        if (std::abs(affineModel.images[0].dy[static_cast<std::size_t>(node)]
            + affineModel.images[1].dy[static_cast<std::size_t>(node)]) > 5e-4) return false;
    }
    return true;
}

} // namespace panolume
