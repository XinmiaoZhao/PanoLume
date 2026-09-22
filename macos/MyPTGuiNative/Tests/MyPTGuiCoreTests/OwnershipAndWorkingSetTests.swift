import XCTest
@testable import MyPTGuiCore

final class OwnershipAndWorkingSetTests: XCTestCase {
    func testOwnershipContractUsesZeroSentinelAndOneBasedSources() throws {
        let map = try SourceOwnershipMap(
            width: 3,
            height: 2,
            sourceCount: 2,
            pixels: [0, 1, 2, 2, 1, 0]
        )

        XCTAssertEqual(map.owner(x: 0, y: 0), 0)
        XCTAssertEqual(map.owner(x: 2, y: 0), 2)
        XCTAssertNil(map.owner(x: 3, y: 0))
    }

    func testOwnershipContractRejectsOutOfRangeSource() {
        XCTAssertThrowsError(
            try SourceOwnershipMap(width: 2, height: 1, sourceCount: 2, pixels: [1, 3])
        )
    }

    func testExportSettingsDecodesLegacyPayloadWithoutBudget() throws {
        let legacy = """
        {
          "maxOutputPixels": 0,
          "maxOutputSide": 0,
          "rendererBackend": "auto",
          "bitDepth": 16,
          "applyPreviewStretch": false,
          "stretchStrength": 0,
          "stretchBlackPercentile": 0.5,
          "stretchWhitePercentile": 99.7,
          "stretchGamma": 0.45
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ExportSettings.self, from: legacy)

        XCTAssertEqual(settings.workingSetBudgetMB, 0)
    }

    func testExportSettingsRoundTripsForcedBudget() throws {
        var settings = ExportSettings()
        settings.workingSetBudgetMB = 768

        let decoded = try JSONDecoder().decode(
            ExportSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.workingSetBudgetMB, 768)
    }
}
