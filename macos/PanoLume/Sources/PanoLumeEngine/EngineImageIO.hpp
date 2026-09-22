// PanoLume internal implementation module. This file is included exactly once
// by PanoLumeEngine.mm to preserve the pre-split translation-unit semantics.

static std::string libraw_error_message(int code) {
#if PANOLUME_HAS_LIBRAW_HEADERS
    const char *message = libraw_strerror(code);
    if (message && std::strlen(message) > 0) {
        return message;
    }
#else
    (void)code;
#endif
    return "unknown LibRaw error";
}

static void resize_rgb_pixels(
    const std::vector<float> &source,
    int sourceWidth,
    int sourceHeight,
    int targetWidth,
    int targetHeight,
    std::vector<float> &target
) {
    target.assign(static_cast<size_t>(targetWidth) * static_cast<size_t>(targetHeight) * 3, 0.0f);
    if (sourceWidth <= 0 || sourceHeight <= 0 || targetWidth <= 0 || targetHeight <= 0 || source.empty()) {
        return;
    }

    const double scaleX = static_cast<double>(sourceWidth) / static_cast<double>(targetWidth);
    const double scaleY = static_cast<double>(sourceHeight) / static_cast<double>(targetHeight);
    for (int y = 0; y < targetHeight; ++y) {
        const double srcY = (static_cast<double>(y) + 0.5) * scaleY - 0.5;
        const int y0 = std::max(0, std::min(sourceHeight - 1, static_cast<int>(std::floor(srcY))));
        const int y1 = std::max(0, std::min(sourceHeight - 1, y0 + 1));
        const double ay = std::min(1.0, std::max(0.0, srcY - static_cast<double>(y0)));
        for (int x = 0; x < targetWidth; ++x) {
            const double srcX = (static_cast<double>(x) + 0.5) * scaleX - 0.5;
            const int x0 = std::max(0, std::min(sourceWidth - 1, static_cast<int>(std::floor(srcX))));
            const int x1 = std::max(0, std::min(sourceWidth - 1, x0 + 1));
            const double ax = std::min(1.0, std::max(0.0, srcX - static_cast<double>(x0)));
            const size_t dst = (static_cast<size_t>(y) * static_cast<size_t>(targetWidth) + static_cast<size_t>(x)) * 3;
            const size_t p00 = (static_cast<size_t>(y0) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(x0)) * 3;
            const size_t p10 = (static_cast<size_t>(y0) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(x1)) * 3;
            const size_t p01 = (static_cast<size_t>(y1) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(x0)) * 3;
            const size_t p11 = (static_cast<size_t>(y1) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(x1)) * 3;
            for (int c = 0; c < 3; ++c) {
                const double top = source[p00 + c] * (1.0 - ax) + source[p10 + c] * ax;
                const double bottom = source[p01 + c] * (1.0 - ax) + source[p11 + c] * ax;
                target[dst + c] = static_cast<float>(top * (1.0 - ay) + bottom * ay);
            }
        }
    }
}

static void resize_native_image_to_max_side(NativeImage &image, int maxSide) {
    if (image.status != "loaded" || maxSide <= 0 || image.width <= 0 || image.height <= 0) {
        return;
    }
    const int longest = std::max(image.width, image.height);
    if (longest <= maxSide) {
        return;
    }
    const double scale = static_cast<double>(maxSide) / static_cast<double>(longest);
    const int targetWidth = std::max(1, static_cast<int>(std::llround(static_cast<double>(image.width) * scale)));
    const int targetHeight = std::max(1, static_cast<int>(std::llround(static_cast<double>(image.height) * scale)));
    std::vector<float> resized;
    resize_rgb_pixels(image.pixels, image.width, image.height, targetWidth, targetHeight, resized);
    image.width = targetWidth;
    image.height = targetHeight;
    image.pixels.swap(resized);
}

static NativeImage resized_native_image_copy(const NativeImage &source, int maxSide) {
    NativeImage image = source;
    image.pixels.clear();
    if (source.status != "loaded" || maxSide <= 0 || source.width <= 0 || source.height <= 0) {
        image.pixels = source.pixels;
        return image;
    }
    const int longest = std::max(source.width, source.height);
    if (longest <= maxSide) {
        image.pixels = source.pixels;
        return image;
    }
    const double scale = static_cast<double>(maxSide) / static_cast<double>(longest);
    image.width = std::max(1, static_cast<int>(std::llround(static_cast<double>(source.width) * scale)));
    image.height = std::max(1, static_cast<int>(std::llround(static_cast<double>(source.height) * scale)));
    std::vector<float> resized;
    resize_rgb_pixels(source.pixels, source.width, source.height, image.width, image.height, resized);
    image.pixels.swap(resized);
    return image;
}

static bool cf_number_to_double(CFTypeRef value, double &out) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    double candidate = 0.0;
    if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &candidate)
        || !std::isfinite(candidate)
        || candidate <= 0.0) {
        return false;
    }
    out = candidate;
    return true;
}

static bool cf_string_to_std(CFTypeRef value, std::string &out) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return false;
    }
    CFStringRef string = static_cast<CFStringRef>(value);
    const char *direct = CFStringGetCStringPtr(string, kCFStringEncodingUTF8);
    if (direct && direct[0] != '\0') {
        out = direct;
        return true;
    }
    const CFIndex length = CFStringGetLength(string);
    const CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    if (maxSize <= 1) {
        return false;
    }
    std::vector<char> buffer(static_cast<size_t>(maxSize), '\0');
    if (!CFStringGetCString(string, buffer.data(), maxSize, kCFStringEncodingUTF8)) {
        return false;
    }
    if (buffer.empty() || buffer[0] == '\0') {
        return false;
    }
    out = buffer.data();
    return true;
}

static void populate_image_metadata(NativeImage &image, const std::string &path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(path.c_str()),
        static_cast<CFIndex>(path.size()),
        false
    );
    if (!url) {
        return;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) {
        return;
    }
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!properties) {
        return;
    }
    CFDictionaryRef exif = nullptr;
    CFTypeRef exifValue = CFDictionaryGetValue(properties, kCGImagePropertyExifDictionary);
    if (exifValue && CFGetTypeID(exifValue) == CFDictionaryGetTypeID()) {
        exif = static_cast<CFDictionaryRef>(exifValue);
    }
    if (exif) {
        double focal35mm = 0.0;
        if (cf_number_to_double(CFDictionaryGetValue(exif, kCGImagePropertyExifFocalLenIn35mmFilm), focal35mm)) {
            image.focalLength35mm = focal35mm;
            image.focalMetadataSource = "exif_35mm_equivalent_focal_length";
        }
        double focalMM = 0.0;
        if (cf_number_to_double(CFDictionaryGetValue(exif, kCGImagePropertyExifFocalLength), focalMM)) {
            image.focalLengthMM = focalMM;
            if (image.focalMetadataSource.empty()) {
                image.focalMetadataSource = "exif_focal_length_mm_no_sensor_size";
            }
        }
        (void)cf_number_to_double(
            CFDictionaryGetValue(exif, kCGImagePropertyExifFNumber),
            image.apertureFNumber
        );
        (void)cf_string_to_std(
            CFDictionaryGetValue(exif, kCGImagePropertyExifLensModel),
            image.lensName
        );
        std::string dateTime;
        if (cf_string_to_std(CFDictionaryGetValue(exif, kCGImagePropertyExifDateTimeOriginal), dateTime)) {
            image.captureDateTimeOriginal = dateTime;
            image.captureMetadataSource = "exif_datetime_original";
        } else if (cf_string_to_std(CFDictionaryGetValue(exif, kCGImagePropertyExifDateTimeDigitized), dateTime)) {
            image.captureDateTimeOriginal = dateTime;
            image.captureMetadataSource = "exif_datetime_digitized";
        }
    }
    CFDictionaryRef tiff = nullptr;
    CFTypeRef tiffValue = CFDictionaryGetValue(properties, kCGImagePropertyTIFFDictionary);
    if (tiffValue && CFGetTypeID(tiffValue) == CFDictionaryGetTypeID()) {
        tiff = static_cast<CFDictionaryRef>(tiffValue);
    }
    if (tiff) {
        (void)cf_string_to_std(CFDictionaryGetValue(tiff, kCGImagePropertyTIFFMake), image.cameraMake);
        (void)cf_string_to_std(CFDictionaryGetValue(tiff, kCGImagePropertyTIFFModel), image.cameraModel);
    }
    if (image.captureDateTimeOriginal.empty()) {
        std::string dateTime;
        if (tiff && cf_string_to_std(CFDictionaryGetValue(tiff, kCGImagePropertyTIFFDateTime), dateTime)) {
            image.captureDateTimeOriginal = dateTime;
            image.captureMetadataSource = "tiff_datetime";
        }
    }
    CFRelease(properties);
}

class LibRawDecodeBackend final : public RawDecodeBackend {
public:
    NativeImage loadRaw(
        PanoLumeContext *context,
        const std::string &path,
        int maxSide,
        bool halfSize,
        bool retainNative16
    ) override {
        NativeImage image;
        image.handle = "native-image-" + std::to_string(context->nextImageId.fetch_add(1));
        image.path = path;
        populate_image_metadata(image, path);
#if PANOLUME_HAS_LIBRAW_HEADERS
        auto raw = std::make_unique<LibRaw>();
        raw->imgdata.params.use_camera_wb = 1;
        raw->imgdata.params.no_auto_bright = 1;
        raw->imgdata.params.output_bps = 16;
        raw->imgdata.params.half_size = halfSize ? 1 : 0;

        int ret = raw->open_file(path.c_str());
        if (ret != LIBRAW_SUCCESS) {
            image.status = "load_failed";
            image.unsupportedReason = "LibRaw failed to open RAW file: " + libraw_error_message(ret);
            return image;
        }
        if (image.cameraMake.empty() && raw->imgdata.idata.make[0] != '\0') {
            image.cameraMake = raw->imgdata.idata.make;
        }
        if (image.cameraModel.empty() && raw->imgdata.idata.model[0] != '\0') {
            image.cameraModel = raw->imgdata.idata.model;
        }
        if (image.lensName.empty() && raw->imgdata.lens.Lens[0] != '\0') {
            image.lensName = raw->imgdata.lens.Lens;
        }
        if (!(image.apertureFNumber > 0.0)
            && std::isfinite(raw->imgdata.other.aperture)
            && raw->imgdata.other.aperture > 0.0) {
            image.apertureFNumber = raw->imgdata.other.aperture;
        }
        ret = raw->unpack();
        if (ret != LIBRAW_SUCCESS) {
            image.status = "load_failed";
            image.unsupportedReason = "LibRaw failed to unpack RAW file: " + libraw_error_message(ret);
            return image;
        }
        ret = raw->dcraw_process();
        if (ret != LIBRAW_SUCCESS) {
            image.status = "load_failed";
            image.unsupportedReason = "LibRaw failed to process RAW file: " + libraw_error_message(ret);
            return image;
        }

        int memoryError = LIBRAW_SUCCESS;
        libraw_processed_image_t *processed = raw->dcraw_make_mem_image(&memoryError);
        if (!processed || memoryError != LIBRAW_SUCCESS) {
            image.status = "load_failed";
            image.unsupportedReason = "LibRaw failed to create RGB output: " + libraw_error_message(memoryError);
            if (processed) {
                LibRaw::dcraw_clear_mem(processed);
            }
            return image;
        }

        if (processed->type != LIBRAW_IMAGE_BITMAP || processed->width == 0 || processed->height == 0 || processed->colors < 3) {
            image.status = "load_failed";
            image.unsupportedReason = "LibRaw returned an unsupported processed image buffer.";
            LibRaw::dcraw_clear_mem(processed);
            return image;
        }

        image.width = static_cast<int>(processed->width);
        image.height = static_cast<int>(processed->height);
        image.originalWidth = halfSize ? image.width * 2 : image.width;
        image.originalHeight = halfSize ? image.height * 2 : image.height;
        image.channels = 3;
        image.bitDepth = static_cast<int>(processed->bits);
        const int sourceChannels = static_cast<int>(processed->colors);
        if (retainNative16) {
            if (processed->bits != 16 || sourceChannels != 3 || maxSide > 0) {
                image.status = "load_failed";
                image.unsupportedReason = "full-resolution RAW export requires an unscaled 16-bit RGB LibRaw buffer";
                LibRaw::dcraw_clear_mem(processed);
                return image;
            }
            image.native16Pixels = reinterpret_cast<const uint16_t *>(processed->data);
            image.native16Storage = std::shared_ptr<void>(
                static_cast<void *>(processed),
                [](void *storage) {
                    LibRaw::dcraw_clear_mem(static_cast<libraw_processed_image_t *>(storage));
                }
            );
            image.status = "loaded";
            return image;
        }
        image.pixels.assign(static_cast<size_t>(image.width) * static_cast<size_t>(image.height) * 3, 0.0f);
        if (processed->bits <= 8) {
            const unsigned char *samples = processed->data;
            for (int y = 0; y < image.height; ++y) {
                for (int x = 0; x < image.width; ++x) {
                    const size_t src = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * static_cast<size_t>(sourceChannels);
                    const size_t dst = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * 3;
                    image.pixels[dst + 0] = static_cast<float>(samples[src + 0]) / 255.0f;
                    image.pixels[dst + 1] = static_cast<float>(samples[src + 1]) / 255.0f;
                    image.pixels[dst + 2] = static_cast<float>(samples[src + 2]) / 255.0f;
                }
            }
        } else {
            const unsigned short *samples = reinterpret_cast<const unsigned short *>(processed->data);
            for (int y = 0; y < image.height; ++y) {
                for (int x = 0; x < image.width; ++x) {
                    const size_t src = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * static_cast<size_t>(sourceChannels);
                    const size_t dst = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * 3;
                    image.pixels[dst + 0] = static_cast<float>(samples[src + 0]) / 65535.0f;
                    image.pixels[dst + 1] = static_cast<float>(samples[src + 1]) / 65535.0f;
                    image.pixels[dst + 2] = static_cast<float>(samples[src + 2]) / 65535.0f;
                }
            }
        }
        LibRaw::dcraw_clear_mem(processed);
        image.status = "loaded";
        resize_native_image_to_max_side(image, maxSide);
#else
        (void)maxSide;
        (void)halfSize;
        (void)retainNative16;
        image.status = "unsupported_until_libraw";
        image.unsupportedReason = "RAW decoding is intentionally blocked until the LibRaw migration phase.";
#endif
        return image;
    }
};

class ImageLoader {
public:
    virtual ~ImageLoader() = default;
    virtual NativeImage load(PanoLumeContext *context, const std::string &path, int maxSide) = 0;
};

class ImageIOStandardImageLoader final : public ImageLoader {
public:
    NativeImage load(PanoLumeContext *context, const std::string &path, int maxSide) override;
};

NativeImage ImageIOStandardImageLoader::load(
    PanoLumeContext *context,
    const std::string &path,
    int maxSide
) {
    NativeImage image;
    image.handle = "native-image-" + std::to_string(context->nextImageId.fetch_add(1));
    image.path = path;
    populate_image_metadata(image, path);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(path.c_str()),
        static_cast<CFIndex>(path.size()),
        false
    );
    if (!url) {
        image.status = "load_failed";
        image.unsupportedReason = "Failed to create file URL.";
        return image;
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) {
        image.status = "load_failed";
        image.unsupportedReason = "ImageIO could not open the image.";
        return image;
    }

    CGImageRef sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    if (!sourceImage) {
        CFRelease(source);
        image.status = "load_failed";
        image.unsupportedReason = "ImageIO could not decode the first frame.";
        return image;
    }

    const size_t sourceWidth = CGImageGetWidth(sourceImage);
    const size_t sourceHeight = CGImageGetHeight(sourceImage);
    image.bitDepth = static_cast<int>(CGImageGetBitsPerComponent(sourceImage));
    if (sourceWidth == 0 || sourceHeight == 0) {
        CGImageRelease(sourceImage);
        CFRelease(source);
        image.status = "load_failed";
        image.unsupportedReason = "Decoded image has invalid dimensions.";
        return image;
    }

    int orientation = 1;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    if (properties) {
        CFNumberRef orientationValue = static_cast<CFNumberRef>(
            CFDictionaryGetValue(properties, kCGImagePropertyOrientation)
        );
        if (orientationValue && CFGetTypeID(orientationValue) == CFNumberGetTypeID()) {
            CFNumberGetValue(orientationValue, kCFNumberIntType, &orientation);
        }
        CFRelease(properties);
    }
    const bool swapsAxes = orientation >= 5 && orientation <= 8;
    image.originalWidth = static_cast<int>(swapsAxes ? sourceHeight : sourceWidth);
    image.originalHeight = static_cast<int>(swapsAxes ? sourceWidth : sourceHeight);

    const int sourceMaxSide = std::max(image.originalWidth, image.originalHeight);
    const int thumbnailMaxSide = maxSide > 0
        ? std::min(maxSide, sourceMaxSide)
        : sourceMaxSide;
    CFNumberRef maximumPixelSize = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &thumbnailMaxSide
    );
    const void *optionKeys[] = {
        kCGImageSourceCreateThumbnailFromImageAlways,
        kCGImageSourceCreateThumbnailWithTransform,
        kCGImageSourceThumbnailMaxPixelSize,
        kCGImageSourceShouldCacheImmediately,
    };
    const void *optionValues[] = {
        kCFBooleanTrue,
        kCFBooleanTrue,
        maximumPixelSize,
        kCFBooleanTrue,
    };
    CFDictionaryRef thumbnailOptions = CFDictionaryCreate(
        kCFAllocatorDefault,
        optionKeys,
        optionValues,
        4,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions);
    CFRelease(thumbnailOptions);
    CFRelease(maximumPixelSize);
    CGImageRelease(sourceImage);
    CFRelease(source);
    if (!cgImage) {
        image.status = "load_failed";
        image.unsupportedReason = "ImageIO could not create an orientation-correct preview.";
        return image;
    }

    image.width = static_cast<int>(CGImageGetWidth(cgImage));
    image.height = static_cast<int>(CGImageGetHeight(cgImage));
    image.channels = 3;

    const size_t bytesPerRow = static_cast<size_t>(image.width) * 4;
    std::vector<unsigned char> rgba(static_cast<size_t>(image.height) * bytesPerRow, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(
        rgba.data(),
        static_cast<size_t>(image.width),
        static_cast<size_t>(image.height),
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!bitmap) {
        CGImageRelease(cgImage);
        image.status = "load_failed";
        image.unsupportedReason = "Failed to create ImageIO conversion buffer.";
        return image;
    }

    CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
    CGContextDrawImage(
        bitmap,
        CGRectMake(0, 0, static_cast<CGFloat>(image.width), static_cast<CGFloat>(image.height)),
        cgImage
    );
    CGContextRelease(bitmap);
    CGImageRelease(cgImage);

    image.pixels.assign(static_cast<size_t>(image.width) * static_cast<size_t>(image.height) * 3, 0.0f);
    for (int y = 0; y < image.height; ++y) {
        for (int x = 0; x < image.width; ++x) {
            const size_t src = static_cast<size_t>(y) * bytesPerRow + static_cast<size_t>(x) * 4;
            const size_t dst = (static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x)) * 3;
            image.pixels[dst + 0] = static_cast<float>(rgba[src + 0]) / 255.0f;
            image.pixels[dst + 1] = static_cast<float>(rgba[src + 1]) / 255.0f;
            image.pixels[dst + 2] = static_cast<float>(rgba[src + 2]) / 255.0f;
        }
    }
    image.status = "loaded";
    return image;
}

static NativeImage load_image_with_native_backends(
    PanoLumeContext *context,
    const std::string &path,
    int maxSide,
    bool rawHalfSize,
    bool retainRaw16 = false
) {
    if (is_raw_extension(path)) {
        LibRawDecodeBackend rawBackend;
        return rawBackend.loadRaw(context, path, maxSide, rawHalfSize, retainRaw16);
    }
    ImageIOStandardImageLoader standardLoader;
    return standardLoader.load(context, path, maxSide);
}

static size_t native16_rgb_byte_count(const NativeImage &image) {
    if (image.width <= 0 || image.height <= 0 || image.channels != 3) {
        return 0;
    }
    const size_t pixels = static_cast<size_t>(image.width) * static_cast<size_t>(image.height);
    if (pixels > std::numeric_limits<size_t>::max() / (3 * sizeof(uint16_t))) {
        return 0;
    }
    return pixels * 3 * sizeof(uint16_t);
}

static bool write_native16_spool(
    NativeImage &image,
    const std::string &spoolPath,
    std::string &errorMessage
) {
    const size_t bytes = native16_rgb_byte_count(image);
    const size_t sampleCount = bytes / sizeof(uint16_t);
    const bool hasNative16 = image.native16Pixels != nullptr;
    const bool hasFloat = image.pixels.size() == sampleCount;
    if (bytes == 0 || (!hasNative16 && !hasFloat)) {
        errorMessage = "source RGB buffer is unavailable for 16-bit spool";
        return false;
    }
    std::remove(spoolPath.c_str());
    FILE *file = std::fopen(spoolPath.c_str(), "wb");
    if (!file) {
        errorMessage = "failed to create the 16-bit RAW spool";
        return false;
    }
    bool wrote = true;
    if (hasNative16) {
        const uint8_t *cursor = reinterpret_cast<const uint8_t *>(image.native16Pixels);
        size_t remaining = bytes;
        while (remaining > 0) {
            const size_t chunk = std::min(remaining, static_cast<size_t>(16 * 1024 * 1024));
            if (std::fwrite(cursor, 1, chunk, file) != chunk) {
                wrote = false;
                break;
            }
            cursor += chunk;
            remaining -= chunk;
        }
    } else {
        std::vector<uint16_t> converted(std::min(sampleCount, static_cast<size_t>(1024 * 1024)));
        for (size_t offset = 0; offset < sampleCount && wrote; offset += converted.size()) {
            const size_t count = std::min(converted.size(), sampleCount - offset);
            for (size_t index = 0; index < count; ++index) {
                const double clamped = std::min(1.0, std::max(0.0, static_cast<double>(image.pixels[offset + index])));
                converted[index] = static_cast<uint16_t>(std::llround(clamped * 65535.0));
            }
            wrote = std::fwrite(converted.data(), sizeof(uint16_t), count, file) == count;
        }
    }
    if (std::fclose(file) != 0) {
        wrote = false;
    }
    if (!wrote) {
        std::remove(spoolPath.c_str());
        errorMessage = "failed while writing the 16-bit RGB spool";
        return false;
    }
    image.native16SpoolPath = spoolPath;
    image.native16Pixels = nullptr;
    image.native16Storage.reset();
    return true;
}

static NativeImage map_native16_spool(
    const NativeImage &metadata,
    std::string &errorMessage
) {
    NativeImage image = metadata;
    const size_t bytes = native16_rgb_byte_count(image);
    if (image.native16SpoolPath.empty() || bytes == 0) {
        image.status = "load_failed";
        image.unsupportedReason = "16-bit RAW spool metadata is invalid";
        errorMessage = image.unsupportedReason;
        return image;
    }
    const int fd = open(image.native16SpoolPath.c_str(), O_RDONLY);
    if (fd < 0) {
        image.status = "load_failed";
        image.unsupportedReason = "failed to open the 16-bit RAW spool";
        errorMessage = image.unsupportedReason;
        return image;
    }
    struct stat fileStatus {};
    const bool validSize = fstat(fd, &fileStatus) == 0
        && static_cast<size_t>(fileStatus.st_size) == bytes;
    if (!validSize) {
        close(fd);
        image.status = "load_failed";
        image.unsupportedReason = "16-bit RAW spool has an unexpected size";
        errorMessage = image.unsupportedReason;
        return image;
    }
    void *mapping = mmap(nullptr, bytes, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        image.status = "load_failed";
        image.unsupportedReason = "failed to map the 16-bit RAW spool";
        errorMessage = image.unsupportedReason;
        return image;
    }
    image.native16Storage = std::shared_ptr<void>(mapping, [bytes](void *memory) {
        munmap(memory, bytes);
    });
    image.native16Pixels = static_cast<const uint16_t *>(mapping);
    image.status = "loaded";
    return image;
}

class TemporaryNative16SpoolFiles {
public:
    void add(const std::string &path) {
        paths_.push_back(path);
    }

    bool cleanup() {
        bool succeeded = true;
        for (const std::string &path : paths_) {
            if (std::remove(path.c_str()) != 0 && errno != ENOENT) {
                succeeded = false;
            }
        }
        paths_.clear();
        return succeeded;
    }

    ~TemporaryNative16SpoolFiles() {
        cleanup();
    }

private:
    std::vector<std::string> paths_;
};

static NativeImage load_fullres_streaming_source(
    PanoLumeContext *context,
    const NativeImage &metadata,
    const std::string &path,
    std::string &errorMessage
) {
    if (!metadata.native16SpoolPath.empty()) {
        return map_native16_spool(metadata, errorMessage);
    }
    NativeImage image = load_image_with_native_backends(context, path, 0, false);
    if (image.status != "loaded") {
        errorMessage = image.unsupportedReason;
    }
    return image;
}

static std::vector<NativeImage> load_images_for_paths(
    PanoLumeContext *context,
    const std::vector<std::string> &paths,
    int maxSide,
    bool rawHalfSize,
    PanoLumeProgressCallback progress,
    void *userData
) {
    std::vector<NativeImage> images;
    images.reserve(paths.size());
    for (size_t i = 0; i < paths.size(); ++i) {
        if (active_native_operation_cancelled()) {
            break;
        }
        emit_progress(progress, userData, "Loading image", 0.05 + 0.70 * (static_cast<double>(i) / std::max<size_t>(paths.size(), 1)));
        NativeImage image = load_image_with_native_backends(context, paths[i], maxSide, rawHalfSize);
        context->images[image.handle] = image;
        images.push_back(image);
    }
    emit_progress(progress, userData, "Image loading complete", 0.80);
    return images;
}

static std::vector<NativeImage> images_from_handles(
    PanoLumeContext *context,
    const std::vector<std::string> &handles
) {
    std::vector<NativeImage> images;
    images.reserve(handles.size());
    for (const std::string &handle : handles) {
        auto found = context->images.find(handle);
        if (found != context->images.end()) {
            if (found->second.status == "loaded" && found->second.pixels.empty()) {
                NativeImage reloaded = load_image_with_native_backends(
                    context,
                    found->second.path,
                    2400,
                    true
                );
                if (reloaded.status == "loaded") {
                    reloaded.handle = handle;
                    found->second = std::move(reloaded);
                }
            }
            images.push_back(found->second);
        }
    }
    return images;
}

static std::vector<NativeImage> resized_images_from_handles(
    PanoLumeContext *context,
    const std::vector<std::string> &handles,
    int maxSide,
    std::vector<NativeImage> &sourceMetadata
) {
    std::vector<NativeImage> images;
    images.reserve(handles.size());
    sourceMetadata.clear();
    sourceMetadata.reserve(handles.size());
    for (const std::string &handle : handles) {
        auto found = context->images.find(handle);
        if (found == context->images.end()) {
            continue;
        }
        NativeImage metadata = found->second;
        metadata.pixels.clear();
        sourceMetadata.push_back(std::move(metadata));
        images.push_back(resized_native_image_copy(found->second, maxSide));
    }
    return images;
}

static std::vector<NativeImage> cached_resized_images_from_handles(
    PanoLumeContext *context,
    const std::string &cacheKey,
    const std::vector<std::string> &handles,
    int maxSide,
    std::vector<NativeImage> &sourceMetadata
) {
    auto imagesFound = context->dragPreviewImageCache.find(cacheKey);
    auto metadataFound = context->dragPreviewSourceMetadataCache.find(cacheKey);
    if (imagesFound != context->dragPreviewImageCache.end()
        && metadataFound != context->dragPreviewSourceMetadataCache.end()
        && imagesFound->second.size() == handles.size()
        && metadataFound->second.size() == handles.size()) {
        sourceMetadata = metadataFound->second;
        return imagesFound->second;
    }
    std::vector<NativeImage> images = resized_images_from_handles(context, handles, maxSide, sourceMetadata);
    if (images.size() == handles.size() && sourceMetadata.size() == handles.size()) {
        context->dragPreviewImageCache[cacheKey] = images;
        context->dragPreviewSourceMetadataCache[cacheKey] = sourceMetadata;
    }
    return images;
}

static std::vector<NativeCameraParams> scale_camera_params_for_images(
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &previewImages,
    const std::vector<NativeImage> &targetImages,
    double &meanScale,
    double &maxScale,
    std::string &failureReason
) {
    meanScale = 1.0;
    maxScale = 1.0;
    if (cameras.size() != previewImages.size() || cameras.size() != targetImages.size() || cameras.empty()) {
        failureReason = "camera scaling requires matching camera, preview image, and target image counts";
        return {};
    }

    std::vector<NativeCameraParams> scaled = cameras;
    double scaleSum = 0.0;
    double scaleMax = 0.0;
    for (size_t i = 0; i < cameras.size(); ++i) {
        const NativeImage &preview = previewImages[i];
        const NativeImage &target = targetImages[i];
        if (preview.width <= 0 || preview.height <= 0 || target.width <= 0 || target.height <= 0) {
            failureReason = "camera scaling requires valid preview and target image dimensions";
            return {};
        }
        const double scaleX = static_cast<double>(target.width) / static_cast<double>(preview.width);
        const double scaleY = static_cast<double>(target.height) / static_cast<double>(preview.height);
        if (!std::isfinite(scaleX) || !std::isfinite(scaleY) || scaleX <= 0.0 || scaleY <= 0.0) {
            failureReason = "camera scaling produced an invalid image scale";
            return {};
        }
        const double relativeMismatch = std::abs(scaleX - scaleY) / std::max(scaleX, scaleY);
        if (relativeMismatch > 0.02) {
            failureReason = "camera scaling encountered non-uniform image resizing";
            return {};
        }
        const double scale = 0.5 * (scaleX + scaleY);
        scaled[i].focalLength = cameras[i].focalLength * scale;
        scaleSum += scale;
        scaleMax = std::max(scaleMax, scale);
    }
    meanScale = scaleSum / static_cast<double>(cameras.size());
    maxScale = scaleMax;
    return scaled;
}

static std::vector<NativeCameraParams> cached_drag_preview_camera_params(
    PanoLumeContext *context,
    const std::string &cacheKey,
    const std::vector<NativeCameraParams> &cameras,
    const std::vector<NativeImage> &previewImages,
    const std::vector<NativeImage> &dragImages,
    std::string &failureReason
) {
    auto found = context->dragPreviewCameraCache.find(cacheKey);
    if (found != context->dragPreviewCameraCache.end()
        && found->second.size() == cameras.size()) {
        return found->second;
    }
    double meanScale = 1.0;
    double maxScale = 1.0;
    std::vector<NativeCameraParams> scaled = scale_camera_params_for_images(
        cameras,
        previewImages,
        dragImages,
        meanScale,
        maxScale,
        failureReason
    );
    if (!scaled.empty()) {
        context->dragPreviewCameraCache[cacheKey] = scaled;
    }
    return scaled;
}

struct DragPreviewLimits {
    int sourceMaxSide;
    int maxOutputPixels;
    int maxOutputSide;
};

static DragPreviewLimits drag_preview_limits(size_t imageCount) {
    if (imageCount <= 3) {
        return {640, 900000, 2560};
    }
    if (imageCount <= 4) {
        return {480, 900000, 1920};
    }
    // The 240 px source tier produced only a 651 px-wide frame for the
    // certified seven-RAW geometry, leaving half of the 320k output budget
    // unused. 280 px clears the 720 px readability floor while measured Metal
    // Fast latency remains comfortably inside the interactive budget.
    return {280, 320000, 960};
}

static int capped_drag_request_limit(
    const panolume::EngineRequest &request,
    const std::string &key,
    int hardLimit
) {
    const int requested = request.integer(key, hardLimit);
    return requested > 0 ? std::min(requested, hardLimit) : hardLimit;
}

static NativeResult copy_result_without_panorama_pixels(NativeResult &source) {
    // NativeOperationScope serializes access to the context while this helper
    // temporarily detaches the large immutable preview raster. Copying that
    // raster for every low-resolution drag frame dominated 7-source latency.
    std::vector<float> detachedPixels;
    std::vector<unsigned char> detachedCoverage;
    detachedPixels.swap(source.panoramaPixels);
    detachedCoverage.swap(source.panoramaCoverage);
    try {
        NativeResult copy = source;
        source.panoramaPixels.swap(detachedPixels);
        source.panoramaCoverage.swap(detachedCoverage);
        return copy;
    } catch (...) {
        source.panoramaPixels.swap(detachedPixels);
        source.panoramaCoverage.swap(detachedCoverage);
        throw;
    }
}

static void clear_transient_projection_results(
    PanoLumeContext *context,
    const std::string &preservedHandle = ""
) {
    for (const std::string &oldHandle : context->transientProjectionResultHandles) {
        if (oldHandle != preservedHandle) {
            context->results.erase(oldHandle);
        }
    }
    context->transientProjectionResultHandles.clear();
}

static void prewarm_drag_preview_cache(
    PanoLumeContext *context,
    const NativeResult &result
) {
    const size_t imageCount = result.imageHandles.size();
    if (imageCount < 2 || result.cameraParams.size() != imageCount) {
        return;
    }
    const DragPreviewLimits limits = drag_preview_limits(imageCount);
    const int dragMaxSide = limits.sourceMaxSide;
    const std::string cacheKey = result.handle + ":drag:" + std::to_string(dragMaxSide);
    std::vector<NativeImage> previewImages;
    std::vector<NativeImage> dragImages = cached_resized_images_from_handles(
        context,
        cacheKey,
        result.imageHandles,
        dragMaxSide,
        previewImages
    );
    if (dragImages.size() != imageCount || previewImages.size() != imageCount) {
        return;
    }
    std::string failureReason;
    (void)cached_drag_preview_camera_params(
        context,
        cacheKey,
        result.cameraParams,
        previewImages,
        dragImages,
        failureReason
    );
}

static NativeResult contact_sheet_result(
    PanoLumeContext *context,
    const std::vector<NativeImage> &images,
    const std::string &projection
) {
    NativeResult result;
    result.handle = "native-result-" + std::to_string(context->nextResultId.fetch_add(1));
    result.projection = projection;
    result.geometry = "image_io_only";
    result.previewStatus = "contact_sheet";

    int loadedCount = 0;
    int width = 0;
    int height = 0;
    const int tileMaxSide = 320;
    const int gap = 16;
    for (const NativeImage &image : images) {
        result.paths.push_back(image.path);
        result.imageHandles.push_back(image.handle);
        if (image.status != "loaded" || image.width <= 0 || image.height <= 0) {
            continue;
        }
        const double scale = static_cast<double>(tileMaxSide) / static_cast<double>(std::max(image.width, image.height));
        const int tileW = std::max(1, static_cast<int>(std::llround(image.width * std::min(1.0, scale))));
        const int tileH = std::max(1, static_cast<int>(std::llround(image.height * std::min(1.0, scale))));
        width += tileW + (loadedCount > 0 ? gap : 0);
        height = std::max(height, tileH);
        loadedCount += 1;
    }
    result.width = std::max(1, width);
    result.height = std::max(1, height);
    return result;
}
