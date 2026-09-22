import CryptoKit
import Foundation
import ImageIO

public enum PTSImportError: Error, LocalizedError, Equatable {
    case fileTooLarge(Int)
    case invalidContainer(String)
    case invalidProject(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "The PTGui project is \(size) bytes; the read-only importer limit is 64 MiB."
        case .invalidContainer(let message), .invalidProject(let message), .unsupported(let message):
            return message
        }
    }
}

public struct PTSImportedImage: Codable, Equatable, Sendable {
    public var index: Int
    public var groupIndex: Int
    public var imageIndex: Int
    public var path: String
    public var width: Int
    public var height: Int
    public var yawDegrees: Double
    public var pitchDegrees: Double
    public var rollDegrees: Double
    public var focalLengthPixels: Double
    public var principalX: Double
    public var principalY: Double
    public var blendWeight: Double
    public var whiteBalanceTemperature: Double?
    public var optimizeYaw: Bool
    public var optimizePitch: Bool
    public var optimizeRoll: Bool

    enum CodingKeys: String, CodingKey {
        case index
        case groupIndex = "group_index"
        case imageIndex = "image_index"
        case path, width, height
        case yawDegrees = "yaw_degrees"
        case pitchDegrees = "pitch_degrees"
        case rollDegrees = "roll_degrees"
        case focalLengthPixels = "focal_length_pixels"
        case principalX = "principal_x"
        case principalY = "principal_y"
        case blendWeight = "blend_weight"
        case whiteBalanceTemperature = "white_balance_temperature"
        case optimizeYaw = "optimize_yaw"
        case optimizePitch = "optimize_pitch"
        case optimizeRoll = "optimize_roll"
    }
}

public struct PTSImportedBlendSettings: Codable, Equatable, Sendable {
    public var engine: String
    public var seamFinding: Bool
    public var seamFindingPrecision: Int
    public var maskPushSeams: Bool

    enum CodingKeys: String, CodingKey {
        case engine
        case seamFinding = "seam_finding"
        case seamFindingPrecision = "seam_finding_precision"
        case maskPushSeams = "mask_push_seams"
    }
}

public enum PTSGeometryRefinementMode: String, Codable, Equatable, Sendable {
    case off
    case strict
}

public enum PTSOwnerSelectionMode: String, Codable, Equatable, Sendable {
    case legacy
    case faintStarPriority = "faint_star_priority"
    case transientSafeFaintStar = "transient_safe_faint_star"
}

public struct PTSImportedControlPoint: Codable, Equatable, Sendable {
    public var imageAIndex: Int
    public var imageBIndex: Int
    public var xA: Double
    public var yA: Double
    public var xB: Double
    public var yB: Double

    enum CodingKeys: String, CodingKey {
        case imageAIndex, imageBIndex, xA, yA, xB, yB
    }
}

public struct PTSControlPointResiduals: Codable, Equatable, Sendable {
    public var medianDegrees: Double
    public var p95Degrees: Double
    public var maximumDegrees: Double
    public var passed: Bool

    enum CodingKeys: String, CodingKey {
        case medianDegrees = "median_degrees"
        case p95Degrees = "p95_degrees"
        case maximumDegrees = "maximum_degrees"
        case passed
    }
}

public struct PTSImportedProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var projectPath: String
    public var container: String
    public var sourceSHA256: String
    public var plaintextSHA256: String
    public var software: String
    public var fileVersion: Int
    public var projection: String
    public var horizontalFOVDegrees: Double
    public var verticalFOVDegrees: Double
    public var previewWidth: Int
    public var previewHeight: Int
    public var fullWidth: Int
    public var fullHeight: Int
    public var anchorImageIndex: Int
    public var blendSettings: PTSImportedBlendSettings
    public var images: [PTSImportedImage]
    public var controlPoints: [PTSImportedControlPoint]
    public var connectedPairCount: Int
    public var connectedGraph: Bool
    public var residuals: PTSControlPointResiduals

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case projectPath = "project_path"
        case container
        case sourceSHA256 = "source_sha256"
        case plaintextSHA256 = "plaintext_sha256"
        case software
        case fileVersion = "file_version"
        case projection
        case horizontalFOVDegrees = "horizontal_fov_degrees"
        case verticalFOVDegrees = "vertical_fov_degrees"
        case previewWidth = "preview_width"
        case previewHeight = "preview_height"
        case fullWidth = "full_width"
        case fullHeight = "full_height"
        case anchorImageIndex = "anchor_image_index"
        case blendSettings = "blend_settings"
        case images
        case controlPoints = "control_points"
        case connectedPairCount = "connected_pair_count"
        case connectedGraph = "connected_graph"
        case residuals
    }
}

public enum PTSReconstructionSizing {
    public static let minimumLongEdge = 4096
    public static let recommendedLongEdge = 16_384
    public static let presetLongEdges = [8_192, recommendedLongEdge, 24_576]

    public static func dimensions(
        fullWidth: Int,
        fullHeight: Int,
        requestedLongEdge: Int
    ) throws -> (width: Int, height: Int) {
        guard fullWidth > 0, fullHeight > 0 else {
            throw PTSImportError.invalidProject("Imported PTS recovery dimensions are invalid.")
        }
        let fullLongEdge = max(fullWidth, fullHeight)
        guard requestedLongEdge >= minimumLongEdge else {
            throw PTSImportError.invalidProject(
                "Reconstruction long edge must be at least \(minimumLongEdge) pixels."
            )
        }
        guard requestedLongEdge <= fullLongEdge else {
            throw PTSImportError.invalidProject(
                "Reconstruction long edge cannot exceed the recovered \(fullLongEdge)-pixel source density."
            )
        }
        if requestedLongEdge == fullLongEdge {
            return (fullWidth, fullHeight)
        }
        let scale = Double(requestedLongEdge) / Double(fullLongEdge)
        return (
            max(1, Int((Double(fullWidth) * scale).rounded())),
            max(1, Int((Double(fullHeight) * scale).rounded()))
        )
    }

    public static func estimatedUncompressedBytes(width: Int, height: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let pixels = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !pixels.overflow else { return .max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 8)
        return bytes.overflow ? .max : bytes.partialValue
    }
}

public struct ImportedPanoramaRenderRequest: Codable, Equatable, Sendable {
    public var project: PTSImportedProject
    public var outputPath: String
    public var outputWidth: Int
    public var outputHeight: Int
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var cropX: Int
    public var cropY: Int
    public var ownershipMapSide: Int
    public var fullResolutionSources: Bool
    public var diagnosticsOnly: Bool
    public var geometryRefinementMode: PTSGeometryRefinementMode
    public var ownerSelectionMode: PTSOwnerSelectionMode
    public var diagnosticsDirectory: String?
    public var jobID: UInt64?

    public init(
        project: PTSImportedProject,
        outputURL: URL,
        outputWidth: Int,
        outputHeight: Int,
        canvasWidth: Int? = nil,
        canvasHeight: Int? = nil,
        cropX: Int = 0,
        cropY: Int = 0,
        ownershipMapSide: Int = 2048,
        fullResolutionSources: Bool,
        diagnosticsOnly: Bool = false,
        geometryRefinementMode: PTSGeometryRefinementMode = .off,
        ownerSelectionMode: PTSOwnerSelectionMode = .legacy,
        diagnosticsDirectoryURL: URL? = nil,
        jobID: UInt64? = nil
    ) {
        self.project = project
        outputPath = outputURL.path
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.canvasWidth = canvasWidth ?? outputWidth
        self.canvasHeight = canvasHeight ?? outputHeight
        self.cropX = cropX
        self.cropY = cropY
        self.ownershipMapSide = ownershipMapSide
        self.fullResolutionSources = fullResolutionSources
        self.diagnosticsOnly = diagnosticsOnly
        self.geometryRefinementMode = geometryRefinementMode
        self.ownerSelectionMode = ownerSelectionMode
        diagnosticsDirectory = diagnosticsDirectoryURL?.path
        self.jobID = jobID
    }

    enum CodingKeys: String, CodingKey {
        case project
        case outputPath = "output_path"
        case outputWidth = "output_width"
        case outputHeight = "output_height"
        case canvasWidth = "canvas_width"
        case canvasHeight = "canvas_height"
        case cropX = "crop_x"
        case cropY = "crop_y"
        case ownershipMapSide = "ownership_map_side"
        case fullResolutionSources = "full_resolution_sources"
        case diagnosticsOnly = "diagnostics_only"
        case geometryRefinementMode = "geometry_refinement_mode"
        case ownerSelectionMode = "owner_selection_mode"
        case diagnosticsDirectory = "diagnostics_directory"
        case jobID = "jobId"
    }
}

public struct PTSResidualPixelSummary: Codable, Equatable, Sendable {
    public var median: Double
    public var p95: Double
    public var maximum: Double
}

public struct PTSHeldOutPairResidualReport: Codable, Equatable, Sendable {
    public var imageA: Int
    public var imageB: Int
    public var beforeP95: Double
    public var afterP95: Double
    public var count: Int

    enum CodingKeys: String, CodingKey {
        case imageA = "image_a"
        case imageB = "image_b"
        case beforeP95 = "before_p95"
        case afterP95 = "after_p95"
        case count
    }
}

public struct PTSGeometryRefinementReport: Codable, Equatable, Sendable {
    public var requestedMode: String
    public var adopted: Bool
    public var fallbackReason: String?
    public var solverSummary: String?
    public var originalObservationCount: Int
    public var refinedObservationCount: Int
    public var starObservationCount: Int
    public var textureObservationCount: Int
    public var trainingCount: Int
    public var heldOutCount: Int
    public var beforePixels: PTSResidualPixelSummary
    public var afterPixels: PTSResidualPixelSummary
    public var maximumRotationChangeDegrees: Double
    public var rotationChangesDegrees: [[Double]]
    public var heldOutPairP95: [PTSHeldOutPairResidualReport]

    enum CodingKeys: String, CodingKey {
        case requestedMode = "requested_mode"
        case adopted
        case fallbackReason = "fallback_reason"
        case solverSummary = "solver_summary"
        case originalObservationCount = "original_observation_count"
        case refinedObservationCount = "refined_observation_count"
        case starObservationCount = "star_observation_count"
        case textureObservationCount = "texture_observation_count"
        case trainingCount = "training_count"
        case heldOutCount = "held_out_count"
        case beforePixels = "before_pixels"
        case afterPixels = "after_pixels"
        case maximumRotationChangeDegrees = "maximum_rotation_change_degrees"
        case rotationChangesDegrees = "rotation_changes_degrees"
        case heldOutPairP95 = "held_out_pair_p95"
    }
}

public struct PTSZeroOverlapReport: Codable, Equatable, Sendable {
    public var engine: String
    public var ownerSelectionMode: String?
    public var seamFindingPrecision: Int
    public var initialOwnerWidth: Int
    public var initialOwnerHeight: Int
    public var fullOwnerWidth: Int
    public var fullOwnerHeight: Int
    public var boundaryPixelCount: Int64
    public var junctionPixelCount: Int64
    public var starProtectedPixelCount: Int64
    public var seamStarCrossingCount: Int
    public var highFrequencyDualSourcePixelCount: Int64
    public var unexpectedTransparentPixelCount: Int64?
    public var evaluatedStarCount: Int
    public var doubleStarCandidateCount: Int
    public var doubleStarRatio: Double
    public var qualityEvaluatedCellCount: Int64?
    public var qualityComparedCellCount: Int64?
    public var qualitySingleCandidateCellCount: Int64?
    public var qualityFallbackCellCount: Int64?
    public var selectedStarRetentionMedian: Double?
    public var selectedStarRetentionP05: Double?
    public var ownerQualityRegretP95: Double?
    public var lowRetentionComponentCount: Int?
    public var largestLowRetentionComponentPixels: Int?
    public var ownerPixelCounts: [Int64]?
    public var coarseConnectedRegionCount: Int?
    public var tinyRegionAreaRatio: Double?
    public var coarseBoundaryPixelRatio: Double?
    public var junctionClusterCount: Int?
    public var detectedTransientComponentCount: Int?
    public var avoidedTransientPixelCount: Int64?
    public var unavoidableTransientPixelCount: Int64?
    public var selectedAvoidableTransientPixelCount: Int64?
    public var lowFrequencyDiscontinuityPixelCount: Int64?
    public var lowFrequencyDiscontinuityP99EV: Double?
    public var largestLowFrequencyDiscontinuitySpanPixels: Int?
    public var pairEdgeConstraintCount: Int64?
    public var pairEdgeResidualP95: Double?
    public var junctionResidualP95: Double?
    public var actualOwnerComparedCoarseCellCount: Int64?
    public var actualOwnerChangedCoarseCellCount: Int64?
    public var ownerLabelMapPath: String?
    public var seamBoundaryMapPath: String?
    public var transientRiskMapPath: String?
    public var selectedTransientRiskMapPath: String?
    public var starRetentionMapPath: String?
    public var qualityRegretMapPath: String?
    public var lowFrequencyDiscontinuityMapPath: String?
    public var pairEdgeResidualMapPath: String?
    public var offsetFieldMapPath: String?
    public var junctionResidualMapPath: String?
    public var actualOwnerLabelMapPath: String?

    enum CodingKeys: String, CodingKey {
        case engine
        case ownerSelectionMode = "owner_selection_mode"
        case seamFindingPrecision = "seam_finding_precision"
        case initialOwnerWidth = "initial_owner_width"
        case initialOwnerHeight = "initial_owner_height"
        case fullOwnerWidth = "full_owner_width"
        case fullOwnerHeight = "full_owner_height"
        case boundaryPixelCount = "boundary_pixel_count"
        case junctionPixelCount = "junction_pixel_count"
        case starProtectedPixelCount = "star_protected_pixel_count"
        case seamStarCrossingCount = "seam_star_crossing_count"
        case highFrequencyDualSourcePixelCount = "high_frequency_dual_source_pixel_count"
        case unexpectedTransparentPixelCount = "unexpected_transparent_pixel_count"
        case evaluatedStarCount = "evaluated_star_count"
        case doubleStarCandidateCount = "double_star_candidate_count"
        case doubleStarRatio = "double_star_ratio"
        case qualityEvaluatedCellCount = "quality_evaluated_cell_count"
        case qualityComparedCellCount = "quality_compared_cell_count"
        case qualitySingleCandidateCellCount = "quality_single_candidate_cell_count"
        case qualityFallbackCellCount = "quality_fallback_cell_count"
        case selectedStarRetentionMedian = "selected_star_retention_median"
        case selectedStarRetentionP05 = "selected_star_retention_p05"
        case ownerQualityRegretP95 = "owner_quality_regret_p95"
        case lowRetentionComponentCount = "low_retention_component_count"
        case largestLowRetentionComponentPixels = "largest_low_retention_component_pixels"
        case ownerPixelCounts = "owner_pixel_counts"
        case coarseConnectedRegionCount = "coarse_connected_region_count"
        case tinyRegionAreaRatio = "tiny_region_area_ratio"
        case coarseBoundaryPixelRatio = "coarse_boundary_pixel_ratio"
        case junctionClusterCount = "junction_cluster_count"
        case detectedTransientComponentCount = "detected_transient_component_count"
        case avoidedTransientPixelCount = "avoided_transient_pixel_count"
        case unavoidableTransientPixelCount = "unavoidable_transient_pixel_count"
        case selectedAvoidableTransientPixelCount = "selected_avoidable_transient_pixel_count"
        case lowFrequencyDiscontinuityPixelCount = "low_frequency_discontinuity_pixel_count"
        case lowFrequencyDiscontinuityP99EV = "low_frequency_discontinuity_p99_ev"
        case largestLowFrequencyDiscontinuitySpanPixels = "largest_low_frequency_discontinuity_span_pixels"
        case pairEdgeConstraintCount = "pair_edge_constraint_count"
        case pairEdgeResidualP95 = "pair_edge_residual_p95"
        case junctionResidualP95 = "junction_residual_p95"
        case actualOwnerComparedCoarseCellCount = "actual_owner_compared_coarse_cell_count"
        case actualOwnerChangedCoarseCellCount = "actual_owner_changed_coarse_cell_count"
        case ownerLabelMapPath = "owner_label_map_path"
        case seamBoundaryMapPath = "seam_boundary_map_path"
        case transientRiskMapPath = "transient_risk_map_path"
        case selectedTransientRiskMapPath = "selected_transient_risk_map_path"
        case starRetentionMapPath = "star_retention_map_path"
        case qualityRegretMapPath = "quality_regret_map_path"
        case lowFrequencyDiscontinuityMapPath = "low_frequency_discontinuity_map_path"
        case pairEdgeResidualMapPath = "pair_edge_residual_map_path"
        case offsetFieldMapPath = "offset_field_map_path"
        case junctionResidualMapPath = "junction_residual_map_path"
        case actualOwnerLabelMapPath = "actual_owner_label_map_path"
    }
}

public struct ImportedPanoramaRenderReport: Codable, Equatable, Sendable {
    public var success: Bool
    public var operation: String
    public var message: String
    public var outputPath: String?
    public var width: Int?
    public var height: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var renderer: String?
    public var sourceCount: Int?
    public var controlPointCount: Int?
    public var connectedPairCount: Int?
    public var elapsedSeconds: Double?
    public var ownershipMapWidth: Int?
    public var ownershipMapHeight: Int?
    public var gainEV: [[Double]]?
    public var gainObservationCount: Int?
    public var gainResidualRMSEV: [Double]?
    public var gainClampedCameraCount: [Int]?
    public var geometryRefinement: PTSGeometryRefinementReport?
    public var zeroOverlap: PTSZeroOverlapReport?
    public var diagnosticCropPaths: [String]?
    public var warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case success, operation, message
        case outputPath = "output_path"
        case width, height
        case bitDepth = "bit_depth"
        case channels, renderer
        case sourceCount = "source_count"
        case controlPointCount = "control_point_count"
        case connectedPairCount = "connected_pair_count"
        case elapsedSeconds = "elapsed_seconds"
        case ownershipMapWidth = "ownership_map_width"
        case ownershipMapHeight = "ownership_map_height"
        case gainEV = "gain_ev"
        case gainObservationCount = "gain_observation_count"
        case gainResidualRMSEV = "gain_residual_rms_ev"
        case gainClampedCameraCount = "gain_clamped_camera_count"
        case geometryRefinement = "geometry_refinement"
        case zeroOverlap = "zero_overlap"
        case diagnosticCropPaths = "diagnostic_crop_paths"
        case warnings
    }
}
