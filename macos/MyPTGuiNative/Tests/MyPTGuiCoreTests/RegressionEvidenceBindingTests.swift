import XCTest
@testable import MyPTGuiRegressionSupport

final class RegressionEvidenceBindingTests: XCTestCase {
    private let current = String(repeating: "a", count: 64)
    private let executable = String(repeating: "b", count: 64)

    func testCurrentSchemaRecordsRuntimeBinding() throws {
        XCTAssertEqual(RegressionProvenanceSchema.currentVersion, 4)
        XCTAssertEqual(RegressionProvenanceSchema.toolVersion, "MyPTGuiRegression-provenance-v4")

        let binding = try RegressionEvidenceBindingValidator.validate(
            workspaceSourceFingerprint: current,
            binarySourceFingerprint: current,
            regressionExecutableSHA256: executable
        )

        XCTAssertEqual(binding.workspaceSourceFingerprint, current)
        XCTAssertEqual(binding.binarySourceFingerprint, current)
        XCTAssertEqual(binding.regressionExecutableSHA256, executable)
    }

    func testMissingEmbeddedFingerprintFailsClosed() {
        XCTAssertThrowsError(
            try RegressionEvidenceBindingValidator.validate(
                workspaceSourceFingerprint: current,
                binarySourceFingerprint: nil,
                regressionExecutableSHA256: executable
            )
        ) { error in
            XCTAssertEqual(error as? RegressionEvidenceBindingError, .missingBinarySourceFingerprint)
        }
    }

    func testStaleRegressionBinaryFailsClosed() {
        let stale = String(repeating: "c", count: 64)
        XCTAssertThrowsError(
            try RegressionEvidenceBindingValidator.validate(
                workspaceSourceFingerprint: current,
                binarySourceFingerprint: stale,
                regressionExecutableSHA256: executable
            )
        ) { error in
            XCTAssertEqual(
                error as? RegressionEvidenceBindingError,
                .sourceFingerprintMismatch(workspace: current, binary: stale)
            )
        }
    }

    func testMissingOrMalformedExecutableDigestFailsClosed() {
        XCTAssertThrowsError(
            try RegressionEvidenceBindingValidator.validate(
                workspaceSourceFingerprint: current,
                binarySourceFingerprint: current,
                regressionExecutableSHA256: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? RegressionEvidenceBindingError,
                .missingRegressionExecutableSHA256
            )
        }

        XCTAssertThrowsError(
            try RegressionEvidenceBindingValidator.validate(
                workspaceSourceFingerprint: current,
                binarySourceFingerprint: current,
                regressionExecutableSHA256: "ABC"
            )
        ) { error in
            XCTAssertEqual(
                error as? RegressionEvidenceBindingError,
                .malformedRegressionExecutableSHA256("ABC")
            )
        }
    }

    func testOracleMustBeItsOwnCleanGitWorktree() throws {
        try OracleWorktreeBindingValidator.validate(
            oracleRootPath: "/tmp/oracle",
            gitTopLevelPath: "/tmp/oracle",
            porcelainStatus: ""
        )

        XCTAssertThrowsError(
            try OracleWorktreeBindingValidator.validate(
                oracleRootPath: "/tmp/oracle",
                gitTopLevelPath: nil,
                porcelainStatus: nil
            )
        ) { error in
            XCTAssertEqual(error as? OracleWorktreeBindingError, .notGitWorktree)
        }

        XCTAssertThrowsError(
            try OracleWorktreeBindingValidator.validate(
                oracleRootPath: "/tmp/repository/legacy/python",
                gitTopLevelPath: "/tmp/repository",
                porcelainStatus: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? OracleWorktreeBindingError,
                .rootMismatch(
                    expected: "/tmp/repository/legacy/python",
                    actual: "/tmp/repository"
                )
            )
        }

        XCTAssertThrowsError(
            try OracleWorktreeBindingValidator.validate(
                oracleRootPath: "/tmp/oracle",
                gitTopLevelPath: "/tmp/oracle",
                porcelainStatus: " M src/myptgui/engine/pipeline.py"
            )
        ) { error in
            XCTAssertEqual(
                error as? OracleWorktreeBindingError,
                .dirty(" M src/myptgui/engine/pipeline.py")
            )
        }
    }
}
