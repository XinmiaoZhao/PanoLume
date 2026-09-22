import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import PanoLumeCore
import PanoLumeRegressionSupport

enum RegressionCLI {
    struct OracleOverrides {
        var root: URL?
        var pythonExecutable: String?
    }

    nonisolated(unsafe) static var oracleOverrides = OracleOverrides()

    struct ParityProvenance: Codable {
        var schemaVersion: Int
        var fingerprint: String
        var sourceCommit: String
        var sourceFingerprint: String
        var binaryEngineSourceFingerprint: String
        var regressionExecutableSHA256: String
        var certifiedSourceFingerprint: String?
        var worktreeClean: Bool
        var inputSHA256: [String: String]
        var configurationSHA256: String
        var metalDylibSHA256: String?
        var metalAPIVersion: Int?
        var oracleRoot: String?
        var oracleCommit: String?
        var oracleScriptsSHA256: String?
        var oracleIdentity: String?
        var oracleWorktreeClean: Bool?
        var pythonExecutable: String?
        var pythonExecutableSHA256: String?
        var pythonVersion: String?
        var toolVersion: String
        var createdAtUTC: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case fingerprint
            case sourceCommit = "source_commit"
            case sourceFingerprint = "source_fingerprint"
            case binaryEngineSourceFingerprint = "binary_engine_source_fingerprint"
            case regressionExecutableSHA256 = "regression_executable_sha256"
            case certifiedSourceFingerprint = "certified_source_fingerprint"
            case worktreeClean = "worktree_clean"
            case inputSHA256 = "input_sha256"
            case configurationSHA256 = "configuration_sha256"
            case metalDylibSHA256 = "metal_dylib_sha256"
            case metalAPIVersion = "metal_api_version"
            case oracleRoot = "oracle_root"
            case oracleCommit = "oracle_commit"
            case oracleScriptsSHA256 = "oracle_scripts_sha256"
            case oracleIdentity = "oracle_identity"
            case oracleWorktreeClean = "oracle_worktree_clean"
            case pythonExecutable = "python_executable"
            case pythonExecutableSHA256 = "python_executable_sha256"
            case pythonVersion = "python_version"
            case toolVersion = "tool_version"
            case createdAtUTC = "created_at_utc"
        }
    }

    final class FileDigestCache: @unchecked Sendable {
        struct Entry {
            var size: UInt64
            var modificationTime: TimeInterval
            var digest: String
        }

        let lock = NSLock()
        var entries: [String: Entry] = [:]

        func digest(
            for url: URL,
            compute: (URL) throws -> String
        ) throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lock.lock()
            if let entry = entries[url.path],
               entry.size == size,
               entry.modificationTime == modificationTime {
                lock.unlock()
                return entry.digest
            }
            lock.unlock()
            let value = try compute(url)
            lock.lock()
            entries[url.path] = Entry(size: size, modificationTime: modificationTime, digest: value)
            lock.unlock()
            return value
        }
    }

    static let provenanceDigestCache = FileDigestCache()
    static func algorithmSourcePaths(root: URL) throws -> [String] {
        let fileManager = FileManager.default
        let roots = [
            "macos/PanoLume/Sources/PanoLumeEngine",
            "macos/PanoLume/Sources/PanoLumeCore",
            "macos/PanoLume/Sources/PanoLumeApp",
            "native/metal_renderer",
        ]
        let engineExtensions: Set<String> = ["c", "cc", "cpp", "h", "hpp", "m", "mm"]
        let metalExtensions = engineExtensions.union(["metal"])
        var paths: [String] = []
        for relativeRoot in roots {
            let directory = root.appendingPathComponent(relativeRoot, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate fingerprint sources under \(directory.path)"]
                )
            }
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                let accepted: Bool
                if relativeRoot.hasSuffix("PanoLumeCore") || relativeRoot.hasSuffix("PanoLumeApp") {
                    accepted = ext == "swift"
                } else if relativeRoot == "native/metal_renderer" {
                    accepted = metalExtensions.contains(ext)
                } else {
                    accepted = engineExtensions.contains(ext)
                }
                guard accepted else { continue }
                let rootPath = root.standardizedFileURL.path + "/"
                let fullPath = fileURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath) else { continue }
                paths.append(String(fullPath.dropFirst(rootPath.count)))
            }
        }
        paths.append("scripts/build_metal_renderer.sh")
        if fileManager.fileExists(atPath: root.appendingPathComponent("scripts/Private/environment.sh").path) {
            paths.append("scripts/Private/environment.sh")
        }
        let sorted = Array(Set(paths)).sorted()
        guard !sorted.isEmpty else {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Fingerprint source enumeration returned no files."]
            )
        }
        return sorted
    }

    struct SourceCertificationManifest: Codable {
        var schemaVersion: Int
        var certifiedSourceCommit: String
        var certifiedSourceFingerprint: String
        var algorithmSourceFiles: [String]
        var certificationStatus: String
        var releaseReportSHA256: String
        var metalDylibSHA256: String
        var metalAPIVersion: Int
        var createdAtUTC: String?
        var note: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case certifiedSourceCommit = "certified_source_commit"
            case certifiedSourceFingerprint = "certified_source_fingerprint"
            case algorithmSourceFiles = "algorithm_source_files"
            case certificationStatus = "certification_status"
            case releaseReportSHA256 = "release_report_sha256"
            case metalDylibSHA256 = "metal_dylib_sha256"
            case metalAPIVersion = "metal_api_version"
            case createdAtUTC = "created_at_utc"
            case note
        }
    }

    struct SourceCertificationReport: Codable {
        var passed: Bool
        var schemaVersion: Int
        var currentSourceCommit: String
        var currentSourceFingerprint: String
        var binaryEngineSourceFingerprint: String
        var regressionExecutableSHA256: String
        var certifiedSourceCommit: String
        var certifiedSourceFingerprint: String
        var certifiedReleaseReportSHA256: String
        var certifiedMetalDylibSHA256: String
        var certifiedMetalAPIVersion: Int
        var algorithmSourceFiles: [String]
        var certificationStatus: String
        var message: String

        enum CodingKeys: String, CodingKey {
            case passed
            case schemaVersion = "schema_version"
            case currentSourceCommit = "current_source_commit"
            case currentSourceFingerprint = "current_source_fingerprint"
            case binaryEngineSourceFingerprint = "binary_engine_source_fingerprint"
            case regressionExecutableSHA256 = "regression_executable_sha256"
            case certifiedSourceCommit = "certified_source_commit"
            case certifiedSourceFingerprint = "certified_source_fingerprint"
            case certifiedReleaseReportSHA256 = "certified_release_report_sha256"
            case certifiedMetalDylibSHA256 = "certified_metal_dylib_sha256"
            case certifiedMetalAPIVersion = "certified_metal_api_version"
            case algorithmSourceFiles = "algorithm_source_files"
            case certificationStatus = "certification_status"
            case message
        }
    }

    struct OracleReuseIdentity: Codable {
        var schemaVersion: Int
        var oracleIdentity: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case oracleIdentity = "oracle_identity"
        }
    }

    static func run(arguments: [String]) -> Int32 {
        let configuredArguments: [String]
        do {
            configuredArguments = try configureGlobalOptions(arguments)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 2
        }
        guard configuredArguments.count >= 2 else {
            printUsage()
            return 2
        }

        #if PANOLUME_PRIVATE_EXTENSIONS
        if let code = privateCommand(configuredArguments) { return code }
        #endif
        switch configuredArguments[1] {
        case "capabilities":
            return printCapabilities()
        case "dependencies":
            return printDependencies()
        case "load-images":
            return loadImages(arguments: Array(configuredArguments.dropFirst(2)))
        case "preview":
            return runPreview(arguments: Array(configuredArguments.dropFirst(2)))
        case "pts-reconstruct":
            return runPTSReconstruct(arguments: Array(configuredArguments.dropFirst(2)))
        case "refine-astro-result":
            return refineAstroResult(arguments: Array(configuredArguments.dropFirst(2)))
        case "standard-image-regression":
            return runStandardImageRegression(arguments: Array(configuredArguments.dropFirst(2)))
        case "preview-export-diagnostic":
            return runPreviewExportDiagnostic(arguments: Array(configuredArguments.dropFirst(2)))
        case "projection-drag-smoke":
            return projectionDragSmoke(arguments: Array(configuredArguments.dropFirst(2)))
        case "raw1-canvas-smoke":
            return raw1CanvasSmoke(arguments: Array(configuredArguments.dropFirst(2)))
        case "cancellation-smoke":
            return cancellationSmoke(arguments: Array(configuredArguments.dropFirst(2)))
        case "external-working-set-calibration":
            return externalWorkingSetCalibration(arguments: Array(configuredArguments.dropFirst(2)))
        case "rerender-control-points":
            return rerenderControlPoints(arguments: Array(configuredArguments.dropFirst(2)))
        case "raw2-auto-refinement":
            return raw2AutoRefinement(arguments: Array(configuredArguments.dropFirst(2)))
        case "raw2-manual-reopt":
            return raw2ManualReopt(arguments: Array(configuredArguments.dropFirst(2)))
        case "raw2-export-pair":
            return raw2ExportPair(arguments: Array(configuredArguments.dropFirst(2)))
        case "manifest":
            return runManifest(arguments: Array(configuredArguments.dropFirst(2)))
        case "parity":
            return runParity(arguments: Array(configuredArguments.dropFirst(2)))
        case "certification":
            return runCertification(arguments: Array(configuredArguments.dropFirst(2)))
        case "perf":
            return runPerf(arguments: Array(configuredArguments.dropFirst(2)))
        case "metrics-from-python-report":
            return metricsFromPythonReport(arguments: Array(configuredArguments.dropFirst(2)))
        case "metrics-from-native-result":
            return metricsFromNativeResult(arguments: Array(configuredArguments.dropFirst(2)))
        case "compare":
            return compare(arguments: Array(configuredArguments.dropFirst(2)))
        default:
            printUsage()
            return 2
        }
    }





    static func configureGlobalOptions(_ arguments: [String]) throws -> [String] {
        guard !arguments.isEmpty else { return arguments }
        var filtered = [arguments[0]]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--oracle-root" || argument == "--python-executable" {
                index += 1
                guard index < arguments.count else {
                    throw NSError(
                        domain: "PanoLumeRegression",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "\(argument) requires a path"]
                    )
                }
                let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                if argument == "--oracle-root" {
                    oracleOverrides.root = url
                } else {
                    oracleOverrides.pythonExecutable = arguments[index]
                }
            } else if argument.hasPrefix("--oracle-root=") {
                oracleOverrides.root = URL(
                    fileURLWithPath: String(argument.dropFirst("--oracle-root=".count))
                ).standardizedFileURL
            } else if argument.hasPrefix("--python-executable=") {
                oracleOverrides.pythonExecutable = String(argument.dropFirst("--python-executable=".count))
            } else {
                filtered.append(argument)
            }
            index += 1
        }
        return filtered
    }

    struct ProjectionDragSmokeReport: Codable {
        var artifact: String
        var caseID: String
        var imageCount: Int
        var success: Bool
        var inputCount: Int
        var samples: Int
        var originalSignature: UInt64
        var dragPreviewSignature: UInt64
        var adjustedSignature: UInt64
        var changed: Bool
        var dragFrameChanged: Bool
        var committedPixelsChanged: Bool
        var committedPixelsRetained: Bool
        var geometryPersisted: Bool
        var independentCommitSSIM: Double?
        var independentCommitPassed: Bool
        var medianLatencyMS: Double
        var p95LatencyMS: Double
        var maxLatencyMS: Double
        var commitLatencyMS: Double
        var commitLatencyGatePassed: Bool
        var originalWidth: Int
        var originalHeight: Int
        var dragPreviewWidth: Int
        var dragPreviewHeight: Int
        var committedWidth: Int
        var committedHeight: Int
        var dimensionGatePassed: Bool
        var blendAfterDrag: Bool
        var commitQuality: String
        var committedGeometry: String?
        var committedBlendMode: String?
        var committedRendererRequested: String?
        var committedRendererUsed: String?
        var committedRendererFallback: Bool?
        var committedRendererPassed: Bool
        var originalHandleStillValid: Bool
        var originalHandle: String
        var adjustedHandle: String
        var pose: PoseAdjustment
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact
            case caseID = "case_id"
            case imageCount = "image_count"
            case success
            case inputCount = "input_count"
            case samples
            case originalSignature = "original_signature"
            case dragPreviewSignature = "drag_preview_signature"
            case adjustedSignature = "adjusted_signature"
            case changed
            case dragFrameChanged = "drag_frame_changed"
            case committedPixelsChanged = "committed_pixels_changed"
            case committedPixelsRetained = "committed_pixels_retained"
            case geometryPersisted = "geometry_persisted"
            case independentCommitSSIM = "independent_commit_ssim"
            case independentCommitPassed = "independent_commit_passed"
            case medianLatencyMS = "median_latency_ms"
            case p95LatencyMS = "p95_latency_ms"
            case maxLatencyMS = "max_latency_ms"
            case commitLatencyMS = "commit_latency_ms"
            case commitLatencyGatePassed = "commit_latency_gate_passed"
            case originalWidth = "original_width"
            case originalHeight = "original_height"
            case dragPreviewWidth = "drag_preview_width"
            case dragPreviewHeight = "drag_preview_height"
            case committedWidth = "committed_width"
            case committedHeight = "committed_height"
            case dimensionGatePassed = "dimension_gate_passed"
            case blendAfterDrag = "blend_after_drag"
            case commitQuality = "commit_quality"
            case committedGeometry = "committed_geometry"
            case committedBlendMode = "committed_blend_mode"
            case committedRendererRequested = "committed_renderer_requested"
            case committedRendererUsed = "committed_renderer_used"
            case committedRendererFallback = "committed_renderer_fallback"
            case committedRendererPassed = "committed_renderer_passed"
            case originalHandleStillValid = "original_handle_still_valid"
            case originalHandle = "original_handle"
            case adjustedHandle = "adjusted_handle"
            case pose
            case message
        }
    }

    struct Raw1CanvasSmokeReport: Codable {
        var artifact: String
        var passed: Bool
        var imageCount: Int
        var pitchDegrees: Double
        var yawDegrees: Double
        var rollDegrees: Double
        var canvasWidth: Int
        var canvasHeight: Int
        var coverageMinX: Int
        var coverageMinY: Int
        var coverageMaxX: Int
        var coverageMaxY: Int
        var leftBand: Int
        var rightBand: Int
        var topBand: Int
        var bottomBand: Int
        var coverageNotClipped: Bool
        var excessTransparentBand: Bool
        var canvasCentered: Bool
        var geometry: String?
        var rendererRequested: String?
        var rendererUsed: String?
        var rendererFallback: Bool?
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact
            case passed
            case imageCount = "image_count"
            case pitchDegrees = "pitch_degrees"
            case yawDegrees = "yaw_degrees"
            case rollDegrees = "roll_degrees"
            case canvasWidth = "canvas_width"
            case canvasHeight = "canvas_height"
            case coverageMinX = "coverage_min_x"
            case coverageMinY = "coverage_min_y"
            case coverageMaxX = "coverage_max_x"
            case coverageMaxY = "coverage_max_y"
            case leftBand = "left_band_px"
            case rightBand = "right_band_px"
            case topBand = "top_band_px"
            case bottomBand = "bottom_band_px"
            case coverageNotClipped = "coverage_not_clipped"
            case excessTransparentBand = "excess_transparent_band"
            case canvasCentered = "canvas_centered"
            case geometry
            case rendererRequested = "renderer_requested"
            case rendererUsed = "renderer_used"
            case rendererFallback = "renderer_fallback"
            case message
        }
    }

    struct StandardImagePairResidual: Codable {
        var imageAIndex: Int
        var imageBIndex: Int
        var count: Int
        var rms: Double
        var p95: Double

        enum CodingKeys: String, CodingKey {
            case imageAIndex = "image_a_index"
            case imageBIndex = "image_b_index"
            case count
            case rms
            case p95
        }
    }

    struct StandardImageRegressionThresholds: Codable {
        var maxPairP95: Double
        var minimumMaskedSSIM: Double
        var maxPreviewSeconds: Double

        enum CodingKeys: String, CodingKey {
            case maxPairP95 = "max_pair_p95"
            case minimumMaskedSSIM = "minimum_masked_ssim"
            case maxPreviewSeconds = "max_preview_seconds"
        }
    }

    struct StandardImageRegressionReport: Encodable {
        var artifact: String
        var caseID: String
        var imageCount: Int
        var passed: Bool
        var inputPaths: [String]
        var referencePath: String?
        var previewPath: String?
        var diffPath: String?
        var geometry: String?
        var alignmentFamily: String?
        var cameraModelAttempted: Bool
        var selectedEdgeCount: Int
        var controlPointCount: Int
        var pairResiduals: [StandardImagePairResidual]
        var worstPairP95: Double?
        var panoramaWidth: Int
        var panoramaHeight: Int
        var previewSeconds: Double
        var visualMetrics: VisualParityMetrics?
        var registration: SimilarityRegistrationResult?
        var thresholds: StandardImageRegressionThresholds
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case artifact
            case caseID = "case_id"
            case imageCount = "image_count"
            case passed
            case inputPaths = "input_paths"
            case referencePath = "reference_path"
            case previewPath = "preview_path"
            case diffPath = "diff_path"
            case geometry
            case alignmentFamily = "alignment_family"
            case cameraModelAttempted = "camera_model_attempted"
            case selectedEdgeCount = "selected_edge_count"
            case controlPointCount = "control_point_count"
            case pairResiduals = "pair_residuals"
            case worstPairP95 = "worst_pair_p95"
            case panoramaWidth = "panorama_width"
            case panoramaHeight = "panorama_height"
            case previewSeconds = "preview_seconds"
            case visualMetrics = "visual_metrics"
            case registration
            case thresholds
            case failures
        }
    }

    struct CancellationSmokeReport: Codable {
        var artifact: String
        var caseID: String
        var imageCount: Int
        var passed: Bool
        var operation: String
        var inputCount: Int
        var jobID: UInt64
        var cancellationRequestedAfterStage: String
        var terminalMessage: String
        var elapsedSeconds: Double
        var partialOutputExists: Bool
        var triggerReached: Bool
        var backgroundFinished: Bool
        var observedStages: [String]
        var cleanupOutcome: String
        var remainingArtifacts: [String]
        var workingSetBudgetMB: Int
        var setupGeometryState: String?

        enum CodingKeys: String, CodingKey {
            case artifact
            case caseID = "case_id"
            case imageCount = "image_count"
            case passed
            case operation
            case inputCount = "input_count"
            case jobID = "job_id"
            case cancellationRequestedAfterStage = "cancellation_requested_after_stage"
            case terminalMessage = "terminal_message"
            case elapsedSeconds = "elapsed_seconds"
            case partialOutputExists = "partial_output_exists"
            case triggerReached = "trigger_reached"
            case backgroundFinished = "background_finished"
            case observedStages = "observed_stages"
            case cleanupOutcome = "cleanup_outcome"
            case remainingArtifacts = "remaining_artifacts"
            case workingSetBudgetMB = "working_set_budget_mb"
            case setupGeometryState = "setup_geometry_state"
        }
    }

    struct ExternalWorkingSetCalibrationReport: Codable {
        var artifact: String
        var passed: Bool
        var childArguments: [String]
        var childExitCode: Int32
        var expectedExitCode: Int32
        var externalPeakRSSMB: Double?
        var sampleCount: Int
        var sampleIntervalSeconds: Double
        var elapsedSeconds: Double
        var regressionExecutableSHA256: String
        var stdoutTail: String
        var stderrTail: String

        enum CodingKeys: String, CodingKey {
            case artifact, passed
            case childArguments = "child_arguments"
            case childExitCode = "child_exit_code"
            case expectedExitCode = "expected_exit_code"
            case externalPeakRSSMB = "external_peak_rss_mb"
            case sampleCount = "sample_count"
            case sampleIntervalSeconds = "sample_interval_seconds"
            case elapsedSeconds = "elapsed_seconds"
            case regressionExecutableSHA256 = "regression_executable_sha256"
            case stdoutTail = "stdout_tail"
            case stderrTail = "stderr_tail"
        }
    }

    struct RerenderControlPointsReport: Codable {
        var artifact: String
        var caseID: String
        var imageCount: Int
        var testKind: String
        var success: Bool
        var originalGeometry: String?
        var rerenderedGeometry: String?
        var originalControlPoints: Int
        var editedControlPoints: Int
        var rerenderedControlPoints: Int
        var manualPointInput: Int
        var manualPointAccepted: Int
        var manualPointRejected: Int
        var manualPointReason: String
        var manualPointAccountingPassed: Bool
        var manualPointRoundTripPassed: Bool
        var originalHandle: String
        var rerenderedHandle: String
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact
            case caseID = "case_id"
            case imageCount = "image_count"
            case testKind = "test_kind"
            case success
            case originalGeometry = "original_geometry"
            case rerenderedGeometry = "rerendered_geometry"
            case originalControlPoints = "original_control_points"
            case editedControlPoints = "edited_control_points"
            case rerenderedControlPoints = "rerendered_control_points"
            case manualPointInput = "manual_point_input"
            case manualPointAccepted = "manual_point_accepted"
            case manualPointRejected = "manual_point_rejected"
            case manualPointReason = "manual_point_reason"
            case manualPointAccountingPassed = "manual_point_accounting_passed"
            case manualPointRoundTripPassed = "manual_point_round_trip_passed"
            case originalHandle = "original_handle"
            case rerenderedHandle = "rerendered_handle"
            case message
        }
    }

    struct DisconnectedControlPointsReport: Codable {
        var artifact: String
        var caseID: String
        var imageCount: Int
        var testKind: String
        var explicitDisconnectedError: Bool
        var success: Bool
        var geometry: String?
        var disconnectedImageIndex: Int
        var originalControlPoints: Int
        var editedControlPoints: Int
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact
            case caseID = "case_id"
            case imageCount = "image_count"
            case testKind = "test_kind"
            case explicitDisconnectedError = "explicit_disconnected_error"
            case success
            case geometry
            case disconnectedImageIndex = "disconnected_image_index"
            case originalControlPoints = "original_control_points"
            case editedControlPoints = "edited_control_points"
            case message
        }
    }

    struct Raw2ManualFixture: Decodable {
        struct Pair: Decodable {
            var fileA: String
            var fileB: String

            enum CodingKeys: String, CodingKey {
                case fileA = "file_a"
                case fileB = "file_b"
            }
        }

        struct ManualPair: Decodable {
            struct Point: Decodable {
                var xA: Double
                var yA: Double
                var xB: Double
                var yB: Double

                enum CodingKeys: String, CodingKey {
                    case xA = "x_a"
                    case yA = "y_a"
                    case xB = "x_b"
                    case yB = "y_b"
                }
            }

            var fileA: String
            var fileB: String
            var points: [Point]

            enum CodingKeys: String, CodingKey {
                case fileA = "file_a"
                case fileB = "file_b"
                case points
            }
        }

        var schemaVersion: Int
        var importOrder: [String]
        var removePair: Pair
        var manualPair: ManualPair

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case importOrder = "import_order"
            case removePair = "remove_pair"
            case manualPair = "manual_pair"
        }
    }

    struct Raw2ManualReoptReport: Codable {
        var artifact: String
        var success: Bool
        var imageCount: Int
        var previewGeometry: String?
        var rerenderedGeometry: String?
        var previewStatus: String?
        var rerenderedStatus: String?
        var reoptimizationMethod: String?
        var correctPair: [Int]
        var wrongPair: [Int]
        var correctPairSelected: Bool
        var wrongPairSelected: Bool
        var manualInput: Int
        var manualAccepted: Int
        var manualRejected: Int
        var manualAccountingPassed: Bool
        var manualPoints: [AstroManualPointRecord]
        var geometryGatePassed: Bool
        var astroRefinementState: String?
        var astroRefinement: AstroRefinementInfo?
        var heldOutGatePassed: Bool
        var dirtyCleared: Bool
        var transparentPreviewPassed: Bool
        var displayStretchChangedPixels: Bool
        var stitchConfigurationSHA256: String
        var lensProfileSHA256: String
        var lensProfileRequired: Bool
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact
            case success
            case imageCount = "image_count"
            case previewGeometry = "preview_geometry"
            case rerenderedGeometry = "rerendered_geometry"
            case previewStatus = "preview_status"
            case rerenderedStatus = "rerendered_status"
            case reoptimizationMethod = "reoptimization_method"
            case correctPair = "correct_pair"
            case wrongPair = "wrong_pair"
            case correctPairSelected = "correct_pair_selected"
            case wrongPairSelected = "wrong_pair_selected"
            case manualInput = "manual_input"
            case manualAccepted = "manual_accepted"
            case manualRejected = "manual_rejected"
            case manualAccountingPassed = "manual_accounting_passed"
            case manualPoints = "manual_points"
            case geometryGatePassed = "geometry_gate_passed"
            case astroRefinementState = "astro_refinement_state"
            case astroRefinement = "astro_refinement"
            case heldOutGatePassed = "held_out_gate_passed"
            case dirtyCleared = "dirty_cleared"
            case transparentPreviewPassed = "transparent_preview_passed"
            case displayStretchChangedPixels = "display_stretch_changed_pixels"
            case stitchConfigurationSHA256 = "stitch_configuration_sha256"
            case lensProfileSHA256 = "lens_profile_sha256"
            case lensProfileRequired = "lens_profile_required"
            case message
        }
    }

    struct Raw2AutoRefinementReport: Codable {
        var artifact = "raw2-auto-refinement"
        var passed: Bool
        var imageCount: Int
        var geometry: String?
        var astroRefinementState: String
        var heldOutGatePassed: Bool
        var gridColumns: Int
        var gridRows: Int
        var correctPairSelected: Bool
        var wrongPairSelected: Bool
        var selectedFilenamePairs: [[String]]
        var lensModel: String
        var astroRefinement: AstroRefinementInfo
        var stitchConfigurationSHA256: String
        var lensProfileSHA256: String
        var lensProfileRequired: Bool
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact, passed, geometry, message
            case imageCount = "image_count"
            case astroRefinementState = "astro_refinement_state"
            case heldOutGatePassed = "held_out_gate_passed"
            case gridColumns = "grid_columns"
            case gridRows = "grid_rows"
            case correctPairSelected = "correct_pair_selected"
            case wrongPairSelected = "wrong_pair_selected"
            case selectedFilenamePairs = "selected_filename_pairs"
            case lensModel = "lens_model"
            case astroRefinement = "astro_refinement"
            case stitchConfigurationSHA256 = "stitch_configuration_sha256"
            case lensProfileSHA256 = "lens_profile_sha256"
            case lensProfileRequired = "lens_profile_required"
        }
    }

    struct Raw2ExportPairReport: Codable {
        var artifact = "raw2-export-pair"
        var passed: Bool
        var imageCount: Int
        var geometry: String?
        var astroRefinementState: String
        var heldOutGatePassed: Bool
        var correctPairSelected: Bool
        var wrongPairSelected: Bool
        var resultHandle: String
        var sameResultHandle: Bool
        var bitDepth: Int
        var cpuOutputPath: String
        var metalOutputPath: String
        var cpuOutputSHA256: String?
        var metalOutputSHA256: String?
        var cpuRendererVerified: Bool
        var metalQualityRendererVerified: Bool
        var metalFallback: Bool
        var dimensionsMatch: Bool
        var coverageMatch: Bool
        var pixelQualityPassed: Bool
        var coverageIoU: Double?
        var rgbSSIM: Double?
        var medianAbsDiff: Double?
        var p95AbsDiff: Double?
        var comparison: TIFFStreamingComparison?
        var thresholds: [String: Double]
        var cpuExportProfile: JSONValue?
        var metalExportProfile: JSONValue?
        var stitchConfigurationSHA256: String
        var lensProfileSHA256: String
        var lensProfileRequired: Bool
        var message: String

        enum CodingKeys: String, CodingKey {
            case artifact, passed, geometry, message, comparison
            case imageCount = "image_count"
            case astroRefinementState = "astro_refinement_state"
            case heldOutGatePassed = "held_out_gate_passed"
            case correctPairSelected = "correct_pair_selected"
            case wrongPairSelected = "wrong_pair_selected"
            case resultHandle = "result_handle"
            case sameResultHandle = "same_result_handle"
            case bitDepth = "bit_depth"
            case cpuOutputPath = "cpu_output_path"
            case metalOutputPath = "metal_output_path"
            case cpuOutputSHA256 = "cpu_output_sha256"
            case metalOutputSHA256 = "metal_output_sha256"
            case cpuRendererVerified = "cpu_renderer_verified"
            case metalQualityRendererVerified = "metal_quality_renderer_verified"
            case metalFallback = "metal_fallback"
            case dimensionsMatch = "dimensions_match"
            case coverageMatch = "coverage_match"
            case pixelQualityPassed = "pixel_quality_passed"
            case coverageIoU = "coverage_iou"
            case rgbSSIM = "rgb_ssim"
            case medianAbsDiff = "median_absdiff"
            case p95AbsDiff = "p95_absdiff"
            case thresholds
            case cpuExportProfile = "cpu_export_profile"
            case metalExportProfile = "metal_export_profile"
            case stitchConfigurationSHA256 = "stitch_configuration_sha256"
            case lensProfileSHA256 = "lens_profile_sha256"
            case lensProfileRequired = "lens_profile_required"
        }
    }

    static func raw2Settings(lensProfileURL: URL?) throws -> StitchSettings {
        var settings = StitchSettings()
        guard let lensProfileURL else { return settings }
        let prior = try LensCalibrationPriorLoader.load(
            from: lensProfileURL,
            targetFocalLengthMM: 16,
            targetFNumber: 2,
            targetCameraMake: "NIKON CORPORATION"
        )
        settings.lensCalibrationPrior = prior
        settings.lensProfilePath = lensProfileURL.path
        settings.lensProfileName = prior.profileName
        return settings
    }

    static func raw2EvidenceBindings(
        inputURLs: [URL],
        settings: StitchSettings
    ) throws -> (configurationSHA256: String, lensProfileSHA256: String) {
        let configuration: [String: String] = [
            "schema": "raw2-stitch-configuration-v1",
            "ordered_paths": inputURLs.map(\.standardizedFileURL.path).joined(separator: "\n"),
            "settings": try stableJSONString(settings),
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        return (
            configurationSHA256: sha256Hex(data),
            lensProfileSHA256: settings.lensCalibrationPrior?.sha256 ?? "none"
        )
    }

    static func printDependencies() -> Int32 {
        do {
            let report = try NativeEngineBridge.dependencyReport()
            try printJSON(report)
            return report.allRequiredAvailable ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func printCapabilities() -> Int32 {
        do {
            let capabilities = try NativeEngineBridge.capabilities()
            try printJSON(capabilities)
            return capabilities.nativeAlgorithmParity ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func loadImages(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--preview-max-side":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("load-images requires an integer after --preview-max-side\n", stderr)
                    return 2
                }
                settings.previewMaxSide = value
            case "--full-input-preview":
                settings.fullInputPreview = true
                settings.previewMaxSide = 0
            case "--raw-full-size":
                settings.rawHalfSize = false
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard !paths.isEmpty else {
            fputs("load-images requires at least one image path\n", stderr)
            return 2
        }
        do {
            let engine = try NativeEngineBridge()
            let response = try engine.loadImages(
                paths: paths.map { URL(fileURLWithPath: $0) },
                settings: settings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            try printJSON(response)
            return response.images.allSatisfy { $0.status == .loaded } ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runPreview(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        var refineFullResolution = false
        var outputURL: URL?
        var draftOutputURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--alignment-mode":
                index += 1
                guard index < arguments.count,
                      ["auto", "sift", "stars"].contains(arguments[index]) else {
                    fputs("preview requires auto, sift, or stars after --alignment-mode\n", stderr)
                    return 2
                }
                settings.alignmentMode = arguments[index]
            case "--geometry":
                index += 1
                guard index < arguments.count,
                      ["auto", "camera", "homography"].contains(arguments[index]) else {
                    fputs("preview requires auto, camera, or homography after --geometry\n", stderr)
                    return 2
                }
                settings.astroGeometry = arguments[index]
            case "--preview-max-side":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                    fputs("preview requires a non-negative integer after --preview-max-side\n", stderr)
                    return 2
                }
                settings.previewMaxSide = value
            case "--optimize-distortion":
                settings.optimizeDistortion = true
            case "--full-resolution-refine":
                refineFullResolution = true
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("preview requires a path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--draft-output":
                index += 1
                guard index < arguments.count else {
                    fputs("preview requires a path after --draft-output\n", stderr)
                    return 2
                }
                draftOutputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--astro-sky-mode":
                index += 1
                guard index < arguments.count,
                      ["auto_sky", "full_frame"].contains(arguments[index]) else {
                    fputs("preview requires auto_sky or full_frame after --astro-sky-mode\n", stderr)
                    return 2
                }
                settings.astroSkyMode = arguments[index]
            case "--robust-reprojection-px":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("preview requires a numeric value after --robust-reprojection-px\n", stderr)
                    return 2
                }
                settings.cameraModelRobustReprojectionPx = value
            case "--robust-min-pair-inliers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("preview requires an integer value after --robust-min-pair-inliers\n", stderr)
                    return 2
                }
                settings.cameraModelRobustMinPairInliers = value
            case "--no-guided-refinement":
                settings.cameraModelGuidedRefinement = false
            case "--no-local-refinement":
                settings.cameraModelLocalRefinement = false
            case "--no-texture-refinement":
                settings.cameraModelTextureRefinement = false
            case "--multiband":
                settings.blendMode = "multiband"
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard paths.count >= 2 else {
            fputs("preview requires at least two image paths\n", stderr)
            return 2
        }
        do {
            let engine = try NativeEngineBridge()
            var response = try engine.runPreview(
                paths: paths.map { URL(fileURLWithPath: $0) },
                settings: settings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            if let draftOutputURL {
                try writeJSON(response, to: draftOutputURL)
            }
            if refineFullResolution,
               let draft = response.result {
                let status = draft.diagnostics["preview_status"]?.stringValue
                guard status == "draft_camera_preview" || status == "unverified_camera_draft" else {
                    if let outputURL {
                        try writeJSON(response, to: outputURL)
                    } else {
                        try printJSON(response)
                    }
                    return 3
                }
                let refinementEngine = try NativeEngineBridge()
                let refinement = try refinementEngine.refineAstroFullResolution(
                    result: draft,
                    settings: settings
                ) { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
                guard refinement.passed else {
                    if let outputURL {
                        try writeJSON(refinement, to: outputURL)
                    } else {
                        try printJSON(refinement)
                    }
                    return 3
                }
                response = try engine.applyAstroRefinement(
                    to: draft,
                    refinement: refinement
                ) { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            }
            if let outputURL {
                try writeJSON(response, to: outputURL)
            } else {
                try printJSON(response)
            }
            let gate = ParityGate.evaluate(result: response.result)
            return gate.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func refineAstroResult(arguments: [String]) -> Int32 {
        var inputURL: URL?
        var outputURL: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard ["--input", "--output"].contains(argument) else {
                fputs("refine-astro-result accepts only --input and --output\n", stderr)
                return 2
            }
            index += 1
            guard index < arguments.count else {
                fputs("refine-astro-result requires a path after \(argument)\n", stderr)
                return 2
            }
            let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            if argument == "--input" {
                inputURL = url
            } else {
                outputURL = url
            }
            index += 1
        }
        guard let inputURL, let outputURL else {
            fputs("refine-astro-result requires --input draft.json --output report.json\n", stderr)
            return 2
        }
        do {
            let response = try JSONDecoder().decode(
                EngineOperationResponse.self,
                from: Data(contentsOf: inputURL)
            )
            guard let draft = response.result else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Input does not contain a Camera draft result"]
                )
            }
            let draftStatus = draft.diagnostics["preview_status"]?.stringValue
            guard draftStatus == "draft_camera_preview" || draftStatus == "unverified_camera_draft" else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Input is not a refinable Camera draft result"]
                )
            }
            let engine = try NativeEngineBridge()
            let refinement = try engine.refineAstroFullResolution(
                result: draft,
                settings: StitchSettings()
            ) { event in
                fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            try writeJSON(refinement, to: outputURL)
            return refinement.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runStandardImageRegression(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        settings.alignmentMode = "auto"
        settings.astroGeometry = "auto"
        settings.displayStretch = false
        var thresholds = StandardImageRegressionThresholds(
            maxPairP95: 0.5,
            minimumMaskedSSIM: 0.98,
            maxPreviewSeconds: 30.0
        )
        var caseID: String?
        var outputDirectory = URL(
            fileURLWithPath: "/tmp/panolume_standard_image_regression",
            isDirectory: true
        )
        var referenceURL: URL?
        var minimumSSIMWasProvided = false
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case", "--reference", "--output-dir", "--max-pair-p95", "--min-ssim", "--max-seconds", "--preview-max-side":
                index += 1
                guard index < arguments.count else {
                    fputs("standard-image-regression requires a value after \(argument)\n", stderr)
                    return 2
                }
                let value = arguments[index]
                switch argument {
                case "--case":
                    guard ["synthetic-crops", "test_1_parts"].contains(value) else {
                        fputs("--case must be synthetic-crops or test_1_parts\n", stderr)
                        return 2
                    }
                    caseID = value
                case "--reference":
                    referenceURL = URL(fileURLWithPath: value).standardizedFileURL
                case "--output-dir":
                    outputDirectory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
                case "--max-pair-p95":
                    guard let parsed = Double(value), parsed > 0 else {
                        fputs("--max-pair-p95 must be positive\n", stderr)
                        return 2
                    }
                    thresholds.maxPairP95 = parsed
                case "--min-ssim":
                    guard let parsed = Double(value), (0...1).contains(parsed) else {
                        fputs("--min-ssim must be between 0 and 1\n", stderr)
                        return 2
                    }
                    thresholds.minimumMaskedSSIM = parsed
                    minimumSSIMWasProvided = true
                case "--max-seconds":
                    guard let parsed = Double(value), parsed > 0 else {
                        fputs("--max-seconds must be positive\n", stderr)
                        return 2
                    }
                    thresholds.maxPreviewSeconds = parsed
                case "--preview-max-side":
                    guard let parsed = Int(value), parsed >= 0 else {
                        fputs("--preview-max-side must be a non-negative integer\n", stderr)
                        return 2
                    }
                    settings.previewMaxSide = parsed
                default:
                    break
                }
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard let caseID else {
            fputs("standard-image-regression requires --case synthetic-crops|test_1_parts\n", stderr)
            return 2
        }
        if caseID == "synthetic-crops", !minimumSSIMWasProvided {
            thresholds.minimumMaskedSSIM = 0.995
        }
        if caseID == "synthetic-crops", paths.isEmpty, referenceURL == nil {
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                let fixture = SyntheticStandardImageFixture.make()
                let generatedReferenceURL = outputDirectory
                    .appendingPathComponent("synthetic-reference.png")
                try savePNG(fixture.reference, to: generatedReferenceURL)
                var generatedPaths: [String] = []
                for (cropIndex, crop) in fixture.crops.enumerated() {
                    let url = outputDirectory.appendingPathComponent(
                        String(format: "synthetic-crop-%02d.png", cropIndex + 1)
                    )
                    try savePNG(crop.pixels, to: url)
                    generatedPaths.append(url.path)
                }
                referenceURL = generatedReferenceURL
                paths = generatedPaths
            } catch {
                fputs("failed to generate synthetic-crops fixture: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        guard paths.count >= 2 else {
            fputs("standard-image-regression requires at least two standard-image paths (or omit paths and --reference for the generated synthetic-crops case)\n", stderr)
            return 2
        }
        if caseID == "test_1_parts", paths.count != 8 {
            fputs("standard-image-regression --case test_1_parts requires exactly eight image paths\n", stderr)
            return 2
        }
        guard referenceURL != nil else {
            fputs("standard-image-regression release cases require --reference for the SSIM gate\n", stderr)
            return 2
        }
        let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        if let referenceURL, !FileManager.default.fileExists(atPath: referenceURL.path) {
            fputs("standard-image-regression reference is missing: \(referenceURL.path)\n", stderr)
            return 2
        }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let engine = try NativeEngineBridge()
            let started = DispatchTime.now().uptimeNanoseconds
            let response = try engine.runPreview(
                paths: inputURLs,
                settings: settings,
                progress: { event in
                    fputs("standard-image-regression \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000.0
            guard let result = response.result else {
                try printJSON(response)
                return 3
            }

            let grouped = Dictionary(grouping: result.controlPoints) { point -> String in
                let a = min(point.imageAIndex, point.imageBIndex)
                let b = max(point.imageAIndex, point.imageBIndex)
                return "\(a):\(b)"
            }
            let pairResiduals = grouped.compactMap { key, points -> StandardImagePairResidual? in
                let indices = key.split(separator: ":").compactMap { Int($0) }
                guard indices.count == 2 else { return nil }
                let errors = points.map(\.error).filter(\.isFinite).sorted()
                guard !errors.isEmpty else { return nil }
                let rms = sqrt(errors.reduce(0.0) { $0 + $1 * $1 } / Double(errors.count))
                return StandardImagePairResidual(
                    imageAIndex: indices[0],
                    imageBIndex: indices[1],
                    count: errors.count,
                    rms: rms,
                    p95: percentile(sorted: errors, fraction: 0.95)
                )
            }.sorted {
                ($0.imageAIndex, $0.imageBIndex) < ($1.imageAIndex, $1.imageBIndex)
            }
            let worstPairP95 = pairResiduals.map(\.p95).max()
            let geometry = result.diagnostics["geometry"]?.stringValue
            let alignmentFamily = result.diagnostics["alignment_family"]?.stringValue
            let cameraModel = result.diagnostics["camera_model"]
            let cameraModelAttempted = cameraModel?["attempted"]?.boolValue ?? (cameraModel != nil)
            let selectedEdgeCount = result.diagnostics["selected_edges"]?.arrayValue?.count ?? 0

            let previewURL = outputDirectory.appendingPathComponent("native-preview.png")
            let pixels = try requirePixels(
                engine.copyResultRGBA(resultHandle: result.handle, settings: settings),
                label: "standard image preview"
            )
            try savePNG(pixels, to: previewURL)
            var visualMetrics: VisualParityMetrics?
            var registration: SimilarityRegistrationResult?
            var diffURL: URL?
            if let referenceURL {
                let destination = outputDirectory.appendingPathComponent("reference-diff.png")
                let comparison = try compareStandardImageReference(
                    referenceURL: referenceURL,
                    candidateURL: previewURL,
                    alignedReferenceURL: outputDirectory.appendingPathComponent("aligned-reference-crop.png"),
                    diffURL: destination
                )
                visualMetrics = comparison.metrics
                registration = comparison.registration
                diffURL = destination
            }

            var failures: [String] = []
            if geometry != "homography" {
                failures.append("auto geometry selected \(geometry ?? "missing") instead of homography")
            }
            if cameraModelAttempted {
                failures.append("ordinary-image regression entered camera bundle adjustment")
            }
            if selectedEdgeCount < inputURLs.count - 1 {
                failures.append("selected edge graph is disconnected or incomplete")
            }
            if pairResiduals.count < selectedEdgeCount {
                failures.append("one or more selected image pairs lack finite residual evidence")
            }
            if let worstPairP95 {
                if worstPairP95 > thresholds.maxPairP95 {
                    failures.append("worst pair P95 \(worstPairP95) px exceeds \(thresholds.maxPairP95) px")
                }
            } else {
                failures.append("pairwise control-point residuals are missing")
            }
            if elapsed > thresholds.maxPreviewSeconds {
                failures.append("preview took \(elapsed) seconds, exceeding \(thresholds.maxPreviewSeconds) seconds")
            }
            if let visualMetrics,
               visualMetrics.maskedSSIM < thresholds.minimumMaskedSSIM {
                failures.append("masked SSIM \(visualMetrics.maskedSSIM) is below \(thresholds.minimumMaskedSSIM)")
            }

            let report = StandardImageRegressionReport(
                artifact: "standard-image-regression",
                caseID: caseID,
                imageCount: inputURLs.count,
                passed: failures.isEmpty,
                inputPaths: inputURLs.map(\.path),
                referencePath: referenceURL?.path,
                previewPath: previewURL.path,
                diffPath: diffURL?.path,
                geometry: geometry,
                alignmentFamily: alignmentFamily,
                cameraModelAttempted: cameraModelAttempted,
                selectedEdgeCount: selectedEdgeCount,
                controlPointCount: result.controlPoints.count,
                pairResiduals: pairResiduals,
                worstPairP95: worstPairP95,
                panoramaWidth: result.panorama.width,
                panoramaHeight: result.panorama.height,
                previewSeconds: elapsed,
                visualMetrics: visualMetrics,
                registration: registration,
                thresholds: thresholds,
                failures: failures
            )
            var provenanceInputs = inputURLs
            if let referenceURL { provenanceInputs.append(referenceURL) }
            let provenance = try makeProvenance(
                inputURLs: provenanceInputs,
                configuration: [
                    "artifact": "standard-image-regression",
                    "case_id": caseID,
                    "image_count": String(inputURLs.count),
                    "settings": try stableJSONString(settings),
                    "thresholds": try stableJSONString(thresholds),
                    "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                    "reference": referenceURL?.path ?? "none",
                ],
                includePythonOracle: false
            )
            let reportURL = outputDirectory.appendingPathComponent("report.json")
            try writeJSON(report, to: reportURL, provenance: provenance)
            FileHandle.standardOutput.write(try Data(contentsOf: reportURL))
            return report.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func raw1CanvasSmoke(arguments: [String]) -> Int32 {
        var outputURL: URL?
        var pose = PoseAdjustment(pitchDegrees: 39.91, yawDegrees: 88.19, rollDegrees: 0.0)
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("raw1-canvas-smoke requires a path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--pitch":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("raw1-canvas-smoke requires a number after --pitch\n", stderr)
                    return 2
                }
                pose.pitchDegrees = value
            case "--yaw":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("raw1-canvas-smoke requires a number after --yaw\n", stderr)
                    return 2
                }
                pose.yawDegrees = value
            case "--roll":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("raw1-canvas-smoke requires a number after --roll\n", stderr)
                    return 2
                }
                pose.rollDegrees = value
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        guard let outputURL else {
            fputs("raw1-canvas-smoke requires --output report.json\n", stderr)
            return 2
        }
        guard paths.count == 7 else {
            fputs("raw1-canvas-smoke requires exactly seven image paths\n", stderr)
            return 2
        }

        do {
            var settings = StitchSettings()
            settings.astroGeometry = "camera"
            settings.previewRendererBackend = "metal_quality"
            let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let engine = try NativeEngineBridge()
            let preview = try engine.runPreview(
                paths: inputURLs,
                settings: settings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            guard let original = preview.result,
                  original.diagnostics["geometry"]?.stringValue == "camera",
                  original.cameraParams.count == original.sourceImages.count else {
                let geometry = preview.result?.diagnostics["geometry"]?.stringValue ?? "missing"
                let reason = preview.result?.diagnostics["preview_failure_reason"]?.stringValue
                    ?? preview.message
                fputs(
                    "raw1-canvas-smoke preview did not produce complete camera geometry "
                        + "(geometry=\(geometry)): \(reason)\n",
                    stderr
                )
                return 3
            }
            let committed = try engine.renderProjectionPreview(
                result: original,
                poseAdjustment: pose,
                quality: .committedPreview,
                settings: settings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            guard let result = committed.result,
                  let pixels = try engine.copyResultRGBA(resultHandle: result.handle, settings: settings),
                  pixels.width > 0,
                  pixels.height > 0 else {
                fputs("raw1-canvas-smoke committed projection has no RGBA pixels\n", stderr)
                return 3
            }

            var minX = pixels.width
            var minY = pixels.height
            var maxX = -1
            var maxY = -1
            pixels.data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for y in 0..<pixels.height {
                    for x in 0..<pixels.width where bytes[y * pixels.bytesPerRow + x * 4 + 3] > 0 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else {
                fputs("raw1-canvas-smoke committed projection has no covered pixels\n", stderr)
                return 3
            }

            let leftBand = minX
            let rightBand = pixels.width - 1 - maxX
            let topBand = minY
            let bottomBand = pixels.height - 1 - maxY
            let horizontalAllowance = max(4, Int(ceil(Double(pixels.width) * 0.01)))
            let verticalAllowance = max(4, Int(ceil(Double(pixels.height) * 0.01)))
            let coverageNotClipped = minX > 0 && minY > 0
                && maxX < pixels.width - 1 && maxY < pixels.height - 1
            let excessTransparentBand = max(leftBand, rightBand) > horizontalAllowance * 2
                || max(topBand, bottomBand) > verticalAllowance * 2
            let coverageCenterX = Double(minX + maxX) * 0.5
            let coverageCenterY = Double(minY + maxY) * 0.5
            let canvasCenterX = Double(pixels.width - 1) * 0.5
            let canvasCenterY = Double(pixels.height - 1) * 0.5
            let canvasCentered = abs(coverageCenterX - canvasCenterX) <= Double(horizontalAllowance)
                && abs(coverageCenterY - canvasCenterY) <= Double(verticalAllowance)
                && abs(leftBand - rightBand) <= horizontalAllowance * 2
                && abs(topBand - bottomBand) <= verticalAllowance * 2
            let geometry = result.diagnostics["geometry"]?.stringValue
            let passed = geometry == "camera"
                && coverageNotClipped
                && !excessTransparentBand
                && canvasCentered
            let report = Raw1CanvasSmokeReport(
                artifact: "raw1-canvas-smoke",
                passed: passed,
                imageCount: inputURLs.count,
                pitchDegrees: pose.pitchDegrees,
                yawDegrees: pose.yawDegrees,
                rollDegrees: pose.rollDegrees,
                canvasWidth: pixels.width,
                canvasHeight: pixels.height,
                coverageMinX: minX,
                coverageMinY: minY,
                coverageMaxX: maxX,
                coverageMaxY: maxY,
                leftBand: leftBand,
                rightBand: rightBand,
                topBand: topBand,
                bottomBand: bottomBand,
                coverageNotClipped: coverageNotClipped,
                excessTransparentBand: excessTransparentBand,
                canvasCentered: canvasCentered,
                geometry: geometry,
                rendererRequested: result.diagnostics["preview_renderer_requested"]?.stringValue,
                rendererUsed: result.diagnostics["preview_renderer_used"]?.stringValue,
                rendererFallback: result.diagnostics["preview_renderer_fallback"]?.boolValue,
                message: passed
                    ? "Dynamic projection canvas contains and centers all covered pixels without a one-sided transparent band."
                    : "Dynamic projection canvas is clipped, off-center, or contains an excessive transparent band."
            )
            let provenance = try makeProvenance(
                inputURLs: inputURLs,
                configuration: [
                    "artifact": "raw1-canvas-smoke",
                    "settings": try stableJSONString(settings),
                    "pose": try stableJSONString(pose),
                    "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                ],
                includePythonOracle: false
            )
            try writeJSON(report, to: outputURL, provenance: provenance)
            try printJSON(report)
            return passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func projectionDragSmoke(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        var pose = PoseAdjustment(pitchDegrees: 2.5, yawDegrees: -4.0, rollDegrees: 0.0)
        var samples = 20
        var caseID: String?
        var outputURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case":
                index += 1
                guard index < arguments.count,
                      ["3raw", "4raw", "7raw"].contains(arguments[index]) else {
                    fputs("projection-drag-smoke requires 3raw, 4raw, or 7raw after --case\n", stderr)
                    return 2
                }
                caseID = arguments[index]
            case "--pitch":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("projection-drag-smoke requires a number after --pitch\n", stderr)
                    return 2
                }
                pose.pitchDegrees = value
            case "--yaw":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("projection-drag-smoke requires a number after --yaw\n", stderr)
                    return 2
                }
                pose.yawDegrees = value
            case "--roll":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    fputs("projection-drag-smoke requires a number after --roll\n", stderr)
                    return 2
                }
                pose.rollDegrees = value
            case "--samples":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 5 else {
                    fputs("projection-drag-smoke requires an integer >= 5 after --samples\n", stderr)
                    return 2
                }
                samples = value
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("projection-drag-smoke requires a path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--optimize-distortion":
                settings.optimizeDistortion = true
            case "--multiband":
                settings.blendMode = "multiband"
            case "--no-blend-after-drag":
                settings.blendAfterProjectionDrag = false
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard let caseID else {
            fputs("projection-drag-smoke requires --case 3raw|4raw|7raw\n", stderr)
            return 2
        }
        guard paths.count >= 2 else {
            fputs("projection-drag-smoke requires at least two image paths\n", stderr)
            return 2
        }
        let expectedImageCount = caseID == "3raw" ? 3 : (caseID == "4raw" ? 4 : 7)
        guard paths.count == expectedImageCount else {
            fputs("projection-drag-smoke --case \(caseID) requires exactly \(expectedImageCount) image paths\n", stderr)
            return 2
        }
        do {
            let engine = try NativeEngineBridge()
            let preview = try engine.runPreview(
                paths: paths.map { URL(fileURLWithPath: $0) },
                settings: settings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            guard let original = preview.result else {
                try printJSON(preview)
                return 3
            }
            guard original.diagnostics["geometry"]?.stringValue == "camera",
                  original.cameraParams.count == original.sourceImages.count else {
                if let outputURL {
                    try writeJSON(preview, to: outputURL)
                }
                let reason = original.diagnostics["preview_failure_reason"]?.stringValue
                    ?? "camera parameters are unavailable"
                fputs("projection-drag-smoke preview is not camera geometry: \(reason)\n", stderr)
                return 3
            }
            let originalPixels = try engine.copyResultRGBA(resultHandle: original.handle, settings: settings)
            var latencies: [Double] = []
            var dragPreviewPixels: PixelBufferInfo?
            for step in 1...samples {
                var dragPose = pose
                dragPose.yawDegrees += Double(step) * 0.15
                let start = DispatchTime.now().uptimeNanoseconds
                dragPreviewPixels = try engine.renderProjectionDragPreviewPixels(
                    result: original,
                    poseAdjustment: dragPose,
                    settings: settings,
                    progress: { _ in }
                )
                let end = DispatchTime.now().uptimeNanoseconds
                latencies.append(Double(end - start) / 1_000_000.0)
            }
            let originalAfterDrag = try engine.copyResultRGBA(resultHandle: original.handle, settings: settings)
            var commitSettings = settings
            commitSettings.previewRendererBackend = commitSettings.blendMode == "multiband"
                ? "cpu"
                : "metal_quality"
            let commitQuality: RenderQuality = settings.blendAfterProjectionDrag
                ? .committedPreview
                : .geometryCommit
            let commitStarted = DispatchTime.now().uptimeNanoseconds
            let adjusted = try engine.renderProjectionPreview(
                result: original,
                poseAdjustment: pose,
                quality: commitQuality,
                settings: commitSettings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            let commitLatencyMS = Double(
                DispatchTime.now().uptimeNanoseconds - commitStarted
            ) / 1_000_000.0
            let commitLatencyGatePassed = commitQuality != .geometryCommit
                || commitLatencyMS <= 100.0
            guard let adjustedResult = adjusted.result else {
                try printJSON(adjusted)
                return 3
            }
            let adjustedPixels = try engine.copyResultRGBA(resultHandle: adjustedResult.handle, settings: settings)
            let originalSignature = pixelSignature(originalPixels)
            let dragSignature = pixelSignature(dragPreviewPixels)
            let adjustedSignature = pixelSignature(adjustedPixels)
            let dragFrameChanged = dragPreviewPixels != nil && originalSignature != dragSignature
            let committedPixelsChanged = originalPixels != adjustedPixels
            let committedPixelsRetained = originalPixels != nil && originalPixels == adjustedPixels
            let poseIsNonzero = abs(pose.pitchDegrees) > 1e-12
                || abs(pose.yawDegrees) > 1e-12
                || abs(pose.rollDegrees) > 1e-12
            let geometryPersisted = adjustedResult.handle == original.handle
                && (poseIsNonzero
                    ? adjustedResult.cameraParams != original.cameraParams
                    : adjustedResult.cameraParams == original.cameraParams)
            var independentCommitSSIM: Double?
            var independentCommitPassed = !settings.blendAfterProjectionDrag
            if settings.blendAfterProjectionDrag {
                let independent = try engine.renderProjectionPreview(
                    result: adjustedResult,
                    poseAdjustment: pose,
                    quality: .committedPreview,
                    settings: commitSettings,
                    progress: { _ in }
                )
                if let independentResult = independent.result {
                    let independentPixels = try engine.copyResultRGBA(
                        resultHandle: independentResult.handle,
                        settings: settings
                    )
                    independentCommitSSIM = maskedPixelSSIM(adjustedPixels, independentPixels)
                    independentCommitPassed = independentResult.cameraParams == adjustedResult.cameraParams
                        && (independentCommitSSIM ?? 0) >= 0.999
                }
            }
            let changed = dragFrameChanged
                && (settings.blendAfterProjectionDrag ? committedPixelsChanged : geometryPersisted)
            let sortedLatencies = latencies.sorted()
            let medianLatency = percentile(sorted: sortedLatencies, fraction: 0.50)
            let p95Latency = percentile(sorted: sortedLatencies, fraction: 0.95)
            let maxLatency = sortedLatencies.last ?? 0.0
            let latencyOK = medianLatency <= 80.0 && p95Latency <= 150.0 && maxLatency <= 250.0
            let dragWidth = dragPreviewPixels?.width ?? 0
            let dragHeight = dragPreviewPixels?.height ?? 0
            let dimensionOK = dragWidth > 0
                && dragHeight > 0
                && (paths.count != 7 || max(dragWidth, dragHeight) >= 720)
            let originalAfterCommit = try engine.copyResultRGBA(
                resultHandle: original.handle,
                settings: settings
            )
            let originalStillValid = originalAfterDrag != nil && originalAfterCommit != nil
            let committedRendererRequested = adjustedResult.diagnostics["preview_renderer_requested"]?.stringValue
            let committedRendererUsed = adjustedResult.diagnostics["preview_renderer_used"]?.stringValue
            let committedRendererFallback = adjustedResult.diagnostics["preview_renderer_fallback"]?.boolValue
            let committedRendererPassed: Bool
            if !settings.blendAfterProjectionDrag {
                committedRendererPassed = true
            } else if settings.blendMode == "multiband" {
                committedRendererPassed = committedRendererRequested == "cpu"
                    && committedRendererUsed?.contains("cpu") == true
                    && committedRendererFallback != true
            } else {
                committedRendererPassed = committedRendererRequested == "metal_quality"
                    && committedRendererUsed == "metal_quality"
                    && committedRendererFallback == false
            }
            let commitBehaviorOK: Bool
            if settings.blendAfterProjectionDrag {
                commitBehaviorOK = commitQuality == .committedPreview
                    && committedPixelsChanged
                    && independentCommitPassed
                    && committedRendererPassed
            } else {
                commitBehaviorOK = commitQuality == .geometryCommit
                    && committedPixelsRetained
                    && geometryPersisted
            }
            let success = changed
                && commitBehaviorOK
                && commitLatencyGatePassed
                && latencyOK
                && dimensionOK
                && originalStillValid
            let report = ProjectionDragSmokeReport(
                artifact: "projection-drag-smoke",
                caseID: caseID,
                imageCount: paths.count,
                success: success,
                inputCount: paths.count,
                samples: samples,
                originalSignature: originalSignature,
                dragPreviewSignature: dragSignature,
                adjustedSignature: adjustedSignature,
                changed: changed,
                dragFrameChanged: dragFrameChanged,
                committedPixelsChanged: committedPixelsChanged,
                committedPixelsRetained: committedPixelsRetained,
                geometryPersisted: geometryPersisted,
                independentCommitSSIM: independentCommitSSIM,
                independentCommitPassed: independentCommitPassed,
                medianLatencyMS: medianLatency,
                p95LatencyMS: p95Latency,
                maxLatencyMS: maxLatency,
                commitLatencyMS: commitLatencyMS,
                commitLatencyGatePassed: commitLatencyGatePassed,
                originalWidth: originalPixels?.width ?? 0,
                originalHeight: originalPixels?.height ?? 0,
                dragPreviewWidth: dragWidth,
                dragPreviewHeight: dragHeight,
                committedWidth: adjustedPixels?.width ?? adjustedResult.panorama.width,
                committedHeight: adjustedPixels?.height ?? adjustedResult.panorama.height,
                dimensionGatePassed: dimensionOK,
                blendAfterDrag: settings.blendAfterProjectionDrag,
                commitQuality: commitQuality.rawValue,
                committedGeometry: adjustedResult.diagnostics["geometry"]?.stringValue,
                committedBlendMode: adjustedResult.diagnostics["blend_mode"]?.stringValue,
                committedRendererRequested: committedRendererRequested,
                committedRendererUsed: committedRendererUsed,
                committedRendererFallback: committedRendererFallback,
                committedRendererPassed: committedRendererPassed,
                originalHandleStillValid: originalStillValid,
                originalHandle: original.handle,
                adjustedHandle: adjustedResult.handle,
                pose: pose,
                message: success
                    ? "Projection drag preview met pixel, geometry, dimension, drag/commit latency, commit, and handle-validity gates."
                    : "Projection drag preview did not satisfy pixel, geometry, dimension, drag/commit latency, commit, or handle-validity gates."
            )
            if let outputURL {
                let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
                let provenance = try makeProvenance(
                    inputURLs: inputURLs,
                    configuration: [
                        "artifact": "projection-drag-smoke",
                        "case_id": caseID,
                        "image_count": String(inputURLs.count),
                        "samples": String(samples),
                        "settings": try stableJSONString(settings),
                        "commit_settings": try stableJSONString(commitSettings),
                        "pose": try stableJSONString(pose),
                        "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                    ],
                    includePythonOracle: false
                )
                try writeJSON(report, to: outputURL, provenance: provenance)
            }
            try printJSON(report)
            return success ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    final class CancellationSmokeState: @unchecked Sendable {
        let condition = NSCondition()
        var stages: [String] = []
        var terminal = "operation did not finish"
        var cleanupOutcome = "unreported"
        var finished = false

        func record(stage: String) {
            condition.lock()
            if stages.last != stage {
                stages.append(stage)
            }
            condition.broadcast()
            condition.unlock()
        }

        func finish(_ message: String, cleanupOutcome: String = "unreported") {
            condition.lock()
            terminal = message
            self.cleanupOutcome = cleanupOutcome
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func waitForTrigger(
            timeout: TimeInterval,
            matches: (String) -> Bool
        ) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let stage = stages.first(where: matches) {
                    return stage
                }
                if finished || !condition.wait(until: deadline) {
                    return nil
                }
            }
        }

        func waitForFinish(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while !finished {
                if !condition.wait(until: deadline) {
                    return false
                }
            }
            return true
        }

        func snapshot() -> (
            terminal: String,
            stages: [String],
            finished: Bool,
            cleanupOutcome: String
        ) {
            condition.lock()
            defer { condition.unlock() }
            return (terminal, stages, finished, cleanupOutcome)
        }
    }

    static func cancellationSmoke(arguments: [String]) -> Int32 {
        var operation = "preview"
        var outputURL: URL?
        var workingSetBudgetMB = 0
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--operation":
                index += 1
                guard index < arguments.count else {
                    fputs("cancellation-smoke requires preview, drag, or export after --operation\n", stderr)
                    return 2
                }
                operation = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("cancellation-smoke requires a report path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--working-set-budget-mb":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      value >= 0 else {
                    fputs("cancellation-smoke requires a nonnegative integer after --working-set-budget-mb\n", stderr)
                    return 2
                }
                workingSetBudgetMB = value
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        guard ["preview", "drag", "export"].contains(operation) else {
            fputs("cancellation-smoke --operation must be preview, drag, or export\n", stderr)
            return 2
        }
        guard paths.count >= 2 else {
            fputs("cancellation-smoke requires at least two image paths\n", stderr)
            return 2
        }
        do {
            let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard missing.isEmpty else {
                fputs("cancellation-smoke missing input: \(missing.map(\.path).joined(separator: ", "))\n", stderr)
                return 2
            }
            let engine = try NativeEngineBridge()
            let jobID: UInt64 = operation == "preview" ? 9_001 : (operation == "drag" ? 9_002 : 9_003)
            let state = CancellationSmokeState()
            let started = Date()
            var settings = StitchSettings()
            settings.astroGeometry = "camera"
            settings.displayStretch = false
            let stageName: String
            let stageMatches: @Sendable (String) -> Bool
            var result: StitchResult?
            switch operation {
            case "drag", "export":
                let preview = try engine.runPreview(paths: urls, settings: settings) { _ in }
                result = preview.result
                guard result != nil else {
                    throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "cancellation-smoke could not create a camera preview for \(operation)"])
                }
                if operation == "export",
                   result?.projectionGeometryState != .verifiedCamera
                    || result?.geometryQualityGatePassed != true {
                    let refinement = try engine.refineAstroFullResolution(
                        result: result!,
                        settings: settings,
                        progress: { _ in }
                    )
                    guard refinement.success, refinement.passed else {
                        throw NSError(
                            domain: "PanoLumeRegression",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "cancellation-smoke export setup requires a verified Camera result; full-resolution refinement failed: \(refinement.message)"
                            ]
                        )
                    }
                    result = try engine.applyAstroRefinement(
                        to: result!,
                        refinement: refinement,
                        progress: { _ in }
                    ).result
                    guard result?.projectionGeometryState == .verifiedCamera,
                          result?.geometryQualityGatePassed == true else {
                        throw NSError(
                            domain: "PanoLumeRegression",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "cancellation-smoke export setup did not apply verified Camera geometry"
                            ]
                        )
                    }
                }
                if operation == "drag" {
                    stageName = "Warping camera projection preview"
                    stageMatches = { $0.localizedCaseInsensitiveContains("Warping") }
                } else {
                    stageName = "Preparing full-resolution export image"
                    stageMatches = { $0 == "Preparing full-resolution export image" }
                }
            default:
                result = nil
                stageName = "Loading image"
                stageMatches = { $0.hasPrefix("Loading image") }
            }
            let scratchDirectory = URL(
                fileURLWithPath: "/private/tmp/panolume-cancellation-\(jobID)",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: scratchDirectory)
            try FileManager.default.createDirectory(
                at: scratchDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: scratchDirectory) }
            let exportURL = scratchDirectory.appendingPathComponent("cancelled-export.tiff")
            let partialPaths = [exportURL.path, exportURL.path + ".panolume-partial"]
                + urls.indices.map { exportURL.path + ".panolume-partial.source-\($0).rgb16" }
            let operationToRun = operation
            let settingsToRun = settings
            let resultToRun = result
            let workingSetBudgetToRun = workingSetBudgetMB
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    switch operationToRun {
                    case "drag":
                        let pixels = try engine.renderProjectionDragPreviewPixels(
                            result: resultToRun!,
                            poseAdjustment: PoseAdjustment(pitchDegrees: 2.5, yawDegrees: -4.0, rollDegrees: 0.0),
                            settings: settingsToRun,
                            jobID: jobID
                        ) { event in
                            state.record(stage: event.stage)
                        }
                        state.finish(
                            pixels == nil
                                ? "Native operation cancelled."
                                : "native drag unexpectedly completed"
                        )
                    case "export":
                        var exportSettings = ExportSettings(
                            rendererBackend: "cpu",
                            bitDepth: 16,
                            workingSetBudgetMB: workingSetBudgetToRun
                        )
                        exportSettings.maxOutputSide = 2_000
                        let response = try engine.exportFullResolution(
                            result: resultToRun!,
                            outputURL: exportURL,
                            settings: exportSettings,
                            jobID: jobID
                        ) { event in
                            state.record(stage: event.stage)
                        }
                        let cleanup = response.result?.diagnostics["export_profile"]?["cleanup_outcome"]?.stringValue
                            ?? "unreported"
                        state.finish(
                            response.success
                                ? "native export unexpectedly completed"
                                : response.message,
                            cleanupOutcome: cleanup
                        )
                    default:
                        _ = try engine.runPreview(paths: urls, settings: settingsToRun, jobID: jobID) { event in
                            state.record(stage: event.stage)
                        }
                        state.finish("native preview unexpectedly completed")
                    }
                } catch {
                    state.finish(error.localizedDescription)
                }
            }
            let reachedStage = state.waitForTrigger(timeout: 120, matches: stageMatches)
            if reachedStage != nil {
                engine.cancel(jobId: jobID)
            } else {
                // A stage timeout is itself evidence, but still cancel and join
                // the worker so the harness never abandons native work.
                engine.cancel(jobId: jobID)
            }
            let backgroundFinished = state.waitForFinish(timeout: 180)
            if !backgroundFinished {
                engine.cancel(jobId: jobID)
            }
            let snapshot = state.snapshot()
            if operation == "export" {
                let cleanupDeadline = Date().addingTimeInterval(5)
                while Date() < cleanupDeadline,
                      partialPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let remainingArtifacts = operation == "export"
                ? partialPaths.filter { FileManager.default.fileExists(atPath: $0) }
                : []
            let partialOutputExists = !remainingArtifacts.isEmpty
            let terminalCancelled = snapshot.terminal.localizedCaseInsensitiveContains("cancelled")
            let nativeCleanupPassed = operation != "export"
                || snapshot.cleanupOutcome == "completed"
                || snapshot.cleanupOutcome == "not_required"
            let report = CancellationSmokeReport(
                artifact: "cancellation-smoke",
                caseID: operation,
                imageCount: urls.count,
                passed: reachedStage != nil
                    && backgroundFinished
                    && terminalCancelled
                    && nativeCleanupPassed
                    && !partialOutputExists,
                operation: operation,
                inputCount: urls.count,
                jobID: jobID,
                cancellationRequestedAfterStage: reachedStage ?? stageName,
                terminalMessage: snapshot.terminal,
                elapsedSeconds: Date().timeIntervalSince(started),
                partialOutputExists: partialOutputExists,
                triggerReached: reachedStage != nil,
                backgroundFinished: backgroundFinished,
                observedStages: snapshot.stages,
                cleanupOutcome: snapshot.cleanupOutcome,
                remainingArtifacts: remainingArtifacts,
                workingSetBudgetMB: workingSetBudgetMB,
                setupGeometryState: result?.projectionGeometryState?.rawValue
            )
            if let outputURL {
                let provenance = try makeProvenance(
                    inputURLs: urls,
                    configuration: [
                        "artifact": "cancellation-smoke",
                        "case_id": operation,
                        "image_count": String(urls.count),
                        "operation": operation,
                        "working_set_budget_mb": String(workingSetBudgetMB),
                        "settings": try stableJSONString(settings),
                        "ordered_paths": urls.map(\.path).joined(separator: "\n"),
                    ],
                    includePythonOracle: false
                )
                try writeJSON(report, to: outputURL, provenance: provenance)
            }
            try printJSON(report)
            return report.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func externalWorkingSetCalibration(arguments: [String]) -> Int32 {
        var outputURL: URL?
        var expectedExitCode: Int32 = 0
        var childArguments: [String] = []
        var index = 0
        var parsingChildArguments = false
        while index < arguments.count {
            let argument = arguments[index]
            if parsingChildArguments {
                childArguments.append(argument)
            } else {
                switch argument {
                case "--output":
                    index += 1
                    guard index < arguments.count else {
                        fputs("external-working-set-calibration requires a report path after --output\n", stderr)
                        return 2
                    }
                    outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                case "--expected-exit-code":
                    index += 1
                    guard index < arguments.count,
                          let value = Int32(arguments[index]) else {
                        fputs("external-working-set-calibration requires an integer after --expected-exit-code\n", stderr)
                        return 2
                    }
                    expectedExitCode = value
                case "--":
                    parsingChildArguments = true
                default:
                    fputs("external-working-set-calibration options must precede --\n", stderr)
                    return 2
                }
            }
            index += 1
        }
        guard let outputURL else {
            fputs("external-working-set-calibration requires --output report.json\n", stderr)
            return 2
        }
        guard !childArguments.isEmpty else {
            fputs("external-working-set-calibration requires a child command after --\n", stderr)
            return 2
        }
        guard childArguments.first != "external-working-set-calibration" else {
            fputs("external-working-set-calibration refuses recursive calibration\n", stderr)
            return 2
        }

        let fileManager = FileManager.default
        let scratchDirectory = URL(
            fileURLWithPath: "/private/tmp/panolume-external-rss-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratchDirectory) }
            let stdoutURL = scratchDirectory.appendingPathComponent("stdout.txt")
            let stderrURL = scratchDirectory.appendingPathComponent("stderr.txt")
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let executableURL = try regressionExecutableURL()
            let executableSHA256 = try sha256File(executableURL)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = childArguments
            process.currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            process.environment = RuntimeEnvironment.normalized()
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            let sampleInterval = 0.1
            let started = Date()
            try process.run()
            var peakRSSMB: Double?
            var sampleCount = 0
            repeat {
                if let rss = externalResidentMemoryMB(processIdentifier: process.processIdentifier) {
                    peakRSSMB = max(peakRSSMB ?? 0, rss)
                    sampleCount += 1
                }
                if process.isRunning {
                    Thread.sleep(forTimeInterval: sampleInterval)
                }
            } while process.isRunning
            process.waitUntilExit()
            try stdoutHandle.synchronize()
            try stderrHandle.synchronize()

            let stdoutTail = try textTail(of: stdoutURL, maximumBytes: 16 * 1024)
            let stderrTail = try textTail(of: stderrURL, maximumBytes: 16 * 1024)
            let report = ExternalWorkingSetCalibrationReport(
                artifact: "external-working-set-calibration",
                passed: process.terminationStatus == expectedExitCode
                    && sampleCount > 0
                    && peakRSSMB?.isFinite == true,
                childArguments: childArguments,
                childExitCode: process.terminationStatus,
                expectedExitCode: expectedExitCode,
                externalPeakRSSMB: peakRSSMB,
                sampleCount: sampleCount,
                sampleIntervalSeconds: sampleInterval,
                elapsedSeconds: Date().timeIntervalSince(started),
                regressionExecutableSHA256: executableSHA256,
                stdoutTail: stdoutTail,
                stderrTail: stderrTail
            )
            let inputURLs = childArguments.compactMap { argument -> URL? in
                let url = URL(fileURLWithPath: argument).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    return nil
                }
                return url
            }
            let provenance = try makeProvenance(
                inputURLs: inputURLs,
                configuration: [
                    "artifact": "external-working-set-calibration",
                    "child_arguments": childArguments.joined(separator: "\n"),
                    "expected_exit_code": String(expectedExitCode),
                    "sample_interval_seconds": String(sampleInterval),
                ],
                includePythonOracle: false
            )
            try writeJSON(report, to: outputURL, provenance: provenance)
            try printJSON(report)
            return report.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func externalResidentMemoryMB(processIdentifier: Int32) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(processIdentifier)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                  ),
                  let rssKB = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return rssKB / 1024.0
        } catch {
            return nil
        }
    }

    static func textTail(of url: URL, maximumBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let offset = length > UInt64(maximumBytes) ? length - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: offset)
        return String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func rerenderControlPoints(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        var expectDisconnected = false
        var caseID: String?
        var outputURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case":
                index += 1
                guard index < arguments.count,
                      ["camera-reopt", "homography-reopt", "disconnected"].contains(arguments[index]) else {
                    fputs("rerender-control-points requires camera-reopt, homography-reopt, or disconnected after --case\n", stderr)
                    return 2
                }
                caseID = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("rerender-control-points requires a report path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--optimize-distortion":
                settings.optimizeDistortion = true
            case "--multiband":
                settings.blendMode = "multiband"
            case "--expect-disconnected":
                expectDisconnected = true
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard let caseID else {
            fputs("rerender-control-points requires --case camera-reopt|homography-reopt|disconnected\n", stderr)
            return 2
        }
        guard expectDisconnected == (caseID == "disconnected") else {
            fputs("rerender-control-points --case disconnected must be paired with --expect-disconnected, and other cases must not use it\n", stderr)
            return 2
        }
        guard paths.count >= 2 else {
            fputs("rerender-control-points requires at least two image paths\n", stderr)
            return 2
        }
        let expectedImageCount = caseID == "camera-reopt" ? 3 : 8
        guard paths.count == expectedImageCount else {
            fputs("rerender-control-points --case \(caseID) requires exactly \(expectedImageCount) image paths\n", stderr)
            return 2
        }
        do {
            let engine = try NativeEngineBridge()
            let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let preview = try engine.runPreview(
                paths: inputURLs,
                settings: settings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            guard var result = preview.result else {
                try printJSON(preview)
                return 3
            }
            let originalCount = result.controlPoints.count
            guard originalCount > 8 else {
                fputs("rerender-control-points needs more than 8 control points in the preview result\n", stderr)
                return 3
            }
            if expectDisconnected {
                let disconnectedIndex = paths.count - 1
                result.controlPoints.removeAll {
                    $0.imageAIndex == disconnectedIndex || $0.imageBIndex == disconnectedIndex
                }
                let message: String
                let explicitDisconnected: Bool
                do {
                    let rerendered = try engine.rerenderFromControlPoints(
                        result: result,
                        settings: settings,
                        progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
                    )
                    message = rerendered.message
                    explicitDisconnected = rerendered.result == nil
                        && message.localizedCaseInsensitiveContains("disconnected")
                } catch {
                    message = error.localizedDescription
                    explicitDisconnected = message.localizedCaseInsensitiveContains("disconnected")
                }
                let report = DisconnectedControlPointsReport(
                    artifact: "control-point-rerender",
                    caseID: caseID,
                    imageCount: inputURLs.count,
                    testKind: "disconnected",
                    explicitDisconnectedError: explicitDisconnected,
                    success: explicitDisconnected,
                    geometry: result.diagnostics["geometry"]?.stringValue,
                    disconnectedImageIndex: disconnectedIndex,
                    originalControlPoints: originalCount,
                    editedControlPoints: result.controlPoints.count,
                    message: message
                )
                try emitControlPointReport(
                    report,
                    outputURL: outputURL,
                    inputURLs: inputURLs,
                    caseID: caseID,
                    settings: settings,
                    expectDisconnected: true
                )
                return explicitDisconnected ? 0 : 3
            }
            if let worst = result.controlPoints.enumerated().max(by: { $0.element.error < $1.element.error })?.offset {
                result.controlPoints.remove(at: worst)
            }
            guard var manualPoint = result.controlPoints
                .filter({ point in
                    guard point.imageAIndex >= 0,
                          point.imageAIndex < result.sourceImages.count,
                          point.imageBIndex >= 0,
                          point.imageBIndex < result.sourceImages.count else {
                        return false
                    }
                    let imageA = result.sourceImages[point.imageAIndex]
                    let imageB = result.sourceImages[point.imageBIndex]
                    return point.xA + 3 < Double(imageA.width)
                        && point.yA >= 0
                        && point.yA < Double(imageA.height)
                        && point.xB + 3 < Double(imageB.width)
                        && point.yB >= 0
                        && point.yB < Double(imageB.height)
                })
                .min(by: { $0.error < $1.error }) else {
                fputs("rerender-control-points could not find an in-bounds reliable point to clone\n", stderr)
                return 3
            }
            manualPoint.id = UUID()
            manualPoint.xA += 3
            manualPoint.xB += 3
            manualPoint.error = 0
            manualPoint.isManual = true
            result.controlPoints.append(manualPoint)
            let editedCount = result.controlPoints.count
            let originalGeometry = result.diagnostics["geometry"]?.stringValue
            let rerendered = try engine.rerenderFromControlPoints(
                result: result,
                settings: settings,
                progress: { event in fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr) }
            )
            guard let rerenderedResult = rerendered.result else {
                try printJSON(rerendered)
                return 3
            }
            let rerenderedGeometry = rerenderedResult.diagnostics["geometry"]?.stringValue
            let manualFiltering = rerenderedResult.diagnostics["manual_point_filtering"]
            let manualInput = Int(manualFiltering?["input"]?.numberValue ?? -1)
            let manualAccepted = Int(manualFiltering?["accepted"]?.numberValue ?? -1)
            let manualRejected = Int(manualFiltering?["rejected"]?.numberValue ?? -1)
            let manualReason = manualFiltering?["reason"]?.stringValue
                ?? "manual-point filtering diagnostics are missing"
            let manualAccountingPassed = manualInput == 1
                && manualAccepted >= 0
                && manualRejected >= 0
                && manualAccepted + manualRejected == manualInput
            let acceptedManualPoints = rerenderedResult.controlPoints.filter(\.isManual).count
            let manualRoundTripPassed = manualAccountingPassed
                && acceptedManualPoints == manualAccepted
            let expectedGeometry = caseID == "camera-reopt" ? "camera" : "homography"
            let success = rerenderedResult.controlPoints.count > 0
                && rerenderedResult.handle != result.handle
                && originalGeometry == expectedGeometry
                && rerenderedGeometry == expectedGeometry
                && manualRoundTripPassed
            let report = RerenderControlPointsReport(
                artifact: "control-point-rerender",
                caseID: caseID,
                imageCount: inputURLs.count,
                testKind: "reoptimize",
                success: success,
                originalGeometry: originalGeometry,
                rerenderedGeometry: rerenderedGeometry,
                originalControlPoints: originalCount,
                editedControlPoints: editedCount,
                rerenderedControlPoints: rerenderedResult.controlPoints.count,
                manualPointInput: manualInput,
                manualPointAccepted: manualAccepted,
                manualPointRejected: manualRejected,
                manualPointReason: manualReason,
                manualPointAccountingPassed: manualAccountingPassed,
                manualPointRoundTripPassed: manualRoundTripPassed,
                originalHandle: result.handle,
                rerenderedHandle: rerenderedResult.handle,
                message: rerendered.message
            )
            try emitControlPointReport(
                report,
                outputURL: outputURL,
                inputURLs: inputURLs,
                caseID: caseID,
                settings: settings,
                expectDisconnected: false
            )
            return success ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func emitControlPointReport<Report: Encodable>(
        _ report: Report,
        outputURL: URL?,
        inputURLs: [URL],
        caseID: String,
        settings: StitchSettings,
        expectDisconnected: Bool
    ) throws {
        guard let outputURL else {
            try printJSON(report)
            return
        }
        let provenance = try makeProvenance(
            inputURLs: inputURLs,
            configuration: [
                "artifact": "control-point-rerender",
                "case_id": caseID,
                "image_count": String(inputURLs.count),
                "expect_disconnected": String(expectDisconnected),
                "settings": try stableJSONString(settings),
                "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
            ]
        )
        try writeJSON(report, to: outputURL, provenance: provenance)
        FileHandle.standardOutput.write(try Data(contentsOf: outputURL))
    }

    static func raw2AutoRefinement(arguments: [String]) -> Int32 {
        var outputURL: URL?
        var lensProfileURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--output" {
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-auto-refinement requires a path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            } else if arguments[index] == "--lens-profile" {
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-auto-refinement requires a path after --lens-profile\n", stderr)
                    return 2
                }
                lensProfileURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            } else {
                paths.append(arguments[index])
            }
            index += 1
        }
        guard let outputURL, paths.count == 8 else {
            fputs("raw2-auto-refinement requires --output report.json and exactly eight 2185→2171 RAW paths\n", stderr)
            return 2
        }
        let expectedNames = stride(from: 2185, through: 2171, by: -2).map { "Z8L_\($0).NEF" }
        let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard inputURLs.map(\.lastPathComponent) == expectedNames else {
            fputs("raw2-auto-refinement inputs must be ordered Z8L_2185.NEF through Z8L_2171.NEF\n", stderr)
            return 2
        }

        do {
            let settings = try raw2Settings(lensProfileURL: lensProfileURL)
            let evidenceBindings = try raw2EvidenceBindings(
                inputURLs: inputURLs,
                settings: settings
            )
            let provenanceInputs = inputURLs + (lensProfileURL.map { [$0] } ?? [])
            let engine = try NativeEngineBridge()
            let preview = try engine.runPreview(paths: inputURLs, settings: settings) { event in
                fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            guard let draft = preview.result else {
                try writeJSON(preview, to: outputURL)
                return 3
            }
            let selectedFilenamePairs = (draft.diagnostics["selected_edges"]?.arrayValue ?? []).compactMap { edge -> [String]? in
                guard let i = edge["i"]?.numberValue,
                      let j = edge["j"]?.numberValue,
                      draft.sourceImages.indices.contains(Int(i)),
                      draft.sourceImages.indices.contains(Int(j)) else {
                    return nil
                }
                return [
                    URL(fileURLWithPath: draft.sourceImages[Int(i)].path).lastPathComponent,
                    URL(fileURLWithPath: draft.sourceImages[Int(j)].path).lastPathComponent,
                ].sorted()
            }
            let correctPair = ["Z8L_2175.NEF", "Z8L_2177.NEF"]
            let wrongPair = ["Z8L_2175.NEF", "Z8L_2183.NEF"]
            let correctPairSelected = selectedFilenamePairs.contains(correctPair)
            let wrongPairSelected = selectedFilenamePairs.contains(wrongPair)
            let draftStatus = draft.diagnostics["preview_status"]?.stringValue
            if draftStatus != "draft_camera_preview" && draftStatus != "unverified_camera_draft" {
                guard let failedAstro = draft.astroRefinement else {
                    try writeJSON(preview, to: outputURL)
                    return 3
                }
                let failureReport = Raw2AutoRefinementReport(
                    passed: false,
                    imageCount: inputURLs.count,
                    geometry: draft.diagnostics["geometry"]?.stringValue,
                    astroRefinementState: failedAstro.state.rawValue,
                    heldOutGatePassed: failedAstro.qualityGatePassed,
                    gridColumns: failedAstro.gridColumns,
                    gridRows: failedAstro.gridRows,
                    correctPairSelected: correctPairSelected,
                    wrongPairSelected: wrongPairSelected,
                    selectedFilenamePairs: selectedFilenamePairs,
                    lensModel: failedAstro.lensModel,
                    astroRefinement: failedAstro,
                    stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                    lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                    lensProfileRequired: lensProfileURL != nil,
                    message: draft.diagnostics["preview_failure_reason"]?.stringValue
                        ?? failedAstro.reason
                )
                let provenance = try makeProvenance(
                    inputURLs: provenanceInputs,
                    configuration: [
                        "artifact": failureReport.artifact,
                        "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                        "settings": try stableJSONString(settings),
                    ],
                    includePythonOracle: false
                )
                try writeJSON(failureReport, to: outputURL, provenance: provenance)
                try printJSON(failureReport)
                return 3
            }
            let refinementEngine = try NativeEngineBridge()
            let refinement = try refinementEngine.refineAstroFullResolution(
                result: draft,
                settings: settings,
                includeWorstStarPatches: true
            ) { event in
                fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            var finalResult = draft
            var finalMessage = refinement.message
            if refinement.passed {
                let applied = try engine.applyAstroRefinement(
                    to: draft,
                    refinement: refinement
                ) { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
                guard let result = applied.result else {
                    try writeJSON(applied, to: outputURL)
                    return 3
                }
                finalResult = result
                finalMessage = applied.message
            }
            let geometry = finalResult.diagnostics["geometry"]?.stringValue
            let gatePassed = refinement.astroRefinement.qualityGatePassed
            let passed = refinement.passed
                && geometry == "camera"
                && gatePassed
                && correctPairSelected
                && !wrongPairSelected
            let report = Raw2AutoRefinementReport(
                passed: passed,
                imageCount: inputURLs.count,
                geometry: geometry,
                astroRefinementState: refinement.astroRefinement.state.rawValue,
                heldOutGatePassed: gatePassed,
                gridColumns: refinement.astroRefinement.gridColumns,
                gridRows: refinement.astroRefinement.gridRows,
                correctPairSelected: correctPairSelected,
                wrongPairSelected: wrongPairSelected,
                selectedFilenamePairs: selectedFilenamePairs,
                lensModel: refinement.astroRefinement.lensModel,
                astroRefinement: refinement.astroRefinement,
                stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                lensProfileRequired: lensProfileURL != nil,
                message: finalMessage
            )
            let provenance = try makeProvenance(
                inputURLs: provenanceInputs,
                configuration: [
                    "artifact": report.artifact,
                    "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                    "settings": try stableJSONString(settings),
                ],
                includePythonOracle: false
            )
            try writeJSON(report, to: outputURL, provenance: provenance)
            try printJSON(report)
            return passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func raw2ManualReopt(arguments: [String]) -> Int32 {
        var fixtureURL: URL?
        var outputURL: URL?
        var lensProfileURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--fixture":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-manual-reopt requires a JSON path after --fixture\n", stderr)
                    return 2
                }
                fixtureURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-manual-reopt requires a report path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--lens-profile":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-manual-reopt requires a path after --lens-profile\n", stderr)
                    return 2
                }
                lensProfileURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        guard let fixtureURL else {
            fputs("raw2-manual-reopt requires --fixture <fixture.json>\n", stderr)
            return 2
        }
        guard paths.count == 8 else {
            fputs("raw2-manual-reopt requires exactly eight raw_2 image paths\n", stderr)
            return 2
        }

        do {
            let fixture = try JSONDecoder().decode(
                Raw2ManualFixture.self,
                from: Data(contentsOf: fixtureURL)
            )
            guard fixture.schemaVersion == 1, fixture.manualPair.points.count == 7 else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "raw_2 fixture must use schema 1 and contain seven manual points"]
                )
            }
            let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let inputNames = inputURLs.map(\.lastPathComponent)
            guard inputNames == fixture.importOrder else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "raw_2 inputs must follow the fixture's 2185→2171 import order"]
                )
            }

            let engine = try NativeEngineBridge()
            let settings = try raw2Settings(lensProfileURL: lensProfileURL)
            let evidenceBindings = try raw2EvidenceBindings(
                inputURLs: inputURLs,
                settings: settings
            )
            let provenanceInputs = inputURLs + [fixtureURL]
                + (lensProfileURL.map { [$0] } ?? [])
            let preview = try engine.runPreview(
                paths: inputURLs,
                settings: settings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            guard var result = preview.result else {
                try printJSON(preview)
                return 3
            }
            let previewGeometry = result.diagnostics["geometry"]?.stringValue
            let previewStatus = result.diagnostics["preview_status"]?.stringValue
            let indexByFilename = Dictionary(
                uniqueKeysWithValues: result.sourceImages.enumerated().map {
                    (URL(fileURLWithPath: $0.element.path).lastPathComponent, $0.offset)
                }
            )
            guard let wrongA = indexByFilename[fixture.removePair.fileA],
                  let wrongB = indexByFilename[fixture.removePair.fileB],
                  let manualA = indexByFilename[fixture.manualPair.fileA],
                  let manualB = indexByFilename[fixture.manualPair.fileB] else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "raw_2 fixture filenames were not found in canonical result sources"]
                )
            }
            func pairKey(_ a: Int, _ b: Int) -> String {
                "\(min(a, b))-\(max(a, b))"
            }
            let wrongKey = pairKey(wrongA, wrongB)
            let manualKey = pairKey(manualA, manualB)
            // The fixture deletes the known-wrong edge and adds seven manual
            // observations to the correct edge. Do not silently turn that
            // add operation into Clear Pair: any independently matched
            // automatic stars on the now-correct edge must participate in the
            // same robust filtering and keep the graph observable when a
            // historical manual coordinate is rejected.
            result.controlPoints.removeAll {
                pairKey($0.imageAIndex, $0.imageBIndex) == wrongKey
            }
            for point in fixture.manualPair.points {
                result.controlPoints.append(ControlPoint(
                    imageAIndex: manualA,
                    imageBIndex: manualB,
                    xA: point.xA,
                    yA: point.yA,
                    xB: point.xB,
                    yB: point.yB,
                    error: 0,
                    isManual: true
                ))
            }
            let submittedManualPoints = result.controlPoints.filter(\.isManual)

            let rerendered = try engine.rerenderFromControlPoints(
                result: result,
                settings: settings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            guard let draftRerenderedResult = rerendered.result else {
                try printJSON(rerendered)
                return 3
            }
            let pairRefitManualPoints = draftRerenderedResult.controlPoints.filter(\.isManual)
            var usedPairRefitManualIndices = Set<Int>()
            func manualCoordinateDistanceSquared(
                _ lhs: ControlPoint,
                _ rhs: ControlPoint
            ) -> Double? {
                let sameOrder = lhs.imageAIndex == rhs.imageAIndex
                    && lhs.imageBIndex == rhs.imageBIndex
                let reverseOrder = lhs.imageAIndex == rhs.imageBIndex
                    && lhs.imageBIndex == rhs.imageAIndex
                guard sameOrder || reverseOrder else { return nil }
                let rhsXA = sameOrder ? rhs.xA : rhs.xB
                let rhsYA = sameOrder ? rhs.yA : rhs.yB
                let rhsXB = sameOrder ? rhs.xB : rhs.xA
                let rhsYB = sameOrder ? rhs.yB : rhs.yA
                return pow(lhs.xA - rhsXA, 2)
                    + pow(lhs.yA - rhsYA, 2)
                    + pow(lhs.xB - rhsXB, 2)
                    + pow(lhs.yB - rhsYB, 2)
            }
            let pairRefitIndexByInput: [Int?] = submittedManualPoints.map { point in
                let match = pairRefitManualPoints.indices
                    .filter { !usedPairRefitManualIndices.contains($0) }
                    .compactMap { acceptedIndex -> (Int, Double)? in
                        guard let distance = manualCoordinateDistanceSquared(
                            point, pairRefitManualPoints[acceptedIndex]
                        ) else { return nil }
                        return (acceptedIndex, distance)
                    }
                    .min { $0.1 < $1.1 }
                guard let match, match.1 <= 0.01 else { return nil }
                usedPairRefitManualIndices.insert(match.0)
                return match.0
            }
            if !rerendered.success {
                let selectedKeys = Set(
                    (draftRerenderedResult.diagnostics["selected_edges"]?.arrayValue ?? []).compactMap { edge -> String? in
                        guard let i = edge["i"]?.numberValue,
                              let j = edge["j"]?.numberValue else { return nil }
                        return pairKey(Int(i), Int(j))
                    }
                )
                let reportedDraftReason = draftRerenderedResult.diagnostics["manual_point_filtering"]?["reason"]?.stringValue
                let draftRejectionReason = reportedDraftReason == nil
                    || reportedDraftReason == "no manual control points were supplied"
                    ? "Rejected as an invalid, duplicate, or robust pair-refit outlier"
                    : reportedDraftReason!
                let manualPoints = pairRefitIndexByInput.enumerated().map { pointIndex, acceptedIndex in
                    let accepted = acceptedIndex != nil
                    return AstroManualPointRecord(
                        index: pointIndex,
                        accepted: accepted,
                        error: acceptedIndex.map { pairRefitManualPoints[$0].error },
                        reason: accepted
                            ? "Accepted during draft control-point filtering before re-optimization failed."
                            : draftRejectionReason
                    )
                }
                let manualInput = manualPoints.count
                let manualAccepted = manualPoints.filter(\.accepted).count
                let manualRejected = manualInput - manualAccepted
                let stretched = try engine.copyResultRGBA(
                    resultHandle: draftRerenderedResult.handle,
                    settings: settings
                )
                var linearSettings = settings
                linearSettings.displayStretch = false
                let linear = try engine.copyResultRGBA(
                    resultHandle: draftRerenderedResult.handle,
                    settings: linearSettings
                )
                var transparentSamples = 0
                var opaqueSamples = 0
                if let stretched {
                    stretched.data.withUnsafeBytes { raw in
                        guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        let step = max(1, (stretched.width * stretched.height) / 200_000)
                        var pixel = 0
                        while pixel < stretched.width * stretched.height {
                            let y = pixel / stretched.width
                            let x = pixel % stretched.width
                            let alpha = bytes[y * stretched.bytesPerRow + x * 4 + 3]
                            if alpha == 0 { transparentSamples += 1 }
                            if alpha == 255 { opaqueSamples += 1 }
                            pixel += step
                        }
                    }
                }
                let report = Raw2ManualReoptReport(
                    artifact: "raw2-manual-reopt",
                    success: false,
                    imageCount: inputURLs.count,
                    previewGeometry: previewGeometry,
                    rerenderedGeometry: draftRerenderedResult.diagnostics["geometry"]?.stringValue,
                    previewStatus: previewStatus,
                    rerenderedStatus: draftRerenderedResult.diagnostics["preview_status"]?.stringValue,
                    reoptimizationMethod: draftRerenderedResult.diagnostics["reoptimization_method"]?.stringValue,
                    correctPair: [min(manualA, manualB), max(manualA, manualB)],
                    wrongPair: [min(wrongA, wrongB), max(wrongA, wrongB)],
                    correctPairSelected: selectedKeys.contains(manualKey),
                    wrongPairSelected: selectedKeys.contains(wrongKey),
                    manualInput: manualInput,
                    manualAccepted: manualAccepted,
                    manualRejected: manualRejected,
                    manualAccountingPassed: manualAccepted + manualRejected == manualInput,
                    manualPoints: manualPoints,
                    geometryGatePassed: false,
                    astroRefinementState: draftRerenderedResult.diagnostics["astro_refinement"]?["state"]?.stringValue
                        ?? AstroRefinementState.failed.rawValue,
                    astroRefinement: draftRerenderedResult.astroRefinement,
                    heldOutGatePassed: false,
                    dirtyCleared: false,
                    transparentPreviewPassed: transparentSamples > 0 && opaqueSamples > 0,
                    displayStretchChangedPixels: pixelSignature(stretched) != pixelSignature(linear),
                    stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                    lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                    lensProfileRequired: lensProfileURL != nil,
                    message: rerendered.message
                )
                if let outputURL {
                    let provenance = try makeProvenance(
                        inputURLs: provenanceInputs,
                        configuration: [
                            "artifact": report.artifact,
                            "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                            "fixture": fixtureURL.path,
                            "settings": try stableJSONString(settings),
                        ],
                        includePythonOracle: false
                    )
                    try writeJSON(report, to: outputURL, provenance: provenance)
                }
                try printJSON(report)
                return 3
            }
            let refinementEngine = try NativeEngineBridge()
            let refinement = try refinementEngine.refineAstroFullResolution(
                result: draftRerenderedResult,
                settings: settings,
                includeWorstStarPatches: true,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            var rerenderedResult = draftRerenderedResult
            var finalMessage = refinement.message
            var dirtyCleared = false
            if refinement.passed {
                let applied = try engine.applyAstroRefinement(
                    to: draftRerenderedResult,
                    refinement: refinement,
                    progress: { event in
                        fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                    }
                )
                guard let appliedResult = applied.result else {
                    try printJSON(applied)
                    return 3
                }
                rerenderedResult = appliedResult
                finalMessage = applied.message
                dirtyCleared = true
            }
            let selectedKeys = Set(
                (rerenderedResult.diagnostics["selected_edges"]?.arrayValue ?? []).compactMap { edge -> String? in
                    guard let i = edge["i"]?.numberValue,
                          let j = edge["j"]?.numberValue else { return nil }
                    return pairKey(Int(i), Int(j))
                }
            )
            let reportedDraftReason = draftRerenderedResult.diagnostics["manual_point_filtering"]?["reason"]?.stringValue
            let draftRejectionReason = reportedDraftReason == nil
                || reportedDraftReason == "no manual control points were supplied"
                ? "Rejected as an invalid, duplicate, or robust pair-refit outlier"
                : reportedDraftReason!
            let manualPoints = pairRefitIndexByInput.enumerated().map { inputIndex, pairRefitIndex in
                guard let pairRefitIndex else {
                    return AstroManualPointRecord(
                        index: inputIndex,
                        accepted: false,
                        error: nil,
                        reason: draftRejectionReason
                    )
                }
                guard refinement.manualPoints.indices.contains(pairRefitIndex) else {
                    return AstroManualPointRecord(
                        index: inputIndex,
                        accepted: false,
                        error: nil,
                        reason: "Accepted by pair refit but missing from full-resolution manual-point accounting"
                    )
                }
                let refined = refinement.manualPoints[pairRefitIndex]
                return AstroManualPointRecord(
                    index: inputIndex,
                    accepted: refined.accepted,
                    error: refined.error,
                    reason: refined.reason
                )
            }
            let manualInput = manualPoints.count
            let manualAccepted = manualPoints.filter(\.accepted).count
            let manualRejected = manualInput - manualAccepted
            let manualAccountingPassed = manualInput == 7
                && manualAccepted >= 0
                && manualRejected >= 0
                && manualAccepted + manualRejected == 7

            let stretched = try engine.copyResultRGBA(
                resultHandle: rerenderedResult.handle,
                settings: settings
            )
            var linearSettings = settings
            linearSettings.displayStretch = false
            let linear = try engine.copyResultRGBA(
                resultHandle: rerenderedResult.handle,
                settings: linearSettings
            )
            var transparentSamples = 0
            var opaqueSamples = 0
            if let stretched {
                stretched.data.withUnsafeBytes { raw in
                    guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    let step = max(1, (stretched.width * stretched.height) / 200_000)
                    var pixel = 0
                    while pixel < stretched.width * stretched.height {
                        let y = pixel / stretched.width
                        let x = pixel % stretched.width
                        let alpha = bytes[y * stretched.bytesPerRow + x * 4 + 3]
                        if alpha == 0 { transparentSamples += 1 }
                        if alpha == 255 { opaqueSamples += 1 }
                        pixel += step
                    }
                }
            }
            let transparentPreviewPassed = transparentSamples > 0 && opaqueSamples > 0
            let displayStretchChangedPixels = pixelSignature(stretched) != pixelSignature(linear)
            let rerenderedGeometry = rerenderedResult.diagnostics["geometry"]?.stringValue
            let rerenderedStatus = rerenderedResult.diagnostics["preview_status"]?.stringValue
            let geometryGatePassed = rerenderedResult.diagnostics["geometry_gate"]?["passed"]?.boolValue == true
            let astroRefinementState = rerenderedResult.diagnostics["astro_refinement"]?["state"]?.stringValue
                ?? refinement.astroRefinement.state.rawValue
            let heldOutGatePassed = refinement.astroRefinement.qualityGatePassed
            let correctPairSelected = selectedKeys.contains(manualKey)
            let wrongPairSelected = selectedKeys.contains(wrongKey)
            let success = previewGeometry == "camera"
                && (previewStatus == "draft_camera_preview"
                    || previewStatus == "unverified_camera_draft"
                    || previewStatus == "camera_projection_preview")
                && rerenderedGeometry == "camera"
                && rerenderedStatus == "camera_projection_preview"
                && geometryGatePassed
                && heldOutGatePassed
                && dirtyCleared
                && correctPairSelected
                && !wrongPairSelected
                && manualAccountingPassed
                && transparentPreviewPassed
                && displayStretchChangedPixels
            let report = Raw2ManualReoptReport(
                artifact: "raw2-manual-reopt",
                success: success,
                imageCount: inputURLs.count,
                previewGeometry: previewGeometry,
                rerenderedGeometry: rerenderedGeometry,
                previewStatus: previewStatus,
                rerenderedStatus: rerenderedStatus,
                reoptimizationMethod: rerenderedResult.diagnostics["reoptimization_method"]?.stringValue,
                correctPair: [min(manualA, manualB), max(manualA, manualB)],
                wrongPair: [min(wrongA, wrongB), max(wrongA, wrongB)],
                correctPairSelected: correctPairSelected,
                wrongPairSelected: wrongPairSelected,
                manualInput: manualInput,
                manualAccepted: manualAccepted,
                manualRejected: manualRejected,
                manualAccountingPassed: manualAccountingPassed,
                manualPoints: manualPoints,
                geometryGatePassed: geometryGatePassed,
                astroRefinementState: astroRefinementState,
                astroRefinement: refinement.astroRefinement,
                heldOutGatePassed: heldOutGatePassed,
                dirtyCleared: dirtyCleared,
                transparentPreviewPassed: transparentPreviewPassed,
                displayStretchChangedPixels: displayStretchChangedPixels,
                stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                lensProfileRequired: lensProfileURL != nil,
                message: finalMessage
            )
            if let outputURL {
                let provenance = try makeProvenance(
                    inputURLs: provenanceInputs,
                    configuration: [
                        "artifact": report.artifact,
                        "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                        "fixture": fixtureURL.path,
                        "settings": try stableJSONString(settings),
                    ],
                    includePythonOracle: false
                )
                try writeJSON(report, to: outputURL, provenance: provenance)
            }
            try printJSON(report)
            return success ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func raw2ExportPair(arguments: [String]) -> Int32 {
        var outputURL: URL?
        var outputDirectory: URL?
        var lensProfileURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-export-pair requires a report path after --output\n", stderr)
                    return 2
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-export-pair requires a directory after --output-dir\n", stderr)
                    return 2
                }
                outputDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--lens-profile":
                index += 1
                guard index < arguments.count else {
                    fputs("raw2-export-pair requires a path after --lens-profile\n", stderr)
                    return 2
                }
                lensProfileURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                paths.append(arguments[index])
            }
            index += 1
        }
        guard let outputURL, paths.count == 8 else {
            fputs("raw2-export-pair requires --output report.json and exactly eight 2185→2171 RAW paths\n", stderr)
            return 2
        }
        let expectedNames = stride(from: 2185, through: 2171, by: -2).map { "Z8L_\($0).NEF" }
        let inputURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard inputURLs.map(\.lastPathComponent) == expectedNames else {
            fputs("raw2-export-pair inputs must be ordered Z8L_2185.NEF through Z8L_2171.NEF\n", stderr)
            return 2
        }

        do {
            let settings = try raw2Settings(lensProfileURL: lensProfileURL)
            let evidenceBindings = try raw2EvidenceBindings(
                inputURLs: inputURLs,
                settings: settings
            )
            let provenanceInputs = inputURLs + (lensProfileURL.map { [$0] } ?? [])
            let artifactsDirectory = outputDirectory
                ?? outputURL.deletingLastPathComponent().appendingPathComponent(
                    outputURL.deletingPathExtension().lastPathComponent + "-artifacts",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: artifactsDirectory,
                withIntermediateDirectories: true
            )
            let cpuURL = artifactsDirectory.appendingPathComponent("raw2-cpu-rgb16.tiff")
            let metalURL = artifactsDirectory.appendingPathComponent("raw2-metal-quality-rgb16.tiff")
            let thresholds = [
                "coverage_iou_min": 0.999,
                "rgb_ssim_min": 0.999,
                "median_absdiff_max": 0.001,
                "p95_absdiff_max": 0.005,
            ]

            func provenance(cpu: ExportSettings, metal: ExportSettings) throws -> ParityProvenance {
                try makeProvenance(
                    inputURLs: provenanceInputs,
                    configuration: [
                        "artifact": "raw2-export-pair",
                        "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                        "settings": try stableJSONString(settings),
                        "stitch_configuration_sha256": evidenceBindings.configurationSHA256,
                        "lens_profile_sha256": evidenceBindings.lensProfileSHA256,
                        "cpu_export_settings": try stableJSONString(cpu),
                        "metal_export_settings": try stableJSONString(metal),
                        "thresholds": try stableJSONString(thresholds),
                    ],
                    includePythonOracle: false
                )
            }

            let engine = try NativeEngineBridge()
            let preview = try engine.runPreview(paths: inputURLs, settings: settings) { event in
                fputs("raw2 export preview \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            guard let draft = preview.result else {
                try writeJSON(preview, to: outputURL)
                return 3
            }
            let selectedFilenamePairs = (draft.diagnostics["selected_edges"]?.arrayValue ?? []).compactMap { edge -> [String]? in
                guard let i = edge["i"]?.numberValue,
                      let j = edge["j"]?.numberValue,
                      draft.sourceImages.indices.contains(Int(i)),
                      draft.sourceImages.indices.contains(Int(j)) else {
                    return nil
                }
                return [
                    URL(fileURLWithPath: draft.sourceImages[Int(i)].path).lastPathComponent,
                    URL(fileURLWithPath: draft.sourceImages[Int(j)].path).lastPathComponent,
                ].sorted()
            }
            let correctPairSelected = selectedFilenamePairs.contains(["Z8L_2175.NEF", "Z8L_2177.NEF"])
            let wrongPairSelected = selectedFilenamePairs.contains(["Z8L_2175.NEF", "Z8L_2183.NEF"])
            let refinementEngine = try NativeEngineBridge()
            let refinement = try refinementEngine.refineAstroFullResolution(
                result: draft,
                settings: settings,
                includeWorstStarPatches: true
            ) { event in
                fputs("raw2 export refine \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            var verifiedResult = draft
            var geometry = draft.diagnostics["geometry"]?.stringValue
            if refinement.passed {
                let applied = try engine.applyAstroRefinement(
                    to: draft,
                    refinement: refinement
                ) { event in
                    fputs("raw2 export apply \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
                guard let result = applied.result else {
                    try writeJSON(applied, to: outputURL)
                    return 3
                }
                verifiedResult = result
                geometry = result.diagnostics["geometry"]?.stringValue
            }

            var cpuSettings = ExportSettings(rendererBackend: "cpu", bitDepth: 16)
            cpuSettings.maxOutputPixels = 0
            cpuSettings.maxOutputSide = 0
            var metalSettings = ExportSettings(rendererBackend: "metal_quality", bitDepth: 16)
            metalSettings.maxOutputPixels = 0
            metalSettings.maxOutputSide = 0

            guard refinement.passed,
                  refinement.astroRefinement.qualityGatePassed,
                  geometry == "camera",
                  correctPairSelected,
                  !wrongPairSelected else {
                let report = Raw2ExportPairReport(
                    passed: false,
                    imageCount: inputURLs.count,
                    geometry: geometry,
                    astroRefinementState: refinement.astroRefinement.state.rawValue,
                    heldOutGatePassed: refinement.astroRefinement.qualityGatePassed,
                    correctPairSelected: correctPairSelected,
                    wrongPairSelected: wrongPairSelected,
                    resultHandle: verifiedResult.handle,
                    sameResultHandle: true,
                    bitDepth: 16,
                    cpuOutputPath: cpuURL.path,
                    metalOutputPath: metalURL.path,
                    cpuOutputSHA256: nil,
                    metalOutputSHA256: nil,
                    cpuRendererVerified: false,
                    metalQualityRendererVerified: false,
                    metalFallback: false,
                    dimensionsMatch: false,
                    coverageMatch: false,
                    pixelQualityPassed: false,
                    coverageIoU: nil,
                    rgbSSIM: nil,
                    medianAbsDiff: nil,
                    p95AbsDiff: nil,
                    comparison: nil,
                    thresholds: thresholds,
                    cpuExportProfile: nil,
                    metalExportProfile: nil,
                    stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                    lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                    lensProfileRequired: lensProfileURL != nil,
                    message: "Full-resolution Camera refinement did not pass before export: \(refinement.message)"
                )
                try writeJSON(
                    report,
                    to: outputURL,
                    provenance: try provenance(cpu: cpuSettings, metal: metalSettings)
                )
                try printJSON(report)
                return 3
            }

            let verifiedHandle = verifiedResult.handle
            let cpuExport = try engine.exportFullResolution(
                result: verifiedResult,
                outputURL: cpuURL,
                settings: cpuSettings
            ) { event in
                fputs("raw2 CPU export \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            let metalExport = try engine.exportFullResolution(
                result: verifiedResult,
                outputURL: metalURL,
                settings: metalSettings
            ) { event in
                fputs("raw2 Metal export \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
            let sameResultHandle = verifiedResult.handle == verifiedHandle
            let cpuProfile = cpuExport.result?.diagnostics["export_profile"]
            let metalProfile = metalExport.result?.diagnostics["export_profile"]
            let cpuRendererVerified = cpuExport.success
                && cpuProfile?["renderer_used"]?.stringValue == "cpu"
                && cpuProfile?["bit_depth"]?.numberValue == 16
            let metalFallback = metalProfile?["cpu_fallback"]?.boolValue == true
                || metalProfile?["renderer_fallback"]?.boolValue == true
            let metalQualityRendererVerified = metalExport.success
                && metalProfile?["renderer_used"]?.stringValue == "metal_quality"
                && metalProfile?["bit_depth"]?.numberValue == 16
                && !metalFallback

            let comparison = try NativeEngineBridge.compareRGB16TIFFsStreaming(
                first: cpuURL,
                second: metalURL
            )
            let cpuWidth = Int(cpuProfile?["width"]?.numberValue ?? -1)
            let cpuHeight = Int(cpuProfile?["height"]?.numberValue ?? -1)
            let metalWidth = Int(metalProfile?["width"]?.numberValue ?? -1)
            let metalHeight = Int(metalProfile?["height"]?.numberValue ?? -1)
            let dimensionsMatch = comparison.success
                && comparison.bitDepth == 16
                && comparison.samplesPerPixel == 3
                && comparison.width == cpuWidth
                && comparison.height == cpuHeight
                && cpuWidth == metalWidth
                && cpuHeight == metalHeight
            let coverageMatch = (comparison.coverageIoU ?? -.infinity) >= 0.999
            let pixelQualityPassed = (comparison.rgbSSIM ?? -.infinity) >= 0.999
                && (comparison.medianAbsDiff ?? .infinity) <= 0.001
                && (comparison.p95AbsDiff ?? .infinity) <= 0.005
            var failures: [String] = []
            if !sameResultHandle { failures.append("CPU and Metal exports did not use the same verified result handle") }
            if !cpuRendererVerified { failures.append("CPU export profile did not verify unsigned RGB16 CPU output") }
            if !metalQualityRendererVerified { failures.append("Metal Quality did not run without fallback") }
            if !dimensionsMatch { failures.append("CPU and Metal TIFF dimensions or RGB16 formats differ") }
            if !coverageMatch { failures.append("coverage IoU is below 0.999") }
            if !pixelQualityPassed { failures.append("RGB SSIM or absolute-difference gate failed") }
            let passed = failures.isEmpty
            let report = Raw2ExportPairReport(
                passed: passed,
                imageCount: inputURLs.count,
                geometry: geometry,
                astroRefinementState: refinement.astroRefinement.state.rawValue,
                heldOutGatePassed: refinement.astroRefinement.qualityGatePassed,
                correctPairSelected: correctPairSelected,
                wrongPairSelected: wrongPairSelected,
                resultHandle: verifiedHandle,
                sameResultHandle: sameResultHandle,
                bitDepth: 16,
                cpuOutputPath: cpuURL.path,
                metalOutputPath: metalURL.path,
                cpuOutputSHA256: try sha256File(cpuURL),
                metalOutputSHA256: try sha256File(metalURL),
                cpuRendererVerified: cpuRendererVerified,
                metalQualityRendererVerified: metalQualityRendererVerified,
                metalFallback: metalFallback,
                dimensionsMatch: dimensionsMatch,
                coverageMatch: coverageMatch,
                pixelQualityPassed: pixelQualityPassed,
                coverageIoU: comparison.coverageIoU,
                rgbSSIM: comparison.rgbSSIM,
                medianAbsDiff: comparison.medianAbsDiff,
                p95AbsDiff: comparison.p95AbsDiff,
                comparison: comparison,
                thresholds: thresholds,
                cpuExportProfile: cpuProfile,
                metalExportProfile: metalProfile,
                stitchConfigurationSHA256: evidenceBindings.configurationSHA256,
                lensProfileSHA256: evidenceBindings.lensProfileSHA256,
                lensProfileRequired: lensProfileURL != nil,
                message: passed
                    ? "CPU and real Metal Quality RGB16 exports passed streaming parity gates."
                    : failures.joined(separator: "; ")
            )
            try writeJSON(
                report,
                to: outputURL,
                provenance: try provenance(cpu: cpuSettings, metal: metalSettings)
            )
            try printJSON(report)
            return passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runPreviewExportDiagnostic(arguments: [String]) -> Int32 {
        var settings = StitchSettings()
        var exportSettings = ExportSettings(rendererBackend: "preview_tiff_diagnostic", bitDepth: 16)
        var outputPath: String?
        var reportURL: URL?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("preview-export-diagnostic requires a path after --output\n", stderr)
                    return 2
                }
                outputPath = arguments[index]
            case "--report":
                index += 1
                guard index < arguments.count else {
                    fputs("preview-export-diagnostic requires a path after --report\n", stderr)
                    return 2
                }
                reportURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--bit-depth":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("preview-export-diagnostic requires an integer after --bit-depth\n", stderr)
                    return 2
                }
                exportSettings.bitDepth = value
            case "--strip-render":
                exportSettings.rendererBackend = "preview_camera_strip_tiff_diagnostic"
            case "--fullres-render":
                exportSettings.rendererBackend = "fullres_camera_strip_tiff_diagnostic"
            case "--renderer":
                index += 1
                guard index < arguments.count else {
                    fputs("preview-export-diagnostic requires a renderer backend after --renderer\n", stderr)
                    return 2
                }
                exportSettings.rendererBackend = arguments[index]
            case "--max-output-side":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("preview-export-diagnostic requires an integer after --max-output-side\n", stderr)
                    return 2
                }
                exportSettings.maxOutputSide = value
            case "--max-output-pixels":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("preview-export-diagnostic requires an integer after --max-output-pixels\n", stderr)
                    return 2
                }
                exportSettings.maxOutputPixels = value
            case "--optimize-distortion":
                settings.optimizeDistortion = true
            case "--camera":
                settings.astroGeometry = "camera"
            case "--no-guided-refinement":
                settings.cameraModelGuidedRefinement = false
            case "--no-local-refinement":
                settings.cameraModelLocalRefinement = false
            case "--no-texture-refinement":
                settings.cameraModelTextureRefinement = false
            case "--multiband":
                settings.blendMode = "multiband"
            default:
                paths.append(argument)
            }
            index += 1
        }
        guard let outputPath else {
            fputs("preview-export-diagnostic requires --output <path>\n", stderr)
            return 2
        }
        guard paths.count >= 2 else {
            fputs("preview-export-diagnostic requires at least two image paths\n", stderr)
            return 2
        }
        do {
            let engine = try NativeEngineBridge()
            let preview = try engine.runPreview(
                paths: paths.map { URL(fileURLWithPath: $0) },
                settings: settings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            guard let result = preview.result else {
                try printJSON(preview)
                return 3
            }
            let response = try engine.exportFullResolution(
                result: result,
                outputURL: URL(fileURLWithPath: outputPath),
                settings: exportSettings,
                progress: { event in
                    fputs("\(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            if let reportURL {
                try writeJSON(response, to: reportURL)
            }
            try printJSON(response)
            return ParityGate.evaluate(result: response.result).passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    struct ManifestNativeRunReport: Encodable {
        var passed: Bool
        var manifestName: String
        var runnableCases: Int
        var skippedCases: Int
        var failedCases: Int
        var failures: [String]
        var cases: [ManifestNativeCaseRun]

        enum CodingKeys: String, CodingKey {
            case passed
            case manifestName = "manifest_name"
            case runnableCases = "runnable_cases"
            case skippedCases = "skipped_cases"
            case failedCases = "failed_cases"
            case failures
            case cases
        }
    }

    struct ManifestNativeCaseRun: Encodable {
        var id: String
        var status: String
        var message: String
        var inputPaths: [String]
        var outputPath: String?
        var metrics: StitchMetrics?
        var diagnostics: JSONValue?
        var exportProfile: JSONValue?
        var comparison: ParityComparison?
        var gate: ParityGateResult?
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case message
            case inputPaths = "input_paths"
            case outputPath = "output_path"
            case metrics
            case diagnostics
            case exportProfile = "export_profile"
            case comparison
            case gate
            case failures
        }
    }

    struct ManifestNativeRunOptions {
        var settings = StitchSettings()
        var exportSettings: ExportSettings?
        var outputDirectory: URL?
        var allowUnprovenParity = false
    }

    struct PreviewParityOptions {
        var caseID = "preview"
        var settingsMode = "ui-default"
        var orderMode = "original"
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_parity_reports", isDirectory: true)
        var reusePythonOracle = false
        var disableGuidedRefinement = false
        var disableLocalRefinement = false
        var disableTextureRefinement = false
        var disableDisplayStretch = false
        var robustReprojectionPx: Double?
        var robustMinPairInliers: Int?
        var nativeRobustReprojectionPx: Double?
        var nativeRobustMinPairInliers: Int?
        var paths: [String] = []
    }

    struct PreviewParitySuiteOptions {
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_parity_reports", isDirectory: true)
        var caseFilters: Set<String> = []
        var settingsFilters: Set<String> = []
        var orderFilters: Set<String> = []
        var resume = false
        var reusePythonOracle = false
    }

    struct ExportParityOptions {
        var caseID = "export"
        var settingsMode = "ui-default"
        var orderMode = "original"
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_parity_reports", isDirectory: true)
        var renderer = "cpu"
        var bitDepth = 16
        var applyPreviewStretch = false
        var paths: [String] = []
    }

    struct ExportParitySuiteOptions {
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_export_parity_reports", isDirectory: true)
        var caseFilters: Set<String> = []
        var settingsFilters: Set<String> = []
        var orderFilters: Set<String> = []
        var renderer = "cpu"
        var includeStretch = true
        var resume = false
    }

    struct ReleaseValidationOptions {
        var raw2AutoRefinement: URL?
        var raw2ManualReoptimization: URL?
        var raw2ExportPair: URL?
        var raw1CanvasSmoke: URL?
        var ordinaryImageReports: [URL] = []
        var controlPointReports: [URL] = []
        var refinementCancellationReports: [URL] = []
        var projectionReleaseReports: [URL] = []
        var installationReports: [URL] = []
        var output: URL?
        var candidateCertification = false

        // Parsed only by archived parity commands. Focused PanoLume promotion
        // does not populate or require this matrix.
        var previewSuite: URL?
        var cpuExportSuite: URL?
        var metalExportSuite: URL?
        var rawDecode: URL?
        var standardImageReports: [URL] = []
        var dragReports: [URL] = []
        var cancellationReports: [URL] = []
        var perfReports: [URL] = []
    }

    struct ReleaseProvenanceAudit {
        var sourceCommit: String?
        var sourceFingerprint: String?
        var binaryEngineSourceFingerprint: String?
        var regressionExecutableSHA256: String?
        var oracleIdentity: String?
        var metalDylibSHA256: String?
        var artifactCount = 0
    }

    struct RawDecodeParityOptions {
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_raw_decode_reports", isDirectory: true)
        var halfSize = true
        var paths: [String] = []
    }

    struct PreviewRunSummary: Encodable {
        var resultPath: String
        var previewPath: String
        var metrics: StitchMetrics
        var geometry: String?
        var previewStatus: String?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case resultPath = "result_path"
            case previewPath = "preview_path"
            case metrics
            case geometry
            case previewStatus = "preview_status"
            case message
        }
    }

    struct VisualParityMetrics: Encodable {
        var baselineWidth: Int
        var baselineHeight: Int
        var candidateWidth: Int
        var candidateHeight: Int
        var widthDeltaFraction: Double
        var heightDeltaFraction: Double
        var maskIoU: Double
        var maskedSSIM: Double
        var maskedMedianAbsDiff: Double
        var maskedP95AbsDiff: Double
        var comparedPixels: Int
        var alignmentMode: String
        var alignmentOffsetX: Int
        var alignmentOffsetY: Int
        var diffPath: String

        enum CodingKeys: String, CodingKey {
            case baselineWidth = "baseline_width"
            case baselineHeight = "baseline_height"
            case candidateWidth = "candidate_width"
            case candidateHeight = "candidate_height"
            case widthDeltaFraction = "width_delta_fraction"
            case heightDeltaFraction = "height_delta_fraction"
            case maskIoU = "mask_iou"
            case maskedSSIM = "masked_ssim"
            case maskedMedianAbsDiff = "masked_median_absdiff"
            case maskedP95AbsDiff = "masked_p95_absdiff"
            case comparedPixels = "compared_pixels"
            case alignmentMode = "alignment_mode"
            case alignmentOffsetX = "alignment_offset_x"
            case alignmentOffsetY = "alignment_offset_y"
            case diffPath = "diff_path"
        }
    }

    struct TIFFRGBImageInfo: Codable {
        var width: Int
        var height: Int
        var channels: Int
        var bitDepth: Int
        var dtype: String

        enum CodingKeys: String, CodingKey {
            case width
            case height
            case channels
            case bitDepth = "bit_depth"
            case dtype
        }
    }

    struct TIFFRGBChannelMetrics: Codable {
        var ssim: Double
        var medianAbsDiff: Double
        var p95AbsDiff: Double

        enum CodingKeys: String, CodingKey {
            case ssim
            case medianAbsDiff = "median_absdiff"
            case p95AbsDiff = "p95_absdiff"
        }
    }

    /// RGB metrics calculated from the original TIFF sample type.  Unlike the
    /// preview comparator this never sends a 16-bit export through an 8-bit
    /// image display conversion before evaluating it.
    struct TIFFRGBParityMetrics: Codable {
        var baseline: TIFFRGBImageInfo
        var candidate: TIFFRGBImageInfo
        var widthDeltaFraction: Double
        var heightDeltaFraction: Double
        var maskIoU: Double
        var maskedRGBSSIM: Double
        var maskedMedianAbsDiff: Double
        var maskedP95AbsDiff: Double
        var perChannel: [String: TIFFRGBChannelMetrics]
        var comparedPixels: Int
        var diffPath: String

        enum CodingKeys: String, CodingKey {
            case baseline
            case candidate
            case widthDeltaFraction = "width_delta_fraction"
            case heightDeltaFraction = "height_delta_fraction"
            case maskIoU = "mask_iou"
            case maskedRGBSSIM = "masked_rgb_ssim"
            case maskedMedianAbsDiff = "masked_median_absdiff"
            case maskedP95AbsDiff = "masked_p95_absdiff"
            case perChannel = "per_channel"
            case comparedPixels = "compared_pixels"
            case diffPath = "diff_path"
        }
    }

    struct PreviewParityReport: Encodable {
        var passed: Bool
        var caseID: String
        var settingsMode: String
        var inputOrder: String
        var inputPaths: [String]
        var canonicalInputPaths: [String]
        var outputDirectory: String
        var python: PreviewRunSummary
        var nativeDirect: PreviewRunSummary
        var nativeHandles: PreviewRunSummary
        var nativeVsPython: VisualParityMetrics
        var handlesVsPython: VisualParityMetrics
        var handlesVsDirect: VisualParityMetrics
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case caseID = "case_id"
            case settingsMode = "settings_mode"
            case inputOrder = "input_order"
            case inputPaths = "input_paths"
            case canonicalInputPaths = "canonical_input_paths"
            case outputDirectory = "output_directory"
            case python
            case nativeDirect = "native_direct"
            case nativeHandles = "native_handles"
            case nativeVsPython = "native_vs_python"
            case handlesVsPython = "handles_vs_python"
            case handlesVsDirect = "handles_vs_direct"
            case failures
        }
    }

    struct PreviewParitySuiteCase: Encodable {
        var id: String
        var settingsMode: String
        var inputOrder: String
        var status: String
        var reportPath: String?
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case settingsMode = "settings_mode"
            case inputOrder = "input_order"
            case status
            case reportPath = "report_path"
            case failures
        }
    }

    struct PreviewParitySuiteReport: Encodable {
        var passed: Bool
        var outputDirectory: String
        var selectedCount: Int
        var skippedCount: Int
        var cases: [PreviewParitySuiteCase]
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case outputDirectory = "output_directory"
            case selectedCount = "selected_count"
            case skippedCount = "skipped_count"
            case cases
            case failures
        }
    }

    struct ExportParitySuiteCase: Encodable {
        var id: String
        var settingsMode: String
        var inputOrder: String
        var applyPreviewStretch: Bool
        var status: String
        var reportPath: String?
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case settingsMode = "settings_mode"
            case inputOrder = "input_order"
            case applyPreviewStretch = "apply_preview_stretch"
            case status
            case reportPath = "report_path"
            case failures
        }
    }

    struct ExportParitySuiteReport: Encodable {
        var passed: Bool
        var outputDirectory: String
        var renderer: String
        var bitDepth: Int
        var selectedCount: Int
        var skippedCount: Int
        var cases: [ExportParitySuiteCase]
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case outputDirectory = "output_directory"
            case renderer
            case bitDepth = "bit_depth"
            case selectedCount = "selected_count"
            case skippedCount = "skipped_count"
            case cases
            case failures
        }
    }

    struct NativeParityReleaseChecklist: Encodable {
        var astroGeometry: Bool
        var manualReoptimization: Bool
        var exportPair: Bool
        var canvasCoverage: Bool
        var ordinaryImages: Bool
        var controlPoints: Bool
        var refinementCancellation: Bool
        var projectionReleaseBarrier: Bool
        var installationLaunch: Bool

        init(
            astroGeometry: Bool,
            manualReoptimization: Bool,
            exportPair: Bool,
            canvasCoverage: Bool,
            ordinaryImages: Bool,
            controlPoints: Bool,
            refinementCancellation: Bool,
            projectionReleaseBarrier: Bool,
            installationLaunch: Bool
        ) {
            self.astroGeometry = astroGeometry
            self.manualReoptimization = manualReoptimization
            self.exportPair = exportPair
            self.canvasCoverage = canvasCoverage
            self.ordinaryImages = ordinaryImages
            self.controlPoints = controlPoints
            self.refinementCancellation = refinementCancellation
            self.projectionReleaseBarrier = projectionReleaseBarrier
            self.installationLaunch = installationLaunch
        }

        init(
            alignmentQuality: Bool,
            ordinaryImageQuality: Bool,
            controlPointEditing: Bool,
            seamQuality: Bool,
            bitDepth: Bool,
            colorAndLinearHandling: Bool,
            exportCorrectness: Bool,
            memoryUse: Bool,
            performance: Bool,
            cancellationSafety: Bool
        ) {
            self.init(
                astroGeometry: alignmentQuality,
                manualReoptimization: controlPointEditing,
                exportPair: seamQuality && bitDepth && colorAndLinearHandling && exportCorrectness && memoryUse,
                canvasCoverage: alignmentQuality,
                ordinaryImages: ordinaryImageQuality,
                controlPoints: controlPointEditing,
                refinementCancellation: cancellationSafety,
                projectionReleaseBarrier: performance,
                installationLaunch: false
            )
        }

        var allPassed: Bool {
            astroGeometry
                && manualReoptimization
                && exportPair
                && canvasCoverage
                && ordinaryImages
                && controlPoints
                && refinementCancellation
                && projectionReleaseBarrier
                && installationLaunch
        }

        enum CodingKeys: String, CodingKey {
            case astroGeometry = "astro_geometry"
            case manualReoptimization = "manual_reoptimization"
            case exportPair = "export_pair"
            case canvasCoverage = "canvas_coverage"
            case ordinaryImages = "ordinary_images"
            case controlPoints = "control_points"
            case refinementCancellation = "refinement_cancellation"
            case projectionReleaseBarrier = "projection_release_barrier"
            case installationLaunch = "installation_launch"
        }
    }

    struct NativeParityReleaseReport: Encodable {
        var passed: Bool
        var candidateCertification: Bool
        var sourceCertificationMatch: Bool
        var checklist: NativeParityReleaseChecklist
        var artifacts: [String: [String]]
        var failures: [String]
        var reportPayloadSHA256: String

        enum CodingKeys: String, CodingKey {
            case passed
            case candidateCertification = "candidate_certification"
            case sourceCertificationMatch = "source_certification_match"
            case checklist
            case artifacts
            case failures
            case reportPayloadSHA256 = "report_payload_sha256"
        }
    }

    struct ExportReleaseEvidence {
        var allPassed: Bool
        var seamQuality: Bool
        var bitDepth: Bool
        var exportCorrectness: Bool
        var memoryUse: Bool
    }

    struct ExportParityReport: Encodable {
        var passed: Bool
        var caseID: String
        var settingsMode: String
        var inputOrder: String
        var inputPaths: [String]
        var canonicalInputPaths: [String]
        var outputDirectory: String
        var pythonReportPath: String
        var pythonExportPath: String
        var nativePreview: PreviewRunSummary
        var nativeExportResultPath: String
        var nativeExportPath: String
        var nativeExportProfile: JSONValue?
        var nativeVsPython: VisualParityMetrics
        var nativeVsPythonRGB: TIFFRGBParityMetrics
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case caseID = "case_id"
            case settingsMode = "settings_mode"
            case inputOrder = "input_order"
            case inputPaths = "input_paths"
            case canonicalInputPaths = "canonical_input_paths"
            case outputDirectory = "output_directory"
            case pythonReportPath = "python_report_path"
            case pythonExportPath = "python_export_path"
            case nativePreview = "native_preview"
            case nativeExportResultPath = "native_export_result_path"
            case nativeExportPath = "native_export_path"
            case nativeExportProfile = "native_export_profile"
            case nativeVsPython = "native_vs_python"
            case nativeVsPythonRGB = "native_vs_python_rgb"
            case failures
        }
    }

    struct RawDecodeChannelReport: Codable {
        var ssim: Double
        var medianAbsDiff: Double
        var p95AbsDiff: Double
        var maxAbsDiff: Double

        enum CodingKeys: String, CodingKey {
            case ssim
            case medianAbsDiff = "median_absdiff"
            case p95AbsDiff = "p95_absdiff"
            case maxAbsDiff = "max_absdiff"
        }
    }

    struct RawDecodeComparatorReport: Codable {
        var passedShape: Bool
        var referenceWidth: Int
        var referenceHeight: Int
        var nativeWidth: Int
        var nativeHeight: Int
        var referenceBitDepth: Int
        var nativeSampleType: String
        var maskedRGBSSIM: Double?
        var maskedMedianAbsDiff: Double?
        var maskedP95AbsDiff: Double?
        var maxAbsDiff: Double?
        var perChannel: [String: RawDecodeChannelReport]?
        var diffPath: String?

        enum CodingKeys: String, CodingKey {
            case passedShape = "passed_shape"
            case referenceWidth = "reference_width"
            case referenceHeight = "reference_height"
            case nativeWidth = "native_width"
            case nativeHeight = "native_height"
            case referenceBitDepth = "reference_bit_depth"
            case nativeSampleType = "native_sample_type"
            case maskedRGBSSIM = "masked_rgb_ssim"
            case maskedMedianAbsDiff = "masked_median_absdiff"
            case maskedP95AbsDiff = "masked_p95_absdiff"
            case maxAbsDiff = "max_absdiff"
            case perChannel = "per_channel"
            case diffPath = "diff_path"
        }
    }

    struct RawDecodeParityImageReport: Encodable {
        var path: String
        var nativeHandle: String
        var nativeWidth: Int
        var nativeHeight: Int
        var nativeBitDepth: Int
        var nativeLinearBufferPath: String
        var comparatorReportPath: String
        var comparison: RawDecodeComparatorReport
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case path
            case nativeHandle = "native_handle"
            case nativeWidth = "native_width"
            case nativeHeight = "native_height"
            case nativeBitDepth = "native_bit_depth"
            case nativeLinearBufferPath = "native_linear_buffer_path"
            case comparatorReportPath = "comparator_report_path"
            case comparison
            case failures
        }
    }

    struct RawDecodeParityReport: Encodable {
        var passed: Bool
        var halfSize: Bool
        var outputDirectory: String
        var images: [RawDecodeParityImageReport]
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case halfSize = "half_size"
            case outputDirectory = "output_directory"
            case images
            case failures
        }
    }

    struct PerfRunReport: Encodable {
        var passed: Bool
        var caseID: String
        var renderer: String
        var inputPaths: [String]
        var outputPath: String
        var previewSeconds: Double
        var exportSeconds: Double
        var totalSeconds: Double
        var cpuBaselineExportSeconds: Double?
        var metalExportSpeedup: Double?
        var previewStatus: String?
        var geometry: String?
        var exportProfile: JSONValue?
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case caseID = "case_id"
            case renderer
            case inputPaths = "input_paths"
            case outputPath = "output_path"
            case previewSeconds = "preview_seconds"
            case exportSeconds = "export_seconds"
            case totalSeconds = "total_seconds"
            case cpuBaselineExportSeconds = "cpu_baseline_export_seconds"
            case metalExportSpeedup = "metal_export_speedup"
            case previewStatus = "preview_status"
            case geometry
            case exportProfile = "export_profile"
            case failures
        }
    }

    struct PairedPerfRepetitionReport: Encodable {
        var index: Int
        var order: [String]
        var cpu: PerfRunReport
        var metalQuality: PerfRunReport

        enum CodingKeys: String, CodingKey {
            case index
            case order
            case cpu
            case metalQuality = "metal_quality"
        }
    }

    struct PairedPerfReport: Encodable {
        var passed: Bool
        var caseID: String
        var repetitions: Int
        var cpuMedianExportSeconds: Double
        var metalQualityMedianExportSeconds: Double
        var medianExportSpeedup: Double
        var minimumExportSpeedup: Double
        var runs: [PairedPerfRepetitionReport]
        var failures: [String]

        enum CodingKeys: String, CodingKey {
            case passed
            case caseID = "case_id"
            case repetitions
            case cpuMedianExportSeconds = "cpu_median_export_seconds"
            case metalQualityMedianExportSeconds = "metal_quality_median_export_seconds"
            case medianExportSpeedup = "median_export_speedup"
            case minimumExportSpeedup = "minimum_export_speedup"
            case runs
            case failures
        }
    }

    static func runPerf(arguments: [String]) -> Int32 {
        guard arguments.first == "run-suite" else {
            fputs("perf requires run-suite\n", stderr)
            return 2
        }
        var caseID = "7raw"
        var renderer = "cpu"
        var outputDirectory = URL(fileURLWithPath: "/tmp/panolume_native_perf_reports", isDirectory: true)
        var paired = false
        var repetitions = 3
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case":
                index += 1
                guard index < arguments.count else {
                    fputs("perf run-suite requires a value after --case\n", stderr)
                    return 2
                }
                caseID = arguments[index]
            case "--renderer":
                index += 1
                guard index < arguments.count else {
                    fputs("perf run-suite requires a value after --renderer\n", stderr)
                    return 2
                }
                renderer = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    fputs("perf run-suite requires a path after --output-dir\n", stderr)
                    return 2
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--paired":
                paired = true
            case "--repetitions":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    fputs("perf run-suite requires a positive integer after --repetitions\n", stderr)
                    return 2
                }
                repetitions = value
            default:
                fputs("unknown perf run-suite argument: \(argument)\n", stderr)
                return 2
            }
            index += 1
        }
        do {
            if paired {
                let report = try runPairedPerfSuite(caseID: caseID, repetitions: repetitions, outputDirectory: outputDirectory)
                try printJSON(report)
                return report.passed ? 0 : 3
            }
            let report = try runPerfSuite(caseID: caseID, renderer: renderer, outputDirectory: outputDirectory)
            try printJSON(report)
            return report.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runPerfSuite(
        caseID: String,
        renderer: String,
        outputDirectory: URL,
        outputStem: String? = nil,
        requireCPUBaseline: Bool = true
    ) throws -> PerfRunReport {
        let root = try repositoryRoot()
        let rawDirectory = root.appendingPathComponent("test_astro/raw", isDirectory: true)
        let ids: [Int]
        switch caseID {
        case "3raw":
            ids = [6050, 6051, 6052]
        case "4raw":
            ids = [6049, 6050, 6051, 6052]
        case "7raw":
            ids = Array(6046...6052)
        default:
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "perf --case must be 3raw, 4raw, or 7raw"])
        }
        let urls = ids.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing RAW input: \(missing.map(\.path).joined(separator: ", "))"])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var settings = StitchSettings()
        settings.previewMaxSide = 2400
        settings.rawHalfSize = true
        settings.astroGeometry = "camera"
        let engine = try NativeEngineBridge()
        let previewStart = Date()
        let preview = try engine.runPreview(paths: urls, settings: settings) { event in
            fputs("perf \(caseID) preview \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        let previewSeconds = Date().timeIntervalSince(previewStart)
        guard let result = preview.result else {
            return PerfRunReport(
                passed: false,
                caseID: caseID,
                renderer: renderer,
                inputPaths: urls.map(\.path),
                outputPath: "",
                previewSeconds: previewSeconds,
                exportSeconds: 0,
                totalSeconds: previewSeconds,
                cpuBaselineExportSeconds: nil,
                metalExportSpeedup: nil,
                previewStatus: nil,
                geometry: nil,
                exportProfile: nil,
                failures: ["native preview did not return a result"]
            )
        }
        let stem = outputStem ?? "perf-\(caseID)-\(renderer)"
        let outputURL = outputDirectory.appendingPathComponent("\(stem).tiff")
        var exportSettings = ExportSettings(rendererBackend: renderer, bitDepth: 16)
        exportSettings.maxOutputSide = 0
        exportSettings.maxOutputPixels = 0
        let exportStart = Date()
        let export = try engine.exportFullResolution(result: result, outputURL: outputURL, settings: exportSettings) { event in
            fputs("perf \(caseID) export \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        let exportSeconds = Date().timeIntervalSince(exportStart)
        let exported = export.result
        let exportProfile = exported?.diagnostics["export_profile"]
        var failures: [String] = []
        if result.diagnostics["preview_status"]?.stringValue != "camera_projection_preview" {
            failures.append("preview_status is \(result.diagnostics["preview_status"]?.stringValue ?? "missing")")
        }
        if renderer.contains("metal") {
            let used = exportProfile?["renderer_used"]?.stringValue
            let cpuFallback = exportProfile?["cpu_fallback"]?.boolValue ?? true
            if used != renderer || cpuFallback {
                let reason = exportProfile?["renderer_fallback_reason"]?.stringValue ?? "missing fallback reason"
                failures.append("Metal renderer did not run: used=\(used ?? "missing"), reason=\(reason)")
            }
        }
        var cpuBaselineExportSeconds: Double?
        var metalExportSpeedup: Double?
        if renderer == "metal_quality" && requireCPUBaseline {
            let cpuReportURL = outputDirectory.appendingPathComponent("perf-\(caseID)-cpu.json")
            if FileManager.default.fileExists(atPath: cpuReportURL.path),
               let cpuSeconds = try readJSONValue(cpuReportURL)["export_seconds"]?.numberValue,
               cpuSeconds > 0,
               exportSeconds > 0 {
                cpuBaselineExportSeconds = cpuSeconds
                metalExportSpeedup = cpuSeconds / exportSeconds
                if metalExportSpeedup! < 1.5 {
                    failures.append("metal_quality export speedup \(metalExportSpeedup!) below 1.5x CPU baseline")
                }
            } else {
                failures.append("metal_quality perf requires a prior CPU baseline report at \(cpuReportURL.path)")
            }
        }
        let report = PerfRunReport(
            passed: failures.isEmpty,
            caseID: caseID,
            renderer: renderer,
            inputPaths: urls.map(\.path),
            outputPath: outputURL.path,
            previewSeconds: previewSeconds,
            exportSeconds: exportSeconds,
            totalSeconds: previewSeconds + exportSeconds,
            cpuBaselineExportSeconds: cpuBaselineExportSeconds,
            metalExportSpeedup: metalExportSpeedup,
            previewStatus: result.diagnostics["preview_status"]?.stringValue,
            geometry: result.diagnostics["geometry"]?.stringValue,
            exportProfile: exportProfile,
            failures: failures
        )
        let provenance = try makeProvenance(
            inputURLs: urls,
            configuration: [
                "artifact": "performance-run",
                "case_id": caseID,
                "renderer": renderer,
                "preview_settings": try stableJSONString(settings),
                "export_settings": try stableJSONString(exportSettings),
                "ordered_paths": urls.map(\.path).joined(separator: "\n"),
            ]
        )
        try writeJSON(
            report,
            to: outputDirectory.appendingPathComponent("\(stem).json"),
            provenance: provenance
        )
        return report
    }

    static func runPairedPerfSuite(
        caseID: String,
        repetitions: Int,
        outputDirectory: URL
    ) throws -> PairedPerfReport {
        guard repetitions >= 3 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "paired performance gate requires at least 3 repetitions"])
        }
        var runs: [PairedPerfRepetitionReport] = []
        var failures: [String] = []
        var cpuTimes: [Double] = []
        var metalTimes: [Double] = []
        for index in 0..<repetitions {
            let cpuFirst = index % 2 == 0
            let order = cpuFirst ? ["cpu", "metal_quality"] : ["metal_quality", "cpu"]
            var cpu: PerfRunReport?
            var metal: PerfRunReport?
            for renderer in order {
                let report = try runPerfSuite(
                    caseID: caseID,
                    renderer: renderer,
                    outputDirectory: outputDirectory,
                    outputStem: "paired-\(caseID)-\(renderer)-run\(index + 1)",
                    requireCPUBaseline: false
                )
                if renderer == "cpu" {
                    cpu = report
                } else {
                    metal = report
                }
            }
            guard let cpu, let metal else {
                throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "paired performance run did not produce both CPU and Metal reports"])
            }
            if !cpu.passed {
                failures.append("paired run \(index + 1) CPU gate failed: \(cpu.failures.joined(separator: "; "))")
            }
            if !metal.passed {
                failures.append("paired run \(index + 1) Metal gate failed: \(metal.failures.joined(separator: "; "))")
            }
            if metal.exportProfile?["renderer_used"]?.stringValue != "metal_quality"
                || metal.exportProfile?["cpu_fallback"]?.boolValue ?? true {
                failures.append("paired run \(index + 1) did not use metal_quality without CPU fallback")
            }
            cpuTimes.append(cpu.exportSeconds)
            metalTimes.append(metal.exportSeconds)
            runs.append(PairedPerfRepetitionReport(index: index + 1, order: order, cpu: cpu, metalQuality: metal))
        }
        let sortedCPU = cpuTimes.sorted()
        let sortedMetal = metalTimes.sorted()
        let cpuMedian = percentile(sorted: sortedCPU, fraction: 0.5)
        let metalMedian = percentile(sorted: sortedMetal, fraction: 0.5)
        let speedups = zip(cpuTimes, metalTimes).map { cpu, metal in
            metal > 0 ? cpu / metal : 0.0
        }
        let medianSpeedup = metalMedian > 0 ? cpuMedian / metalMedian : 0.0
        let minimumSpeedup = speedups.min() ?? 0.0
        if medianSpeedup < 1.5 {
            failures.append("paired median metal_quality speedup \(medianSpeedup) below 1.5x CPU")
        }
        let report = PairedPerfReport(
            passed: failures.isEmpty,
            caseID: caseID,
            repetitions: repetitions,
            cpuMedianExportSeconds: cpuMedian,
            metalQualityMedianExportSeconds: metalMedian,
            medianExportSpeedup: medianSpeedup,
            minimumExportSpeedup: minimumSpeedup,
            runs: runs,
            failures: failures
        )
        let inputURLs = (runs.first?.cpu.inputPaths ?? []).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let provenance = try makeProvenance(
            inputURLs: inputURLs,
            configuration: [
                "artifact": "paired-performance-suite",
                "case_id": caseID,
                "repetitions": String(repetitions),
                "renderer_pair": "cpu,metal_quality",
                "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
            ]
        )
        try writeJSON(
            report,
            to: outputDirectory.appendingPathComponent("paired-\(caseID)-report.json"),
            provenance: provenance
        )
        return report
    }

    static func runCertification(arguments: [String]) -> Int32 {
        guard let command = arguments.first,
              ["status", "verify", "promote"].contains(command) else {
            fputs("certification requires status, verify, or promote\n", stderr)
            return 2
        }
        var manifestURL: URL?
        var releaseReportURL: URL?
        var outputURL: URL?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--manifest", "--release-report", "--output":
                index += 1
                guard index < arguments.count else {
                    fputs("certification \(command) requires a path after \(argument)\n", stderr)
                    return 2
                }
                let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                switch argument {
                case "--manifest": manifestURL = url
                case "--release-report": releaseReportURL = url
                case "--output": outputURL = url
                default: break
                }
            default:
                fputs("unknown certification \(command) argument: \(argument)\n", stderr)
                return 2
            }
            index += 1
        }

        do {
            let root = try repositoryRoot()
            let defaultManifest = root.appendingPathComponent(
                "macos/PanoLume/Docs/Certification/native-source-certification.json"
            )
            let selectedManifest = manifestURL ?? defaultManifest
            let sourcePaths = try algorithmSourcePaths(root: root)
            let currentCommit = try gitOutput(["rev-parse", "HEAD"], root: root)
            let currentFingerprint = try algorithmSourceFingerprint(root: root)
            let runtimeBinding = try validatedRuntimeEvidenceBinding(
                workspaceSourceFingerprint: currentFingerprint
            ).binding

            if command == "promote" {
                guard let releaseReportURL else {
                    fputs("certification promote requires --release-report\n", stderr)
                    return 2
                }
                let releaseData = try Data(contentsOf: releaseReportURL)
                let release = try readJSONValue(releaseReportURL)
                let reportCommit = release["provenance"]?["source_commit"]?.stringValue
                let reportFingerprint = release["provenance"]?["source_fingerprint"]?.stringValue
                let reportBinaryFingerprint = release["provenance"]?["binary_engine_source_fingerprint"]?.stringValue
                let reportRegressionExecutableSHA256 = release["provenance"]?["regression_executable_sha256"]?.stringValue
                let reportProvenanceSchema = Int(
                    release["provenance"]?["schema_version"]?.numberValue ?? 0
                )
                let reportClean = release["provenance"]?["worktree_clean"]?.boolValue ?? false
                let reportMetalSHA256 = release["provenance"]?["metal_dylib_sha256"]?.stringValue
                let reportMetalAPIVersion = Int(
                    release["provenance"]?["metal_api_version"]?.numberValue ?? 0
                )
                let existingManifest = (try? Data(contentsOf: selectedManifest)).flatMap {
                    try? JSONDecoder().decode(SourceCertificationManifest.self, from: $0)
                }
                var releaseProvenanceAudit = ReleaseProvenanceAudit()
                var releaseProvenanceFailures: [String] = []
                validateReleaseProvenance(
                    release,
                    url: releaseReportURL,
                    label: "candidate release report",
                    requiresOracle: false,
                    audit: &releaseProvenanceAudit,
                    failures: &releaseProvenanceFailures
                )
                let sourceAlreadyCertified = existingManifest?.schemaVersion == 3
                    && existingManifest?.certificationStatus == "certified"
                    && existingManifest?.certifiedSourceFingerprint == currentFingerprint
                let controlledCandidate = release["candidate_certification"]?.boolValue == true
                let integrityAudit = try CandidateReleaseReportIntegrity.validateForPromotion(
                    reportData: releaseData
                )
                let independentlyRevalidated = try validateFocusedRelease(
                    arguments: releaseRevalidationArguments(
                        artifacts: integrityAudit.artifacts,
                        candidateCertification: controlledCandidate
                    ),
                    writeOutput: false
                )
                let status = try gitOutput(["status", "--porcelain", "--untracked-files=all"], root: root)
                guard release["passed"]?.boolValue == true,
                      releaseProvenanceFailures.isEmpty,
                      independentlyRevalidated.passed,
                      independentlyRevalidated.failures.isEmpty,
                      independentlyRevalidated.checklist.allPassed,
                      independentlyRevalidated.candidateCertification == controlledCandidate,
                      independentlyRevalidated.sourceCertificationMatch
                        == (release["source_certification_match"]?.boolValue ?? false),
                      sourceAlreadyCertified || controlledCandidate,
                      reportClean,
                      reportProvenanceSchema == RegressionProvenanceSchema.currentVersion,
                      reportCommit == currentCommit,
                      reportFingerprint == currentFingerprint,
                      reportBinaryFingerprint == runtimeBinding.binarySourceFingerprint,
                      reportRegressionExecutableSHA256 == runtimeBinding.regressionExecutableSHA256,
                      reportMetalSHA256.map({ isLowercaseHex($0, count: 64) }) == true,
                      reportMetalAPIVersion == NativeEngineBridge.currentMetalRendererAPIVersion,
                      status.isEmpty else {
                    throw NSError(
                        domain: "PanoLumeRegression",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Certification promotion requires a passing controlled-candidate release report from this exact clean source fingerprint."]
                    )
                }
                let manifest = SourceCertificationManifest(
                    schemaVersion: 3,
                    certifiedSourceCommit: currentCommit,
                    certifiedSourceFingerprint: currentFingerprint,
                    algorithmSourceFiles: sourcePaths,
                    certificationStatus: "certified",
                    releaseReportSHA256: try sha256File(releaseReportURL),
                    metalDylibSHA256: reportMetalSHA256 ?? "",
                    metalAPIVersion: reportMetalAPIVersion,
                    createdAtUTC: ISO8601DateFormatter().string(from: Date()),
                    note: "Promoted only after provenance-bound PanoLume focused-risk release validation."
                )
                let destination = outputURL ?? selectedManifest
                try writeJSON(manifest, to: destination)
                try printJSON(manifest)
                return 0
            }

            let data = try Data(contentsOf: selectedManifest)
            let manifest = try JSONDecoder().decode(SourceCertificationManifest.self, from: data)
            let filesMatch = manifest.algorithmSourceFiles == sourcePaths
            let passed = manifest.schemaVersion == 3
                && manifest.certificationStatus == "certified"
                && filesMatch
                && isLowercaseHex(manifest.certifiedSourceCommit, count: 40)
                && manifest.certifiedSourceFingerprint == currentFingerprint
                && isLowercaseHex(manifest.releaseReportSHA256, count: 64)
                && isLowercaseHex(manifest.metalDylibSHA256, count: 64)
                && manifest.metalAPIVersion == NativeEngineBridge.currentMetalRendererAPIVersion
            let report = SourceCertificationReport(
                passed: passed,
                schemaVersion: manifest.schemaVersion,
                currentSourceCommit: currentCommit,
                currentSourceFingerprint: currentFingerprint,
                binaryEngineSourceFingerprint: runtimeBinding.binarySourceFingerprint,
                regressionExecutableSHA256: runtimeBinding.regressionExecutableSHA256,
                certifiedSourceCommit: manifest.certifiedSourceCommit,
                certifiedSourceFingerprint: manifest.certifiedSourceFingerprint,
                certifiedReleaseReportSHA256: manifest.releaseReportSHA256,
                certifiedMetalDylibSHA256: manifest.metalDylibSHA256,
                certifiedMetalAPIVersion: manifest.metalAPIVersion,
                algorithmSourceFiles: sourcePaths,
                certificationStatus: passed ? "certified_current_sources" : "recertification_required",
                message: passed
                    ? "Current engine/Metal sources exactly match the promoted certification fingerprint."
                    : "Current engine/Metal sources differ from the promoted certification or the manifest is incomplete. Runtime parity must remain fail-closed."
            )
            if let outputURL {
                try writeJSON(report, to: outputURL)
            }
            try printJSON(report)
            return command == "verify" && !passed ? 3 : 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runParity(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            fputs("parity requires compare-preview, compare-export, compare-raw-decode, run-suite, run-export-suite, or validate-release\n", stderr)
            return 2
        }
        do {
            switch command {
            case "compare-preview":
                let options = try parsePreviewParityOptions(Array(arguments.dropFirst()))
                let report = try comparePreviewParity(options: options)
                try printJSON(report)
                return report.passed ? 0 : 3
            case "compare-export":
                let options = try parseExportParityOptions(Array(arguments.dropFirst()))
                let report = try compareExportParity(options: options)
                try printJSON(report)
                return report.passed ? 0 : 3
            case "compare-raw-decode":
                let options = try parseRawDecodeParityOptions(Array(arguments.dropFirst()))
                let report = try compareRawDecodeParity(options: options)
                try printJSON(report)
                return report.passed ? 0 : 3
            case "run-suite":
                let report = try runPreviewParitySuite(arguments: Array(arguments.dropFirst()))
                try printJSON(report)
                return report.passed ? 0 : 3
            case "run-export-suite":
                let report = try runExportParitySuite(arguments: Array(arguments.dropFirst()))
                try printJSON(report)
                return report.passed ? 0 : 3
            case "validate-release":
                let report = try validateFocusedRelease(arguments: Array(arguments.dropFirst()))
                try printJSON(report)
                return report.passed ? 0 : 3
            default:
                fputs("unknown parity subcommand: \(command)\n", stderr)
                return 2
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func parsePreviewParityOptions(_ arguments: [String]) throws -> PreviewParityOptions {
        var options = PreviewParityOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a value after --case"])
                }
                options.caseID = arguments[index]
            case "--settings":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a value after --settings"])
                }
                options.settingsMode = arguments[index]
            case "--order":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a value after --order"])
                }
                options.orderMode = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a path after --output-dir"])
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--reuse-python-oracle":
                options.reusePythonOracle = true
            case "--no-guided-refinement":
                options.disableGuidedRefinement = true
            case "--no-local-refinement":
                options.disableLocalRefinement = true
            case "--no-texture-refinement":
                options.disableTextureRefinement = true
            case "--no-display-stretch":
                options.disableDisplayStretch = true
            case "--robust-reprojection-px":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a numeric value after --robust-reprojection-px"])
                }
                options.robustReprojectionPx = value
            case "--robust-min-pair-inliers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires an integer value after --robust-min-pair-inliers"])
                }
                options.robustMinPairInliers = value
            case "--native-robust-reprojection-px":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires a numeric value after --native-robust-reprojection-px"])
                }
                options.nativeRobustReprojectionPx = value
            case "--native-robust-min-pair-inliers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires an integer value after --native-robust-min-pair-inliers"])
                }
                options.nativeRobustMinPairInliers = value
            default:
                options.paths.append(argument)
            }
            index += 1
        }
        guard options.paths.count >= 2 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview requires at least two image paths"])
        }
        guard ["original", "reverse", "sorted"].contains(options.orderMode) else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-preview --order must be original, reverse, or sorted"])
        }
        return options
    }

    static func parseExportParityOptions(_ arguments: [String]) throws -> ExportParityOptions {
        var options = ExportParityOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--case":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires a value after --case"])
                }
                options.caseID = arguments[index]
            case "--settings":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires a value after --settings"])
                }
                options.settingsMode = arguments[index]
            case "--order":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires a value after --order"])
                }
                options.orderMode = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires a path after --output-dir"])
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--renderer":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires a value after --renderer"])
                }
                options.renderer = arguments[index]
            case "--bit-depth":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires an integer after --bit-depth"])
                }
                options.bitDepth = value
            case "--apply-preview-stretch":
                options.applyPreviewStretch = true
            default:
                options.paths.append(argument)
            }
            index += 1
        }
        guard options.paths.count >= 2 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export requires at least two image paths"])
        }
        guard ["original", "reverse", "sorted"].contains(options.orderMode) else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export --order must be original, reverse, or sorted"])
        }
        guard ["auto", "cpu", "metal_fast", "metal_quality"].contains(options.renderer) else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export --renderer must be auto, cpu, metal_fast, or metal_quality"])
        }
        guard options.bitDepth == 8 || options.bitDepth == 16 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-export --bit-depth must be 8 or 16"])
        }
        return options
    }

    static func parseRawDecodeParityOptions(_ arguments: [String]) throws -> RawDecodeParityOptions {
        var options = RawDecodeParityOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-raw-decode requires a path after --output-dir"])
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--full-size":
                options.halfSize = false
            default:
                options.paths.append(argument)
            }
            index += 1
        }
        guard !options.paths.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-raw-decode requires at least one RAW path"])
        }
        return options
    }

    static func settings(forParityMode mode: String) -> StitchSettings {
        var settings = StitchSettings()
        settings.blendMode = "feather"
        settings.previewMaxSide = 2400
        settings.rawHalfSize = true
        switch mode {
        case "camera":
            settings.astroGeometry = "camera"
        case "ui-default":
            break
        default:
            break
        }
        return settings
    }

    static func previewCaseProvenance(options: PreviewParityOptions) throws -> ParityProvenance {
        var settings = settings(forParityMode: options.settingsMode)
        if options.disableGuidedRefinement { settings.cameraModelGuidedRefinement = false }
        if options.disableLocalRefinement { settings.cameraModelLocalRefinement = false }
        if options.disableTextureRefinement { settings.cameraModelTextureRefinement = false }
        if options.disableDisplayStretch { settings.displayStretch = false }
        if let value = options.robustReprojectionPx { settings.cameraModelRobustReprojectionPx = value }
        if let value = options.robustMinPairInliers { settings.cameraModelRobustMinPairInliers = value }
        var nativeSettings = settings
        if let value = options.nativeRobustReprojectionPx { nativeSettings.cameraModelRobustReprojectionPx = value }
        if let value = options.nativeRobustMinPairInliers { nativeSettings.cameraModelRobustMinPairInliers = value }
        let inputURLs = try orderedParityURLs(paths: options.paths, mode: options.orderMode)
        return try makeProvenance(
            inputURLs: inputURLs,
            configuration: [
                "artifact": "preview-parity-case",
                "case_id": options.caseID,
                "settings_mode": options.settingsMode,
                "input_order": options.orderMode,
                "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                "python_settings": try stableJSONString(settings),
                "native_settings": try stableJSONString(nativeSettings),
            ]
        )
    }

    static func exportCaseProvenance(options: ExportParityOptions) throws -> ParityProvenance {
        let settings = settings(forParityMode: options.settingsMode)
        let exportSettings = ExportSettings(
            rendererBackend: options.renderer,
            bitDepth: options.bitDepth,
            applyPreviewStretch: options.applyPreviewStretch,
            stretchStrength: options.applyPreviewStretch ? settings.stretchStrength : 0.0,
            stretchBlackPercentile: settings.stretchBlackPercentile,
            stretchWhitePercentile: settings.stretchWhitePercentile,
            stretchGamma: settings.stretchGamma
        )
        let inputURLs = try orderedParityURLs(paths: options.paths, mode: options.orderMode)
        return try makeProvenance(
            inputURLs: inputURLs,
            configuration: [
                "artifact": "export-parity-case",
                "case_id": options.caseID,
                "settings_mode": options.settingsMode,
                "input_order": options.orderMode,
                "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                "preview_settings": try stableJSONString(settings),
                "export_settings": try stableJSONString(exportSettings),
            ]
        )
    }

    static func rawDecodeProvenance(options: RawDecodeParityOptions) throws -> ParityProvenance {
        let inputURLs = options.paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return try makeProvenance(
            inputURLs: inputURLs,
            configuration: [
                "artifact": "raw-decode-parity",
                "half_size": String(options.halfSize),
                "ordered_paths": inputURLs.map(\.path).joined(separator: "\n"),
                "sample_type": "uint16_linear_rgb_spool",
            ]
        )
    }

    static func comparePreviewParity(options: PreviewParityOptions) throws -> PreviewParityReport {
        var settings = settings(forParityMode: options.settingsMode)
        if options.disableGuidedRefinement {
            settings.cameraModelGuidedRefinement = false
        }
        if options.disableLocalRefinement {
            settings.cameraModelLocalRefinement = false
        }
        if options.disableTextureRefinement {
            settings.cameraModelTextureRefinement = false
        }
        if options.disableDisplayStretch {
            settings.displayStretch = false
        }
        if let robustReprojectionPx = options.robustReprojectionPx {
            settings.cameraModelRobustReprojectionPx = robustReprojectionPx
        }
        if let robustMinPairInliers = options.robustMinPairInliers {
            settings.cameraModelRobustMinPairInliers = robustMinPairInliers
        }
        var nativeSettings = settings
        if let nativeRobustReprojectionPx = options.nativeRobustReprojectionPx {
            nativeSettings.cameraModelRobustReprojectionPx = nativeRobustReprojectionPx
        }
        if let nativeRobustMinPairInliers = options.nativeRobustMinPairInliers {
            nativeSettings.cameraModelRobustMinPairInliers = nativeRobustMinPairInliers
        }
        let importURLs = try orderedParityURLs(paths: options.paths, mode: options.orderMode)
        let canonicalURLs = try canonicalParityURLs(paths: options.paths)
        let caseDirectory = options.outputDirectory
            .appendingPathComponent(sanitizeFilename(options.caseID), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(options.settingsMode), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(options.orderMode), isDirectory: true)
        let pythonDirectory = caseDirectory.appendingPathComponent("python", isDirectory: true)
        let nativeDirectory = caseDirectory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)

        let pythonReportURL = try runPythonOracle(
            paths: canonicalURLs,
            settings: settings,
            outputDirectory: pythonDirectory,
            reuseExisting: options.reusePythonOracle
        )
        let pythonJSON = try readJSONValue(pythonReportURL)
        let pythonPreviewURL = pythonDirectory.appendingPathComponent("panorama.png")
        let pythonPreviewPixels = try loadPNG(pythonPreviewURL)
        var pythonMetrics = metrics(fromPythonReport: pythonJSON)
        if pythonMetrics.panoramaWidth == 0 || pythonMetrics.panoramaHeight == 0 {
            pythonMetrics.panoramaWidth = pythonPreviewPixels.width
            pythonMetrics.panoramaHeight = pythonPreviewPixels.height
        }
        let pythonSummary = PreviewRunSummary(
            resultPath: pythonReportURL.path,
            previewPath: pythonPreviewURL.path,
            metrics: pythonMetrics,
            geometry: (pythonJSON["diagnostics"] ?? pythonJSON)["geometry"]?.stringValue,
            previewStatus: (pythonJSON["diagnostics"] ?? pythonJSON)["preview_status"]?.stringValue,
            message: "Python oracle completed."
        )

        let engine = try NativeEngineBridge()
        let direct = try engine.runPreview(paths: importURLs, settings: nativeSettings) { event in
            fputs("\(options.caseID): native-direct \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        guard let directResult = direct.result else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "native direct preview did not return a result"])
        }
        let directJSON = nativeDirectory.appendingPathComponent("native_direct.json")
        try writeJSON(direct, to: directJSON)
        let directPreviewURL = nativeDirectory.appendingPathComponent("native_direct.png")
        try savePNG(try requirePixels(engine.copyResultRGBA(resultHandle: directResult.handle, settings: nativeSettings), label: "native direct"), to: directPreviewURL)
        let directSummary = PreviewRunSummary(
            resultPath: directJSON.path,
            previewPath: directPreviewURL.path,
            metrics: metrics(fromNativeResult: directResult),
            geometry: directResult.diagnostics["geometry"]?.stringValue,
            previewStatus: directResult.diagnostics["preview_status"]?.stringValue,
            message: direct.message
        )

        let handleEngine = try NativeEngineBridge()
        let loaded = try handleEngine.loadImages(paths: importURLs, settings: settings) { event in
            fputs("\(options.caseID): load-handles \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        let handles = loaded.images.filter { $0.status == .loaded }.map(\.handle)
        guard handles.count == importURLs.count else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "native handle preview loaded \(handles.count) of \(importURLs.count) images"])
        }
        let handleResponse = try handleEngine.runPreviewFromLoadedImages(
            imageHandles: handles,
            paths: importURLs,
            settings: nativeSettings
        ) { event in
            fputs("\(options.caseID): native-handles \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        guard let handleResult = handleResponse.result else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "native handle preview did not return a result"])
        }
        let handleJSON = nativeDirectory.appendingPathComponent("native_handles.json")
        try writeJSON(handleResponse, to: handleJSON)
        let handlePreviewURL = nativeDirectory.appendingPathComponent("native_handles.png")
        try savePNG(try requirePixels(handleEngine.copyResultRGBA(resultHandle: handleResult.handle, settings: nativeSettings), label: "native handles"), to: handlePreviewURL)
        let handleSummary = PreviewRunSummary(
            resultPath: handleJSON.path,
            previewPath: handlePreviewURL.path,
            metrics: metrics(fromNativeResult: handleResult),
            geometry: handleResult.diagnostics["geometry"]?.stringValue,
            previewStatus: handleResult.diagnostics["preview_status"]?.stringValue,
            message: handleResponse.message
        )

        let nativeVsPythonDiffURL = nativeDirectory.appendingPathComponent("native_vs_python_diff.png")
        let handlesVsPythonDiffURL = nativeDirectory.appendingPathComponent("handles_vs_python_diff.png")
        let nativeVsPython = try comparePreviewImages(
            baselineURL: pythonPreviewURL,
            candidateURL: directPreviewURL,
            diffURL: nativeVsPythonDiffURL
        )
        let handlesVsPython: VisualParityMetrics
        if FileManager.default.contentsEqual(atPath: directPreviewURL.path, andPath: handlePreviewURL.path) {
            if FileManager.default.fileExists(atPath: handlesVsPythonDiffURL.path) {
                try FileManager.default.removeItem(at: handlesVsPythonDiffURL)
            }
            try FileManager.default.copyItem(at: nativeVsPythonDiffURL, to: handlesVsPythonDiffURL)
            var reused = nativeVsPython
            reused.diffPath = handlesVsPythonDiffURL.path
            handlesVsPython = reused
        } else {
            handlesVsPython = try comparePreviewImages(
                baselineURL: pythonPreviewURL,
                candidateURL: handlePreviewURL,
                diffURL: handlesVsPythonDiffURL
            )
        }
        let handlesVsDirect = try comparePreviewImages(
            baselineURL: directPreviewURL,
            candidateURL: handlePreviewURL,
            diffURL: nativeDirectory.appendingPathComponent("handles_vs_direct_diff.png")
        )

        var failures: [String] = []
        failures.append(contentsOf: previewStatusFailures(prefix: "native direct", summary: directSummary))
        failures.append(contentsOf: previewStatusFailures(prefix: "native handles", summary: handleSummary))
        failures.append(contentsOf: starProjectionParityFailures(prefix: "native direct", baseline: pythonMetrics, candidate: directSummary.metrics))
        failures.append(contentsOf: starProjectionParityFailures(prefix: "native handles", baseline: pythonMetrics, candidate: handleSummary.metrics))
        failures.append(contentsOf: visualParityFailures(
            prefix: "native direct vs python",
            metrics: nativeVsPython,
            minimumSSIM: 0.935
        ))
        failures.append(contentsOf: visualParityFailures(
            prefix: "native handles vs python",
            metrics: handlesVsPython,
            minimumSSIM: 0.935
        ))
        failures.append(contentsOf: visualParityFailures(prefix: "native handles vs direct", metrics: handlesVsDirect, strictSSIM: false))

        let report = PreviewParityReport(
            passed: failures.isEmpty,
            caseID: options.caseID,
            settingsMode: options.settingsMode,
            inputOrder: options.orderMode,
            inputPaths: importURLs.map(\.path),
            canonicalInputPaths: canonicalURLs.map(\.path),
            outputDirectory: caseDirectory.path,
            python: pythonSummary,
            nativeDirect: directSummary,
            nativeHandles: handleSummary,
            nativeVsPython: nativeVsPython,
            handlesVsPython: handlesVsPython,
            handlesVsDirect: handlesVsDirect,
            failures: failures
        )
        try writeJSON(
            report,
            to: caseDirectory.appendingPathComponent("report.json"),
            provenance: try previewCaseProvenance(options: options)
        )
        return report
    }

    static func compareExportParity(options: ExportParityOptions) throws -> ExportParityReport {
        let settings = settings(forParityMode: options.settingsMode)
        let importURLs = try orderedParityURLs(paths: options.paths, mode: options.orderMode)
        let canonicalURLs = try canonicalParityURLs(paths: options.paths)
        let caseDirectory = options.outputDirectory
            .appendingPathComponent(sanitizeFilename(options.caseID), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(options.settingsMode), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(options.orderMode), isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
        let pythonDirectory = caseDirectory.appendingPathComponent("python", isDirectory: true)
        let nativeDirectory = caseDirectory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)

        let exportSettings = ExportSettings(
            rendererBackend: options.renderer,
            bitDepth: options.bitDepth,
            applyPreviewStretch: options.applyPreviewStretch,
            stretchStrength: options.applyPreviewStretch ? settings.stretchStrength : 0.0,
            stretchBlackPercentile: settings.stretchBlackPercentile,
            stretchWhitePercentile: settings.stretchWhitePercentile,
            stretchGamma: settings.stretchGamma
        )

        let engine = try NativeEngineBridge()
        let preview = try engine.runPreview(paths: importURLs, settings: settings) { event in
            fputs("\(options.caseID): native-preview \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        guard let previewResult = preview.result else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "native preview did not return a result for export parity"])
        }
        let previewJSON = nativeDirectory.appendingPathComponent("native_preview.json")
        try writeJSON(preview, to: previewJSON)
        let pythonExportURL = pythonDirectory.appendingPathComponent("python_export.tiff")
        let pythonReportURL = try runPythonOracle(
            paths: canonicalURLs,
            settings: settings,
            outputDirectory: pythonDirectory,
            exportTIFF: pythonExportURL,
            exportSettings: exportSettings,
            cameraParamsJSON: previewJSON
        )
        let previewSummary = PreviewRunSummary(
            resultPath: previewJSON.path,
            previewPath: "",
            metrics: metrics(fromNativeResult: previewResult),
            geometry: previewResult.diagnostics["geometry"]?.stringValue,
            previewStatus: previewResult.diagnostics["preview_status"]?.stringValue,
            message: preview.message
        )
        let nativeExportURL = nativeDirectory.appendingPathComponent("native_export.tiff")
        let exported = try engine.exportFullResolution(
            result: previewResult,
            outputURL: nativeExportURL,
            settings: exportSettings
        ) { event in
            fputs("\(options.caseID): native-export \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
        }
        guard let exportedResult = exported.result else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "native export did not return a result"])
        }
        let nativeExportJSON = nativeDirectory.appendingPathComponent("native_export.json")
        try writeJSON(exported, to: nativeExportJSON)

        let nativeVsPython = try comparePreviewImages(
            baselineURL: pythonExportURL,
            candidateURL: nativeExportURL,
            diffURL: nativeDirectory.appendingPathComponent("native_export_vs_python_diff.png")
        )
        let nativeVsPythonRGB = try compareTIFFRGBImages(
            baselineURL: pythonExportURL,
            candidateURL: nativeExportURL,
            reportURL: nativeDirectory.appendingPathComponent("native_export_vs_python_rgb.json"),
            diffURL: nativeDirectory.appendingPathComponent("native_export_vs_python_rgb_diff.png")
        )

        var failures: [String] = []
        failures.append(contentsOf: previewStatusFailures(prefix: "native preview before export", summary: previewSummary))
        if !FileManager.default.fileExists(atPath: pythonExportURL.path) {
            failures.append("Python TIFF export missing at \(pythonExportURL.path)")
        }
        if !FileManager.default.fileExists(atPath: nativeExportURL.path) {
            failures.append("Native TIFF export missing at \(nativeExportURL.path)")
        }
        if let profile = exportedResult.diagnostics["export_profile"] {
            if profile["geometry_source"]?.stringValue != "camera" {
                failures.append("native export geometry_source is \(profile["geometry_source"]?.stringValue ?? "missing"), expected camera")
            }
            if exportedResult.panorama.bitDepth != options.bitDepth {
                failures.append("native export result bit depth is \(exportedResult.panorama.bitDepth), expected \(options.bitDepth)")
            }
            if options.renderer.contains("metal"),
               profile["renderer_used"]?.stringValue != options.renderer {
                failures.append("native export renderer_used is \(profile["renderer_used"]?.stringValue ?? "missing"), expected \(options.renderer)")
            }
            if options.renderer.contains("metal"),
               profile["cpu_fallback"]?.boolValue != false {
                failures.append("native export requested \(options.renderer) but reported CPU fallback")
            }
        } else {
            failures.append("native export profile missing")
        }
        failures.append(contentsOf: visualParityFailures(prefix: "native TIFF vs python TIFF", metrics: nativeVsPython))
        failures.append(contentsOf: tiffRGBParityFailures(
            prefix: "native TIFF RGB vs python TIFF RGB",
            metrics: nativeVsPythonRGB,
            expectedBitDepth: options.bitDepth
        ))

        let report = ExportParityReport(
            passed: failures.isEmpty,
            caseID: options.caseID,
            settingsMode: options.settingsMode,
            inputOrder: options.orderMode,
            inputPaths: importURLs.map(\.path),
            canonicalInputPaths: canonicalURLs.map(\.path),
            outputDirectory: caseDirectory.path,
            pythonReportPath: pythonReportURL.path,
            pythonExportPath: pythonExportURL.path,
            nativePreview: previewSummary,
            nativeExportResultPath: nativeExportJSON.path,
            nativeExportPath: nativeExportURL.path,
            nativeExportProfile: exportedResult.diagnostics["export_profile"],
            nativeVsPython: nativeVsPython,
            nativeVsPythonRGB: nativeVsPythonRGB,
            failures: failures
        )
        try writeJSON(
            report,
            to: caseDirectory.appendingPathComponent("report.json"),
            provenance: try exportCaseProvenance(options: options)
        )
        return report
    }

    static func compareRawDecodeParity(options: RawDecodeParityOptions) throws -> RawDecodeParityReport {
        let urls = options.paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "compare-raw-decode missing RAW input: \(missing.map(\.path).joined(separator: ", "))"])
        }
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let engine = try NativeEngineBridge()
        var imageReports: [RawDecodeParityImageReport] = []
        var failures: [String] = []
        func unavailableComparison(width: Int, height: Int) -> RawDecodeComparatorReport {
            RawDecodeComparatorReport(
                passedShape: false,
                referenceWidth: 0,
                referenceHeight: 0,
                nativeWidth: width,
                nativeHeight: height,
                referenceBitDepth: 0,
                nativeSampleType: "unavailable",
                maskedRGBSSIM: nil,
                maskedMedianAbsDiff: nil,
                maskedP95AbsDiff: nil,
                maxAbsDiff: nil,
                perChannel: nil,
                diffPath: nil
            )
        }
        for rawURL in urls {
            let imageDirectory = options.outputDirectory.appendingPathComponent(sanitizeFilename(rawURL.deletingPathExtension().lastPathComponent), isDirectory: true)
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            var imageFailures: [String] = []
            let bufferURL = imageDirectory.appendingPathComponent("native_linear_rgb.rgb16")
            let comparatorURL = imageDirectory.appendingPathComponent("raw_decode_comparison.json")
            var nativeWidth = 0
            var nativeHeight = 0
            var nativeBitDepth = 0
            var comparison = unavailableComparison(width: 0, height: 0)
            do {
                defer { try? FileManager.default.removeItem(at: bufferURL) }
                try? FileManager.default.removeItem(at: bufferURL)
                let spool = try engine.decodeRawLinearRGB16(
                    path: rawURL,
                    outputURL: bufferURL,
                    halfSize: options.halfSize
                ) { event in
                    fputs("raw-decode \(rawURL.lastPathComponent): \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
                nativeWidth = spool.width
                nativeHeight = spool.height
                nativeBitDepth = spool.bitDepth
                if spool.channels != 3 {
                    imageFailures.append("native RAW channel count is \(spool.channels), expected 3")
                }
                if spool.bitDepth != 16 || spool.sampleType != "uint16_linear_rgb_spool" {
                    imageFailures.append("native RAW spool did not retain uint16 linear RGB samples")
                }
                let expectedBytes = spool.width * spool.height * spool.channels * MemoryLayout<UInt16>.size
                let attributes = try FileManager.default.attributesOfItem(atPath: bufferURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
                if byteCount != expectedBytes {
                    imageFailures.append("native RAW spool size is \(byteCount), expected \(expectedBytes)")
                }
                comparison = try runRawDecodeComparator(
                    rawURL: rawURL,
                    nativeBufferURL: bufferURL,
                    width: spool.width,
                    height: spool.height,
                    halfSize: options.halfSize,
                    reportURL: comparatorURL,
                    diffURL: imageDirectory.appendingPathComponent("raw_decode_diff.png")
                )
                if !comparison.passedShape {
                    imageFailures.append("native and rawpy decode dimensions differ")
                }
                if comparison.referenceBitDepth != 16 || comparison.nativeSampleType != "uint16_linear_rgb_spool" {
                    imageFailures.append("RAW comparator did not examine uint16 linear RGB samples")
                }
                let oneSample = 1.0 / 65535.0
                let twoSamples = 2.1 / 65535.0
                if let value = comparison.maskedRGBSSIM, value < 0.99999 {
                    imageFailures.append("linear RGB SSIM \(value) below 0.99999")
                } else if comparison.maskedRGBSSIM == nil {
                    imageFailures.append("linear RGB SSIM missing")
                }
                if let value = comparison.maskedP95AbsDiff, value > oneSample {
                    imageFailures.append("linear RGB P95 absdiff \(value) exceeds one 16-bit sample")
                } else if comparison.maskedP95AbsDiff == nil {
                    imageFailures.append("linear RGB P95 absdiff missing")
                }
                if let value = comparison.maxAbsDiff, value > twoSamples {
                    imageFailures.append("linear RGB max absdiff \(value) exceeds two 16-bit samples")
                } else if comparison.maxAbsDiff == nil {
                    imageFailures.append("linear RGB max absdiff missing")
                }
                for channel in ["red", "green", "blue"] {
                    guard let channelMetrics = comparison.perChannel?[channel] else {
                        imageFailures.append("linear RGB \(channel) channel metrics missing")
                        continue
                    }
                    if channelMetrics.ssim < 0.99999 {
                        imageFailures.append("linear RGB \(channel) SSIM \(channelMetrics.ssim) below 0.99999")
                    }
                    if channelMetrics.maxAbsDiff > twoSamples {
                        imageFailures.append("linear RGB \(channel) max absdiff \(channelMetrics.maxAbsDiff) exceeds two 16-bit samples")
                    }
                }
            } catch {
                imageFailures.append(error.localizedDescription)
                comparison = unavailableComparison(width: nativeWidth, height: nativeHeight)
            }
            imageReports.append(RawDecodeParityImageReport(
                path: rawURL.path,
                nativeHandle: "direct-native16-spool",
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight,
                nativeBitDepth: nativeBitDepth,
                nativeLinearBufferPath: "",
                comparatorReportPath: FileManager.default.fileExists(atPath: comparatorURL.path) ? comparatorURL.path : "",
                comparison: comparison,
                failures: imageFailures
            ))
            failures.append(contentsOf: imageFailures.map { "\(rawURL.path): \($0)" })
        }
        let report = RawDecodeParityReport(
            passed: failures.isEmpty && imageReports.count == urls.count,
            halfSize: options.halfSize,
            outputDirectory: options.outputDirectory.path,
            images: imageReports,
            failures: failures
        )
        try writeJSON(
            report,
            to: options.outputDirectory.appendingPathComponent("report.json"),
            provenance: try rawDecodeProvenance(options: options)
        )
        return report
    }

    static func orderedParityURLs(paths: [String], mode: String) throws -> [URL] {
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        switch mode {
        case "original":
            return urls
        case "reverse":
            return Array(urls.reversed())
        case "sorted":
            return urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        default:
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported parity order mode: \(mode)"])
        }
    }

    static func canonicalParityURLs(paths: [String]) throws -> [URL] {
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let metadata = urls.map { url in
            (url: url, captureDate: captureDateTimeOriginal(for: url))
        }
        if metadata.allSatisfy({ ($0.captureDate ?? "").isEmpty == false }) {
            return metadata.sorted {
                if $0.captureDate != $1.captureDate {
                    return ($0.captureDate ?? "") < ($1.captureDate ?? "")
                }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }.map(\.url)
        }
        return urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func captureDateTimeOriginal(for url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !value.isEmpty {
                return value
            }
            if let value = exif[kCGImagePropertyExifDateTimeDigitized] as? String, !value.isEmpty {
                return value
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    static func runPreviewParitySuite(arguments: [String]) throws -> PreviewParitySuiteReport {
        let options = try parsePreviewParitySuiteOptions(arguments)
        let outputDirectory = options.outputDirectory
        let settingsModes = options.settingsFilters.isEmpty ? ["ui-default", "camera"] : ["ui-default", "camera"].filter { options.settingsFilters.contains($0) }
        let orderModes = options.orderFilters.isEmpty ? ["original", "sorted", "reverse"] : ["original", "sorted", "reverse"].filter { options.orderFilters.contains($0) }
        guard !settingsModes.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite selected no settings modes"])
        }
        guard !orderModes.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite selected no input orders"])
        }
        let root = try repositoryRoot()
        let rawDirectory = root.appendingPathComponent("test_astro/raw", isDirectory: true)
        let rawIDs = Array(6046...6052)
        var cases: [(String, [URL])] = []
        for start in 0...(rawIDs.count - 3) {
            let ids = Array(rawIDs[start..<(start + 3)])
            cases.append(("raw-\(ids.first!)-\(ids.last!)-3", ids.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }))
        }
        for start in 0...(rawIDs.count - 4) {
            let ids = Array(rawIDs[start..<(start + 4)])
            cases.append(("raw-\(ids.first!)-\(ids.last!)-4", ids.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }))
        }
        cases.append(("raw-6046-6052-7", rawIDs.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }))

        var suiteCases: [PreviewParitySuiteCase] = []
        var allFailures: [String] = []
        var selectedCount = 0
        var skippedCount = 0
        for (caseID, urls) in cases {
            for mode in settingsModes {
                for order in orderModes {
                    let runCaseID = "\(caseID)-\(order)"
                    let selected = options.caseFilters.isEmpty
                        || options.caseFilters.contains(caseID)
                        || options.caseFilters.contains(runCaseID)
                    if !selected {
                        continue
                    }
                    selectedCount += 1
                    let reportPathURL = previewParityReportURL(
                        outputDirectory: outputDirectory,
                        caseID: runCaseID,
                        settingsMode: mode,
                        orderMode: order
                    )
                    let caseOptions = PreviewParityOptions(
                        caseID: runCaseID,
                        settingsMode: mode,
                        orderMode: order,
                        outputDirectory: outputDirectory,
                        reusePythonOracle: options.reusePythonOracle,
                        paths: urls.map(\.path)
                    )
                    let expectedProvenance = try previewCaseProvenance(options: caseOptions)
                    if options.resume,
                       let existingPassed = try existingPreviewParityPassed(
                           reportPathURL,
                           expectedFingerprint: expectedProvenance.fingerprint
                       ),
                       existingPassed {
                        skippedCount += 1
                        suiteCases.append(PreviewParitySuiteCase(
                            id: runCaseID,
                            settingsMode: mode,
                            inputOrder: order,
                            status: "skipped_existing_pass",
                            reportPath: reportPathURL.path,
                            failures: []
                        ))
                        continue
                    }
                    let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
                    if !missing.isEmpty {
                        let failures = missing.map { "missing RAW input: \($0.path)" }
                        allFailures.append(contentsOf: failures.map { "\(runCaseID)/\(mode)/\(order): \($0)" })
                        suiteCases.append(PreviewParitySuiteCase(
                            id: runCaseID,
                            settingsMode: mode,
                            inputOrder: order,
                            status: "failed",
                            reportPath: nil,
                            failures: failures
                        ))
                        continue
                    }
                    do {
                        let report = try comparePreviewParity(options: caseOptions)
                        if !report.passed {
                            allFailures.append(contentsOf: report.failures.map { "\(runCaseID)/\(mode)/\(order): \($0)" })
                        }
                        suiteCases.append(PreviewParitySuiteCase(
                            id: runCaseID,
                            settingsMode: mode,
                            inputOrder: order,
                            status: report.passed ? "passed" : "failed",
                            reportPath: reportPathURL.path,
                            failures: report.failures
                        ))
                    } catch {
                        let failure = error.localizedDescription
                        allFailures.append("\(runCaseID)/\(mode)/\(order): \(failure)")
                        suiteCases.append(PreviewParitySuiteCase(
                            id: runCaseID,
                            settingsMode: mode,
                            inputOrder: order,
                            status: "failed",
                            reportPath: nil,
                            failures: [failure]
                        ))
                    }
                }
            }
        }
        guard selectedCount > 0 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite selected no cases"])
        }
        let suite = PreviewParitySuiteReport(
            passed: allFailures.isEmpty,
            outputDirectory: outputDirectory.path,
            selectedCount: selectedCount,
            skippedCount: skippedCount,
            cases: suiteCases,
            failures: allFailures
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let suiteInputs = rawIDs.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }
        let suiteProvenance = try makeProvenance(
            inputURLs: suiteInputs,
            configuration: [
                "artifact": "preview-parity-suite",
                "case_filters": options.caseFilters.sorted().joined(separator: ","),
                "settings_modes": settingsModes.joined(separator: ","),
                "order_modes": orderModes.joined(separator: ","),
                "selected_count": String(selectedCount),
            ]
        )
        try writeJSON(
            suite,
            to: outputDirectory.appendingPathComponent("suite_report.json"),
            provenance: suiteProvenance
        )
        return suite
    }

    static func runExportParitySuite(arguments: [String]) throws -> ExportParitySuiteReport {
        let options = try parseExportParitySuiteOptions(arguments)
        let settingsModes = options.settingsFilters.isEmpty
            ? ["ui-default", "camera"]
            : ["ui-default", "camera"].filter { options.settingsFilters.contains($0) }
        let orderModes = options.orderFilters.isEmpty
            ? ["sorted", "reverse"]
            : ["sorted", "reverse"].filter { options.orderFilters.contains($0) }
        guard !settingsModes.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite selected no settings modes"])
        }
        guard !orderModes.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite selected no input orders"])
        }

        let root = try repositoryRoot()
        let rawDirectory = root.appendingPathComponent("test_astro/raw", isDirectory: true)
        let cases: [(String, [Int])] = [
            ("raw-6050-6052-3", [6050, 6051, 6052]),
            ("raw-6049-6052-4", [6049, 6050, 6051, 6052]),
            ("raw-6046-6052-7", Array(6046...6052))
        ]
        let stretchModes = options.includeStretch ? [false, true] : [false]
        var suiteCases: [ExportParitySuiteCase] = []
        var allFailures: [String] = []
        var selectedCount = 0
        var skippedCount = 0

        for (caseID, ids) in cases {
            let urls = ids.map { rawDirectory.appendingPathComponent("_DSC\($0).ARW") }
            for settingsMode in settingsModes {
                for orderMode in orderModes {
                    for applyStretch in stretchModes {
                        let stretchName = applyStretch ? "stretch" : "linear"
                        let runCaseID = "\(caseID)-\(orderMode)-\(stretchName)"
                        let selected = options.caseFilters.isEmpty
                            || options.caseFilters.contains(caseID)
                            || options.caseFilters.contains(runCaseID)
                        if !selected {
                            continue
                        }
                        selectedCount += 1
                        let reportURL = exportParityReportURL(
                            outputDirectory: options.outputDirectory,
                            caseID: runCaseID,
                            settingsMode: settingsMode,
                            orderMode: orderMode
                        )
                        let caseOptions = ExportParityOptions(
                            caseID: runCaseID,
                            settingsMode: settingsMode,
                            orderMode: orderMode,
                            outputDirectory: options.outputDirectory,
                            renderer: options.renderer,
                            bitDepth: 16,
                            applyPreviewStretch: applyStretch,
                            paths: urls.map(\.path)
                        )
                        let expectedProvenance = try exportCaseProvenance(options: caseOptions)
                        if options.resume,
                           let existingPassed = try existingPreviewParityPassed(
                               reportURL,
                               expectedFingerprint: expectedProvenance.fingerprint
                           ),
                           existingPassed {
                            skippedCount += 1
                            suiteCases.append(ExportParitySuiteCase(
                                id: runCaseID,
                                settingsMode: settingsMode,
                                inputOrder: orderMode,
                                applyPreviewStretch: applyStretch,
                                status: "skipped_existing_pass",
                                reportPath: reportURL.path,
                                failures: []
                            ))
                            continue
                        }
                        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
                        if !missing.isEmpty {
                            let failures = missing.map { "missing RAW input: \($0.path)" }
                            allFailures.append(contentsOf: failures.map { "\(runCaseID)/\(settingsMode)/\(orderMode): \($0)" })
                            suiteCases.append(ExportParitySuiteCase(
                                id: runCaseID,
                                settingsMode: settingsMode,
                                inputOrder: orderMode,
                                applyPreviewStretch: applyStretch,
                                status: "failed",
                                reportPath: nil,
                                failures: failures
                            ))
                            continue
                        }
                        do {
                            let report = try compareExportParity(options: caseOptions)
                            if !report.passed {
                                allFailures.append(contentsOf: report.failures.map { "\(runCaseID)/\(settingsMode)/\(orderMode): \($0)" })
                            }
                            suiteCases.append(ExportParitySuiteCase(
                                id: runCaseID,
                                settingsMode: settingsMode,
                                inputOrder: orderMode,
                                applyPreviewStretch: applyStretch,
                                status: report.passed ? "passed" : "failed",
                                reportPath: reportURL.path,
                                failures: report.failures
                            ))
                        } catch {
                            let failure = error.localizedDescription
                            allFailures.append("\(runCaseID)/\(settingsMode)/\(orderMode): \(failure)")
                            suiteCases.append(ExportParitySuiteCase(
                                id: runCaseID,
                                settingsMode: settingsMode,
                                inputOrder: orderMode,
                                applyPreviewStretch: applyStretch,
                                status: "failed",
                                reportPath: nil,
                                failures: [failure]
                            ))
                        }
                    }
                }
            }
        }
        guard selectedCount > 0 else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite selected no cases"])
        }
        let suite = ExportParitySuiteReport(
            passed: allFailures.isEmpty,
            outputDirectory: options.outputDirectory.path,
            renderer: options.renderer,
            bitDepth: 16,
            selectedCount: selectedCount,
            skippedCount: skippedCount,
            cases: suiteCases,
            failures: allFailures
        )
        let suiteInputs = Array(6046...6052).map {
            rawDirectory.appendingPathComponent("_DSC\($0).ARW")
        }
        let suiteProvenance = try makeProvenance(
            inputURLs: suiteInputs,
            configuration: [
                "artifact": "export-parity-suite",
                "case_filters": options.caseFilters.sorted().joined(separator: ","),
                "settings_modes": settingsModes.joined(separator: ","),
                "order_modes": orderModes.joined(separator: ","),
                "renderer": options.renderer,
                "include_stretch": String(options.includeStretch),
                "selected_count": String(selectedCount),
            ]
        )
        try writeJSON(
            suite,
            to: options.outputDirectory.appendingPathComponent("suite_report.json"),
            provenance: suiteProvenance
        )
        return suite
    }

    static func parseExportParitySuiteOptions(_ arguments: [String]) throws -> ExportParitySuiteOptions {
        var options = ExportParitySuiteOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite requires a path after --output-dir"])
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--case":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite requires a value after --case"])
                }
                options.caseFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--settings":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite requires a value after --settings"])
                }
                options.settingsFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--order":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite requires a value after --order"])
                }
                options.orderFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--renderer":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite requires a value after --renderer"])
                }
                options.renderer = arguments[index]
            case "--linear-only":
                options.includeStretch = false
            case "--resume":
                options.resume = true
            default:
                throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown parity run-export-suite argument: \(argument)"])
            }
            index += 1
        }
        let allowedSettings = Set(["ui-default", "camera"])
        let invalidSettings = options.settingsFilters.subtracting(allowedSettings)
        if !invalidSettings.isEmpty {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite --settings must contain only ui-default or camera"])
        }
        let allowedOrders = Set(["sorted", "reverse"])
        let invalidOrders = options.orderFilters.subtracting(allowedOrders)
        if !invalidOrders.isEmpty {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite --order must contain only sorted or reverse"])
        }
        guard options.renderer == "cpu" || options.renderer == "metal_quality" else {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-export-suite --renderer must be cpu or metal_quality"])
        }
        return options
    }

    static func exportParityReportURL(
        outputDirectory: URL,
        caseID: String,
        settingsMode: String,
        orderMode: String
    ) -> URL {
        outputDirectory
            .appendingPathComponent(sanitizeFilename(caseID), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(settingsMode), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(orderMode), isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent("report.json")
    }

    static func validateFocusedRelease(
        arguments: [String],
        writeOutput: Bool = true
    ) throws -> NativeParityReleaseReport {
        let options = try parseReleaseValidationOptions(arguments)
        var failures: [String] = []
        var provenanceAudit = ReleaseProvenanceAudit()

        func readFocused(_ url: URL?, label: String) -> JSONValue? {
            let report = readReleaseArtifact(url, label: label, failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: label,
                requiresOracle: false,
                audit: &provenanceAudit,
                failures: &failures
            )
            return report
        }
        func passed(_ report: JSONValue?) -> Bool {
            report?["passed"]?.boolValue == true || report?["success"]?.boolValue == true
        }

        let raw2Auto = readFocused(options.raw2AutoRefinement, label: "raw_2 auto-refinement report")
        let astroGeometry = raw2Auto?["artifact"]?.stringValue == "raw2-auto-refinement"
            && passed(raw2Auto)
            && Int(raw2Auto?["image_count"]?.numberValue ?? 0) == 8
            && raw2Auto?["geometry"]?.stringValue == "camera"
            && raw2Auto?["astro_refinement_state"]?.stringValue == "passed"
            && raw2Auto?["held_out_gate_passed"]?.boolValue == true
            && Int(raw2Auto?["grid_columns"]?.numberValue ?? 0) == 16
            && Int(raw2Auto?["grid_rows"]?.numberValue ?? 0) == 8
            && raw2Auto?["correct_pair_selected"]?.boolValue == true
            && raw2Auto?["wrong_pair_selected"]?.boolValue == false
        if !astroGeometry {
            failures.append("raw_2 auto refinement must pass Camera held-out 16x8 gates, select 2177↔2175, and exclude 2183↔2175")
        }

        let raw2Manual = readFocused(options.raw2ManualReoptimization, label: "raw_2 manual re-optimization report")
        let manualReoptimization = raw2Manual?["artifact"]?.stringValue == "raw2-manual-reopt"
            && passed(raw2Manual)
            && Int(raw2Manual?["image_count"]?.numberValue ?? 0) == 8
            && Int(raw2Manual?["manual_input"]?.numberValue ?? 0) == 7
            && raw2Manual?["manual_accounting_passed"]?.boolValue == true
            && raw2Manual?["geometry_gate_passed"]?.boolValue == true
            && raw2Manual?["rerendered_geometry"]?.stringValue == "camera"
            && raw2Manual?["dirty_cleared"]?.boolValue == true
            && (raw2Manual?["manual_points"]?.arrayValue?.count ?? 0) == 7
            && (raw2Manual?["manual_points"]?.arrayValue ?? []).allSatisfy {
                !($0["reason"]?.stringValue ?? "").isEmpty
            }
        if !manualReoptimization {
            failures.append("raw_2 seven-point manual re-optimization evidence is incomplete or remained dirty")
        }

        let exportPairReport = readFocused(options.raw2ExportPair, label: "raw_2 16-bit export pair report")
        let coverageIoU = exportPairReport?["coverage_iou"]?.numberValue ?? -.infinity
        let rgbSSIM = exportPairReport?["rgb_ssim"]?.numberValue ?? -.infinity
        let medianAbsDiff = exportPairReport?["median_absdiff"]?.numberValue ?? .infinity
        let p95AbsDiff = exportPairReport?["p95_absdiff"]?.numberValue ?? .infinity
        let exportPair = exportPairReport?["artifact"]?.stringValue == "raw2-export-pair"
            && passed(exportPairReport)
            && Int(exportPairReport?["bit_depth"]?.numberValue ?? 0) == 16
            && exportPairReport?["cpu_renderer_verified"]?.boolValue == true
            && exportPairReport?["metal_quality_renderer_verified"]?.boolValue == true
            && exportPairReport?["dimensions_match"]?.boolValue == true
            && exportPairReport?["coverage_match"]?.boolValue == true
            && exportPairReport?["pixel_quality_passed"]?.boolValue == true
            && exportPairReport?["same_result_handle"]?.boolValue == true
            && exportPairReport?["metal_fallback"]?.boolValue == false
            && coverageIoU >= 0.999
            && rgbSSIM >= 0.999
            && medianAbsDiff <= 0.001
            && p95AbsDiff <= 0.005
        if !exportPair {
            failures.append("raw_2 CPU/Metal Quality 16-bit export-pair evidence is incomplete")
        }

        let raw2Evidence = [raw2Auto, raw2Manual, exportPairReport].compactMap { $0 }
        let stitchConfigurationHashes = Set(raw2Evidence.compactMap {
            $0["stitch_configuration_sha256"]?.stringValue
        })
        let lensProfileHashes = Set(raw2Evidence.compactMap {
            $0["lens_profile_sha256"]?.stringValue
        })
        let sourceFingerprints = Set(raw2Evidence.compactMap {
            $0["provenance"]?["source_fingerprint"]?.stringValue
        })
        let raw2EvidenceBound = raw2Evidence.count == 3
            && stitchConfigurationHashes.count == 1
            && stitchConfigurationHashes.first.map { isLowercaseHex($0, count: 64) } == true
            && lensProfileHashes.count == 1
            && lensProfileHashes.first.map { $0 == "none" || isLowercaseHex($0, count: 64) } == true
            && sourceFingerprints.count == 1
            && sourceFingerprints.first.map { isLowercaseHex($0, count: 64) } == true
        if !raw2EvidenceBound {
            failures.append("raw_2 auto/manual/export evidence must bind one source, stitch configuration, and lens-profile SHA-256")
        }

        for (label, pathKey, digestKey) in [
            ("CPU", "cpu_output_path", "cpu_output_sha256"),
            ("Metal Quality", "metal_output_path", "metal_output_sha256"),
        ] {
            guard let path = exportPairReport?[pathKey]?.stringValue,
                  let digest = exportPairReport?[digestKey]?.stringValue,
                  isLowercaseHex(digest, count: 64),
                  FileManager.default.fileExists(atPath: path),
                  (try? sha256File(URL(fileURLWithPath: path))) == digest else {
                failures.append("raw_2 \(label) export output is missing or its SHA-256 does not match the report")
                continue
            }
        }

        let canvasReport = readFocused(options.raw1CanvasSmoke, label: "raw_1 projection-canvas report")
        let canvasCoverage = canvasReport?["artifact"]?.stringValue == "raw1-canvas-smoke"
            && passed(canvasReport)
            && Int(canvasReport?["image_count"]?.numberValue ?? 0) == 7
            && abs((canvasReport?["pitch_degrees"]?.numberValue ?? .infinity) - 39.91) <= 0.01
            && abs((canvasReport?["yaw_degrees"]?.numberValue ?? .infinity) - 88.19) <= 0.01
            && canvasReport?["coverage_not_clipped"]?.boolValue == true
            && canvasReport?["excess_transparent_band"]?.boolValue == false
            && canvasReport?["canvas_centered"]?.boolValue == true
        if !canvasCoverage {
            failures.append("raw_1 pitch 39.91° / yaw 88.19° canvas coverage smoke is missing or clipped")
        }

        var ordinaryImages = !options.ordinaryImageReports.isEmpty
        for url in options.ordinaryImageReports {
            let report = readFocused(url, label: "ordinary-image report")
            let valid = report?["artifact"]?.stringValue == "standard-image-regression"
                && passed(report)
                && report?["geometry"]?.stringValue == "homography"
                && report?["camera_model_attempted"]?.boolValue == false
            ordinaryImages = ordinaryImages && valid
        }
        if !ordinaryImages {
            failures.append("at least one passing synthetic ordinary-image homography report is required")
        }

        var controlPoints = !options.controlPointReports.isEmpty
        for url in options.controlPointReports {
            let report = readFocused(url, label: "control-point report")
            controlPoints = controlPoints
                && report?["artifact"]?.stringValue == "control-point-rerender"
                && passed(report)
                && report?["manual_point_accounting_passed"]?.boolValue == true
        }
        if !controlPoints {
            failures.append("focused control-point evidence must prove explicit manual-point accounting")
        }

        var refinementCancellation = options.refinementCancellationReports.count == 1
        for url in options.refinementCancellationReports {
            let report = readFocused(url, label: "astro-refinement cancellation report")
            refinementCancellation = refinementCancellation
                && report?["artifact"]?.stringValue == "astro-refinement-cancellation"
                && passed(report)
                && report?["stale_result_applied"]?.boolValue == false
                && report?["dirty_preserved"]?.boolValue == true
        }
        if !refinementCancellation {
            failures.append("one passing background astro-refinement cancellation report is required")
        }

        var projectionReleaseBarrier = options.projectionReleaseReports.count == 1
        for url in options.projectionReleaseReports {
            let report = readFocused(url, label: "projection release-barrier report")
            projectionReleaseBarrier = projectionReleaseBarrier
                && report?["artifact"]?.stringValue == "projection-drag-smoke"
                && report?["case_id"]?.stringValue == "raw2"
                && Int(report?["image_count"]?.numberValue ?? 0) == 8
                && passed(report)
                && report?["release_barrier_passed"]?.boolValue == true
                && report?["geometry_persisted"]?.boolValue == true
                && (report?["median_latency_ms"]?.numberValue ?? .infinity) <= 100
                && (report?["p95_latency_ms"]?.numberValue ?? .infinity) <= 200
                && (report?["max_latency_ms"]?.numberValue ?? .infinity) <= 350
        }
        if !projectionReleaseBarrier {
            failures.append("one raw_2 projection session report must pass the 100/200/350 ms and release-barrier gates")
        }

        var installationLaunch = options.installationReports.count == 1
        for url in options.installationReports {
            let report = readFocused(url, label: "PanoLume installation report")
            installationLaunch = installationLaunch
                && report?["artifact"]?.stringValue == "panolume-install-smoke"
                && passed(report)
                && report?["bundle_identifier"]?.stringValue == "com.zhaoxinmiao.PanoLume"
                && report?["codesign_verified"]?.boolValue == true
                && report?["relocatable_dependencies_verified"]?.boolValue == true
                && report?["icon_verified"]?.boolValue == true
                && report?["launch_verified"]?.boolValue == true
        }
        if !installationLaunch {
            failures.append("one signed, relocatable PanoLume install-and-launch report is required")
        }

        let checklist = NativeParityReleaseChecklist(
            astroGeometry: astroGeometry,
            manualReoptimization: manualReoptimization,
            exportPair: exportPair,
            canvasCoverage: canvasCoverage,
            ordinaryImages: ordinaryImages,
            controlPoints: controlPoints,
            refinementCancellation: refinementCancellation,
            projectionReleaseBarrier: projectionReleaseBarrier,
            installationLaunch: installationLaunch
        )
        let artifacts: [String: [String]] = [
            "raw2_auto_refinement": options.raw2AutoRefinement.map { [$0.path] } ?? [],
            "raw2_manual_reoptimization": options.raw2ManualReoptimization.map { [$0.path] } ?? [],
            "raw2_export_pair": options.raw2ExportPair.map { [$0.path] } ?? [],
            "raw1_canvas_smoke": options.raw1CanvasSmoke.map { [$0.path] } ?? [],
            "ordinary_image_reports": options.ordinaryImageReports.map(\.path),
            "control_point_reports": options.controlPointReports.map(\.path),
            "refinement_cancellation_reports": options.refinementCancellationReports.map(\.path),
            "projection_release_reports": options.projectionReleaseReports.map(\.path),
            "installation_reports": options.installationReports.map(\.path),
        ]
        let artifactURLs = artifacts.values.flatMap { $0 }.map(URL.init(fileURLWithPath:))
        let releaseProvenance = try makeProvenance(
            inputURLs: artifactURLs,
            configuration: [
                "artifact": "panolume-focused-release-validation-v3",
                "artifact_count": String(provenanceAudit.artifactCount),
                "candidate_certification": String(options.candidateCertification),
            ]
        )
        let sourceCertificationMatch = certifiedAlgorithmSourceFingerprint(root: try repositoryRoot())
            == releaseProvenance.sourceFingerprint
        if !sourceCertificationMatch && !options.candidateCertification {
            failures.append("current source is not promoted; use --candidate-certification only for a controlled candidate report")
        }
        if !releaseProvenance.worktreeClean {
            failures.append("focused release validation must run from a clean worktree")
        }
        if let value = provenanceAudit.sourceCommit, value != releaseProvenance.sourceCommit {
            failures.append("focused evidence source commit differs from the current source commit")
        }
        if let value = provenanceAudit.sourceFingerprint, value != releaseProvenance.sourceFingerprint {
            failures.append("focused evidence source fingerprint differs from the current source fingerprint")
        }
        if let value = provenanceAudit.binaryEngineSourceFingerprint,
           value != releaseProvenance.binaryEngineSourceFingerprint {
            failures.append("focused evidence embedded engine fingerprint differs from the current regression binary")
        }
        if let value = provenanceAudit.regressionExecutableSHA256,
           value != releaseProvenance.regressionExecutableSHA256 {
            failures.append("focused evidence was produced by another regression executable")
        }

        var finalReport = NativeParityReleaseReport(
            passed: checklist.allPassed && failures.isEmpty,
            candidateCertification: options.candidateCertification,
            sourceCertificationMatch: sourceCertificationMatch,
            checklist: checklist,
            artifacts: artifacts,
            failures: failures,
            reportPayloadSHA256: ""
        )
        finalReport.reportPayloadSHA256 = try CandidateReleaseReportIntegrity
            .canonicalPayloadSHA256(reportData: JSONEncoder().encode(finalReport))
        if writeOutput {
            let output = options.output ?? URL(fileURLWithPath: "/tmp/panolume_focused_release_report.json")
            try writeJSON(finalReport, to: output, provenance: releaseProvenance)
        }
        return finalReport
    }

    static func validateParityRelease(
        arguments: [String],
        writeOutput: Bool = true
    ) throws -> NativeParityReleaseReport {
        let options = try parseReleaseValidationOptions(arguments)
        var failures: [String] = []
        var provenanceAudit = ReleaseProvenanceAudit()
        let preview = readReleaseArtifact(options.previewSuite, label: "preview suite", failures: &failures)
        validateReleaseProvenance(
            preview,
            url: options.previewSuite,
            label: "preview suite",
            requiresOracle: true,
            audit: &provenanceAudit,
            failures: &failures
        )
        let alignmentQuality = preview?[
            "passed"
        ]?.boolValue == true && (preview?["selected_count"]?.numberValue ?? 0) >= 60
        if !alignmentQuality {
            failures.append("preview suite must pass all 60 preview parity cases")
        }
        validateSuiteCaseProvenance(
            preview,
            label: "preview suite",
            minimumCount: 60,
            audit: &provenanceAudit,
            failures: &failures
        )

        let cpuExport = validateExportReleaseEvidence(
            options.cpuExportSuite,
            label: "CPU export suite",
            expectedRenderer: "cpu",
            provenanceAudit: &provenanceAudit,
            failures: &failures
        )
        let metalExport = validateExportReleaseEvidence(
            options.metalExportSuite,
            label: "Metal export suite",
            expectedRenderer: "metal_quality",
            provenanceAudit: &provenanceAudit,
            failures: &failures
        )

        let raw = readReleaseArtifact(options.rawDecode, label: "full-size RAW decode report", failures: &failures)
        validateReleaseProvenance(
            raw,
            url: options.rawDecode,
            label: "full-size RAW decode report",
            requiresOracle: true,
            audit: &provenanceAudit,
            failures: &failures
        )
        let colorAndLinearHandling = raw?["passed"]?.boolValue == true
            && raw?["half_size"]?.boolValue == false
            && (raw?["images"]?.arrayValue?.count ?? 0) >= 7
        if !colorAndLinearHandling {
            failures.append("full-size RAW decode report must pass for all seven release RAW files")
        }

        var standardImageEvidence: [ReleaseStandardImageEvidence] = []
        for url in options.standardImageReports {
            let report = readReleaseArtifact(url, label: "standard-image report", failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: "standard-image report",
                audit: &provenanceAudit,
                failures: &failures
            )
            guard let report else { continue }
            standardImageEvidence.append(ReleaseStandardImageEvidence(
                artifact: report["artifact"]?.stringValue,
                caseID: report["case_id"]?.stringValue,
                imageCount: report["image_count"]?.numberValue.map { Int($0) },
                passed: report["passed"]?.boolValue == true,
                geometry: report["geometry"]?.stringValue,
                cameraModelAttempted: report["camera_model_attempted"]?.boolValue,
                worstPairP95: report["worst_pair_p95"]?.numberValue,
                maskedSSIM: report["visual_metrics"]?["masked_ssim"]?.numberValue,
                previewSeconds: report["preview_seconds"]?.numberValue
            ))
        }

        var controlPointEvidence: [ReleaseControlPointEvidence] = []
        for url in options.controlPointReports {
            let report = readReleaseArtifact(url, label: "control-point report", failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: "control-point report",
                audit: &provenanceAudit,
                failures: &failures
            )
            guard let report else { continue }
            controlPointEvidence.append(ReleaseControlPointEvidence(
                artifact: report["artifact"]?.stringValue,
                caseID: report["case_id"]?.stringValue,
                imageCount: report["image_count"]?.numberValue.map { Int($0) },
                success: report["success"]?.boolValue == true,
                testKind: report["test_kind"]?.stringValue,
                originalGeometry: report["original_geometry"]?.stringValue
                    ?? report["geometry"]?.stringValue,
                rerenderedGeometry: report["rerendered_geometry"]?.stringValue,
                manualPointAccountingPassed: report["manual_point_accounting_passed"]?.boolValue,
                manualPointRoundTripPassed: report["manual_point_round_trip_passed"]?.boolValue,
                explicitDisconnectedError: report["explicit_disconnected_error"]?.boolValue
            ))
        }

        var dragEvidence: [ReleaseDragEvidence] = []
        for url in options.dragReports {
            let report = readReleaseArtifact(url, label: "drag report", failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: "drag report",
                audit: &provenanceAudit,
                failures: &failures
            )
            guard let report else { continue }
            dragEvidence.append(ReleaseDragEvidence(
                artifact: report["artifact"]?.stringValue,
                caseID: report["case_id"]?.stringValue,
                imageCount: report["image_count"]?.numberValue.map { Int($0) },
                inputCount: report["input_count"]?.numberValue.map { Int($0) },
                success: report["success"]?.boolValue == true,
                blendAfterDrag: report["blend_after_drag"]?.boolValue,
                commitQuality: report["commit_quality"]?.stringValue,
                medianLatencyMS: report["median_latency_ms"]?.numberValue,
                p95LatencyMS: report["p95_latency_ms"]?.numberValue,
                maxLatencyMS: report["max_latency_ms"]?.numberValue,
                commitLatencyMS: report["commit_latency_ms"]?.numberValue,
                commitLatencyGatePassed: report["commit_latency_gate_passed"]?.boolValue,
                dragPreviewWidth: report["drag_preview_width"]?.numberValue.map { Int($0) },
                dragPreviewHeight: report["drag_preview_height"]?.numberValue.map { Int($0) },
                committedWidth: report["committed_width"]?.numberValue.map { Int($0) },
                committedHeight: report["committed_height"]?.numberValue.map { Int($0) },
                dimensionGatePassed: report["dimension_gate_passed"]?.boolValue == true,
                dragFrameChanged: report["drag_frame_changed"]?.boolValue == true,
                geometryPersisted: report["geometry_persisted"]?.boolValue == true,
                committedPixelsChanged: report["committed_pixels_changed"]?.boolValue == true,
                committedPixelsRetained: report["committed_pixels_retained"]?.boolValue == true,
                independentCommitPassed: report["independent_commit_passed"]?.boolValue == true,
                independentCommitSSIM: report["independent_commit_ssim"]?.numberValue,
                committedRendererPassed: report["committed_renderer_passed"]?.boolValue == true
            ))
        }

        var cancellationEvidence: [ReleaseCancellationEvidence] = []
        for url in options.cancellationReports {
            let report = readReleaseArtifact(url, label: "cancellation report", failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: "cancellation report",
                audit: &provenanceAudit,
                failures: &failures
            )
            guard let report else { continue }
            cancellationEvidence.append(ReleaseCancellationEvidence(
                artifact: report["artifact"]?.stringValue,
                operation: report["operation"]?.stringValue,
                caseID: report["case_id"]?.stringValue,
                imageCount: report["image_count"]?.numberValue.map { Int($0) },
                inputCount: report["input_count"]?.numberValue.map { Int($0) },
                passed: report["passed"]?.boolValue == true,
                partialOutputExists: report["partial_output_exists"]?.boolValue
            ))
        }

        let requiredEvidence = ReleaseRequiredEvidenceValidator.validate(
            drag: dragEvidence,
            cancellation: cancellationEvidence,
            standardImages: standardImageEvidence,
            controlPoints: controlPointEvidence
        )
        failures.append(contentsOf: requiredEvidence.failures)

        let expectedPerfCases = Set(["3raw", "4raw", "7raw"])
        var observedPerfCases = Set<String>()
        var pairedPerfPassed = options.perfReports.count >= 3
        if options.perfReports.count < 3 {
            failures.append("release validation requires paired 3 RAW, 4 RAW, and 7 RAW performance reports")
        }
        for url in options.perfReports {
            let report = readReleaseArtifact(url, label: "paired performance report", failures: &failures)
            validateReleaseProvenance(
                report,
                url: url,
                label: "paired performance report",
                audit: &provenanceAudit,
                failures: &failures
            )
            let caseID = report?["case_id"]?.stringValue ?? "missing"
            observedPerfCases.insert(caseID)
            let passed = report?["passed"]?.boolValue == true
            let repetitions = report?["repetitions"]?.numberValue ?? 0
            let speedup = report?["median_export_speedup"]?.numberValue ?? 0
            if !passed || repetitions < 3 || speedup < 1.5 {
                pairedPerfPassed = false
                failures.append("paired performance report \(url.path) did not prove a 1.5x Metal Quality median speedup")
            }
        }
        if !expectedPerfCases.isSubset(of: observedPerfCases) {
            pairedPerfPassed = false
            failures.append("paired performance reports must cover 3raw, 4raw, and 7raw")
        }

        let checklist = NativeParityReleaseChecklist(
            alignmentQuality: alignmentQuality,
            ordinaryImageQuality: requiredEvidence.standardImagesPassed,
            controlPointEditing: requiredEvidence.controlPointsPassed,
            seamQuality: cpuExport.seamQuality && metalExport.seamQuality,
            bitDepth: cpuExport.bitDepth && metalExport.bitDepth,
            colorAndLinearHandling: colorAndLinearHandling,
            exportCorrectness: cpuExport.exportCorrectness && metalExport.exportCorrectness,
            memoryUse: cpuExport.memoryUse && metalExport.memoryUse,
            performance: requiredEvidence.dragPassed && pairedPerfPassed,
            cancellationSafety: requiredEvidence.cancellationPassed
        )
        let artifacts: [String: [String]] = [
            "preview_suite": options.previewSuite.map { [$0.path] } ?? [],
            "cpu_export_suite": options.cpuExportSuite.map { [$0.path] } ?? [],
            "metal_export_suite": options.metalExportSuite.map { [$0.path] } ?? [],
            "raw_decode": options.rawDecode.map { [$0.path] } ?? [],
            "standard_image_reports": options.standardImageReports.map(\.path),
            "control_point_reports": options.controlPointReports.map(\.path),
            "drag_reports": options.dragReports.map(\.path),
            "cancellation_reports": options.cancellationReports.map(\.path),
            "paired_performance_reports": options.perfReports.map(\.path)
        ]
        let output = options.output ?? URL(fileURLWithPath: "/tmp/panolume_native_parity_release_report.json")
        let cpuExportSuiteJSON = options.cpuExportSuite.flatMap { try? readJSONValue($0) }
        let metalExportSuiteJSON = options.metalExportSuite.flatMap { try? readJSONValue($0) }
        let nestedSuiteReportURLs = suiteCaseReportURLs(preview)
            + suiteCaseReportURLs(cpuExportSuiteJSON)
            + suiteCaseReportURLs(metalExportSuiteJSON)
        let artifactURLs = [options.previewSuite, options.cpuExportSuite, options.metalExportSuite, options.rawDecode]
            .compactMap { $0 }
            + options.standardImageReports
            + options.controlPointReports
            + options.dragReports
            + options.cancellationReports
            + options.perfReports
            + nestedSuiteReportURLs
        let releaseProvenance = try makeProvenance(
            inputURLs: artifactURLs.filter { FileManager.default.fileExists(atPath: $0.path) },
            configuration: [
                "artifact": "native-parity-release-validation",
                "artifact_count": String(provenanceAudit.artifactCount),
                "certified_source_commit": provenanceAudit.sourceCommit ?? "missing",
                "source_fingerprint": provenanceAudit.sourceFingerprint ?? "missing",
                "binary_engine_source_fingerprint": provenanceAudit.binaryEngineSourceFingerprint ?? "missing",
                "regression_executable_sha256": provenanceAudit.regressionExecutableSHA256 ?? "missing",
                "oracle_identity": provenanceAudit.oracleIdentity ?? "missing",
                "candidate_certification": String(options.candidateCertification),
            ]
        )
        let sourceCertificationMatch = certifiedAlgorithmSourceFingerprint(root: try repositoryRoot())
            == releaseProvenance.sourceFingerprint
        if !sourceCertificationMatch && !options.candidateCertification {
            failures.append(
                "current source is not yet certified; rerun release validation with --candidate-certification to produce controlled promotion evidence without opening the runtime gate"
            )
        }
        if !releaseProvenance.worktreeClean {
            failures.append("release validation must run from a clean worktree")
        }
        if let certifiedCommit = provenanceAudit.sourceCommit,
           certifiedCommit != releaseProvenance.sourceCommit {
            failures.append("release evidence source commit \(certifiedCommit) does not match current commit \(releaseProvenance.sourceCommit)")
        }
        if let evidenceFingerprint = provenanceAudit.sourceFingerprint,
           evidenceFingerprint != releaseProvenance.sourceFingerprint {
            failures.append("release evidence source fingerprint does not match the current engine/Metal source fingerprint")
        }
        if let evidenceBinaryFingerprint = provenanceAudit.binaryEngineSourceFingerprint,
           evidenceBinaryFingerprint != releaseProvenance.binaryEngineSourceFingerprint {
            failures.append("release evidence embedded binary fingerprint does not match the current PanoLumeRegression binary")
        }
        if let evidenceExecutableSHA256 = provenanceAudit.regressionExecutableSHA256,
           evidenceExecutableSHA256 != releaseProvenance.regressionExecutableSHA256 {
            failures.append("release evidence was not generated by the current PanoLumeRegression executable")
        }
        if let evidenceOracle = provenanceAudit.oracleIdentity,
           evidenceOracle != releaseProvenance.oracleIdentity {
            failures.append("release evidence Python oracle identity does not match the current oracle")
        }
        var finalReport = NativeParityReleaseReport(
            passed: checklist.allPassed && failures.isEmpty,
            candidateCertification: options.candidateCertification,
            sourceCertificationMatch: sourceCertificationMatch,
            checklist: checklist,
            artifacts: artifacts,
            failures: failures,
            reportPayloadSHA256: ""
        )
        finalReport.reportPayloadSHA256 = try CandidateReleaseReportIntegrity
            .canonicalPayloadSHA256(reportData: JSONEncoder().encode(finalReport))
        if writeOutput {
            try writeJSON(finalReport, to: output, provenance: releaseProvenance)
        }
        return finalReport
    }

    static func parseReleaseValidationOptions(_ arguments: [String]) throws -> ReleaseValidationOptions {
        var options = ReleaseValidationOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--candidate-certification":
                options.candidateCertification = true
            case "--raw2-auto-refinement", "--raw2-manual-reoptimization", "--raw2-export-pair", "--raw1-canvas-smoke", "--ordinary-image-report", "--control-point-report", "--refinement-cancellation-report", "--projection-release-report", "--installation-report", "--output":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity validate-release requires a path after \(argument)"])
                }
                let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                switch argument {
                case "--raw2-auto-refinement": options.raw2AutoRefinement = url
                case "--raw2-manual-reoptimization": options.raw2ManualReoptimization = url
                case "--raw2-export-pair": options.raw2ExportPair = url
                case "--raw1-canvas-smoke": options.raw1CanvasSmoke = url
                case "--ordinary-image-report": options.ordinaryImageReports.append(url)
                case "--control-point-report": options.controlPointReports.append(url)
                case "--refinement-cancellation-report": options.refinementCancellationReports.append(url)
                case "--projection-release-report": options.projectionReleaseReports.append(url)
                case "--installation-report": options.installationReports.append(url)
                case "--output": options.output = url
                default: break
                }
            default:
                throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown parity validate-release argument: \(argument)"])
            }
            index += 1
        }
        return options
    }

    static func releaseRevalidationArguments(
        artifacts: [String: [String]],
        candidateCertification: Bool
    ) -> [String] {
        var arguments: [String] = candidateCertification ? ["--candidate-certification"] : []
        let categories: [(String, String)] = [
            ("raw2_auto_refinement", "--raw2-auto-refinement"),
            ("raw2_manual_reoptimization", "--raw2-manual-reoptimization"),
            ("raw2_export_pair", "--raw2-export-pair"),
            ("raw1_canvas_smoke", "--raw1-canvas-smoke"),
            ("ordinary_image_reports", "--ordinary-image-report"),
            ("control_point_reports", "--control-point-report"),
            ("refinement_cancellation_reports", "--refinement-cancellation-report"),
            ("projection_release_reports", "--projection-release-report"),
            ("installation_reports", "--installation-report"),
        ]
        for (category, option) in categories {
            for path in artifacts[category] ?? [] {
                arguments.append(option)
                arguments.append(path)
            }
        }
        return arguments
    }

    static func validateReleaseProvenance(
        _ report: JSONValue?,
        url: URL?,
        label: String,
        requiresOracle: Bool = false,
        audit: inout ReleaseProvenanceAudit,
        failures: inout [String]
    ) {
        guard let report else {
            return
        }
        guard let provenance = report["provenance"] else {
            failures.append("\(label) lacks provenance schema v4")
            return
        }
        let schemaVersion = Int(provenance["schema_version"]?.numberValue ?? 0)
        let sourceCommit = provenance["source_commit"]?.stringValue ?? ""
        let sourceFingerprint = provenance["source_fingerprint"]?.stringValue ?? ""
        let binaryEngineSourceFingerprint = provenance["binary_engine_source_fingerprint"]?.stringValue ?? ""
        let regressionExecutableSHA256 = provenance["regression_executable_sha256"]?.stringValue ?? ""
        let fingerprint = provenance["fingerprint"]?.stringValue ?? ""
        let configurationSHA256 = provenance["configuration_sha256"]?.stringValue ?? ""
        let toolVersion = provenance["tool_version"]?.stringValue ?? ""
        let metalDylibSHA256 = provenance["metal_dylib_sha256"]?.stringValue ?? ""
        let metalAPIVersion = Int(provenance["metal_api_version"]?.numberValue ?? 0)
        let worktreeClean = provenance["worktree_clean"]?.boolValue ?? false
        let oracleIdentity = provenance["oracle_identity"]?.stringValue ?? ""
        let oracleWorktreeClean = provenance["oracle_worktree_clean"]?.boolValue
        if schemaVersion != RegressionProvenanceSchema.currentVersion
            || !isLowercaseHex(sourceCommit, count: 40)
            || !isLowercaseHex(sourceFingerprint, count: 64)
            || !isLowercaseHex(binaryEngineSourceFingerprint, count: 64)
            || !isLowercaseHex(regressionExecutableSHA256, count: 64)
            || !isLowercaseHex(fingerprint, count: 64)
            || !isLowercaseHex(configurationSHA256, count: 64)
            || toolVersion != RegressionProvenanceSchema.toolVersion {
            failures.append("\(label) has incomplete provenance at \(url?.path ?? "unknown path")")
            return
        }
        if sourceFingerprint != binaryEngineSourceFingerprint {
            failures.append("\(label) was generated by a stale PanoLumeRegression binary whose embedded engine/Metal fingerprint differs from its workspace")
        }
        if !worktreeClean {
            failures.append("\(label) was produced from a dirty worktree")
        }
        if report["provenance"]?["input_sha256"] == nil {
            failures.append("\(label) provenance lacks input SHA-256 values")
        }
        do {
            if try recomputeProvenanceFingerprint(provenance) != fingerprint {
                failures.append("\(label) provenance fingerprint does not match its canonical payload")
            }
        } catch {
            failures.append("\(label) provenance fingerprint payload is malformed")
        }
        if requiresOracle && !isLowercaseHex(oracleIdentity, count: 64) {
            failures.append("\(label) provenance lacks a deterministic Python oracle identity")
        }
        if requiresOracle && oracleWorktreeClean != true {
            failures.append("\(label) provenance does not prove a clean standalone Python oracle Git worktree")
        }
        if !oracleIdentity.isEmpty && oracleWorktreeClean != true {
            failures.append("\(label) records a Python oracle identity without a clean oracle worktree binding")
        }
        if !isLowercaseHex(metalDylibSHA256, count: 64)
            || metalAPIVersion != NativeEngineBridge.currentMetalRendererAPIVersion {
            failures.append(
                "\(label) does not identify the current Metal ABI v\(NativeEngineBridge.currentMetalRendererAPIVersion) dylib"
            )
        }
        if let expectedCommit = audit.sourceCommit, expectedCommit != sourceCommit {
            failures.append("\(label) source commit \(sourceCommit) differs from \(expectedCommit)")
        } else if audit.sourceCommit == nil {
            audit.sourceCommit = sourceCommit
        }
        if let expected = audit.sourceFingerprint, expected != sourceFingerprint {
            failures.append("\(label) engine/Metal source fingerprint differs from the release evidence set")
        } else if audit.sourceFingerprint == nil {
            audit.sourceFingerprint = sourceFingerprint
        }
        if let expected = audit.binaryEngineSourceFingerprint,
           expected != binaryEngineSourceFingerprint {
            failures.append("\(label) embedded binary source fingerprint differs from the release evidence set")
        } else if audit.binaryEngineSourceFingerprint == nil {
            audit.binaryEngineSourceFingerprint = binaryEngineSourceFingerprint
        }
        if let expected = audit.regressionExecutableSHA256,
           expected != regressionExecutableSHA256 {
            failures.append("\(label) was produced by a different PanoLumeRegression executable")
        } else if audit.regressionExecutableSHA256 == nil {
            audit.regressionExecutableSHA256 = regressionExecutableSHA256
        }
        if !oracleIdentity.isEmpty {
            if let expected = audit.oracleIdentity, expected != oracleIdentity {
                failures.append("\(label) Python oracle identity differs from the release evidence set")
            } else if audit.oracleIdentity == nil {
                audit.oracleIdentity = oracleIdentity
            }
        }
        if let expectedMetal = audit.metalDylibSHA256, expectedMetal != metalDylibSHA256 {
            failures.append("\(label) Metal dylib hash differs from the release evidence set")
        } else if audit.metalDylibSHA256 == nil, !metalDylibSHA256.isEmpty {
            audit.metalDylibSHA256 = metalDylibSHA256
        }
        audit.artifactCount += 1
    }

    static func recomputeProvenanceFingerprint(_ provenance: JSONValue) throws -> String {
        guard case .object(let inputValues) = provenance["input_sha256"],
              let sourceCommit = provenance["source_commit"]?.stringValue,
              let sourceFingerprint = provenance["source_fingerprint"]?.stringValue,
              let binaryEngineSourceFingerprint = provenance["binary_engine_source_fingerprint"]?.stringValue,
              let regressionExecutableSHA256 = provenance["regression_executable_sha256"]?.stringValue,
              let worktreeClean = provenance["worktree_clean"]?.boolValue,
              let configurationSHA256 = provenance["configuration_sha256"]?.stringValue,
              let toolVersion = provenance["tool_version"]?.stringValue else {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "incomplete provenance fingerprint payload"]
            )
        }
        var inputSHA256: [String: String] = [:]
        for (path, value) in inputValues {
            guard let digest = value.stringValue else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "non-string input digest in provenance"]
                )
            }
            inputSHA256[path] = digest
        }
        let object: [String: Any] = [
            "schema_version": Int(provenance["schema_version"]?.numberValue ?? 0),
            "source_commit": sourceCommit,
            "source_fingerprint": sourceFingerprint,
            "binary_engine_source_fingerprint": binaryEngineSourceFingerprint,
            "regression_executable_sha256": regressionExecutableSHA256,
            "certified_source_fingerprint": provenance["certified_source_fingerprint"]?.stringValue ?? NSNull(),
            "worktree_clean": worktreeClean,
            "input_sha256": inputSHA256,
            "configuration_sha256": configurationSHA256,
            "metal_dylib_sha256": provenance["metal_dylib_sha256"]?.stringValue ?? NSNull(),
            "metal_api_version": provenance["metal_api_version"]?.numberValue.map { Int($0) } ?? NSNull(),
            "oracle_identity": provenance["oracle_identity"]?.stringValue ?? NSNull(),
            "oracle_worktree_clean": provenance["oracle_worktree_clean"]?.boolValue ?? NSNull(),
            "tool_version": toolVersion,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return sha256Hex(data)
    }

    static func validateSuiteCaseProvenance(
        _ suite: JSONValue?,
        label: String,
        minimumCount: Int,
        audit: inout ReleaseProvenanceAudit,
        failures: inout [String]
    ) {
        let cases = suite?["cases"]?.arrayValue ?? []
        if cases.count < minimumCount {
            failures.append("\(label) does not contain \(minimumCount) case records")
            return
        }
        for entry in cases {
            guard let path = entry["report_path"]?.stringValue else {
                failures.append("\(label) case \(entry["id"]?.stringValue ?? "unknown") lacks a report path")
                continue
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let report = readReleaseArtifact(url, label: "\(label) case", failures: &failures)
            if report?["passed"]?.boolValue != true {
                failures.append("\(label) case report is not passing at \(url.path)")
            }
            validateReleaseProvenance(
                report,
                url: url,
                label: "\(label) case",
                requiresOracle: true,
                audit: &audit,
                failures: &failures
            )
        }
    }

    static func readReleaseArtifact(
        _ url: URL?,
        label: String,
        failures: inout [String]
    ) -> JSONValue? {
        guard let url else {
            failures.append("release validation is missing \(label)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            failures.append("release validation cannot find \(label) at \(url.path)")
            return nil
        }
        do {
            return try readJSONValue(url)
        } catch {
            failures.append("release validation cannot parse \(label) at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    static func suiteCaseReportURLs(_ suite: JSONValue?) -> [URL] {
        (suite?["cases"]?.arrayValue ?? []).compactMap { entry in
            entry["report_path"]?.stringValue.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        }
    }

    static func validateExportReleaseEvidence(
        _ suiteURL: URL?,
        label: String,
        expectedRenderer: String,
        provenanceAudit: inout ReleaseProvenanceAudit,
        failures: inout [String]
    ) -> ExportReleaseEvidence {
        guard let suite = readReleaseArtifact(suiteURL, label: label, failures: &failures) else {
            return ExportReleaseEvidence(allPassed: false, seamQuality: false, bitDepth: false, exportCorrectness: false, memoryUse: false)
        }
        validateReleaseProvenance(
            suite,
            url: suiteURL,
            label: label,
            requiresOracle: true,
            audit: &provenanceAudit,
            failures: &failures
        )
        var allPassed = suite["passed"]?.boolValue == true
        var seamQuality = true
        var bitDepth = suite["bit_depth"]?.numberValue == 16
        var exportCorrectness = true
        var memoryUse = true
        if suite["renderer"]?.stringValue != expectedRenderer {
            allPassed = false
            exportCorrectness = false
            failures.append("\(label) renderer is \(suite["renderer"]?.stringValue ?? "missing"), expected \(expectedRenderer)")
        }
        if (suite["selected_count"]?.numberValue ?? 0) < 24 {
            allPassed = false
            exportCorrectness = false
            failures.append("\(label) must cover all 24 full-resolution export cases")
        }
        let cases = suite["cases"]?.arrayValue ?? []
        if cases.count < 24 {
            allPassed = false
            exportCorrectness = false
            failures.append("\(label) case list is incomplete")
        }
        for entry in cases {
            let id = entry["id"]?.stringValue ?? "unknown"
            let status = entry["status"]?.stringValue ?? "missing"
            guard status == "passed" || status == "skipped_existing_pass",
                  let path = entry["report_path"]?.stringValue else {
                allPassed = false
                exportCorrectness = false
                failures.append("\(label) case \(id) did not pass")
                continue
            }
            let reportURL = URL(fileURLWithPath: path).standardizedFileURL
            guard let report = readReleaseArtifact(reportURL, label: "\(label) case \(id)", failures: &failures) else {
                allPassed = false
                exportCorrectness = false
                seamQuality = false
                bitDepth = false
                memoryUse = false
                continue
            }
            validateReleaseProvenance(
                report,
                url: reportURL,
                label: "\(label) case \(id)",
                requiresOracle: true,
                audit: &provenanceAudit,
                failures: &failures
            )
            if report["passed"]?.boolValue != true {
                allPassed = false
                exportCorrectness = false
                failures.append("\(label) case \(id) report is not passing")
            }
            let candidateBitDepth = report["native_vs_python_rgb"]?["candidate"]?["bit_depth"]?.numberValue
            if candidateBitDepth != 16 {
                bitDepth = false
                failures.append("\(label) case \(id) did not produce 16-bit native RGB TIFF")
            }
            guard let profile = report["native_export_profile"] else {
                allPassed = false
                exportCorrectness = false
                seamQuality = false
                memoryUse = false
                failures.append("\(label) case \(id) lacks native export profile")
                continue
            }
            if profile["renderer_used"]?.stringValue != expectedRenderer {
                allPassed = false
                exportCorrectness = false
                failures.append("\(label) case \(id) used \(profile["renderer_used"]?.stringValue ?? "missing"), expected \(expectedRenderer)")
            }
            if expectedRenderer == "metal_quality", profile["cpu_fallback"]?.boolValue != false {
                allPassed = false
                exportCorrectness = false
                failures.append("\(label) case \(id) fell back from Metal Quality")
            }
            if expectedRenderer == "cpu" {
                let overlapPixels = profile["overlap_pixels"]?.numberValue ?? 0
                let meanOverlap = profile["mean_overlap_absdiff"]?.numberValue ?? .infinity
                let maxOverlap = profile["max_overlap_absdiff"]?.numberValue ?? .infinity
                if overlapPixels < 1_000_000 || meanOverlap > 0.04 || maxOverlap > 1.0 {
                    seamQuality = false
                    failures.append("\(label) case \(id) failed overlap seam limits")
                }
            }
            let inputCount = report["input_paths"]?.arrayValue?.count ?? 0
            let memoryLimit: Double = inputCount <= 3 ? 8_000 : (inputCount == 4 ? 9_000 : 12_000)
            let peakMemory = profile["peak_memory_mb"]?.numberValue ?? .infinity
            if peakMemory > memoryLimit {
                memoryUse = false
                failures.append("\(label) case \(id) peak memory \(peakMemory) MB exceeds \(memoryLimit) MB")
            }
            guard let outputPath = report["native_export_path"]?.stringValue,
                  FileManager.default.fileExists(atPath: outputPath),
                  !FileManager.default.fileExists(atPath: outputPath + ".panolume-partial") else {
                exportCorrectness = false
                failures.append("\(label) case \(id) did not leave one complete published TIFF")
                continue
            }
        }
        return ExportReleaseEvidence(
            allPassed: allPassed,
            seamQuality: seamQuality,
            bitDepth: bitDepth,
            exportCorrectness: exportCorrectness,
            memoryUse: memoryUse
        )
    }

    static func parsePreviewParitySuiteOptions(_ arguments: [String]) throws -> PreviewParitySuiteOptions {
        var options = PreviewParitySuiteOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite requires a path after --output-dir"])
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--case":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite requires a value after --case"])
                }
                options.caseFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--settings":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite requires a value after --settings"])
                }
                options.settingsFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--order":
                index += 1
                guard index < arguments.count else {
                    throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite requires a value after --order"])
                }
                options.orderFilters.formUnion(splitCommaSeparated(arguments[index]))
            case "--resume":
                options.resume = true
            case "--reuse-python-oracle":
                options.reusePythonOracle = true
            default:
                throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown parity run-suite argument: \(argument)"])
            }
            index += 1
        }
        let allowedSettings = Set(["ui-default", "camera"])
        let invalidSettings = options.settingsFilters.subtracting(allowedSettings)
        if !invalidSettings.isEmpty {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite --settings must contain only ui-default or camera"])
        }
        let allowedOrders = Set(["original", "sorted", "reverse"])
        let invalidOrders = options.orderFilters.subtracting(allowedOrders)
        if !invalidOrders.isEmpty {
            throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "parity run-suite --order must contain only original, sorted, or reverse"])
        }
        return options
    }

    static func splitCommaSeparated(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func previewParityReportURL(
        outputDirectory: URL,
        caseID: String,
        settingsMode: String,
        orderMode: String
    ) -> URL {
        outputDirectory
            .appendingPathComponent(sanitizeFilename(caseID), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(settingsMode), isDirectory: true)
            .appendingPathComponent(sanitizeFilename(orderMode), isDirectory: true)
            .appendingPathComponent("report.json")
    }

    static func existingPreviewParityPassed(
        _ reportURL: URL,
        expectedFingerprint: String
    ) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: reportURL.path) else {
            return nil
        }
        let report = try readJSONValue(reportURL)
        let passed = report["passed"]?.boolValue ?? false
        let fingerprint = report["provenance"]?["fingerprint"]?.stringValue
        let clean = report["provenance"]?["worktree_clean"]?.boolValue ?? false
        return passed && clean && fingerprint == expectedFingerprint
    }

    static func runPythonOracle(
        paths: [URL],
        settings: StitchSettings,
        outputDirectory: URL,
        exportTIFF: URL? = nil,
        exportSettings: ExportSettings? = nil,
        cameraParamsJSON: URL? = nil,
        reuseExisting: Bool = false
    ) throws -> URL {
        let root = try pythonOracleRoot(required: true)
        let python = try pythonExecutable(required: true)
        let currentOracleIdentity = try pythonOracleIdentityFingerprint(root: root, python: python)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let reportURL = outputDirectory.appendingPathComponent("report.json")
        let identityURL = outputDirectory.appendingPathComponent("oracle-identity.json")
        let reusableIdentity = (try? Data(contentsOf: identityURL)).flatMap {
            try? JSONDecoder().decode(OracleReuseIdentity.self, from: $0)
        }
        if reuseExisting,
           FileManager.default.fileExists(atPath: reportURL.path),
           FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("panorama.png").path),
           exportTIFF == nil,
           cameraParamsJSON == nil,
           reusableIdentity?.schemaVersion == 1,
           reusableIdentity?.oracleIdentity == currentOracleIdentity {
            return reportURL
        }
        let script = root.appendingPathComponent("scripts/diagnose_stitch.py")
        var arguments = [script.path]
        arguments.append(contentsOf: paths.map(\.path))
        arguments.append(contentsOf: [
            "--mode", settings.alignmentMode,
            "--projection", settings.projection,
            "--blend", settings.blendMode == "multiband" ? "multiband" : "feather",
            "--astro-geometry", settings.astroGeometry,
            "--star-threshold", String(settings.starThreshold),
            "--max-stars", String(settings.maxMatchStars),
            "--coverage-multiplier", String(settings.starCoverageMultiplier),
            "--adaptive-coverage-multiplier", String(settings.starAdaptiveCoverageMultiplier),
            "--pixel-tolerance", String(settings.matchPixelTolerance),
            "--star-transform", settings.starTransformModel,
            "--optimizer-max-iter", String(settings.optimizerMaxIterations),
            "--robust-reprojection-px", String(settings.cameraModelRobustReprojectionPx),
            "--robust-min-pair-inliers", String(settings.cameraModelRobustMinPairInliers),
            "--guided-max-points-per-pair", String(settings.cameraModelGuidedMaxPointsPerPair),
            "--local-search-px", String(settings.cameraModelLocalSearchPx),
            "--local-max-points-per-pair", String(settings.cameraModelLocalMaxPointsPerPair),
            "--texture-max-points-per-pair", String(settings.cameraModelTextureMaxPointsPerPair),
            "--texture-reprojection-px", String(settings.cameraModelTextureReprojectionPx),
            "--out-dir", outputDirectory.path
        ])
        if let exportTIFF {
            let exportSettings = exportSettings ?? ExportSettings(rendererBackend: "cpu", bitDepth: 16)
            arguments.append(contentsOf: [
                "--export-tiff", exportTIFF.path,
                "--export-bit-depth", String(exportSettings.bitDepth),
                "--export-renderer", exportSettings.rendererBackend,
                "--export-stretch-strength", String(exportSettings.applyPreviewStretch ? exportSettings.stretchStrength : 0.0),
                "--export-stretch-black-percentile", String(exportSettings.stretchBlackPercentile),
                "--export-stretch-white-percentile", String(exportSettings.stretchWhitePercentile),
                "--export-stretch-gamma", String(exportSettings.stretchGamma)
            ])
        }
        if let cameraParamsJSON {
            arguments.append(contentsOf: [
                "--override-camera-params-json", cameraParamsJSON.path
            ])
        }
        if settings.previewMaxSide > 0 {
            arguments.append(contentsOf: ["--max-size", String(settings.previewMaxSide)])
        } else {
            arguments.append("--full-resolution")
        }
        if !settings.starAdaptiveCoverage {
            arguments.append("--no-adaptive-coverage")
        }
        if !settings.optimizeFocal {
            arguments.append("--no-optimize-focal")
        }
        if settings.optimizeDistortion {
            arguments.append("--optimize-distortion")
        }
        if !settings.cameraModelGuidedRefinement {
            arguments.append("--no-guided-refinement")
        }
        if !settings.cameraModelLocalRefinement {
            arguments.append("--no-local-refinement")
        }
        if !settings.cameraModelTextureRefinement {
            arguments.append("--no-texture-refinement")
        }
        if !settings.displayStretch {
            arguments.append("--no-display-stretch")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = RuntimeEnvironment.normalized()
        let pythonPath = root.appendingPathComponent("src").path
        if let existing = environment["PYTHONPATH"], !existing.isEmpty {
            environment["PYTHONPATH"] = "\(pythonPath):\(existing)"
        } else {
            environment["PYTHONPATH"] = pythonPath
        }
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        try stdoutData.write(to: outputDirectory.appendingPathComponent("python_stdout.txt"))
        try stderrData.write(to: outputDirectory.appendingPathComponent("python_stderr.txt"))
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(domain: "PanoLumeRegression", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Python oracle failed: \(stderrText)"])
        }
        try writeJSON(
            OracleReuseIdentity(schemaVersion: 1, oracleIdentity: currentOracleIdentity),
            to: identityURL
        )
        return reportURL
    }

    static func repositoryRoot() throws -> URL {
        let environment = RuntimeEnvironment.normalized()
        if let configured = environment["PANOLUME_REPOSITORY_ROOT"], !configured.isEmpty {
            let root = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("macos/PanoLume/Package.swift").path
            ) || FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "PANOLUME_REPOSITORY_ROOT is not a PanoLume checkout: \(root.path)"]
                )
            }
            return root
        }

        var starts = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL,
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL,
        ]
        if let executable = Bundle.main.executableURL {
            starts.append(executable.deletingLastPathComponent().standardizedFileURL)
        }
        var packageFallback: URL?
        for start in starts {
            var current = start
            for _ in 0..<16 {
                if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                    return current
                }
                if FileManager.default.fileExists(
                    atPath: current.appendingPathComponent("macos/PanoLume/Package.swift").path
                ) {
                    packageFallback = packageFallback ?? current
                }
                let directPackage = current.appendingPathComponent("Package.swift")
                let directSources = current.appendingPathComponent("Sources/PanoLumeCore", isDirectory: true)
                if FileManager.default.fileExists(atPath: directPackage.path),
                   FileManager.default.fileExists(atPath: directSources.path) {
                    let possibleRepository = current.deletingLastPathComponent().deletingLastPathComponent()
                    if FileManager.default.fileExists(
                        atPath: possibleRepository.appendingPathComponent("native/metal_renderer/PanoLumeMetalRenderer.mm").path
                    ) {
                        packageFallback = packageFallback ?? possibleRepository
                    }
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        if let packageFallback {
            return packageFallback
        }
        throw NSError(
            domain: "PanoLumeRegression",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repository root from the working directory, executable, or compiled source path. Set PANOLUME_REPOSITORY_ROOT."]
        )
    }

    static func pythonOracleRoot(required: Bool) throws -> URL {
        let environment = RuntimeEnvironment.normalized()
        let explicit = oracleOverrides.root
            ?? (environment["PANOLUME_PYTHON_ORACLE_ROOT"] ?? environment["PANOLUME_ORACLE_ROOT"]).map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        if let explicit {
            let script = explicit.appendingPathComponent("scripts/diagnose_stitch.py")
            guard FileManager.default.fileExists(atPath: script.path) else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Python oracle root does not contain scripts/diagnose_stitch.py: \(explicit.path)"]
                )
            }
            return explicit
        }
        let root = try repositoryRoot()
        let candidates = [
            root,
            root.appendingPathComponent("legacy/python", isDirectory: true),
        ]
        if let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/diagnose_stitch.py").path)
        }) {
            return found
        }
        if required {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Python oracle is unavailable. Pass --oracle-root or set PANOLUME_PYTHON_ORACLE_ROOT (PANOLUME_ORACLE_ROOT is also accepted)."]
            )
        }
        return root
    }

    static func pythonExecutable(required: Bool) throws -> URL {
        let environment = RuntimeEnvironment.normalized()
        let explicit = oracleOverrides.pythonExecutable ?? environment["PANOLUME_PYTHON_EXECUTABLE"]
        if let explicit, !explicit.isEmpty {
            if let resolved = resolveExecutable(explicit) {
                return resolved
            }
            throw NSError(
                domain: "PanoLumeRegression",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Configured Python executable is not executable or was not found on PATH: \(explicit)"]
            )
        }
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/Caskroom/miniconda/base/envs/panolume/bin/python"),
            URL(fileURLWithPath: "/usr/bin/python3"),
            resolveExecutable("python3"),
        ].compactMap { $0 }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        if required {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Python executable is unavailable. Pass --python-executable or set PANOLUME_PYTHON_EXECUTABLE."]
            )
        }
        return candidates.first ?? URL(fileURLWithPath: "/usr/bin/python3")
    }

    static func resolveExecutable(_ value: String) -> URL? {
        if value.contains("/") {
            let url = URL(fileURLWithPath: value).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let path = RuntimeEnvironment.normalized()["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let root = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
            let candidate = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(value)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    static func executableVersion(_ executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func pythonOracleScriptDigest(root: URL) throws -> String {
        let scripts = [
            root.appendingPathComponent("scripts/diagnose_stitch.py"),
            root.appendingPathComponent("scripts/compare_rgb_tiff.py"),
            root.appendingPathComponent("scripts/compare_raw_decode.py"),
        ]
        guard scripts.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Python oracle is missing one or more required regression scripts at \(root.path)"]
            )
        }
        let entries = try scripts
            .map { "\($0.lastPathComponent):\(try sha256File($0))" }
            .sorted()
            .joined(separator: "\n")
        return sha256Hex(Data(entries.utf8))
    }

    static func pythonOracleCommit(root: URL) -> String? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return nil
        }
        return try? gitOutput(["rev-parse", "HEAD"], root: root)
    }

    static func validatePythonOracleWorktree(root: URL) throws {
        let topLevel = try? gitOutput(["rev-parse", "--show-toplevel"], root: root)
        let status = try? gitOutput(
            ["status", "--porcelain", "--untracked-files=all"],
            root: root
        )
        try OracleWorktreeBindingValidator.validate(
            oracleRootPath: root.path,
            gitTopLevelPath: topLevel,
            porcelainStatus: status
        )
    }

    static func pythonOracleIdentityFingerprint(root: URL, python: URL) throws -> String {
        try validatePythonOracleWorktree(root: root)
        guard let oracleCommit = pythonOracleCommit(root: root),
              isLowercaseHex(oracleCommit, count: 40) else {
            throw NSError(
                domain: "PanoLumeRegression",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Certification evidence refused: the Python oracle worktree HEAD commit is unavailable or malformed."
                ]
            )
        }
        let object: [String: Any] = [
            "oracle_commit": oracleCommit,
            "oracle_scripts_sha256": try pythonOracleScriptDigest(root: root),
            "oracle_worktree_clean": true,
            "python_executable_sha256": try sha256File(python),
            "python_version": executableVersion(python) ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return sha256Hex(data)
    }

    static func requirePixels(_ pixels: PixelBufferInfo?, label: String) throws -> PixelBufferInfo {
        guard let pixels, pixels.width > 0, pixels.height > 0, !pixels.data.isEmpty else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(label) did not return preview pixels"])
        }
        return pixels
    }

    static func savePNG(_ pixels: PixelBufferInfo, to url: URL) throws {
        guard let provider = CGDataProvider(data: pixels.data as CFData),
              let image = CGImage(
                width: pixels.width,
                height: pixels.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to create PNG at \(url.path)"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to finalize PNG at \(url.path)"])
        }
    }

    static func loadPNG(_ url: URL) throws -> PixelBufferInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to load PNG at \(url.path)"])
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to decode PNG at \(url.path)"])
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    static func compareTIFFRGBImages(
        baselineURL: URL,
        candidateURL: URL,
        reportURL: URL,
        diffURL: URL
    ) throws -> TIFFRGBParityMetrics {
        let root = try pythonOracleRoot(required: true)
        let python = try pythonExecutable(required: true)
        let script = root.appendingPathComponent("scripts/compare_rgb_tiff.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "16-bit TIFF comparator is missing at \(script.path)"])
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [
            script.path,
            baselineURL.path,
            candidateURL.path,
            "--output-json", reportURL.path,
            "--diff", diffURL.path
        ]
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        try stdoutData.write(to: reportURL.deletingLastPathComponent().appendingPathComponent("tiff_comparator_stdout.txt"))
        try stderrData.write(to: reportURL.deletingLastPathComponent().appendingPathComponent("tiff_comparator_stderr.txt"))
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(domain: "PanoLumeRegression", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "16-bit TIFF comparator failed: \(stderrText)"])
        }
        let data = try Data(contentsOf: reportURL)
        do {
            return try JSONDecoder().decode(TIFFRGBParityMetrics.self, from: data)
        } catch {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to decode TIFF RGB report at \(reportURL.path): \(error.localizedDescription)"])
        }
    }

    static func runRawDecodeComparator(
        rawURL: URL,
        nativeBufferURL: URL,
        width: Int,
        height: Int,
        halfSize: Bool,
        reportURL: URL,
        diffURL: URL
    ) throws -> RawDecodeComparatorReport {
        let root = try pythonOracleRoot(required: true)
        let python = try pythonExecutable(required: true)
        let script = root.appendingPathComponent("scripts/compare_raw_decode.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "RAW decode comparator is missing at \(script.path)"])
        }
        var arguments = [
            script.path,
            rawURL.path,
            nativeBufferURL.path,
            "--width", String(width),
            "--height", String(height),
            "--output-json", reportURL.path,
            "--diff", diffURL.path
        ]
        if halfSize {
            arguments.append("--half-size")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        try stdoutData.write(to: reportURL.deletingLastPathComponent().appendingPathComponent("raw_decode_comparator_stdout.txt"))
        try stderrData.write(to: reportURL.deletingLastPathComponent().appendingPathComponent("raw_decode_comparator_stderr.txt"))
        guard process.terminationStatus == 0 || process.terminationStatus == 3 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(domain: "PanoLumeRegression", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "RAW decode comparator failed: \(stderrText)"])
        }
        let data = try Data(contentsOf: reportURL)
        do {
            return try JSONDecoder().decode(RawDecodeComparatorReport.self, from: data)
        } catch {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to decode RAW comparator report at \(reportURL.path): \(error.localizedDescription)"])
        }
    }

    static func compareStandardImageReference(
        referenceURL: URL,
        candidateURL: URL,
        alignedReferenceURL: URL,
        diffURL: URL
    ) throws -> (metrics: VisualParityMetrics, registration: SimilarityRegistrationResult) {
        let reference = try loadPNG(referenceURL)
        let candidate = try loadPNG(candidateURL)
        let registration = SimilarityRegistrar.register(
            reference: reference,
            candidate: candidate
        )
        let aligned = SimilarityRegistrar.warpReference(
            reference,
            transform: registration.transform,
            canvasWidth: candidate.width,
            canvasHeight: candidate.height
        )
        try savePNG(aligned, to: alignedReferenceURL)
        let metrics = try comparePreviewImages(
            baselineURL: alignedReferenceURL,
            candidateURL: candidateURL,
            diffURL: diffURL
        )
        return (metrics, registration)
    }

    static func comparePreviewImages(
        baselineURL: URL,
        candidateURL: URL,
        diffURL: URL
    ) throws -> VisualParityMetrics {
        let baseline = try loadPNG(baselineURL)
        let originalCandidate = try loadPNG(candidateURL)
        let widthDelta = abs(Double(originalCandidate.width - baseline.width)) / Double(max(baseline.width, 1))
        let heightDelta = abs(Double(originalCandidate.height - baseline.height)) / Double(max(baseline.height, 1))
        if originalCandidate.width == baseline.width,
           originalCandidate.height == baseline.height,
           originalCandidate.data == baseline.data {
            var comparedPixels = 0
            var diffData = Data(count: baseline.width * baseline.height * 4)
            for y in 0..<baseline.height {
                for x in 0..<baseline.width {
                    let sourceOffset = y * baseline.bytesPerRow + x * 4
                    let destinationOffset = (y * baseline.width + x) * 4
                    if luminance(
                        baseline.data[sourceOffset],
                        baseline.data[sourceOffset + 1],
                        baseline.data[sourceOffset + 2]
                    ) > 2.0 / 255.0 {
                        comparedPixels += 1
                    }
                    diffData[destinationOffset + 3] = 255
                }
            }
            try savePNG(
                PixelBufferInfo(
                    data: diffData,
                    width: baseline.width,
                    height: baseline.height,
                    bytesPerRow: baseline.width * 4
                ),
                to: diffURL
            )
            return VisualParityMetrics(
                baselineWidth: baseline.width,
                baselineHeight: baseline.height,
                candidateWidth: originalCandidate.width,
                candidateHeight: originalCandidate.height,
                widthDeltaFraction: 0.0,
                heightDeltaFraction: 0.0,
                maskIoU: 1.0,
                maskedSSIM: 1.0,
                maskedMedianAbsDiff: 0.0,
                maskedP95AbsDiff: 0.0,
                comparedPixels: comparedPixels,
                alignmentMode: "identity",
                alignmentOffsetX: 0,
                alignmentOffsetY: 0,
                diffPath: diffURL.path
            )
        }
        let candidate: PixelBufferInfo
        let alignmentMode: String
        let alignmentOffsetX: Int
        let alignmentOffsetY: Int
        if widthDelta <= 0.02 && heightDelta <= 0.02 {
            let aligned = alignCandidateToBaseline(
                baseline: baseline,
                candidate: originalCandidate,
                maxShift: 8
            )
            candidate = aligned.pixels
            alignmentMode = aligned.mode
            alignmentOffsetX = aligned.offsetX
            alignmentOffsetY = aligned.offsetY
        } else {
            candidate = resizeNearest(originalCandidate, width: baseline.width, height: baseline.height)
            alignmentMode = "dimension_failure_nearest"
            alignmentOffsetX = 0
            alignmentOffsetY = 0
        }
        var intersection = 0
        var union = 0
        var compared = 0
        var diffs: [Double] = []
        var baseValues: [Double] = []
        var candidateValues: [Double] = []
        var diffData = Data(count: baseline.width * baseline.height * 4)
        let count = baseline.width * baseline.height
        for pixel in 0..<count {
            let offset = pixel * 4
            let baseLum = luminance(baseline.data[offset], baseline.data[offset + 1], baseline.data[offset + 2])
            let candLum = luminance(candidate.data[offset], candidate.data[offset + 1], candidate.data[offset + 2])
            let baseMask = baseLum > 2.0 / 255.0
            let candMask = candLum > 2.0 / 255.0
            if baseMask || candMask {
                union += 1
            }
            if baseMask && candMask {
                intersection += 1
                compared += 1
                let diff = abs(baseLum - candLum)
                diffs.append(diff)
                baseValues.append(baseLum)
                candidateValues.append(candLum)
            }
            let rDiff = abs(Int(baseline.data[offset]) - Int(candidate.data[offset]))
            let gDiff = abs(Int(baseline.data[offset + 1]) - Int(candidate.data[offset + 1]))
            let bDiff = abs(Int(baseline.data[offset + 2]) - Int(candidate.data[offset + 2]))
            diffData[offset] = UInt8(min(255, rDiff * 4))
            diffData[offset + 1] = UInt8(min(255, gDiff * 4))
            diffData[offset + 2] = UInt8(min(255, bDiff * 4))
            diffData[offset + 3] = 255
        }
        try savePNG(PixelBufferInfo(data: diffData, width: baseline.width, height: baseline.height, bytesPerRow: baseline.width * 4), to: diffURL)
        diffs.sort()
        let median = percentile(sorted: diffs, fraction: 0.50)
        let p95 = percentile(sorted: diffs, fraction: 0.95)
        return VisualParityMetrics(
            baselineWidth: baseline.width,
            baselineHeight: baseline.height,
            candidateWidth: originalCandidate.width,
            candidateHeight: originalCandidate.height,
            widthDeltaFraction: widthDelta,
            heightDeltaFraction: heightDelta,
            maskIoU: union > 0 ? Double(intersection) / Double(union) : 0.0,
            maskedSSIM: globalSSIM(baseValues, candidateValues),
            maskedMedianAbsDiff: median,
            maskedP95AbsDiff: p95,
            comparedPixels: compared,
            alignmentMode: alignmentMode,
            alignmentOffsetX: alignmentOffsetX,
            alignmentOffsetY: alignmentOffsetY,
            diffPath: diffURL.path
        )
    }

    static func alignCandidateToBaseline(
        baseline: PixelBufferInfo,
        candidate: PixelBufferInfo,
        maxShift: Int
    ) -> (pixels: PixelBufferInfo, mode: String, offsetX: Int, offsetY: Int) {
        let sampleStride = max(1, max(baseline.width, baseline.height) / 128)
        var bestScore = -Double.infinity
        var bestOffsetX = 0
        var bestOffsetY = 0
        for offsetY in (-maxShift)...maxShift {
            for offsetX in (-maxShift)...maxShift {
                let score = sampledAlignmentScore(
                    baseline: baseline,
                    candidate: candidate,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    sampleStride: sampleStride
                )
                let currentDistance = abs(offsetX) + abs(offsetY)
                let bestDistance = abs(bestOffsetX) + abs(bestOffsetY)
                if score > bestScore + 1e-12
                    || (abs(score - bestScore) <= 1e-12 && currentDistance < bestDistance) {
                    bestScore = score
                    bestOffsetX = offsetX
                    bestOffsetY = offsetY
                }
            }
        }

        var data = Data(count: baseline.width * baseline.height * 4)
        for y in 0..<baseline.height {
            let sourceY = y + bestOffsetY
            for x in 0..<baseline.width {
                let sourceX = x + bestOffsetX
                let destinationOffset = (y * baseline.width + x) * 4
                if sourceX >= 0 && sourceX < candidate.width
                    && sourceY >= 0 && sourceY < candidate.height {
                    let sourceOffset = sourceY * candidate.bytesPerRow + sourceX * 4
                    data[destinationOffset] = candidate.data[sourceOffset]
                    data[destinationOffset + 1] = candidate.data[sourceOffset + 1]
                    data[destinationOffset + 2] = candidate.data[sourceOffset + 2]
                    data[destinationOffset + 3] = candidate.data[sourceOffset + 3]
                } else {
                    data[destinationOffset + 3] = 255
                }
            }
        }
        let translated = PixelBufferInfo(
            data: data,
            width: baseline.width,
            height: baseline.height,
            bytesPerRow: baseline.width * 4
        )
        let scaled = resizeBilinear(candidate, width: baseline.width, height: baseline.height)
        let scaledScore = sampledAlignmentScore(
            baseline: baseline,
            candidate: scaled,
            offsetX: 0,
            offsetY: 0,
            sampleStride: sampleStride
        )
        if scaledScore > bestScore {
            return (scaled, "bilinear_scale", 0, 0)
        }
        return (translated, "integer_translation", bestOffsetX, bestOffsetY)
    }

    static func sampledAlignmentScore(
        baseline: PixelBufferInfo,
        candidate: PixelBufferInfo,
        offsetX: Int,
        offsetY: Int,
        sampleStride: Int
    ) -> Double {
        var intersection = 0
        var union = 0
        var sumBase = 0.0
        var sumCandidate = 0.0
        var sumBaseSquared = 0.0
        var sumCandidateSquared = 0.0
        var sumProduct = 0.0
        for y in stride(from: 0, to: baseline.height, by: sampleStride) {
            let sourceY = y + offsetY
            for x in stride(from: 0, to: baseline.width, by: sampleStride) {
                let baseOffset = y * baseline.bytesPerRow + x * 4
                let baseLum = luminance(
                    baseline.data[baseOffset],
                    baseline.data[baseOffset + 1],
                    baseline.data[baseOffset + 2]
                )
                let sourceX = x + offsetX
                let candidateLum: Double
                if sourceX >= 0 && sourceX < candidate.width
                    && sourceY >= 0 && sourceY < candidate.height {
                    let sourceOffset = sourceY * candidate.bytesPerRow + sourceX * 4
                    candidateLum = luminance(
                        candidate.data[sourceOffset],
                        candidate.data[sourceOffset + 1],
                        candidate.data[sourceOffset + 2]
                    )
                } else {
                    candidateLum = 0.0
                }
                let baseMask = baseLum > 2.0 / 255.0
                let candidateMask = candidateLum > 2.0 / 255.0
                if baseMask || candidateMask { union += 1 }
                if baseMask && candidateMask {
                    intersection += 1
                    sumBase += baseLum
                    sumCandidate += candidateLum
                    sumBaseSquared += baseLum * baseLum
                    sumCandidateSquared += candidateLum * candidateLum
                    sumProduct += baseLum * candidateLum
                }
            }
        }
        guard intersection > 1, union > 0 else { return -Double.infinity }
        let n = Double(intersection)
        let meanBase = sumBase / n
        let meanCandidate = sumCandidate / n
        let denominator = max(1.0, n - 1.0)
        let varianceBase = max(0.0, (sumBaseSquared - n * meanBase * meanBase) / denominator)
        let varianceCandidate = max(0.0, (sumCandidateSquared - n * meanCandidate * meanCandidate) / denominator)
        let covariance = (sumProduct - n * meanBase * meanCandidate) / denominator
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        let sampledSSIM = ((2.0 * meanBase * meanCandidate + c1) * (2.0 * covariance + c2))
            / ((meanBase * meanBase + meanCandidate * meanCandidate + c1)
                * (varianceBase + varianceCandidate + c2))
        return sampledSSIM * Double(intersection) / Double(union)
    }

    static func resizeBilinear(_ pixels: PixelBufferInfo, width: Int, height: Int) -> PixelBufferInfo {
        var data = Data(count: width * height * 4)
        let scaleX = Double(pixels.width) / Double(width)
        let scaleY = Double(pixels.height) / Double(height)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * scaleY - 0.5
            let y0 = min(pixels.height - 1, max(0, Int(floor(sourceY))))
            let y1 = min(pixels.height - 1, y0 + 1)
            let wy = min(1.0, max(0.0, sourceY - Double(y0)))
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * scaleX - 0.5
                let x0 = min(pixels.width - 1, max(0, Int(floor(sourceX))))
                let x1 = min(pixels.width - 1, x0 + 1)
                let wx = min(1.0, max(0.0, sourceX - Double(x0)))
                let destinationOffset = (y * width + x) * 4
                for channel in 0..<4 {
                    let p00 = Double(pixels.data[y0 * pixels.bytesPerRow + x0 * 4 + channel])
                    let p10 = Double(pixels.data[y0 * pixels.bytesPerRow + x1 * 4 + channel])
                    let p01 = Double(pixels.data[y1 * pixels.bytesPerRow + x0 * 4 + channel])
                    let p11 = Double(pixels.data[y1 * pixels.bytesPerRow + x1 * 4 + channel])
                    let top = p00 * (1.0 - wx) + p10 * wx
                    let bottom = p01 * (1.0 - wx) + p11 * wx
                    data[destinationOffset + channel] = UInt8(
                        min(255.0, max(0.0, (top * (1.0 - wy) + bottom * wy).rounded()))
                    )
                }
            }
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    static func resizeNearest(_ pixels: PixelBufferInfo, width: Int, height: Int) -> PixelBufferInfo {
        var data = Data(count: width * height * 4)
        for y in 0..<height {
            let sy = min(pixels.height - 1, max(0, Int((Double(y) + 0.5) * Double(pixels.height) / Double(height))))
            for x in 0..<width {
                let sx = min(pixels.width - 1, max(0, Int((Double(x) + 0.5) * Double(pixels.width) / Double(width))))
                let src = sy * pixels.bytesPerRow + sx * 4
                let dst = (y * width + x) * 4
                data[dst] = pixels.data[src]
                data[dst + 1] = pixels.data[src + 1]
                data[dst + 2] = pixels.data[src + 2]
                data[dst + 3] = pixels.data[src + 3]
            }
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
    }

    static func percentile(sorted values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else {
            return 1.0
        }
        let clipped = min(1.0, max(0.0, fraction))
        let position = Double(values.count - 1) * clipped
        let lower = min(values.count - 1, max(0, Int(floor(position))))
        let upper = min(values.count - 1, max(0, Int(ceil(position))))
        if lower == upper {
            return values[lower]
        }
        let alpha = position - Double(lower)
        return values[lower] * (1.0 - alpha) + values[upper] * alpha
    }

    static func globalSSIM(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0.0
        }
        let n = Double(lhs.count)
        let meanL = lhs.reduce(0.0, +) / n
        let meanR = rhs.reduce(0.0, +) / n
        var varL = 0.0
        var varR = 0.0
        var cov = 0.0
        for index in lhs.indices {
            let dl = lhs[index] - meanL
            let dr = rhs[index] - meanR
            varL += dl * dl
            varR += dr * dr
            cov += dl * dr
        }
        let denom = max(1.0, n - 1.0)
        varL /= denom
        varR /= denom
        cov /= denom
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        return ((2.0 * meanL * meanR + c1) * (2.0 * cov + c2))
            / ((meanL * meanL + meanR * meanR + c1) * (varL + varR + c2))
    }

    static func previewStatusFailures(prefix: String, summary: PreviewRunSummary) -> [String] {
        var failures: [String] = []
        if summary.geometry != "camera" {
            failures.append("\(prefix) geometry is \(summary.geometry ?? "missing"), expected camera")
        }
        if summary.previewStatus != "camera_projection_preview" {
            failures.append("\(prefix) preview_status is \(summary.previewStatus ?? "missing"), expected camera_projection_preview")
        }
        return failures
    }

    static func starProjectionParityFailures(prefix: String, baseline: StitchMetrics, candidate: StitchMetrics) -> [String] {
        var failures: [String] = []
        if let count = candidate.highConfidenceStarCount, count <= 0 {
            failures.append("\(prefix) high-confidence star count is zero")
        } else if candidate.highConfidenceStarCount == nil {
            failures.append("\(prefix) high-confidence star count missing")
        }
        if let current = candidate.highConfidenceStarP95 {
            if current > 4.0 {
                failures.append("\(prefix) high-confidence star P95 \(current) exceeds 4.0")
            }
        } else {
            failures.append("\(prefix) high-confidence star P95 missing")
        }
        if let current = candidate.mutualStarP95 {
            if current > 6.0 {
                failures.append("\(prefix) mutual star P95 \(current) exceeds 6.0")
            }
        } else {
            failures.append("\(prefix) mutual star P95 missing")
        }
        return failures
    }

    static func visualParityFailures(
        prefix: String,
        metrics: VisualParityMetrics,
        strictSSIM: Bool = true,
        minimumSSIM: Double = 0.96
    ) -> [String] {
        var failures: [String] = []
        if metrics.widthDeltaFraction > 0.02 || metrics.heightDeltaFraction > 0.02 {
            failures.append("\(prefix) dimension delta exceeds 2%")
        }
        if metrics.maskIoU < 0.92 {
            failures.append("\(prefix) mask IoU \(metrics.maskIoU) below 0.92")
        }
        if strictSSIM && metrics.maskedSSIM < minimumSSIM {
            failures.append("\(prefix) masked SSIM \(metrics.maskedSSIM) below \(minimumSSIM)")
        }
        if metrics.maskedMedianAbsDiff > 0.04 {
            failures.append("\(prefix) masked median absdiff \(metrics.maskedMedianAbsDiff) above 0.04")
        }
        if metrics.maskedP95AbsDiff > 0.15 {
            failures.append("\(prefix) masked P95 absdiff \(metrics.maskedP95AbsDiff) above 0.15")
        }
        return failures
    }

    static func tiffRGBParityFailures(
        prefix: String,
        metrics: TIFFRGBParityMetrics,
        expectedBitDepth: Int
    ) -> [String] {
        var failures: [String] = []
        if metrics.baseline.channels != 3 || metrics.candidate.channels != 3 {
            failures.append("\(prefix) requires 3-channel RGB TIFFs")
        }
        if metrics.baseline.bitDepth != expectedBitDepth || metrics.candidate.bitDepth != expectedBitDepth {
            failures.append("\(prefix) bit depth is python=\(metrics.baseline.bitDepth), native=\(metrics.candidate.bitDepth), expected \(expectedBitDepth)")
        }
        if metrics.widthDeltaFraction > 0.02 || metrics.heightDeltaFraction > 0.02 {
            failures.append("\(prefix) dimension delta exceeds 2%")
        }
        if metrics.maskIoU < 0.92 {
            failures.append("\(prefix) mask IoU \(metrics.maskIoU) below 0.92")
        }
        if metrics.maskedRGBSSIM < 0.96 {
            failures.append("\(prefix) masked RGB SSIM \(metrics.maskedRGBSSIM) below 0.96")
        }
        if metrics.maskedMedianAbsDiff > 0.04 {
            failures.append("\(prefix) masked RGB median absdiff \(metrics.maskedMedianAbsDiff) above 0.04")
        }
        if metrics.maskedP95AbsDiff > 0.15 {
            failures.append("\(prefix) masked RGB P95 absdiff \(metrics.maskedP95AbsDiff) above 0.15")
        }
        for channel in ["red", "green", "blue"] {
            guard let value = metrics.perChannel[channel] else {
                failures.append("\(prefix) \(channel) channel metrics missing")
                continue
            }
            if value.ssim < 0.96 {
                failures.append("\(prefix) \(channel) SSIM \(value.ssim) below 0.96")
            }
            if value.medianAbsDiff > 0.04 {
                failures.append("\(prefix) \(channel) median absdiff \(value.medianAbsDiff) above 0.04")
            }
            if value.p95AbsDiff > 0.15 {
                failures.append("\(prefix) \(channel) P95 absdiff \(value.p95AbsDiff) above 0.15")
            }
        }
        return failures
    }

    static func runManifest(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            fputs("manifest requires a subcommand and manifest.json\n", stderr)
            return 2
        }
        let command = arguments[0]
        do {
            switch command {
            case "validate":
                guard arguments.count == 2 else {
                    fputs("manifest validate requires manifest.json\n", stderr)
                    return 2
                }
                let url = URL(fileURLWithPath: arguments[1])
                let validation = try BaselineManifestHarness.validate(manifestURL: url)
                try printJSON(validation)
                return validation.passed ? 0 : 3
            case "summarize":
                guard arguments.count == 2 else {
                    fputs("manifest summarize requires manifest.json\n", stderr)
                    return 2
                }
                let url = URL(fileURLWithPath: arguments[1])
                let summary = try BaselineManifestHarness.summarize(manifestURL: url)
                try printJSON(summary)
                return summary.validation.passed ? 0 : 3
            case "run-native":
                return try runNativeManifest(arguments: Array(arguments.dropFirst()))
            default:
                fputs("unknown manifest subcommand: \(command)\n", stderr)
                return 2
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func runNativeManifest(arguments: [String]) throws -> Int32 {
        var options = ManifestNativeRunOptions()
        var manifestPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--optimize-distortion":
                options.settings.optimizeDistortion = true
            case "--no-guided-refinement":
                options.settings.cameraModelGuidedRefinement = false
            case "--no-local-refinement":
                options.settings.cameraModelLocalRefinement = false
            case "--no-texture-refinement":
                options.settings.cameraModelTextureRefinement = false
            case "--multiband":
                options.settings.blendMode = "multiband"
            case "--strip-render":
                options.exportSettings = ExportSettings(rendererBackend: "preview_camera_strip_tiff_diagnostic", bitDepth: 16)
            case "--fullres-render":
                options.exportSettings = ExportSettings(rendererBackend: "fullres_camera_strip_tiff_diagnostic", bitDepth: 16)
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    fputs("manifest run-native requires a path after --output-dir\n", stderr)
                    return 2
                }
                options.outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--max-output-side":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("manifest run-native requires an integer after --max-output-side\n", stderr)
                    return 2
                }
                var exportSettings = options.exportSettings ?? ExportSettings(rendererBackend: "fullres_camera_strip_tiff_diagnostic", bitDepth: 16)
                exportSettings.maxOutputSide = value
                options.exportSettings = exportSettings
            case "--max-output-pixels":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("manifest run-native requires an integer after --max-output-pixels\n", stderr)
                    return 2
                }
                var exportSettings = options.exportSettings ?? ExportSettings(rendererBackend: "fullres_camera_strip_tiff_diagnostic", bitDepth: 16)
                exportSettings.maxOutputPixels = value
                options.exportSettings = exportSettings
            case "--preview-max-side":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    fputs("manifest run-native requires an integer after --preview-max-side\n", stderr)
                    return 2
                }
                options.settings.previewMaxSide = value
            case "--allow-unproven-parity":
                options.allowUnprovenParity = true
            default:
                if manifestPath == nil {
                    manifestPath = argument
                } else {
                    fputs("manifest run-native received multiple manifest paths\n", stderr)
                    return 2
                }
            }
            index += 1
        }
        guard let manifestPath else {
            fputs("manifest run-native requires manifest.json\n", stderr)
            return 2
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try BaselineManifestHarness.load(from: manifestURL)
        let validation = try BaselineManifestHarness.validate(manifestURL: manifestURL)
        let validationStatus = Dictionary(uniqueKeysWithValues: validation.cases.map { ($0.id, $0.status) })
        let baseURL = manifestURL.deletingLastPathComponent()
        let outputDirectory = options.outputDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if options.exportSettings != nil {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        var caseRuns: [ManifestNativeCaseRun] = []
        var allFailures: [String] = validation.failures
        for baselineCase in manifest.cases {
            let run = try runNativeManifestCase(
                baselineCase,
                validationStatus: validationStatus[baselineCase.id] ?? "unknown",
                baseURL: baseURL,
                outputDirectory: outputDirectory,
                options: options
            )
            if run.status == "failed" {
                allFailures.append(contentsOf: run.failures.map { "\(run.id): \($0)" })
            }
            caseRuns.append(run)
        }

        let skipped = caseRuns.filter { $0.status == "skipped" }.count
        let failed = caseRuns.filter { $0.status == "failed" }.count
        let runnable = caseRuns.count - skipped
        let report = ManifestNativeRunReport(
            passed: validation.passed && failed == 0,
            manifestName: manifest.name,
            runnableCases: runnable,
            skippedCases: skipped,
            failedCases: failed,
            failures: allFailures,
            cases: caseRuns
        )
        try printJSON(report)
        return report.passed ? 0 : 3
    }

    static func runNativeManifestCase(
        _ baselineCase: BaselineCase,
        validationStatus: String,
        baseURL: URL,
        outputDirectory: URL,
        options: ManifestNativeRunOptions
    ) throws -> ManifestNativeCaseRun {
        if let skipReason = baselineCase.skipReason,
           !skipReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ManifestNativeCaseRun(
                id: baselineCase.id,
                status: "skipped",
                message: skipReason,
                inputPaths: [],
                outputPath: nil,
                metrics: nil,
                diagnostics: nil,
                exportProfile: nil,
                comparison: nil,
                gate: nil,
                failures: []
            )
        }
        guard validationStatus == "runnable" else {
            return ManifestNativeCaseRun(
                id: baselineCase.id,
                status: "failed",
                message: "manifest case is not runnable",
                inputPaths: [],
                outputPath: nil,
                metrics: nil,
                diagnostics: nil,
                exportProfile: nil,
                comparison: nil,
                gate: nil,
                failures: ["manifest case is not runnable"]
            )
        }

        let stitchInputs = baselineCase.inputs
            .filter { $0.kind == .standardImage || $0.kind == .rawImage }
            .map { resolveManifestPath($0.path, relativeTo: baseURL) }
        guard stitchInputs.count >= 2 else {
            return ManifestNativeCaseRun(
                id: baselineCase.id,
                status: "skipped",
                message: "native preview requires at least two stitch inputs",
                inputPaths: stitchInputs.map(\.path),
                outputPath: nil,
                metrics: nil,
                diagnostics: nil,
                exportProfile: nil,
                comparison: nil,
                gate: nil,
                failures: []
            )
        }

        let engine = try NativeEngineBridge()
        let preview = try engine.runPreview(
            paths: stitchInputs,
            settings: options.settings,
            progress: { event in
                fputs("\(baselineCase.id): \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
            }
        )
        guard var result = preview.result else {
            return ManifestNativeCaseRun(
                id: baselineCase.id,
                status: "failed",
                message: preview.message,
                inputPaths: stitchInputs.map(\.path),
                outputPath: nil,
                metrics: nil,
                diagnostics: nil,
                exportProfile: nil,
                comparison: nil,
                gate: nil,
                failures: ["native preview did not return a result"]
            )
        }

        var outputPath: String?
        if let exportSettings = options.exportSettings {
            let outputURL = outputDirectory.appendingPathComponent("\(sanitizeFilename(baselineCase.id)).tiff")
            let export = try engine.exportFullResolution(
                result: result,
                outputURL: outputURL,
                settings: exportSettings,
                progress: { event in
                    fputs("\(baselineCase.id): \(event.stage) \(Int(event.fraction * 100))%\n", stderr)
                }
            )
            if let exported = export.result {
                result = exported
                outputPath = outputURL.path
            } else {
                return ManifestNativeCaseRun(
                    id: baselineCase.id,
                    status: "failed",
                    message: export.message,
                    inputPaths: stitchInputs.map(\.path),
                    outputPath: outputURL.path,
                    metrics: nil,
                    diagnostics: nil,
                    exportProfile: nil,
                    comparison: nil,
                    gate: nil,
                    failures: ["native export did not return a result"]
                )
            }
        }

        let candidateMetrics = metrics(fromNativeResult: result)
        var failures = expectedMetricFailures(
            expected: baselineCase.expectedMetrics,
            candidate: candidateMetrics,
            diagnostics: result.diagnostics
        )
        let pythonReports = baselineCase.inputs
            .filter { $0.kind == .pythonReport }
            .map { resolveManifestPath($0.path, relativeTo: baseURL) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let comparison: ParityComparison?
        if let pythonReport = pythonReports.first {
            let baselineMetrics = try metrics(fromPythonReport: readJSONValue(pythonReport))
            let value = ParityComparator.compare(baseline: baselineMetrics, candidate: candidateMetrics)
            comparison = value
            failures.append(contentsOf: value.failures)
        } else {
            comparison = nil
        }

        let gate = ParityGate.evaluate(result: result)
        if !gate.passed && !options.allowUnprovenParity {
            failures.append("native parity gate failed: \(gate.reason)")
        }
        return ManifestNativeCaseRun(
            id: baselineCase.id,
            status: failures.isEmpty ? "passed" : "failed",
            message: failures.isEmpty ? "native candidate passed configured checks" : "native candidate failed configured checks",
            inputPaths: stitchInputs.map(\.path),
            outputPath: outputPath,
            metrics: candidateMetrics,
            diagnostics: manifestDiagnostics(from: result.diagnostics),
            exportProfile: result.diagnostics["export_profile"],
            comparison: comparison,
            gate: gate,
            failures: failures
        )
    }

    static func compare(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            fputs("compare requires baseline.json and candidate.json\n", stderr)
            return 2
        }
        do {
            let baseline = try readMetrics(URL(fileURLWithPath: arguments[0]))
            let candidate = try readMetrics(URL(fileURLWithPath: arguments[1]))
            let result = ParityComparator.compare(baseline: baseline, candidate: candidate)
            try printJSON(result)
            return result.passed ? 0 : 3
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func metricsFromPythonReport(arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            fputs("metrics-from-python-report requires report.json\n", stderr)
            return 2
        }
        do {
            let root = try readJSONValue(URL(fileURLWithPath: arguments[0]))
            try printJSON(metrics(fromPythonReport: root))
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func metricsFromNativeResult(arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            fputs("metrics-from-native-result requires native-result.json\n", stderr)
            return 2
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            if let response = try? JSONDecoder().decode(EngineOperationResponse.self, from: data),
               let result = response.result {
                try printJSON(metrics(fromNativeResult: result))
                return 0
            }
            let result = try JSONDecoder().decode(StitchResult.self, from: data)
            try printJSON(metrics(fromNativeResult: result))
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func readMetrics(_ url: URL) throws -> StitchMetrics {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StitchMetrics.self, from: data)
    }

    static func readJSONValue(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func metrics(fromNativeResult result: StitchResult) -> StitchMetrics {
        let selectedEdges = result.diagnostics["selected_edges"]?.arrayValue?.count ?? 0
        let alignmentError = alignmentMetrics(from: result.diagnostics)
        let starProjection = starProjectionMetrics(from: result.diagnostics)
        let exportProfile = result.diagnostics["export_profile"]
        return StitchMetrics(
            controlPointCount: result.controlPoints.count,
            selectedEdges: selectedEdges,
            panoramaWidth: result.panorama.width,
            panoramaHeight: result.panorama.height,
            alignmentRMS: alignmentError.rms,
            alignmentP95: alignmentError.p95,
            bitDepth: result.panorama.bitDepth > 0 ? result.panorama.bitDepth : nil,
            exportSeconds: exportProfile?["total_seconds"]?.numberValue,
            peakMemoryMB: exportProfile?["peak_memory_mb"]?.numberValue,
            overlapPixels: exportProfile?["overlap_pixels"]?.numberValue.map { Int($0) },
            meanOverlapAbsdiff: exportProfile?["mean_overlap_absdiff"]?.numberValue,
            maxOverlapAbsdiff: exportProfile?["max_overlap_absdiff"]?.numberValue,
            highConfidenceStarCount: starProjection.highConfidenceCount,
            highConfidenceStarP95: starProjection.highConfidenceP95,
            mutualStarP95: starProjection.mutualP95
        )
    }

    static func manifestDiagnostics(from diagnostics: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for key in [
            "camera_model",
            "guided_star_refinement",
            "local_star_refinement",
            "texture_sift_refinement",
            "camera_projection_preview",
            "output_bounds",
            "blend_mode",
            "blend_engine",
            "preview_status",
            "selected_edges",
            "control_points",
            "star_projection_alignment"
        ] {
            if let value = diagnostics[key] {
                object[key] = value
            }
        }
        return .object(object)
    }

    static func metrics(fromPythonReport root: JSONValue) -> StitchMetrics {
        let diagnostics = root["diagnostics"] ?? root
        let alignmentError = alignmentMetrics(from: diagnostics)
        let starProjection = starProjectionMetrics(from: diagnostics)
        let exportProfile = diagnostics["export_profile"]
        let panoramaShape = root["panorama"]?["shape"]?.arrayValue ?? []
        let height = Int(panoramaShape.first?.numberValue ?? 0)
        let width = Int(panoramaShape.dropFirst().first?.numberValue ?? 0)
        let controlPoints = root["control_points"]?.arrayValue?.count
            ?? Int(diagnostics["control_points"]?["total"]?.numberValue ?? 0)
        let selectedEdges = diagnostics["selected_edges"]?.arrayValue?.count ?? 0
        return StitchMetrics(
            controlPointCount: controlPoints,
            selectedEdges: selectedEdges,
            panoramaWidth: width,
            panoramaHeight: height,
            alignmentRMS: alignmentError.rms,
            alignmentP95: alignmentError.p95,
            bitDepth: nil,
            exportSeconds: exportProfile?["total_seconds"]?.numberValue,
            peakMemoryMB: exportProfile?["peak_memory_mb"]?.numberValue,
            overlapPixels: exportProfile?["overlap_pixels"]?.numberValue.map { Int($0) },
            meanOverlapAbsdiff: exportProfile?["mean_overlap_absdiff"]?.numberValue,
            maxOverlapAbsdiff: exportProfile?["max_overlap_absdiff"]?.numberValue,
            highConfidenceStarCount: starProjection.highConfidenceCount,
            highConfidenceStarP95: starProjection.highConfidenceP95,
            mutualStarP95: starProjection.mutualP95
        )
    }

    static func alignmentMetrics(from diagnostics: JSONValue) -> (rms: Double?, p95: Double?) {
        if let selectedError = diagnostics["selected_alignment_quality"]?["panorama_error"] {
            return (
                selectedError["rms"]?.numberValue,
                selectedError["p95"]?.numberValue
            )
        }
        let controlPointSummary = diagnostics["control_points"]
        return (
            controlPointSummary?["rms_error"]?.numberValue,
            controlPointSummary?["p95_error"]?.numberValue
        )
    }

    static func starProjectionMetrics(
        from diagnostics: JSONValue
    ) -> (highConfidenceCount: Int?, highConfidenceP95: Double?, mutualP95: Double?) {
        let starProjection = diagnostics["star_projection_alignment"]
            ?? diagnostics["camera_model"]?["star_projection_alignment"]
        if let summary = starProjection?["summary"] {
            let highConfidence = summary["high_confidence_mutual_projection_error_px"]
            let mutual = summary["mutual_projection_error_px"]
            return (
                highConfidence?["count"]?.numberValue.map { Int($0) },
                highConfidence?["p95"]?.numberValue,
                mutual?["p95"]?.numberValue
            )
        }
        let highConfidence = starProjection?["high_confidence"]
        let mutual = starProjection?["mutual"]
        return (
            highConfidence?["count"]?.numberValue.map { Int($0) },
            highConfidence?["p95"]?.numberValue,
            mutual?["p95"]?.numberValue
        )
    }

    static func expectedMetricFailures(
        expected: BaselineExpectedMetrics?,
        candidate: StitchMetrics,
        diagnostics: JSONValue
    ) -> [String] {
        guard let expected else {
            return []
        }
        var failures: [String] = []
        if let minimum = expected.minControlPoints, candidate.controlPointCount < minimum {
            failures.append("control point count below expected minimum: expected >= \(minimum), candidate \(candidate.controlPointCount)")
        }
        if let minimum = expected.minSelectedEdges, candidate.selectedEdges < minimum {
            failures.append("selected edge count below expected minimum: expected >= \(minimum), candidate \(candidate.selectedEdges)")
        }
        if let maximum = expected.maxAlignmentRMS {
            if let current = candidate.alignmentRMS {
                if current > maximum {
                    failures.append("alignment RMS exceeds expected maximum: expected <= \(maximum), candidate \(current)")
                }
            } else {
                failures.append("alignment RMS missing in candidate")
            }
        }
        if let maximum = expected.maxAlignmentP95 {
            if let current = candidate.alignmentP95 {
                if current > maximum {
                    failures.append("alignment P95 exceeds expected maximum: expected <= \(maximum), candidate \(current)")
                }
            } else {
                failures.append("alignment P95 missing in candidate")
            }
        }
        if let minimum = expected.minHighConfidenceStarCount {
            if let current = candidate.highConfidenceStarCount {
                if current < minimum {
                    failures.append("high-confidence star count below expected minimum: expected >= \(minimum), candidate \(current)")
                }
            } else {
                failures.append("high-confidence star count missing in candidate")
            }
        }
        if let maximum = expected.maxHighConfidenceStarP95Px {
            if let current = candidate.highConfidenceStarP95 {
                if current > maximum {
                    failures.append("high-confidence star P95 exceeds expected maximum: expected <= \(maximum)px, candidate \(current)px")
                }
            } else {
                failures.append("high-confidence star P95 missing in candidate")
            }
        }
        if let maximum = expected.maxMutualStarP95Px {
            if let current = candidate.mutualStarP95 {
                if current > maximum {
                    failures.append("mutual star P95 exceeds expected maximum: expected <= \(maximum)px, candidate \(current)px")
                }
            } else {
                failures.append("mutual star P95 missing in candidate")
            }
        }
        if let minimum = expected.minBitDepth {
            if let current = candidate.bitDepth {
                if current < minimum {
                    failures.append("bit depth below expected minimum: expected >= \(minimum), candidate \(current)")
                }
            } else {
                failures.append("bit depth missing in candidate")
            }
        }
        if let maximum = expected.maxExportSeconds {
            if let current = candidate.exportSeconds {
                if current > maximum {
                    failures.append("export time exceeds expected maximum: expected <= \(maximum)s, candidate \(current)s")
                }
            } else {
                failures.append("export time missing in candidate")
            }
        }
        if let maximum = expected.maxPeakMemoryMB {
            if let current = candidate.peakMemoryMB {
                if current > maximum {
                    failures.append("peak memory exceeds expected maximum: expected <= \(maximum)MB, candidate \(current)MB")
                }
            } else {
                failures.append("peak memory missing in candidate")
            }
        }
        if let minimum = expected.minOverlapPixels {
            if let current = candidate.overlapPixels {
                if current < minimum {
                    failures.append("overlap pixels below expected minimum: expected >= \(minimum), candidate \(current)")
                }
            } else {
                failures.append("overlap pixels missing in candidate")
            }
        }
        if let maximum = expected.maxMeanOverlapAbsdiff {
            if let current = candidate.meanOverlapAbsdiff {
                if current > maximum {
                    failures.append("mean overlap absdiff exceeds expected maximum: expected <= \(maximum), candidate \(current)")
                }
            } else {
                failures.append("mean overlap absdiff missing in candidate")
            }
        }
        if let maximum = expected.maxOverlapAbsdiff {
            if let current = candidate.maxOverlapAbsdiff {
                if current > maximum {
                    failures.append("max overlap absdiff exceeds expected maximum: expected <= \(maximum), candidate \(current)")
                }
            } else {
                failures.append("max overlap absdiff missing in candidate")
            }
        }
        failures.append(contentsOf: refinementEvidenceFailures(expected: expected, diagnostics: diagnostics))
        return failures
    }

    static func refinementEvidenceFailures(
        expected: BaselineExpectedMetrics,
        diagnostics: JSONValue
    ) -> [String] {
        var failures: [String] = []
        let local = diagnostics["local_star_refinement"]
        if expected.requireLocalRefinementAccepted == true {
            if local?["accepted"]?.boolValue != true {
                let reason = local?["reason"]?.stringValue ?? "missing local_star_refinement diagnostics"
                failures.append("local refinement was not accepted: \(reason)")
            }
        }
        if let minimum = expected.minLocalRefinementPoints {
            let current = Int(local?["added_control_points"]?.numberValue ?? 0)
            if current < minimum {
                failures.append("local refinement points below expected minimum: expected >= \(minimum), candidate \(current)")
            }
        }

        let texture = diagnostics["texture_sift_refinement"]
        if expected.requireTextureRefinementAccepted == true {
            if texture?["accepted"]?.boolValue != true {
                let reason = texture?["reason"]?.stringValue ?? "missing texture_sift_refinement diagnostics"
                failures.append("texture refinement was not accepted: \(reason)")
            }
        }
        if let minimum = expected.minTextureRefinementPoints {
            let current = Int(texture?["added_control_points"]?.numberValue ?? 0)
            if current < minimum {
                failures.append("texture refinement points below expected minimum: expected >= \(minimum), candidate \(current)")
            }
        }
        return failures
    }

    static func resolveManifestPath(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    static func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "case" : sanitized
    }

    static func pixelSignature(_ pixels: PixelBufferInfo?) -> UInt64 {
        guard let pixels else {
            return 0
        }
        var hash: UInt64 = 1469598103934665603
        let prime: UInt64 = 1099511628211
        for byte in pixels.data.prefix(1_000_000) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= UInt64(pixels.width)
        hash = hash &* prime
        hash ^= UInt64(pixels.height)
        return hash
    }

    static func maskedPixelSSIM(
        _ lhs: PixelBufferInfo?,
        _ rhs: PixelBufferInfo?
    ) -> Double? {
        guard let lhs, let rhs,
              lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.width > 0,
              lhs.height > 0 else {
            return nil
        }
        var count = 0.0
        var sumLHS = 0.0
        var sumRHS = 0.0
        var sumLHSSquared = 0.0
        var sumRHSSquared = 0.0
        var sumProduct = 0.0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let lhsOffset = y * lhs.bytesPerRow + x * 4
                let rhsOffset = y * rhs.bytesPerRow + x * 4
                let lhsValue = luminance(
                    lhs.data[lhsOffset],
                    lhs.data[lhsOffset + 1],
                    lhs.data[lhsOffset + 2]
                )
                let rhsValue = luminance(
                    rhs.data[rhsOffset],
                    rhs.data[rhsOffset + 1],
                    rhs.data[rhsOffset + 2]
                )
                if lhsValue <= 2.0 / 255.0 || rhsValue <= 2.0 / 255.0 { continue }
                count += 1
                sumLHS += lhsValue
                sumRHS += rhsValue
                sumLHSSquared += lhsValue * lhsValue
                sumRHSSquared += rhsValue * rhsValue
                sumProduct += lhsValue * rhsValue
            }
        }
        guard count > 1 else { return nil }
        let meanLHS = sumLHS / count
        let meanRHS = sumRHS / count
        let denominator = max(1.0, count - 1.0)
        let varianceLHS = max(
            0,
            (sumLHSSquared - count * meanLHS * meanLHS) / denominator
        )
        let varianceRHS = max(
            0,
            (sumRHSSquared - count * meanRHS * meanRHS) / denominator
        )
        let covariance = (sumProduct - count * meanLHS * meanRHS) / denominator
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        return ((2 * meanLHS * meanRHS + c1) * (2 * covariance + c2))
            / ((meanLHS * meanLHS + meanRHS * meanRHS + c1)
                * (varianceLHS + varianceRHS + c2))
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == count
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func sha256File(_ url: URL) throws -> String {
        try provenanceDigestCache.digest(for: url) { fileURL in
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if chunk.isEmpty {
                    break
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func algorithmSourceFingerprint(root: URL) throws -> String {
        // Keep this order identical to GenerateSourceFingerprintPlugin. The
        // ordered payload is the ABI between workspace verification and the
        // fingerprint embedded in the running binary.
        let entries = try algorithmSourcePaths(root: root).map { path -> String in
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(
                    domain: "PanoLumeRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Algorithm source is missing: \(url.path)"]
                )
            }
            return "\(path):\(try sha256File(url))"
        }
        return sha256Hex(Data(entries.joined(separator: "\n").utf8))
    }

    static func certifiedAlgorithmSourceFingerprint(root: URL) -> String? {
        let url = root.appendingPathComponent(
            "macos/PanoLume/Docs/Certification/native-source-certification.json"
        )
        guard let data = try? Data(contentsOf: url),
              let sourcePaths = try? algorithmSourcePaths(root: root),
              let manifest = try? JSONDecoder().decode(SourceCertificationManifest.self, from: data),
              manifest.schemaVersion == 3,
              manifest.certificationStatus == "certified",
              manifest.algorithmSourceFiles == sourcePaths,
              isLowercaseHex(manifest.certifiedSourceCommit, count: 40),
              isLowercaseHex(manifest.certifiedSourceFingerprint, count: 64),
              isLowercaseHex(manifest.releaseReportSHA256, count: 64),
              isLowercaseHex(manifest.metalDylibSHA256, count: 64),
              manifest.metalAPIVersion == NativeEngineBridge.currentMetalRendererAPIVersion else {
            return nil
        }
        return manifest.certifiedSourceFingerprint
    }

    static func gitOutput(_ arguments: [String], root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8) ?? "git command failed"
            throw NSError(domain: "PanoLumeRegression", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stableJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to encode provenance configuration"])
        }
        return text
    }

    static func regressionExecutableURL() throws -> URL {
        var candidates: [URL] = []
        if let bundleExecutable = Bundle.main.executableURL {
            candidates.append(bundleExecutable)
        }
        if let argument = CommandLine.arguments.first, !argument.isEmpty {
            let argumentURL: URL
            if argument.hasPrefix("/") {
                argumentURL = URL(fileURLWithPath: argument)
            } else {
                argumentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(argument)
            }
            candidates.append(argumentURL)
        }
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return resolved
            }
        }
        throw NSError(
            domain: "PanoLumeRegression",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Certification evidence refused: unable to locate the running PanoLumeRegression executable for SHA-256 binding."
            ]
        )
    }

    static func validatedRuntimeEvidenceBinding(
        workspaceSourceFingerprint: String
    ) throws -> (binding: RegressionEvidenceRuntimeBinding, capabilities: EngineCapabilities) {
        let capabilities = try NativeEngineBridge.capabilities()
        let executableSHA256 = try sha256File(regressionExecutableURL())
        let binding = try RegressionEvidenceBindingValidator.validate(
            workspaceSourceFingerprint: workspaceSourceFingerprint,
            binarySourceFingerprint: capabilities.nativeEngineSourceFingerprint,
            regressionExecutableSHA256: executableSHA256
        )
        return (binding, capabilities)
    }

    static func makeProvenance(
        inputURLs: [URL],
        configuration: [String: String],
        includePythonOracle: Bool = true
    ) throws -> ParityProvenance {
        let root = try repositoryRoot()
        let sourceCommit = try gitOutput(["rev-parse", "HEAD"], root: root)
        let sourceFingerprint = try algorithmSourceFingerprint(root: root)
        let runtimeEvidence = try validatedRuntimeEvidenceBinding(
            workspaceSourceFingerprint: sourceFingerprint
        )
        let runtimeBinding = runtimeEvidence.binding
        let certifiedSourceFingerprint = certifiedAlgorithmSourceFingerprint(root: root)
        let status = try gitOutput(["status", "--porcelain", "--untracked-files=all"], root: root)
        let worktreeClean = status.isEmpty
        var inputSHA256: [String: String] = [:]
        for url in inputURLs.map(\.standardizedFileURL) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "PanoLumeRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "provenance input is missing: \(url.path)"])
            }
            inputSHA256[url.path] = try sha256File(url)
        }
        let configurationData = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let configurationSHA256 = sha256Hex(configurationData)
        let metalURL = root.appendingPathComponent("build/native/libpanolume_metal.dylib")
        let metalDylibSHA256 = FileManager.default.fileExists(atPath: metalURL.path)
            ? try sha256File(metalURL)
            : nil
        let metalAPIVersion = runtimeEvidence.capabilities.nativeMetalRendererAPIVersion
        let oracleCandidate = includePythonOracle ? (try? pythonOracleRoot(required: false)) : nil
        let oracleRoot = oracleCandidate.flatMap { candidate in
            FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("scripts/diagnose_stitch.py").path
            ) ? candidate : nil
        }
        let oracleScriptsSHA256 = oracleRoot.flatMap { try? pythonOracleScriptDigest(root: $0) }
        let usableOracleRoot = oracleScriptsSHA256 == nil ? nil : oracleRoot
        let oracleCommit = usableOracleRoot.flatMap(pythonOracleCommit)
        let resolvedPython = usableOracleRoot == nil ? nil : (try? pythonExecutable(required: false))
        let pythonExecutableSHA256 = try resolvedPython.map(sha256File)
        let pythonVersion = resolvedPython.flatMap(executableVersion)
        let oracleIdentity = try usableOracleRoot.flatMap { root in
            try resolvedPython.map { try pythonOracleIdentityFingerprint(root: root, python: $0) }
        }
        let oracleWorktreeClean = oracleIdentity == nil ? nil : true
        let fingerprintObject: [String: Any] = [
            "schema_version": RegressionProvenanceSchema.currentVersion,
            "source_commit": sourceCommit,
            "source_fingerprint": sourceFingerprint,
            "binary_engine_source_fingerprint": runtimeBinding.binarySourceFingerprint,
            "regression_executable_sha256": runtimeBinding.regressionExecutableSHA256,
            "certified_source_fingerprint": certifiedSourceFingerprint ?? NSNull(),
            "worktree_clean": worktreeClean,
            "input_sha256": inputSHA256,
            "configuration_sha256": configurationSHA256,
            "metal_dylib_sha256": metalDylibSHA256 ?? NSNull(),
            "metal_api_version": metalAPIVersion ?? NSNull(),
            "oracle_identity": oracleIdentity ?? NSNull(),
            "oracle_worktree_clean": oracleWorktreeClean ?? NSNull(),
            "tool_version": RegressionProvenanceSchema.toolVersion,
        ]
        let fingerprintData = try JSONSerialization.data(withJSONObject: fingerprintObject, options: [.sortedKeys])
        return ParityProvenance(
            schemaVersion: RegressionProvenanceSchema.currentVersion,
            fingerprint: sha256Hex(fingerprintData),
            sourceCommit: sourceCommit,
            sourceFingerprint: sourceFingerprint,
            binaryEngineSourceFingerprint: runtimeBinding.binarySourceFingerprint,
            regressionExecutableSHA256: runtimeBinding.regressionExecutableSHA256,
            certifiedSourceFingerprint: certifiedSourceFingerprint,
            worktreeClean: worktreeClean,
            inputSHA256: inputSHA256,
            configurationSHA256: configurationSHA256,
            metalDylibSHA256: metalDylibSHA256,
            metalAPIVersion: metalAPIVersion,
            oracleRoot: usableOracleRoot?.path,
            oracleCommit: oracleCommit,
            oracleScriptsSHA256: oracleScriptsSHA256,
            oracleIdentity: oracleIdentity,
            oracleWorktreeClean: oracleWorktreeClean,
            pythonExecutable: resolvedPython?.path,
            pythonExecutableSHA256: pythonExecutableSHA256,
            pythonVersion: pythonVersion,
            toolVersion: RegressionProvenanceSchema.toolVersion,
            createdAtUTC: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        provenance: ParityProvenance
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reportData = try encoder.encode(value)
        let provenanceData = try encoder.encode(provenance)
        guard var report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any] else {
            throw NSError(domain: "PanoLumeRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "provenance can only be attached to JSON objects"])
        }
        report["provenance"] = try JSONSerialization.jsonObject(with: provenanceData)
        var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        data.append(contentsOf: Data("\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    static func printUsage() {
        fputs(
            """
            Usage:
              PanoLumeRegression [--oracle-root path] [--python-executable path] <command> ...
              PanoLumeRegression capabilities
              PanoLumeRegression dependencies
              PanoLumeRegression load-images [--preview-max-side px] [--full-input-preview] [--raw-full-size] <image1> <image2> [...]
              PanoLumeRegression preview [--alignment-mode auto|sift|stars] [--geometry auto|camera|homography] [--preview-max-side px] [--optimize-distortion] [--no-guided-refinement] [--no-local-refinement] [--no-texture-refinement] [--multiband] <image1> <image2> [...]
              PanoLumeRegression standard-image-regression --case synthetic-crops|test_1_parts [--reference image] [--output-dir dir] [--max-pair-p95 px] [--min-ssim value] [--max-seconds value] [--preview-max-side px] [<image1> <image2> ...]

            For --case synthetic-crops, omit both --reference and image paths to generate a deterministic native three-crop fixture in --output-dir. Explicit paths plus --reference override generation.
              PanoLumeRegression preview-export-diagnostic --output <preview.tiff> [--report response.json] [--bit-depth 8|16] [--strip-render|--fullres-render|--renderer backend] [--max-output-side px] [--max-output-pixels n] [--camera] [--optimize-distortion] [--no-local-refinement] [--multiband] <image1> <image2> [...]
              PanoLumeRegression projection-drag-smoke --case 3raw|4raw|7raw [--pitch deg] [--yaw deg] [--roll deg] [--samples n] [--output report.json] [--no-blend-after-drag] [--optimize-distortion] [--multiband] <image1> <image2> [...]
              PanoLumeRegression raw1-canvas-smoke --output report.json [--pitch deg] [--yaw deg] [--roll deg] <raw1> ... <raw7>
              PanoLumeRegression cancellation-smoke [--operation preview|drag|export] [--working-set-budget-mb n] [--output report.json] <image1> <image2> [...]
              PanoLumeRegression external-working-set-calibration --output report.json [--expected-exit-code n] -- <PanoLumeRegression command and arguments>
              PanoLumeRegression rerender-control-points --case camera-reopt|homography-reopt|disconnected [--output report.json] [--optimize-distortion] [--multiband] [--expect-disconnected] <image1> <image2> [...]
              PanoLumeRegression raw2-auto-refinement --output report.json [--lens-profile profile.lcp] <Z8L_2185.NEF> ... <Z8L_2171.NEF>
              PanoLumeRegression raw2-manual-reopt --fixture fixture.json [--output report.json] [--lens-profile profile.lcp] <Z8L_2185.NEF> ... <Z8L_2171.NEF>
              PanoLumeRegression raw2-export-pair --output report.json [--output-dir dir] [--lens-profile profile.lcp] <Z8L_2185.NEF> ... <Z8L_2171.NEF>
              PanoLumeRegression refine-astro-result --input draft-result.json --output refinement-report.json
              PanoLumeRegression manifest validate <manifest.json>
              PanoLumeRegression manifest summarize <manifest.json>
              PanoLumeRegression manifest run-native [--allow-unproven-parity] [--strip-render|--fullres-render] [--output-dir dir] [--max-output-side px] [--max-output-pixels n] [--preview-max-side px] [--optimize-distortion] [--no-local-refinement] [--multiband] <manifest.json>
              PanoLumeRegression parity compare-preview [--case id] [--settings ui-default|camera] [--order original|sorted|reverse] [--output-dir dir] [--reuse-python-oracle] <image1> <image2> [...]
              PanoLumeRegression parity compare-export [--case id] [--settings ui-default|camera] [--order original|sorted|reverse] [--output-dir dir] [--renderer cpu|metal_fast|metal_quality] [--bit-depth 8|16] [--apply-preview-stretch] <image1> <image2> [...]
              PanoLumeRegression parity compare-raw-decode [--output-dir dir] [--full-size] <raw1> [raw2 ...]
              PanoLumeRegression parity run-suite [--output-dir dir] [--case id[,id...]] [--settings ui-default|camera] [--order original|sorted|reverse] [--resume] [--reuse-python-oracle]
              PanoLumeRegression parity run-export-suite [--output-dir dir] [--case id[,id...]] [--settings ui-default|camera] [--order sorted|reverse] [--renderer cpu|metal_quality] [--linear-only] [--resume]
              PanoLumeRegression parity validate-release [--candidate-certification] --raw2-auto-refinement raw2-auto.json --raw2-manual-reoptimization raw2-manual.json --raw2-export-pair raw2-export.json --raw1-canvas-smoke raw1-canvas.json --ordinary-image-report ordinary.json --control-point-report control-points.json --refinement-cancellation-report refinement-cancel.json --projection-release-report projection-release.json --installation-report install-launch.json [--output report.json]
              PanoLumeRegression certification status [--manifest manifest.json] [--output report.json]
              PanoLumeRegression certification verify [--manifest manifest.json] [--output report.json]
              PanoLumeRegression certification promote --release-report report.json [--manifest manifest.json] [--output manifest.json]
              PanoLumeRegression perf run-suite [--case 3raw|4raw|7raw] [--renderer cpu|metal_fast|metal_quality] [--paired --repetitions 3] [--output-dir dir]
              PanoLumeRegression metrics-from-python-report <report.json>
              PanoLumeRegression metrics-from-native-result <native-result.json>
              PanoLumeRegression compare <baseline-metrics.json> <candidate-metrics.json>

            Exit code 3 means PanoLume built and ran but a required quality or release gate remains closed.

            Python parity commands also accept PANOLUME_PYTHON_ORACLE_ROOT
            (or PANOLUME_ORACLE_ROOT) and PANOLUME_PYTHON_EXECUTABLE. Set
            PANOLUME_REPOSITORY_ROOT only for a relocated standalone binary.
            Native-only commands do not require an oracle.

            """,
            stderr
        )
    }
}

exit(RegressionCLI.run(arguments: CommandLine.arguments))
