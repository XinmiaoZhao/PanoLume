import Foundation
import CoreGraphics
import ImageIO
import PanoLumeCore
import PanoLumeEngine

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct SourceCertificationFixture: Decodable {
    var schemaVersion: Int
    var certificationStatus: String
    var certifiedSourceCommit: String
    var certifiedSourceFingerprint: String
    var releaseReportSHA256: String
    var metalDylibSHA256: String
    var metalAPIVersion: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case certificationStatus = "certification_status"
        case certifiedSourceCommit = "certified_source_commit"
        case certifiedSourceFingerprint = "certified_source_fingerprint"
        case releaseReportSHA256 = "release_report_sha256"
        case metalDylibSHA256 = "metal_dylib_sha256"
        case metalAPIVersion = "metal_api_version"
    }
}

private func sourceCertificationFixture() throws -> SourceCertificationFixture {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent(
        "Docs/Certification/native-source-certification.json"
    )
    return try JSONDecoder().decode(
        SourceCertificationFixture.self,
        from: Data(contentsOf: url)
    )
}

private func isLowercaseHex(_ value: String, count: Int) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdef")
    return value.count == count
        && value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SelfTestFailure(description: message)
    }
}

func requireRuntimeParityGate(_ result: StitchResult, _ label: String, eligible: Bool = true) throws {
    let capabilities = try NativeEngineBridge.capabilities()
    let gate = ParityGate.evaluate(result: result)
    try require(
        gate.passed == (capabilities.nativeAlgorithmParity && eligible),
        "\(label) parity gate did not match runtime capabilities"
    )
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func settingsRoundTrip() throws {
    var settings = StitchSettings()
    settings.projection = "cylindrical"
    settings.optimizeDistortion = true
    settings.cameraModelGuidedRefinement = false
    settings.cameraModelGuidedMaxPointsPerPair = 17
    settings.cameraModelTextureRefinement = false
    settings.cameraModelTextureMaxPointsPerPair = 19
    settings.cameraModelTextureReprojectionPx = 6.5
    settings.starCoverageMultiplier = 1.5
    settings.starAdaptiveCoverageMultiplier = 4.5
    settings.cameraModelMaxHighConfidenceStarP95Px = 3.5
    settings.cameraModelMaxMutualStarP95Px = 10.5
    settings.cameraModelRobustReprojectionPx = 4.25
    settings.cameraModelRobustMinPairInliers = 7

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(StitchSettings.self, from: data)

    try require(decoded.projection == "cylindrical", "settings projection did not round-trip")
    try require(decoded.optimizeDistortion, "settings optimizeDistortion did not round-trip")
    try require(!decoded.cameraModelGuidedRefinement, "settings cameraModelGuidedRefinement did not round-trip")
    try require(decoded.cameraModelGuidedMaxPointsPerPair == 17, "settings cameraModelGuidedMaxPointsPerPair did not round-trip")
    try require(!decoded.cameraModelTextureRefinement, "settings cameraModelTextureRefinement did not round-trip")
    try require(decoded.cameraModelTextureMaxPointsPerPair == 19, "settings cameraModelTextureMaxPointsPerPair did not round-trip")
    try require(abs(decoded.cameraModelTextureReprojectionPx - 6.5) < 1e-9, "settings cameraModelTextureReprojectionPx did not round-trip")
    try require(abs(decoded.starCoverageMultiplier - 1.5) < 1e-9, "settings starCoverageMultiplier did not round-trip")
    try require(abs(decoded.starAdaptiveCoverageMultiplier - 4.5) < 1e-9, "settings starAdaptiveCoverageMultiplier did not round-trip")
    try require(abs(decoded.cameraModelMaxHighConfidenceStarP95Px - 3.5) < 1e-9, "settings cameraModelMaxHighConfidenceStarP95Px did not round-trip")
    try require(abs(decoded.cameraModelMaxMutualStarP95Px - 10.5) < 1e-9, "settings cameraModelMaxMutualStarP95Px did not round-trip")
    try require(abs(decoded.cameraModelRobustReprojectionPx - 4.25) < 1e-9, "settings cameraModelRobustReprojectionPx did not round-trip")
    try require(decoded.cameraModelRobustMinPairInliers == 7, "settings cameraModelRobustMinPairInliers did not round-trip")
    try require(decoded.blendMode == "feather", "default blend mode changed unexpectedly")
}

func sourceOwnershipCharacterization() throws {
    try require(
        panolume_source_ownership_characterization_self_test() == 1,
        "source ownership contract characterization failed"
    )
}

func ptsProjectionCharacterization() throws {
    try require(
        panolume_pts_projection_characterization_self_test() == 1,
        "PTS stereographic projection characterization failed"
    )
}

func parityComparatorRejectsQualityRegression() throws {
    let baseline = StitchMetrics(
        controlPointCount: 100,
        selectedEdges: 4,
        panoramaWidth: 4000,
        panoramaHeight: 1200,
        alignmentRMS: 0.8,
        alignmentP95: 1.5,
        bitDepth: 16,
        exportSeconds: 20,
        peakMemoryMB: 4000,
        highConfidenceStarCount: 200,
        highConfidenceStarP95: 2.0,
        mutualStarP95: 6.0
    )
    let candidate = StitchMetrics(
        controlPointCount: 80,
        selectedEdges: 3,
        panoramaWidth: 4000,
        panoramaHeight: 1200,
        alignmentRMS: 1.2,
        alignmentP95: 2.4,
        bitDepth: 8,
        exportSeconds: 40,
        peakMemoryMB: 9000,
        highConfidenceStarCount: 80,
        highConfidenceStarP95: 4.0,
        mutualStarP95: 9.0
    )

    let result = ParityComparator.compare(baseline: baseline, candidate: candidate)
    try require(!result.passed, "parity comparator accepted a worse candidate")
    try require(result.failures.count >= 5, "parity comparator did not report enough regression categories")
}

func parityComparatorRejectsMissingCandidateEvidence() throws {
    let baseline = StitchMetrics(
        controlPointCount: 20,
        selectedEdges: 2,
        panoramaWidth: 1000,
        panoramaHeight: 500,
        alignmentRMS: 0.8,
        alignmentP95: 1.4,
        bitDepth: 16,
        exportSeconds: 20,
        peakMemoryMB: 3000,
        highConfidenceStarCount: 100,
        highConfidenceStarP95: 2.0,
        mutualStarP95: 7.0
    )
    let candidate = StitchMetrics(
        controlPointCount: 20,
        selectedEdges: 2,
        panoramaWidth: 1000,
        panoramaHeight: 500
    )

    let result = ParityComparator.compare(baseline: baseline, candidate: candidate)
    try require(!result.passed, "parity comparator accepted missing candidate evidence")
    try require(result.failures.contains("alignment RMS missing in candidate"), "missing alignment RMS was not reported")
    try require(result.failures.contains("alignment P95 missing in candidate"), "missing alignment P95 was not reported")
    try require(result.failures.contains("bit depth missing in candidate"), "missing bit depth was not reported")
    try require(result.failures.contains("export time missing in candidate"), "missing export time was not reported")
    try require(result.failures.contains("peak memory missing in candidate"), "missing peak memory was not reported")
    try require(result.failures.contains("high-confidence star count missing in candidate"), "missing high-confidence star count was not reported")
    try require(result.failures.contains("high-confidence star P95 missing in candidate"), "missing high-confidence star P95 was not reported")
    try require(result.failures.contains("mutual star P95 missing in candidate"), "missing mutual star P95 was not reported")
}

func missingResultFailsGate() throws {
    let gate = ParityGate.evaluate(result: nil)
    try require(!gate.passed, "empty result passed parity gate")
    try require(gate.reason == "No stitch result exists.", "empty-result release-gate reason changed")
}

func engineCompletionGateBlocksIncompleteNativeResult() throws {
    let result = StitchResult(
        handle: "native-result-1",
        projection: "equirectangular",
        panorama: PanoramaInfo(width: 100, height: 50, channels: 3, bitDepth: 0),
        cameraParams: [],
        controlPoints: [],
        sourceImages: [],
        diagnostics: .object([
            "completion_gate": .object([
                "passed": .bool(false),
                "reason": .string("algorithm parity missing"),
                "missing_algorithms": .array([.string("bundle_adjustment")])
            ])
        ])
    )

    let gate = ParityGate.evaluate(result: result)
    try require(!gate.passed, "incomplete native result passed parity gate")
    try require(gate.reason == "algorithm parity missing", "engine parity reason was not propagated")
    try require(gate.missing.contains("bundle_adjustment"), "missing algorithm was not propagated")
}

func engineCompletionGateAcceptsCertifiedNativeResult() throws {
    let result = StitchResult(
        handle: "native-result-certified",
        projection: "equirectangular",
        panorama: PanoramaInfo(width: 100, height: 50, channels: 3, bitDepth: 16),
        cameraParams: [],
        controlPoints: [],
        sourceImages: [],
        diagnostics: .object([
            "completion_gate": .object([
                "passed": .bool(true),
                "reason": .string("release-certified"),
                "missing_algorithms": .array([])
            ])
        ])
    )

    try require(ParityGate.evaluate(result: result).passed, "release-certified native result did not pass without a per-result checklist")
    let incompleteChecklist = ParityChecklist(alignmentQuality: true)
    let checked = ParityGate.evaluate(result: result, checklist: incompleteChecklist)
    try require(!checked.passed, "explicit incomplete checklist did not fail closed")
    try require(checked.missing.contains("seam quality"), "explicit checklist failure did not report missing seam quality")
}

func capabilitiesExposeNativeParity() throws {
    let capabilities = try NativeEngineBridge.capabilities()
    let certification = try sourceCertificationFixture()
    try require(capabilities.swiftuiShell, "SwiftUI shell capability is false")
    try require(capabilities.cABIFacade, "C ABI facade capability is false")
    try require(capabilities.standardImageIO == true, "standard ImageIO capability is false")
    try require(capabilities.displayStretch == true, "display stretch capability is false")
    if capabilities.dependencies["ceres"] == true {
        try require(capabilities.ceresRotationCameraAdjustmentPreview == true, "Ceres camera adjustment preview capability is false")
        try require(capabilities.nativeBrownConradyDistortionAdjustmentPreview == true, "Brown-Conrady distortion adjustment preview capability is false")
        try require(capabilities.nativeMultiRoundRobustCameraFilter == true, "multi-round robust camera filter capability is false")
        if capabilities.dependencies["opencv"] == true {
            try require(capabilities.nativeGuidedStarRefinementPreview == true, "guided star refinement preview capability is false")
            try require(capabilities.nativeTextureSIFTRefinementPreview == true, "texture SIFT refinement preview capability is false")
        }
    }
    if capabilities.dependencies["opencv"] == true {
        try require(capabilities.nativeCameraProjectionPreview == true, "native camera projection preview capability is false")
        try require(capabilities.nativeCPUMultibandBlendingPreview == true, "CPU multiband blending preview capability is false")
    }
    if capabilities.dependencies["libtiff"] == true {
        try require(capabilities.nativePreviewTIFFExportDiagnostic == true, "preview TIFF diagnostic export capability is false")
        try require(capabilities.nativeExportPeakMemoryDiagnostic == true, "export peak-memory diagnostic capability is false")
        if capabilities.dependencies["opencv"] == true {
            try require(capabilities.nativePreviewCameraStripTIFFExportDiagnostic == true, "preview camera strip TIFF diagnostic export capability is false")
            try require(capabilities.nativeExportOverlapSeamDiagnostic == true, "export overlap seam diagnostic capability is false")
            if capabilities.dependencies["libraw"] == true {
                try require(capabilities.nativeFullresCameraStripTIFFExportDiagnostic == true, "full-res camera strip TIFF diagnostic export capability is false")
            }
        }
    }
    try require(!capabilities.pythonRuntimeDependency, "native path reports a Python runtime dependency")
    try require(capabilities.nativeDependenciesAvailable != nil, "capabilities did not separate native dependency availability")
    try require(capabilities.nativeQualityGateAvailable != nil, "capabilities did not expose native quality gate availability")
    if capabilities.nativeMetalRendererAvailable == true {
        try require(capabilities.nativeMetalRendererAPICompatible == true, "available Metal renderer did not report a compatible API")
        try require(
            capabilities.nativeMetalRendererAPIVersion == NativeEngineBridge.currentMetalRendererAPIVersion,
            "available Metal renderer did not report the current coverage-buffer API"
        )
    }
    try require(
        !capabilities.pysideReferenceRequired,
        "archived PySide parity must not be a current release dependency"
    )
    if capabilities.nativeAlgorithmParity {
        try require(capabilities.missingAlgorithms.isEmpty, "certified native parity still reports missing algorithms")
    } else {
        try require(!capabilities.missingAlgorithms.isEmpty, "unavailable runtime parity did not explain its missing requirement")
    }
    try require(certification.schemaVersion == 2, "source certification schema is not v2")
    if certification.certificationStatus == "uncertified" {
        try require(!capabilities.nativeAlgorithmParity, "unpromoted source unexpectedly opened production export")
        try require(certification.certifiedSourceCommit == "uncertified", "unexpected unpromoted commit")
        try require(certification.certifiedSourceFingerprint == "uncertified", "unexpected unpromoted fingerprint")
        try require(certification.releaseReportSHA256 == "uncertified", "unexpected unpromoted report")
        try require(certification.metalDylibSHA256 == "uncertified", "unexpected unpromoted Metal identity")
        try require(certification.metalAPIVersion == 0, "unpromoted manifest must not certify a Metal API")
    } else {
        try require(certification.certificationStatus == "certified", "unrecognized certification state")
    try require(isLowercaseHex(certification.certifiedSourceCommit, count: 40), "certified source commit is malformed")
    try require(isLowercaseHex(certification.certifiedSourceFingerprint, count: 64), "certified source fingerprint is malformed")
    try require(isLowercaseHex(certification.releaseReportSHA256, count: 64), "certified release report SHA is malformed")
    try require(isLowercaseHex(certification.metalDylibSHA256, count: 64), "certified Metal SHA is malformed")
    try require(certification.metalAPIVersion > 0, "certified Metal API is malformed")
    }
    try require(capabilities.nativeParityCertifiedSourceCommit == certification.certifiedSourceCommit, "runtime source certification differs from the manifest")
    try require(capabilities.nativeParityReleaseReportSHA256 == certification.releaseReportSHA256, "runtime release report certification differs from the manifest")
    try require(capabilities.nativeParityMetalDylibSHA256 == certification.metalDylibSHA256, "runtime Metal certification differs from the manifest")
    try require(capabilities.nativeParityMetalAPIVersion == certification.metalAPIVersion, "runtime certified Metal API differs from the manifest")
    if certification.metalAPIVersion == NativeEngineBridge.currentMetalRendererAPIVersion {
        try require(capabilities.nativeParityReleaseIdentityAvailable == true, "generated release identity is unavailable")
    } else {
        try require(capabilities.nativeParityReleaseIdentityAvailable == false, "obsolete Metal certification did not fail closed")
        try require(!capabilities.nativeAlgorithmParity, "obsolete Metal certification unexpectedly opened runtime parity")
    }
    try require(capabilities.nativeParityCertifiedEngineSourceFingerprint == certification.certifiedSourceFingerprint, "runtime certified fingerprint differs from the manifest")
    if let currentFingerprint = capabilities.nativeEngineSourceFingerprint {
        try require(isLowercaseHex(currentFingerprint, count: 64), "runtime source fingerprint is malformed")
        if currentFingerprint != certification.certifiedSourceFingerprint {
            try require(!capabilities.nativeAlgorithmParity, "source mismatch did not fail runtime parity closed")
        }
        if capabilities.nativeAlgorithmParity {
            try require(currentFingerprint == certification.certifiedSourceFingerprint, "open parity gate has mismatched source identity")
        }
    } else {
        try require(!capabilities.nativeAlgorithmParity, "missing source fingerprint did not fail runtime parity closed")
    }
    try require(capabilities.dependencyReport != nil, "capabilities did not include dependency_report")
}

func dependencyReportIsStructured() throws {
    let report = try NativeEngineBridge.dependencyReport()
    try require(report.schemaVersion == 1, "dependency report schema version changed")
    try require(report.requiredForParity.contains(.opencv), "OpenCV is not listed as required for parity")
    try require(report.requiredForParity.contains(.libraw), "LibRaw is not listed as required for parity")
    try require(report.status(for: .opencv) != nil, "OpenCV dependency status is missing")
    try require(report.status(for: .metal)?.requiredForParity == false, "Metal should not be a hard parity dependency while CPU fallback exists")
    for kind in [NativeDependencyKind.opencv, .libraw, .ceres, .libtiff] {
        if report.status(for: kind)?.headerAvailable == true {
            try require(report.status(for: kind)?.runtimeAvailable == true, "directly linked \(kind.rawValue) runtime was not reported available")
        }
    }
    if !report.allRequiredAvailable {
        try require(report.status == "missing_required_dependencies", "missing dependency report status is not explicit")
    }
}

func metalRendererPathResolutionSupportsStandaloneAppBundle() throws {
    let bundleRoot = URL(fileURLWithPath: "/Users/example/Applications/PanoLume Native.app")
    let executableURL = bundleRoot
        .appendingPathComponent("Contents")
        .appendingPathComponent("MacOS")
        .appendingPathComponent("PanoLume")
    let candidates = try NativeEngineBridge.metalRendererDylibCandidates(
        bundleRoot: bundleRoot,
        executableURL: executableURL
    )
    try require(
        candidates.contains("/Users/example/Applications/PanoLume Native.app/Contents/Resources/libpanolume_metal.dylib"),
        "standalone app Metal lookup omitted Contents/Resources"
    )
    try require(
        candidates.contains("/Users/example/Applications/PanoLume Native.app/Contents/Frameworks/libpanolume_metal.dylib"),
        "standalone app Metal lookup omitted Contents/Frameworks"
    )
    try require(
        candidates.contains("/Users/example/Applications/PanoLume Native.app/Contents/MacOS/libpanolume_metal.dylib"),
        "standalone app Metal lookup omitted the executable directory"
    )
    try require(candidates.count == Set(candidates).count, "Metal lookup candidates contain duplicates")
}

func makeFixture(_ name: String, type: CFString, width: Int = 4, height: Int = 2) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            rgba[offset + 0] = UInt8((20 + x * 30) % 256)
            rgba[offset + 1] = UInt8((30 + y * 50) % 256)
            rgba[offset + 2] = UInt8((40 + x * 20 + y * 10) % 256)
            rgba[offset + 3] = 255
        }
    }
    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw SelfTestFailure(description: "failed to create fixture data provider")
    }
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw SelfTestFailure(description: "failed to create fixture CGImage")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw SelfTestFailure(description: "failed to create fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SelfTestFailure(description: "failed to write fixture")
    }
    return url
}

func makeFeatureFixture(_ name: String, xOffset: Int, width: Int = 360, height: Int = 240) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let gx = x + xOffset
            let offset = (y * width + x) * 4
            let checker = ((gx / 11) + (y / 13)) % 2 == 0
            let dot = ((gx * 17 + y * 31) % 97) < 9
            rgba[offset + 0] = UInt8((checker ? 45 : 185) + (dot ? 45 : 0))
            rgba[offset + 1] = UInt8((checker ? 170 : 55) + (dot ? 30 : 0))
            rgba[offset + 2] = UInt8((gx * 3 + y * 5) % 220)
            rgba[offset + 3] = 255
        }
    }
    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw SelfTestFailure(description: "failed to create feature fixture provider")
    }
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw SelfTestFailure(description: "failed to create feature fixture image")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw SelfTestFailure(description: "failed to create feature fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SelfTestFailure(description: "failed to write feature fixture")
    }
    return url
}

func makeStarFixture(_ name: String, dx: Int, dy: Int, width: Int = 420, height: Int = 280) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: rgba.count, by: 4) {
        rgba[i + 0] = 3
        rgba[i + 1] = 3
        rgba[i + 2] = 4
        rgba[i + 3] = 255
    }

    var seed: UInt64 = 0x1234abcd
    var stars: [(Int, Int, Int)] = []
    while stars.count < 120 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = 45 + Int(seed % UInt64(width - 100))
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let y = 45 + Int(seed % UInt64(height - 90))
        let tooClose = stars.contains { sx, sy, _ in
            let ox = sx - x
            let oy = sy - y
            return ox * ox + oy * oy < 81
        }
        if tooClose {
            continue
        }
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        stars.append((x, y, 150 + Int(seed % 90)))
    }

    for (baseX, baseY, intensity) in stars {
        let cx = baseX + dx
        let cy = baseY + dy
        guard cx >= 4 && cy >= 4 && cx < width - 4 && cy < height - 4 else {
            continue
        }
        for yy in -3...3 {
            for xx in -3...3 {
                let distanceSquared = xx * xx + yy * yy
                guard distanceSquared <= 9 else {
                    continue
                }
                let value = max(0, intensity - distanceSquared * 24)
                let px = cx + xx
                let py = cy + yy
                let offset = (py * width + px) * 4
                rgba[offset + 0] = UInt8(min(255, Int(rgba[offset + 0]) + value))
                rgba[offset + 1] = UInt8(min(255, Int(rgba[offset + 1]) + value))
                rgba[offset + 2] = UInt8(min(255, Int(rgba[offset + 2]) + value))
            }
        }
    }

    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw SelfTestFailure(description: "failed to create star fixture provider")
    }
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw SelfTestFailure(description: "failed to create star fixture image")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw SelfTestFailure(description: "failed to create star fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SelfTestFailure(description: "failed to write star fixture")
    }
    return url
}

func makeAdaptiveCoverageStarFixture(_ name: String, dx: Int, dy: Int, width: Int = 420, height: Int = 280) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: rgba.count, by: 4) {
        rgba[i + 0] = 2
        rgba[i + 1] = 2
        rgba[i + 2] = 3
        rgba[i + 3] = 255
    }

    var stars: [(Int, Int, Int)] = []
    for row in 0..<3 {
        for col in 0..<4 {
            stars.append((58 + col * 15, 58 + row * 14, 245 - row * 7 - col * 3))
        }
    }

    var seed: UInt64 = 0x7654fedc
    while stars.count < 112 {
        seed = seed &* 2862933555777941757 &+ 3037000493
        let x = 42 + Int(seed % UInt64(width - 84))
        seed = seed &* 2862933555777941757 &+ 3037000493
        let y = 42 + Int(seed % UInt64(height - 84))
        let tooClose = stars.contains { sx, sy, _ in
            let ox = sx - x
            let oy = sy - y
            return ox * ox + oy * oy < 144
        }
        if tooClose {
            continue
        }
        seed = seed &* 2862933555777941757 &+ 3037000493
        stars.append((x, y, 95 + Int(seed % 35)))
    }

    for (baseX, baseY, intensity) in stars {
        let cx = baseX + dx
        let cy = baseY + dy
        guard cx >= 4 && cy >= 4 && cx < width - 4 && cy < height - 4 else {
            continue
        }
        for yy in -3...3 {
            for xx in -3...3 {
                let distanceSquared = xx * xx + yy * yy
                guard distanceSquared <= 9 else {
                    continue
                }
                let value = max(0, intensity - distanceSquared * 23)
                let px = cx + xx
                let py = cy + yy
                let offset = (py * width + px) * 4
                rgba[offset + 0] = UInt8(min(255, Int(rgba[offset + 0]) + value))
                rgba[offset + 1] = UInt8(min(255, Int(rgba[offset + 1]) + value))
                rgba[offset + 2] = UInt8(min(255, Int(rgba[offset + 2]) + value))
            }
        }
    }

    let data = Data(rgba)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw SelfTestFailure(description: "failed to create adaptive star fixture provider")
    }
    guard let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw SelfTestFailure(description: "failed to create adaptive star fixture image")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw SelfTestFailure(description: "failed to create adaptive star fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SelfTestFailure(description: "failed to write adaptive star fixture")
    }
    return url
}

func standardImageLoadFromGeneratedFixtures() throws {
    let png = try makeFixture("panolume_native_fixture.png", type: "public.png" as CFString)
    let tiff = try makeFixture("panolume_native_fixture.tiff", type: "public.tiff" as CFString)
    let engine = try NativeEngineBridge()
    let result = try engine.loadImages(paths: [png, tiff], settings: StitchSettings(), progress: { _ in })

    try require(result.images.count == 2, "expected two loaded fixture images")
    try require(result.images.allSatisfy { $0.status == .loaded }, "standard fixture images did not load")
    try require(result.images.allSatisfy { $0.width == 4 && $0.height == 2 }, "fixture dimensions were not preserved")
    try require(result.images.allSatisfy { $0.originalWidth == 4 && $0.originalHeight == 2 }, "fixture original dimensions were not preserved")
}

func progressiveSourcePreviewPreservesFullSizeAndCancellation() throws {
    let png = try makeFixture(
        "panolume_native_source_preview.png",
        type: "public.png" as CFString,
        width: 80,
        height: 40
    )
    var settings = StitchSettings()
    settings.displayStretch = false
    let engine = try NativeEngineBridge()
    let preview = try engine.loadSourcePreview(
        path: png,
        maxSide: 20,
        fullResolution: false,
        settings: settings,
        jobID: 7001,
        progress: { _ in }
    )
    try require(preview.pixels.width == 20 && preview.pixels.height == 10, "source preview size cap changed")
    try require(preview.imageInfo.originalWidth == 80 && preview.imageInfo.originalHeight == 40, "source preview lost original dimensions")
    let full = try engine.loadSourcePreview(
        path: png,
        maxSide: 20,
        fullResolution: true,
        settings: settings,
        jobID: 7002,
        progress: { _ in }
    )
    try require(full.pixels.width == 80 && full.pixels.height == 40, "full source preview was unexpectedly downsampled")
    engine.cancel(jobId: 7003)
    do {
        _ = try engine.loadSourcePreview(
            path: png,
            maxSide: 20,
            fullResolution: false,
            settings: settings,
            jobID: 7003,
            progress: { _ in }
        )
        throw SelfTestFailure(description: "cancelled source preview unexpectedly completed")
    } catch let error as NativeEngineError {
        try require(error.localizedDescription.lowercased().contains("cancel"), "source preview cancellation reason was not explicit")
    }
}

func starAsterismPreviewProducesControlPoints() throws {
    let left = try makeStarFixture("panolume_native_stars_left.png", dx: 0, dy: 0)
    let right = try makeStarFixture("panolume_native_stars_right.png", dx: 26, dy: -13)
    var settings = StitchSettings()
    settings.alignmentMode = "stars"
    settings.blendMode = "multiband"
    settings.displayStretch = false
    settings.optimizeDistortion = true
    let engine = try NativeEngineBridge()
    let response = try engine.runPreview(
        paths: [left, right],
        settings: settings,
        progress: { _ in }
    )
    let result = try requireResult(response.result)

    try require(result.diagnostics["alignment_family"]?.stringValue == "stars", "star preview did not select the star matcher")
    try require(result.controlPoints.count >= 8, "star preview produced too few control points")
    try require(result.diagnostics["selected_edges"]?.arrayValue?.first?["method"]?.stringValue == "stars", "selected edge is not marked as stars")
    try require(result.diagnostics["selected_edges"]?.arrayValue?.first?["coverage_quality"] != nil, "selected edge missing coverage diagnostics")
    try require(result.diagnostics["star_projection_alignment"]?["high_confidence"]?["p95"]?.numberValue != nil, "star projection high-confidence P95 missing")
    try require(result.diagnostics["star_projection_alignment"]?["mutual"]?["p95"]?.numberValue != nil, "star projection mutual P95 missing")
    try require(result.cameraParams.count == 2, "star preview did not emit native camera params")
    try require(result.diagnostics["camera_model"]?["success"]?.boolValue == true, "native camera model did not report success")
    try require(result.diagnostics["camera_model"]?["distortion_optimized"]?.boolValue != nil, "camera model did not report whether draft distortion optimization ran")
    try require(result.diagnostics["camera_model"]?["optimized_distortion"]?["k1"]?.numberValue != nil, "camera model did not report its draft distortion parameter")
    try require(result.diagnostics["guided_star_refinement"]?["enabled"]?.boolValue == true, "guided star refinement did not run")
    try require((result.diagnostics["guided_star_refinement"]?["pairs"]?.arrayValue?.count ?? 0) >= 1, "guided star refinement did not report pair diagnostics")
    try require(result.diagnostics["texture_sift_refinement"]?["enabled"]?.boolValue == true, "texture SIFT refinement did not run")
    try require((result.diagnostics["texture_sift_refinement"]?["pairs"]?.arrayValue?.count ?? 0) >= 1, "texture SIFT refinement did not report pair diagnostics")
    try require((result.diagnostics["camera_model"]?["robust_reprojection_filter"]?["rounds"]?.numberValue ?? 0) >= 1, "robust camera filter was not attempted")
    try require(result.diagnostics["camera_model"]?["robust_reprojection_filter"]?["max_rounds"]?.numberValue == 3, "robust camera filter max rounds changed unexpectedly")
    try require(result.diagnostics["camera_model"]?["robust_reprojection_filter"]?["stop_reason"]?.stringValue?.isEmpty == false, "robust camera filter stop reason missing")
    try require(result.diagnostics["geometry"]?.stringValue == "camera", "star preview did not promote camera geometry")
    try require(
        ["draft_camera_preview", "camera_projection_preview"].contains(result.diagnostics["preview_status"]?.stringValue ?? ""),
        "star preview did not render a camera draft or final projection"
    )
    try require(result.diagnostics["blend_engine"]?.stringValue == "native_multiband", "multiband preview did not use the native multiband blender")
    try require(result.diagnostics["camera_projection_preview"]?["success"]?.boolValue == true, "camera projection preview did not report success")
    try require(result.diagnostics["camera_projection_preview"]?["primary_preview"]?.boolValue == true, "camera projection preview was not marked as primary")
    let pixels = try engine.copyResultRGBA(resultHandle: result.handle, settings: settings)
    try require(pixels != nil, "star result did not expose an RGBA preview buffer")
    let commitPose = PoseAdjustment(pitchDegrees: 1.25, yawDegrees: -2.0, rollDegrees: 0.5)
    let geometryCommit = try engine.renderProjectionPreview(
        result: result,
        poseAdjustment: commitPose,
        quality: .geometryCommit,
        settings: settings,
        progress: { _ in }
    )
    let committed = try requireResult(geometryCommit.result)
    let pixelsAfterCommit = try engine.copyResultRGBA(resultHandle: committed.handle, settings: settings)
    try require(committed.handle == result.handle, "geometry-only commit replaced the native result handle")
    try require(committed.panorama == result.panorama, "geometry-only commit changed panorama metadata")
    try require(committed.controlPoints == result.controlPoints, "geometry-only delta lost control points")
    try require(committed.sourceImages == result.sourceImages, "geometry-only delta lost source images")
    try require(committed.cameraParams != result.cameraParams, "geometry-only commit did not apply its pose")
    try require(committed.diagnostics["selected_edges"] == result.diagnostics["selected_edges"], "geometry-only delta lost diagnostics")
    try require(committed.diagnostics["projection_adjustment"]?["yaw_degrees"]?.numberValue == -2.0, "geometry-only delta did not merge its pose diagnostics")
    try require(pixelsAfterCommit == pixels, "geometry-only commit replaced the retained preview pixels")
    try requireRuntimeParityGate(committed, "geometry-only star projection commit")
    try requireRuntimeParityGate(result, "star preview")
}

func adaptiveCoverageStarMatcherReportsAccepted() throws {
    let left = try makeAdaptiveCoverageStarFixture("panolume_native_adaptive_stars_left.png", dx: 0, dy: 0)
    let right = try makeAdaptiveCoverageStarFixture("panolume_native_adaptive_stars_right.png", dx: 24, dy: -12)
    var settings = StitchSettings()
    settings.alignmentMode = "stars"
    settings.astroGeometry = "homography"
    settings.astroSkyMode = "full_frame"
    settings.displayStretch = false
    settings.maxMatchStars = 10
    settings.starCoverageMultiplier = 1.0
    settings.starAdaptiveCoverageMultiplier = 8.0
    settings.starAdaptiveMinBBoxArea = 0.16
    settings.starAdaptiveMinGridOccupancy = 0.80
    let engine = try NativeEngineBridge()
    let response = try engine.runPreview(
        paths: [left, right],
        settings: settings,
        progress: { _ in }
    )
    let result = try requireResult(response.result)
    let edge = result.diagnostics["selected_edges"]?.arrayValue?.first

    try require(result.diagnostics["alignment_family"]?.stringValue == "stars", "adaptive fixture did not use star alignment")
    try require(edge?["adaptive_coverage_attempted"]?.boolValue == true, "adaptive coverage was not attempted on low-coverage star match")
    try require(edge?["adaptive_coverage_accepted"]?.boolValue == true, "adaptive coverage candidate was not accepted")
    try require((edge?["adaptive_coverage_inliers"]?.numberValue ?? 0) >= Double(result.controlPoints.count), "adaptive coverage inlier count missing")
    let adaptiveGrid = edge?["adaptive_quality"]?["min_grid_occupancy"]?.numberValue ?? 0.0
    try require(adaptiveGrid >= 0.30, "accepted adaptive coverage did not meet the weak-edge grid floor")
}

func legacyVisibleStarMetricsDoNotDecideCameraSuccess() throws {
    let left = try makeStarFixture("panolume_native_camera_gate_left.png", dx: 0, dy: 0)
    let right = try makeStarFixture("panolume_native_camera_gate_right.png", dx: 26, dy: -13)
    var settings = StitchSettings()
    settings.alignmentMode = "stars"
    settings.astroGeometry = "camera"
    settings.displayStretch = false
    settings.optimizeDistortion = true
    settings.cameraModelMaxOptimizedRMSPx = 100.0
    settings.cameraModelMaxSelectedPairP95Px = 100.0
    settings.cameraModelMinHighConfidenceStars = 1
    settings.cameraModelMaxHighConfidenceStarP95Px = 0.000001
    settings.cameraModelMaxMutualStarP95Px = 0.000001
    let engine = try NativeEngineBridge()
    let response = try engine.runPreview(
        paths: [left, right],
        settings: settings,
        progress: { _ in }
    )
    let result = try requireResult(response.result)
    let reason = result.diagnostics["camera_model"]?["quality_gate_reason"]?.stringValue ?? ""
    let highP95 = result.diagnostics["star_projection_alignment"]?["high_confidence"]?["p95"]?.numberValue ?? -1.0
    let mutualP95 = result.diagnostics["star_projection_alignment"]?["mutual"]?["p95"]?.numberValue ?? -1.0

    try require(highP95 > settings.cameraModelMaxHighConfidenceStarP95Px, "legacy high-confidence diagnostic did not exercise its tiny threshold")
    try require(mutualP95 > settings.cameraModelMaxMutualStarP95Px, "legacy mutual diagnostic did not exercise its tiny threshold")
    try require(
        result.diagnostics["camera_model"]?["success"]?.boolValue == true,
        "legacy nearest/high-confidence/mutual thresholds still decided Camera success: reason=\(reason)"
    )
    try require(result.cameraParams.count == 2, "Camera draft omitted parameters after legacy metrics were demoted to diagnostics")
    try require(reason == "camera quality gate passed", "Camera gate did not report the independent quality path")
}

func homographyPreviewProducesResultPixels() throws {
    let left = try makeFeatureFixture("panolume_native_homography_left.png", xOffset: 0)
    let right = try makeFeatureFixture("panolume_native_homography_right.png", xOffset: 140)
    let engine = try NativeEngineBridge()
    let response = try engine.runPreview(
        paths: [left, right],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let result = try requireResult(response.result)

    try require(result.controlPoints.count >= 8, "homography preview produced too few control points")
    try require(result.diagnostics["selected_edges"]?.arrayValue?.count == 1, "homography preview did not select one edge")
    if result.cameraParams.count == result.sourceImages.count,
       result.diagnostics["camera_model"]?["success"]?.boolValue == true {
        try require(result.diagnostics["geometry"]?.stringValue == "camera", "native preview did not promote camera geometry")
        try require(result.diagnostics["preview_status"]?.stringValue == "camera_projection_preview", "native preview did not render camera projection")
        try require(result.diagnostics["camera_projection_preview"]?["primary_preview"]?.boolValue == true, "primary camera projection was not reported")
        try require(result.diagnostics["output_bounds"]?["width"]?.numberValue == Double(result.panorama.width), "primary camera output bounds width mismatch")
    } else {
        try require(result.diagnostics["preview_status"]?.stringValue == "homography_preview", "native preview did not use homography fallback")
    }
    let pixels = try engine.copyResultRGBA(resultHandle: result.handle, settings: StitchSettings())
    try require(pixels != nil, "homography result did not expose an RGBA preview buffer")
    try require(pixels?.width == result.panorama.width, "preview pixel width does not match result")
    try require(pixels?.height == result.panorama.height, "preview pixel height does not match result")
    if result.cameraParams.count == result.sourceImages.count,
       result.diagnostics["camera_model"]?["success"]?.boolValue == true {
        let projectionResponse = try engine.renderProjectionPreview(
            result: result,
            poseAdjustment: PoseAdjustment(),
            quality: .dragPreview,
            progress: { _ in }
        )
        let projection = try requireResult(projectionResponse.result)
        let projectionPixels = try engine.copyResultRGBA(resultHandle: projection.handle, settings: StitchSettings())
        try require(projectionPixels != nil, "projection preview did not expose an RGBA buffer")
        try require(projectionPixels?.width == projection.panorama.width, "projection preview pixel width mismatch")
        try require(projectionPixels?.height == projection.panorama.height, "projection preview pixel height mismatch")
        let secondProjectionResponse = try engine.renderProjectionPreview(
            result: result,
            poseAdjustment: PoseAdjustment(yawDegrees: 0.5),
            quality: .dragPreview,
            progress: { _ in }
        )
        let secondProjection = try requireResult(secondProjectionResponse.result)
        let staleProjectionPixels = try engine.copyResultRGBA(resultHandle: projection.handle, settings: StitchSettings())
        try require(staleProjectionPixels == nil, "stale drag projection preview handle was not released")
        let secondProjectionPixels = try engine.copyResultRGBA(resultHandle: secondProjection.handle, settings: StitchSettings())
        try require(secondProjectionPixels != nil, "latest drag projection preview did not expose an RGBA buffer")
        try require(secondProjection.diagnostics["geometry"]?.stringValue == "camera", "projection preview did not render camera geometry")
        try require(secondProjection.diagnostics["preview_status"]?.stringValue == "camera_projection_preview", "projection preview did not use camera projection status")
        try require(secondProjection.diagnostics["output_bounds"]?["width"]?.numberValue == Double(secondProjection.panorama.width), "camera projection output bounds width mismatch")
        try require(secondProjection.panorama.width == result.panorama.width, "projection drag changed the fixed canvas width")
        try require(secondProjection.panorama.height == result.panorama.height, "projection drag changed the fixed canvas height")
        if let pixels {
            var transparent = 0
            var opaque = 0
            for offset in stride(from: 3, to: pixels.data.count, by: 4) {
                if pixels.data[offset] == 0 { transparent += 1 }
                if pixels.data[offset] == 255 { opaque += 1 }
            }
            try require(transparent > 0 && opaque > 0, "camera preview did not preserve transparent coverage")
        }
        let dragPixels = try engine.renderProjectionDragPreviewPixels(
            result: result,
            poseAdjustment: PoseAdjustment(yawDegrees: 0.5),
            settings: StitchSettings(),
            progress: { _ in }
        )
        try require(dragPixels != nil, "non-persistent drag preview did not return pixels")
        try require(pixelSignature(dragPixels) != pixelSignature(pixels), "non-persistent drag preview did not change rendered pixels")
        let originalPixelsAfterDrag = try engine.copyResultRGBA(resultHandle: result.handle, settings: StitchSettings())
        try require(originalPixelsAfterDrag != nil, "non-persistent drag preview invalidated the original result handle")
    } else {
        var rejected = false
        do {
            _ = try engine.renderProjectionPreview(
                result: result,
                poseAdjustment: PoseAdjustment(yawDegrees: 0.5),
                quality: .dragPreview,
                progress: { _ in }
            )
        } catch {
            rejected = true
            try require(
                error.localizedDescription.contains("Homography diagnostics cannot be dragged"),
                "Homography drag rejection did not explain why projection is unavailable: \(error.localizedDescription)"
            )
        }
        try require(rejected, "Homography diagnostics unexpectedly allowed projection drag")
    }
    try requireRuntimeParityGate(result, "homography preview")
}

func previewResizing() throws {
    let png = try makeFixture("panolume_native_resize_fixture.png", type: "public.png" as CFString, width: 8, height: 4)
    var settings = StitchSettings()
    settings.previewMaxSide = 4
    let engine = try NativeEngineBridge()
    let result = try engine.loadImages(paths: [png], settings: settings, progress: { _ in })
    let image = try requireImage(result.images.first)

    try require(image.status == .loaded, "resize fixture did not load")
    try require(max(image.width, image.height) == 4, "previewMaxSide was not respected")
}

func displayStretchNumericBehavior() throws {
    let rgb: [Float] = [
        0.0, 0.0, 0.0,
        0.1, 0.1, 0.1,
        0.5, 0.5, 0.5,
        1.0, 1.0, 1.0
    ]
    let params = try requireStretch(DisplayStretch.computeParams(
        rgb: rgb,
        blackPercentile: 0,
        whitePercentile: 100,
        gamma: 1.0
    ))
    let stretched = DisplayStretch.apply(rgb: rgb, params: params, strength: 1.0)

    try require(abs(params.black - 0.1) < 1e-6, "stretch ignored zero filtering incorrectly")
    try require(abs(params.white - 1.0) < 1e-6, "stretch white percentile mismatch")
    try require(abs(Double(stretched[3]) - 0.0) < 1e-6, "black point stretch mismatch")
    try require(abs(Double(stretched[6]) - 0.4444444) < 1e-5, "midtone stretch mismatch")
}

func rawStatusReflectsLibRawAvailability() throws {
    let capabilities = try NativeEngineBridge.capabilities()
    let engine = try NativeEngineBridge()
    let result = try engine.loadImages(
        paths: [URL(fileURLWithPath: "/tmp/panolume_native_missing_raw.ARW")],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let image = try requireImage(result.images.first)

    if capabilities.dependencies["libraw"] == true {
        try require(image.status == .loadFailed, "missing RAW should fail through LibRaw when LibRaw is available")
        try require(image.unsupportedReason?.contains("LibRaw") == true, "LibRaw failure reason is not explicit")
    } else {
        try require(image.status == .unsupportedUntilLibraw, "RAW did not return unsupported_until_libraw")
        try require(image.unsupportedReason?.contains("LibRaw") == true, "RAW unsupported reason is not explicit")
    }
}

func contactSheetResultRemainsDiagnostic() throws {
    let png = try makeFixture("panolume_native_contact_a.png", type: "public.png" as CFString)
    let tiff = try makeFixture("panolume_native_contact_b.tiff", type: "public.tiff" as CFString)
    let engine = try NativeEngineBridge()
    let load = try engine.loadImages(paths: [png, tiff], settings: StitchSettings(), progress: { _ in })
    let response = try engine.renderContactSheetPreview(
        imageHandles: load.images.map(\.handle),
        paths: [png, tiff],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let result = try requireResult(response.result)

    try require(result.panorama.width > 0 && result.panorama.height > 0, "contact sheet dimensions are invalid")
    try require(result.diagnostics["geometry"]?.stringValue == "image_io_only", "contact sheet geometry marker missing")
    try requireRuntimeParityGate(result, "contact sheet", eligible: false)
}

func manifestValidationAndSummary() throws {
    let png = try makeFixture("panolume_native_manifest_fixture.png", type: "public.png" as CFString)
    let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_manifest.json")
    let manifest: [String: Any] = [
        "schema_version": 1,
        "name": "native-selftest-manifest",
        "description": "Self-test manifest with one runnable standard-image case and one skipped RAW case.",
        "cases": [
            [
                "id": "synthetic-standard",
                "title": "Synthetic standard image",
                "tags": ["synthetic", "standard"],
                "inputs": [
                    [
                        "path": png.path,
                        "kind": "standard_image",
                        "required": true
                    ]
                ],
                "expected_metrics": [
                    "min_control_points": 0,
                    "min_selected_edges": 0
                ]
            ],
            [
                "id": "optional-raw-baseline",
                "title": "Optional RAW baseline",
                "tags": ["raw", "optional"],
                "skip_reason": "RAW fixtures are not committed to the repository.",
                "inputs": [
                    [
                        "path": "/Volumes/baseline/optional.ARW",
                        "kind": "raw_image",
                        "required": false
                    ]
                ]
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: manifestURL)

    let validation = try BaselineManifestHarness.validate(manifestURL: manifestURL)
    try require(validation.passed, "self-test baseline manifest did not validate: \(validation.failures)")
    try require(validation.runnableCases == 1, "manifest runnable case count mismatch")
    try require(validation.skippedCases == 1, "manifest skipped case count mismatch")

    let summary = try BaselineManifestHarness.summarize(manifestURL: manifestURL)
    try require(summary.cases.count == 2, "manifest summary did not preserve cases")
    try require(summary.notes.contains { $0.contains("does not run Python") }, "manifest summary did not explain non-execution")
}

func runPreviewReturnsDiagnosticResultForMissingInputs() throws {
    let engine = try NativeEngineBridge()
    let progress = ProgressCounter()
    let response = try engine.runPreview(
        paths: [
            URL(fileURLWithPath: "/tmp/a.ARW"),
            URL(fileURLWithPath: "/tmp/b.ARW")
        ],
        settings: StitchSettings(),
        progress: { _ in progress.increment() }
    )

    try require(response.success, "preview response failed")
    let result = try requireResult(response.result)
    try requireRuntimeParityGate(result, "native preview", eligible: false)
    try require(result.sourceImages.count == 2, "preview did not preserve source image count")
    try require(progress.count > 0, "preview did not emit progress events")
}

func requireImage(_ image: NativeImageInfo?) throws -> NativeImageInfo {
    guard let image else {
        throw SelfTestFailure(description: "expected native image info")
    }
    return image
}

func requireStretch(_ params: StretchParams?) throws -> StretchParams {
    guard let params else {
        throw SelfTestFailure(description: "expected stretch params")
    }
    return params
}

func nativeDefaultExportHonorsFullResolutionGate() throws {
    let left = try makeStarFixture("panolume_native_default_export_left.png", dx: 0, dy: 0, width: 640, height: 420)
    let right = try makeStarFixture("panolume_native_default_export_right.png", dx: 30, dy: -14, width: 640, height: 420)
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_default_export.tiff")
    let engine = try NativeEngineBridge()
    let preview = try engine.runPreview(
        paths: [left, right],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let draft = try requireResult(preview.result)
    let refinement = try engine.refineAstroFullResolution(
        result: draft,
        settings: StitchSettings(),
        progress: { _ in }
    )
    guard refinement.passed else {
        do {
            _ = try engine.exportFullResolution(
                result: draft,
                outputURL: output,
                settings: ExportSettings(),
                progress: { _ in }
            )
        } catch NativeEngineError.engineFailure(let message) {
            try require(
                message.localizedCaseInsensitiveContains("refinement")
                    || message.localizedCaseInsensitiveContains("verified")
                    || message.localizedCaseInsensitiveContains("camera projection"),
                "production export rejection did not explain the full-resolution gate: \(message)"
            )
            return
        }
        throw SelfTestFailure(description: "production export opened after full-resolution refinement failed")
    }
    let applied = try engine.applyAstroRefinement(
        to: draft,
        refinement: refinement,
        progress: { _ in }
    )
    let result = try requireResult(applied.result)
    let response = try engine.exportFullResolution(
        result: result,
        outputURL: output,
        settings: ExportSettings(),
        progress: { _ in }
    )
    let exported = try requireResult(response.result)
    try require(response.success, "default production TIFF export did not report success")
    try require(FileManager.default.fileExists(atPath: output.path), "default production TIFF export did not write a file")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    try require((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0, "default production TIFF export wrote an empty file")
    try require(exported.diagnostics["export_profile"]?["mode"]?.stringValue == "production_fullres_camera_strip_tiff", "default production export profile missing production mode")
    try require(exported.diagnostics["export_profile"]?["renderer_used"]?.stringValue == "cpu", "default production export profile missing CPU renderer")
    try require(exported.diagnostics["export_profile"]?["writer"]?.stringValue == "libtiff_fullres_camera_strips", "default production export profile missing TIFF strip writer")
    try require(exported.diagnostics["export_profile"]?["cpu_fallback"]?.boolValue == false, "default production export should not report CPU fallback")
}

func nativeExportRejectsNonTIFFOutput() throws {
    let left = try makeStarFixture("panolume_native_reject_export_left.png", dx: 0, dy: 0, width: 640, height: 420)
    let right = try makeStarFixture("panolume_native_reject_export_right.png", dx: 30, dy: -14, width: 640, height: 420)
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_reject_export.png")
    let engine = try NativeEngineBridge()
    let preview = try engine.runPreview(
        paths: [left, right],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let result = try requireResult(preview.result)
    do {
        _ = try engine.exportFullResolution(
            result: result,
            outputURL: output,
            settings: ExportSettings(rendererBackend: "preview_tiff_diagnostic", bitDepth: 16),
            progress: { _ in }
        )
        throw SelfTestFailure(description: "native export accepted a non-TIFF output path")
    } catch NativeEngineError.engineFailure(let message) {
        try require(message.localizedCaseInsensitiveContains("TIFF"), "non-TIFF export failure did not mention TIFF")
    }
}

func nativeDiagnosticTIFFExportWritesPreview() throws {
    let left = try makeFeatureFixture("panolume_native_export_diag_left.png", xOffset: 0)
    let right = try makeFeatureFixture("panolume_native_export_diag_right.png", xOffset: 140)
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_export_diag.tiff")
    let engine = try NativeEngineBridge()
    let preview = try engine.runPreview(
        paths: [left, right],
        settings: StitchSettings(),
        progress: { _ in }
    )
    let result = try requireResult(preview.result)
    let response = try engine.exportFullResolution(
        result: result,
        outputURL: output,
        settings: ExportSettings(rendererBackend: "preview_tiff_diagnostic", bitDepth: 16),
        progress: { _ in }
    )
    let exported = try requireResult(response.result)
    try require(response.success, "diagnostic TIFF export did not report success")
    try require(FileManager.default.fileExists(atPath: output.path), "diagnostic TIFF export did not write a file")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    try require((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0, "diagnostic TIFF export wrote an empty file")
    try require(exported.diagnostics["export_profile"]?["writer"]?.stringValue == "libtiff_scanlines", "diagnostic TIFF export profile missing writer")
    try require((exported.diagnostics["export_profile"]?["peak_memory_mb"]?.numberValue ?? 0.0) > 0.0, "diagnostic TIFF export profile missing peak memory")
    try requireRuntimeParityGate(exported, "diagnostic TIFF export")
}

func nativeCameraStripTIFFExportRerendersPreviewGeometry() throws {
    let left = try makeStarFixture("panolume_native_export_strip_left.png", dx: 0, dy: 0)
    let right = try makeStarFixture("panolume_native_export_strip_right.png", dx: 26, dy: -13)
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_export_strip.tiff")
    var settings = StitchSettings()
    settings.alignmentMode = "stars"
    settings.displayStretch = false
    settings.optimizeDistortion = true

    let engine = try NativeEngineBridge()
    let preview = try engine.runPreview(
        paths: [left, right],
        settings: settings,
        progress: { _ in }
    )
    let draft = try requireResult(preview.result)
    let refinement = try engine.refineAstroFullResolution(
        result: draft,
        settings: settings,
        progress: { _ in }
    )
    guard refinement.passed else {
        do {
            _ = try engine.exportFullResolution(
                result: draft,
                outputURL: output,
                settings: ExportSettings(rendererBackend: "preview_camera_strip_tiff_diagnostic", bitDepth: 16),
                progress: { _ in }
            )
        } catch NativeEngineError.engineFailure(let message) {
            try require(message.localizedCaseInsensitiveContains("camera projection"), "camera-strip rejection did not explain its geometry requirement")
            return
        }
        throw SelfTestFailure(description: "camera-strip diagnostic export opened after refinement failed")
    }
    let applied = try engine.applyAstroRefinement(to: draft, refinement: refinement, progress: { _ in })
    let result = try requireResult(applied.result)
    try require(result.cameraParams.count == result.sourceImages.count, "camera strip TIFF export fixture did not produce camera params")
    let response = try engine.exportFullResolution(
        result: result,
        outputURL: output,
        settings: ExportSettings(rendererBackend: "preview_camera_strip_tiff_diagnostic", bitDepth: 16),
        progress: { _ in }
    )
    let exported = try requireResult(response.result)
    try require(response.success, "camera strip TIFF export did not report success")
    try require(FileManager.default.fileExists(atPath: output.path), "camera strip TIFF export did not write a file")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    try require((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0, "camera strip TIFF export wrote an empty file")
    try require(exported.diagnostics["export_profile"]?["writer"]?.stringValue == "libtiff_camera_strips", "camera strip TIFF export profile missing writer")
    try require(exported.diagnostics["export_profile"]?["mode"]?.stringValue == "preview_camera_strip_tiff_diagnostic", "camera strip TIFF export profile missing mode")
    try require((exported.diagnostics["export_profile"]?["peak_memory_mb"]?.numberValue ?? 0.0) > 0.0, "camera strip TIFF export profile missing peak memory")
    try require((exported.diagnostics["export_profile"]?["overlap_pixels"]?.numberValue ?? 0.0) > 0.0, "camera strip TIFF export profile missing overlap pixels")
    try require(exported.diagnostics["export_profile"]?["mean_overlap_absdiff"]?.numberValue != nil, "camera strip TIFF export profile missing overlap diff")
    try requireRuntimeParityGate(exported, "camera strip TIFF export")
}

func nativeFullresCameraStripTIFFExportReloadsAndScalesInputs() throws {
    let left = try makeStarFixture("panolume_native_export_fullres_strip_left.png", dx: 0, dy: 0, width: 840, height: 560)
    let right = try makeStarFixture("panolume_native_export_fullres_strip_right.png", dx: 52, dy: -26, width: 840, height: 560)
    let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panolume_native_export_fullres_strip.tiff")
    var settings = StitchSettings()
    settings.alignmentMode = "stars"
    settings.displayStretch = false
    settings.optimizeDistortion = true
    settings.previewMaxSide = 420

    let engine = try NativeEngineBridge()
    let preview = try engine.runPreview(
        paths: [left, right],
        settings: settings,
        progress: { _ in }
    )
    let draft = try requireResult(preview.result)
    let refinement = try engine.refineAstroFullResolution(
        result: draft,
        settings: settings,
        progress: { _ in }
    )
    guard refinement.passed else {
        do {
            _ = try engine.exportFullResolution(
                result: draft,
                outputURL: output,
                settings: ExportSettings(rendererBackend: "fullres_camera_strip_tiff_diagnostic", bitDepth: 16),
                progress: { _ in }
            )
        } catch NativeEngineError.engineFailure(let message) {
            try require(message.localizedCaseInsensitiveContains("camera projection"), "full-res camera-strip rejection did not explain its geometry requirement")
            return
        }
        throw SelfTestFailure(description: "full-res camera-strip diagnostic export opened after refinement failed")
    }
    let applied = try engine.applyAstroRefinement(to: draft, refinement: refinement, progress: { _ in })
    let result = try requireResult(applied.result)
    try require(result.cameraParams.count == result.sourceImages.count, "full-res camera strip TIFF export fixture did not produce camera params")
    let response = try engine.exportFullResolution(
        result: result,
        outputURL: output,
        settings: ExportSettings(
            maxOutputPixels: 0,
            maxOutputSide: 1600,
            rendererBackend: "fullres_camera_strip_tiff_diagnostic",
            bitDepth: 16,
            applyPreviewStretch: true,
            stretchStrength: 1.0,
            stretchBlackPercentile: 0.5,
            stretchWhitePercentile: 99.7,
            stretchGamma: 0.45
        ),
        progress: { _ in }
    )
    let exported = try requireResult(response.result)
    try require(response.success, "full-res camera strip TIFF export did not report success")
    try require(FileManager.default.fileExists(atPath: output.path), "full-res camera strip TIFF export did not write a file")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    try require((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0, "full-res camera strip TIFF export wrote an empty file")
    try require(exported.panorama.width > result.panorama.width, "full-res camera strip TIFF export did not increase output width")
    try require(exported.diagnostics["export_profile"]?["writer"]?.stringValue == "libtiff_fullres_camera_strips", "full-res camera strip TIFF export profile missing writer")
    try require(exported.diagnostics["export_profile"]?["mode"]?.stringValue == "fullres_camera_strip_tiff_diagnostic", "full-res camera strip TIFF export profile missing mode")
    try require(exported.diagnostics["export_profile"]?["full_resolution_source"]?.boolValue == true, "full-res camera strip TIFF export did not report full-resolution source")
    try require((exported.diagnostics["export_profile"]?["mean_camera_scale"]?.numberValue ?? 0.0) > 1.9, "full-res camera strip TIFF export did not scale camera focal length")
    try require((exported.diagnostics["export_profile"]?["peak_memory_mb"]?.numberValue ?? 0.0) > 0.0, "full-res camera strip TIFF export profile missing peak memory")
    try require((exported.diagnostics["export_profile"]?["operation_peak_rss_mb"]?.numberValue ?? 0.0) > 0.0, "full-res camera strip TIFF export profile missing operation peak RSS")
    try require(exported.diagnostics["export_profile"]?["operation_peak_rss_delta_mb"]?.numberValue != nil, "full-res camera strip TIFF export profile missing operation RSS delta")
    try require((exported.diagnostics["export_profile"]?["spool_bytes_peak"]?.numberValue ?? 0.0) > 0.0, "full-res camera strip TIFF export did not report RGB16 spools")
    try require(exported.diagnostics["export_profile"]?["active_source_leases_peak"]?.numberValue == 1.0, "bounded CPU export retained more than one source lease")
    try require(exported.diagnostics["export_profile"]?["cleanup_outcome"]?.stringValue == "completed", "full-res camera strip TIFF export did not confirm spool cleanup")
    try require(exported.diagnostics["export_profile"]?["overlap_metric_method"]?.stringValue == "streaming_composite", "full-res overlap metric did not report bounded streaming semantics")
    try require((exported.diagnostics["export_profile"]?["overlap_pixels"]?.numberValue ?? 0.0) > 0.0, "full-res camera strip TIFF export profile missing overlap pixels")
    try require(exported.diagnostics["export_profile"]?["mean_overlap_absdiff"]?.numberValue != nil, "full-res camera strip TIFF export profile missing overlap diff")
    try require(exported.diagnostics["export_profile"]?["preview_stretch_applied"]?.boolValue == true, "full-res camera strip TIFF export did not apply preview stretch")

    let lowBudgetOutput = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("panolume_native_export_low_budget.tiff")
    try? FileManager.default.removeItem(at: lowBudgetOutput)
    var rejectedLowBudget = false
    do {
        _ = try engine.exportFullResolution(
            result: result,
            outputURL: lowBudgetOutput,
            settings: ExportSettings(
                maxOutputSide: 1600,
                rendererBackend: "fullres_camera_strip_tiff_diagnostic",
                bitDepth: 16,
                workingSetBudgetMB: 1
            ),
            progress: { _ in }
        )
    } catch NativeEngineError.engineFailure(let message) {
        rejectedLowBudget = message.localizedCaseInsensitiveContains("working-set budget")
    }
    try require(rejectedLowBudget, "forced low working-set budget was not rejected before export")
    try require(!FileManager.default.fileExists(atPath: lowBudgetOutput.path), "low-budget rejection left an output file")
    try requireRuntimeParityGate(exported, "full-res camera strip TIFF export")
}

func requireResult(_ result: StitchResult?) throws -> StitchResult {
    guard let result else {
        throw SelfTestFailure(description: "expected a stitch result")
    }
    return result
}

func pixelSignature(_ pixels: PixelBufferInfo?) -> UInt64 {
    guard let pixels else {
        return 0
    }
    var hash: UInt64 = 1469598103934665603
    for byte in pixels.data.prefix(1_000_000) {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    hash ^= UInt64(pixels.width)
    hash = hash &* 1099511628211
    hash ^= UInt64(pixels.height)
    return hash
}

let tests: [(String, () throws -> Void)] = [
    ("settingsRoundTrip", settingsRoundTrip),
    ("sourceOwnershipCharacterization", sourceOwnershipCharacterization),
    ("ptsProjectionCharacterization", ptsProjectionCharacterization),
    ("parityComparatorRejectsQualityRegression", parityComparatorRejectsQualityRegression),
    ("parityComparatorRejectsMissingCandidateEvidence", parityComparatorRejectsMissingCandidateEvidence),
    ("missingResultFailsGate", missingResultFailsGate),
    ("engineCompletionGateBlocksIncompleteNativeResult", engineCompletionGateBlocksIncompleteNativeResult),
    ("engineCompletionGateAcceptsCertifiedNativeResult", engineCompletionGateAcceptsCertifiedNativeResult),
    ("capabilitiesExposeNativeParity", capabilitiesExposeNativeParity),
    ("dependencyReportIsStructured", dependencyReportIsStructured),
    ("metalRendererPathResolutionSupportsStandaloneAppBundle", metalRendererPathResolutionSupportsStandaloneAppBundle),
    ("standardImageLoadFromGeneratedFixtures", standardImageLoadFromGeneratedFixtures),
    ("progressiveSourcePreviewPreservesFullSizeAndCancellation", progressiveSourcePreviewPreservesFullSizeAndCancellation),
    ("starAsterismPreviewProducesControlPoints", starAsterismPreviewProducesControlPoints),
    ("adaptiveCoverageStarMatcherReportsAccepted", adaptiveCoverageStarMatcherReportsAccepted),
    ("legacyVisibleStarMetricsDoNotDecideCameraSuccess", legacyVisibleStarMetricsDoNotDecideCameraSuccess),
    ("homographyPreviewProducesResultPixels", homographyPreviewProducesResultPixels),
    ("previewResizing", previewResizing),
    ("displayStretchNumericBehavior", displayStretchNumericBehavior),
    ("rawStatusReflectsLibRawAvailability", rawStatusReflectsLibRawAvailability),
    ("contactSheetResultRemainsDiagnostic", contactSheetResultRemainsDiagnostic),
    ("manifestValidationAndSummary", manifestValidationAndSummary),
    ("runPreviewReturnsDiagnosticResultForMissingInputs", runPreviewReturnsDiagnosticResultForMissingInputs),
    ("nativeDefaultExportHonorsFullResolutionGate", nativeDefaultExportHonorsFullResolutionGate),
    ("nativeExportRejectsNonTIFFOutput", nativeExportRejectsNonTIFFOutput),
    ("nativeDiagnosticTIFFExportWritesPreview", nativeDiagnosticTIFFExportWritesPreview),
    ("nativeCameraStripTIFFExportRerendersPreviewGeometry", nativeCameraStripTIFFExportRerendersPreviewGeometry),
    ("nativeFullresCameraStripTIFFExportReloadsAndScalesInputs", nativeFullresCameraStripTIFFExportReloadsAndScalesInputs),
]

for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        fputs("FAIL \(name): \(error)\n", stderr)
        exit(1)
    }
}

print("PASS native self-test suite")
