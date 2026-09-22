#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>

namespace panolume {

struct AstroSkyMask {
    int width = 0;
    int height = 0;
    std::vector<std::uint8_t> alpha;
    std::vector<float> boundary;

    bool valid() const {
        return width > 0
            && height > 0
            && alpha.size() == static_cast<std::size_t>(width * height);
    }

    bool contains(int x, int y, int guardPixels = 0) const;
};

AstroSkyMask make_auto_sky_mask(
    const std::vector<float> &luminance,
    int width,
    int height,
    int maxDimension = 800
);

} // namespace panolume
