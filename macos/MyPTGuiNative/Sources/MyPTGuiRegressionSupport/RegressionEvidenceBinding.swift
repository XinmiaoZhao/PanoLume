import Foundation

public enum RegressionProvenanceSchema {
    public static let currentVersion = 4
    public static let toolVersion = "MyPTGuiRegression-provenance-v4"
}

public struct RegressionEvidenceRuntimeBinding: Equatable, Sendable {
    public let workspaceSourceFingerprint: String
    public let binarySourceFingerprint: String
    public let regressionExecutableSHA256: String

    public init(
        workspaceSourceFingerprint: String,
        binarySourceFingerprint: String,
        regressionExecutableSHA256: String
    ) {
        self.workspaceSourceFingerprint = workspaceSourceFingerprint
        self.binarySourceFingerprint = binarySourceFingerprint
        self.regressionExecutableSHA256 = regressionExecutableSHA256
    }
}

public enum RegressionEvidenceBindingError: Error, Equatable, LocalizedError {
    case malformedWorkspaceSourceFingerprint(String)
    case missingBinarySourceFingerprint
    case malformedBinarySourceFingerprint(String)
    case sourceFingerprintMismatch(workspace: String, binary: String)
    case missingRegressionExecutableSHA256
    case malformedRegressionExecutableSHA256(String)

    public var errorDescription: String? {
        switch self {
        case .malformedWorkspaceSourceFingerprint:
            return "Certification evidence refused: the workspace engine/Metal source fingerprint is malformed."
        case .missingBinarySourceFingerprint:
            return "Certification evidence refused: the running native engine does not expose its embedded source fingerprint. Rebuild MyPTGuiRegression."
        case .malformedBinarySourceFingerprint:
            return "Certification evidence refused: the running native engine exposes a malformed embedded source fingerprint. Rebuild MyPTGuiRegression."
        case .sourceFingerprintMismatch(let workspace, let binary):
            return "Certification evidence refused: workspace engine/Metal fingerprint \(workspace) does not match the running binary fingerprint \(binary). Rebuild MyPTGuiRegression from the current workspace."
        case .missingRegressionExecutableSHA256:
            return "Certification evidence refused: the running MyPTGuiRegression executable could not be hashed."
        case .malformedRegressionExecutableSHA256:
            return "Certification evidence refused: the MyPTGuiRegression executable SHA-256 is malformed."
        }
    }
}

public enum RegressionEvidenceBindingValidator {
    public static func validate(
        workspaceSourceFingerprint: String,
        binarySourceFingerprint: String?,
        regressionExecutableSHA256: String?
    ) throws -> RegressionEvidenceRuntimeBinding {
        guard isLowercaseSHA256(workspaceSourceFingerprint) else {
            throw RegressionEvidenceBindingError.malformedWorkspaceSourceFingerprint(
                workspaceSourceFingerprint
            )
        }
        guard let binarySourceFingerprint else {
            throw RegressionEvidenceBindingError.missingBinarySourceFingerprint
        }
        guard isLowercaseSHA256(binarySourceFingerprint) else {
            throw RegressionEvidenceBindingError.malformedBinarySourceFingerprint(
                binarySourceFingerprint
            )
        }
        guard workspaceSourceFingerprint == binarySourceFingerprint else {
            throw RegressionEvidenceBindingError.sourceFingerprintMismatch(
                workspace: workspaceSourceFingerprint,
                binary: binarySourceFingerprint
            )
        }
        guard let regressionExecutableSHA256 else {
            throw RegressionEvidenceBindingError.missingRegressionExecutableSHA256
        }
        guard isLowercaseSHA256(regressionExecutableSHA256) else {
            throw RegressionEvidenceBindingError.malformedRegressionExecutableSHA256(
                regressionExecutableSHA256
            )
        }
        return RegressionEvidenceRuntimeBinding(
            workspaceSourceFingerprint: workspaceSourceFingerprint,
            binarySourceFingerprint: binarySourceFingerprint,
            regressionExecutableSHA256: regressionExecutableSHA256
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count == 64
            && value.unicodeScalars.allSatisfy { lowercaseHex.contains($0) }
    }
}

public enum OracleWorktreeBindingError: Error, Equatable, LocalizedError {
    case notGitWorktree
    case rootMismatch(expected: String, actual: String)
    case dirty(String)

    public var errorDescription: String? {
        switch self {
        case .notGitWorktree:
            return "Certification evidence refused: the Python oracle must be a Git worktree. Use the archived oracle tag in a separate worktree."
        case .rootMismatch(let expected, let actual):
            return "Certification evidence refused: the Python oracle root \(expected) is not the Git worktree root \(actual). Ignored legacy/python copies cannot be used as certification oracles."
        case .dirty:
            return "Certification evidence refused: the Python oracle Git worktree has uncommitted or untracked changes."
        }
    }
}

public enum OracleWorktreeBindingValidator {
    public static func validate(
        oracleRootPath: String,
        gitTopLevelPath: String?,
        porcelainStatus: String?
    ) throws {
        guard let gitTopLevelPath, let porcelainStatus else {
            throw OracleWorktreeBindingError.notGitWorktree
        }
        let expected = canonicalPath(oracleRootPath)
        let actual = canonicalPath(gitTopLevelPath)
        guard expected == actual else {
            throw OracleWorktreeBindingError.rootMismatch(expected: expected, actual: actual)
        }
        guard porcelainStatus.isEmpty else {
            throw OracleWorktreeBindingError.dirty(porcelainStatus)
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
