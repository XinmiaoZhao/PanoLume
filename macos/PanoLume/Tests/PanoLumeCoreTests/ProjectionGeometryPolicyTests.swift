import XCTest
@testable import PanoLumeCore

final class ProjectionGeometryPolicyTests: XCTestCase {
    func testUnverifiedDraftOnlyDragsAfterRefinementFailure() {
        let draft = makeResult(state: .unverifiedCameraDraft, status: "unverified_camera_draft")
        XCTAssertFalse(ProjectionGeometryPolicy.canDrag(
            result: draft,
            controlPointsDirty: false,
            refinementState: .refiningFullResolution,
            refinementActive: true
        ))
        XCTAssertTrue(ProjectionGeometryPolicy.canDrag(
            result: draft,
            controlPointsDirty: true,
            refinementState: .failed,
            refinementActive: false
        ))
    }

    func testHomographyNeverDragsAndVerifiedCameraRequiresCleanPoints() {
        let homography = makeResult(state: .homographyDiagnostic, status: "homography_preview")
        XCTAssertFalse(ProjectionGeometryPolicy.canDrag(
            result: homography,
            controlPointsDirty: false,
            refinementState: .failed,
            refinementActive: false
        ))
        let verified = makeResult(state: .verifiedCamera, status: "camera_projection_preview")
        XCTAssertTrue(ProjectionGeometryPolicy.canDrag(
            result: verified,
            controlPointsDirty: false,
            refinementState: .passed,
            refinementActive: false
        ))
        XCTAssertFalse(ProjectionGeometryPolicy.canDrag(
            result: verified,
            controlPointsDirty: true,
            refinementState: .passed,
            refinementActive: false
        ))
        var legacyMissingGate = verified
        legacyMissingGate.geometryQualityGatePassed = nil
        XCTAssertFalse(ProjectionGeometryPolicy.canDrag(
            result: legacyMissingGate,
            controlPointsDirty: false,
            refinementState: .passed,
            refinementActive: false
        ))
    }

    private func makeResult(
        state: ProjectionGeometryState,
        status: String
    ) -> StitchResult {
        StitchResult(
            handle: "test",
            projection: "equirectangular",
            projectionGeometryState: state,
            geometryQualityGatePassed: state == .verifiedCamera,
            panorama: PanoramaInfo(width: 100, height: 50, channels: 3, bitDepth: 8),
            cameraParams: [CameraParams(
                rotation: [0, 0, 0],
                translation: [0, 0, 0],
                focalLength: 1000,
                k1: 0,
                k2: 0,
                k3: 0,
                p1: 0,
                p2: 0
            )],
            controlPoints: [],
            sourceImages: [ResultSourceImage(
                handle: nil,
                path: "/tmp/source.tiff",
                width: 100,
                height: 50,
                channels: 4,
                bitDepth: 8,
                status: .loaded,
                unsupportedReason: nil
            )],
            diagnostics: .object(["preview_status": .string(status)])
        )
    }
}
