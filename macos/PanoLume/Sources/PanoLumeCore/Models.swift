import Foundation
import CoreGraphics

public struct PhotoAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var displayName: String
    public var width: Int
    public var height: Int
    public var originalWidth: Int
    public var originalHeight: Int
    public var nativeHandle: String?
    public var loadStatus: NativeImageStatus
    public var unsupportedReason: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensName: String?
    public var focalLengthMM: Double?
    public var apertureFNumber: Double?

    public init(id: UUID = UUID(), url: URL, width: Int = 0, height: Int = 0) {
        self.id = id
        self.url = url
        self.displayName = url.lastPathComponent
        self.width = width
        self.height = height
        self.originalWidth = width
        self.originalHeight = height
        self.nativeHandle = nil
        self.loadStatus = .notLoaded
        self.unsupportedReason = nil
        self.cameraMake = nil
        self.cameraModel = nil
        self.lensName = nil
        self.focalLengthMM = nil
        self.apertureFNumber = nil
    }
}

public enum NativeImageStatus: String, Codable, Equatable, Sendable {
    case notLoaded = "not_loaded"
    case loaded
    case unsupportedUntilLibraw = "unsupported_until_libraw"
    case loadFailed = "load_failed"
}

public struct NativeImageInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { handle }
    public var handle: String
    public var path: String
    public var width: Int
    public var height: Int
    public var originalWidth: Int?
    public var originalHeight: Int?
    public var channels: Int
    public var bitDepth: Int
    public var status: NativeImageStatus
    public var unsupportedReason: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensName: String?
    public var focalLengthMM: Double?
    public var apertureFNumber: Double?

    enum CodingKeys: String, CodingKey {
        case handle
        case path
        case width
        case height
        case originalWidth = "original_width"
        case originalHeight = "original_height"
        case channels
        case bitDepth = "bit_depth"
        case status
        case unsupportedReason = "unsupported_reason"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case lensName = "lens_name"
        case focalLengthMM = "focal_length_mm"
        case apertureFNumber = "aperture_f_number"
    }
}

public struct PixelBufferInfo: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int

    public init(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

/// Linear RGB values copied from the native image cache.  This is a regression
/// interface rather than a display API: callers receive the float samples that
/// entered native alignment/export before any display stretch or 8-bit packing.
public struct LinearPixelBufferInfo: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var channels: Int

    public init(data: Data, width: Int, height: Int, channels: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.channels = channels
    }
}

public struct StretchParams: Codable, Equatable, Sendable {
    public var black: Double
    public var white: Double
    public var gamma: Double

    public init(black: Double, white: Double, gamma: Double) {
        self.black = black
        self.white = white
        self.gamma = gamma
    }
}

public struct ImageLoadResult: Codable, Equatable, Sendable {
    public var success: Bool
    public var operation: String
    public var message: String
    public var images: [NativeImageInfo]
    public var diagnostics: JSONValue
}

public struct StitchSettings: Codable, Equatable, Sendable {
    public var projection: String
    public var blendMode: String
    public var alignmentMode: String
    public var astroGeometry: String
    public var astroSkyMode: String
    public var previewMaxSide: Int
    public var maxOutputPixels: Int
    public var maxOutputSide: Int
    public var rawHalfSize: Bool
    public var fullInputPreview: Bool
    public var displayStretch: Bool
    public var previewRendererBackend: String
    public var stretchStrength: Double
    public var stretchBlackPercentile: Double
    public var stretchWhitePercentile: Double
    public var stretchGamma: Double
    public var starThreshold: Double
    public var maxMatchStars: Int
    public var matchPixelTolerance: Double
    public var starTransformModel: String
    public var starCoverageMultiplier: Double
    public var starAdaptiveCoverage: Bool
    public var starAdaptiveCoverageMultiplier: Double
    public var starAdaptiveMinBBoxArea: Double
    public var starAdaptiveMinGridOccupancy: Double
    public var optimizeFocal: Bool
    public var optimizeDistortion: Bool
    public var optimizerMaxIterations: Int
    public var cameraModelMaxOptimizedRMSPx: Double
    public var cameraModelMaxSelectedPairP95Px: Double
    public var cameraModelMinHighConfidenceStars: Int
    public var cameraModelMaxHighConfidenceStarP95Px: Double
    public var cameraModelMaxMutualStarP95Px: Double
    public var cameraModelRobustReprojectionPx: Double
    public var cameraModelRobustMinPairInliers: Int
    public var cameraModelGuidedRefinement: Bool
    public var cameraModelGuidedMaxPointsPerPair: Int
    public var cameraModelLocalRefinement: Bool
    public var cameraModelLocalSearchPx: Double
    public var cameraModelLocalMaxPointsPerPair: Int
    public var cameraModelLocalEvidenceThreshold: Double
    public var cameraModelTextureRefinement: Bool
    public var cameraModelTextureMaxPointsPerPair: Int
    public var cameraModelTextureReprojectionPx: Double
    public var focalLengthGuess: Double?
    public var initialK1: Double
    public var initialK2: Double
    public var initialK3: Double
    public var lensProfilePath: String?
    public var lensProfileName: String?
    public var lensCalibrationPrior: LensCalibrationPrior?
    public var projectionDragEnabled: Bool
    public var blendAfterProjectionDrag: Bool

    public init() {
        projection = "equirectangular"
        blendMode = "feather"
        alignmentMode = "auto"
        astroGeometry = "auto"
        astroSkyMode = "auto_sky"
        previewMaxSide = 2400
        maxOutputPixels = 32_000_000
        maxOutputSide = 9000
        rawHalfSize = true
        fullInputPreview = false
        displayStretch = true
        previewRendererBackend = "auto"
        stretchStrength = 1.0
        stretchBlackPercentile = 0.5
        stretchWhitePercentile = 99.7
        stretchGamma = 0.45
        starThreshold = 5.0
        maxMatchStars = 350
        matchPixelTolerance = 5.0
        starTransformModel = "similarity"
        starCoverageMultiplier = 2.0
        starAdaptiveCoverage = true
        starAdaptiveCoverageMultiplier = 6.0
        starAdaptiveMinBBoxArea = 0.12
        starAdaptiveMinGridOccupancy = 0.30
        optimizeFocal = true
        optimizeDistortion = false
        optimizerMaxIterations = 200
        cameraModelMaxOptimizedRMSPx = 5.0
        cameraModelMaxSelectedPairP95Px = 8.0
        cameraModelMinHighConfidenceStars = 40
        cameraModelMaxHighConfidenceStarP95Px = 4.0
        cameraModelMaxMutualStarP95Px = 12.0
        cameraModelRobustReprojectionPx = 5.0
        cameraModelRobustMinPairInliers = 5
        cameraModelGuidedRefinement = true
        cameraModelGuidedMaxPointsPerPair = 64
        cameraModelLocalRefinement = true
        cameraModelLocalSearchPx = 12.0
        cameraModelLocalMaxPointsPerPair = 36
        cameraModelLocalEvidenceThreshold = 0.48
        cameraModelTextureRefinement = true
        cameraModelTextureMaxPointsPerPair = 48
        cameraModelTextureReprojectionPx = 8.0
        focalLengthGuess = nil
        initialK1 = 0.0
        initialK2 = 0.0
        initialK3 = 0.0
        lensProfilePath = nil
        lensProfileName = nil
        lensCalibrationPrior = nil
        projectionDragEnabled = false
        blendAfterProjectionDrag = true
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var maxOutputPixels: Int
    public var maxOutputSide: Int
    public var rendererBackend: String
    public var bitDepth: Int
    public var applyPreviewStretch: Bool
    public var stretchStrength: Double
    public var stretchBlackPercentile: Double
    public var stretchWhitePercentile: Double
    public var stretchGamma: Double
    /// Zero selects the engine's automatic bounded working-set budget.
    public var workingSetBudgetMB: Int

    public init(
        maxOutputPixels: Int = 0,
        maxOutputSide: Int = 0,
        rendererBackend: String = "auto",
        bitDepth: Int = 16,
        applyPreviewStretch: Bool = false,
        stretchStrength: Double = 0.0,
        stretchBlackPercentile: Double = 0.5,
        stretchWhitePercentile: Double = 99.7,
        stretchGamma: Double = 0.45,
        workingSetBudgetMB: Int = 0
    ) {
        self.maxOutputPixels = maxOutputPixels
        self.maxOutputSide = maxOutputSide
        self.rendererBackend = rendererBackend
        self.bitDepth = bitDepth
        self.applyPreviewStretch = applyPreviewStretch
        self.stretchStrength = stretchStrength
        self.stretchBlackPercentile = stretchBlackPercentile
        self.stretchWhitePercentile = stretchWhitePercentile
        self.stretchGamma = stretchGamma
        self.workingSetBudgetMB = max(0, workingSetBudgetMB)
    }

    enum CodingKeys: String, CodingKey {
        case maxOutputPixels, maxOutputSide, rendererBackend, bitDepth
        case applyPreviewStretch, stretchStrength, stretchBlackPercentile
        case stretchWhitePercentile, stretchGamma, workingSetBudgetMB
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxOutputPixels = try values.decode(Int.self, forKey: .maxOutputPixels)
        maxOutputSide = try values.decode(Int.self, forKey: .maxOutputSide)
        rendererBackend = try values.decode(String.self, forKey: .rendererBackend)
        bitDepth = try values.decode(Int.self, forKey: .bitDepth)
        applyPreviewStretch = try values.decode(Bool.self, forKey: .applyPreviewStretch)
        stretchStrength = try values.decode(Double.self, forKey: .stretchStrength)
        stretchBlackPercentile = try values.decode(Double.self, forKey: .stretchBlackPercentile)
        stretchWhitePercentile = try values.decode(Double.self, forKey: .stretchWhitePercentile)
        stretchGamma = try values.decode(Double.self, forKey: .stretchGamma)
        workingSetBudgetMB = max(0, try values.decodeIfPresent(Int.self, forKey: .workingSetBudgetMB) ?? 0)
    }
}

public struct WorkingSetBudget: Codable, Equatable, Sendable {
    public var requestedMB: Int
    public var effectiveMB: Int
    public var isAutomatic: Bool

    public init(requestedMB: Int, effectiveMB: Int, isAutomatic: Bool) {
        self.requestedMB = max(0, requestedMB)
        self.effectiveMB = max(1, effectiveMB)
        self.isAutomatic = isAutomatic
    }
}

/// PanoLume-owned discrete ownership contract. Zero is always unowned and
/// source identifiers are one-based so no sentinel overlaps a valid source.
public struct SourceOwnershipMap: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var sourceCount: Int
    public var pixels: [UInt16]

    public init(width: Int, height: Int, sourceCount: Int, pixels: [UInt16]) throws {
        guard width > 0, height > 0, width <= Int.max / height, sourceCount > 0,
              pixels.count == width * height,
              sourceCount <= Int(UInt16.max),
              pixels.allSatisfy({ $0 == 0 || Int($0) <= sourceCount }) else {
            throw SourceOwnershipMapError.invalidContract
        }
        self.width = width
        self.height = height
        self.sourceCount = sourceCount
        self.pixels = pixels
    }

    public func owner(x: Int, y: Int) -> UInt16? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return pixels[y * width + x]
    }
}

public enum SourceOwnershipMapError: Error, Equatable, Sendable {
    case invalidContract
}

/// Operation-scoped export telemetry. `peakMemoryMB` remains the historical
/// process-lifetime high-water mark; the operation fields are sampled only
/// while the current export is active.
public struct WorkingSetStats: Codable, Equatable, Sendable {
    public var operationStartRSSMB: Double?
    public var operationPeakRSSMB: Double?
    public var operationPeakRSSDeltaMB: Double?
    public var spoolBytesPeak: UInt64
    public var mappedSourceBytesPeak: UInt64
    public var activeSourceLeasesPeak: UInt64
    public var sourceCacheHits: UInt64
    public var sourceCacheMisses: UInt64
    public var cleanupOutcome: String

    enum CodingKeys: String, CodingKey {
        case operationStartRSSMB = "operation_start_rss_mb"
        case operationPeakRSSMB = "operation_peak_rss_mb"
        case operationPeakRSSDeltaMB = "operation_peak_rss_delta_mb"
        case spoolBytesPeak = "spool_bytes_peak"
        case mappedSourceBytesPeak = "mapped_source_bytes_peak"
        case activeSourceLeasesPeak = "active_source_leases_peak"
        case sourceCacheHits = "source_cache_hits"
        case sourceCacheMisses = "source_cache_misses"
        case cleanupOutcome = "cleanup_outcome"
    }

    public init(
        operationStartRSSMB: Double? = nil,
        operationPeakRSSMB: Double? = nil,
        operationPeakRSSDeltaMB: Double? = nil,
        spoolBytesPeak: UInt64 = 0,
        mappedSourceBytesPeak: UInt64 = 0,
        activeSourceLeasesPeak: UInt64 = 0,
        sourceCacheHits: UInt64 = 0,
        sourceCacheMisses: UInt64 = 0,
        cleanupOutcome: String = "not_required"
    ) {
        self.operationStartRSSMB = operationStartRSSMB
        self.operationPeakRSSMB = operationPeakRSSMB
        self.operationPeakRSSDeltaMB = operationPeakRSSDeltaMB
        self.spoolBytesPeak = spoolBytesPeak
        self.mappedSourceBytesPeak = mappedSourceBytesPeak
        self.activeSourceLeasesPeak = activeSourceLeasesPeak
        self.sourceCacheHits = sourceCacheHits
        self.sourceCacheMisses = sourceCacheMisses
        self.cleanupOutcome = cleanupOutcome
    }
}

public struct CameraParams: Codable, Equatable, Sendable {
    public var rotation: [Double]
    public var translation: [Double]
    public var focalLength: Double
    public var k1: Double
    public var k2: Double
    public var k3: Double
    public var p1: Double
    public var p2: Double
    public var principalOffsetX: Double
    public var principalOffsetY: Double

    public init(
        rotation: [Double],
        translation: [Double],
        focalLength: Double,
        k1: Double,
        k2: Double,
        k3: Double,
        p1: Double,
        p2: Double,
        principalOffsetX: Double = 0,
        principalOffsetY: Double = 0
    ) {
        self.rotation = rotation
        self.translation = translation
        self.focalLength = focalLength
        self.k1 = k1
        self.k2 = k2
        self.k3 = k3
        self.p1 = p1
        self.p2 = p2
        self.principalOffsetX = principalOffsetX
        self.principalOffsetY = principalOffsetY
    }

    enum CodingKeys: String, CodingKey {
        case rotation, translation, focalLength, k1, k2, k3, p1, p2
        case principalOffsetX, principalOffsetY
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try values.decode([Double].self, forKey: .rotation)
        translation = try values.decode([Double].self, forKey: .translation)
        focalLength = try values.decode(Double.self, forKey: .focalLength)
        k1 = try values.decode(Double.self, forKey: .k1)
        k2 = try values.decode(Double.self, forKey: .k2)
        k3 = try values.decode(Double.self, forKey: .k3)
        p1 = try values.decode(Double.self, forKey: .p1)
        p2 = try values.decode(Double.self, forKey: .p2)
        principalOffsetX = try values.decodeIfPresent(Double.self, forKey: .principalOffsetX) ?? 0
        principalOffsetY = try values.decodeIfPresent(Double.self, forKey: .principalOffsetY) ?? 0
    }
}

public struct ControlPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var imageAIndex: Int
    public var imageBIndex: Int
    public var xA: Double
    public var yA: Double
    public var xB: Double
    public var yB: Double
    public var error: Double
    public var isManual: Bool

    public init(
        id: UUID = UUID(),
        imageAIndex: Int,
        imageBIndex: Int,
        xA: Double,
        yA: Double,
        xB: Double,
        yB: Double,
        error: Double = 0.0,
        isManual: Bool = false
    ) {
        self.id = id
        self.imageAIndex = imageAIndex
        self.imageBIndex = imageBIndex
        self.xA = xA
        self.yA = yA
        self.xB = xB
        self.yB = yB
        self.error = error
        self.isManual = isManual
    }
}

public struct PanoramaInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var bitDepth: Int

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case channels
        case bitDepth = "bit_depth"
    }

    public init(width: Int, height: Int, channels: Int, bitDepth: Int) {
        self.width = width
        self.height = height
        self.channels = channels
        self.bitDepth = bitDepth
    }
}

public struct ResultSourceImage: Codable, Equatable, Sendable {
    public var handle: String?
    public var path: String
    public var width: Int
    public var height: Int
    public var originalWidth: Int? = nil
    public var originalHeight: Int? = nil
    public var channels: Int?
    public var bitDepth: Int?
    public var status: NativeImageStatus?
    public var unsupportedReason: String?

    enum CodingKeys: String, CodingKey {
        case handle
        case path
        case width
        case height
        case originalWidth = "original_width"
        case originalHeight = "original_height"
        case channels
        case bitDepth = "bit_depth"
        case status
        case unsupportedReason = "unsupported_reason"
    }
}

public struct ProjectionCanvasInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rawWidth: Int
    public var rawHeight: Int
    public var minU: Double
    public var minV: Double
    public var maxU: Double
    public var maxV: Double
    public var projectionScale: Double

    enum CodingKeys: String, CodingKey {
        case width, height
        case rawWidth = "raw_width"
        case rawHeight = "raw_height"
        case minU = "min_u"
        case minV = "min_v"
        case maxU = "max_u"
        case maxV = "max_v"
        case projectionScale = "projection_scale"
    }
}

public enum ProjectionGeometryState: String, Codable, Equatable, Sendable {
    case verifiedCamera = "verified_camera"
    case unverifiedCameraDraft = "unverified_camera_draft"
    case homographyDiagnostic = "homography_diagnostic"
}

public enum AstroRefinementState: String, Codable, Equatable, Sendable {
    case notRequired = "not_required"
    case draftHeldOutValidation = "draft_heldout_validation"
    case draftPendingFullResolution = "draft_pending_full_resolution"
    case refiningFullResolution = "refining_full_resolution"
    case passed
    case failed
    case cancelled
}

public struct AstroRiskGridCell: Codable, Equatable, Sendable {
    public var column: Int
    public var row: Int
    public var count: Int
    public var p95: Double?
    public var mappedFWHM: Double?
    public var riskRatio: Double?
    public var effective: Bool?

    enum CodingKeys: String, CodingKey {
        case column, row, count, effective
        case p95 = "p95_px"
        case mappedFWHM = "mapped_fwhm_px"
        case riskRatio = "risk_ratio"
    }
}

public struct HeldOutIdentityAudit: Codable, Equatable, Sendable {
    public var candidates: Int
    public var accepted: Int
    public var rejectedDescriptor: Int
    public var rejectedPatch: Int
    public var rejectedFWHM: Int
    public var rejectedFlux: Int
    public var rejectedRatio: Int
    public var rejectedConflict: Int
    public var rejectedPrediction: Int
    public var rejectedBoundary: Int
    public var rejectedField: Int?
    public var fieldCutoff: Double?
    public var fieldMedian: Double?
    public var fieldP95: Double?

    enum CodingKeys: String, CodingKey {
        case candidates, accepted
        case rejectedDescriptor = "rejected_descriptor"
        case rejectedPatch = "rejected_patch"
        case rejectedFWHM = "rejected_fwhm"
        case rejectedFlux = "rejected_flux"
        case rejectedRatio = "rejected_ratio"
        case rejectedConflict = "rejected_conflict"
        case rejectedPrediction = "rejected_prediction"
        case rejectedBoundary = "rejected_boundary"
        case rejectedField = "rejected_field"
        case fieldCutoff = "field_cutoff_px"
        case fieldMedian = "field_median_px"
        case fieldP95 = "field_p95_px"
    }
}

public struct AstroResidualDirectionBucket: Codable, Equatable, Sendable {
    public var band: String
    public var count: Int
    public var radialP95: Double?
    public var tangentialP95: Double?

    enum CodingKeys: String, CodingKey {
        case band, count
        case radialP95 = "radial_p95_px"
        case tangentialP95 = "tangential_p95_px"
    }
}

public struct WorstAstroObservation: Codable, Equatable, Sendable {
    public var error: Double?
    public var mappedFWHM: Double?
    public var sourceX: Double?
    public var sourceY: Double?
    public var targetX: Double?
    public var targetY: Double?
    public var sourcePSFSignalToNoise: Double?
    public var targetPSFSignalToNoise: Double?
    public var sourcePSFNormalizedRMS: Double?
    public var targetPSFNormalizedRMS: Double?
    public var identityAssociationResidual: Double?
    public var patchSide: Int?
    public var sourcePatchDataURL: String?
    public var targetPatchDataURL: String?

    enum CodingKeys: String, CodingKey {
        case error = "error_px"
        case mappedFWHM = "mapped_fwhm_px"
        case sourceX = "source_x"
        case sourceY = "source_y"
        case targetX = "target_x"
        case targetY = "target_y"
        case sourcePSFSignalToNoise = "source_psf_snr"
        case targetPSFSignalToNoise = "target_psf_snr"
        case sourcePSFNormalizedRMS = "source_psf_normalized_rms"
        case targetPSFNormalizedRMS = "target_psf_normalized_rms"
        case identityAssociationResidual = "identity_association_residual_px"
        case patchSide = "patch_side"
        case sourcePatchDataURL = "source_patch_data_url"
        case targetPatchDataURL = "target_patch_data_url"
    }
}

public struct HeldOutPairReport: Codable, Equatable, Sendable {
    public var i: Int
    public var j: Int
    public var count: Int
    public var occupiedCells: Int
    public var effectiveCells: Int?
    public var lowSupportCells: Int?
    public var p95: Double?
    public var mappedFWHM: Double?
    public var pairRiskRatio: Double?
    public var worstGridRiskRatio: Double?
    public var passed: Bool
    public var reason: String
    public var grids: [AstroRiskGridCell]
    public var identityAudit: HeldOutIdentityAudit?
    public var residualDirectionBuckets: [AstroResidualDirectionBucket]?
    public var worstObservations: [WorstAstroObservation]?

    enum CodingKeys: String, CodingKey {
        case i, j, count, passed, reason, grids
        case identityAudit = "identity_audit"
        case residualDirectionBuckets = "residual_direction_buckets"
        case worstObservations = "worst_observations"
        case occupiedCells = "occupied_cells"
        case effectiveCells = "effective_cells"
        case lowSupportCells = "low_support_cells"
        case p95 = "p95_px"
        case mappedFWHM = "mapped_fwhm_px"
        case pairRiskRatio = "pair_risk_ratio"
        case worstGridRiskRatio = "worst_grid_risk_ratio"
    }
}

public struct AstroPSFFitAudit: Codable, Equatable, Sendable {
    public var imageIndex: Int
    public var preliminaryCandidates: Int
    public var selectedForFit: Int
    public var accepted: Int
    public var signalToNoiseP05: Double?
    public var signalToNoiseMedian: Double?
    public var normalizedRMSMedian: Double?
    public var normalizedRMSP95: Double?
    public var rejectedReasons: [String: Int]

    enum CodingKeys: String, CodingKey {
        case accepted
        case imageIndex = "image_index"
        case preliminaryCandidates = "preliminary_candidates"
        case selectedForFit = "selected_for_fit"
        case signalToNoiseP05 = "signal_to_noise_p05"
        case signalToNoiseMedian = "signal_to_noise_median"
        case normalizedRMSMedian = "normalized_rms_median"
        case normalizedRMSP95 = "normalized_rms_p95"
        case rejectedReasons = "rejected_reasons"
    }
}

public struct LensModelCandidateReport: Codable, Equatable, Sendable {
    public var model: String
    public var solverSucceeded: Bool
    public var accepted: Bool
    public var worstPairP95: Double?
    public var worstGridRiskRatio: Double?
    public var heldOutImprovement: Double?
    public var validationImprovement: Double?
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case model, accepted, reason
        case solverSucceeded = "solver_succeeded"
        case worstPairP95 = "worst_pair_p95_px"
        case worstGridRiskRatio = "worst_grid_risk_ratio"
        case heldOutImprovement = "held_out_improvement"
        case validationImprovement = "validation_improvement"
    }
}

public struct AstroPartitionCounts: Codable, Equatable, Sendable {
    public var fit: Int
    public var validation: Int
    public var finalHeldOut: Int

    enum CodingKeys: String, CodingKey {
        case fit, validation
        case finalHeldOut = "final_held_out"
    }
}

public struct AppliedLensCalibrationPrior: Codable, Equatable, Sendable {
    public var available: Bool
    public var required: Bool
    public var sha256: String
    public var weight: Double?
    public var conversionMaxErrorPixels: Double?
    public var warning: String

    enum CodingKeys: String, CodingKey {
        case available, required, sha256, weight, warning
        case conversionMaxErrorPixels = "conversion_max_error_px"
    }
}

public struct LocalWarpReport: Codable, Equatable, Sendable {
    public var attempted: Bool
    public var solverSucceeded: Bool
    public var accepted: Bool
    public var observations: Int
    public var maxNormalizedDisplacement: Double?
    public var minimumJacobianDeterminant: Double?
    public var amplitudeRegularization: Double?
    public var firstDifferenceRegularization: Double?
    public var curvatureRegularization: Double?
    public var worstPairImprovement: Double?
    public var worstGridImprovement: Double?
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case attempted, accepted, observations, reason
        case solverSucceeded = "solver_succeeded"
        case maxNormalizedDisplacement = "max_normalized_displacement"
        case minimumJacobianDeterminant = "minimum_jacobian_determinant"
        case amplitudeRegularization = "amplitude_regularization"
        case firstDifferenceRegularization = "first_difference_regularization"
        case curvatureRegularization = "curvature_regularization"
        case worstPairImprovement = "worst_pair_improvement"
        case worstGridImprovement = "worst_grid_improvement"
    }
}

public struct LocalWarpImageModel: Codable, Equatable, Sendable {
    public var dx: [Double]
    public var dy: [Double]
}

public struct LocalWarpModel: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var referenceImage: Int
    public var images: [LocalWarpImageModel]

    enum CodingKeys: String, CodingKey {
        case columns, rows, images
        case referenceImage = "reference_image"
    }
}

public struct AstroRefinementInfo: Codable, Equatable, Sendable {
    public var state: AstroRefinementState
    public var qualityGatePassed: Bool
    public var reason: String
    public var lensModel: String
    public var gridColumns: Int
    public var gridRows: Int
    public var pairs: [HeldOutPairReport]
    public var lensModels: [LensModelCandidateReport]
    public var localWarp: LocalWarpReport?
    public var evaluationPartition: String?
    public var residualFrame: String?
    public var partitionCounts: AstroPartitionCounts?
    public var lensCalibrationPrior: AppliedLensCalibrationPrior?
    public var psfFits: [AstroPSFFitAudit]?

    enum CodingKeys: String, CodingKey {
        case state, reason, pairs
        case qualityGatePassed = "quality_gate_passed"
        case lensModel = "lens_model"
        case gridColumns = "grid_columns"
        case gridRows = "grid_rows"
        case lensModels = "lens_models"
        case localWarp = "local_warp"
        case evaluationPartition = "evaluation_partition"
        case residualFrame = "residual_frame"
        case partitionCounts = "partition_counts"
        case lensCalibrationPrior = "lens_calibration_prior"
        case psfFits = "psf_fits"
    }
}

public struct StitchResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String { handle }
    public var handle: String
    public var projection: String
    public var projectionGeometryState: ProjectionGeometryState?
    public var geometryQualityGatePassed: Bool?
    public var panorama: PanoramaInfo
    public var cameraParams: [CameraParams]
    public var localWarp: LocalWarpModel?
    public var controlPoints: [ControlPoint]
    public var sourceImages: [ResultSourceImage]
    public var diagnostics: JSONValue
    public var projectionCanvas: ProjectionCanvasInfo?
    public var astroRefinement: AstroRefinementInfo?

    enum CodingKeys: String, CodingKey {
        case handle
        case projection
        case projectionGeometryState = "projection_geometry_state"
        case geometryQualityGatePassed = "geometry_quality_gate_passed"
        case panorama
        case cameraParams = "camera_params"
        case localWarp = "local_warp"
        case controlPoints = "control_points"
        case sourceImages = "source_images"
        case diagnostics
        case projectionCanvas = "projection_canvas"
        case astroRefinement = "astro_refinement"
    }

    public init(
        handle: String,
        projection: String,
        projectionGeometryState: ProjectionGeometryState? = nil,
        geometryQualityGatePassed: Bool? = nil,
        panorama: PanoramaInfo,
        cameraParams: [CameraParams],
        localWarp: LocalWarpModel? = nil,
        controlPoints: [ControlPoint],
        sourceImages: [ResultSourceImage],
        diagnostics: JSONValue,
        projectionCanvas: ProjectionCanvasInfo? = nil,
        astroRefinement: AstroRefinementInfo? = nil
    ) {
        self.handle = handle
        self.projection = projection
        self.projectionGeometryState = projectionGeometryState
        self.geometryQualityGatePassed = geometryQualityGatePassed
        self.panorama = panorama
        self.cameraParams = cameraParams
        self.localWarp = localWarp
        self.controlPoints = controlPoints
        self.sourceImages = sourceImages
        self.diagnostics = diagnostics
        self.projectionCanvas = projectionCanvas
        self.astroRefinement = astroRefinement
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public var root: JSONValue

    public init(root: JSONValue) {
        self.root = root
    }
}

public struct ProgressEvent: Codable, Equatable, Sendable {
    public var stage: String
    public var fraction: Double

    public init(stage: String, fraction: Double) {
        self.stage = stage
        self.fraction = max(0.0, min(1.0, fraction))
    }
}

public enum RenderJobState: Codable, Equatable, Sendable {
    case idle
    case running(String, Double)
    case completed(String)
    case failed(String)
}

public struct PoseAdjustment: Codable, Equatable, Sendable {
    public var pitchDegrees: Double
    public var yawDegrees: Double
    public var rollDegrees: Double

    public init(pitchDegrees: Double = 0, yawDegrees: Double = 0, rollDegrees: Double = 0) {
        self.pitchDegrees = pitchDegrees
        self.yawDegrees = yawDegrees
        self.rollDegrees = rollDegrees
    }
}

public extension PoseAdjustment {
    static let zero = PoseAdjustment()

    var isZero: Bool {
        abs(pitchDegrees) < 1e-9 && abs(yawDegrees) < 1e-9 && abs(rollDegrees) < 1e-9
    }
}

public enum RenderQuality: String, Codable, Equatable, Sendable {
    case dragPreview
    case committedPreview
    case geometryCommit
    case export
}

/// A temporary display transform used while the serialized native projection
/// renderer catches up with pointer movement. The transform is relative to the
/// last native frame accepted by the workbench and never changes export
/// geometry on its own.
public struct ProjectionVisualFeedback: Equatable, Sendable {
    public var translation: CGSize
    public var rotationDegrees: Double

    public init(translation: CGSize = CGSize(width: 0, height: 0), rotationDegrees: Double = 0) {
        self.translation = translation
        self.rotationDegrees = rotationDegrees
    }

    public static let zero = ProjectionVisualFeedback()

    public var isZero: Bool {
        abs(translation.width) < 0.001
            && abs(translation.height) < 0.001
            && abs(rotationDegrees) < 0.001
    }

    public static func == (lhs: ProjectionVisualFeedback, rhs: ProjectionVisualFeedback) -> Bool {
        lhs.translation.width == rhs.translation.width
            && lhs.translation.height == rhs.translation.height
            && lhs.rotationDegrees == rhs.rotationDegrees
    }
}

public struct EngineOperationResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var operation: String
    public var message: String
    public var result: StitchResult?
}
