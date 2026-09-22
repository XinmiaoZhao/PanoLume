#include "include/PanoLumeEngine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#if __has_include(<tiffio.h>)
#include <tiffio.h>
#define PANOLUME_HAS_TIFF_COMPARATOR 1
#else
#define PANOLUME_HAS_TIFF_COMPARATOR 0
#endif

namespace {

char *copy_result(const std::string &value) {
    char *copy = static_cast<char *>(std::malloc(value.size() + 1));
    if (copy == nullptr) return nullptr;
    std::memcpy(copy, value.c_str(), value.size() + 1);
    return copy;
}

std::string json_escape(const std::string &value) {
    std::ostringstream out;
    for (unsigned char character : value) {
        switch (character) {
        case '\\': out << "\\\\"; break;
        case '"': out << "\\\""; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (character < 0x20) {
                out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                    << static_cast<int>(character) << std::dec;
            } else {
                out << static_cast<char>(character);
            }
        }
    }
    return out.str();
}

char *failure(const std::string &message) {
    return copy_result(
        "{\"success\":false,\"message\":\"" + json_escape(message) + "\"}"
    );
}

#if PANOLUME_HAS_TIFF_COMPARATOR

struct TIFFInfo {
    uint32_t width = 0;
    uint32_t height = 0;
    uint16_t bitsPerSample = 0;
    uint16_t samplesPerPixel = 0;
    uint16_t sampleFormat = SAMPLEFORMAT_UINT;
    uint16_t planarConfiguration = 0;
    uint16_t photometric = 0;
    tmsize_t scanlineBytes = 0;
};

bool read_info(TIFF *tiff, TIFFInfo &info, std::string &error) {
    if (tiff == nullptr
        || !TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &info.width)
        || !TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &info.height)) {
        error = "TIFF dimensions are unavailable";
        return false;
    }
    TIFFGetFieldDefaulted(tiff, TIFFTAG_BITSPERSAMPLE, &info.bitsPerSample);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLESPERPIXEL, &info.samplesPerPixel);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLEFORMAT, &info.sampleFormat);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_PLANARCONFIG, &info.planarConfiguration);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_PHOTOMETRIC, &info.photometric);
    info.scanlineBytes = TIFFScanlineSize(tiff);
    if (info.width == 0 || info.height == 0) {
        error = "TIFF dimensions must be positive";
        return false;
    }
    if (info.bitsPerSample != 16 || info.samplesPerPixel != 3
        || info.sampleFormat != SAMPLEFORMAT_UINT
        || info.planarConfiguration != PLANARCONFIG_CONTIG
        || info.photometric != PHOTOMETRIC_RGB) {
        std::ostringstream detail;
        detail << "TIFF must be contiguous unsigned 16-bit RGB"
               << " (bits=" << info.bitsPerSample
               << ", samples=" << info.samplesPerPixel
               << ", sample_format=" << info.sampleFormat
               << ", planar=" << info.planarConfiguration
               << ", photometric=" << info.photometric << ")";
        error = detail.str();
        return false;
    }
    const uint64_t required = static_cast<uint64_t>(info.width) * 3ULL * sizeof(uint16_t);
    if (info.scanlineBytes <= 0 || static_cast<uint64_t>(info.scanlineBytes) < required) {
        error = "TIFF scanline is shorter than its RGB16 width";
        return false;
    }
    return true;
}

struct StreamingMoments {
    uint64_t count = 0;
    long double meanA = 0.0;
    long double meanB = 0.0;
    long double m2A = 0.0;
    long double m2B = 0.0;
    long double covariance = 0.0;

    void add(double a, double b) {
        count += 1;
        const long double deltaA = static_cast<long double>(a) - meanA;
        const long double deltaB = static_cast<long double>(b) - meanB;
        meanA += deltaA / static_cast<long double>(count);
        meanB += deltaB / static_cast<long double>(count);
        m2A += deltaA * (static_cast<long double>(a) - meanA);
        m2B += deltaB * (static_cast<long double>(b) - meanB);
        covariance += deltaA * (static_cast<long double>(b) - meanB);
    }

    double ssim() const {
        if (count == 0) return std::numeric_limits<double>::quiet_NaN();
        const long double denominator = static_cast<long double>(count);
        const long double varianceA = m2A / denominator;
        const long double varianceB = m2B / denominator;
        const long double covarianceValue = covariance / denominator;
        constexpr long double range = 65535.0L;
        constexpr long double c1 = (0.01L * range) * (0.01L * range);
        constexpr long double c2 = (0.03L * range) * (0.03L * range);
        const long double luminance = (
            2.0L * meanA * meanB + c1
        ) / (meanA * meanA + meanB * meanB + c1);
        const long double structure = (
            2.0L * covarianceValue + c2
        ) / (varianceA + varianceB + c2);
        return static_cast<double>(luminance * structure);
    }
};

uint16_t histogram_quantile(
    const std::array<uint64_t, 65536> &histogram,
    uint64_t count,
    double fraction
) {
    if (count == 0) return 0;
    const uint64_t target = std::max<uint64_t>(
        1,
        static_cast<uint64_t>(std::ceil(fraction * static_cast<double>(count)))
    );
    uint64_t cumulative = 0;
    for (size_t value = 0; value < histogram.size(); ++value) {
        cumulative += histogram[value];
        if (cumulative >= target) return static_cast<uint16_t>(value);
    }
    return 65535;
}

#endif

} // namespace

extern "C" char *panolume_compare_tiff_rgb16_streaming(
    const char *firstPath,
    const char *secondPath
) {
#if PANOLUME_HAS_TIFF_COMPARATOR
    if (firstPath == nullptr || secondPath == nullptr
        || firstPath[0] == '\0' || secondPath[0] == '\0') {
        return failure("Two TIFF paths are required");
    }
    using TIFFPointer = std::unique_ptr<TIFF, decltype(&TIFFClose)>;
    TIFFPointer first(TIFFOpen(firstPath, "r"), TIFFClose);
    TIFFPointer second(TIFFOpen(secondPath, "r"), TIFFClose);
    if (!first || !second) return failure("One or both TIFF files could not be opened");
    TIFFInfo a;
    TIFFInfo b;
    std::string error;
    if (!read_info(first.get(), a, error)) return failure("First " + error);
    if (!read_info(second.get(), b, error)) return failure("Second " + error);
    if (a.width != b.width || a.height != b.height) {
        std::ostringstream detail;
        detail << "TIFF dimensions differ (" << a.width << "x" << a.height
               << " vs " << b.width << "x" << b.height << ")";
        return failure(detail.str());
    }

    std::vector<unsigned char> rowA(static_cast<size_t>(a.scanlineBytes));
    std::vector<unsigned char> rowB(static_cast<size_t>(b.scanlineBytes));
    std::array<uint64_t, 65536> absoluteDifferenceHistogram{};
    std::array<StreamingMoments, 3> channelMoments;
    uint64_t coveredA = 0;
    uint64_t coveredB = 0;
    uint64_t coverageIntersection = 0;
    uint64_t coverageUnion = 0;
    uint64_t sampleCount = 0;
    uint16_t maximumDifference = 0;
    for (uint32_t row = 0; row < a.height; ++row) {
        if (TIFFReadScanline(first.get(), rowA.data(), row, 0) < 0
            || TIFFReadScanline(second.get(), rowB.data(), row, 0) < 0) {
            return failure("A TIFF scanline could not be decoded");
        }
        const uint16_t *pixelsA = reinterpret_cast<const uint16_t *>(rowA.data());
        const uint16_t *pixelsB = reinterpret_cast<const uint16_t *>(rowB.data());
        for (uint32_t column = 0; column < a.width; ++column) {
            const size_t offset = static_cast<size_t>(column) * 3;
            const bool hasA = pixelsA[offset] != 0 || pixelsA[offset + 1] != 0 || pixelsA[offset + 2] != 0;
            const bool hasB = pixelsB[offset] != 0 || pixelsB[offset + 1] != 0 || pixelsB[offset + 2] != 0;
            coveredA += hasA ? 1 : 0;
            coveredB += hasB ? 1 : 0;
            coverageIntersection += hasA && hasB ? 1 : 0;
            coverageUnion += hasA || hasB ? 1 : 0;
            for (size_t channel = 0; channel < 3; ++channel) {
                const uint16_t valueA = pixelsA[offset + channel];
                const uint16_t valueB = pixelsB[offset + channel];
                const uint16_t difference = static_cast<uint16_t>(
                    valueA > valueB ? valueA - valueB : valueB - valueA
                );
                absoluteDifferenceHistogram[difference] += 1;
                maximumDifference = std::max(maximumDifference, difference);
                channelMoments[channel].add(valueA, valueB);
                sampleCount += 1;
            }
        }
    }
    const uint16_t medianDifference = histogram_quantile(
        absoluteDifferenceHistogram, sampleCount, 0.50
    );
    const uint16_t p95Difference = histogram_quantile(
        absoluteDifferenceHistogram, sampleCount, 0.95
    );
    const double coverageIoU = coverageUnion == 0
        ? 1.0
        : static_cast<double>(coverageIntersection) / static_cast<double>(coverageUnion);
    const double rgbSSIM = (
        channelMoments[0].ssim() + channelMoments[1].ssim() + channelMoments[2].ssim()
    ) / 3.0;
    constexpr double inverseRange = 1.0 / 65535.0;
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "{";
    out << "\"success\":true,";
    out << "\"streaming\":true,";
    out << "\"format\":\"rgb16_uint_contiguous\",";
    out << "\"width\":" << a.width << ",";
    out << "\"height\":" << a.height << ",";
    out << "\"bit_depth\":16,";
    out << "\"samples_per_pixel\":3,";
    out << "\"covered_pixels_first\":" << coveredA << ",";
    out << "\"covered_pixels_second\":" << coveredB << ",";
    out << "\"coverage_intersection_pixels\":" << coverageIntersection << ",";
    out << "\"coverage_union_pixels\":" << coverageUnion << ",";
    out << "\"coverage_iou\":" << coverageIoU << ",";
    out << "\"rgb_ssim\":" << rgbSSIM << ",";
    out << "\"median_absdiff\":" << static_cast<double>(medianDifference) * inverseRange << ",";
    out << "\"p95_absdiff\":" << static_cast<double>(p95Difference) * inverseRange << ",";
    out << "\"max_absdiff\":" << static_cast<double>(maximumDifference) * inverseRange;
    out << "}";
    return copy_result(out.str());
#else
    (void)firstPath;
    (void)secondPath;
    return failure("libtiff headers are unavailable");
#endif
}
