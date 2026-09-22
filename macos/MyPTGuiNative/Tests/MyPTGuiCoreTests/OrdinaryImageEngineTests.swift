import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import MyPTGuiCore
import MyPTGuiRegressionSupport

final class OrdinaryImageEngineTests: XCTestCase {
    func testAutoPreviewKeepsOrdinaryOverlappingCropsOnAccurateHomography() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myptgui-ordinary-image-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixture = SyntheticStandardImageFixture.make()
        let reference = fixture.reference
        let cropURLs = try fixture.crops.enumerated().map { index, crop in
            let url = temporaryDirectory.appendingPathComponent("crop-\(index).png")
            try writePNG(crop.pixels, to: url)
            return url
        }

        var settings = StitchSettings()
        settings.alignmentMode = "auto"
        settings.astroGeometry = "auto"
        settings.displayStretch = false
        settings.previewMaxSide = 0
        settings.maxOutputPixels = 2_000_000
        settings.maxOutputSide = 2_000
        settings.blendMode = "feather"
        settings.previewRendererBackend = "cpu"

        let engine = try NativeEngineBridge()
        let response = try engine.runPreview(
            paths: cropURLs,
            settings: settings,
            progress: { _ in }
        )
        let result = try XCTUnwrap(response.result)

        XCTAssertEqual(result.diagnostics["geometry"]?.stringValue, "homography")
        XCTAssertEqual(result.diagnostics["preview_status"]?.stringValue, "homography_preview")
        let cameraModelAttempted = result.diagnostics["camera_model"]?["attempted"]?.boolValue
            ?? (result.diagnostics["camera_model"] != nil)
        XCTAssertFalse(cameraModelAttempted, "ordinary SIFT input unexpectedly entered camera optimization")

        let selectedEdges = try selectedEdgePairs(
            result.diagnostics["selected_edges"]?.arrayValue ?? [],
            imageCount: cropURLs.count
        )
        XCTAssertGreaterThanOrEqual(selectedEdges.count, cropURLs.count - 1)
        XCTAssertTrue(
            isConnected(imageCount: cropURLs.count, edges: selectedEdges),
            "selected-edge graph is disconnected: \(selectedEdges)"
        )

        for edge in selectedEdges {
            let errors = result.controlPoints.compactMap { point -> Double? in
                let pair = canonicalPair(point.imageAIndex, point.imageBIndex)
                return pair == edge && point.error.isFinite ? point.error : nil
            }.sorted()
            XCTAssertFalse(errors.isEmpty, "selected edge \(edge) has no residual evidence")
            let p95 = percentile(errors, fraction: 0.95)
            XCTAssertLessThanOrEqual(
                p95,
                0.5,
                "selected edge \(edge) P95 \(p95) px exceeds the ordinary-image threshold"
            )
        }

        let preview = try XCTUnwrap(
            engine.copyResultRGBA(resultHandle: result.handle, settings: settings)
        )
        let registration = SimilarityRegistrar.register(reference: reference, candidate: preview)
        XCTAssertGreaterThan(registration.heldOutSamples, 100)
        XCTAssertGreaterThanOrEqual(
            registration.heldOutScore,
            0.995,
            "held-out registered quality regressed; transform=\(registration.transform)"
        )

        let alignedReference = SimilarityRegistrar.warpReference(
            reference,
            transform: registration.transform,
            canvasWidth: preview.width,
            canvasHeight: preview.height
        )
        let finalScore = maskedLuminanceSSIM(reference: alignedReference, candidate: preview)
        XCTAssertGreaterThanOrEqual(finalScore, 0.995, "final registered SSIM regressed")
    }

    private func writePNG(_ pixels: PixelBufferInfo, to url: URL) throws {
        guard let provider = CGDataProvider(data: pixels.data as CFData),
              let image = CGImage(
                width: pixels.width,
                height: pixels.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func selectedEdgePairs(
        _ edges: [JSONValue],
        imageCount: Int
    ) throws -> [(Int, Int)] {
        try edges.map { edge in
            let first = try XCTUnwrap(edge["i"]?.numberValue.map { Int($0.rounded()) })
            let second = try XCTUnwrap(edge["j"]?.numberValue.map { Int($0.rounded()) })
            XCTAssertTrue((0..<imageCount).contains(first))
            XCTAssertTrue((0..<imageCount).contains(second))
            XCTAssertNotEqual(first, second)
            return canonicalPair(first, second)
        }
    }

    private func canonicalPair(_ first: Int, _ second: Int) -> (Int, Int) {
        (min(first, second), max(first, second))
    }

    private func isConnected(imageCount: Int, edges: [(Int, Int)]) -> Bool {
        guard imageCount > 0 else { return false }
        var adjacency = Array(repeating: [Int](), count: imageCount)
        for (first, second) in edges
            where adjacency.indices.contains(first) && adjacency.indices.contains(second) {
            adjacency[first].append(second)
            adjacency[second].append(first)
        }
        var visited: Set<Int> = [0]
        var queue = [0]
        while let current = queue.first {
            queue.removeFirst()
            for neighbor in adjacency[current] where visited.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        return visited.count == imageCount
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        precondition(!sorted.isEmpty)
        let position = Double(sorted.count - 1) * min(max(fraction, 0), 1)
        let low = Int(floor(position))
        let high = Int(ceil(position))
        if low == high { return sorted[low] }
        let alpha = position - Double(low)
        return sorted[low] * (1 - alpha) + sorted[high] * alpha
    }

    private func maskedLuminanceSSIM(
        reference: PixelBufferInfo,
        candidate: PixelBufferInfo
    ) -> Double {
        precondition(reference.width == candidate.width && reference.height == candidate.height)
        var count = 0.0
        var sumReference = 0.0
        var sumCandidate = 0.0
        var sumReferenceSquared = 0.0
        var sumCandidateSquared = 0.0
        var sumProduct = 0.0
        for y in 0..<candidate.height {
            for x in 0..<candidate.width {
                let referenceOffset = y * reference.bytesPerRow + x * 4
                let candidateOffset = y * candidate.bytesPerRow + x * 4
                let candidateValue = luminance(candidate, offset: candidateOffset)
                let referenceValue = luminance(reference, offset: referenceOffset)
                guard candidateValue > 2.0 / 255.0, referenceValue > 2.0 / 255.0 else { continue }
                count += 1
                sumReference += referenceValue
                sumCandidate += candidateValue
                sumReferenceSquared += referenceValue * referenceValue
                sumCandidateSquared += candidateValue * candidateValue
                sumProduct += referenceValue * candidateValue
            }
        }
        guard count > 1 else { return 0 }
        let meanReference = sumReference / count
        let meanCandidate = sumCandidate / count
        let denominator = count - 1
        let varianceReference = max(
            0,
            (sumReferenceSquared - count * meanReference * meanReference) / denominator
        )
        let varianceCandidate = max(
            0,
            (sumCandidateSquared - count * meanCandidate * meanCandidate) / denominator
        )
        let covariance = (sumProduct - count * meanReference * meanCandidate) / denominator
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        return ((2 * meanReference * meanCandidate + c1) * (2 * covariance + c2))
            / ((meanReference * meanReference + meanCandidate * meanCandidate + c1)
                * (varianceReference + varianceCandidate + c2))
    }

    private func luminance(_ pixels: PixelBufferInfo, offset: Int) -> Double {
        (0.2126 * Double(pixels.data[offset])
            + 0.7152 * Double(pixels.data[offset + 1])
            + 0.0722 * Double(pixels.data[offset + 2])) / 255.0
    }
}
