import XCTest
@testable import PanoLumeCore

final class ProductionExportCertificationPolicyTests: XCTestCase {
    func testProductionExportFailsClosedWithoutPromotedBinaryCertification() {
        let reason = ProductionExportCertificationPolicy.unavailableReason(
            nativeAlgorithmParity: false,
            parityGate: ParityGateResult(passed: true, reason: "result passed", missing: [])
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("locked") == true)
    }

    func testProductionExportRejectsAResultThatFailsItsParityGate() {
        let reason = ProductionExportCertificationPolicy.unavailableReason(
            nativeAlgorithmParity: true,
            parityGate: ParityGateResult(
                passed: false,
                reason: "control points were edited",
                missing: []
            )
        )

        XCTAssertEqual(
            reason,
            "Production export is blocked by the parity gate: control points were edited"
        )
    }

    func testProductionExportCertificationPolicyOpensOnlyWhenBothGatesPass() {
        let reason = ProductionExportCertificationPolicy.unavailableReason(
            nativeAlgorithmParity: true,
            parityGate: ParityGateResult(passed: true, reason: "certified", missing: [])
        )

        XCTAssertNil(reason)
    }
}
