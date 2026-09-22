import Foundation

public enum BaselineInputKind: String, Codable, Sendable {
    case standardImage = "standard_image"
    case rawImage = "raw_image"
    case pythonReport = "python_report"
    case nativeResult = "native_result"
}

public struct BaselineInput: Codable, Equatable, Sendable {
    public var path: String
    public var kind: BaselineInputKind
    public var required: Bool?

    public init(path: String, kind: BaselineInputKind, required: Bool? = nil) {
        self.path = path
        self.kind = kind
        self.required = required
    }
}

public struct BaselineExpectedMetrics: Codable, Equatable, Sendable {
    public var minControlPoints: Int?
    public var minSelectedEdges: Int?
    public var maxAlignmentRMS: Double?
    public var maxAlignmentP95: Double?
    public var minBitDepth: Int?
    public var maxExportSeconds: Double?
    public var maxPeakMemoryMB: Double?
    public var minOverlapPixels: Int?
    public var maxMeanOverlapAbsdiff: Double?
    public var maxOverlapAbsdiff: Double?
    public var requireLocalRefinementAccepted: Bool?
    public var minLocalRefinementPoints: Int?
    public var requireTextureRefinementAccepted: Bool?
    public var minTextureRefinementPoints: Int?
    public var minHighConfidenceStarCount: Int?
    public var maxHighConfidenceStarP95Px: Double?
    public var maxMutualStarP95Px: Double?

    enum CodingKeys: String, CodingKey {
        case minControlPoints = "min_control_points"
        case minSelectedEdges = "min_selected_edges"
        case maxAlignmentRMS = "max_alignment_rms"
        case maxAlignmentP95 = "max_alignment_p95"
        case minBitDepth = "min_bit_depth"
        case maxExportSeconds = "max_export_seconds"
        case maxPeakMemoryMB = "max_peak_memory_mb"
        case minOverlapPixels = "min_overlap_pixels"
        case maxMeanOverlapAbsdiff = "max_mean_overlap_absdiff"
        case maxOverlapAbsdiff = "max_overlap_absdiff"
        case requireLocalRefinementAccepted = "require_local_refinement_accepted"
        case minLocalRefinementPoints = "min_local_refinement_points"
        case requireTextureRefinementAccepted = "require_texture_refinement_accepted"
        case minTextureRefinementPoints = "min_texture_refinement_points"
        case minHighConfidenceStarCount = "min_high_confidence_star_count"
        case maxHighConfidenceStarP95Px = "max_high_confidence_star_p95_px"
        case maxMutualStarP95Px = "max_mutual_star_p95_px"
    }
}

public struct BaselineCase: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String?
    public var tags: [String]
    public var inputs: [BaselineInput]
    public var expectedMetrics: BaselineExpectedMetrics?
    public var skipReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tags
        case inputs
        case expectedMetrics = "expected_metrics"
        case skipReason = "skip_reason"
    }
}

public struct BaselineDatasetManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var description: String?
    public var cases: [BaselineCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case description
        case cases
    }
}

public struct BaselineInputValidation: Codable, Equatable, Sendable {
    public var path: String
    public var resolvedPath: String
    public var kind: BaselineInputKind
    public var required: Bool
    public var exists: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case resolvedPath = "resolved_path"
        case kind
        case required
        case exists
    }
}

public struct BaselineCaseValidation: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var messages: [String]
    public var inputs: [BaselineInputValidation]
}

public struct BaselineManifestValidation: Codable, Equatable, Sendable {
    public var passed: Bool
    public var manifestName: String
    public var runnableCases: Int
    public var skippedCases: Int
    public var failedCases: Int
    public var failures: [String]
    public var cases: [BaselineCaseValidation]

    enum CodingKeys: String, CodingKey {
        case passed
        case manifestName = "manifest_name"
        case runnableCases = "runnable_cases"
        case skippedCases = "skipped_cases"
        case failedCases = "failed_cases"
        case failures
        case cases
    }
}

public struct BaselineCasePlan: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var inputCount: Int
    public var nativeActions: [String]
    public var pythonOracleRequired: Bool
    public var expectedMetrics: BaselineExpectedMetrics?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case inputCount = "input_count"
        case nativeActions = "native_actions"
        case pythonOracleRequired = "python_oracle_required"
        case expectedMetrics = "expected_metrics"
    }
}

public struct BaselineManifestSummary: Codable, Equatable, Sendable {
    public var manifestName: String
    public var validation: BaselineManifestValidation
    public var cases: [BaselineCasePlan]
    public var notes: [String]

    enum CodingKeys: String, CodingKey {
        case manifestName = "manifest_name"
        case validation
        case cases
        case notes
    }
}

public enum BaselineManifestHarness {
    public static func load(from url: URL) throws -> BaselineDatasetManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BaselineDatasetManifest.self, from: data)
    }

    public static func validate(manifestURL: URL) throws -> BaselineManifestValidation {
        let manifest = try load(from: manifestURL)
        var failures: [String] = []
        var seenIDs = Set<String>()
        var caseResults: [BaselineCaseValidation] = []
        let baseURL = manifestURL.deletingLastPathComponent()

        if manifest.schemaVersion != 1 {
            failures.append("Unsupported manifest schema_version \(manifest.schemaVersion); expected 1.")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("Manifest name is empty.")
        }

        for baselineCase in manifest.cases {
            var messages: [String] = []
            var failureMessages: [String] = []
            var inputResults: [BaselineInputValidation] = []
            let isSkipped = baselineCase.skipReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

            if baselineCase.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("Case id is empty.")
                failureMessages.append("Case id is empty.")
            } else if !seenIDs.insert(baselineCase.id).inserted {
                messages.append("Duplicate case id \(baselineCase.id).")
                failureMessages.append("Duplicate case id \(baselineCase.id).")
            }

            if baselineCase.inputs.isEmpty && !isSkipped {
                messages.append("Case has no inputs and no skip_reason.")
                failureMessages.append("Case has no inputs and no skip_reason.")
            }

            for input in baselineCase.inputs {
                let resolved = resolve(input.path, relativeTo: baseURL)
                let exists = FileManager.default.fileExists(atPath: resolved.path)
                let required = input.required ?? true
                if !isSkipped && required && !exists {
                    messages.append("Missing required input: \(input.path)")
                    failureMessages.append("Missing required input: \(input.path)")
                } else if !isSkipped && !required && !exists {
                    messages.append("Optional input is absent: \(input.path)")
                }
                inputResults.append(BaselineInputValidation(
                    path: input.path,
                    resolvedPath: resolved.path,
                    kind: input.kind,
                    required: required,
                    exists: exists
                ))
            }

            if let skipReason = baselineCase.skipReason,
               !skipReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.insert("Skipped: \(skipReason)", at: 0)
            }

            let failed = !failureMessages.isEmpty
            caseResults.append(BaselineCaseValidation(
                id: baselineCase.id,
                status: failed ? "failed" : (isSkipped ? "skipped" : "runnable"),
                messages: messages,
                inputs: inputResults
            ))
        }

        for caseResult in caseResults where caseResult.status == "failed" {
            for message in caseResult.messages {
                failures.append("\(caseResult.id): \(message)")
            }
        }

        let runnable = caseResults.filter { $0.status == "runnable" }.count
        let skipped = caseResults.filter { $0.status == "skipped" }.count
        let failed = caseResults.filter { $0.status == "failed" }.count
        return BaselineManifestValidation(
            passed: failures.isEmpty,
            manifestName: manifest.name,
            runnableCases: runnable,
            skippedCases: skipped,
            failedCases: failed,
            failures: failures,
            cases: caseResults
        )
    }

    public static func summarize(manifestURL: URL) throws -> BaselineManifestSummary {
        let manifest = try load(from: manifestURL)
        let validation = try validate(manifestURL: manifestURL)
        let statuses = Dictionary(uniqueKeysWithValues: validation.cases.map { ($0.id, $0.status) })
        let plans = manifest.cases.map { baselineCase in
            BaselineCasePlan(
                id: baselineCase.id,
                status: statuses[baselineCase.id] ?? "unknown",
                inputCount: baselineCase.inputs.count,
                nativeActions: ["manifest run-native", "preview(parity-gated)", "optional diagnostic export", "metrics-from-native-result"],
                pythonOracleRequired: baselineCase.inputs.contains { $0.kind == .pythonReport || $0.kind == .rawImage },
                expectedMetrics: baselineCase.expectedMetrics
            )
        }
        return BaselineManifestSummary(
            manifestName: manifest.name,
            validation: validation,
            cases: plans,
            notes: [
                "This command only plans parity work; it does not run Python or native stitching. Use MyPTGuiRegression manifest run-native to execute native candidates.",
                "Skipped cases are valid placeholders for RAW datasets that are intentionally not committed."
            ]
        )
    }

    private static func resolve(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }
}
