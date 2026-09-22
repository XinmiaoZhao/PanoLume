import CryptoKit
import Foundation
import XCTest
@testable import PanoLumeRegressionSupport

final class CandidateReleaseReportIntegrityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panolume-candidate-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testUntamperedCandidateReportPassesIntegrityAudit() throws {
        let report = try makeSealedReport()
        let audit = try CandidateReleaseReportIntegrity.validateForPromotion(
            reportData: encode(report)
        )

        XCTAssertEqual(audit.artifacts["raw2_auto_refinement"]?.count, 1)
        XCTAssertEqual(audit.artifacts["raw2_export_pair"]?.count, 1)
        XCTAssertEqual(audit.artifacts["projection_release_reports"]?.count, 1)
    }

    func testVolatileProvenanceTimestampIsExcludedFromPayloadSeal() throws {
        var report = try makeSealedReport()
        let originalSeal = try XCTUnwrap(report["report_payload_sha256"] as? String)
        var provenance = try XCTUnwrap(report["provenance"] as? [String: Any])
        provenance["created_at_utc"] = "2030-01-01T00:00:00Z"
        report["provenance"] = provenance

        XCTAssertEqual(
            try CandidateReleaseReportIntegrity.canonicalPayloadSHA256(
                reportData: encode(report)
            ),
            originalSeal
        )
    }

    func testChangingPassedWithoutResealingIsRejected() throws {
        var report = try makeSealedReport()
        report["passed"] = false

        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(reportData: encode(report))
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .payloadSHA256Mismatch
            )
        }

        report = try reseal(report)
        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(reportData: encode(report))
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .releaseDidNotPass
            )
        }
    }

    func testResealingCannotHideFalseChecklistOrFailures() throws {
        var checklistReport = try makeSealedReport()
        var checklist = try XCTUnwrap(checklistReport["checklist"] as? [String: Any])
        checklist["projection_release_barrier"] = false
        checklistReport["checklist"] = checklist
        checklistReport = try reseal(checklistReport)
        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(
                reportData: encode(checklistReport)
            )
        ) { error in
            guard case .incompleteChecklist(let keys) = error as? CandidateReleaseReportIntegrityError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(keys, ["projection_release_barrier"])
        }

        var failureReport = try makeSealedReport()
        failureReport["failures"] = ["injected failure"]
        failureReport = try reseal(failureReport)
        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(
                reportData: encode(failureReport)
            )
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .releaseFailuresNotEmpty
            )
        }
    }

    func testChangingMetricsOrEvidenceContentIsRejected() throws {
        var report = try makeSealedReport()
        report["metrics"] = ["median_latency_ms": 0]
        report = try reseal(report)
        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(reportData: encode(report))
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .unexpectedTopLevelFields(["metrics"])
            )
        }

        let evidenceReport = try makeSealedReport()
        let artifacts = try XCTUnwrap(evidenceReport["artifacts"] as? [String: Any])
        let releasePaths = try XCTUnwrap(artifacts["projection_release_reports"] as? [String])
        let changedPath = try XCTUnwrap(releasePaths.first)
        try Data("{\"success\":true,\"median_latency_ms\":999}".utf8)
            .write(to: URL(fileURLWithPath: changedPath), options: .atomic)

        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(
                reportData: encode(evidenceReport)
            )
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .evidenceDigestMismatch(changedPath)
            )
        }

    }

    func testChangingEvidencePathEvenAfterResealingIsRejected() throws {
        var report = try makeSealedReport()
        var artifacts = try XCTUnwrap(report["artifacts"] as? [String: Any])
        var paths = try XCTUnwrap(artifacts["ordinary_image_reports"] as? [String])
        paths[0] = temporaryDirectory.appendingPathComponent("replacement.json").path
        artifacts["ordinary_image_reports"] = paths
        report["artifacts"] = artifacts
        report = try reseal(report)

        XCTAssertThrowsError(
            try CandidateReleaseReportIntegrity.validateForPromotion(reportData: encode(report))
        ) { error in
            XCTAssertEqual(
                error as? CandidateReleaseReportIntegrityError,
                .artifactProvenanceMismatch
            )
        }
    }

    private func makeSealedReport() throws -> [String: Any] {
        let categoryCounts = CandidateReleaseReportIntegrity.requiredArtifactCounts
            .mapValues(\.lowerBound)
        var artifacts: [String: [String]] = [:]
        var inputSHA256: [String: String] = [:]
        for category in categoryCounts.keys.sorted() {
            for index in 0..<(categoryCounts[category] ?? 0) {
                let url = temporaryDirectory.appendingPathComponent("\(category)-\(index).json")
                let data = Data("{\"artifact\":\"\(category)\",\"index\":\(index)}".utf8)
                try data.write(to: url, options: .atomic)
                artifacts[category, default: []].append(url.path)
                inputSHA256[url.path] = sha256(data)
            }
        }
        let checklist = Dictionary(
            uniqueKeysWithValues: CandidateReleaseReportIntegrity.requiredChecklistKeys.map {
                ($0, true)
            }
        )
        let report: [String: Any] = [
            "passed": true,
            "candidate_certification": true,
            "source_certification_match": false,
            "checklist": checklist,
            "artifacts": artifacts,
            "failures": [String](),
            "report_payload_sha256": "",
            "provenance": [
                "created_at_utc": "2026-07-12T00:00:00Z",
                "input_sha256": inputSHA256,
            ],
        ]
        return try reseal(report)
    }

    private func reseal(_ report: [String: Any]) throws -> [String: Any] {
        var sealed = report
        sealed["report_payload_sha256"] = try CandidateReleaseReportIntegrity
            .canonicalPayloadSHA256(reportData: encode(report))
        return sealed
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
