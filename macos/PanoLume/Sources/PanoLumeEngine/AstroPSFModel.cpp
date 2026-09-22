#include "AstroPSFModel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace panolume {
namespace {

constexpr int kParameterCount = 7;

double median(std::vector<double> values) {
    if (values.empty()) return 0.0;
    const std::size_t middle = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + middle, values.end());
    const double high = values[middle];
    if ((values.size() & 1U) != 0U) return high;
    std::nth_element(values.begin(), values.begin() + middle - 1, values.end());
    return 0.5 * (values[middle - 1] + high);
}

bool solve_linear_system(
    std::array<std::array<double, kParameterCount>, kParameterCount> matrix,
    std::array<double, kParameterCount> rhs,
    std::array<double, kParameterCount> &solution
) {
    for (int pivot = 0; pivot < kParameterCount; ++pivot) {
        int best = pivot;
        for (int row = pivot + 1; row < kParameterCount; ++row) {
            if (std::abs(matrix[row][pivot]) > std::abs(matrix[best][pivot])) best = row;
        }
        if (!std::isfinite(matrix[best][pivot]) || std::abs(matrix[best][pivot]) < 1e-12) {
            return false;
        }
        if (best != pivot) {
            std::swap(matrix[best], matrix[pivot]);
            std::swap(rhs[best], rhs[pivot]);
        }
        const double diagonal = matrix[pivot][pivot];
        for (int column = pivot; column < kParameterCount; ++column) {
            matrix[pivot][column] /= diagonal;
        }
        rhs[pivot] /= diagonal;
        for (int row = 0; row < kParameterCount; ++row) {
            if (row == pivot) continue;
            const double factor = matrix[row][pivot];
            if (factor == 0.0) continue;
            for (int column = pivot; column < kParameterCount; ++column) {
                matrix[row][column] -= factor * matrix[pivot][column];
            }
            rhs[row] -= factor * rhs[pivot];
        }
    }
    solution = rhs;
    for (double value : solution) {
        if (!std::isfinite(value)) return false;
    }
    return true;
}

struct Evaluation {
    double model = 0.0;
    std::array<double, kParameterCount> derivative{};
};

Evaluation evaluate(double x, double y, const std::array<double, kParameterCount> &p) {
    const double background = p[0];
    const double amplitude = std::exp(p[1]);
    const double centerX = p[2];
    const double centerY = p[3];
    const double sigmaX = std::exp(p[4]);
    const double sigmaY = std::exp(p[5]);
    const double angle = p[6];
    const double cosine = std::cos(angle);
    const double sine = std::sin(angle);
    const double dx = x - centerX;
    const double dy = y - centerY;
    const double rotatedX = cosine * dx + sine * dy;
    const double rotatedY = -sine * dx + cosine * dy;
    const double inverseX2 = 1.0 / std::max(sigmaX * sigmaX, 1e-12);
    const double inverseY2 = 1.0 / std::max(sigmaY * sigmaY, 1e-12);
    const double exponent = -0.5 * (
        rotatedX * rotatedX * inverseX2 + rotatedY * rotatedY * inverseY2
    );
    const double gaussian = amplitude * std::exp(std::max(-60.0, exponent));
    Evaluation result;
    result.model = background + gaussian;
    result.derivative[0] = 1.0;
    result.derivative[1] = gaussian;
    result.derivative[2] = gaussian * (
        rotatedX * cosine * inverseX2 - rotatedY * sine * inverseY2
    );
    result.derivative[3] = gaussian * (
        rotatedX * sine * inverseX2 + rotatedY * cosine * inverseY2
    );
    result.derivative[4] = gaussian * rotatedX * rotatedX * inverseX2;
    result.derivative[5] = gaussian * rotatedY * rotatedY * inverseY2;
    result.derivative[6] = gaussian * rotatedX * rotatedY * (inverseY2 - inverseX2);
    return result;
}

double fit_cost(
    const std::vector<double> &pixels,
    int width,
    int height,
    double noise,
    const std::array<double, kParameterCount> &parameters
) {
    double cost = 0.0;
    const double huber = std::max(2.5 * noise, 1e-12);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double residual = pixels[static_cast<std::size_t>(y * width + x)]
                - evaluate(static_cast<double>(x), static_cast<double>(y), parameters).model;
            const double magnitude = std::abs(residual);
            cost += magnitude <= huber
                ? 0.5 * residual * residual
                : huber * (magnitude - 0.5 * huber);
        }
    }
    return cost;
}

} // namespace

EllipticalGaussianPSF fit_elliptical_gaussian_psf(
    const std::vector<double> &pixels,
    int width,
    int height,
    double noiseSigma
) {
    EllipticalGaussianPSF result;
    if (width < 7 || height < 7
        || pixels.size() != static_cast<std::size_t>(width * height)
        || !std::isfinite(noiseSigma) || noiseSigma <= 0.0) {
        result.reason = "invalid_patch";
        return result;
    }
    std::vector<double> border;
    border.reserve(static_cast<std::size_t>(2 * width + 2 * height));
    double maximum = -std::numeric_limits<double>::infinity();
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double value = pixels[static_cast<std::size_t>(y * width + x)];
            if (!std::isfinite(value)) {
                result.reason = "non_finite_patch";
                return result;
            }
            maximum = std::max(maximum, value);
            if (x == 0 || y == 0 || x == width - 1 || y == height - 1) border.push_back(value);
        }
    }
    const double background = median(border);
    const double amplitude = maximum - background;
    if (!std::isfinite(amplitude) || amplitude < 5.0 * noiseSigma) {
        result.reason = "low_signal_to_noise";
        return result;
    }

    double total = 0.0;
    double sumX = 0.0;
    double sumY = 0.0;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double weight = std::max(
                pixels[static_cast<std::size_t>(y * width + x)] - background,
                0.0
            );
            total += weight;
            sumX += weight * static_cast<double>(x);
            sumY += weight * static_cast<double>(y);
        }
    }
    if (total <= 0.0) {
        result.reason = "empty_signal";
        return result;
    }
    const double initialX = sumX / total;
    const double initialY = sumY / total;
    double momentXX = 0.0;
    double momentXY = 0.0;
    double momentYY = 0.0;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double weight = std::max(
                pixels[static_cast<std::size_t>(y * width + x)] - background,
                0.0
            );
            const double dx = static_cast<double>(x) - initialX;
            const double dy = static_cast<double>(y) - initialY;
            momentXX += weight * dx * dx;
            momentXY += weight * dx * dy;
            momentYY += weight * dy * dy;
        }
    }
    momentXX /= total;
    momentXY /= total;
    momentYY /= total;
    const double trace = momentXX + momentYY;
    const double discriminant = std::sqrt(std::max(
        0.0,
        (momentXX - momentYY) * (momentXX - momentYY) + 4.0 * momentXY * momentXY
    ));
    const double majorVariance = std::max(0.36, 0.5 * (trace + discriminant));
    const double minorVariance = std::max(0.36, 0.5 * (trace - discriminant));
    const double initialAngle = 0.5 * std::atan2(2.0 * momentXY, momentXX - momentYY);

    std::array<double, kParameterCount> parameters = {
        background,
        std::log(std::max(amplitude, noiseSigma)),
        initialX,
        initialY,
        std::log(std::sqrt(majorVariance)),
        std::log(std::sqrt(minorVariance)),
        initialAngle
    };
    double damping = 1e-3;
    double currentCost = fit_cost(pixels, width, height, noiseSigma, parameters);
    for (int iteration = 0; iteration < 16; ++iteration) {
        std::array<std::array<double, kParameterCount>, kParameterCount> normal{};
        std::array<double, kParameterCount> rhs{};
        const double huber = std::max(2.5 * noiseSigma, 1e-12);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const Evaluation evaluation = evaluate(
                    static_cast<double>(x), static_cast<double>(y), parameters
                );
                const double residual = pixels[static_cast<std::size_t>(y * width + x)] - evaluation.model;
                const double robustWeight = std::abs(residual) <= huber
                    ? 1.0
                    : huber / std::max(std::abs(residual), 1e-12);
                for (int row = 0; row < kParameterCount; ++row) {
                    rhs[row] += robustWeight * evaluation.derivative[row] * residual;
                    for (int column = 0; column < kParameterCount; ++column) {
                        normal[row][column] += robustWeight
                            * evaluation.derivative[row] * evaluation.derivative[column];
                    }
                }
            }
        }
        for (int diagonal = 0; diagonal < kParameterCount; ++diagonal) {
            normal[diagonal][diagonal] += damping * std::max(normal[diagonal][diagonal], 1.0);
        }
        std::array<double, kParameterCount> delta{};
        if (!solve_linear_system(normal, rhs, delta)) {
            result.reason = "singular_fit";
            return result;
        }
        std::array<double, kParameterCount> candidate = parameters;
        for (int parameter = 0; parameter < kParameterCount; ++parameter) {
            candidate[parameter] += delta[parameter];
        }
        candidate[1] = std::max(
            std::log(noiseSigma),
            std::min(std::log(std::max(amplitude * 4.0, noiseSigma)), candidate[1])
        );
        candidate[2] = std::max(-0.5, std::min(static_cast<double>(width) - 0.5, candidate[2]));
        candidate[3] = std::max(-0.5, std::min(static_cast<double>(height) - 0.5, candidate[3]));
        candidate[4] = std::max(std::log(0.5), std::min(std::log(8.0), candidate[4]));
        candidate[5] = std::max(std::log(0.5), std::min(std::log(8.0), candidate[5]));
        const double candidateCost = fit_cost(pixels, width, height, noiseSigma, candidate);
        if (std::isfinite(candidateCost) && candidateCost < currentCost) {
            parameters = candidate;
            const double improvement = currentCost - candidateCost;
            currentCost = candidateCost;
            damping = std::max(1e-8, damping * 0.35);
            result.iterations = iteration + 1;
            if (improvement <= std::max(1e-12, currentCost * 1e-9)) break;
        } else {
            damping = std::min(1e8, damping * 10.0);
            if (damping >= 1e7) break;
        }
    }

    const double sigmaA = std::exp(parameters[4]);
    const double sigmaB = std::exp(parameters[5]);
    const double fittedAmplitude = std::exp(parameters[1]);
    // Identity-quality PSFs need a stable sub-pixel centre, not merely a
    // detectable peak. Ten-sigma fitted amplitude is a fixed pre-partition
    // measurement gate; weaker detections remain available to ordinary image
    // processing but never enter fit/validation/final astro correspondence.
    if (!std::isfinite(fittedAmplitude) || fittedAmplitude < 10.0 * noiseSigma) {
        result.reason = "low_signal_to_noise";
        return result;
    }
    const double centerMargin = 1.0;
    if (parameters[2] < centerMargin || parameters[2] > static_cast<double>(width - 1) - centerMargin
        || parameters[3] < centerMargin || parameters[3] > static_cast<double>(height - 1) - centerMargin) {
        result.reason = "centroid_outside_patch";
        return result;
    }
    if (sigmaA < 0.5 || sigmaB < 0.5 || sigmaA > 8.0 || sigmaB > 8.0
        || std::max(sigmaA, sigmaB) / std::max(std::min(sigmaA, sigmaB), 1e-9) > 4.0) {
        result.reason = "invalid_shape";
        return result;
    }
    double sumSquared = 0.0;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double residual = pixels[static_cast<std::size_t>(y * width + x)]
                - evaluate(static_cast<double>(x), static_cast<double>(y), parameters).model;
            sumSquared += residual * residual;
        }
    }
    const double normalizedRMS = std::sqrt(sumSquared / static_cast<double>(width * height))
        / noiseSigma;
    if (!std::isfinite(normalizedRMS) || normalizedRMS > 5.0) {
        result.reason = "poor_fit";
        return result;
    }
    const double cosine = std::cos(parameters[6]);
    const double sine = std::sin(parameters[6]);
    const double varianceA = sigmaA * sigmaA;
    const double varianceB = sigmaB * sigmaB;
    result.success = true;
    result.reason = "accepted";
    result.centerX = parameters[2];
    result.centerY = parameters[3];
    result.covarianceXX = cosine * cosine * varianceA + sine * sine * varianceB;
    result.covarianceXY = cosine * sine * (varianceA - varianceB);
    result.covarianceYY = sine * sine * varianceA + cosine * cosine * varianceB;
    result.sigmaMajor = std::max(sigmaA, sigmaB);
    result.sigmaMinor = std::min(sigmaA, sigmaB);
    result.angleRadians = parameters[6];
    result.amplitude = fittedAmplitude;
    result.background = parameters[0];
    result.signalToNoise = fittedAmplitude / noiseSigma;
    result.normalizedRMS = normalizedRMS;
    return result;
}

bool astro_psf_characterization_self_test() {
    constexpr int width = 13;
    constexpr int height = 13;
    constexpr double centerX = 6.23;
    constexpr double centerY = 5.71;
    constexpr double sigmaX = 1.8;
    constexpr double sigmaY = 1.15;
    constexpr double angle = 0.37;
    const double cosine = std::cos(angle);
    const double sine = std::sin(angle);
    std::vector<double> pixels(static_cast<std::size_t>(width * height));
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double dx = static_cast<double>(x) - centerX;
            const double dy = static_cast<double>(y) - centerY;
            const double rx = cosine * dx + sine * dy;
            const double ry = -sine * dx + cosine * dy;
            const double deterministicNoise = 0.01 * std::sin(1.7 * x + 0.9 * y);
            pixels[static_cast<std::size_t>(y * width + x)] = 0.12 + 2.8 * std::exp(
                -0.5 * (rx * rx / (sigmaX * sigmaX) + ry * ry / (sigmaY * sigmaY))
            ) + deterministicNoise;
        }
    }
    const EllipticalGaussianPSF fit = fit_elliptical_gaussian_psf(pixels, width, height, 0.02);
    return fit.success
        && std::abs(fit.centerX - centerX) <= 0.03
        && std::abs(fit.centerY - centerY) <= 0.03
        && fit.sigmaMajor > 1.70 && fit.sigmaMajor < 1.90
        && fit.sigmaMinor > 1.05 && fit.sigmaMinor < 1.25
        && fit.signalToNoise > 50.0;
}

} // namespace panolume
