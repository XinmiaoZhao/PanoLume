// PanoLume C ABI facade implementation. Included exactly once by MyPTGuiEngine.mm.

MyPTGuiNativeContext *myptgui_create_context(void) {
    return new MyPTGuiNativeContext();
}

void myptgui_destroy_context(MyPTGuiNativeContext *context) {
    myptgui_reset_projection_session(context);
    delete context;
}

void myptgui_reset_projection_session(MyPTGuiNativeContext *context) {
    (void)context;
    if (g_nativeMetalResetInteractiveCache != nullptr) {
        g_nativeMetalResetInteractiveCache();
    }
    if (g_nativeMetalEndInteractiveSession != nullptr) {
        g_nativeMetalEndInteractiveSession(0);
    }
}

char *myptgui_engine_capabilities(void) {
    return copy_json(capabilities_json());
}

char *myptgui_dependency_report_json(void) {
    return copy_json(dependency_report_json());
}

int myptgui_identity_matcher_characterization_self_test(void) {
    return panolume::identity_matcher_characterization_self_test() ? 1 : 0;
}

int myptgui_local_warp_characterization_self_test(void) {
    return panolume::local_warp_characterization_self_test() ? 1 : 0;
}

int myptgui_astro_psf_characterization_self_test(void) {
    return panolume::astro_psf_characterization_self_test() ? 1 : 0;
}

int myptgui_astro_geometry_characterization_self_test(void) {
    return native_astro_geometry_characterization_self_test() ? 1 : 0;
}

int myptgui_typed_request_characterization_self_test(void) {
    return panolume::engine_request_characterization_self_test() ? 1 : 0;
}

int myptgui_pts_projection_characterization_self_test(void) {
    return native_pts_projection_characterization_self_test() ? 1 : 0;
}

char *myptgui_render_imported_project(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
#if MYPTGUI_HAS_OPENCV_HEADERS && MYPTGUI_HAS_LIBTIFF_HEADERS
    if (!context) {
        return copy_json(error_json("renderImportedProject", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    NativePTSProjectRequest parsed;
    std::string error;
    if (!native_pts_parse_request(request, parsed, error)) {
        return copy_json(error_json("renderImportedProject", error));
    }
    std::string report;
    if (!native_pts_render_to_tiff(context, parsed, progress, userData, report, error)) {
        if (operationScope.cancelled()) {
            return cancelled_operation_json("renderImportedProject");
        }
        return copy_json(error_json("renderImportedProject", error));
    }
    return copy_json(report);
#else
    (void)context; (void)requestJson; (void)progress; (void)userData;
    return copy_json(error_json(
        "renderImportedProject",
        "Imported-project rendering requires OpenCV and libtiff"
    ));
#endif
}

#if __has_include("Private/ImportedProjectCABI.hpp")
#include "Private/ImportedProjectCABI.hpp"
#endif


char *myptgui_metal_dylib_candidates_for_paths_json(
    const char *bundleRoot,
    const char *executablePath
) {
    return copy_json(json_string_array(native_metal_dylib_candidates_for_paths(
        bundleRoot ? bundleRoot : "",
        executablePath ? executablePath : ""
    )));
}

char *myptgui_load_images(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("loadImages", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("loadImages");
    }
    const std::vector<std::string> paths = request.string_array("paths");
    if (paths.empty()) {
        return copy_json(error_json("loadImages", "No input paths were provided"));
    }
    const int maxSide = request.integer("previewMaxSide", 2400);
    const bool rawHalfSize = request.boolean("rawHalfSize", true);
    emit_progress(progress, userData, "Starting image load", 0.01);
    std::vector<NativeImage> images = load_images_for_paths(context, paths, maxSide, rawHalfSize, progress, userData);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("loadImages");
    }
    return copy_json(image_load_result_json(images, "Image loading complete."));
}

char *myptgui_load_source_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    const char *operation = "loadSourcePreview";
    if (!context) {
        return copy_json(error_json(operation, "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    const std::string path = request.string("path");
    if (path.empty()) {
        return copy_json(error_json(operation, "Source preview path is empty"));
    }
    const bool fullResolution = request.boolean("fullResolution", false);
    const int maxSide = fullResolution
        ? 0
        : std::max(1, request.integer("maxSide", 2400));
    const bool rawHalfSize = fullResolution
        ? false
        : request.boolean("rawHalfSize", true);
    const bool retainRaw16 = fullResolution && is_raw_extension(path);
    emit_progress(
        progress,
        userData,
        fullResolution ? "Loading full-resolution source image" : "Loading source preview",
        0.05
    );
    NativeImage image = load_image_with_native_backends(
        context,
        path,
        maxSide,
        rawHalfSize,
        retainRaw16
    );
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    context->images[image.handle] = image;
    emit_progress(progress, userData, "Source preview decoded", 0.85);
    std::vector<NativeImage> responseImages = {image};
    return copy_json(image_load_result_json(
        responseImages,
        fullResolution
            ? "Full-resolution source preview loaded."
            : "Source preview loaded."
    ));
}

static char *run_preview_from_handles_impl(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData,
    const char *operation
) {
    if (!context) {
        return copy_json(error_json(operation, "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    std::vector<std::string> handles = request.string_array("imageHandles");
    const std::vector<std::string> requestPaths = request.string_array("paths");
    if (!handles.empty() && !requestPaths.empty() && handles.size() != requestPaths.size()) {
        return copy_json(error_json(operation, "Loaded image handle count does not match requested path count"));
    }
    std::vector<NativeImage> images = images_from_handles(context, handles);
    if (handles.empty()) {
        if (!requestPaths.empty()) {
            images = load_images_for_paths(
                context,
                requestPaths,
                request.integer("previewMaxSide", 2400),
                request.boolean("rawHalfSize", true),
                progress,
                userData
            );
        }
    } else if (images.size() != handles.size()) {
        return copy_json(error_json(operation, "Not all requested image handles are loaded"));
    }
    if (images.empty()) {
        return copy_json(error_json(operation, "No loaded images are available"));
    }
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    emit_progress(progress, userData, "Rendering preview", 0.90);
    NativeResult result = native_preview_result(
        context,
        images,
        request.string("projection", "equirectangular"),
        request,
        progress,
        userData
    );
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    prewarm_drag_preview_cache(context, result);
    context->results[result.handle] = result;
    emit_progress(progress, userData, "Preview completed with a closed release gate", 1.0);
    return copy_json(result_json(
        context,
        result,
        operation,
        true,
        "Preview from loaded image handles completed with release quality diagnostics."
    ));
}

char *myptgui_render_contact_sheet_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    return run_preview_from_handles_impl(context, requestJson, progress, userData, "renderContactSheetPreview");
}

char *myptgui_run_preview_from_handles(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    return run_preview_from_handles_impl(context, requestJson, progress, userData, "runPreviewFromHandles");
}

char *myptgui_run_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("runPreview", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("runPreview");
    }
    std::vector<std::string> paths = request.string_array("paths");
    if (paths.empty()) {
        return copy_json(error_json("runPreview", "No input paths were provided"));
    }

    std::vector<NativeImage> images = load_images_for_paths(
        context,
        paths,
        request.integer("previewMaxSide", 2400),
        request.boolean("rawHalfSize", true),
        progress,
        userData
    );
    if (operationScope.cancelled()) {
        return cancelled_operation_json("runPreview");
    }
    NativeResult result = native_preview_result(
        context,
        images,
        request.string("projection", "equirectangular"),
        request,
        progress,
        userData
    );
    if (operationScope.cancelled()) {
        return cancelled_operation_json("runPreview");
    }

    emit_progress(progress, userData, "Preview request accepted", 0.05);
    emit_progress(progress, userData, "Parity gate evaluated", 0.75);
    emit_progress(progress, userData, "Preview completed", 1.0);

    prewarm_drag_preview_cache(context, result);
    const std::string resultHandle = result.handle;
    context->results[resultHandle] = std::move(result);
    NativeResult &storedResult = context->results[resultHandle];
    return copy_json(result_json(
        context,
        storedResult,
        "runPreview",
        true,
        "Preview completed with release quality diagnostics."
    ));
}

char *myptgui_refine_astro_full_resolution(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("refineAstroFullResolution", "Panorama context is null"));
    }
    const panolume::EngineRequest typedRequest(requestJson);
    NativeOperationScope operationScope(context, typedRequest);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("refineAstroFullResolution");
    }
#if MYPTGUI_HAS_OPENCV_HEADERS && MYPTGUI_HAS_CERES_HEADERS
    const panolume::JSONRequest &request = typedRequest.root();
    if (!request.valid()) {
        return copy_json(error_json("refineAstroFullResolution", "Invalid structured refinement request: " + request.error()));
    }
    NativeLensCalibrationPrior lensPrior = native_lens_calibration_prior_from_request(request);
    const std::vector<std::string> paths = request.string_array("paths");
    const int imageCount = static_cast<int>(paths.size());
    std::vector<NativeCameraParams> cameras = native_camera_params_from_json(request);
    const std::vector<double> workingWidths = request.number_array("workingWidths");
    const std::vector<double> workingHeights = request.number_array("workingHeights");
    if (imageCount < 2
        || static_cast<int>(cameras.size()) != imageCount
        || static_cast<int>(workingWidths.size()) != imageCount
        || static_cast<int>(workingHeights.size()) != imageCount) {
        return copy_json(error_json(
            "refineAstroFullResolution",
            "Refinement requires paths, working dimensions, and one camera per image"
        ));
    }
    std::vector<std::pair<int, int>> selectedPairs = native_selected_pairs_from_json(request, imageCount);
    std::sort(selectedPairs.begin(), selectedPairs.end(), [](const auto &lhs, const auto &rhs) {
        if (lhs.first != rhs.first) {
            return lhs.first < rhs.first;
        }
        return lhs.second < rhs.second;
    });
    auto failedResponse = [&](const std::string &reason) {
        std::ostringstream out;
        out << "{";
        out << "\"success\":true,\"operation\":\"refineAstroFullResolution\",";
        out << "\"message\":\"" << json_escape(reason) << "\",";
        out << "\"passed\":false,";
        out << "\"camera_params\":" << camera_params_json(cameras) << ",";
        out << "\"local_warp\":{\"columns\":6,\"rows\":4,\"reference_image\":-1,\"images\":[]},";
        out << "\"astro_refinement\":{";
        out << "\"state\":\"failed\",\"quality_gate_passed\":false,";
        out << "\"reason\":\"" << json_escape(reason) << "\",";
        out << "\"lens_model\":\"unavailable\",\"grid_columns\":16,\"grid_rows\":8,";
        out << "\"pairs\":[],\"lens_models\":[]";
        out << "},\"manual_points\":[]}";
        return copy_json(out.str());
    };

    std::map<int, NativeImage> imageCache;
    std::vector<int> lru;
    bool emitImageStreamingProgress = true;
    std::vector<NativeImage> fullMetadata(static_cast<size_t>(imageCount));
    auto touch = [&](int index) {
        lru.erase(std::remove(lru.begin(), lru.end(), index), lru.end());
        lru.push_back(index);
    };
    auto imageForIndex = [&](int index) -> NativeImage * {
        auto found = imageCache.find(index);
        if (found != imageCache.end()) {
            touch(index);
            return &found->second;
        }
        while (imageCache.size() >= 2 && !lru.empty()) {
            const int evicted = lru.front();
            lru.erase(lru.begin());
            imageCache.erase(evicted);
        }
        if (emitImageStreamingProgress) {
            emit_progress(
                progress,
                userData,
                "Streaming full-resolution source for astro refinement",
                0.05 + 0.45 * static_cast<double>(index) / std::max(1, imageCount)
            );
        }
        NativeImage image = load_image_with_native_backends(context, paths[static_cast<size_t>(index)], 0, false);
        if (image.status != "loaded" || image.pixels.empty()) {
            return nullptr;
        }
        NativeImage metadata = image;
        metadata.pixels.clear();
        fullMetadata[static_cast<size_t>(index)] = std::move(metadata);
        imageCache[index] = std::move(image);
        touch(index);
        return &imageCache.find(index)->second;
    };

    NativeStarSettings baseSettings = native_star_settings_from_request(typedRequest);
    const double starThreshold = std::max(0.5, request.number("starThreshold", 5.0));
    std::vector<std::vector<NativeStar>> fullStarSources(static_cast<size_t>(imageCount));
    std::vector<NativePSFFitAudit> fullPSFFits(static_cast<size_t>(imageCount));
    for (int index = 0; index < imageCount; ++index) {
        if (operationScope.cancelled()) {
            return cancelled_operation_json("refineAstroFullResolution");
        }
        NativeImage *image = imageForIndex(index);
        if (!image) {
            return failedResponse("A full-resolution source could not be decoded for held-out refinement");
        }
        fullStarSources[static_cast<size_t>(index)] = detect_native_stars_for_request(
            *image, starThreshold, typedRequest, &fullPSFFits[static_cast<size_t>(index)]
        );
        fullPSFFits[static_cast<size_t>(index)].imageIndex = index;
        if (fullStarSources[static_cast<size_t>(index)].empty()) {
            return failedResponse("A full-resolution source contains no usable sky stars");
        }
    }
    if (lensPrior.available && !fullMetadata.empty() && !fullMetadata.front().cameraMake.empty()) {
        auto normalizeMake = [](const std::string &value) {
            std::string normalized;
            for (unsigned char character : value) {
                if (std::isalpha(character)) normalized.push_back(static_cast<char>(std::toupper(character)));
            }
            return normalized;
        };
        const std::string profileMake = normalizeMake(lensPrior.cameraMake);
        const std::string imageMake = normalizeMake(fullMetadata.front().cameraMake);
        if (!profileMake.empty() && !imageMake.empty()
            && profileMake.find(imageMake) == std::string::npos
            && imageMake.find(profileMake) == std::string::npos) {
            lensPrior.cameraMakeMismatch = true;
            lensPrior.priorWeight = std::min(lensPrior.priorWeight, 0.15);
            lensPrior.warning = "Profile body " + lensPrior.cameraMake
                + " does not match source body " + fullMetadata.front().cameraMake
                + "; coefficients remain a weak initialization only.";
        }
    }
    for (int index = 0; index < imageCount; ++index) {
        const double scaleX = static_cast<double>(fullMetadata[static_cast<size_t>(index)].width)
            / std::max(workingWidths[static_cast<size_t>(index)], 1.0);
        const double scaleY = static_cast<double>(fullMetadata[static_cast<size_t>(index)].height)
            / std::max(workingHeights[static_cast<size_t>(index)], 1.0);
        if (!std::isfinite(scaleX) || !std::isfinite(scaleY)
            || scaleX <= 0.0 || scaleY <= 0.0
            || std::abs(scaleX - scaleY) / std::max(scaleX, scaleY) > 0.01) {
            return failedResponse("Working/full-resolution dimensions have incompatible aspect ratios");
        }
        cameras[static_cast<size_t>(index)].focalLength *= 0.5 * (scaleX + scaleY);
        cameras[static_cast<size_t>(index)].k1 = 0.0;
        cameras[static_cast<size_t>(index)].k2 = 0.0;
        cameras[static_cast<size_t>(index)].k3 = 0.0;
        cameras[static_cast<size_t>(index)].p1 = 0.0;
        cameras[static_cast<size_t>(index)].p2 = 0.0;
        cameras[static_cast<size_t>(index)].principalOffsetX = 0.0;
        cameras[static_cast<size_t>(index)].principalOffsetY = 0.0;
    }
    // Matching gets its own immutable initialization. A parsed LCP may make
    // the camera prediction less ambiguous, but it remains a weighted hint:
    // the zero-distortion rotation/shared-focal cameras above are still the
    // baseline candidate and the Sony-on-Nikon mismatch can never fix lens
    // coefficients. Correspondence identity is frozen after this step.
    std::vector<NativeCameraParams> identityCameras = cameras;
    if (lensPrior.available) {
        const double weight = std::max(0.0, std::min(1.0, lensPrior.priorWeight));
        for (NativeCameraParams &camera : identityCameras) {
            camera.focalLength *= 1.0 + weight * (lensPrior.focalScale - 1.0);
            camera.k1 = weight * lensPrior.distortion[0];
            camera.k2 = weight * lensPrior.distortion[1];
            camera.k3 = weight * lensPrior.distortion[2];
            camera.p1 = weight * lensPrior.distortion[3];
            camera.p2 = weight * lensPrior.distortion[4];
        }
    }

    std::vector<NativeControlPoint> scaledDraftPoints;
    parse_control_points(typedRequest, scaledDraftPoints);
    for (NativeControlPoint &point : scaledDraftPoints) {
        if (point.imageAIndex < 0 || point.imageBIndex < 0
            || point.imageAIndex >= imageCount || point.imageBIndex >= imageCount) {
            continue;
        }
        const int a = point.imageAIndex;
        const int b = point.imageBIndex;
        point.xA *= static_cast<double>(fullMetadata[static_cast<size_t>(a)].width)
            / std::max(workingWidths[static_cast<size_t>(a)], 1.0);
        point.yA *= static_cast<double>(fullMetadata[static_cast<size_t>(a)].height)
            / std::max(workingHeights[static_cast<size_t>(a)], 1.0);
        point.xB *= static_cast<double>(fullMetadata[static_cast<size_t>(b)].width)
            / std::max(workingWidths[static_cast<size_t>(b)], 1.0);
        point.yB *= static_cast<double>(fullMetadata[static_cast<size_t>(b)].height)
            / std::max(workingHeights[static_cast<size_t>(b)], 1.0);
    }

    std::vector<NativeMatchEdge> fullEdges;
    fullEdges.reserve(selectedPairs.size());
    for (size_t pairIndex = 0; pairIndex < selectedPairs.size(); ++pairIndex) {
        if (operationScope.cancelled()) {
            return cancelled_operation_json("refineAstroFullResolution");
        }
        const int i = selectedPairs[pairIndex].first;
        const int j = selectedPairs[pairIndex].second;
        const std::vector<NativeStar> &starsA = fullStarSources[static_cast<size_t>(i)];
        const std::vector<NativeStar> &starsB = fullStarSources[static_cast<size_t>(j)];
        NativeStarSettings pairSettings = baseSettings;
        pairSettings.pixelTolerance = std::max(8.0, baseSettings.pixelTolerance * 2.4);
        if (!imageForIndex(i) || !imageForIndex(j)) {
            return failedResponse("A full-resolution source could not be reloaded for identity patch validation");
        }
        const auto cachedA = imageCache.find(i);
        const auto cachedB = imageCache.find(j);
        if (cachedA == imageCache.end() || cachedB == imageCache.end()) {
            return failedResponse("The two-image refinement cache lost a source during identity validation");
        }
        std::vector<NativeImage> identityImages = fullMetadata;
        identityImages[static_cast<size_t>(i)] = cachedA->second;
        identityImages[static_cast<size_t>(j)] = cachedB->second;
        // Independent, bidirectional camera prediction plus full-resolution
        // PSF descriptors is the primary identity path. Draft control points
        // are intentionally only a strict fallback seed; otherwise a nearby
        // draft centroid can silently choose a different full-resolution star
        // and contaminate validation/final P95 after the split is sealed.
        NativeStarMatch cameraGuidedMatch = match_native_stars_by_camera_identity(
            identityCameras,
            identityImages,
            i,
            j,
            starsA,
            starsB,
            pairSettings,
            28.0
        );
        const NativeStarMatch independentAudit = cameraGuidedMatch;
        NativeMatchEdge edge;
        bool recoveryAttempted = false;
        bool edgeBuilt = cameraGuidedMatch.success && compute_camera_guided_star_edge(
            i,
            j,
            cachedA->second,
            cachedB->second,
            starsA,
            starsB,
            cameraGuidedMatch,
            pairSettings,
            edge
        );
        if (edgeBuilt) {
            edge.method += "_independent_full_resolution_identity";
        }
        NativeStarMatch draftAnchorAudit;
        if (!edgeBuilt) {
            cameraGuidedMatch = match_full_resolution_stars_from_draft_identities(
                i,
                j,
                cachedA->second,
                cachedB->second,
                starsA,
                starsB,
                scaledDraftPoints,
                pairSettings,
                12.0
            );
            cameraGuidedMatch = expand_draft_identity_anchors_from_pair_seed(
                std::move(cameraGuidedMatch),
                cachedA->second,
                cachedB->second,
                starsA,
                starsB,
                pairSettings
            );
            draftAnchorAudit = cameraGuidedMatch;
            edgeBuilt = cameraGuidedMatch.success && compute_camera_guided_star_edge(
                i,
                j,
                cachedA->second,
                cachedB->second,
                starsA,
                starsB,
                cameraGuidedMatch,
                pairSettings,
                edge
            );
            if (edgeBuilt) {
                edge.method += "_strict_draft_identity_fallback";
            }
        }
        if (!edgeBuilt) {
            edgeBuilt = compute_star_pair_edge(
                i, j, starsA, starsB, pairSettings, edge, &recoveryAttempted
            );
            if (edgeBuilt) {
                edge.method += "_after_strict_identity_failure";
                const NativeStarMatch &audit = draftAnchorAudit.identityCandidates > 0
                    ? draftAnchorAudit : independentAudit;
                edge.identityCandidates = audit.identityCandidates;
                edge.identityAccepted = audit.identityAccepted;
                edge.identityRejectedDescriptor = audit.identityRejectedDescriptor;
                edge.identityRejectedPatch = audit.identityRejectedPatch;
                edge.identityRejectedFWHM = audit.identityRejectedFWHM;
                edge.identityRejectedFlux = audit.identityRejectedFlux;
                edge.identityRejectedRatio = audit.identityRejectedRatio;
                edge.identityRejectedConflict = audit.identityRejectedConflict;
                edge.identityRejectedPrediction = audit.identityRejectedPrediction;
                edge.identityRejectedBoundary = audit.identityRejectedBoundary;
                edge.identityRejectedField = audit.identityRejectedField;
                edge.identityFieldCutoff = audit.identityFieldCutoff;
                edge.identityFieldMedian = audit.identityFieldMedian;
                edge.identityFieldP95 = audit.identityFieldP95;
            }
        }
        if (!edgeBuilt) {
            auto identityAuditSummary = [](const char *label, const NativeStarMatch &audit) {
                std::ostringstream summary;
                summary << label << "={reason:" << audit.reason
                        << ",candidates:" << audit.identityCandidates
                        << ",accepted:" << audit.identityAccepted
                        << ",descriptor:" << audit.identityRejectedDescriptor
                        << ",patch:" << audit.identityRejectedPatch
                        << ",fwhm:" << audit.identityRejectedFWHM
                        << ",flux:" << audit.identityRejectedFlux
                        << ",ratio:" << audit.identityRejectedRatio
                        << ",conflict:" << audit.identityRejectedConflict
                        << ",prediction:" << audit.identityRejectedPrediction
                        << ",boundary:" << audit.identityRejectedBoundary
                        << ",field:" << audit.identityRejectedField
                        << ",field_cutoff:" << audit.identityFieldCutoff << "}";
                return summary.str();
            };
            std::ostringstream reason;
            reason << "selected edge " << i << "-" << j
                   << " could not recover 12 spatially independent full-resolution held-out stars"
                   << " (PSF-fitted stars " << starsA.size() << "/" << starsB.size() << "); "
                   << identityAuditSummary("independent", independentAudit) << "; "
                   << identityAuditSummary("draft_fallback", draftAnchorAudit);
            return failedResponse(reason.str());
        }
        fullEdges.push_back(std::move(edge));
        emit_progress(
            progress,
            userData,
            "Extracting full-resolution held-out star centroids",
            0.50 + 0.25 * static_cast<double>(pairIndex + 1) / std::max<size_t>(1, selectedPairs.size())
        );
    }
    NativeResult refinementResult;
    refinementResult.projection = request.string("projection", "equirectangular");
    native_apply_selected_edges(refinementResult, fullEdges);
    const std::vector<NativeCameraParams> scaledDraftCameras = cameras;
    const NativeAstroRefinementReport scaledDraftHeldOut = native_evaluate_heldout_pairs(
        scaledDraftCameras,
        fullMetadata,
        refinementResult.selectedEdges,
        refinementResult.projection,
        &fullStarSources,
        nullptr,
        NativeAstroEvaluationPartition::validation
    );
    std::vector<NativeControlPoint> trainingPoints = refinementResult.controlPoints;
    std::vector<NativeControlPoint> manualPoints;
    for (const NativeControlPoint &point : scaledDraftPoints) {
        if (point.isManual) {
            manualPoints.push_back(point);
            trainingPoints.push_back(point);
        }
    }

    const int maxIterations = std::max(10, request.integer("optimizerMaxIterations", 200));
    const bool optimizeFocal = request.boolean("optimizeFocal", true);
    const double fixedInitialFocal = cameras.front().focalLength;
    std::string solverSummary;
    emit_progress(progress, userData, "Optimizing full-resolution astro geometry", 0.80);
    if (!run_ceres_camera_adjustment(
            fullMetadata,
            trainingPoints,
            optimizeFocal,
            false,
            maxIterations,
            cameras,
            solverSummary,
            fixedInitialFocal
    )) {
        return failedResponse("Full-resolution Ceres refinement failed: " + solverSummary);
    }

    // Full-resolution pair matches contain more faint detections and require
    // their own robust rounds; reusing the draft's accepted set is not enough.
    // Held-out observations remain outside this vector throughout.
    const double fullRobustThreshold = std::max(
        4.0,
        request.number("cameraModelFullResolutionRobustPx", 8.0)
    );
    for (int round = 0; round < 3; ++round) {
        apply_camera_errors_to_control_points(cameras, fullMetadata, trainingPoints);
        std::vector<NativeControlPoint> robustPoints = native_camera_reprojection_inliers(
            trainingPoints,
            refinementResult.selectedEdges,
            fullRobustThreshold,
            12
        );
        if (robustPoints.size() == trainingPoints.size()
            || robustPoints.size() < static_cast<size_t>(std::max(12, imageCount * 4))) {
            break;
        }
        std::vector<NativeCameraParams> robustCameras = cameras;
        std::string robustSummary;
        if (!run_ceres_camera_adjustment(
                fullMetadata,
                robustPoints,
                optimizeFocal,
                false,
                maxIterations,
                robustCameras,
                robustSummary,
                fixedInitialFocal
            )) {
            break;
        }
        cameras = std::move(robustCameras);
        trainingPoints = std::move(robustPoints);
        solverSummary = robustSummary;
    }

    const NativeAstroRefinementReport refinedBaseHeldOut = native_evaluate_heldout_pairs(
        cameras,
        fullMetadata,
        refinementResult.selectedEdges,
        refinementResult.projection,
        &fullStarSources,
        nullptr,
        NativeAstroEvaluationPartition::validation
    );
    const double scaledDraftP95 = native_heldout_worst_pair_p95(scaledDraftHeldOut);
    const double refinedBaseP95 = native_heldout_worst_pair_p95(refinedBaseHeldOut);
    const double scaledDraftGrid = native_heldout_worst_grid_risk(scaledDraftHeldOut);
    const double refinedBaseGrid = native_heldout_worst_grid_risk(refinedBaseHeldOut);
    const bool refinementImprovedHeldOut = std::isfinite(refinedBaseP95)
        && (!std::isfinite(scaledDraftP95) || refinedBaseP95 < scaledDraftP95)
        && (!std::isfinite(scaledDraftGrid) || refinedBaseGrid <= scaledDraftGrid * 1.05 + 1e-9)
        && native_heldout_pairs_do_not_regress(scaledDraftHeldOut, refinedBaseHeldOut, 1.05);
    if (!refinementImprovedHeldOut) {
        cameras = scaledDraftCameras;
        solverSummary = "full-resolution Ceres candidate rejected because independent validation geometry did not improve";
    }

    std::vector<NativeControlPoint> fitPlusValidationPoints = trainingPoints;
    for (const NativeSelectedEdge &edge : refinementResult.selectedEdges) {
        fitPlusValidationPoints.insert(
            fitPlusValidationPoints.end(),
            edge.validationControlPoints.begin(),
            edge.validationControlPoints.end()
        );
    }
    bool fitPlusValidationRefitSucceeded = false;
    NativeAstroRefinementReport validationSelection = native_select_lens_model_by_heldout(
        fullMetadata,
        trainingPoints,
        fitPlusValidationPoints,
        refinementResult.selectedEdges,
        refinementResult.projection,
        optimizeFocal,
        maxIterations,
        fixedInitialFocal,
        cameras,
        solverSummary,
        fitPlusValidationRefitSucceeded,
        &fullStarSources,
        lensPrior.available ? &lensPrior : nullptr
    );
    if (!fitPlusValidationRefitSucceeded) {
        return failedResponse(
            "Selected Camera/lens model failed mandatory fit+validation refit: " + solverSummary
        );
    }
    panolume::LocalWarpModel localWarpModel;
    panolume::LocalWarpModel sharedGridModel;
    panolume::LocalWarpFitReport sharedGridReport;
    NativeAstroRefinementReport sharedGridValidation;
    bool sharedGridSolved = false;
    if (!validationSelection.qualityGatePassed) {
        sharedGridSolved = native_fit_shared_lens_warp_model(
                cameras,
                fullMetadata,
                trainingPoints,
                sharedGridModel,
                sharedGridReport
            );
        if (sharedGridSolved) {
            sharedGridValidation = native_evaluate_heldout_pairs(
                cameras,
                fullMetadata,
                refinementResult.selectedEdges,
                refinementResult.projection,
                &fullStarSources,
                &sharedGridModel,
                NativeAstroEvaluationPartition::validation
            );
            const double basePair = native_heldout_worst_pair_p95(validationSelection);
            const double warpedPair = native_heldout_worst_pair_p95(sharedGridValidation);
            const double baseGrid = native_heldout_worst_grid_risk(validationSelection);
            const double warpedGrid = native_heldout_worst_grid_risk(sharedGridValidation);
            if (std::isfinite(basePair) && basePair > 0.0 && std::isfinite(warpedPair)) {
                sharedGridReport.worstPairImprovement = (basePair - warpedPair) / basePair;
            }
            if (std::isfinite(baseGrid) && baseGrid > 0.0 && std::isfinite(warpedGrid)) {
                sharedGridReport.worstGridImprovement = (baseGrid - warpedGrid) / baseGrid;
            }
            bool accepted = sharedGridValidation.qualityGatePassed
                && sharedGridReport.worstPairImprovement >= 0.15
                && sharedGridReport.worstGridImprovement >= 0.10
                && native_heldout_pairs_do_not_regress(validationSelection, sharedGridValidation, 1.05)
                && sharedGridReport.minimumJacobianDeterminant >= 0.7
                && sharedGridReport.maxNormalizedDisplacement <= 0.004 + 1e-9;
            if (accepted) {
                panolume::LocalWarpModel refittedWarp;
                panolume::LocalWarpFitReport refittedWarpReport;
                accepted = native_fit_shared_lens_warp_model(
                    cameras,
                    fullMetadata,
                    fitPlusValidationPoints,
                    refittedWarp,
                    refittedWarpReport
                ) && refittedWarpReport.minimumJacobianDeterminant >= 0.7
                    && refittedWarpReport.maxNormalizedDisplacement <= 0.004 + 1e-9;
                if (accepted) localWarpModel = std::move(refittedWarp);
            }
            sharedGridReport.accepted = accepted;
            sharedGridReport.reason = accepted
                ? "shared 4x6 lens grid passed validation and was refit on fit+validation"
                : (sharedGridValidation.qualityGatePassed
                    ? "shared grid did not meet the 15% pair and 10% grid improvement/stability gates or refit constraints"
                    : "shared grid candidate still failed one or more independent validation gates");
            NativeLensModelCandidateReport gridCandidate;
            gridCandidate.model = validationSelection.lensModel + "_shared_lens_grid_4x6";
            gridCandidate.solverSucceeded = sharedGridReport.solverSucceeded;
            gridCandidate.accepted = accepted;
            gridCandidate.worstPairP95 = warpedPair;
            gridCandidate.worstGridRiskRatio = warpedGrid;
            gridCandidate.heldOutImprovement = sharedGridReport.worstPairImprovement;
            gridCandidate.reason = sharedGridReport.reason;
            validationSelection.lensModels.push_back(gridCandidate);
            if (accepted) {
                sharedGridValidation.lensModel = validationSelection.lensModel + "_shared_lens_grid_4x6";
                sharedGridValidation.lensModels = validationSelection.lensModels;
                sharedGridValidation.localWarp = sharedGridReport;
                validationSelection = std::move(sharedGridValidation);
            } else {
                validationSelection.localWarp = sharedGridReport;
            }
        } else {
            validationSelection.localWarp = sharedGridReport;
        }
    }
    if (!validationSelection.qualityGatePassed && sharedGridSolved) {
        std::string affineEligibilityReason;
        const bool affineEligible = native_validation_has_stable_per_image_residual(
            cameras,
            fullMetadata,
            refinementResult.selectedEdges,
            sharedGridModel,
            affineEligibilityReason
        );
        panolume::LocalWarpModel affineModel;
        panolume::LocalWarpModel combinedModel;
        panolume::LocalWarpFitReport affineReport;
        bool affineSolved = affineEligible && native_fit_shared_lens_warp_model(
                cameras,
                fullMetadata,
                trainingPoints,
                affineModel,
                affineReport,
                true,
                &sharedGridModel
            );
        affineSolved = affineSolved && native_compose_local_warp_models(
            sharedGridModel,
            affineModel,
            combinedModel,
            affineReport
        );
        if (affineSolved) {
            NativeAstroRefinementReport affineValidation = native_evaluate_heldout_pairs(
                cameras,
                fullMetadata,
                refinementResult.selectedEdges,
                refinementResult.projection,
                &fullStarSources,
                &combinedModel,
                NativeAstroEvaluationPartition::validation
            );
            const double basePair = native_heldout_worst_pair_p95(validationSelection);
            const double affinePair = native_heldout_worst_pair_p95(affineValidation);
            const double baseGrid = native_heldout_worst_grid_risk(validationSelection);
            const double affineGrid = native_heldout_worst_grid_risk(affineValidation);
            if (std::isfinite(basePair) && basePair > 0.0 && std::isfinite(affinePair)) {
                affineReport.worstPairImprovement = (basePair - affinePair) / basePair;
            }
            if (std::isfinite(baseGrid) && baseGrid > 0.0 && std::isfinite(affineGrid)) {
                affineReport.worstGridImprovement = (baseGrid - affineGrid) / baseGrid;
            }
            bool accepted = affineValidation.qualityGatePassed
                && affineReport.worstPairImprovement >= 0.15
                && affineReport.worstGridImprovement >= 0.10
                && native_heldout_pairs_do_not_regress(validationSelection, affineValidation, 1.05)
                && native_heldout_pairs_do_not_regress(sharedGridValidation, affineValidation, 1.05)
                && affineReport.minimumJacobianDeterminant >= 0.7
                && affineReport.maxNormalizedDisplacement <= 0.004 + 1e-9;
            if (accepted) {
                panolume::LocalWarpModel refittedShared;
                panolume::LocalWarpFitReport refittedSharedReport;
                panolume::LocalWarpModel refittedAffine;
                panolume::LocalWarpFitReport refittedAffineReport;
                panolume::LocalWarpModel refittedCombined;
                accepted = native_fit_shared_lens_warp_model(
                    cameras,
                    fullMetadata,
                    fitPlusValidationPoints,
                    refittedShared,
                    refittedSharedReport
                ) && native_fit_shared_lens_warp_model(
                    cameras,
                    fullMetadata,
                    fitPlusValidationPoints,
                    refittedAffine,
                    refittedAffineReport,
                    true,
                    &refittedShared
                ) && native_compose_local_warp_models(
                    refittedShared,
                    refittedAffine,
                    refittedCombined,
                    refittedAffineReport
                );
                if (accepted) localWarpModel = std::move(refittedCombined);
            }
            affineReport.accepted = accepted;
            affineReport.reason = accepted
                ? "validation-stable zero-mean per-image affine residual was layered over the shared grid and baked into 4x6 nodes"
                : "layered per-image affine residual failed validation improvement/stability or fit+validation refit constraints";
            NativeLensModelCandidateReport affineCandidate;
            affineCandidate.model = validationSelection.lensModel
                + "_shared_lens_grid_4x6_zero_mean_per_image_affine";
            affineCandidate.solverSucceeded = affineReport.solverSucceeded;
            affineCandidate.accepted = accepted;
            affineCandidate.worstPairP95 = affinePair;
            affineCandidate.worstGridRiskRatio = affineGrid;
            affineCandidate.heldOutImprovement = affineReport.worstPairImprovement;
            affineCandidate.reason = affineReport.reason;
            validationSelection.lensModels.push_back(affineCandidate);
            validationSelection.localWarp = affineReport;
            if (accepted) {
                affineValidation.lensModel = affineCandidate.model;
                affineValidation.lensModels = validationSelection.lensModels;
                affineValidation.localWarp = affineReport;
                validationSelection = std::move(affineValidation);
            }
        } else {
            affineReport.reason = affineEligible
                ? "layered per-image affine residual solve or composition failed"
                : affineEligibilityReason;
            validationSelection.localWarp = affineReport;
            NativeLensModelCandidateReport affineCandidate;
            affineCandidate.model = validationSelection.lensModel
                + "_shared_lens_grid_4x6_zero_mean_per_image_affine";
            affineCandidate.solverSucceeded = false;
            affineCandidate.accepted = false;
            affineCandidate.reason = affineReport.reason;
            validationSelection.lensModels.push_back(affineCandidate);
        }
    }
    NativeAstroRefinementReport refinement = native_evaluate_heldout_pairs(
        cameras,
        fullMetadata,
        refinementResult.selectedEdges,
        refinementResult.projection,
        &fullStarSources,
        localWarpModel.images.empty() ? nullptr : &localWarpModel,
        NativeAstroEvaluationPartition::finalHeldOut
    );
    refinement.lensModel = validationSelection.lensModel;
    refinement.lensModels = validationSelection.lensModels;
    refinement.localWarp = validationSelection.localWarp;
    refinement.lensPriorAvailable = validationSelection.lensPriorAvailable;
    refinement.lensPriorSHA256 = validationSelection.lensPriorSHA256;
    refinement.lensPriorWarning = validationSelection.lensPriorWarning;
    refinement.lensPriorWeight = validationSelection.lensPriorWeight;
    refinement.lensPriorConversionMaxErrorPixels = validationSelection.lensPriorConversionMaxErrorPixels;
    refinement.psfFits = fullPSFFits;
    if (request.boolean("includeWorstStarPatches", false)) {
        emitImageStreamingProgress = false;
        for (NativeHeldOutPairReport &pair : refinement.pairs) {
            for (NativeWorstAstroObservationReport &observation : pair.worstObservations) {
                if (operationScope.cancelled()) {
                    return cancelled_operation_json("refineAstroFullResolution");
                }
                if (NativeImage *source = imageForIndex(pair.i)) {
                    observation.sourcePatchDataURL = native_worst_star_patch_data_url(
                        *source, observation.sourceX, observation.sourceY
                    );
                }
                if (NativeImage *target = imageForIndex(pair.j)) {
                    observation.targetPatchDataURL = native_worst_star_patch_data_url(
                        *target, observation.targetX, observation.targetY
                    );
                }
                if (!observation.sourcePatchDataURL.empty()
                    && !observation.targetPatchDataURL.empty()) {
                    observation.patchSide = 15;
                }
            }
        }
    }
    const bool passed = refinement.qualityGatePassed;
    refinement.state = passed ? "passed" : "failed";
    refinement.reason = passed
        ? "full-resolution held-out pair and 16x8 output-grid gates passed"
        : "full-resolution held-out pair or output-grid gate failed";

    apply_camera_errors_to_control_points(cameras, fullMetadata, manualPoints);
    const double manualThreshold = std::max(1.0, request.number("cameraModelRobustReprojectionPx", 5.0));
    std::ostringstream manualJSON;
    manualJSON << "[";
    for (size_t index = 0; index < manualPoints.size(); ++index) {
        if (index) {
            manualJSON << ",";
        }
        const bool accepted = std::isfinite(manualPoints[index].error)
            && manualPoints[index].error <= manualThreshold;
        manualJSON << "{";
        manualJSON << "\"index\":" << index << ",";
        manualJSON << "\"accepted\":" << bool_json(accepted) << ",";
        manualJSON << "\"error_px\":" << number_json(manualPoints[index].error) << ",";
        manualJSON << "\"reason\":\""
            << (accepted ? "accepted by robust full-resolution reprojection gate"
                         : "rejected by robust full-resolution reprojection gate")
            << "\"}";
    }
    manualJSON << "]";

    std::vector<int> fullWidths;
    std::vector<int> fullHeights;
    for (int index = 0; index < imageCount; ++index) {
        fullWidths.push_back(fullMetadata[static_cast<size_t>(index)].width);
        fullHeights.push_back(fullMetadata[static_cast<size_t>(index)].height);
        const double scale = std::max(
            static_cast<double>(fullMetadata[static_cast<size_t>(index)].width)
                / std::max(workingWidths[static_cast<size_t>(index)], 1.0),
            1e-9
        );
        cameras[static_cast<size_t>(index)].focalLength /= scale;
    }
    emit_progress(progress, userData, "Full-resolution astro refinement complete", 1.0);
    std::ostringstream out;
    out << "{";
    out << "\"success\":true,\"operation\":\"refineAstroFullResolution\",";
    out << "\"message\":\"" << json_escape(refinement.reason) << "\",";
    out << "\"passed\":" << bool_json(passed) << ",";
    out << "\"camera_params\":" << camera_params_json(cameras) << ",";
    out << "\"local_warp\":" << local_warp_model_json(localWarpModel) << ",";
    out << "\"astro_refinement\":" << astro_refinement_report_json(refinement) << ",";
    out << "\"manual_points\":" << manualJSON.str() << ",";
    out << "\"full_widths\":" << number_array_json(fullWidths) << ",";
    out << "\"full_heights\":" << number_array_json(fullHeights);
    out << "}";
    return copy_json(out.str());
#else
    (void)progress;
    (void)userData;
    return copy_json(error_json(
        "refineAstroFullResolution",
        "Full-resolution astro refinement requires OpenCV and Ceres"
    ));
#endif
}

char *myptgui_apply_astro_refinement(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("applyAstroRefinement", "Panorama context is null"));
    }
    const panolume::EngineRequest typedRequest(requestJson);
    NativeOperationScope operationScope(context, typedRequest);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("applyAstroRefinement");
    }
#if MYPTGUI_HAS_OPENCV_HEADERS
    const panolume::JSONRequest &request = typedRequest.root();
    const std::string handle = request.string("resultHandle", "");
    auto found = context->results.find(handle);
    if (found == context->results.end()) {
        return copy_json(error_json("applyAstroRefinement", "Unknown draft result handle"));
    }
    std::vector<NativeCameraParams> cameras = native_camera_params_from_json(request);
    if (cameras.size() != found->second.imageHandles.size() || cameras.empty()) {
        return copy_json(error_json("applyAstroRefinement", "Refined camera count does not match draft sources"));
    }
    NativeResult refined = copy_result_without_panorama_pixels(found->second);
    refined.handle = handle;
    refined.cameraParams = cameras;
    refined.baseCameraParams = cameras;
    refined.localWarpModel = native_local_warp_from_json(request);
    if (!refined.localWarpModel.images.empty()
        && refined.localWarpModel.images.size() != refined.imageHandles.size()) {
        return copy_json(error_json("applyAstroRefinement", "Refined local-warp image count does not match draft sources"));
    }
    refined.astroRefinementReport.state = "passed";
    refined.astroRefinementReport.qualityGatePassed = true;
    refined.astroRefinementReport.reason = "full-resolution astro refinement applied";
    refined.astroRefinementJsonOverride = request.string("astroRefinementJSON", "");
    refined.geometry = "camera";
    refined.projectionGeometryState = "verified_camera";
    refined.geometryGatePassed = true;
    refined.geometryGateReason = "full-resolution held-out geometry gate passed";
    refined.previewStatus = "camera_projection_preview";
    refined.previewFailureReason.clear();
    std::vector<NativeImage> images = images_from_handles(context, refined.imageHandles);
    if (images.size() != refined.imageHandles.size()) {
        return copy_json(error_json("applyAstroRefinement", "Draft preview sources are unavailable"));
    }
    std::string failureReason;
    emit_progress(progress, userData, "Rendering refined camera preview", 0.75);
    if (!render_native_camera_projection_preview(
            images,
            refined,
            refined.projection,
            true,
            progress,
            userData,
            failureReason
        )) {
        return copy_json(error_json("applyAstroRefinement", "Refined preview render failed: " + failureReason));
    }
    refined.previewStatus = "camera_projection_preview";
    refined.geometryGatePassed = true;
    refined.geometryGateReason = "full-resolution held-out geometry and refined preview passed";
    context->results[handle] = std::move(refined);
    NativeResult &stored = context->results[handle];
    emit_progress(progress, userData, "Refined camera preview applied", 1.0);
    return copy_json(result_json(
        context,
        stored,
        "applyAstroRefinement",
        true,
        "Full-resolution astro refinement passed and was applied."
    ));
#else
    (void)progress;
    (void)userData;
    return copy_json(error_json("applyAstroRefinement", "OpenCV renderer is unavailable"));
#endif
}

char *myptgui_rerender_from_control_points(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("rerenderFromControlPoints", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("rerenderFromControlPoints");
    }
    const std::string handle = request.string("resultHandle");
    auto found = context->results.find(handle);
    if (found == context->results.end()) {
        return copy_json(error_json("rerenderFromControlPoints", "Unknown result handle"));
    }
    NativeResult rerendered;
    std::string failureReason;
    emit_progress(progress, userData, "Starting control-point rerender", 0.02);
    bool rerenderedSuccessfully = false;
#if MYPTGUI_HAS_OPENCV_HEADERS
    // Rebuild every edited star pair graph from the submitted observations,
    // even when the previous result happened to contain camera geometry. This
    // removes stale selected edges and gives newly added manual edges a chance
    // to establish a fresh global camera initialization.
    if (found->second.geometry == "homography"
        || lower_string(found->second.alignmentFamily) == "stars") {
        rerenderedSuccessfully = rerender_native_homography_from_control_points(
            context,
            found->second,
            request,
            rerendered,
            progress,
            userData,
            failureReason
        );
    } else
#endif
    if (found->second.geometry == "camera") {
        rerenderedSuccessfully = rerender_native_camera_from_control_points(
            context,
            found->second,
            request,
            rerendered,
            progress,
            userData,
            failureReason
        );
    } else if (failureReason.empty()) {
        failureReason = "source result does not contain camera or homography geometry";
    }
    if (!rerenderedSuccessfully) {
        if (operationScope.cancelled()) {
            return cancelled_operation_json("rerenderFromControlPoints");
        }
        if (!rerendered.handle.empty()) {
            rerendered.geometryGatePassed = false;
            rerendered.geometryGateReason = failureReason;
            rerendered.previewFailureReason = failureReason;
            const std::string failedHandle = rerendered.handle;
            context->results[failedHandle] = std::move(rerendered);
            NativeResult &storedFailure = context->results[failedHandle];
            return copy_json(result_json(
                context,
                storedFailure,
                "rerenderFromControlPoints",
                false,
                "Control-point edits were preserved, but re-optimization failed: " + failureReason
            ));
        }
        return copy_json(error_json("rerenderFromControlPoints", "Control-point rerender failed: " + failureReason));
    }
    if (operationScope.cancelled()) {
        return cancelled_operation_json("rerenderFromControlPoints");
    }
    prewarm_drag_preview_cache(context, rerendered);
    const std::string rerenderedHandle = rerendered.handle;
    context->results[rerenderedHandle] = std::move(rerendered);
    NativeResult &storedRerendered = context->results[rerenderedHandle];
    emit_progress(progress, userData, "Control-point rerender completed", 1.0);
    return copy_json(result_json(
        context,
        storedRerendered,
        "rerenderFromControlPoints",
        true,
        "Control-point rerender completed with edited control points."
    ));
}

char *myptgui_render_projection_preview(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("renderProjectionPreview", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    // Allocate the version before waiting for the serialized native renderer.
    // This lets a newly enqueued drag or release invalidate an older live frame
    // while that frame is still inside OpenCV/Metal work.
    const unsigned long long requestVersion = context->projectionPreviewVersion.fetch_add(1) + 1;
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("renderProjectionPreview");
    }
    const std::string handle = request.string("resultHandle");
    auto found = context->results.find(handle);
    if (found == context->results.end()) {
        return copy_json(error_json("renderProjectionPreview", "Unknown result handle"));
    }
    const std::string resultKey = found->first;
    const std::string quality = lower_string(request.string("quality", "dragPreview"));
    const bool geometryOnlyCommit = quality == "geometrycommit" || quality == "geometry_only";
    const bool commitGeometry = geometryOnlyCommit || quality == "committedpreview" || quality == "export";
    const std::string projection = request.string("projection", found->second.projection);
    const double pitchDegrees = request.number("pitchDegrees", 0.0);
    const double yawDegrees = request.number("yawDegrees", 0.0);
    const double rollDegrees = request.number("rollDegrees", 0.0);

    if (geometryOnlyCommit) {
        // Geometry-only release is deliberately handled before cloning the
        // source result. That clone includes every control point/diagnostic
        // collection and dominated release latency for large RAW stitches.
        clear_transient_projection_results(context, resultKey);
        NativeResult &committed = found->second;
        if (committed.baseCameraParams.empty()) {
            committed.baseCameraParams = committed.cameraParams;
        }
        if (committed.baseCameraParams.empty()
            || committed.baseCameraParams.size() != committed.imageHandles.size()) {
            return copy_json(error_json(
                "renderProjectionPreview",
                "Geometry-only projection commit requires valid base camera params"
            ));
        }
        committed.cameraParams = committed.baseCameraParams;
        apply_pose_adjustment_to_cameras(
            committed.cameraParams,
            pitchDegrees,
            yawDegrees,
            rollDegrees
        );
        committed.projection = projection;
        committed.blendMode = lower_string(request.string(
            "blendMode",
            committed.blendMode
        ));
        committed.previewRendererRequested = lower_string(request.string(
            "previewRendererBackend",
            committed.previewRendererRequested.empty() ? "auto" : committed.previewRendererRequested
        ));
        if (committed.blendMode == "multiband") {
            committed.previewRendererRequested = "cpu";
        }
        committed.hasProjectionAdjustment = true;
        committed.projectionAdjustmentDegrees = {pitchDegrees, yawDegrees, rollDegrees};
        emit_progress(progress, userData, "Projection geometry committed", 1.0);
        return copy_json(geometry_commit_result_json(
            committed,
            "renderProjectionPreview",
            "Projection geometry committed; the existing preview frame was retained."
        ));
    }

    NativeResult preview = copy_result_without_panorama_pixels(found->second);
    preview.blendMode = lower_string(request.string("blendMode", preview.blendMode));
    preview.previewRendererRequested = lower_string(request.string(
        "previewRendererBackend",
        preview.previewRendererRequested.empty() ? "auto" : preview.previewRendererRequested
    ));
    if (!commitGeometry) {
        // Interactive frames have one deterministic quality contract. Metal
        // Fast is attempted first; the renderer already falls back to the CPU
        // fast path when the runtime is unavailable.
        preview.blendMode = "fast";
        preview.previewRendererRequested = "metal_fast";
    } else if (preview.blendMode == "multiband") {
        // The Metal bridge intentionally has no multiband implementation.
        preview.previewRendererRequested = "cpu";
    }
    if (!commitGeometry) {
        preview.handle += "-projection-preview-" + std::to_string(context->nextResultId.fetch_add(1));
    }
    if (commitGeometry) {
        // A release request owns the lane once acquired. Remove obsolete JSON
        // drag results before doing any high-quality work so they cannot be
        // presented or reused after the release frame.
        clear_transient_projection_results(context, resultKey);
    }
    if (preview.cameraParams.empty()
        || preview.cameraParams.size() != preview.imageHandles.size()) {
        return copy_json(error_json(
            "renderProjectionPreview",
            "Projection drag requires a renderable Camera solution; Homography diagnostics cannot be dragged"
        ));
    }
#if MYPTGUI_HAS_OPENCV_HEADERS
    if (dependency_available("opencv")) {
        std::vector<NativeImage> images;
        std::vector<NativeImage> renderImages;
        if (!commitGeometry) {
            const size_t imageCount = preview.imageHandles.size();
            const DragPreviewLimits limits = drag_preview_limits(imageCount);
            const int dragMaxSide = capped_drag_request_limit(
                request,
                "previewMaxSide",
                limits.sourceMaxSide
            );
            const std::string cacheKey = found->second.handle + ":drag:" + std::to_string(dragMaxSide);
            renderImages = cached_resized_images_from_handles(context, cacheKey, preview.imageHandles, dragMaxSide, images);
        } else {
            images = images_from_handles(context, preview.imageHandles);
            renderImages = images;
        }
        if (renderImages.size() != preview.imageHandles.size() || renderImages.empty()) {
            return copy_json(error_json("renderProjectionPreview", "Source images are unavailable for projection preview"));
        }
        std::string failureReason;
        if (preview.baseCameraParams.empty() && !found->second.cameraParams.empty()) {
            preview.baseCameraParams = found->second.cameraParams;
        }
        if (!preview.baseCameraParams.empty()) {
            preview.cameraParams = preview.baseCameraParams;
        }
        if (!commitGeometry) {
            const size_t imageCount = renderImages.size();
            const DragPreviewLimits limits = drag_preview_limits(imageCount);
            std::string scaleFailure;
            const int dragMaxSide = capped_drag_request_limit(
                request,
                "previewMaxSide",
                limits.sourceMaxSide
            );
            const std::string cacheKey = found->second.handle + ":drag:" + std::to_string(dragMaxSide);
            std::vector<NativeCameraParams> scaledCameras = cached_drag_preview_camera_params(
                context,
                cacheKey,
                preview.cameraParams,
                images,
                renderImages,
                scaleFailure
            );
            if (!scaleFailure.empty() || scaledCameras.empty()) {
                return copy_json(error_json("renderProjectionPreview", "Drag-preview camera scaling failed: " + scaleFailure));
            }
            preview.cameraParams = std::move(scaledCameras);
            preview.outputBounds.maxOutputPixels = capped_drag_request_limit(
                request,
                "maxOutputPixels",
                limits.maxOutputPixels
            );
            preview.outputBounds.maxOutputSide = capped_drag_request_limit(
                request,
                "maxOutputSide",
                limits.maxOutputSide
            );
        } else {
            preview.outputBounds.maxOutputPixels = std::max(
                1,
                request.integer("maxOutputPixels", preview.outputBounds.maxOutputPixels > 0
                    ? preview.outputBounds.maxOutputPixels
                    : 32000000)
            );
            preview.outputBounds.maxOutputSide = std::max(
                1,
                request.integer("maxOutputSide", preview.outputBounds.maxOutputSide > 0
                    ? preview.outputBounds.maxOutputSide
                    : 9000)
            );
        }
        apply_pose_adjustment_to_cameras(preview.cameraParams, pitchDegrees, yawDegrees, rollDegrees);
        preview.hasProjectionAdjustment = true;
        preview.projectionAdjustmentDegrees = {pitchDegrees, yawDegrees, rollDegrees};
        if (render_native_camera_projection_preview(
            renderImages,
            preview,
            projection,
            false,
            progress,
            userData,
            failureReason,
            &context->projectionPreviewVersion,
            requestVersion
        )) {
            if (preview.projectionGeometryState == "unverified_camera_draft"
                || !preview.geometryGatePassed) {
                preview.projectionGeometryState = "unverified_camera_draft";
                preview.previewStatus = "unverified_camera_draft";
                preview.geometryGatePassed = false;
            }
            if (operationScope.cancelled()) {
                return cancelled_operation_json("renderProjectionPreview");
            }
            if (context->projectionPreviewVersion.load() != requestVersion) {
                return copy_json(error_json("renderProjectionPreview", "Projection drag preview was superseded by a newer request"));
            }
            if (commitGeometry) {
                preview.handle = resultKey;
                context->results[resultKey] = std::move(preview);
                NativeResult &stored = context->results[resultKey];
                emit_progress(progress, userData, "Camera projection preview rendered", 1.0);
                return copy_json(result_json(
                    context,
                    stored,
                    "renderProjectionPreview",
                    true,
                    "Projection adjustment committed; full-resolution export will use the adjusted geometry."
                ));
            } else {
                clear_transient_projection_results(context);
                const std::string previewHandle = preview.handle;
                context->results[previewHandle] = std::move(preview);
                context->transientProjectionResultHandles.insert(previewHandle);
                NativeResult &stored = context->results[previewHandle];
                emit_progress(progress, userData, "Camera projection preview rendered", 1.0);
                return copy_json(result_json(
                    context,
                    stored,
                    "renderProjectionPreview",
                    true,
                    "Projection drag preview rendered."
                ));
            }
        }
        if (operationScope.cancelled()) {
            return cancelled_operation_json("renderProjectionPreview");
        }
        if (context->projectionPreviewVersion.load() != requestVersion) {
            return copy_json(error_json("renderProjectionPreview", "Projection preview was superseded by a newer request"));
        }
        return copy_json(error_json(
            "renderProjectionPreview",
            "Camera projection preview failed: " + failureReason
        ));
    }
#endif
    return copy_json(error_json(
        "renderProjectionPreview",
        "Camera projection preview requires the OpenCV renderer"
    ));
}

static bool write_preview_tiff_diagnostic(
    const NativeResult &result,
    const std::string &outputPath,
    int bitDepth,
    std::string &profileJson,
    std::string &errorMessage
) {
#if MYPTGUI_HAS_LIBTIFF_HEADERS
    if (outputPath.empty()) {
        errorMessage = "output path is empty";
        return false;
    }
    if (result.width <= 0 || result.height <= 0 || result.panoramaPixels.empty()) {
        errorMessage = "result does not contain preview pixels";
        return false;
    }
    if (bitDepth != 8 && bitDepth != 16) {
        errorMessage = "diagnostic TIFF export supports only 8-bit or 16-bit RGB";
        return false;
    }
    const size_t expected = static_cast<size_t>(result.width) * static_cast<size_t>(result.height) * 3;
    if (result.panoramaPixels.size() < expected) {
        errorMessage = "preview pixel buffer is smaller than expected";
        return false;
    }

    auto start = std::chrono::steady_clock::now();
    TIFF *tiff = TIFFOpen(outputPath.c_str(), "w8");
    if (!tiff) {
        errorMessage = "failed to open TIFF output";
        return false;
    }
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, static_cast<uint32_t>(result.width));
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, static_cast<uint32_t>(result.height));
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 3);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, bitDepth);
    TIFFSetField(tiff, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    const int stripHeightLimit = 256;
    TIFFSetField(tiff, TIFFTAG_ROWSPERSTRIP, stripHeightLimit);
    TIFFSetField(tiff, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT);

    bool ok = true;
    if (bitDepth == 16) {
        std::vector<uint16_t> row(static_cast<size_t>(result.width) * 3);
        for (int y = 0; y < result.height; ++y) {
            const size_t rowOffset = static_cast<size_t>(y) * static_cast<size_t>(result.width) * 3;
            for (int x = 0; x < result.width * 3; ++x) {
                const float value = result.panoramaPixels[rowOffset + static_cast<size_t>(x)];
                const double clamped = std::min(1.0, std::max(0.0, static_cast<double>(value)));
                row[static_cast<size_t>(x)] = static_cast<uint16_t>(std::llround(clamped * 65535.0));
            }
            if (TIFFWriteScanline(tiff, row.data(), static_cast<uint32_t>(y), 0) < 0) {
                ok = false;
                break;
            }
        }
    } else {
        std::vector<uint8_t> row(static_cast<size_t>(result.width) * 3);
        for (int y = 0; y < result.height; ++y) {
            const size_t rowOffset = static_cast<size_t>(y) * static_cast<size_t>(result.width) * 3;
            for (int x = 0; x < result.width * 3; ++x) {
                const float value = result.panoramaPixels[rowOffset + static_cast<size_t>(x)];
                const double clamped = std::min(1.0, std::max(0.0, static_cast<double>(value)));
                row[static_cast<size_t>(x)] = static_cast<uint8_t>(std::llround(clamped * 255.0));
            }
            if (TIFFWriteScanline(tiff, row.data(), static_cast<uint32_t>(y), 0) < 0) {
                ok = false;
                break;
            }
        }
    }
    TIFFClose(tiff);
    if (!ok) {
        errorMessage = "failed while writing TIFF scanlines";
        return false;
    }
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double peakMemoryMB = current_peak_memory_mb();
    std::ostringstream profile;
    profile << "{";
    profile << "\"mode\":\"preview_tiff_diagnostic\",";
    profile << "\"renderer_requested\":\"preview_tiff_diagnostic\",";
    profile << "\"renderer_used\":\"libtiff_scanlines\",";
    profile << "\"renderer_fallback\":false,";
    profile << "\"writer\":\"libtiff_scanlines\",";
    profile << "\"geometry_source\":\"" << json_escape(result.geometry) << "\",";
    profile << "\"quality_gate_passed\":" << bool_json(result.cameraModelReport.qualityGatePassed) << ",";
    if (!result.starProjectionAlignmentJson.empty()) {
        profile << "\"star_projection_alignment\":" << result.starProjectionAlignmentJson << ",";
    }
    profile << "\"bit_depth\":" << bitDepth << ",";
    profile << "\"width\":" << result.width << ",";
    profile << "\"height\":" << result.height << ",";
    profile << "\"total_seconds\":" << elapsed << ",";
    append_peak_memory_json(profile, peakMemoryMB);
    profile << "}";
    profileJson = profile.str();
    return true;
#else
    (void)result;
    (void)outputPath;
    (void)bitDepth;
    (void)profileJson;
    errorMessage = "libtiff headers are not available";
    return false;
#endif
}

static bool write_camera_strip_tiff_diagnostic(
    const NativeResult &result,
    const std::vector<NativeImage> &images,
    const std::string &outputPath,
    int bitDepth,
    int maxOutputPixels,
    int maxOutputSide,
    const std::string &profileMode,
    const std::string &rendererRequested,
    const std::string &profileWriter,
    bool fullResolutionSource,
    double meanCameraScale,
    double maxCameraScale,
    const StretchParams *stretchParams,
    double outputStretchStrength,
    NativeOutputBoundsReport *writtenBounds,
    std::string &profileJson,
    std::string &errorMessage,
    const std::vector<std::string> *streamingPaths = nullptr,
    MyPTGuiNativeContext *streamingContext = nullptr,
    NativeWorkingSetStats *workingSetStats = nullptr,
    uint64_t workingSetBudgetBytes = 0
) {
#if MYPTGUI_HAS_LIBTIFF_HEADERS && MYPTGUI_HAS_OPENCV_HEADERS
    if (outputPath.empty()) {
        errorMessage = "output path is empty";
        return false;
    }
    if (result.cameraParams.size() != images.size() || result.cameraParams.empty()) {
        errorMessage = "camera strip diagnostic requires camera params";
        return false;
    }
    if (lower_string(result.blendMode) == "source_ownership") {
        errorMessage = "source ownership is currently an experimental CPU preview mode; strip export remains fail-closed until CPU/Metal ownership certification";
        return false;
    }
    if (bitDepth != 8 && bitDepth != 16) {
        errorMessage = "camera strip TIFF diagnostic supports only 8-bit or 16-bit RGB";
        return false;
    }

    std::string planFailure;
    NativeOutputBoundsReport bounds;
    if (maxOutputPixels > 0) {
        bounds.maxOutputPixels = maxOutputPixels;
    }
    if (maxOutputSide > 0) {
        bounds.maxOutputSide = maxOutputSide;
    }
    double offsetX = 0.0;
    double offsetY = 0.0;
    double projectionScale = 1.0;
    if (!native_camera_projection_plan(
        images,
        result.cameraParams,
        result.projection,
        bounds,
        offsetX,
        offsetY,
        projectionScale,
        planFailure
    )) {
        errorMessage = planFailure;
        return false;
    }

    const bool streamingSource = streamingPaths != nullptr && streamingContext != nullptr;
    if (streamingSource && streamingPaths->size() != images.size()) {
        errorMessage = "streaming source path count does not match camera images";
        return false;
    }

    auto start = std::chrono::steady_clock::now();
    if (workingSetStats) {
        workingSetStats->sample();
    }
    TIFF *tiff = TIFFOpen(outputPath.c_str(), "w8");
    if (!tiff) {
        errorMessage = "failed to open TIFF output";
        return false;
    }
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, static_cast<uint32_t>(bounds.width));
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, static_cast<uint32_t>(bounds.height));
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 3);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, bitDepth);
    TIFFSetField(tiff, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    int stripHeightLimit = streamingSource ? 64 : 256;
    if (streamingSource && workingSetBudgetBytes > 0) {
        uint64_t maximumSourceBytes = 0;
        for (const NativeImage &image : images) {
            maximumSourceBytes = std::max<uint64_t>(maximumSourceBytes, native16_rgb_byte_count(image));
        }
        constexpr uint64_t estimatedBytesPerPixelRow = 64;
        constexpr uint64_t fixedMarginRows = 181;
        const uint64_t rowBytes = static_cast<uint64_t>(bounds.width) * estimatedBytesPerPixelRow;
        const uint64_t fixedBytes = maximumSourceBytes + rowBytes * fixedMarginRows;
        if (maximumSourceBytes > workingSetBudgetBytes || fixedBytes >= workingSetBudgetBytes || rowBytes == 0) {
            errorMessage = "working-set budget is too small for one source lease and the minimum camera-strip buffers; required at least "
                + std::to_string((fixedBytes + 1024 * 1024 - 1) / (1024 * 1024)) + " MB";
            return false;
        }
        const uint64_t affordableRows = (workingSetBudgetBytes - fixedBytes) / rowBytes;
        stripHeightLimit = static_cast<int>(std::max<uint64_t>(1, std::min<uint64_t>(256, affordableRows)));
    }
    TIFFSetField(tiff, TIFFTAG_ROWSPERSTRIP, stripHeightLimit);
    TIFFSetField(tiff, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT);

    bool ok = true;
    size_t stripCount = 0;
    NativeOverlapSeamStats seamStats;
    const bool applyOutputStretch = stretchParams != nullptr
        && stretchParams->valid
        && outputStretchStrength > 0.0;
    const bool requestedMetalFast = rendererRequested == "metal_fast";
    const bool requestedMetalQuality = rendererRequested == "metal_quality";
    const bool requestedMetal = requestedMetalFast || requestedMetalQuality;
    std::string actualRenderer = (rendererRequested == "cpu" || rendererRequested == "auto")
        ? "cpu"
        : profileWriter;
    std::string rendererFallbackReason;
    bool useMetal = false;
    if (requestedMetal) {
        if (lower_string(result.projection) != "equirectangular") {
            rendererFallbackReason = "Metal renderer currently supports equirectangular camera projection only";
        } else if (bitDepth != 16) {
            rendererFallbackReason = "Metal renderer currently supports 16-bit TIFF output only";
        } else {
            NativeMetalRuntimeStatus metalStatus = native_metal_runtime_status();
            if (!metalStatus.dylibLoaded || !metalStatus.deviceAvailable) {
                rendererFallbackReason = metalStatus.reason.empty()
                    ? "Metal renderer is unavailable"
                    : metalStatus.reason;
            } else if (requestedMetalQuality && !metalStatus.qualityAvailable) {
                rendererFallbackReason = "Metal quality renderer is not available";
            } else if (!metalStatus.fastAvailable) {
                rendererFallbackReason = "Metal fast renderer is not available";
            } else {
                useMetal = true;
                actualRenderer = requestedMetalQuality ? "metal_quality" : "metal_fast";
            }
        }
    }
    if (useMetal && streamingSource && workingSetBudgetBytes > 0) {
        uint64_t simultaneousSourceBytes = 0;
        for (const NativeImage &image : images) {
            simultaneousSourceBytes += native16_rgb_byte_count(image);
        }
        if (simultaneousSourceBytes >= workingSetBudgetBytes) {
            useMetal = false;
            actualRenderer = "cpu";
            rendererFallbackReason = "Metal API v5 requires simultaneous full-resolution source leases exceeding the working-set budget";
        }
    }
    for (int y0 = 0; y0 < bounds.height; y0 += stripHeightLimit) {
        if (active_native_operation_cancelled()) {
            errorMessage = "export cancelled";
            TIFFClose(tiff);
            return false;
        }
        const int stripHeight = std::min(stripHeightLimit, bounds.height - y0);
        if (useMetal) {
            std::vector<NativeImage> metalImages;
            std::vector<std::unique_ptr<NativeSourceLease>> metalLeases;
            const std::vector<NativeImage> *metalSources = &images;
            if (streamingSource) {
                metalImages.reserve(images.size());
                metalLeases.reserve(images.size());
                for (size_t idx = 0; idx < images.size(); ++idx) {
                    std::string sourceError;
                    NativeImage source = load_fullres_streaming_source(
                        streamingContext,
                        images[idx],
                        (*streamingPaths)[idx],
                        sourceError
                    );
                    if (source.status != "loaded") {
                        TIFFClose(tiff);
                        errorMessage = "failed to map streaming Metal source: " + sourceError;
                        return false;
                    }
                    const uint64_t leaseBytes = native_image_storage_bytes(source);
                    metalLeases.push_back(std::make_unique<NativeSourceLease>(workingSetStats, leaseBytes));
                    metalImages.push_back(std::move(source));
                }
                metalSources = &metalImages;
            }
            std::vector<uint16_t> metalStrip;
            std::vector<uint8_t> metalCoverage;
            std::string metalError;
            if (!render_camera_strip_with_metal(
                result,
                *metalSources,
                bounds,
                y0,
                stripHeight,
                offsetX,
                offsetY,
                projectionScale,
                requestedMetalQuality,
                metalStrip,
                metalCoverage,
                metalError
            )) {
                errorMessage = "Metal camera strip render failed: " + metalError;
                TIFFClose(tiff);
                return false;
            }
            if (applyOutputStretch) {
                std::vector<uint16_t> row(static_cast<size_t>(bounds.width) * 3);
                for (int localY = 0; localY < stripHeight; ++localY) {
                    const size_t rowOffset = static_cast<size_t>(localY) * static_cast<size_t>(bounds.width) * 3;
                    for (int x = 0; x < bounds.width * 3; ++x) {
                        const float linear = static_cast<float>(
                            static_cast<double>(metalStrip[rowOffset + static_cast<size_t>(x)]) / 65535.0
                        );
                        const float value = stretched_channel(linear, *stretchParams, outputStretchStrength);
                        row[static_cast<size_t>(x)] = static_cast<uint16_t>(std::llround(static_cast<double>(value) * 65535.0));
                    }
                    if (TIFFWriteScanline(tiff, row.data(), static_cast<uint32_t>(y0 + localY), 0) < 0) {
                        ok = false;
                        break;
                    }
                }
            } else {
                for (int localY = 0; localY < stripHeight; ++localY) {
                    const size_t rowOffset = static_cast<size_t>(localY) * static_cast<size_t>(bounds.width) * 3;
                    if (TIFFWriteScanline(tiff, metalStrip.data() + rowOffset, static_cast<uint32_t>(y0 + localY), 0) < 0) {
                        ok = false;
                        break;
                    }
                }
            }
            stripCount += 1;
            if (!ok) {
                break;
            }
            continue;
        }
        const int featherRadius = 30;
        const int stripMargin = std::max(8, featherRadius * 3);
        const int renderY0 = std::max(0, y0 - stripMargin);
        const int renderY1 = std::min(bounds.height, y0 + stripHeight + stripMargin);
        const int renderHeight = std::max(1, renderY1 - renderY0);
        const int cropTop = y0 - renderY0;
        cv::Mat numerator(renderHeight, bounds.width, CV_32FC3, cv::Scalar(0.0f, 0.0f, 0.0f));
        cv::Mat denominator(renderHeight, bounds.width, CV_32FC1, cv::Scalar(0.0f));
        NativeStreamingOverlapStatsAccumulator overlapAccumulator;
        for (size_t idx = 0; idx < images.size(); ++idx) {
            if (active_native_operation_cancelled()) {
                TIFFClose(tiff);
                errorMessage = "export cancelled";
                return false;
            }
            NativeImage streamedImage;
            const NativeImage *sourceImage = &images[idx];
            std::unique_ptr<NativeSourceLease> sourceLease;
            if (streamingSource) {
                std::string sourceError;
                streamedImage = load_fullres_streaming_source(
                    streamingContext,
                    images[idx],
                    (*streamingPaths)[idx],
                    sourceError
                );
                if (streamedImage.status != "loaded") {
                    TIFFClose(tiff);
                    errorMessage = "failed to load streaming full-resolution source: " + sourceError;
                    return false;
                }
                sourceLease = std::make_unique<NativeSourceLease>(
                    workingSetStats,
                    native_image_storage_bytes(streamedImage)
                );
                sourceImage = &streamedImage;
            }
            cv::Mat mapX;
            cv::Mat mapY;
            cv::Mat mask;
            native_camera_build_warp_maps_strip(
                *sourceImage,
                result.cameraParams[idx],
                result.projection,
                bounds.width,
                renderY0,
                renderHeight,
                offsetX,
                offsetY,
                projectionScale,
                mapX,
                mapY,
                mask,
                result.localWarpModel.images.size() == images.size()
                    ? &result.localWarpModel.images[idx]
                    : nullptr
            );
            cv::Mat sourceForRemap = image_to_rgb_remap_mat(*sourceImage);
            if (sourceForRemap.empty()) {
                TIFFClose(tiff);
                errorMessage = "streaming full-resolution source has no RGB pixels";
                return false;
            }
            cv::Mat warped;
            cv::remap(
                sourceForRemap,
                warped,
                mapX,
                mapY,
                cv::INTER_LINEAR,
                cv::BORDER_CONSTANT,
                cv::Scalar(0.0f, 0.0f, 0.0f)
            );
            if (warped.type() == CV_16UC3) {
                warped.convertTo(warped, CV_32FC3, 1.0 / 65535.0);
            }
            cv::Mat weight = native_feather_weight_from_mask(mask);
            std::vector<cv::Mat> weightChannels(3, weight);
            cv::Mat weight3;
            cv::merge(weightChannels, weight3);
            numerator += warped.mul(weight3);
            denominator += weight;
            overlapAccumulator.append(warped, mask, seamStats);
        }
        cv::Mat safeDenominator;
        cv::max(denominator, 1e-8, safeDenominator);
        std::vector<cv::Mat> denominatorChannels(3, safeDenominator);
        cv::Mat denominator3;
        cv::merge(denominatorChannels, denominator3);
        cv::Mat extendedStrip = numerator / denominator3;
        cv::min(extendedStrip, 1.0, extendedStrip);
        cv::max(extendedStrip, 0.0, extendedStrip);
        cv::Mat strip = extendedStrip(cv::Rect(0, cropTop, bounds.width, stripHeight)).clone();
        if (bitDepth == 16) {
            std::vector<uint16_t> row(static_cast<size_t>(bounds.width) * 3);
            for (int localY = 0; localY < strip.rows; ++localY) {
                const float *src = strip.ptr<float>(localY);
                for (int x = 0; x < bounds.width * 3; ++x) {
                    const float value = applyOutputStretch
                        ? stretched_channel(src[x], *stretchParams, outputStretchStrength)
                        : std::min(1.0f, std::max(0.0f, src[x]));
                    row[static_cast<size_t>(x)] = static_cast<uint16_t>(std::llround(static_cast<double>(value) * 65535.0));
                }
                if (TIFFWriteScanline(tiff, row.data(), static_cast<uint32_t>(y0 + localY), 0) < 0) {
                    ok = false;
                    break;
                }
            }
        } else {
            std::vector<uint8_t> row(static_cast<size_t>(bounds.width) * 3);
            for (int localY = 0; localY < strip.rows; ++localY) {
                const float *src = strip.ptr<float>(localY);
                for (int x = 0; x < bounds.width * 3; ++x) {
                    const float value = applyOutputStretch
                        ? stretched_channel(src[x], *stretchParams, outputStretchStrength)
                        : std::min(1.0f, std::max(0.0f, src[x]));
                    row[static_cast<size_t>(x)] = static_cast<uint8_t>(std::llround(static_cast<double>(value) * 255.0));
                }
                if (TIFFWriteScanline(tiff, row.data(), static_cast<uint32_t>(y0 + localY), 0) < 0) {
                    ok = false;
                    break;
                }
            }
        }
        stripCount += 1;
        if (!ok) {
            break;
        }
    }
    TIFFClose(tiff);
    if (!ok) {
        errorMessage = "failed while writing camera strip TIFF scanlines";
        return false;
    }
    if (writtenBounds) {
        *writtenBounds = bounds;
    }
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double peakMemoryMB = current_peak_memory_mb();
    std::ostringstream profile;
    profile << "{";
    profile << "\"mode\":\"" << json_escape(profileMode) << "\",";
    profile << "\"renderer_requested\":\"" << json_escape(rendererRequested) << "\",";
    profile << "\"renderer_used\":\"" << json_escape(actualRenderer) << "\",";
    const bool rendererFallback = requestedMetal && rendererRequested != actualRenderer;
    const bool cpuFallback = rendererRequested.find("metal") != std::string::npos && rendererFallback;
    profile << "\"renderer_fallback\":" << bool_json(rendererFallback) << ",";
    profile << "\"cpu_fallback\":" << bool_json(cpuFallback) << ",";
    if (rendererFallback) {
        std::string fallbackReason = "requested renderer '" + rendererRequested + "' used '" + actualRenderer + "'";
        if (cpuFallback) {
            fallbackReason = rendererFallbackReason.empty()
                ? "Metal renderer is unavailable; using CPU camera strips"
                : rendererFallbackReason + "; using CPU camera strips";
        }
        profile << "\"renderer_fallback_reason\":\"" << json_escape(fallbackReason) << "\",";
    }
    profile << "\"writer\":\"" << json_escape(profileWriter) << "\",";
    profile << "\"source_streaming\":" << bool_json(streamingSource) << ",";
    profile << "\"geometry_source\":\"" << json_escape(result.geometry) << "\",";
    profile << "\"quality_gate_passed\":" << bool_json(result.cameraModelReport.qualityGatePassed) << ",";
    if (!result.starProjectionAlignmentJson.empty()) {
        profile << "\"star_projection_alignment\":" << result.starProjectionAlignmentJson << ",";
    }
    profile << "\"bit_depth\":" << bitDepth << ",";
    profile << "\"width\":" << bounds.width << ",";
    profile << "\"height\":" << bounds.height << ",";
    profile << "\"strips\":" << stripCount << ",";
    profile << "\"rows_per_strip\":" << stripHeightLimit << ",";
    profile << "\"overlap_pixels\":" << seamStats.overlapPixels << ",";
    profile << "\"overlap_metric_method\":\"streaming_composite\",";
    profile << "\"mean_overlap_absdiff\":" << seamStats.meanAbsDiff() << ",";
    profile << "\"max_overlap_absdiff\":" << seamStats.maxAbsDiff << ",";
    profile << "\"full_resolution_source\":" << bool_json(fullResolutionSource) << ",";
    profile << "\"mean_camera_scale\":" << meanCameraScale << ",";
    profile << "\"max_camera_scale\":" << maxCameraScale << ",";
    profile << "\"preview_stretch_applied\":" << bool_json(applyOutputStretch) << ",";
    profile << "\"preview_stretch_strength\":" << outputStretchStrength << ",";
    if (stretchParams) {
        profile << "\"preview_stretch_black\":" << number_json(stretchParams->black) << ",";
        profile << "\"preview_stretch_white\":" << number_json(stretchParams->white) << ",";
        profile << "\"preview_stretch_gamma\":" << number_json(stretchParams->gamma) << ",";
    }
    profile << "\"total_seconds\":" << elapsed << ",";
    append_peak_memory_json(profile, peakMemoryMB);
    profile << "}";
    profileJson = profile.str();
    return true;
#else
    (void)result;
    (void)images;
    (void)outputPath;
    (void)bitDepth;
    (void)maxOutputPixels;
    (void)maxOutputSide;
    (void)profileMode;
    (void)rendererRequested;
    (void)profileWriter;
    (void)fullResolutionSource;
    (void)meanCameraScale;
    (void)maxCameraScale;
    (void)stretchParams;
    (void)outputStretchStrength;
    (void)writtenBounds;
    (void)profileJson;
    (void)streamingPaths;
    (void)streamingContext;
    (void)workingSetStats;
    (void)workingSetBudgetBytes;
    errorMessage = "libtiff or OpenCV headers are not available";
    return false;
#endif
}

static bool result_has_camera_projection_geometry(const NativeResult &result) {
    return result.previewStatus == "camera_projection_preview"
        && result.geometry == "camera"
        && result.cameraParams.size() == result.imageHandles.size()
        && !result.cameraParams.empty();
}

char *myptgui_export_full_resolution(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    if (!context) {
        return copy_json(error_json("exportFullResolution", "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json("exportFullResolution");
    }
    NativeWorkingSetStats workingSetStats;
    const int requestedWorkingSetBudgetMB = std::max(0, request.integer("workingSetBudgetMB", 0));
    const uint64_t effectiveWorkingSetBudgetBytes = native_effective_working_set_budget_bytes(requestedWorkingSetBudgetMB);
    workingSetStats.requestedBudgetBytes = static_cast<uint64_t>(requestedWorkingSetBudgetMB) * 1024ULL * 1024ULL;
    workingSetStats.effectiveBudgetBytes = effectiveWorkingSetBudgetBytes;
    const std::string handle = request.string("resultHandle");
    auto found = context->results.find(handle);
    if (found == context->results.end()) {
        return copy_json(error_json("exportFullResolution", "Unknown result handle"));
    }
    const std::string backend = lower_string(request.string("rendererBackend", "auto"));
    if (backend == "preview_tiff_diagnostic") {
        NativeResult exported = found->second;
        const std::string outputPath = request.string("outputPath");
        if (!is_tiff_path(outputPath)) {
            return copy_json(error_json("exportFullResolution", "Production export currently supports TIFF output only."));
        }
        const int bitDepth = std::max(8, request.integer("bitDepth", 16));
        std::string profileJson;
        std::string errorMessage;
        emit_progress(progress, userData, "Writing diagnostic TIFF", 0.1);
        if (!write_preview_tiff_diagnostic(exported, outputPath, bitDepth, profileJson, errorMessage)) {
            if (operationScope.cancelled()) {
                return cancelled_operation_json("exportFullResolution");
            }
            return copy_json(error_json("exportFullResolution", "Diagnostic TIFF export failed: " + errorMessage));
        }
        if (operationScope.cancelled()) {
            return cancelled_operation_json("exportFullResolution");
        }
        emit_progress(progress, userData, "Diagnostic TIFF written", 1.0);
        append_working_set_profile_json(profileJson, workingSetStats);
        exported.exportProfileJson = profileJson;
        return copy_json(result_json(
            context,
            exported,
            "exportFullResolution",
            true,
            "Preview-resolution TIFF diagnostic export completed."
        ));
    }
    if (backend == "preview_camera_strip_tiff_diagnostic") {
        NativeResult exported = found->second;
        if (!result_has_camera_projection_geometry(exported)) {
            return copy_json(error_json("exportFullResolution", "camera projection preview required before camera strip export"));
        }
        const std::string outputPath = request.string("outputPath");
        if (!is_tiff_path(outputPath)) {
            return copy_json(error_json("exportFullResolution", "Export currently supports TIFF output only."));
        }
        const int bitDepth = std::max(8, request.integer("bitDepth", 16));
        std::vector<NativeImage> images;
        images.reserve(exported.imageHandles.size());
        for (const std::string &imageHandle : exported.imageHandles) {
            auto imageFound = context->images.find(imageHandle);
            if (imageFound == context->images.end()) {
                return copy_json(error_json("exportFullResolution", "Camera-strip diagnostic TIFF export failed: missing source image for result"));
            }
            images.push_back(imageFound->second);
        }
        std::string profileJson;
        std::string errorMessage;
        emit_progress(progress, userData, "Writing camera-strip diagnostic TIFF", 0.1);
        NativeOutputBoundsReport writtenBounds;
        if (!write_camera_strip_tiff_diagnostic(
            exported,
            images,
            outputPath,
            bitDepth,
            0,
            0,
            "preview_camera_strip_tiff_diagnostic",
            backend,
            "libtiff_camera_strips",
            false,
            1.0,
            1.0,
            nullptr,
            0.0,
            &writtenBounds,
            profileJson,
            errorMessage,
            nullptr,
            nullptr,
            &workingSetStats,
            effectiveWorkingSetBudgetBytes
        )) {
            if (operationScope.cancelled()) {
                return cancelled_operation_json("exportFullResolution");
            }
            return copy_json(error_json("exportFullResolution", "Camera-strip diagnostic TIFF export failed: " + errorMessage));
        }
        if (operationScope.cancelled()) {
            return cancelled_operation_json("exportFullResolution");
        }
        emit_progress(progress, userData, "Camera-strip diagnostic TIFF written", 1.0);
        append_working_set_profile_json(profileJson, workingSetStats);
        exported.outputBounds = writtenBounds;
        exported.width = writtenBounds.width;
        exported.height = writtenBounds.height;
        exported.bitDepth = bitDepth;
        exported.exportProfileJson = profileJson;
        return copy_json(result_json(
            context,
            exported,
            "exportFullResolution",
            true,
            "Preview-geometry strip TIFF diagnostic export completed."
        ));
    }
    const bool productionFullresBackend = backend == "auto"
        || backend == "cpu"
        || backend == "metal_quality"
        || backend == "metal_fast";
    if (backend == "fullres_camera_strip_tiff_diagnostic" || productionFullresBackend) {
        NativeResult exported = found->second;
        if (!result_has_camera_projection_geometry(exported)) {
            return copy_json(error_json("exportFullResolution", "camera projection preview required before camera strip export"));
        }
        const std::string outputPath = request.string("outputPath");
        if (!is_tiff_path(outputPath)) {
            return copy_json(error_json("exportFullResolution", "Full-resolution export currently supports TIFF output only."));
        }
        const std::string temporaryOutputPath = temporary_export_path(outputPath);
        std::remove(temporaryOutputPath.c_str());
        const int bitDepth = std::max(8, request.integer("bitDepth", 16));
        const int maxOutputPixels = request.integer("maxOutputPixels", 0);
        const int maxOutputSide = request.integer("maxOutputSide", 0);
        const bool applyPreviewStretch = request.boolean("applyPreviewStretch", false);
        const double outputStretchStrength = applyPreviewStretch
            ? std::max(0.0, request.number("stretchStrength", 1.0))
            : 0.0;
        StretchParams outputStretchParams;
        if (applyPreviewStretch && outputStretchStrength > 0.0) {
            outputStretchParams = compute_stretch_params(
                exported.panoramaPixels,
                request.number("stretchBlackPercentile", 0.5),
                request.number("stretchWhitePercentile", 99.7),
                request.number("stretchGamma", 0.45)
            );
        }
        const StretchParams *outputStretchPtr = outputStretchParams.valid ? &outputStretchParams : nullptr;
        const std::string profileMode = productionFullresBackend
            ? "production_fullres_camera_strip_tiff"
            : "fullres_camera_strip_tiff_diagnostic";
        const std::string profileWriter = productionFullresBackend
            ? "libtiff_fullres_camera_strips"
            : "libtiff_fullres_camera_strips";

        std::vector<NativeImage> previewImages;
        previewImages.reserve(exported.imageHandles.size());
        for (const std::string &imageHandle : exported.imageHandles) {
            auto imageFound = context->images.find(imageHandle);
            if (imageFound == context->images.end()) {
                return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed: missing preview source image for result"));
            }
            NativeImage metadata;
            metadata.handle = imageFound->second.handle;
            metadata.path = imageFound->second.path;
            metadata.width = imageFound->second.width;
            metadata.height = imageFound->second.height;
            metadata.originalWidth = imageFound->second.originalWidth;
            metadata.originalHeight = imageFound->second.originalHeight;
            metadata.channels = imageFound->second.channels;
            metadata.bitDepth = imageFound->second.bitDepth;
            metadata.status = imageFound->second.status;
            previewImages.push_back(std::move(metadata));
            // Preview pixels are rehydrated lazily if the user returns to a
            // handle-based preview or projection drag.  Free them here so a
            // full-resolution strip can fit alongside a single RAW decode.
            imageFound->second.pixels.clear();
            imageFound->second.pixels.shrink_to_fit();
        }
        if (exported.paths.size() != previewImages.size()) {
            return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed: result paths do not match preview images"));
        }

        emit_progress(progress, userData, "Reloading full-resolution export images", 0.05);
        std::vector<NativeImage> fullImageMetadata;
        fullImageMetadata.reserve(exported.paths.size());
        TemporaryNative16SpoolFiles raw16Spools;
        bool hasNative16Spools = false;
        auto cancelledFullresResponse = [&](const std::string &stage) -> char * {
            std::remove(temporaryOutputPath.c_str());
            const bool cleanupSucceeded = raw16Spools.cleanup();
            workingSetStats.cleanupOutcome = hasNative16Spools
                ? (cleanupSucceeded ? "completed" : "failed")
                : "not_required";
            std::string cancellationProfile = "{\"mode\":\"cancelled_fullres_camera_strip\",";
            cancellationProfile += "\"renderer_requested\":\"" + json_escape(backend) + "\",";
            cancellationProfile += "\"renderer_used\":\"cancelled\",";
            cancellationProfile += "\"cancelled\":true,";
            cancellationProfile += "\"cancelled_stage\":\"" + json_escape(stage) + "\"}";
            append_working_set_profile_json(cancellationProfile, workingSetStats);
            exported.exportProfileJson = cancellationProfile;
            return copy_json(result_json(
                context,
                exported,
                "exportFullResolution",
                false,
                "Operation cancelled during " + stage + "."
            ));
        };
        for (size_t i = 0; i < exported.paths.size(); ++i) {
            if (operationScope.cancelled()) {
                return cancelledFullresResponse("source preparation");
            }
            emit_progress(
                progress,
                userData,
                "Preparing full-resolution export image",
                0.05 + 0.25 * (static_cast<double>(i) / std::max<size_t>(exported.paths.size(), 1))
            );
            const bool rawSource = is_raw_extension(exported.paths[i]);
            const int sourceWidth = std::max(previewImages[i].originalWidth, previewImages[i].width);
            const int sourceHeight = std::max(previewImages[i].originalHeight, previewImages[i].height);
            const uint64_t estimatedDecodeBytes = static_cast<uint64_t>(std::max(sourceWidth, 0))
                * static_cast<uint64_t>(std::max(sourceHeight, 0))
                * 3ULL
                * (rawSource ? sizeof(uint16_t) : sizeof(float));
            if (estimatedDecodeBytes > effectiveWorkingSetBudgetBytes) {
                return copy_json(error_json(
                    "exportFullResolution",
                    "Full-resolution source decode exceeds the working-set budget; source requires approximately "
                        + std::to_string((estimatedDecodeBytes + 1024 * 1024 - 1) / (1024 * 1024)) + " MB"
                ));
            }
            NativeImage image = load_image_with_native_backends(
                context,
                exported.paths[i],
                0,
                false,
                rawSource
            );
            if (image.status != "loaded") {
                return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed while loading source: " + image.unsupportedReason));
            }
            const std::string spoolPath = temporaryOutputPath
                + ".source-" + std::to_string(i) + ".rgb16";
            std::string spoolError;
            if (!write_native16_spool(image, spoolPath, spoolError)) {
                return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed while spooling source: " + spoolError));
            }
            raw16Spools.add(spoolPath);
            hasNative16Spools = true;
            workingSetStats.spoolBytes += static_cast<uint64_t>(std::max(image.width, 0))
                * static_cast<uint64_t>(std::max(image.height, 0))
                * static_cast<uint64_t>(std::max(image.channels, 0))
                * sizeof(uint16_t);
            workingSetStats.sample();
            // Keep only dimensions and an on-disk native16 source descriptor
            // for projection planning.  Each TIFF strip maps one source file
            // at a time, so no full-resolution float32 frame is retained.
            image.pixels.clear();
            image.pixels.shrink_to_fit();
            fullImageMetadata.push_back(std::move(image));
        }

        double meanCameraScale = 1.0;
        double maxCameraScale = 1.0;
        std::string scaleFailure;
        std::vector<NativeCameraParams> scaledCameras = scale_camera_params_for_images(
            exported.cameraParams,
            previewImages,
            fullImageMetadata,
            meanCameraScale,
            maxCameraScale,
            scaleFailure
        );
        if (!scaleFailure.empty() || scaledCameras.empty()) {
            return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed: " + scaleFailure));
        }
        exported.cameraParams = scaledCameras;

        std::string profileJson;
        std::string errorMessage;
        NativeOutputBoundsReport writtenBounds;
        emit_progress(progress, userData, "Writing full-resolution camera-strip TIFF", 0.35);
        if (!write_camera_strip_tiff_diagnostic(
            exported,
            fullImageMetadata,
            temporaryOutputPath,
            bitDepth,
            maxOutputPixels,
            maxOutputSide,
            profileMode,
            backend,
            profileWriter,
            true,
            meanCameraScale,
            maxCameraScale,
            outputStretchPtr,
            outputStretchStrength,
            &writtenBounds,
            profileJson,
            errorMessage,
            &exported.paths,
            context,
            &workingSetStats,
            effectiveWorkingSetBudgetBytes
        )) {
            std::remove(temporaryOutputPath.c_str());
            if (operationScope.cancelled()) {
                return cancelledFullresResponse("camera-strip rendering");
            }
            return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed: " + errorMessage));
        }
        const bool cleanupSucceeded = raw16Spools.cleanup();
        workingSetStats.cleanupOutcome = hasNative16Spools
            ? (cleanupSucceeded ? "completed" : "failed")
            : "not_required";
        append_working_set_profile_json(profileJson, workingSetStats);
        if (operationScope.cancelled()) {
            return cancelledFullresResponse("output publication");
        }
        if (!commit_temporary_export(temporaryOutputPath, outputPath, errorMessage)) {
            return copy_json(error_json("exportFullResolution", "Full-resolution camera-strip TIFF export failed: " + errorMessage));
        }
        emit_progress(progress, userData, "Full-resolution camera-strip TIFF written", 1.0);
        exported.outputBounds = writtenBounds;
        exported.width = writtenBounds.width;
        exported.height = writtenBounds.height;
        exported.bitDepth = bitDepth;
        exported.exportProfileJson = profileJson;
        const std::string rendererUsed = panolume::JSONRequest(profileJson).string(
            "renderer_used",
            "cpu"
        );
        const std::string completionMessage = productionFullresBackend
            ? (rendererUsed == "metal_quality"
                ? "Production full-resolution TIFF export completed with streaming Metal Quality camera strips."
                : "Production full-resolution TIFF export completed with streaming CPU camera strips.")
            : "Full-resolution camera-strip TIFF diagnostic export completed.";
        return copy_json(result_json(
            context,
            exported,
            "exportFullResolution",
            true,
            completionMessage
        ));
    }
    emit_progress(progress, userData, "Export parity gate evaluated", 1.0);
    return copy_json(error_json(
        "exportFullResolution",
        "Unsupported export renderer backend: " + backend
    ));
}

MyPTGuiPixelBuffer myptgui_copy_image_rgba(
    MyPTGuiNativeContext *context,
    const char *imageHandle,
    const char *requestJson
) {
    MyPTGuiPixelBuffer empty = {nullptr, 0, 0, 0, 0};
    if (!context || !imageHandle) {
        return empty;
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return empty;
    }
    auto found = context->images.find(imageHandle);
    if (found == context->images.end()) {
        return empty;
    }
    const NativeImage &image = found->second;
    if (image.status != "loaded"
        || image.width <= 0
        || image.height <= 0
        || (image.pixels.empty() && image.native16Pixels == nullptr)) {
        return empty;
    }

    const bool displayStretch = request.boolean("displayStretch", true);
    const double strength = request.number("stretchStrength", 1.0);
    const double blackPercentile = request.number("stretchBlackPercentile", 0.5);
    const double whitePercentile = request.number("stretchWhitePercentile", 99.7);
    const double gamma = request.number("stretchGamma", 0.45);
    const StretchParams params = displayStretch
        ? compute_stretch_params(image, blackPercentile, whitePercentile, gamma)
        : StretchParams();

    MyPTGuiPixelBuffer buffer;
    buffer.width = image.width;
    buffer.height = image.height;
    buffer.bytesPerRow = image.width * 4;
    buffer.byteCount = static_cast<size_t>(buffer.bytesPerRow) * static_cast<size_t>(buffer.height);
    buffer.data = static_cast<unsigned char *>(std::malloc(buffer.byteCount));
    if (!buffer.data) {
        return empty;
    }

    const bool native16 = image.native16Pixels != nullptr;
    constexpr float native16Scale = 1.0f / 65535.0f;
    for (int y = 0; y < image.height; ++y) {
        if (operationScope.cancelled()) {
            std::free(buffer.data);
            return empty;
        }
        for (int x = 0; x < image.width; ++x) {
            const size_t pixel = static_cast<size_t>(y) * static_cast<size_t>(image.width) + static_cast<size_t>(x);
            const size_t src = pixel * 3;
            const size_t dst = static_cast<size_t>(y) * static_cast<size_t>(buffer.bytesPerRow) + static_cast<size_t>(x) * 4;
            const float linearR = native16
                ? static_cast<float>(image.native16Pixels[src + 0]) * native16Scale
                : image.pixels[src + 0];
            const float linearG = native16
                ? static_cast<float>(image.native16Pixels[src + 1]) * native16Scale
                : image.pixels[src + 1];
            const float linearB = native16
                ? static_cast<float>(image.native16Pixels[src + 2]) * native16Scale
                : image.pixels[src + 2];
            const float r = displayStretch ? stretched_channel(linearR, params, strength) : std::min(1.0f, std::max(0.0f, linearR));
            const float g = displayStretch ? stretched_channel(linearG, params, strength) : std::min(1.0f, std::max(0.0f, linearG));
            const float b = displayStretch ? stretched_channel(linearB, params, strength) : std::min(1.0f, std::max(0.0f, linearB));
            buffer.data[dst + 0] = static_cast<unsigned char>(std::llround(r * 255.0f));
            buffer.data[dst + 1] = static_cast<unsigned char>(std::llround(g * 255.0f));
            buffer.data[dst + 2] = static_cast<unsigned char>(std::llround(b * 255.0f));
            buffer.data[dst + 3] = 255;
        }
    }
    return buffer;
}

void myptgui_release_image(
    MyPTGuiNativeContext *context,
    const char *imageHandle
) {
    if (!context || !imageHandle) {
        return;
    }
    std::lock_guard<std::mutex> operationLock(context->operationMutex);
    context->images.erase(imageHandle);
}

MyPTGuiFloatPixelBuffer myptgui_copy_image_linear_rgb(
    MyPTGuiNativeContext *context,
    const char *imageHandle
) {
    MyPTGuiFloatPixelBuffer empty = {nullptr, 0, 0, 0, 0};
    if (!context || !imageHandle) {
        return empty;
    }
    std::lock_guard<std::mutex> operationLock(context->operationMutex);
    auto found = context->images.find(imageHandle);
    if (found == context->images.end()) {
        return empty;
    }
    const NativeImage &image = found->second;
    if (image.status != "loaded" || image.width <= 0 || image.height <= 0 || image.channels != 3 || image.pixels.empty()) {
        return empty;
    }
    const size_t expected = static_cast<size_t>(image.width) * static_cast<size_t>(image.height) * 3;
    if (image.pixels.size() != expected) {
        return empty;
    }
    MyPTGuiFloatPixelBuffer buffer;
    buffer.width = image.width;
    buffer.height = image.height;
    buffer.channels = 3;
    buffer.valueCount = expected;
    buffer.data = static_cast<float *>(std::malloc(expected * sizeof(float)));
    if (!buffer.data) {
        return empty;
    }
    std::memcpy(buffer.data, image.pixels.data(), expected * sizeof(float));
    return buffer;
}

char *myptgui_decode_raw_linear_rgb16_to_file(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    const char *operation = "decodeRawLinearRGB16ToFile";
    if (!context) {
        return copy_json(error_json(operation, "Image-processing context is unavailable"));
    }
    const panolume::EngineRequest request(requestJson);
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    const std::string inputPath = request.string("path");
    const std::string outputPath = request.string("outputPath");
    const bool halfSize = request.boolean("halfSize", false);
    if (inputPath.empty() || outputPath.empty()) {
        return copy_json(error_json(operation, "RAW decode spool requires path and outputPath"));
    }
    if (!is_raw_extension(inputPath)) {
        return copy_json(error_json(operation, "RAW decode spool only accepts RAW input files"));
    }
    emit_progress(progress, userData, "Decoding linear RGB16 RAW", 0.10);
    NativeImage image = load_image_with_native_backends(context, inputPath, 0, halfSize, true);
    if (image.status != "loaded") {
        return copy_json(error_json(operation, image.unsupportedReason.empty()
            ? "RAW decode did not return a loaded image"
            : image.unsupportedReason));
    }
    if (operationScope.cancelled()) {
        return cancelled_operation_json(operation);
    }
    emit_progress(progress, userData, "Writing linear RGB16 spool", 0.75);
    std::string spoolError;
    if (!write_native16_spool(image, outputPath, spoolError)) {
        return copy_json(error_json(operation, spoolError));
    }
    if (operationScope.cancelled()) {
        std::remove(outputPath.c_str());
        return cancelled_operation_json(operation);
    }
    emit_progress(progress, userData, "Linear RGB16 spool written", 1.0);
    std::ostringstream out;
    out << "{"
        << "\"success\":true,"
        << "\"operation\":\"" << operation << "\","
        << "\"message\":\"Linear RGB16 RAW spool completed.\","
        << "\"path\":\"" << json_escape(outputPath) << "\","
        << "\"width\":" << image.width << ","
        << "\"height\":" << image.height << ","
        << "\"channels\":3,"
        << "\"bit_depth\":16,"
        << "\"sample_type\":\"uint16_linear_rgb_spool\","
        << "\"half_size\":" << bool_json(halfSize)
        << "}";
    return copy_json(out.str());
}

static MyPTGuiPixelBuffer pixel_buffer_from_result(
    NativeResult &result,
    const char *requestJson
) {
    MyPTGuiPixelBuffer empty = {nullptr, 0, 0, 0, 0};
    if (result.width <= 0 || result.height <= 0 || result.panoramaPixels.empty()) {
        return empty;
    }

    const panolume::EngineRequest request(requestJson);
    const bool displayStretch = request.boolean("displayStretch", true);
    const double strength = request.number("stretchStrength", 1.0);
    const double blackPercentile = request.number("stretchBlackPercentile", 0.5);
    const double whitePercentile = request.number("stretchWhitePercentile", 99.7);
    const double gamma = request.number("stretchGamma", 0.45);
    StretchParams params;
    if (displayStretch) {
        NativeDisplayStretchCache &cache = result.displayStretchCache;
        const bool cacheMatches = cache.computed
            && std::abs(cache.blackPercentile - blackPercentile) <= 1e-9
            && std::abs(cache.whitePercentile - whitePercentile) <= 1e-9
            && std::abs(cache.gamma - gamma) <= 1e-9;
        if (!cacheMatches) {
            cache.computed = true;
            cache.blackPercentile = blackPercentile;
            cache.whitePercentile = whitePercentile;
            cache.gamma = gamma;
            cache.params = compute_stretch_params(
                result.panoramaPixels,
                blackPercentile,
                whitePercentile,
                gamma
            );
        }
        params = cache.params;
    }

    MyPTGuiPixelBuffer buffer;
    buffer.width = result.width;
    buffer.height = result.height;
    buffer.bytesPerRow = result.width * 4;
    buffer.byteCount = static_cast<size_t>(buffer.bytesPerRow) * static_cast<size_t>(buffer.height);
    buffer.data = static_cast<unsigned char *>(std::malloc(buffer.byteCount));
    if (!buffer.data) {
        return empty;
    }

    const size_t expectedCoverage = static_cast<size_t>(result.width) * static_cast<size_t>(result.height);
    const bool hasCoverage = result.panoramaCoverage.size() == expectedCoverage;
    for (int y = 0; y < result.height; ++y) {
        for (int x = 0; x < result.width; ++x) {
            const size_t pixel = static_cast<size_t>(y) * static_cast<size_t>(result.width) + static_cast<size_t>(x);
            const size_t src = pixel * 3;
            const size_t dst = static_cast<size_t>(y) * static_cast<size_t>(buffer.bytesPerRow) + static_cast<size_t>(x) * 4;
            const unsigned char alpha = hasCoverage ? result.panoramaCoverage[pixel] : 255;
            if (alpha == 0) {
                buffer.data[dst + 0] = 0;
                buffer.data[dst + 1] = 0;
                buffer.data[dst + 2] = 0;
                buffer.data[dst + 3] = 0;
                continue;
            }
            const float r = displayStretch ? stretched_channel(result.panoramaPixels[src + 0], params, strength) : std::min(1.0f, std::max(0.0f, result.panoramaPixels[src + 0]));
            const float g = displayStretch ? stretched_channel(result.panoramaPixels[src + 1], params, strength) : std::min(1.0f, std::max(0.0f, result.panoramaPixels[src + 1]));
            const float b = displayStretch ? stretched_channel(result.panoramaPixels[src + 2], params, strength) : std::min(1.0f, std::max(0.0f, result.panoramaPixels[src + 2]));
            buffer.data[dst + 0] = static_cast<unsigned char>(std::llround(r * 255.0f));
            buffer.data[dst + 1] = static_cast<unsigned char>(std::llround(g * 255.0f));
            buffer.data[dst + 2] = static_cast<unsigned char>(std::llround(b * 255.0f));
            buffer.data[dst + 3] = alpha;
        }
    }
    return buffer;
}

MyPTGuiPixelBuffer myptgui_copy_result_rgba(
    MyPTGuiNativeContext *context,
    const char *resultHandle,
    const char *requestJson
) {
    MyPTGuiPixelBuffer empty = {nullptr, 0, 0, 0, 0};
    if (!context || !resultHandle) {
        return empty;
    }
    std::lock_guard<std::mutex> operationLock(context->operationMutex);
    auto found = context->results.find(resultHandle);
    if (found == context->results.end()) {
        return empty;
    }
    return pixel_buffer_from_result(found->second, requestJson);
}

MyPTGuiPixelBuffer myptgui_render_projection_drag_preview_rgba(
    MyPTGuiNativeContext *context,
    const char *requestJson,
    MyPTGuiProgressCallback progress,
    void *userData
) {
    MyPTGuiPixelBuffer empty = {nullptr, 0, 0, 0, 0};
    if (!context) {
        return empty;
    }
    const panolume::EngineRequest request(requestJson);
    // Allocate before entering the serialized lane so this enqueued frame can
    // invalidate an older Metal/OpenCV frame that is still rendering.
    const unsigned long long requestVersion = context->projectionPreviewVersion.fetch_add(1) + 1;
    NativeOperationScope operationScope(context, request);
    if (operationScope.cancelled()) {
        return empty;
    }
    const std::string handle = request.string("resultHandle");
    auto found = context->results.find(handle);
    if (found == context->results.end()) {
        return empty;
    }
    NativeResult preview = copy_result_without_panorama_pixels(found->second);
    preview.blendMode = "fast";
    preview.previewRendererRequested = "metal_fast";
#if MYPTGUI_HAS_OPENCV_HEADERS
    if (!dependency_available("opencv")) {
        return empty;
    }
    const size_t imageCount = preview.imageHandles.size();
    const DragPreviewLimits limits = drag_preview_limits(imageCount);
    const int dragMaxSide = capped_drag_request_limit(
        request,
        "previewMaxSide",
        limits.sourceMaxSide
    );
    std::vector<NativeImage> images;
    const std::string cacheKey = found->second.handle + ":drag:" + std::to_string(dragMaxSide);
    std::vector<NativeImage> renderImages = cached_resized_images_from_handles(context, cacheKey, preview.imageHandles, dragMaxSide, images);
    if (renderImages.size() != preview.imageHandles.size() || renderImages.empty()) {
        return empty;
    }
    std::string scaleFailure;
    if (preview.baseCameraParams.empty() && !found->second.cameraParams.empty()) {
        preview.baseCameraParams = found->second.cameraParams;
    }
    if (!preview.baseCameraParams.empty()) {
        preview.cameraParams = preview.baseCameraParams;
    }
    std::vector<NativeCameraParams> scaledCameras = cached_drag_preview_camera_params(
        context,
        cacheKey,
        preview.cameraParams,
        images,
        renderImages,
        scaleFailure
    );
    if (!scaleFailure.empty() || scaledCameras.empty()) {
        return empty;
    }
    preview.cameraParams = std::move(scaledCameras);
    const double pitchDegrees = request.number("pitchDegrees", 0.0);
    const double yawDegrees = request.number("yawDegrees", 0.0);
    const double rollDegrees = request.number("rollDegrees", 0.0);
    apply_pose_adjustment_to_cameras(preview.cameraParams, pitchDegrees, yawDegrees, rollDegrees);
    preview.hasProjectionAdjustment = true;
    preview.projectionAdjustmentDegrees = {pitchDegrees, yawDegrees, rollDegrees};
    preview.outputBounds.maxOutputPixels = capped_drag_request_limit(
        request,
        "maxOutputPixels",
        limits.maxOutputPixels
    );
    preview.outputBounds.maxOutputSide = capped_drag_request_limit(
        request,
        "maxOutputSide",
        limits.maxOutputSide
    );

    std::string failureReason;
    const std::string projection = request.string("projection", preview.projection);
    if (!render_native_camera_projection_preview(
        renderImages,
        preview,
        projection,
        false,
        progress,
        userData,
        failureReason,
        &context->projectionPreviewVersion,
        requestVersion
    )) {
        return empty;
    }
    if (operationScope.cancelled() || context->projectionPreviewVersion.load() != requestVersion) {
        return empty;
    }
    return pixel_buffer_from_result(preview, requestJson);
#else
    return empty;
#endif
}

void myptgui_free_pixel_buffer(MyPTGuiPixelBuffer buffer) {
    std::free(buffer.data);
}

void myptgui_free_float_pixel_buffer(MyPTGuiFloatPixelBuffer buffer) {
    std::free(buffer.data);
}

void myptgui_cancel(MyPTGuiNativeContext *context, unsigned long long jobId) {
    if (!context) {
        return;
    }
    std::lock_guard<std::mutex> lock(context->cancellationMutex);
    context->cancelledJobs[jobId] = true;
}

void myptgui_free_string(char *value) {
    std::free(value);
}
