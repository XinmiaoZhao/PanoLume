#include "AstroSkyMask.hpp"

#include <algorithm>
#include <cmath>
#include <deque>
#include <limits>
#include <numeric>

namespace panolume {
namespace {

float percentile(std::vector<float> values, float p) {
    if (values.empty()) {
        return 0.0f;
    }
    p = std::max(0.0f, std::min(100.0f, p));
    const double position = (static_cast<double>(values.size()) - 1.0) * p / 100.0;
    const std::size_t lower = static_cast<std::size_t>(std::floor(position));
    const std::size_t upper = static_cast<std::size_t>(std::ceil(position));
    std::nth_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(lower), values.end());
    const float low = values[lower];
    if (upper == lower) {
        return low;
    }
    std::nth_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(upper), values.end());
    return low + (values[upper] - low) * static_cast<float>(position - static_cast<double>(lower));
}

std::vector<double> integral_image(const std::vector<float> &values, int width, int height) {
    std::vector<double> integral(static_cast<std::size_t>(width + 1) * static_cast<std::size_t>(height + 1), 0.0);
    for (int y = 0; y < height; ++y) {
        double rowSum = 0.0;
        for (int x = 0; x < width; ++x) {
            rowSum += values[static_cast<std::size_t>(y * width + x)];
            integral[static_cast<std::size_t>((y + 1) * (width + 1) + x + 1)] =
                integral[static_cast<std::size_t>(y * (width + 1) + x + 1)] + rowSum;
        }
    }
    return integral;
}

double mean_rect(
    const std::vector<double> &integral,
    int width,
    int height,
    int x0,
    int y0,
    int x1,
    int y1
) {
    x0 = std::max(0, std::min(width - 1, x0));
    x1 = std::max(0, std::min(width - 1, x1));
    y0 = std::max(0, std::min(height - 1, y0));
    y1 = std::max(0, std::min(height - 1, y1));
    if (x0 > x1 || y0 > y1) {
        return 0.0;
    }
    const int stride = width + 1;
    const double sum = integral[static_cast<std::size_t>((y1 + 1) * stride + x1 + 1)]
        - integral[static_cast<std::size_t>(y0 * stride + x1 + 1)]
        - integral[static_cast<std::size_t>((y1 + 1) * stride + x0)]
        + integral[static_cast<std::size_t>(y0 * stride + x0)];
    return sum / static_cast<double>((x1 - x0 + 1) * (y1 - y0 + 1));
}

std::vector<float> smooth_boundary(std::vector<float> values, int height) {
    if (values.empty()) {
        return values;
    }
    const int medianRadius = std::max(1, static_cast<int>(values.size()) / 90);
    std::vector<float> medianSmoothed(values.size());
    for (int index = 0; index < static_cast<int>(values.size()); ++index) {
        const int lower = std::max(0, index - medianRadius);
        const int upper = std::min(static_cast<int>(values.size()) - 1, index + medianRadius);
        std::vector<float> window(values.begin() + lower, values.begin() + upper + 1);
        std::nth_element(window.begin(), window.begin() + static_cast<std::ptrdiff_t>(window.size() / 2), window.end());
        medianSmoothed[static_cast<std::size_t>(index)] = window[window.size() / 2];
    }
    const int averageRadius = std::max(1, static_cast<int>(values.size()) / 60);
    std::vector<float> averaged(values.size());
    for (int index = 0; index < static_cast<int>(values.size()); ++index) {
        const int lower = std::max(0, index - averageRadius);
        const int upper = std::min(static_cast<int>(values.size()) - 1, index + averageRadius);
        float sum = 0.0f;
        for (int cursor = lower; cursor <= upper; ++cursor) {
            sum += medianSmoothed[static_cast<std::size_t>(cursor)];
        }
        averaged[static_cast<std::size_t>(index)] = std::max(
            0.0f,
            std::min(static_cast<float>(height - 1), sum / static_cast<float>(upper - lower + 1))
        );
    }
    return averaged;
}

} // namespace

bool AstroSkyMask::contains(int x, int y, int guardPixels) const {
    if (!valid() || x < 0 || y < 0 || x >= width || y >= height) {
        return false;
    }
    if (!boundary.empty() && x < static_cast<int>(boundary.size())) {
        const bool aboveHorizon = static_cast<float>(y + std::max(0, guardPixels))
            < boundary[static_cast<std::size_t>(x)];
        // The alpha mask additionally removes bottom-connected foreground that
        // rises above the smoothed horizon (buildings, terrain, lamp poles).
        // Requiring both keeps that refinement effective during star detection.
        return aboveHorizon && alpha[static_cast<std::size_t>(y * width + x)] >= 128;
    }
    return alpha[static_cast<std::size_t>(y * width + x)] >= 128;
}

AstroSkyMask make_auto_sky_mask(
    const std::vector<float> &luminance,
    int width,
    int height,
    int maxDimension
) {
    AstroSkyMask result;
    if (width < 16 || height < 16 || luminance.size() != static_cast<std::size_t>(width * height)) {
        return result;
    }
    const double scale = std::min(
        1.0,
        static_cast<double>(std::max(16, maxDimension)) / static_cast<double>(std::max(width, height))
    );
    const int sampledWidth = std::max(16, static_cast<int>(std::llround(width * scale)));
    const int sampledHeight = std::max(16, static_cast<int>(std::llround(height * scale)));
    std::vector<float> sampled(static_cast<std::size_t>(sampledWidth * sampledHeight), 0.0f);
    for (int y = 0; y < sampledHeight; ++y) {
        const int sourceY = std::min(height - 1, y * height / sampledHeight);
        for (int x = 0; x < sampledWidth; ++x) {
            const int sourceX = std::min(width - 1, x * width / sampledWidth);
            sampled[static_cast<std::size_t>(y * sampledWidth + x)] =
                luminance[static_cast<std::size_t>(sourceY * width + sourceX)];
        }
    }

    const std::vector<double> integral = integral_image(sampled, sampledWidth, sampledHeight);
    std::vector<float> rowScores(static_cast<std::size_t>(sampledHeight), 0.0f);
    for (int y = 0; y < sampledHeight; ++y) {
        double score = 0.0;
        for (int x = 0; x < sampledWidth; ++x) {
            const double blur = mean_rect(integral, sampledWidth, sampledHeight, x - 2, y - 2, x + 2, y + 2);
            score += std::max(static_cast<double>(sampled[static_cast<std::size_t>(y * sampledWidth + x)]) - blur, 0.0);
        }
        const double verticalPrior = 1.0 - static_cast<double>(y) / std::max(1, sampledHeight - 1);
        rowScores[static_cast<std::size_t>(y)] = static_cast<float>(score / sampledWidth + 0.05 * verticalPrior);
    }

    const int defaultHorizon = static_cast<int>(std::llround(sampledHeight * 0.68));
    const int minRow = sampledHeight / 4;
    const int maxRow = std::min(sampledHeight - 2, sampledHeight * 9 / 10);
    std::vector<double> rowPrefix(static_cast<std::size_t>(sampledHeight + 1), 0.0);
    for (int row = 0; row < sampledHeight; ++row) {
        rowPrefix[static_cast<std::size_t>(row + 1)] = rowPrefix[static_cast<std::size_t>(row)] + rowScores[static_cast<std::size_t>(row)];
    }
    int bestHorizon = defaultHorizon;
    double bestScore = -std::numeric_limits<double>::infinity();
    for (int row = minRow; row <= maxRow; ++row) {
        const double sky = rowPrefix[static_cast<std::size_t>(row)] / std::max(1, row);
        const double ground = (rowPrefix.back() - rowPrefix[static_cast<std::size_t>(row)]) / std::max(1, sampledHeight - row);
        const double prior = 1.0 - std::abs(row - defaultHorizon) / static_cast<double>(sampledHeight);
        const double score = sky - ground + 0.20 * prior;
        if (score > bestScore) {
            bestScore = score;
            bestHorizon = row;
        }
    }

    const int searchRadius = std::max(6, sampledHeight / 5);
    const int verticalWindow = std::max(2, sampledHeight / 80);
    const int horizontalWindow = std::max(1, sampledWidth / 180);
    std::vector<float> sampledBoundary(static_cast<std::size_t>(sampledWidth), static_cast<float>(bestHorizon));
    for (int x = 0; x < sampledWidth; ++x) {
        const int lowerRow = std::max(sampledHeight / 5, bestHorizon - searchRadius);
        const int upperRow = std::min(sampledHeight * 19 / 20, bestHorizon + searchRadius);
        double bestColumnScore = -std::numeric_limits<double>::infinity();
        int bestRow = bestHorizon;
        for (int row = lowerRow; row <= upperRow; ++row) {
            const double upperMean = mean_rect(
                integral, sampledWidth, sampledHeight,
                x - horizontalWindow, row - verticalWindow,
                x + horizontalWindow, row - 1
            );
            const double lowerMean = mean_rect(
                integral, sampledWidth, sampledHeight,
                x - horizontalWindow, row + 1,
                x + horizontalWindow, row + verticalWindow
            );
            const double transition = std::abs(upperMean - lowerMean);
            const double darkForeground = std::max(upperMean - lowerMean, 0.0);
            const double prior = 1.0 - std::min(std::abs(row - bestHorizon) / static_cast<double>(searchRadius), 1.0);
            const double score = transition * 1.25 + darkForeground * 0.75
                + rowScores[static_cast<std::size_t>(row)] * 0.35 + prior * 0.08;
            if (score > bestColumnScore) {
                bestColumnScore = score;
                bestRow = row;
            }
        }
        sampledBoundary[static_cast<std::size_t>(x)] = static_cast<float>(bestRow);
    }
    sampledBoundary = smooth_boundary(std::move(sampledBoundary), sampledHeight);

    result.width = width;
    result.height = height;
    result.alpha.assign(static_cast<std::size_t>(width * height), 0);
    result.boundary.resize(static_cast<std::size_t>(width));
    for (int x = 0; x < width; ++x) {
        const int sampledX = std::min(sampledWidth - 1, x * sampledWidth / width);
        result.boundary[static_cast<std::size_t>(x)] =
            sampledBoundary[static_cast<std::size_t>(sampledX)] * static_cast<float>(height) / static_cast<float>(sampledHeight);
    }

    // Refine the horizon with bottom-connected dark foreground so buildings,
    // terrain, and lamp structures cannot leak star candidates into the sky.
    std::vector<float> samples;
    samples.reserve(std::min<std::size_t>(luminance.size(), 300000));
    const std::size_t step = std::max<std::size_t>(1, luminance.size() / 300000);
    for (std::size_t index = 0; index < luminance.size(); index += step) {
        if (std::isfinite(luminance[index])) {
            samples.push_back(luminance[index]);
        }
    }
    const float low = percentile(samples, 12.0f);
    const float middle = percentile(samples, 55.0f);
    const float darkThreshold = low + std::max(middle - low, 0.02f) * 0.35f;
    std::vector<std::uint8_t> candidate(static_cast<std::size_t>(width * height), 0);
    const int protection = std::max(8, height / 12);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float boundary = result.boundary[static_cast<std::size_t>(x)];
            if (y >= static_cast<int>(boundary)
                || (y + protection >= boundary
                    && luminance[static_cast<std::size_t>(y * width + x)] <= darkThreshold)) {
                candidate[static_cast<std::size_t>(y * width + x)] = 1;
            }
        }
    }
    std::vector<std::uint8_t> connected(candidate.size(), 0);
    std::deque<int> queue;
    for (int x = 0; x < width; ++x) {
        const int index = (height - 1) * width + x;
        if (candidate[static_cast<std::size_t>(index)]) {
            connected[static_cast<std::size_t>(index)] = 1;
            queue.push_back(index);
        }
    }
    while (!queue.empty()) {
        const int index = queue.front();
        queue.pop_front();
        const int x = index % width;
        const int y = index / width;
        const int neighbors[4] = {
            x > 0 ? index - 1 : -1,
            x + 1 < width ? index + 1 : -1,
            y > 0 ? index - width : -1,
            y + 1 < height ? index + width : -1
        };
        for (int neighbor : neighbors) {
            if (neighbor >= 0
                && candidate[static_cast<std::size_t>(neighbor)]
                && !connected[static_cast<std::size_t>(neighbor)]) {
                connected[static_cast<std::size_t>(neighbor)] = 1;
                queue.push_back(neighbor);
            }
        }
    }
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const std::size_t index = static_cast<std::size_t>(y * width + x);
            const bool geometricSky = static_cast<float>(y + std::max(2, height / 300))
                < result.boundary[static_cast<std::size_t>(x)];
            result.alpha[index] = geometricSky && !connected[index] ? 255 : 0;
        }
    }
    return result;
}

} // namespace panolume
