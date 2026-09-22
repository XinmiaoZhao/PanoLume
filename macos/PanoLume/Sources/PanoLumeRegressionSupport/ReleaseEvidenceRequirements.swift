import Foundation

public struct ReleaseDragEvidence: Equatable, Sendable {
    public var artifact: String?
    public var caseID: String?
    public var imageCount: Int?
    public var inputCount: Int?
    public var success: Bool
    public var blendAfterDrag: Bool?
    public var commitQuality: String?
    public var medianLatencyMS: Double?
    public var p95LatencyMS: Double?
    public var maxLatencyMS: Double?
    public var commitLatencyMS: Double?
    public var commitLatencyGatePassed: Bool?
    public var dragPreviewWidth: Int?
    public var dragPreviewHeight: Int?
    public var committedWidth: Int?
    public var committedHeight: Int?
    public var dimensionGatePassed: Bool
    public var dragFrameChanged: Bool
    public var geometryPersisted: Bool
    public var committedPixelsChanged: Bool
    public var committedPixelsRetained: Bool
    public var independentCommitPassed: Bool
    public var independentCommitSSIM: Double?
    public var committedRendererPassed: Bool

    public init(
        artifact: String? = "projection-drag-smoke",
        caseID: String?,
        imageCount: Int?,
        inputCount: Int?,
        success: Bool = true,
        blendAfterDrag: Bool?,
        commitQuality: String?,
        medianLatencyMS: Double? = 40,
        p95LatencyMS: Double? = 70,
        maxLatencyMS: Double? = 100,
        commitLatencyMS: Double? = 50,
        commitLatencyGatePassed: Bool? = true,
        dragPreviewWidth: Int? = 900,
        dragPreviewHeight: Int? = 500,
        committedWidth: Int? = 1_800,
        committedHeight: Int? = 1_000,
        dimensionGatePassed: Bool = true,
        dragFrameChanged: Bool = true,
        geometryPersisted: Bool = true,
        committedPixelsChanged: Bool = true,
        committedPixelsRetained: Bool = true,
        independentCommitPassed: Bool = true,
        independentCommitSSIM: Double? = 1,
        committedRendererPassed: Bool = true
    ) {
        self.artifact = artifact
        self.caseID = caseID
        self.imageCount = imageCount
        self.inputCount = inputCount
        self.success = success
        self.blendAfterDrag = blendAfterDrag
        self.commitQuality = commitQuality
        self.medianLatencyMS = medianLatencyMS
        self.p95LatencyMS = p95LatencyMS
        self.maxLatencyMS = maxLatencyMS
        self.commitLatencyMS = commitLatencyMS
        self.commitLatencyGatePassed = commitLatencyGatePassed
        self.dragPreviewWidth = dragPreviewWidth
        self.dragPreviewHeight = dragPreviewHeight
        self.committedWidth = committedWidth
        self.committedHeight = committedHeight
        self.dimensionGatePassed = dimensionGatePassed
        self.dragFrameChanged = dragFrameChanged
        self.geometryPersisted = geometryPersisted
        self.committedPixelsChanged = committedPixelsChanged
        self.committedPixelsRetained = committedPixelsRetained
        self.independentCommitPassed = independentCommitPassed
        self.independentCommitSSIM = independentCommitSSIM
        self.committedRendererPassed = committedRendererPassed
    }
}

public struct ReleaseCancellationEvidence: Equatable, Sendable {
    public var artifact: String?
    public var caseID: String?
    public var operation: String?
    public var imageCount: Int?
    public var inputCount: Int?
    public var passed: Bool
    public var partialOutputExists: Bool?

    public init(
        artifact: String? = "cancellation-smoke",
        operation: String?,
        caseID: String? = nil,
        imageCount: Int? = 3,
        inputCount: Int? = 3,
        passed: Bool = true,
        partialOutputExists: Bool? = false
    ) {
        self.artifact = artifact
        self.operation = operation
        self.caseID = caseID ?? operation
        self.imageCount = imageCount
        self.inputCount = inputCount
        self.passed = passed
        self.partialOutputExists = partialOutputExists
    }
}

public struct ReleaseStandardImageEvidence: Equatable, Sendable {
    public var artifact: String?
    public var caseID: String?
    public var imageCount: Int?
    public var passed: Bool
    public var geometry: String?
    public var cameraModelAttempted: Bool?
    public var worstPairP95: Double?
    public var maskedSSIM: Double?
    public var previewSeconds: Double?

    public init(
        artifact: String? = "standard-image-regression",
        caseID: String?,
        imageCount: Int?,
        passed: Bool = true,
        geometry: String? = "homography",
        cameraModelAttempted: Bool? = false,
        worstPairP95: Double? = 0.25,
        maskedSSIM: Double? = 0.999,
        previewSeconds: Double? = 10
    ) {
        self.artifact = artifact
        self.caseID = caseID
        self.imageCount = imageCount
        self.passed = passed
        self.geometry = geometry
        self.cameraModelAttempted = cameraModelAttempted
        self.worstPairP95 = worstPairP95
        self.maskedSSIM = maskedSSIM
        self.previewSeconds = previewSeconds
    }
}

public struct ReleaseControlPointEvidence: Equatable, Sendable {
    public var artifact: String?
    public var caseID: String?
    public var imageCount: Int?
    public var success: Bool
    public var testKind: String?
    public var originalGeometry: String?
    public var rerenderedGeometry: String?
    public var manualPointAccountingPassed: Bool?
    public var manualPointRoundTripPassed: Bool?
    public var explicitDisconnectedError: Bool?

    public init(
        artifact: String? = "control-point-rerender",
        caseID: String?,
        imageCount: Int?,
        success: Bool = true,
        testKind: String?,
        originalGeometry: String? = nil,
        rerenderedGeometry: String? = nil,
        manualPointAccountingPassed: Bool? = nil,
        manualPointRoundTripPassed: Bool? = nil,
        explicitDisconnectedError: Bool? = nil
    ) {
        self.artifact = artifact
        self.caseID = caseID
        self.imageCount = imageCount
        self.success = success
        self.testKind = testKind
        self.originalGeometry = originalGeometry
        self.rerenderedGeometry = rerenderedGeometry
        self.manualPointAccountingPassed = manualPointAccountingPassed
        self.manualPointRoundTripPassed = manualPointRoundTripPassed
        self.explicitDisconnectedError = explicitDisconnectedError
    }
}

public struct ReleaseRequiredEvidenceValidation: Equatable, Sendable {
    public var dragPassed: Bool
    public var cancellationPassed: Bool
    public var standardImagesPassed: Bool
    public var controlPointsPassed: Bool
    public var failures: [String]

    public var passed: Bool {
        dragPassed && cancellationPassed && standardImagesPassed && controlPointsPassed
    }
}

/// Legacy parity-matrix validator retained only so archived diagnostic reports
/// remain readable. PanoLume promotion uses CandidateReleaseReportIntegrity's
/// focused-risk schema and never calls this validator.
// Retained only to decode and inspect historical schema-v2 reports. Current
// validation and promotion call the focused PanoLume schema directly.
public enum ReleaseRequiredEvidenceValidator {
    private static let dragImageCounts = ["3raw": 3, "4raw": 4, "7raw": 7]
    private static let requiredBlendOn = Set(["3raw", "4raw", "7raw"])
    private static let requiredCancellation = Set(["preview", "drag", "export"])
    private static let requiredStandardImages = Set(["synthetic-crops", "test_1_parts"])
    private static let requiredControlPoints = Set(["camera-reopt", "homography-reopt", "disconnected"])

    public static func validate(
        drag: [ReleaseDragEvidence],
        cancellation: [ReleaseCancellationEvidence],
        standardImages: [ReleaseStandardImageEvidence],
        controlPoints: [ReleaseControlPointEvidence]
    ) -> ReleaseRequiredEvidenceValidation {
        var dragFailures: [String] = []
        var cancellationFailures: [String] = []
        var standardFailures: [String] = []
        var controlPointFailures: [String] = []

        validateDrag(drag, failures: &dragFailures)
        validateCancellation(cancellation, failures: &cancellationFailures)
        validateStandardImages(standardImages, failures: &standardFailures)
        validateControlPoints(controlPoints, failures: &controlPointFailures)

        return ReleaseRequiredEvidenceValidation(
            dragPassed: dragFailures.isEmpty,
            cancellationPassed: cancellationFailures.isEmpty,
            standardImagesPassed: standardFailures.isEmpty,
            controlPointsPassed: controlPointFailures.isEmpty,
            failures: dragFailures + cancellationFailures + standardFailures + controlPointFailures
        )
    }

    private static func validateDrag(
        _ reports: [ReleaseDragEvidence],
        failures: inout [String]
    ) {
        var observed = Set<String>()
        for (index, report) in reports.enumerated() {
            let label = "drag report #\(index + 1)"
            guard report.artifact == "projection-drag-smoke" else {
                failures.append("\(label) is not a projection-drag-smoke artifact")
                continue
            }
            guard let caseID = report.caseID,
                  let expectedImages = dragImageCounts[caseID],
                  let blendAfterDrag = report.blendAfterDrag else {
                failures.append("\(label) lacks a valid case_id or blend_after_drag mode")
                continue
            }
            guard report.imageCount == expectedImages,
                  report.inputCount == expectedImages else {
                failures.append("\(label) case \(caseID) must bind image_count and input_count to \(expectedImages)")
                continue
            }
            let mode = blendAfterDrag ? "blend-on" : "geometry-only"
            let key = "\(caseID)/\(mode)"
            if !observed.insert(key).inserted {
                failures.append("drag evidence contains duplicate case \(key)")
            }
            let dimensionsValid = (report.dragPreviewWidth ?? 0) > 0
                && (report.dragPreviewHeight ?? 0) > 0
                && (report.committedWidth ?? 0) > 0
                && (report.committedHeight ?? 0) > 0
                && (caseID != "7raw" || max(report.dragPreviewWidth ?? 0, report.dragPreviewHeight ?? 0) >= 720)
            let latencyValid = (report.medianLatencyMS ?? .infinity) <= 80
                && (report.p95LatencyMS ?? .infinity) <= 150
                && (report.maxLatencyMS ?? .infinity) <= 250
            let commitValid: Bool
            if blendAfterDrag {
                commitValid = report.commitQuality == "committedPreview"
                    && report.committedPixelsChanged
                    && report.independentCommitPassed
                    && (report.independentCommitSSIM ?? 0) >= 0.999
                    && report.committedRendererPassed
            } else {
                commitValid = report.commitQuality == "geometryCommit"
                    && report.committedPixelsRetained
                    && (report.commitLatencyMS ?? .infinity) <= 100
                    && report.commitLatencyGatePassed == true
            }
            if !report.success
                || !latencyValid
                || !dimensionsValid
                || !report.dimensionGatePassed
                || !report.dragFrameChanged
                || !report.geometryPersisted
                || !commitValid {
                failures.append("drag evidence \(key) does not meet latency, dimensions, geometry, and commit gates")
            }
        }
        for caseID in requiredBlendOn.sorted() where !observed.contains("\(caseID)/blend-on") {
            failures.append("drag evidence is missing required \(caseID)/blend-on")
        }
        if !observed.contains("7raw/geometry-only") {
            failures.append("drag evidence is missing required 7raw/geometry-only")
        }
    }

    private static func validateCancellation(
        _ reports: [ReleaseCancellationEvidence],
        failures: inout [String]
    ) {
        var observed = Set<String>()
        for (index, report) in reports.enumerated() {
            let label = "cancellation report #\(index + 1)"
            guard report.artifact == "cancellation-smoke",
                  let operation = report.operation,
                  requiredCancellation.contains(operation) else {
                failures.append("\(label) lacks a valid cancellation operation")
                continue
            }
            if !observed.insert(operation).inserted {
                failures.append("cancellation evidence contains duplicate operation \(operation)")
            }
            if report.caseID != operation
                || (report.imageCount ?? 0) < 2
                || report.imageCount != report.inputCount
                || !report.passed
                || report.partialOutputExists != false {
                failures.append("cancellation evidence \(operation) did not prove safe cancellation without partial output")
            }
        }
        for operation in requiredCancellation.sorted() where !observed.contains(operation) {
            failures.append("cancellation evidence is missing required operation \(operation)")
        }
    }

    private static func validateStandardImages(
        _ reports: [ReleaseStandardImageEvidence],
        failures: inout [String]
    ) {
        var observed = Set<String>()
        for (index, report) in reports.enumerated() {
            let label = "standard-image report #\(index + 1)"
            guard report.artifact == "standard-image-regression",
                  let caseID = report.caseID,
                  requiredStandardImages.contains(caseID) else {
                failures.append("\(label) lacks a valid standard-image case_id")
                continue
            }
            if !observed.insert(caseID).inserted {
                failures.append("standard-image evidence contains duplicate case \(caseID)")
            }
            let minimumSSIM = caseID == "synthetic-crops" ? 0.995 : 0.98
            let imageCountValid = caseID == "test_1_parts"
                ? report.imageCount == 8
                : (report.imageCount ?? 0) >= 2
            if !report.passed
                || !imageCountValid
                || report.geometry != "homography"
                || report.cameraModelAttempted != false
                || (report.worstPairP95 ?? .infinity) > 0.5
                || (report.maskedSSIM ?? -.infinity) < minimumSSIM
                || (report.previewSeconds ?? .infinity) > 30 {
                failures.append("standard-image evidence \(caseID) does not meet homography, P95, SSIM, image-count, and timing gates")
            }
        }
        for caseID in requiredStandardImages.sorted() where !observed.contains(caseID) {
            failures.append("standard-image evidence is missing required case \(caseID)")
        }
    }

    private static func validateControlPoints(
        _ reports: [ReleaseControlPointEvidence],
        failures: inout [String]
    ) {
        var observed = Set<String>()
        for (index, report) in reports.enumerated() {
            let label = "control-point report #\(index + 1)"
            guard report.artifact == "control-point-rerender",
                  let caseID = report.caseID,
                  requiredControlPoints.contains(caseID) else {
                failures.append("\(label) lacks a valid control-point case_id")
                continue
            }
            if !observed.insert(caseID).inserted {
                failures.append("control-point evidence contains duplicate case \(caseID)")
            }
            let expectedImageCount = caseID == "camera-reopt" ? 3 : 8
            guard report.success, report.imageCount == expectedImageCount else {
                failures.append("control-point evidence \(caseID) did not pass or lacks image_count")
                continue
            }
            if caseID == "disconnected" {
                if report.testKind != "disconnected"
                    || report.originalGeometry != "homography"
                    || report.explicitDisconnectedError != true {
                    failures.append("control-point evidence disconnected did not prove an explicit disconnected-graph error")
                }
                continue
            }
            let expectedGeometry = caseID == "camera-reopt" ? "camera" : "homography"
            if report.testKind != "reoptimize"
                || report.originalGeometry != expectedGeometry
                || report.rerenderedGeometry != expectedGeometry
                || report.manualPointAccountingPassed != true
                || report.manualPointRoundTripPassed != true {
                failures.append("control-point evidence \(caseID) did not prove manual-point accounting and \(expectedGeometry) re-optimization")
            }
        }
        for caseID in requiredControlPoints.sorted() where !observed.contains(caseID) {
            failures.append("control-point evidence is missing required case \(caseID)")
        }
    }
}
