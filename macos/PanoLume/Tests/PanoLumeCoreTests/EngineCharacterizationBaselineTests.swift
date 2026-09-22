import Foundation
import PanoLumeEngine
import XCTest

final class EngineCharacterizationBaselineTests: XCTestCase {
    func testPreSplitBaselineIsReadableAndBoundToKnownBehavior() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baselineURL = packageRoot
            .appendingPathComponent("Docs", isDirectory: true)
            .appendingPathComponent("Characterization", isDirectory: true)
            .appendingPathComponent("panolume-0.3-pre-split.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as? [String: Any]
        )

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["metal_api_version"] as? Int, 5)

        let raw2 = try XCTUnwrap(object["raw_2_auto"] as? [String: Any])
        XCTAssertEqual(raw2["projection_geometry_state"] as? String, "verified_camera")
        XCTAssertEqual(raw2["selected_correct_pair"] as? String, "2175-2177")
        XCTAssertEqual(raw2["excluded_wrong_pair"] as? String, "2175-2183")

        let export = try XCTUnwrap(object["raw_2_export_pair"] as? [String: Any])
        XCTAssertEqual(export["width"] as? Int, 9000)
        XCTAssertEqual(export["height"] as? Int, 3383)
        XCTAssertEqual(export["bit_depth"] as? Int, 16)

        let raw1 = try XCTUnwrap(object["raw_1_canvas"] as? [String: Any])
        XCTAssertEqual(raw1["width"] as? Int, 6416)
        XCTAssertEqual(raw1["height"] as? Int, 1876)
        XCTAssertEqual(raw1["coverage_clipped"] as? Bool, false)
    }

    func testNativeCharacterizationEntryPointsRemainGreen() {
        XCTAssertEqual(panolume_identity_matcher_characterization_self_test(), 1)
        XCTAssertEqual(panolume_local_warp_characterization_self_test(), 1)
        XCTAssertEqual(panolume_astro_psf_characterization_self_test(), 1)
        XCTAssertEqual(panolume_astro_geometry_characterization_self_test(), 1)
        XCTAssertEqual(panolume_source_ownership_characterization_self_test(), 1)
        XCTAssertEqual(panolume_typed_request_characterization_self_test(), 1)
        XCTAssertEqual(panolume_pts_projection_characterization_self_test(), 1)
    }
}
