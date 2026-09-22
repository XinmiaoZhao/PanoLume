// PanoLume internal implementation module. This file is included exactly once
// by MyPTGuiEngine.mm to preserve the pre-split translation-unit semantics.

static double percentile_sorted(const std::vector<double> &values, double percentile) {
    if (values.empty()) {
        return 0.0;
    }
    const double clipped = std::min(100.0, std::max(0.0, percentile));
    const double position = (static_cast<double>(values.size()) - 1.0) * clipped / 100.0;
    const size_t lower = static_cast<size_t>(std::floor(position));
    const size_t upper = static_cast<size_t>(std::ceil(position));
    if (lower == upper) {
        return values[lower];
    }
    const double alpha = position - static_cast<double>(lower);
    return values[lower] * (1.0 - alpha) + values[upper] * alpha;
}

static StretchParams compute_stretch_params(
    const NativeImage &image,
    double blackPercentile,
    double whitePercentile,
    double gamma
) {
    StretchParams params;
    params.gamma = gamma;
    if (image.status != "loaded"
        || (image.pixels.empty() && image.native16Pixels == nullptr)) {
        return params;
    }

    std::vector<double> luminance;
    if (image.native16Pixels != nullptr && image.width > 0 && image.height > 0) {
        const size_t pixelCount = static_cast<size_t>(image.width) * static_cast<size_t>(image.height);
        constexpr size_t targetSamples = 1000000;
        const size_t stride = std::max<size_t>(1, (pixelCount + targetSamples - 1) / targetSamples);
        luminance.reserve(std::min(pixelCount, targetSamples));
        constexpr double normalization = 1.0 / 65535.0;
        for (size_t pixel = 0; pixel < pixelCount; pixel += stride) {
            const size_t i = pixel * 3;
            const double value = (
                0.2126 * static_cast<double>(image.native16Pixels[i + 0])
                + 0.7152 * static_cast<double>(image.native16Pixels[i + 1])
                + 0.0722 * static_cast<double>(image.native16Pixels[i + 2])
            ) * normalization;
            if (std::isfinite(value) && value > 1e-7) {
                luminance.push_back(value);
            }
        }
    } else {
        luminance.reserve(image.pixels.size() / 3);
        for (size_t i = 0; i + 2 < image.pixels.size(); i += 3) {
            const double value =
                0.2126 * static_cast<double>(image.pixels[i + 0])
                + 0.7152 * static_cast<double>(image.pixels[i + 1])
                + 0.0722 * static_cast<double>(image.pixels[i + 2]);
            if (std::isfinite(value) && value > 1e-7) {
                luminance.push_back(value);
            }
        }
    }
    if (luminance.empty()) {
        return params;
    }
    std::sort(luminance.begin(), luminance.end());
    params.black = percentile_sorted(luminance, blackPercentile);
    params.white = percentile_sorted(luminance, whitePercentile);
    params.valid = std::isfinite(params.black)
        && std::isfinite(params.white)
        && params.white > params.black + 1e-8;
    return params;
}

static StretchParams compute_stretch_params(
    const std::vector<float> &pixels,
    double blackPercentile,
    double whitePercentile,
    double gamma
) {
    StretchParams params;
    params.gamma = gamma;
    if (pixels.empty()) {
        return params;
    }

    std::vector<double> luminance;
    luminance.reserve(pixels.size() / 3);
    for (size_t i = 0; i + 2 < pixels.size(); i += 3) {
        const double value =
            0.2126 * static_cast<double>(pixels[i + 0])
            + 0.7152 * static_cast<double>(pixels[i + 1])
            + 0.0722 * static_cast<double>(pixels[i + 2]);
        if (std::isfinite(value) && value > 1e-7) {
            luminance.push_back(value);
        }
    }
    if (luminance.empty()) {
        return params;
    }
    std::sort(luminance.begin(), luminance.end());
    params.black = percentile_sorted(luminance, blackPercentile);
    params.white = percentile_sorted(luminance, whitePercentile);
    params.valid = std::isfinite(params.black)
        && std::isfinite(params.white)
        && params.white > params.black + 1e-8;
    return params;
}

static float stretched_channel(float value, const StretchParams &params, double strength) {
    const double linear = std::min(1.0, std::max(0.0, static_cast<double>(value)));
    if (!params.valid || strength <= 0.0) {
        return static_cast<float>(linear);
    }
    double stretched = (static_cast<double>(value) - params.black) / (params.white - params.black);
    stretched = std::min(1.0, std::max(0.0, stretched));
    if (params.gamma > 0.0 && std::abs(params.gamma - 1.0) > 1e-6) {
        stretched = std::pow(stretched, params.gamma);
    }

    double result = stretched;
    if (strength < 1.0) {
        result = linear * (1.0 - strength) + stretched * strength;
    } else if (strength > 1.0) {
        result = std::pow(stretched, 1.0 / std::min(strength, 4.0));
    }
    return static_cast<float>(std::min(1.0, std::max(0.0, result)));
}

static std::string control_points_json(const std::vector<NativeControlPoint> &points) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < points.size(); ++i) {
        const NativeControlPoint &point = points[i];
        if (i) {
            out << ",";
        }
        out << "{";
        char uuid[37];
        std::snprintf(uuid, sizeof(uuid), "00000000-0000-0000-0000-%012zu", i);
        out << "\"id\":\"" << uuid << "\",";
        out << "\"imageAIndex\":" << point.imageAIndex << ",";
        out << "\"imageBIndex\":" << point.imageBIndex << ",";
        out << "\"xA\":" << point.xA << ",";
        out << "\"yA\":" << point.yA << ",";
        out << "\"xB\":" << point.xB << ",";
        out << "\"yB\":" << point.yB << ",";
        out << "\"error\":" << number_json(point.error) << ",";
        out << "\"isManual\":" << bool_json(point.isManual);
        out << "}";
    }
    out << "]";
    return out.str();
}
static std::string selected_edges_json(const std::vector<NativeSelectedEdge> &edges) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < edges.size(); ++i) {
        const NativeSelectedEdge &edge = edges[i];
        if (i) {
            out << ",";
        }
        out << "{";
        out << "\"i\":" << edge.i << ",";
        out << "\"j\":" << edge.j << ",";
        out << "\"score\":" << edge.score << ",";
        out << "\"method\":\"" << json_escape(edge.method) << "\",";
        out << "\"transform_model\":\"" << json_escape(edge.transformModel) << "\",";
        out << "\"transform_model_reason\":\"" << json_escape(edge.transformModelReason) << "\",";
        out << "\"transform_model_candidates\":{";
        out << "\"homography_p95_px\":" << number_json(edge.homographyP95) << ",";
        out << "\"similarity_p95_px\":" << number_json(edge.similarityP95) << ",";
        out << "\"pixel_grid_p95_px\":" << number_json(edge.pixelGridP95);
        out << "},";
        out << "\"coverage_quality\":{";
        out << "\"image_a\":{\"bbox_area\":" << number_json(edge.coverageBBoxAreaA)
            << ",\"grid_occupancy\":" << number_json(edge.coverageGridOccupancyA) << "},";
        out << "\"image_b\":{\"bbox_area\":" << number_json(edge.coverageBBoxAreaB)
            << ",\"grid_occupancy\":" << number_json(edge.coverageGridOccupancyB) << "},";
        out << "\"min_bbox_area\":" << number_json(std::min(edge.coverageBBoxAreaA, edge.coverageBBoxAreaB)) << ",";
        out << "\"min_grid_occupancy\":" << number_json(std::min(edge.coverageGridOccupancyA, edge.coverageGridOccupancyB));
        out << "},";
        out << "\"adaptive_quality\":{";
        out << "\"image_a\":{\"bbox_area\":" << number_json(edge.adaptiveBBoxAreaA)
            << ",\"grid_occupancy\":" << number_json(edge.adaptiveGridOccupancyA) << "},";
        out << "\"image_b\":{\"bbox_area\":" << number_json(edge.adaptiveBBoxAreaB)
            << ",\"grid_occupancy\":" << number_json(edge.adaptiveGridOccupancyB) << "},";
        out << "\"min_bbox_area\":" << number_json(std::min(edge.adaptiveBBoxAreaA, edge.adaptiveBBoxAreaB)) << ",";
        out << "\"min_grid_occupancy\":" << number_json(std::min(edge.adaptiveGridOccupancyA, edge.adaptiveGridOccupancyB));
        out << "},";
        out << "\"adaptive_coverage_attempted\":" << bool_json(edge.adaptiveCoverageAttempted) << ",";
        out << "\"adaptive_coverage_accepted\":" << bool_json(edge.adaptiveCoverageAccepted) << ",";
        out << "\"adaptive_coverage_inliers\":" << edge.adaptiveCoverageInliers << ",";
        out << "\"adaptive_coverage_reject_reason\":\"" << json_escape(edge.adaptiveCoverageRejectReason) << "\",";
        out << "\"partitions\":{";
        out << "\"fit_count\":" << edge.fitObservationCount << ",";
        out << "\"validation_count\":" << edge.validationControlPoints.size() << ",";
        out << "\"final_held_out_count\":" << edge.heldOutControlPoints.size() << ",";
        out << "\"occupied_cells\":" << edge.heldOutOccupiedCells << ",";
        out << "\"identity_association_p95_px\":" << number_json(edge.heldOutP95);
        out << "},";
        out << "\"identity_audit\":{";
        out << "\"candidates\":" << edge.identityCandidates << ",";
        out << "\"accepted\":" << edge.identityAccepted << ",";
        out << "\"rejected_descriptor\":" << edge.identityRejectedDescriptor << ",";
        out << "\"rejected_patch\":" << edge.identityRejectedPatch << ",";
        out << "\"rejected_fwhm\":" << edge.identityRejectedFWHM << ",";
        out << "\"rejected_flux\":" << edge.identityRejectedFlux << ",";
        out << "\"rejected_ratio\":" << edge.identityRejectedRatio << ",";
        out << "\"rejected_conflict\":" << edge.identityRejectedConflict << ",";
        out << "\"rejected_prediction\":" << edge.identityRejectedPrediction << ",";
        out << "\"rejected_boundary\":" << edge.identityRejectedBoundary;
        out << "}";
        out << "}";
    }
    out << "]";
    return out.str();
}

static std::string int_array_json(const std::vector<int> &values) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < values.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << values[i];
    }
    out << "]";
    return out.str();
}

static std::string control_point_summary_json(const std::vector<NativeControlPoint> &points) {
    if (points.empty()) {
        return "{\"total\":0,\"rms_error\":null,\"p95_error\":null}";
    }
    std::vector<double> errors;
    errors.reserve(points.size());
    double sumSquared = 0.0;
    for (const NativeControlPoint &point : points) {
        if (!std::isfinite(point.error)) {
            continue;
        }
        errors.push_back(point.error);
        sumSquared += point.error * point.error;
    }
    if (errors.empty()) {
        return "{\"total\":0,\"rms_error\":null,\"p95_error\":null}";
    }
    std::sort(errors.begin(), errors.end());
    const double p95Position = (static_cast<double>(errors.size()) - 1.0) * 0.95;
    const size_t lower = static_cast<size_t>(std::floor(p95Position));
    const size_t upper = static_cast<size_t>(std::ceil(p95Position));
    const double alpha = p95Position - static_cast<double>(lower);
    const double p95 = errors[lower] * (1.0 - alpha) + errors[upper] * alpha;
    std::ostringstream out;
    out << "{";
    out << "\"total\":" << points.size() << ",";
    out << "\"rms_error\":" << std::sqrt(sumSquared / static_cast<double>(points.size())) << ",";
    out << "\"p95_error\":" << p95;
    out << "}";
    return out.str();
}

static std::string camera_params_json(const std::vector<NativeCameraParams> &cameras) {
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "[";
    for (size_t i = 0; i < cameras.size(); ++i) {
        const NativeCameraParams &camera = cameras[i];
        if (i) {
            out << ",";
        }
        out << "{";
        out << "\"rotation\":[" << camera.rotation[0] << "," << camera.rotation[1] << "," << camera.rotation[2] << "],";
        out << "\"translation\":[" << camera.translation[0] << "," << camera.translation[1] << "," << camera.translation[2] << "],";
        out << "\"focalLength\":" << camera.focalLength << ",";
        out << "\"k1\":" << camera.k1 << ",";
        out << "\"k2\":" << camera.k2 << ",";
        out << "\"k3\":" << camera.k3 << ",";
        out << "\"p1\":" << camera.p1 << ",";
        out << "\"p2\":" << camera.p2 << ",";
        out << "\"principalOffsetX\":" << camera.principalOffsetX << ",";
        out << "\"principalOffsetY\":" << camera.principalOffsetY;
        out << "}";
    }
    out << "]";
    return out.str();
}

static std::string distortion_params_json(const std::array<double, 5> &distortion) {
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "{";
    out << "\"k1\":" << distortion[0] << ",";
    out << "\"k2\":" << distortion[1] << ",";
    out << "\"k3\":" << distortion[2] << ",";
    out << "\"p1\":" << distortion[3] << ",";
    out << "\"p2\":" << distortion[4];
    out << "}";
    return out.str();
}

static std::string camera_model_report_json(const NativeCameraModelReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"attempted\":" << bool_json(report.attempted) << ",";
    out << "\"solver_succeeded\":" << bool_json(report.solverSucceeded) << ",";
    out << "\"success\":" << bool_json(report.success) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\",";
    out << "\"input_control_points\":" << report.inputControlPoints << ",";
    out << "\"output_control_points\":" << report.outputControlPoints << ",";
    out << "\"focal_source\":\"" << json_escape(report.focalSource) << "\",";
    out << "\"initial_focal\":" << report.initialFocal << ",";
    out << "\"optimized_focal\":" << report.optimizedFocal << ",";
    out << "\"distortion_optimized\":" << bool_json(report.distortionOptimized) << ",";
    out << "\"initial_distortion\":" << distortion_params_json(report.initialDistortion) << ",";
    out << "\"optimized_distortion\":" << distortion_params_json(report.optimizedDistortion) << ",";
    out << "\"initial_rms_error\":" << number_json(report.initialRms) << ",";
    out << "\"optimized_rms_error\":" << number_json(report.optimizedRms) << ",";
    out << "\"selected_pair_p95_error\":" << number_json(report.selectedPairP95) << ",";
    out << "\"worst_selected_edge\":{";
    out << "\"i\":" << report.worstSelectedEdgeI << ",";
    out << "\"j\":" << report.worstSelectedEdgeJ;
    out << "},";
    out << "\"quality_gate_passed\":" << bool_json(report.qualityGatePassed) << ",";
    out << "\"quality_gate_reason\":\"" << json_escape(report.qualityGateReason) << "\",";
    out << "\"robust_reprojection_filter\":{";
    out << "\"threshold_px\":" << report.robustThreshold << ",";
    out << "\"max_rounds\":" << report.robustMaxRounds << ",";
    out << "\"rounds\":" << report.robustRounds << ",";
    out << "\"rejected_control_points\":" << report.robustRejected << ",";
    out << "\"stop_reason\":\"" << json_escape(report.robustStopReason) << "\"";
    out << "},";
    out << "\"solver_summary\":\"" << json_escape(report.solverSummary) << "\"";
    out << "}";
    return out.str();
}

static std::string astro_refinement_report_json(const NativeAstroRefinementReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"state\":\"" << json_escape(report.state) << "\",";
    out << "\"quality_gate_passed\":" << bool_json(report.qualityGatePassed) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\",";
    out << "\"lens_model\":\"" << json_escape(report.lensModel) << "\",";
    out << "\"evaluation_partition\":\"" << json_escape(report.evaluationPartition) << "\",";
    out << "\"residual_frame\":\"" << json_escape(report.residualFrame) << "\",";
    out << "\"partition_counts\":{";
    out << "\"fit\":" << report.fitObservations << ",";
    out << "\"validation\":" << report.validationObservations << ",";
    out << "\"final_held_out\":" << report.finalHeldOutObservations << "},";
    out << "\"lens_calibration_prior\":{";
    out << "\"available\":" << bool_json(report.lensPriorAvailable) << ",";
    out << "\"required\":" << bool_json(report.lensPriorRequired) << ",";
    out << "\"sha256\":\"" << json_escape(report.lensPriorSHA256) << "\",";
    out << "\"weight\":" << number_json(report.lensPriorWeight) << ",";
    out << "\"conversion_max_error_px\":" << number_json(report.lensPriorConversionMaxErrorPixels) << ",";
    out << "\"warning\":\"" << json_escape(report.lensPriorWarning) << "\"},";
    out << "\"grid_columns\":16,\"grid_rows\":8,";
    out << "\"local_warp\":{";
    out << "\"attempted\":" << bool_json(report.localWarp.attempted) << ",";
    out << "\"solver_succeeded\":" << bool_json(report.localWarp.solverSucceeded) << ",";
    out << "\"accepted\":" << bool_json(report.localWarp.accepted) << ",";
    out << "\"observations\":" << report.localWarp.observations << ",";
    out << "\"max_normalized_displacement\":" << number_json(report.localWarp.maxNormalizedDisplacement) << ",";
    out << "\"minimum_jacobian_determinant\":" << number_json(report.localWarp.minimumJacobianDeterminant) << ",";
    out << "\"amplitude_regularization\":" << number_json(report.localWarp.amplitudeRegularization) << ",";
    out << "\"first_difference_regularization\":" << number_json(report.localWarp.firstDifferenceRegularization) << ",";
    out << "\"curvature_regularization\":" << number_json(report.localWarp.curvatureRegularization) << ",";
    out << "\"worst_pair_improvement\":" << number_json(report.localWarp.worstPairImprovement) << ",";
    out << "\"worst_grid_improvement\":" << number_json(report.localWarp.worstGridImprovement) << ",";
    out << "\"reason\":\"" << json_escape(report.localWarp.reason) << "\"";
    out << "},";
    out << "\"lens_models\":[";
    for (size_t modelIndex = 0; modelIndex < report.lensModels.size(); ++modelIndex) {
        const NativeLensModelCandidateReport &model = report.lensModels[modelIndex];
        if (modelIndex) {
            out << ",";
        }
        out << "{";
        out << "\"model\":\"" << json_escape(model.model) << "\",";
        out << "\"solver_succeeded\":" << bool_json(model.solverSucceeded) << ",";
        out << "\"accepted\":" << bool_json(model.accepted) << ",";
        out << "\"worst_pair_p95_px\":" << number_json(model.worstPairP95) << ",";
        out << "\"worst_grid_risk_ratio\":" << number_json(model.worstGridRiskRatio) << ",";
        out << "\"held_out_improvement\":" << number_json(model.heldOutImprovement) << ",";
        out << "\"validation_improvement\":" << number_json(model.heldOutImprovement) << ",";
        out << "\"reason\":\"" << json_escape(model.reason) << "\"";
        out << "}";
    }
    out << "],";
    out << "\"psf_fits\":[";
    for (size_t imageIndex = 0; imageIndex < report.psfFits.size(); ++imageIndex) {
        const NativePSFFitAudit &audit = report.psfFits[imageIndex];
        if (imageIndex) out << ",";
        out << "{";
        out << "\"image_index\":" << audit.imageIndex << ",";
        out << "\"preliminary_candidates\":" << audit.preliminaryCandidates << ",";
        out << "\"selected_for_fit\":" << audit.selectedForFit << ",";
        out << "\"accepted\":" << audit.accepted << ",";
        out << "\"signal_to_noise_p05\":" << number_json(audit.signalToNoiseP05) << ",";
        out << "\"signal_to_noise_median\":" << number_json(audit.signalToNoiseMedian) << ",";
        out << "\"normalized_rms_median\":" << number_json(audit.normalizedRMSMedian) << ",";
        out << "\"normalized_rms_p95\":" << number_json(audit.normalizedRMSP95) << ",";
        out << "\"rejected_reasons\":{";
        bool firstReason = true;
        for (const auto &entry : audit.rejectedReasons) {
            if (!firstReason) out << ",";
            firstReason = false;
            out << "\"" << json_escape(entry.first) << "\":" << entry.second;
        }
        out << "}}";
    }
    out << "],";
    out << "\"pairs\":[";
    for (size_t pairIndex = 0; pairIndex < report.pairs.size(); ++pairIndex) {
        const NativeHeldOutPairReport &pair = report.pairs[pairIndex];
        if (pairIndex) {
            out << ",";
        }
        out << "{";
        out << "\"i\":" << pair.i << ",\"j\":" << pair.j << ",";
        out << "\"count\":" << pair.count << ",";
        out << "\"occupied_cells\":" << pair.occupiedCells << ",";
        out << "\"effective_cells\":" << pair.effectiveCells << ",";
        out << "\"low_support_cells\":" << pair.lowSupportCells << ",";
        out << "\"p95_px\":" << number_json(pair.p95) << ",";
        out << "\"mapped_fwhm_px\":" << number_json(pair.mappedFWHM) << ",";
        out << "\"pair_risk_ratio\":" << number_json(pair.pairRiskRatio) << ",";
        out << "\"worst_grid_risk_ratio\":" << number_json(pair.worstGridRiskRatio) << ",";
        out << "\"passed\":" << bool_json(pair.passed) << ",";
        out << "\"reason\":\"" << json_escape(pair.reason) << "\",";
        out << "\"identity_audit\":{";
        out << "\"candidates\":" << pair.identityCandidates << ",";
        out << "\"accepted\":" << pair.identityAccepted << ",";
        out << "\"rejected_descriptor\":" << pair.identityRejectedDescriptor << ",";
        out << "\"rejected_patch\":" << pair.identityRejectedPatch << ",";
        out << "\"rejected_fwhm\":" << pair.identityRejectedFWHM << ",";
        out << "\"rejected_flux\":" << pair.identityRejectedFlux << ",";
        out << "\"rejected_ratio\":" << pair.identityRejectedRatio << ",";
        out << "\"rejected_conflict\":" << pair.identityRejectedConflict << ",";
        out << "\"rejected_prediction\":" << pair.identityRejectedPrediction << ",";
        out << "\"rejected_boundary\":" << pair.identityRejectedBoundary << ",";
        out << "\"rejected_field\":" << pair.identityRejectedField << ",";
        out << "\"field_cutoff_px\":" << number_json(pair.identityFieldCutoff) << ",";
        out << "\"field_median_px\":" << number_json(pair.identityFieldMedian) << ",";
        out << "\"field_p95_px\":" << number_json(pair.identityFieldP95);
        out << "},";
        out << "\"residual_direction_buckets\":[";
        for (size_t bucketIndex = 0; bucketIndex < pair.residualDirectionBuckets.size(); ++bucketIndex) {
            const NativeResidualDirectionBucketReport &bucket = pair.residualDirectionBuckets[bucketIndex];
            if (bucketIndex) out << ",";
            out << "{";
            out << "\"band\":\"" << json_escape(bucket.band) << "\",";
            out << "\"count\":" << bucket.count << ",";
            out << "\"radial_p95_px\":" << number_json(bucket.radialP95) << ",";
            out << "\"tangential_p95_px\":" << number_json(bucket.tangentialP95);
            out << "}";
        }
        out << "],";
        out << "\"worst_observations\":[";
        for (size_t observationIndex = 0; observationIndex < pair.worstObservations.size(); ++observationIndex) {
            const NativeWorstAstroObservationReport &observation = pair.worstObservations[observationIndex];
            if (observationIndex) out << ",";
            out << "{";
            out << "\"error_px\":" << number_json(observation.error) << ",";
            out << "\"mapped_fwhm_px\":" << number_json(observation.mappedFWHM) << ",";
            out << "\"source_x\":" << number_json(observation.sourceX) << ",";
            out << "\"source_y\":" << number_json(observation.sourceY) << ",";
            out << "\"target_x\":" << number_json(observation.targetX) << ",";
            out << "\"target_y\":" << number_json(observation.targetY) << ",";
            out << "\"source_psf_snr\":" << number_json(observation.sourcePSFSignalToNoise) << ",";
            out << "\"target_psf_snr\":" << number_json(observation.targetPSFSignalToNoise) << ",";
            out << "\"source_psf_normalized_rms\":" << number_json(observation.sourcePSFNormalizedRMS) << ",";
            out << "\"target_psf_normalized_rms\":" << number_json(observation.targetPSFNormalizedRMS) << ",";
            out << "\"identity_association_residual_px\":"
                << number_json(observation.identityAssociationResidual);
            if (!observation.sourcePatchDataURL.empty()
                && !observation.targetPatchDataURL.empty()) {
                out << ",\"patch_side\":" << observation.patchSide << ",";
                out << "\"source_patch_data_url\":\""
                    << json_escape(observation.sourcePatchDataURL) << "\",";
                out << "\"target_patch_data_url\":\""
                    << json_escape(observation.targetPatchDataURL) << "\"";
            }
            out << "}";
        }
        out << "],";
        out << "\"grids\":[";
        for (size_t gridIndex = 0; gridIndex < pair.grids.size(); ++gridIndex) {
            const NativeHeldOutGridReport &grid = pair.grids[gridIndex];
            if (gridIndex) {
                out << ",";
            }
            out << "{";
            out << "\"column\":" << grid.column << ",\"row\":" << grid.row << ",";
            out << "\"count\":" << grid.count << ",";
            out << "\"p95_px\":" << number_json(grid.p95) << ",";
            out << "\"mapped_fwhm_px\":" << number_json(grid.mappedFWHM) << ",";
            out << "\"risk_ratio\":" << number_json(grid.riskRatio) << ",";
            out << "\"effective\":" << bool_json(grid.effective);
            out << "}";
        }
        out << "]}";
    }
    out << "]}";
    return out.str();
}

static std::string local_warp_model_json(const panolume::LocalWarpModel &model) {
    std::ostringstream out;
    out << "{";
    out << "\"columns\":" << model.columns << ",";
    out << "\"rows\":" << model.rows << ",";
    out << "\"reference_image\":" << model.referenceImage << ",";
    out << "\"images\":[";
    for (size_t imageIndex = 0; imageIndex < model.images.size(); ++imageIndex) {
        if (imageIndex) out << ",";
        out << "{\"dx\":[";
        for (size_t node = 0; node < model.images[imageIndex].dx.size(); ++node) {
            if (node) out << ",";
            out << number_json(model.images[imageIndex].dx[node]);
        }
        out << "],\"dy\":[";
        for (size_t node = 0; node < model.images[imageIndex].dy.size(); ++node) {
            if (node) out << ",";
            out << number_json(model.images[imageIndex].dy[node]);
        }
        out << "]}";
    }
    out << "]}";
    return out.str();
}

static std::string astro_refinement_json(const NativeResult &result) {
    return result.astroRefinementJsonOverride.empty()
        ? astro_refinement_report_json(result.astroRefinementReport)
        : result.astroRefinementJsonOverride;
}

static std::string manual_point_filtering_report_json(const NativeManualPointFilteringReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"input\":" << report.input << ",";
    out << "\"accepted\":" << report.accepted << ",";
    out << "\"rejected\":" << report.rejected << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\"";
    out << "}";
    return out.str();
}

static std::string guided_refinement_report_json(const NativeGuidedRefinementReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"enabled\":" << bool_json(report.enabled) << ",";
    out << "\"accepted\":" << bool_json(report.accepted) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\",";
    out << "\"input_control_points\":" << report.inputControlPoints << ",";
    out << "\"output_control_points\":" << report.outputControlPoints << ",";
    out << "\"added_control_points\":" << report.addedControlPoints << ",";
    out << "\"current_rms_error\":" << report.currentRms << ",";
    out << "\"candidate_rms_error\":" << report.candidateRms << ",";
    out << "\"pairs\":[";
    for (size_t idx = 0; idx < report.pairs.size(); ++idx) {
        const NativeGuidedPairReport &pair = report.pairs[idx];
        if (idx) {
            out << ",";
        }
        out << "{";
        out << "\"i\":" << pair.i << ",";
        out << "\"j\":" << pair.j << ",";
        out << "\"source_stars\":" << pair.sourceStars << ",";
        out << "\"target_stars\":" << pair.targetStars << ",";
        out << "\"candidate_matches\":" << pair.candidateMatches << ",";
        out << "\"added_control_points\":" << pair.addedControlPoints << ",";
        out << "\"threshold_px\":" << pair.thresholdPx << ",";
        out << "\"reason\":\"" << json_escape(pair.reason) << "\"";
        out << "}";
    }
    out << "]";
    out << "}";
    return out.str();
}

static std::string local_refinement_report_json(const NativeLocalRefinementReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"enabled\":" << bool_json(report.enabled) << ",";
    out << "\"accepted\":" << bool_json(report.accepted) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\",";
    out << "\"input_control_points\":" << report.inputControlPoints << ",";
    out << "\"output_control_points\":" << report.outputControlPoints << ",";
    out << "\"added_control_points\":" << report.addedControlPoints << ",";
    out << "\"train_control_points\":" << report.trainControlPoints << ",";
    out << "\"validation_control_points\":" << report.validationControlPoints << ",";
    out << "\"current_validation_rms_error\":" << report.currentValidationRms << ",";
    out << "\"candidate_validation_rms_error\":" << report.candidateValidationRms << ",";
    out << "\"current_base_rms_error\":" << report.currentBaseRms << ",";
    out << "\"candidate_base_rms_error\":" << report.candidateBaseRms << ",";
    out << "\"final_base_rms_error\":" << report.finalBaseRms << ",";
    out << "\"pairs\":[";
    for (size_t idx = 0; idx < report.pairs.size(); ++idx) {
        const NativeLocalPairReport &pair = report.pairs[idx];
        if (idx) {
            out << ",";
        }
        out << "{";
        out << "\"i\":" << pair.i << ",";
        out << "\"j\":" << pair.j << ",";
        out << "\"source_stars\":" << pair.sourceStars << ",";
        out << "\"target_stars\":" << pair.targetStars << ",";
        out << "\"eligible_sources\":" << pair.eligibleSources << ",";
        out << "\"candidate_matches\":" << pair.candidateMatches << ",";
        out << "\"added_control_points\":" << pair.addedControlPoints << ",";
        out << "\"rejected_low_evidence\":" << pair.rejectedLowEvidence << ",";
        out << "\"rejected_duplicate\":" << pair.rejectedDuplicate << ",";
        out << "\"cluster_candidates\":" << pair.clusterCandidates << ",";
        out << "\"cluster_selected\":" << pair.clusterSelected << ",";
        out << "\"search_radius_px\":" << pair.searchRadiusPx << ",";
        out << "\"evidence_threshold\":" << pair.evidenceThreshold << ",";
        out << "\"offset_x_px\":" << pair.offsetX << ",";
        out << "\"offset_y_px\":" << pair.offsetY << ",";
        out << "\"reason\":\"" << json_escape(pair.reason) << "\"";
        out << "}";
    }
    out << "]";
    out << "}";
    return out.str();
}

static std::string texture_refinement_report_json(const NativeTextureRefinementReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"enabled\":" << bool_json(report.enabled) << ",";
    out << "\"accepted\":" << bool_json(report.accepted) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\",";
    out << "\"input_control_points\":" << report.inputControlPoints << ",";
    out << "\"output_control_points\":" << report.outputControlPoints << ",";
    out << "\"added_control_points\":" << report.addedControlPoints << ",";
    out << "\"train_control_points\":" << report.trainControlPoints << ",";
    out << "\"validation_control_points\":" << report.validationControlPoints << ",";
    out << "\"current_validation_rms_error\":" << report.currentValidationRms << ",";
    out << "\"candidate_validation_rms_error\":" << report.candidateValidationRms << ",";
    out << "\"current_base_rms_error\":" << report.currentBaseRms << ",";
    out << "\"candidate_base_rms_error\":" << report.candidateBaseRms << ",";
    out << "\"feature_counts\":" << int_array_json(report.featureCounts) << ",";
    out << "\"pairs\":[";
    for (size_t idx = 0; idx < report.pairs.size(); ++idx) {
        const NativeTexturePairReport &pair = report.pairs[idx];
        if (idx) {
            out << ",";
        }
        out << "{";
        out << "\"i\":" << pair.i << ",";
        out << "\"j\":" << pair.j << ",";
        out << "\"source_features\":" << pair.sourceFeatures << ",";
        out << "\"target_features\":" << pair.targetFeatures << ",";
        out << "\"raw_matches\":" << pair.rawMatches << ",";
        out << "\"geometry_consistent_matches\":" << pair.geometryConsistentMatches << ",";
        out << "\"candidate_control_points\":" << pair.candidateControlPoints << ",";
        out << "\"added_control_points\":" << pair.addedControlPoints << ",";
        out << "\"threshold_px\":" << pair.thresholdPx << ",";
        out << "\"reason\":\"" << json_escape(pair.reason) << "\"";
        out << "}";
    }
    out << "]";
    out << "}";
    return out.str();
}

static std::string output_bounds_report_json(const NativeOutputBoundsReport &bounds) {
    std::ostringstream out;
    out << "{";
    out << "\"raw_width\":" << bounds.rawWidth << ",";
    out << "\"raw_height\":" << bounds.rawHeight << ",";
    out << "\"width\":" << bounds.width << ",";
    out << "\"height\":" << bounds.height << ",";
    out << "\"pixels\":" << bounds.pixels << ",";
    out << "\"scale\":" << bounds.scale << ",";
    out << "\"projection_scale\":" << bounds.projectionScale << ",";
    out << "\"min_u\":" << bounds.minU << ",";
    out << "\"min_v\":" << bounds.minV << ",";
    out << "\"max_u\":" << bounds.maxU << ",";
    out << "\"max_v\":" << bounds.maxV << ",";
    out << "\"projection_bounds\":{";
    out << "\"min_u\":" << bounds.minU << ",";
    out << "\"min_v\":" << bounds.minV << ",";
    out << "\"max_u\":" << bounds.maxU << ",";
    out << "\"max_v\":" << bounds.maxV;
    out << "},";
    out << "\"max_output_pixels\":" << bounds.maxOutputPixels << ",";
    out << "\"max_output_side\":" << bounds.maxOutputSide;
    out << "}";
    return out.str();
}

static std::string camera_projection_report_json(const NativeCameraProjectionReport &report) {
    std::ostringstream out;
    out << "{";
    out << "\"attempted\":" << bool_json(report.attempted) << ",";
    out << "\"success\":" << bool_json(report.success) << ",";
    out << "\"primary_preview\":" << bool_json(report.primaryPreview) << ",";
    out << "\"reason\":\"" << json_escape(report.reason) << "\"";
    out << "}";
    return out.str();
}

// Geometry-only projection commits intentionally avoid result_json(). A full
// result can contain tens of thousands of control points plus large diagnostic
// arrays, even though this operation changes only the stored camera pose and a
// handful of presentation fields. Swift merges this versioned delta into the
// complete StitchResult it already owns.
static std::string geometry_commit_result_json(
    const NativeResult &result,
    const std::string &operation,
    const std::string &message
) {
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<double>::max_digits10);
    out << "{";
    out << "\"success\":true,";
    out << "\"operation\":\"" << json_escape(operation) << "\",";
    out << "\"message\":\"" << json_escape(message) << "\",";
    out << "\"result\":null,";
    out << "\"result_delta\":{";
    out << "\"schema_version\":1,";
    out << "\"handle\":\"" << json_escape(result.handle) << "\",";
    out << "\"projection\":\"" << json_escape(result.projection) << "\",";
    out << "\"camera_params\":" << camera_params_json(result.cameraParams) << ",";
    if (!result.localWarpModel.images.empty()) {
        out << "\"local_warp\":" << local_warp_model_json(result.localWarpModel) << ",";
    }
    out << "\"pose_adjustment\":{";
    out << "\"pitchDegrees\":" << result.projectionAdjustmentDegrees[0] << ",";
    out << "\"yawDegrees\":" << result.projectionAdjustmentDegrees[1] << ",";
    out << "\"rollDegrees\":" << result.projectionAdjustmentDegrees[2];
    out << "},";
    out << "\"diagnostics_delta\":{";
    out << "\"geometry\":\"" << json_escape(result.geometry) << "\",";
    out << "\"projection\":\"" << json_escape(result.projection) << "\",";
    out << "\"blend_mode\":\"" << json_escape(result.blendMode) << "\",";
    out << "\"preview_renderer_requested\":\""
        << json_escape(result.previewRendererRequested) << "\",";
    out << "\"projection_adjustment\":{";
    out << "\"pitch_degrees\":" << result.projectionAdjustmentDegrees[0] << ",";
    out << "\"yaw_degrees\":" << result.projectionAdjustmentDegrees[1] << ",";
    out << "\"roll_degrees\":" << result.projectionAdjustmentDegrees[2];
    out << "}";
    out << "}";
    out << "}";
    out << "}";
    return out.str();
}

static std::string result_json(
    const MyPTGuiNativeContext *context,
    const NativeResult &result,
    const std::string &operation,
    bool success,
    const std::string &message
) {
    const std::string projectionGeometryState = result.previewStatus == "camera_projection_preview"
        && result.geometryGatePassed
        ? "verified_camera"
        : ((result.projectionGeometryState == "unverified_camera_draft"
                || result.previewStatus == "draft_camera_preview"
                || result.previewStatus == "unverified_camera_draft"
                || (result.geometry == "camera" && !result.cameraParams.empty() && !result.geometryGatePassed))
            ? "unverified_camera_draft"
            : "homography_diagnostic");
    std::ostringstream out;
    out << "{";
    out << "\"success\":" << bool_json(success) << ",";
    out << "\"operation\":\"" << json_escape(operation) << "\",";
    out << "\"message\":\"" << json_escape(message) << "\",";
    out << "\"result\":{";
    out << "\"handle\":\"" << json_escape(result.handle) << "\",";
    out << "\"projection\":\"" << json_escape(result.projection) << "\",";
    out << "\"projection_geometry_state\":\"" << projectionGeometryState << "\",";
    out << "\"geometry_quality_gate_passed\":" << bool_json(result.geometryGatePassed) << ",";
    out << "\"panorama\":{\"width\":" << result.width << ",\"height\":" << result.height << ",\"channels\":3,\"bit_depth\":" << result.bitDepth << "},";
    out << "\"camera_params\":" << camera_params_json(result.cameraParams) << ",";
    out << "\"control_points\":" << control_points_json(result.controlPoints) << ",";
    out << "\"source_images\":" << source_images_json(context, result) << ",";
    if (result.outputBounds.valid) {
        out << "\"projection_canvas\":" << output_bounds_report_json(result.outputBounds) << ",";
    }
    if (result.astroRefinementReport.state != "not_required") {
        out << "\"astro_refinement\":" << astro_refinement_json(result) << ",";
    }
    out << "\"diagnostics\":{";
    out << "\"native_status\":\"native_preview_available_parity_not_proven\",";
    out << "\"mode\":\"native_" << json_escape(operation) << "\",";
    out << "\"geometry\":\"" << json_escape(result.geometry) << "\",";
    out << "\"projection_geometry_state\":\"" << projectionGeometryState << "\",";
    out << "\"projection\":\"" << json_escape(result.projection) << "\",";
    out << "\"blend_mode\":\"" << json_escape(result.blendMode) << "\",";
    if (!result.blendEngine.empty()) {
        out << "\"blend_engine\":\"" << json_escape(result.blendEngine) << "\",";
    }
    if (!result.sourceOwnershipJson.empty()) {
        out << "\"source_ownership\":" << result.sourceOwnershipJson << ",";
    }
    out << "\"preview_renderer_requested\":\"" << json_escape(result.previewRendererRequested) << "\",";
    out << "\"preview_renderer_used\":\"" << json_escape(result.previewRendererUsed) << "\",";
    out << "\"preview_renderer_fallback\":" << bool_json(result.previewRendererFallback) << ",";
    if (!result.previewRendererFallbackReason.empty()) {
        out << "\"preview_renderer_fallback_reason\":\"" << json_escape(result.previewRendererFallbackReason) << "\",";
    }
    out << "\"preview_status\":\"" << json_escape(result.previewStatus) << "\",";
    if (!result.previewFailureReason.empty()) {
        out << "\"preview_failure_reason\":\"" << json_escape(result.previewFailureReason) << "\",";
    }
    if (!result.alignmentFamily.empty()) {
        out << "\"alignment_family\":\"" << json_escape(result.alignmentFamily) << "\",";
    }
    out << "\"astro_sky_mode\":\"" << json_escape(result.astroSkyMode) << "\",";
    out << "\"geometry_gate\":{";
    out << "\"passed\":" << bool_json(result.geometryGatePassed) << ",";
    out << "\"reason\":\"" << json_escape(result.geometryGateReason) << "\"";
    out << "},";
    if (!result.reoptimizationMethod.empty()) {
        out << "\"reoptimization_method\":\"" << json_escape(result.reoptimizationMethod) << "\",";
    }
    out << "\"star_edge_recovery\":{";
    out << "\"attempts\":" << result.starRecoveryAttempts << ",";
    out << "\"accepted\":" << result.starRecoveryAccepted << ",";
    out << "\"attempt_details\":[";
    for (size_t idx = 0; idx < result.starRecoveryDiagnostics.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "\"" << json_escape(result.starRecoveryDiagnostics[idx]) << "\"";
    }
    out << "],";
    out << "\"rejected_camera_edges\":[";
    for (size_t idx = 0; idx < result.rejectedCameraEdges.size(); ++idx) {
        if (idx) {
            out << ",";
        }
        out << "{\"i\":" << result.rejectedCameraEdges[idx].first
            << ",\"j\":" << result.rejectedCameraEdges[idx].second << "}";
    }
    out << "],";
    out << "\"camera_tree_attempts\":[";
    for (size_t idx = 0; idx < result.cameraTreeAttempts.size(); ++idx) {
        const NativeCameraTreeAttemptReport &attempt = result.cameraTreeAttempts[idx];
        if (idx) {
            out << ",";
        }
        out << "{";
        out << "\"attempt\":" << attempt.attempt << ",";
        out << "\"success\":" << bool_json(attempt.success) << ",";
        out << "\"optimized_rms_error\":" << number_json(attempt.optimizedRms) << ",";
        out << "\"selected_pair_p95_error\":" << number_json(attempt.selectedPairP95) << ",";
        out << "\"reason\":\"" << json_escape(attempt.reason) << "\",";
        out << "\"worst_edge\":{";
        out << "\"i\":" << attempt.worstEdgeI << ",";
        out << "\"j\":" << attempt.worstEdgeJ << "},";
        out << "\"selected_edges\":[";
        for (size_t edgeIndex = 0; edgeIndex < attempt.selectedEdges.size(); ++edgeIndex) {
            if (edgeIndex) {
                out << ",";
            }
            out << "{\"i\":" << attempt.selectedEdges[edgeIndex].first
                << ",\"j\":" << attempt.selectedEdges[edgeIndex].second << "}";
        }
        out << "]}";
    }
    out << "]},";
    out << "\"input_order_used\":\"" << json_escape(result.inputOrderUsed) << "\",";
    out << "\"input_order_auto_corrected\":" << bool_json(result.inputOrderAutoCorrected) << ",";
    if (!result.inputOrderCanonicalJson.empty()) {
        out << "\"input_order_canonical\":" << result.inputOrderCanonicalJson << ",";
    }
    if (!result.inputOrderCandidatesJson.empty()) {
        out << "\"input_order_candidates\":" << result.inputOrderCandidatesJson << ",";
    }
    if (!result.starCounts.empty()) {
        out << "\"star_counts\":" << int_array_json(result.starCounts) << ",";
    }
    out << "\"selected_edges\":" << selected_edges_json(result.selectedEdges) << ",";
    out << "\"control_points\":" << control_point_summary_json(result.controlPoints) << ",";
    if (result.manualPointFilteringReport.available) {
        out << "\"manual_point_filtering\":"
            << manual_point_filtering_report_json(result.manualPointFilteringReport) << ",";
    }
    if (result.cameraModelReport.attempted) {
        out << "\"camera_model\":" << camera_model_report_json(result.cameraModelReport) << ",";
    }
    if (result.guidedRefinementReport.enabled || result.guidedRefinementReport.inputControlPoints > 0) {
        out << "\"guided_star_refinement\":" << guided_refinement_report_json(result.guidedRefinementReport) << ",";
    }
    if (result.localRefinementReport.enabled || result.localRefinementReport.inputControlPoints > 0) {
        out << "\"local_star_refinement\":" << local_refinement_report_json(result.localRefinementReport) << ",";
    }
    if (result.textureRefinementReport.enabled || result.textureRefinementReport.inputControlPoints > 0) {
        out << "\"texture_sift_refinement\":" << texture_refinement_report_json(result.textureRefinementReport) << ",";
    }
    if (result.cameraProjectionReport.attempted) {
        out << "\"camera_projection_preview\":" << camera_projection_report_json(result.cameraProjectionReport) << ",";
    }
    if (!result.starProjectionAlignmentJson.empty()) {
        out << "\"star_projection_alignment\":" << result.starProjectionAlignmentJson << ",";
    }
    if (result.astroRefinementReport.state != "not_required") {
        out << "\"astro_refinement\":" << astro_refinement_json(result) << ",";
    }
    if (result.outputBounds.valid) {
        out << "\"output_bounds\":" << output_bounds_report_json(result.outputBounds) << ",";
    }
    if (result.hasProjectionAdjustment) {
        out << "\"projection_adjustment\":{";
        out << "\"pitch_degrees\":" << result.projectionAdjustmentDegrees[0] << ",";
        out << "\"yaw_degrees\":" << result.projectionAdjustmentDegrees[1] << ",";
        out << "\"roll_degrees\":" << result.projectionAdjustmentDegrees[2];
        out << "},";
    }
    if (!result.exportProfileJson.empty()) {
        out << "\"export_profile\":" << result.exportProfileJson << ",";
    }
    out << "\"image_io\":{\"status\":\"available\",\"standard_formats\":\"ImageIO/CoreGraphics\",\"raw_status\":\"" << raw_status() << "\"},";
    const bool cameraResultPassed = result.geometryGatePassed
        && result.geometry == "camera"
        && result.previewStatus == "camera_projection_preview"
        && result.cameraModelReport.success
        && !result.cameraParams.empty()
        && result.cameraParams.size() == result.imageHandles.size();
    const bool homographyResultPassed = result.geometryGatePassed
        && result.geometry == "homography"
        && result.previewStatus == "homography_preview"
        && !result.selectedEdges.empty();
    const bool stitchResultPassed = cameraResultPassed || homographyResultPassed;
    const bool completionPassed = native_parity_runtime_available() && stitchResultPassed;
    out << "\"completion_gate\":{";
    out << "\"passed\":" << bool_json(completionPassed) << ",";
    if (completionPassed) {
        out << "\"reason\":\"This exact build is certified for production export.\",";
    } else if (!native_parity_runtime_available()) {
        out << "\"reason\":\"Production export remains locked until the exact source fingerprint, required dependencies, and Metal Quality binary are certified and present.\",";
    } else {
        out << "\"reason\":\"The runtime is release-certified, but this result did not complete a valid camera or homography stitch.\",";
    }
    out << "\"missing_algorithms\":" << missing_algorithms_json(!stitchResultPassed);
    out << "},";
    out << "\"capabilities\":" << capabilities_json();
    out << "}";
    out << "}";
    out << "}";
    return out.str();
}

static std::string error_json(const std::string &operation, const std::string &message) {
    return std::string("{")
        + "\"success\":false,"
        + "\"operation\":\"" + json_escape(operation) + "\","
        + "\"message\":\"" + json_escape(message) + "\","
        + "\"result\":null"
        + "}";
}

static std::string image_load_result_json(
    const std::vector<NativeImage> &images,
    const std::string &message
) {
    int loaded = 0;
    int unsupported = 0;
    int failed = 0;
    for (const NativeImage &image : images) {
        if (image.status == "loaded") {
            loaded += 1;
        } else if (image.status == "unsupported_until_libraw") {
            unsupported += 1;
        } else {
            failed += 1;
        }
    }

    std::ostringstream out;
    out << "{";
    out << "\"success\":true,";
    out << "\"operation\":\"loadImages\",";
    out << "\"message\":\"" << json_escape(message) << "\",";
    out << "\"images\":" << image_infos_json(images) << ",";
    out << "\"diagnostics\":{";
    out << "\"loaded\":" << loaded << ",";
    out << "\"unsupported\":" << unsupported << ",";
    out << "\"failed\":" << failed << ",";
    out << "\"standard_image_io\":\"ImageIO/CoreGraphics\",";
    out << "\"raw_status\":\"" << raw_status() << "\"";
    out << "}";
    out << "}";
    return out.str();
}

static std::vector<NativeCameraParams> native_camera_params_from_json(
    const panolume::JSONRequest &request,
    const std::string &key = "cameraParams"
) {
    std::vector<NativeCameraParams> cameras;
    for (const panolume::JSONRequest &object : request.object_array(key)) {
        NativeCameraParams camera;
        const std::vector<double> rotation = object.number_array("rotation");
        const std::vector<double> translation = object.number_array("translation");
        if (rotation.size() != 3) {
            return {};
        }
        std::copy(rotation.begin(), rotation.end(), camera.rotation.begin());
        if (translation.size() == 3) {
            std::copy(translation.begin(), translation.end(), camera.translation.begin());
        }
        camera.focalLength = object.number("focalLength", 0.0);
        camera.k1 = object.number("k1", 0.0);
        camera.k2 = object.number("k2", 0.0);
        camera.k3 = object.number("k3", 0.0);
        camera.p1 = object.number("p1", 0.0);
        camera.p2 = object.number("p2", 0.0);
        camera.principalOffsetX = object.number("principalOffsetX", 0.0);
        camera.principalOffsetY = object.number("principalOffsetY", 0.0);
        cameras.push_back(camera);
    }
    return cameras;
}

static panolume::LocalWarpModel native_local_warp_from_json(
    const panolume::JSONRequest &request,
    const std::string &key = "localWarp"
) {
    panolume::LocalWarpModel model;
    const panolume::JSONRequest object = request.object(key);
    if (!object.valid()) return model;
    model.columns = object.integer("columns", panolume::kLocalWarpColumns);
    model.rows = object.integer("rows", panolume::kLocalWarpRows);
    model.referenceImage = object.integer("reference_image", object.integer("referenceImage", -1));
    if (model.columns != panolume::kLocalWarpColumns || model.rows != panolume::kLocalWarpRows) {
        return panolume::LocalWarpModel();
    }
    for (const panolume::JSONRequest &image : object.object_array("images")) {
        const std::vector<double> dx = image.number_array("dx");
        const std::vector<double> dy = image.number_array("dy");
        if (dx.size() != panolume::kLocalWarpNodeCount
            || dy.size() != panolume::kLocalWarpNodeCount) {
            return panolume::LocalWarpModel();
        }
        panolume::LocalWarpImageModel imageModel;
        std::copy(dx.begin(), dx.end(), imageModel.dx.begin());
        std::copy(dy.begin(), dy.end(), imageModel.dy.begin());
        model.images.push_back(std::move(imageModel));
    }
    return model;
}

static std::vector<std::pair<int, int>> native_selected_pairs_from_json(
    const panolume::JSONRequest &request,
    int imageCount
) {
    std::vector<std::pair<int, int>> pairs;
    for (const panolume::JSONRequest &object : request.object_array("selectedPairs")) {
        const int i = object.integer("i", -1);
        const int j = object.integer("j", -1);
        if (i >= 0 && j >= 0 && i < imageCount && j < imageCount && i != j) {
            pairs.push_back({std::min(i, j), std::max(i, j)});
        }
    }
    if (pairs.empty()) {
        for (int index = 0; index + 1 < imageCount; ++index) {
            pairs.push_back({index, index + 1});
        }
    }
    std::sort(pairs.begin(), pairs.end());
    pairs.erase(std::unique(pairs.begin(), pairs.end()), pairs.end());
    return pairs;
}

static std::string number_array_json(const std::vector<int> &values) {
    std::ostringstream out;
    out << "[";
    for (size_t index = 0; index < values.size(); ++index) {
        if (index) {
            out << ",";
        }
        out << values[index];
    }
    out << "]";
    return out.str();
}
