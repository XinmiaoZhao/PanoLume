import Foundation
import MyPTGuiEngine

// A strong Swift reference keeps the generated identity object linked in
// optimized builds. The C++ bridge intentionally imports the same symbol as
// weak so a missing identity fails closed instead of preventing diagnostics.
@_silgen_name("myptgui_build_engine_source_fingerprint")
func myptguiBuildEngineSourceFingerprintLinkAnchor() -> UnsafePointer<CChar>

public enum NativeEngineError: Error, LocalizedError, Equatable {
    case contextCreationFailed
    case emptyResponse
    case engineFailure(String)
    case encodingFailure(String)
    case decodingFailure(String)

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create the image-processing engine context."
        case .emptyResponse:
            return "The panorama engine returned an empty response."
        case .engineFailure(let message):
            return message
        case .encodingFailure(let message):
            return "Failed to encode engine request: \(message)"
        case .decodingFailure(let message):
            return "Failed to decode engine response: \(message)"
        }
    }
}

public struct EngineCapabilities: Codable, Equatable, Sendable {
    public var swiftuiShell: Bool
    public var cABIFacade: Bool
    public var standardImageIO: Bool?
    public var displayStretch: Bool?
    public var opencvSIFTHomographyPreview: Bool?
    public var starAsterismPreview: Bool?
    public var ceresRotationCameraAdjustmentPreview: Bool?
    public var nativeBrownConradyDistortionAdjustmentPreview: Bool?
    public var nativeGuidedStarRefinementPreview: Bool?
    public var nativeLocalStarRefinementPreview: Bool?
    public var nativeTextureSIFTRefinementPreview: Bool?
    public var nativeCameraProjectionPreview: Bool?
    public var nativeCPUMultibandBlendingPreview: Bool?
    public var nativePreviewTIFFExportDiagnostic: Bool?
    public var nativePreviewCameraStripTIFFExportDiagnostic: Bool?
    public var nativeFullresCameraStripTIFFExportDiagnostic: Bool?
    public var nativeExportPeakMemoryDiagnostic: Bool?
    public var nativeExportOverlapSeamDiagnostic: Bool?
    public var nativeMultiRoundRobustCameraFilter: Bool?
    public var nativeDependenciesAvailable: Bool?
    public var nativeQualityGateAvailable: Bool?
    public var nativeMetalRendererAvailable: Bool?
    public var nativeMetalQualityAvailable: Bool?
    public var nativeMetalRendererAPICompatible: Bool?
    public var nativeMetalRendererAPIVersion: Int?
    public var nativePreviewGPUAvailable: Bool?
    public var pythonRuntimeDependency: Bool
    public var pysideReferenceRequired: Bool
    public var nativeAlgorithmParity: Bool
    public var nativeParityCertifiedSourceCommit: String?
    public var nativeParityReleaseReportSHA256: String?
    public var nativeParityMetalDylibSHA256: String?
    public var nativeParityMetalAPIVersion: Int?
    public var nativeParityReleaseIdentityAvailable: Bool?
    public var nativeEngineSourceFingerprint: String?
    public var nativeParityCertifiedEngineSourceFingerprint: String?
    public var dependencies: [String: Bool]
    public var dependencyReport: NativeDependencyReport?
    public var missingAlgorithms: [String]

    enum CodingKeys: String, CodingKey {
        case swiftuiShell = "swiftui_shell"
        case cABIFacade = "c_abi_facade"
        case standardImageIO = "standard_image_io"
        case displayStretch = "display_stretch"
        case opencvSIFTHomographyPreview = "opencv_sift_homography_preview"
        case starAsterismPreview = "star_asterism_preview"
        case ceresRotationCameraAdjustmentPreview = "ceres_rotation_camera_adjustment_preview"
        case nativeBrownConradyDistortionAdjustmentPreview = "native_brown_conrady_distortion_adjustment_preview"
        case nativeGuidedStarRefinementPreview = "native_guided_star_refinement_preview"
        case nativeLocalStarRefinementPreview = "native_local_star_refinement_preview"
        case nativeTextureSIFTRefinementPreview = "native_texture_sift_refinement_preview"
        case nativeCameraProjectionPreview = "native_camera_projection_preview"
        case nativeCPUMultibandBlendingPreview = "native_cpu_multiband_blending_preview"
        case nativePreviewTIFFExportDiagnostic = "native_preview_tiff_export_diagnostic"
        case nativePreviewCameraStripTIFFExportDiagnostic = "native_preview_camera_strip_tiff_export_diagnostic"
        case nativeFullresCameraStripTIFFExportDiagnostic = "native_fullres_camera_strip_tiff_export_diagnostic"
        case nativeExportPeakMemoryDiagnostic = "native_export_peak_memory_diagnostic"
        case nativeExportOverlapSeamDiagnostic = "native_export_overlap_seam_diagnostic"
        case nativeMultiRoundRobustCameraFilter = "native_multi_round_robust_camera_filter"
        case nativeDependenciesAvailable = "native_dependencies_available"
        case nativeQualityGateAvailable = "native_quality_gate_available"
        case nativeMetalRendererAvailable = "native_metal_renderer_available"
        case nativeMetalQualityAvailable = "native_metal_quality_available"
        case nativeMetalRendererAPICompatible = "native_metal_renderer_api_compatible"
        case nativeMetalRendererAPIVersion = "native_metal_renderer_api_version"
        case nativePreviewGPUAvailable = "native_preview_gpu_available"
        case pythonRuntimeDependency = "python_runtime_dependency"
        case pysideReferenceRequired = "pyside_reference_required"
        case nativeAlgorithmParity = "native_algorithm_parity"
        case nativeParityCertifiedSourceCommit = "native_parity_certified_source_commit"
        case nativeParityReleaseReportSHA256 = "native_parity_release_report_sha256"
        case nativeParityMetalDylibSHA256 = "native_parity_metal_dylib_sha256"
        case nativeParityMetalAPIVersion = "native_parity_metal_api_version"
        case nativeParityReleaseIdentityAvailable = "native_parity_release_identity_available"
        case nativeEngineSourceFingerprint = "native_engine_source_fingerprint"
        case nativeParityCertifiedEngineSourceFingerprint = "native_parity_certified_engine_source_fingerprint"
        case dependencies
        case dependencyReport = "dependency_report"
        case missingAlgorithms = "missing_algorithms"
    }
}

struct PreviewRequest: Codable {
    var paths: [String]
    var projection: String
    var settings: StitchSettings
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case paths
        case projection
        case settings
        case jobID = "jobId"
    }
}

struct ImageLoadRequest: Codable {
    var paths: [String]
    var settings: StitchSettings
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case paths
        case settings
        case jobID = "jobId"
    }
}

struct SourcePreviewLoadRequest: Codable {
    var path: String
    var maxSide: Int
    var fullResolution: Bool
    var rawHalfSize: Bool
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case path
        case maxSide
        case fullResolution
        case rawHalfSize
        case jobID = "jobId"
    }
}

struct SourcePreviewPixelRequest: Codable {
    var settings: StitchSettings
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case settings
        case jobID = "jobId"
    }
}

public struct SourcePreviewImage: Equatable, Sendable {
    public var pixels: PixelBufferInfo
    public var imageInfo: NativeImageInfo
    public var isFullResolution: Bool

    public init(
        pixels: PixelBufferInfo,
        imageInfo: NativeImageInfo,
        isFullResolution: Bool
    ) {
        self.pixels = pixels
        self.imageInfo = imageInfo
        self.isFullResolution = isFullResolution
    }
}

struct Raw16SpoolRequest: Codable {
    var path: String
    var outputPath: String
    var halfSize: Bool
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case path
        case outputPath
        case halfSize
        case jobID = "jobId"
    }
}

public struct Raw16SpoolResult: Codable, Equatable, Sendable {
    public var success: Bool
    public var message: String
    public var path: String
    public var width: Int
    public var height: Int
    public var channels: Int
    public var bitDepth: Int
    public var sampleType: String
    public var halfSize: Bool

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case path
        case width
        case height
        case channels
        case bitDepth = "bit_depth"
        case sampleType = "sample_type"
        case halfSize = "half_size"
    }
}

public struct TIFFStreamingComparison: Codable, Equatable, Sendable {
    public var success: Bool
    public var message: String?
    public var streaming: Bool?
    public var format: String?
    public var width: Int?
    public var height: Int?
    public var bitDepth: Int?
    public var samplesPerPixel: Int?
    public var coveredPixelsFirst: UInt64?
    public var coveredPixelsSecond: UInt64?
    public var coverageIntersectionPixels: UInt64?
    public var coverageUnionPixels: UInt64?
    public var coverageIoU: Double?
    public var rgbSSIM: Double?
    public var medianAbsDiff: Double?
    public var p95AbsDiff: Double?
    public var maxAbsDiff: Double?

    enum CodingKeys: String, CodingKey {
        case success, message, streaming, format, width, height
        case bitDepth = "bit_depth"
        case samplesPerPixel = "samples_per_pixel"
        case coveredPixelsFirst = "covered_pixels_first"
        case coveredPixelsSecond = "covered_pixels_second"
        case coverageIntersectionPixels = "coverage_intersection_pixels"
        case coverageUnionPixels = "coverage_union_pixels"
        case coverageIoU = "coverage_iou"
        case rgbSSIM = "rgb_ssim"
        case medianAbsDiff = "median_absdiff"
        case p95AbsDiff = "p95_absdiff"
        case maxAbsDiff = "max_absdiff"
    }
}

struct ContactSheetRequest: Codable {
    var paths: [String]
    var imageHandles: [String]
    var projection: String
    var settings: StitchSettings
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case paths
        case imageHandles
        case projection
        case settings
        case jobID = "jobId"
    }
}

struct ResultRequest: Codable {
    var resultHandle: String
    var settings: StitchSettings?
    var exportSettings: ExportSettings?
    var outputPath: String?
    var poseAdjustment: PoseAdjustment?
    var quality: RenderQuality?
    var controlPoints: [ControlPoint]?
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case resultHandle
        case settings
        case exportSettings
        case outputPath
        case poseAdjustment
        case quality
        case controlPoints
        case jobID = "jobId"
    }
}

struct AstroSelectedPairRequest: Codable {
    var i: Int
    var j: Int
}

struct AstroRefinementRequest: Codable {
    var paths: [String]
    var cameraParams: [CameraParams]
    var workingWidths: [Int]
    var workingHeights: [Int]
    var selectedPairs: [AstroSelectedPairRequest]
    var controlPoints: [ControlPoint]
    var projection: String
    var settings: StitchSettings
    var includeWorstStarPatches: Bool
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case paths, cameraParams, workingWidths, workingHeights
        case selectedPairs, controlPoints, projection, settings, includeWorstStarPatches
        case jobID = "jobId"
    }
}

struct ApplyAstroRefinementRequest: Codable {
    var resultHandle: String
    var cameraParams: [CameraParams]
    var astroRefinementJSON: String
    var localWarp: LocalWarpModel
    var jobID: UInt64?

    enum CodingKeys: String, CodingKey {
        case resultHandle, cameraParams, astroRefinementJSON, localWarp
        case jobID = "jobId"
    }
}

public struct AstroManualPointRecord: Codable, Equatable, Sendable {
    public var index: Int
    public var accepted: Bool
    public var error: Double?
    public var reason: String

    public init(index: Int, accepted: Bool, error: Double?, reason: String) {
        self.index = index
        self.accepted = accepted
        self.error = error
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case index, accepted, reason
        case error = "error_px"
    }
}

public struct AstroRefinementResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var operation: String
    public var message: String
    public var passed: Bool
    public var cameraParams: [CameraParams]
    public var astroRefinement: AstroRefinementInfo
    public var localWarp: LocalWarpModel
    public var manualPoints: [AstroManualPointRecord]
    public var fullWidths: [Int]?
    public var fullHeights: [Int]?

    enum CodingKeys: String, CodingKey {
        case success, operation, message, passed
        case cameraParams = "camera_params"
        case astroRefinement = "astro_refinement"
        case localWarp = "local_warp"
        case manualPoints = "manual_points"
        case fullWidths = "full_widths"
        case fullHeights = "full_heights"
    }
}

struct GeometryCommitResultDelta: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var handle: String
    var projection: String
    var cameraParams: [CameraParams]
    var poseAdjustment: PoseAdjustment
    var diagnosticsDelta: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case handle
        case projection
        case cameraParams = "camera_params"
        case poseAdjustment = "pose_adjustment"
        case diagnosticsDelta = "diagnostics_delta"
    }
}

struct GeometryCommitWireResponse: Decodable {
    var success: Bool
    var operation: String
    var message: String
    var resultDelta: GeometryCommitResultDelta?

    enum CodingKeys: String, CodingKey {
        case success
        case operation
        case message
        case resultDelta = "result_delta"
    }
}

final class ProgressBox {
    let callback: @Sendable (ProgressEvent) -> Void

    init(callback: @escaping @Sendable (ProgressEvent) -> Void) {
        self.callback = callback
    }
}

public final class NativeEngineBridge {
    /// C/Metal coverage-buffer ABI required by this source tree. A promoted
    /// manifest may intentionally report an older value, which keeps export
    /// fail-closed until a new certification is completed.
    public static let currentMetalRendererAPIVersion = 5

    let context: OpaquePointer

    public init() throws {
        guard let created = myptgui_create_context() else {
            throw NativeEngineError.contextCreationFailed
        }
        context = created
    }

    /// Compares two unsigned contiguous RGB16 TIFFs one scanline at a time.
    /// The native comparator keeps only two rows, an exact UInt16 difference
    /// histogram, and streaming moments in memory, so certification does not
    /// need to decode two full-resolution panoramas at once.
    public static func compareRGB16TIFFsStreaming(
        first firstURL: URL,
        second secondURL: URL
    ) throws -> TIFFStreamingComparison {
        let raw = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                myptgui_compare_tiff_rgb16_streaming(firstPath, secondPath)
            }
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        do {
            return try JSONDecoder().decode(TIFFStreamingComparison.self, from: data)
        } catch {
            throw NativeEngineError.decodingFailure(error.localizedDescription)
        }
    }

    deinit {
        myptgui_destroy_context(context)
    }

    /// Ends the current interactive projection texture lifetime without
    /// destroying the document engine. In-flight command buffers retain their
    /// own resources; subsequent documents cannot reuse a stale pointer-keyed
    /// Metal buffer.
    public func resetProjectionSession() {
        myptgui_reset_projection_session(context)
    }

    public static func capabilities() throws -> EngineCapabilities {
        _ = myptguiBuildEngineSourceFingerprintLinkAnchor()
        guard let raw = myptgui_engine_capabilities() else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("capabilities response is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(EngineCapabilities.self, from: data)
        } catch {
            throw NativeEngineError.decodingFailure(error.localizedDescription)
        }
    }

    public static func dependencyReport() throws -> NativeDependencyReport {
        guard let raw = myptgui_dependency_report_json() else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("dependency report response is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(NativeDependencyReport.self, from: data)
        } catch {
            throw NativeEngineError.decodingFailure(error.localizedDescription)
        }
    }

    /// Resolves the Metal renderer locations used by the native loader for an
    /// independently packaged app. This diagnostic shares the production C++
    /// path builder so bundle layout tests cannot drift from runtime lookup.
    public static func metalRendererDylibCandidates(
        bundleRoot: URL,
        executableURL: URL
    ) throws -> [String] {
        let raw = bundleRoot.path.withCString { bundlePointer in
            executableURL.path.withCString { executablePointer in
                myptgui_metal_dylib_candidates_for_paths_json(
                    bundlePointer,
                    executablePointer
                )
            }
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw NativeEngineError.decodingFailure(error.localizedDescription)
        }
    }

    public func runPreview(
        paths: [URL],
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        let request = PreviewRequest(
            paths: paths.map(\.path),
            projection: settings.projection,
            settings: settings,
            jobID: jobID
        )
        let json = try encode(request)
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_run_preview(context, pointer, callback, userData)
        }
    }

    public func loadImages(
        paths: [URL],
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> ImageLoadResult {
        let request = ImageLoadRequest(paths: paths.map(\.path), settings: settings, jobID: jobID)
        let json = try encode(request)
        return try callImageLoad(json: json, progress: progress) { pointer, callback, userData in
            myptgui_load_images(context, pointer, callback, userData)
        }
    }

    /// Loads one source image through an isolated preview context. Full RAW
    /// requests retain native 16-bit samples until RGBA conversion so the
    /// viewer does not allocate a second full-size float RGB raster.
    public func loadSourcePreview(
        path: URL,
        maxSide: Int = 2400,
        fullResolution: Bool,
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> SourcePreviewImage {
        let loadRequest = SourcePreviewLoadRequest(
            path: path.path,
            maxSide: max(1, maxSide),
            fullResolution: fullResolution,
            rawHalfSize: !fullResolution,
            jobID: jobID
        )
        let loadJSON = try encode(loadRequest)
        let response = try callImageLoad(json: loadJSON, progress: progress) { pointer, callback, userData in
            myptgui_load_source_preview(context, pointer, callback, userData)
        }
        guard let info = response.images.first else {
            throw NativeEngineError.engineFailure("Source preview returned no image information.")
        }
        guard info.status == .loaded else {
            throw NativeEngineError.engineFailure(
                info.unsupportedReason ?? "Source preview could not decode the image."
            )
        }
        defer {
            info.handle.withCString { myptgui_release_image(context, $0) }
        }

        let pixelJSON = try encode(SourcePreviewPixelRequest(settings: settings, jobID: jobID))
        let buffer = info.handle.withCString { handlePointer in
            pixelJSON.withCString { requestPointer in
                myptgui_copy_image_rgba(context, handlePointer, requestPointer)
            }
        }
        defer { myptgui_free_pixel_buffer(buffer) }
        guard let dataPointer = buffer.data, buffer.byteCount > 0 else {
            throw NativeEngineError.engineFailure(
                "Source preview conversion was cancelled or returned no pixels."
            )
        }
        return SourcePreviewImage(
            pixels: PixelBufferInfo(
                data: Data(bytes: dataPointer, count: buffer.byteCount),
                width: Int(buffer.width),
                height: Int(buffer.height),
                bytesPerRow: Int(buffer.bytesPerRow)
            ),
            imageInfo: info,
            isFullResolution: fullResolution
        )
    }

    public func runPreviewFromLoadedImages(
        imageHandles: [String],
        paths: [URL],
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        guard imageHandles.count == paths.count else {
            throw NativeEngineError.engineFailure("Loaded image handle count does not match requested path count.")
        }
        let request = ContactSheetRequest(
            paths: paths.map(\.path),
            imageHandles: imageHandles,
            projection: settings.projection,
            settings: settings,
            jobID: jobID
        )
        let json = try encode(request)
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_run_preview_from_handles(context, pointer, callback, userData)
        }
    }

    public func renderContactSheetPreview(
        imageHandles: [String],
        paths: [URL],
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        try runPreviewFromLoadedImages(
            imageHandles: imageHandles,
            paths: paths,
            settings: settings,
            jobID: jobID,
            progress: progress
        )
    }

    public func copyImageRGBA(imageHandle: String, settings: StitchSettings) throws -> PixelBufferInfo? {
        let json = try encode(settings)
        let buffer = imageHandle.withCString { handlePointer in
            json.withCString { requestPointer in
                myptgui_copy_image_rgba(context, handlePointer, requestPointer)
            }
        }
        defer { myptgui_free_pixel_buffer(buffer) }
        guard let dataPointer = buffer.data, buffer.byteCount > 0 else {
            return nil
        }
        return PixelBufferInfo(
            data: Data(bytes: dataPointer, count: buffer.byteCount),
            width: Int(buffer.width),
            height: Int(buffer.height),
            bytesPerRow: Int(buffer.bytesPerRow)
        )
    }

    public func copyImageLinearRGB(imageHandle: String) -> LinearPixelBufferInfo? {
        let buffer = imageHandle.withCString { handlePointer in
            myptgui_copy_image_linear_rgb(context, handlePointer)
        }
        defer { myptgui_free_float_pixel_buffer(buffer) }
        let expectedValues = Int(buffer.width) * Int(buffer.height) * Int(buffer.channels)
        guard let dataPointer = buffer.data,
              buffer.valueCount == expectedValues,
              expectedValues > 0,
              buffer.channels == 3 else {
            return nil
        }
        return LinearPixelBufferInfo(
            data: Data(bytes: dataPointer, count: expectedValues * MemoryLayout<Float>.size),
            width: Int(buffer.width),
            height: Int(buffer.height),
            channels: Int(buffer.channels)
        )
    }

    public func decodeRawLinearRGB16(
        path: URL,
        outputURL: URL,
        halfSize: Bool,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> Raw16SpoolResult {
        let request = Raw16SpoolRequest(
            path: path.path,
            outputPath: outputURL.path,
            halfSize: halfSize,
            jobID: jobID
        )
        let json = try encode(request)
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }
        let raw: UnsafeMutablePointer<CChar>? = json.withCString { pointer in
            myptgui_decode_raw_linear_rgb16_to_file(
                context,
                pointer,
                NativeEngineBridge.progressTrampoline,
                userData
            )
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("RAW spool response is not UTF-8")
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Raw16SpoolResult.self, from: data)
        } catch {
            if let operation = try? decoder.decode(EngineOperationResponse.self, from: data), !operation.success {
                throw NativeEngineError.engineFailure(operation.message)
            }
            throw NativeEngineError.decodingFailure("\(error.localizedDescription): \(text)")
        }
    }

    public func copyResultRGBA(resultHandle: String, settings: StitchSettings) throws -> PixelBufferInfo? {
        let json = try encode(settings)
        let buffer = resultHandle.withCString { handlePointer in
            json.withCString { requestPointer in
                myptgui_copy_result_rgba(context, handlePointer, requestPointer)
            }
        }
        defer { myptgui_free_pixel_buffer(buffer) }
        guard let dataPointer = buffer.data, buffer.byteCount > 0 else {
            return nil
        }
        return PixelBufferInfo(
            data: Data(bytes: dataPointer, count: buffer.byteCount),
            width: Int(buffer.width),
            height: Int(buffer.height),
            bytesPerRow: Int(buffer.bytesPerRow)
        )
    }

    public func rerenderFromControlPoints(
        result: StitchResult,
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        let request = ResultRequest(
            resultHandle: result.handle,
            settings: settings,
            exportSettings: nil,
            outputPath: nil,
            poseAdjustment: nil,
            quality: nil,
            controlPoints: result.controlPoints,
            jobID: jobID
        )
        let json = try encode(request)
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_rerender_from_control_points(context, pointer, callback, userData)
        }
    }

    public func refineAstroFullResolution(
        result: StitchResult,
        settings: StitchSettings,
        includeWorstStarPatches: Bool = false,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> AstroRefinementResponse {
        let selectedPairs = (result.diagnostics["selected_edges"]?.arrayValue ?? []).compactMap { edge -> AstroSelectedPairRequest? in
            guard let i = edge["i"]?.numberValue, let j = edge["j"]?.numberValue else {
                return nil
            }
            return AstroSelectedPairRequest(i: Int(i), j: Int(j))
        }
        let request = AstroRefinementRequest(
            paths: result.sourceImages.map(\.path),
            cameraParams: result.cameraParams,
            workingWidths: result.sourceImages.map(\.width),
            workingHeights: result.sourceImages.map(\.height),
            selectedPairs: selectedPairs,
            // Automatic draft correspondences preserve star identity while
            // full-resolution RAWs are re-decoded. The native refinement
            // re-centroids them and performs a fresh deterministic
            // train/held-out split; only the training side reaches Ceres.
            controlPoints: result.controlPoints,
            projection: result.projection,
            settings: settings,
            includeWorstStarPatches: includeWorstStarPatches,
            jobID: jobID
        )
        let json = try encode(request)
        return try callDecodable(json: json, progress: progress) { pointer, callback, userData in
            myptgui_refine_astro_full_resolution(context, pointer, callback, userData)
        }
    }

    public func applyAstroRefinement(
        to result: StitchResult,
        refinement: AstroRefinementResponse,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        let reportData = try JSONEncoder().encode(refinement.astroRefinement)
        guard let reportJSON = String(data: reportData, encoding: .utf8) else {
            throw NativeEngineError.encodingFailure("astro refinement report is not UTF-8")
        }
        let request = ApplyAstroRefinementRequest(
            resultHandle: result.handle,
            cameraParams: refinement.cameraParams,
            astroRefinementJSON: reportJSON,
            localWarp: refinement.localWarp,
            jobID: jobID
        )
        let json = try encode(request)
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_apply_astro_refinement(context, pointer, callback, userData)
        }
    }

    public func renderProjectionPreview(
        result: StitchResult,
        poseAdjustment: PoseAdjustment,
        quality: RenderQuality,
        settings: StitchSettings? = nil,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        let request = ResultRequest(
            resultHandle: result.handle,
            settings: settings,
            exportSettings: nil,
            outputPath: nil,
            poseAdjustment: poseAdjustment,
            quality: quality,
            controlPoints: nil,
            jobID: jobID
        )
        let json = try encode(request)
        if quality == .geometryCommit {
            return try callGeometryCommit(
                json: json,
                sourceResult: result,
                expectedPose: poseAdjustment,
                progress: progress
            ) { pointer, callback, userData in
                myptgui_render_projection_preview(context, pointer, callback, userData)
            }
        }
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_render_projection_preview(context, pointer, callback, userData)
        }
    }

    public func renderProjectionDragPreviewPixels(
        result: StitchResult,
        poseAdjustment: PoseAdjustment,
        settings: StitchSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> PixelBufferInfo? {
        let request = ResultRequest(
            resultHandle: result.handle,
            settings: settings,
            exportSettings: nil,
            outputPath: nil,
            poseAdjustment: poseAdjustment,
            quality: .dragPreview,
            controlPoints: nil,
            jobID: jobID
        )
        let json = try encode(request)
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }
        let buffer = json.withCString { pointer in
            myptgui_render_projection_drag_preview_rgba(
                context,
                pointer,
                NativeEngineBridge.progressTrampoline,
                userData
            )
        }
        defer { myptgui_free_pixel_buffer(buffer) }
        guard let dataPointer = buffer.data, buffer.byteCount > 0 else {
            return nil
        }
        return PixelBufferInfo(
            data: Data(bytes: dataPointer, count: buffer.byteCount),
            width: Int(buffer.width),
            height: Int(buffer.height),
            bytesPerRow: Int(buffer.bytesPerRow)
        )
    }

    public func exportFullResolution(
        result: StitchResult,
        outputURL: URL,
        settings: ExportSettings,
        jobID: UInt64? = nil,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> EngineOperationResponse {
        let request = ResultRequest(
            resultHandle: result.handle,
            settings: nil,
            exportSettings: settings,
            outputPath: outputURL.path,
            poseAdjustment: nil,
            quality: .export,
            controlPoints: nil,
            jobID: jobID
        )
        let json = try encode(request)
        return try call(json: json, progress: progress) { pointer, callback, userData in
            myptgui_export_full_resolution(context, pointer, callback, userData)
        }
    }

    public func renderImportedProject(
        request: ImportedPanoramaRenderRequest,
        progress: @escaping @Sendable (ProgressEvent) -> Void
    ) throws -> ImportedPanoramaRenderReport {
        let json = try encode(request)
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }
        let raw = json.withCString { pointer in
            myptgui_render_imported_project(
                context,
                pointer,
                NativeEngineBridge.progressTrampoline,
                userData
            )
        }
        guard let raw else { throw NativeEngineError.emptyResponse }
        defer { myptgui_free_string(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("imported-project response is not UTF-8")
        }
        do {
            let report = try JSONDecoder().decode(ImportedPanoramaRenderReport.self, from: data)
            if !report.success { throw NativeEngineError.engineFailure(report.message) }
            return report
        } catch let error as NativeEngineError {
            throw error
        } catch {
            if let fallback = try? JSONDecoder().decode(EngineOperationResponse.self, from: data),
               !fallback.success {
                throw NativeEngineError.engineFailure(fallback.message)
            }
            throw NativeEngineError.decodingFailure(error.localizedDescription)
        }
    }



    public func cancel(jobId: UInt64) {
        myptgui_cancel(context, jobId)
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NativeEngineError.encodingFailure("encoded request is not UTF-8")
            }
            return json
        } catch let error as NativeEngineError {
            throw error
        } catch {
            throw NativeEngineError.encodingFailure(error.localizedDescription)
        }
    }

    func call(
        json: String,
        progress: @escaping @Sendable (ProgressEvent) -> Void,
        invoke: (UnsafePointer<CChar>, MyPTGuiProgressCallback?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    ) throws -> EngineOperationResponse {
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }

        let raw: UnsafeMutablePointer<CChar>? = json.withCString { pointer in
            invoke(pointer, NativeEngineBridge.progressTrampoline, userData)
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }

        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("response is not UTF-8")
        }
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(EngineOperationResponse.self, from: data)
            if !response.success, response.result == nil {
                throw NativeEngineError.engineFailure(response.message)
            }
            return response
        } catch let error as NativeEngineError {
            throw error
        } catch {
            throw NativeEngineError.decodingFailure("\(error.localizedDescription): \(text)")
        }
    }

    func callDecodable<Response: Decodable>(
        json: String,
        progress: @escaping @Sendable (ProgressEvent) -> Void,
        invoke: (UnsafePointer<CChar>, MyPTGuiProgressCallback?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Response {
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }
        let raw = json.withCString { pointer in
            invoke(pointer, NativeEngineBridge.progressTrampoline, userData)
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("response is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            if let operation = try? JSONDecoder().decode(EngineOperationResponse.self, from: data), !operation.success {
                throw NativeEngineError.engineFailure(operation.message)
            }
            throw NativeEngineError.decodingFailure("\(error.localizedDescription): \(text)")
        }
    }

    func callGeometryCommit(
        json: String,
        sourceResult: StitchResult,
        expectedPose: PoseAdjustment,
        progress: @escaping @Sendable (ProgressEvent) -> Void,
        invoke: (UnsafePointer<CChar>, MyPTGuiProgressCallback?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    ) throws -> EngineOperationResponse {
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }

        let raw: UnsafeMutablePointer<CChar>? = json.withCString { pointer in
            invoke(pointer, NativeEngineBridge.progressTrampoline, userData)
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }

        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("geometry commit response is not UTF-8")
        }
        do {
            let wire = try JSONDecoder().decode(GeometryCommitWireResponse.self, from: data)
            guard wire.success else {
                throw NativeEngineError.engineFailure(wire.message)
            }
            guard let delta = wire.resultDelta else {
                throw NativeEngineError.decodingFailure("geometry commit response omitted result_delta")
            }
            let merged = try NativeEngineBridge.mergingGeometryCommitDelta(
                delta,
                into: sourceResult,
                expectedPose: expectedPose
            )
            return EngineOperationResponse(
                success: true,
                operation: wire.operation,
                message: wire.message,
                result: merged
            )
        } catch let error as NativeEngineError {
            throw error
        } catch {
            throw NativeEngineError.decodingFailure("\(error.localizedDescription): \(text)")
        }
    }

    static func mergingGeometryCommitDelta(
        _ delta: GeometryCommitResultDelta,
        into sourceResult: StitchResult,
        expectedPose: PoseAdjustment
    ) throws -> StitchResult {
        guard delta.schemaVersion == 1 else {
            throw NativeEngineError.decodingFailure(
                "unsupported geometry commit delta schema \(delta.schemaVersion)"
            )
        }
        guard delta.handle == sourceResult.handle else {
            throw NativeEngineError.decodingFailure(
                "geometry commit delta handle does not match the source result"
            )
        }
        guard !delta.cameraParams.isEmpty,
              delta.cameraParams.count == sourceResult.cameraParams.count else {
            throw NativeEngineError.decodingFailure(
                "geometry commit delta camera count does not match the source result"
            )
        }
        let poseTolerance = 1e-9
        guard abs(delta.poseAdjustment.pitchDegrees - expectedPose.pitchDegrees) <= poseTolerance,
              abs(delta.poseAdjustment.yawDegrees - expectedPose.yawDegrees) <= poseTolerance,
              abs(delta.poseAdjustment.rollDegrees - expectedPose.rollDegrees) <= poseTolerance else {
            throw NativeEngineError.decodingFailure(
                "geometry commit delta pose does not match the requested pose"
            )
        }
        guard case .object(var diagnostics) = sourceResult.diagnostics else {
            throw NativeEngineError.decodingFailure(
                "source result diagnostics are not an object"
            )
        }
        for (key, value) in delta.diagnosticsDelta {
            diagnostics[key] = value
        }

        var merged = sourceResult
        merged.projection = delta.projection
        merged.cameraParams = delta.cameraParams
        merged.diagnostics = .object(diagnostics)
        return merged
    }

    func callImageLoad(
        json: String,
        progress: @escaping @Sendable (ProgressEvent) -> Void,
        invoke: (UnsafePointer<CChar>, MyPTGuiProgressCallback?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    ) throws -> ImageLoadResult {
        let box = ProgressBox(callback: progress)
        let userData = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }

        let raw: UnsafeMutablePointer<CChar>? = json.withCString { pointer in
            invoke(pointer, NativeEngineBridge.progressTrampoline, userData)
        }
        guard let raw else {
            throw NativeEngineError.emptyResponse
        }
        defer { myptgui_free_string(raw) }

        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeEngineError.decodingFailure("response is not UTF-8")
        }
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(ImageLoadResult.self, from: data)
            if !response.success {
                throw NativeEngineError.engineFailure(response.message)
            }
            return response
        } catch let error as NativeEngineError {
            throw error
        } catch {
            if let operation = try? decoder.decode(EngineOperationResponse.self, from: data), !operation.success {
                throw NativeEngineError.engineFailure(operation.message)
            }
            throw NativeEngineError.decodingFailure("\(error.localizedDescription): \(text)")
        }
    }

    static let progressTrampoline: MyPTGuiProgressCallback = { stage, fraction, userData in
        guard let userData else {
            return
        }
        let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
        let stageText = stage.map(String.init(cString:)) ?? "Panorama engine"
        box.callback(ProgressEvent(stage: stageText, fraction: fraction))
    }
}

extension NativeEngineBridge: @unchecked Sendable {}
