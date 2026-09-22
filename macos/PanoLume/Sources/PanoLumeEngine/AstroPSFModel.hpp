#pragma once

#include <array>
#include <string>
#include <vector>

namespace panolume {

struct EllipticalGaussianPSF {
    bool success = false;
    std::string reason;
    double centerX = 0.0;
    double centerY = 0.0;
    double covarianceXX = 0.0;
    double covarianceXY = 0.0;
    double covarianceYY = 0.0;
    double sigmaMajor = 0.0;
    double sigmaMinor = 0.0;
    double angleRadians = 0.0;
    double amplitude = 0.0;
    double background = 0.0;
    double signalToNoise = 0.0;
    double normalizedRMS = 0.0;
    int iterations = 0;
};

// Fits background + an independently centred, rotated elliptical Gaussian.
// Pixel coordinates are local to the supplied row-major patch.
EllipticalGaussianPSF fit_elliptical_gaussian_psf(
    const std::vector<double> &pixels,
    int width,
    int height,
    double noiseSigma
);

bool astro_psf_characterization_self_test();

} // namespace panolume
