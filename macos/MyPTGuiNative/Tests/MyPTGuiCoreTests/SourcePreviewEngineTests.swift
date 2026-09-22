import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MyPTGuiCore

final class SourcePreviewEngineTests: XCTestCase {
    @MainActor
    func testControllerUsesFourPreviewLRUAndIgnoresStaleSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myptgui-source-preview-lru-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try (0..<5).map { index -> PhotoAsset in
            let url = directory.appendingPathComponent("source-\(index).jpg")
            try writeOrientedJPEG(width: 320 + index, height: 180, orientation: 1, to: url)
            return PhotoAsset(url: url)
        }
        let controller = SourcePreviewController()
        let settings = StitchSettings()

        // Rapid replacement exercises versioning/cancellation; only the last
        // selected request may publish pixels.
        controller.synchronize(photos: photos, selectedPhotoID: photos[0].id, settings: settings)
        controller.synchronize(photos: photos, selectedPhotoID: photos[1].id, settings: settings)
        try await waitUntil {
            controller.selectedPhotoID == photos[1].id
                && controller.selectedPixels != nil
                && !controller.isLoading
        }

        for photo in photos[2...] {
            controller.synchronize(photos: photos, selectedPhotoID: photo.id, settings: settings)
            try await waitUntil {
                controller.selectedPhotoID == photo.id
                    && controller.selectedPixels != nil
                    && !controller.isLoading
            }
        }

        // IDs 1...4 occupy the four-entry LRU, so the first image must start
        // a new decode instead of publishing a stale/cached buffer.
        controller.synchronize(photos: photos, selectedPhotoID: photos[0].id, settings: settings)
        XCTAssertEqual(controller.selectedPhotoID, photos[0].id)
        XCTAssertNil(controller.selectedPixels)
        XCTAssertTrue(controller.isLoading)

        // Removing every photo cancels both selected and thumbnail work and
        // prevents their late completion from repopulating visible state.
        controller.synchronize(photos: [], selectedPhotoID: nil, settings: settings)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(controller.selectedPhotoID)
        XCTAssertNil(controller.selectedPixels)
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.thumbnailPixels.isEmpty)
    }

    func testProgressivePreviewPreservesOrientationCorrectOriginalDimensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myptgui-source-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("oriented.jpg")
        try writeOrientedJPEG(width: 640, height: 360, orientation: 6, to: sourceURL)

        var settings = StitchSettings()
        settings.displayStretch = false
        let engine = try NativeEngineBridge()
        let preview = try engine.loadSourcePreview(
            path: sourceURL,
            maxSide: 240,
            fullResolution: false,
            settings: settings,
            jobID: 41,
            progress: { _ in }
        )
        XCTAssertEqual(preview.imageInfo.originalWidth, 360)
        XCTAssertEqual(preview.imageInfo.originalHeight, 640)
        XCTAssertEqual(preview.imageInfo.width, preview.pixels.width)
        XCTAssertEqual(preview.imageInfo.height, preview.pixels.height)
        XCTAssertEqual(preview.pixels.width, 135)
        XCTAssertEqual(preview.pixels.height, 240)

        let full = try engine.loadSourcePreview(
            path: sourceURL,
            maxSide: 240,
            fullResolution: true,
            settings: settings,
            jobID: 42,
            progress: { _ in }
        )
        XCTAssertTrue(full.isFullResolution)
        XCTAssertEqual(full.pixels.width, 360)
        XCTAssertEqual(full.pixels.height, 640)
        XCTAssertEqual(full.imageInfo.originalWidth, full.pixels.width)
        XCTAssertEqual(full.imageInfo.originalHeight, full.pixels.height)
        XCTAssertEqual(full.pixels.data.count, full.pixels.bytesPerRow * full.pixels.height)
    }

    func testSourcePreviewHonorsCancellationBeforeDecode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myptgui-source-preview-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.jpg")
        try writeOrientedJPEG(width: 320, height: 180, orientation: 1, to: sourceURL)

        let engine = try NativeEngineBridge()
        engine.cancel(jobId: 99)
        XCTAssertThrowsError(
            try engine.loadSourcePreview(
                path: sourceURL,
                maxSide: 240,
                fullResolution: false,
                settings: StitchSettings(),
                jobID: 99,
                progress: { _ in }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("cancel"))
        }
    }

    private func writeOrientedJPEG(
        width: Int,
        height: Int,
        orientation: Int,
        to url: URL
    ) throws {
        var pixels = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 7 + y * 3) & 0xff)
                pixels[offset + 1] = UInt8((x * 2 + y * 11) & 0xff)
                pixels[offset + 2] = UInt8((x * 13 + y * 5) & 0xff)
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
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
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: CFDictionary = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.96,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for progressive source preview state.")
    }
}
