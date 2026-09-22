import XCTest
@testable import MyPTGuiCore

final class ProjectionRenderPolicyTests: XCTestCase {
    func testDragPreviewUsesImageCountQualityTiers() {
        let cases = [
            (count: 3, inputSide: 640, outputPixels: 900_000, outputSide: 2_560),
            (count: 4, inputSide: 480, outputPixels: 900_000, outputSide: 1_920),
            (count: 7, inputSide: 280, outputPixels: 320_000, outputSide: 960),
        ]

        for item in cases {
            var base = StitchSettings()
            base.previewMaxSide = 0
            base.maxOutputPixels = 0
            base.maxOutputSide = 0
            base.fullInputPreview = true
            base.blendMode = "feather"
            base.previewRendererBackend = "auto"

            let resolved = ProjectionRenderPolicy.settings(
                for: .dragPreview,
                imageCount: item.count,
                base: base
            )

            XCTAssertEqual(resolved.previewMaxSide, item.inputSide)
            XCTAssertEqual(resolved.maxOutputPixels, item.outputPixels)
            XCTAssertEqual(resolved.maxOutputSide, item.outputSide)
            XCTAssertFalse(resolved.fullInputPreview)
            XCTAssertEqual(resolved.blendMode, "fast")
            XCTAssertEqual(resolved.previewRendererBackend, "metal_fast")
        }
    }

    func testDragPreviewNeverRaisesUserLimits() {
        var base = StitchSettings()
        base.previewMaxSide = 180
        base.maxOutputPixels = 120_000
        base.maxOutputSide = 720

        let resolved = ProjectionRenderPolicy.settings(
            for: .dragPreview,
            imageCount: 7,
            base: base
        )

        XCTAssertEqual(resolved.previewMaxSide, 180)
        XCTAssertEqual(resolved.maxOutputPixels, 120_000)
        XCTAssertEqual(resolved.maxOutputSide, 720)
    }

    func testCommittedPreviewChoosesSupportedRenderer() {
        var automatic = StitchSettings()
        automatic.previewRendererBackend = "auto"
        XCTAssertEqual(
            ProjectionRenderPolicy.settings(
                for: .committedPreview,
                imageCount: 7,
                base: automatic
            ).previewRendererBackend,
            "metal_quality"
        )

        var multiband = StitchSettings()
        multiband.blendMode = "multiband"
        multiband.previewRendererBackend = "metal_quality"
        XCTAssertEqual(
            ProjectionRenderPolicy.settings(
                for: .committedPreview,
                imageCount: 7,
                base: multiband
            ).previewRendererBackend,
            "cpu"
        )
    }

    func testProjectionDefaultsBlendAfterDragAndGeometryCommitRoundTrips() throws {
        XCTAssertTrue(StitchSettings().blendAfterProjectionDrag)

        let encoded = try JSONEncoder().encode(RenderQuality.geometryCommit)
        XCTAssertEqual(try JSONDecoder().decode(RenderQuality.self, from: encoded), .geometryCommit)
    }
}
