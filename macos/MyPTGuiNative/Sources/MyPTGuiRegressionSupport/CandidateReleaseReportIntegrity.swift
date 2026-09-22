import CryptoKit
import Foundation

public struct CandidateReleaseReportAudit: Equatable, Sendable {
    public var artifacts: [String: [String]]

    public init(artifacts: [String: [String]]) {
        self.artifacts = artifacts
    }
}

public enum CandidateReleaseReportIntegrityError: Error, Equatable, LocalizedError {
    case malformedReport
    case unexpectedTopLevelFields([String])
    case missingPayloadSHA256
    case payloadSHA256Mismatch
    case releaseDidNotPass
    case releaseFailuresNotEmpty
    case incompleteChecklist([String])
    case malformedArtifactManifest(String)
    case duplicateEvidencePath(String)
    case artifactProvenanceMismatch
    case missingEvidenceFile(String)
    case malformedEvidenceDigest(String)
    case evidenceDigestMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .malformedReport:
            return "Certification promotion refused: the candidate release report is malformed."
        case .unexpectedTopLevelFields(let fields):
            return "Certification promotion refused: the candidate report contains unexpected fields: \(fields.joined(separator: ", "))."
        case .missingPayloadSHA256:
            return "Certification promotion refused: report_payload_sha256 is missing or malformed."
        case .payloadSHA256Mismatch:
            return "Certification promotion refused: report_payload_sha256 does not match the canonical candidate report payload."
        case .releaseDidNotPass:
            return "Certification promotion refused: the candidate release report is not passing."
        case .releaseFailuresNotEmpty:
            return "Certification promotion refused: the candidate release report still contains failures."
        case .incompleteChecklist(let keys):
            return "Certification promotion refused: required checklist items are missing or false: \(keys.joined(separator: ", "))."
        case .malformedArtifactManifest(let category):
            return "Certification promotion refused: evidence category \(category) has the wrong count or malformed paths."
        case .duplicateEvidencePath(let path):
            return "Certification promotion refused: evidence path is reused: \(path)."
        case .artifactProvenanceMismatch:
            return "Certification promotion refused: the artifact path set does not match provenance input_sha256."
        case .missingEvidenceFile(let path):
            return "Certification promotion refused: evidence file is missing: \(path)."
        case .malformedEvidenceDigest(let path):
            return "Certification promotion refused: evidence SHA-256 is malformed for \(path)."
        case .evidenceDigestMismatch(let path):
            return "Certification promotion refused: evidence content changed after validation: \(path)."
        }
    }
}

public enum CandidateReleaseReportIntegrity {
    public static let requiredChecklistKeys = Set([
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

    public static let requiredArtifactCounts: [String: ClosedRange<Int>] = [
        "raw2_auto_refinement": 1...1,
        "raw2_manual_reoptimization": 1...1,
        "raw2_export_pair": 1...1,
        "raw1_canvas_smoke": 1...1,
        "ordinary_image_reports": 1...2,
        "control_point_reports": 1...2,
        "refinement_cancellation_reports": 1...1,
        "projection_release_reports": 1...1,
        "installation_reports": 1...1,
    ]

    private static let allowedTopLevelKeys = Set([
        "passed",
        "candidate_certification",
        "source_certification_match",
        "checklist",
        "artifacts",
        "failures",
        "report_payload_sha256",
        "provenance",
    ])

    /// Hashes the stable report body. Provenance is independently validated and
    /// intentionally excluded because it contains created_at_utc. The seal
    /// field itself is also excluded to avoid a circular digest.
    public static func canonicalPayloadSHA256(reportData: Data) throws -> String {
        guard var report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any] else {
            throw CandidateReleaseReportIntegrityError.malformedReport
        }
        report.removeValue(forKey: "report_payload_sha256")
        report.removeValue(forKey: "provenance")
        let payload = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    public static func validateForPromotion(
        reportData: Data,
        verifyEvidenceFiles: Bool = true
    ) throws -> CandidateReleaseReportAudit {
        guard let report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any] else {
            throw CandidateReleaseReportIntegrityError.malformedReport
        }
        let unexpected = Set(report.keys).subtracting(allowedTopLevelKeys).sorted()
        guard unexpected.isEmpty else {
            throw CandidateReleaseReportIntegrityError.unexpectedTopLevelFields(unexpected)
        }
        guard let storedPayloadSHA256 = report["report_payload_sha256"] as? String,
              isLowercaseSHA256(storedPayloadSHA256) else {
            throw CandidateReleaseReportIntegrityError.missingPayloadSHA256
        }
        guard try canonicalPayloadSHA256(reportData: reportData) == storedPayloadSHA256 else {
            throw CandidateReleaseReportIntegrityError.payloadSHA256Mismatch
        }
        guard report["candidate_certification"] is Bool,
              report["source_certification_match"] is Bool else {
            throw CandidateReleaseReportIntegrityError.malformedReport
        }
        guard report["passed"] as? Bool == true else {
            throw CandidateReleaseReportIntegrityError.releaseDidNotPass
        }
        guard let failures = report["failures"] as? [Any], failures.isEmpty else {
            throw CandidateReleaseReportIntegrityError.releaseFailuresNotEmpty
        }
        guard let checklist = report["checklist"] as? [String: Any] else {
            throw CandidateReleaseReportIntegrityError.incompleteChecklist(
                requiredChecklistKeys.sorted()
            )
        }
        let incompleteChecklist = requiredChecklistKeys.filter {
            checklist[$0] as? Bool != true
        }.sorted()
        guard incompleteChecklist.isEmpty,
              Set(checklist.keys) == requiredChecklistKeys else {
            throw CandidateReleaseReportIntegrityError.incompleteChecklist(
                incompleteChecklist.isEmpty
                    ? Array(Set(checklist.keys).symmetricDifference(requiredChecklistKeys)).sorted()
                    : incompleteChecklist
            )
        }
        guard let artifactObject = report["artifacts"] as? [String: Any],
              Set(artifactObject.keys) == Set(requiredArtifactCounts.keys) else {
            throw CandidateReleaseReportIntegrityError.malformedArtifactManifest("artifacts")
        }
        var artifacts: [String: [String]] = [:]
        var allPaths = Set<String>()
        for category in requiredArtifactCounts.keys.sorted() {
            guard let values = artifactObject[category] as? [Any],
                  let expectedRange = requiredArtifactCounts[category],
                  expectedRange.contains(values.count) else {
                throw CandidateReleaseReportIntegrityError.malformedArtifactManifest(category)
            }
            let paths = try values.map { value -> String in
                guard let path = value as? String,
                      !path.isEmpty,
                      URL(fileURLWithPath: path).path == path else {
                    throw CandidateReleaseReportIntegrityError.malformedArtifactManifest(category)
                }
                return path
            }
            for path in paths where !allPaths.insert(path).inserted {
                throw CandidateReleaseReportIntegrityError.duplicateEvidencePath(path)
            }
            artifacts[category] = paths
        }

        guard let provenance = report["provenance"] as? [String: Any],
              let inputSHA256 = provenance["input_sha256"] as? [String: Any],
              Set(inputSHA256.keys) == allPaths else {
            throw CandidateReleaseReportIntegrityError.artifactProvenanceMismatch
        }
        if verifyEvidenceFiles {
            for path in allPaths.sorted() {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CandidateReleaseReportIntegrityError.missingEvidenceFile(path)
                }
                guard let expectedDigest = inputSHA256[path] as? String,
                      isLowercaseSHA256(expectedDigest) else {
                    throw CandidateReleaseReportIntegrityError.malformedEvidenceDigest(path)
                }
                let actualDigest = try SHA256.hash(data: Data(contentsOf: URL(fileURLWithPath: path)))
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard actualDigest == expectedDigest else {
                    throw CandidateReleaseReportIntegrityError.evidenceDigestMismatch(path)
                }
            }
        }
        return CandidateReleaseReportAudit(artifacts: artifacts)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64
            && value.unicodeScalars.allSatisfy { lowercaseHex.contains($0) }
    }
}
