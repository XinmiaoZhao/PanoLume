import Foundation
import XCTest
@testable import MyPTGuiCore

final class GeometryCommitDeltaTests: XCTestCase {
    func testGeometryDeltaMergePreservesHeavyResultCollections() throws {
        let originalCameras = [camera(rotation: [0, 0, 0]), camera(rotation: [0, 0.1, 0])]
        let adjustedCameras = [camera(rotation: [0.02, 0, 0]), camera(rotation: [0.02, 0.1, 0])]
        var controlPoints: [ControlPoint] = []
        controlPoints.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let x = Double(index % 500)
            let y = Double(index / 500)
            controlPoints.append(ControlPoint(
                imageAIndex: 0,
                imageBIndex: 1,
                xA: x,
                yA: y,
                xB: x + 2,
                yB: y - 1,
                error: 0.2
            ))
        }
        let sourceImages = [
            ResultSourceImage(
                handle: "image-0",
                path: "/tmp/a.raw",
                width: 6_000,
                height: 4_000,
                channels: 3,
                bitDepth: 16,
                status: .loaded,
                unsupportedReason: nil
            ),
            ResultSourceImage(
                handle: "image-1",
                path: "/tmp/b.raw",
                width: 6_000,
                height: 4_000,
                channels: 3,
                bitDepth: 16,
                status: .loaded,
                unsupportedReason: nil
            ),
        ]
        let source = StitchResult(
            handle: "result-1",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 2_000, height: 800, channels: 3, bitDepth: 16),
            cameraParams: originalCameras,
            controlPoints: controlPoints,
            sourceImages: sourceImages,
            diagnostics: .object([
                "geometry": .string("camera"),
                "blend_mode": .string("feather"),
                "selected_edges": .array([.object(["i": .number(0), "j": .number(1)])]),
                "completion_gate": .object(["passed": .bool(false)]),
            ])
        )
        let pose = PoseAdjustment(pitchDegrees: 2.5, yawDegrees: -4, rollDegrees: 0.75)
        let delta = GeometryCommitResultDelta(
            schemaVersion: 1,
            handle: source.handle,
            projection: "cylindrical",
            cameraParams: adjustedCameras,
            poseAdjustment: pose,
            diagnosticsDelta: [
                "projection": .string("cylindrical"),
                "blend_mode": .string("fast"),
                "projection_adjustment": .object([
                    "pitch_degrees": .number(2.5),
                    "yaw_degrees": .number(-4),
                    "roll_degrees": .number(0.75),
                ]),
            ]
        )

        let encodedDelta = try JSONEncoder().encode(delta)
        XCTAssertLessThan(encodedDelta.count, 4_096, "geometry delta unexpectedly includes heavy result data")

        let merged = try NativeEngineBridge.mergingGeometryCommitDelta(
            delta,
            into: source,
            expectedPose: pose
        )

        XCTAssertEqual(merged.handle, source.handle)
        XCTAssertEqual(merged.panorama, source.panorama)
        XCTAssertEqual(merged.controlPoints, controlPoints)
        XCTAssertEqual(merged.sourceImages, sourceImages)
        XCTAssertEqual(merged.cameraParams, adjustedCameras)
        XCTAssertEqual(merged.projection, "cylindrical")
        XCTAssertEqual(merged.diagnostics["blend_mode"]?.stringValue, "fast")
        XCTAssertEqual(merged.diagnostics["selected_edges"], source.diagnostics["selected_edges"])
        XCTAssertEqual(merged.diagnostics["completion_gate"], source.diagnostics["completion_gate"])
        XCTAssertEqual(source.cameraParams, originalCameras, "merge mutated the caller's source value")
    }

    func testGeometryDeltaRejectsAStaleHandle() {
        let source = StitchResult(
            handle: "current",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 10, height: 5, channels: 3, bitDepth: 16),
            cameraParams: [camera(rotation: [0, 0, 0])],
            controlPoints: [],
            sourceImages: [],
            diagnostics: .object([:])
        )
        let delta = GeometryCommitResultDelta(
            schemaVersion: 1,
            handle: "stale",
            projection: source.projection,
            cameraParams: source.cameraParams,
            poseAdjustment: .zero,
            diagnosticsDelta: [:]
        )

        XCTAssertThrowsError(
            try NativeEngineBridge.mergingGeometryCommitDelta(
                delta,
                into: source,
                expectedPose: .zero
            )
        )
    }

    private func camera(rotation: [Double]) -> CameraParams {
        CameraParams(
            rotation: rotation,
            translation: [0, 0, 0],
            focalLength: 1_000,
            k1: 0,
            k2: 0,
            k3: 0,
            p1: 0,
            p2: 0
        )
    }
}
