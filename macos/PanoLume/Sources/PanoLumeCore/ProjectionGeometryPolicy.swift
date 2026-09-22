import Foundation

public enum ProjectionGeometryPolicy {
    public static func canDrag(
        result: StitchResult?,
        controlPointsDirty: Bool,
        refinementState: AstroRefinementState,
        refinementActive: Bool
    ) -> Bool {
        guard let result,
              !result.sourceImages.isEmpty,
              result.cameraParams.count == result.sourceImages.count,
              !refinementActive else {
            return false
        }
        let status = result.diagnostics["preview_status"]?.stringValue
        if status == "camera_projection_preview"
            && result.projectionGeometryState == .verifiedCamera
            && result.geometryQualityGatePassed == true {
            return !controlPointsDirty
        }
        let unverified = result.projectionGeometryState == .unverifiedCameraDraft
            || status == "draft_camera_preview"
            || status == "unverified_camera_draft"
        return unverified && refinementState == .failed
    }
}
