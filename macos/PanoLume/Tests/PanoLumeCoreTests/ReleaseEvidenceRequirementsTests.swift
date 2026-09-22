import XCTest
@testable import PanoLumeRegressionSupport

final class ReleaseEvidenceRequirementsTests: XCTestCase {
    func testFocusedPromotionSchemaContainsCurrentRiskEvidenceOnly() {
        let categories = Set(CandidateReleaseReportIntegrity.requiredArtifactCounts.keys)

        XCTAssertEqual(categories, [
            "raw2_auto_refinement",
            "raw2_manual_reoptimization",
            "raw2_export_pair",
            "raw1_canvas_smoke",
            "ordinary_image_reports",
            "control_point_reports",
            "refinement_cancellation_reports",
            "projection_release_reports",
            "installation_reports",
        ])
        XCTAssertFalse(categories.contains("preview_suite"))
        XCTAssertFalse(categories.contains("paired_performance_reports"))
        XCTAssertFalse(categories.contains("drag_reports"))
    }

    func testFocusedChecklistDoesNotContainPythonParityMatrixConcepts() {
        let keys = CandidateReleaseReportIntegrity.requiredChecklistKeys

        XCTAssertEqual(keys, [
            "astro_geometry",
            "manual_reoptimization",
            "export_pair",
            "canvas_coverage",
            "ordinary_images",
            "control_points",
            "refinement_cancellation",
            "projection_release_barrier",
            "installation_launch",
        ])
        XCTAssertFalse(keys.contains("performance"))
        XCTAssertFalse(keys.contains("alignment_quality"))
    }
}
