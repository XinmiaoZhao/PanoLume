import Foundation

public struct ParityChecklist: Codable, Equatable, Sendable {
    public var alignmentQuality: Bool
    public var seamQuality: Bool
    public var bitDepth: Bool
    public var colorAndLinearHandling: Bool
    public var exportCorrectness: Bool
    public var memoryUse: Bool
    public var performance: Bool

    public init(
        alignmentQuality: Bool = false,
        seamQuality: Bool = false,
        bitDepth: Bool = false,
        colorAndLinearHandling: Bool = false,
        exportCorrectness: Bool = false,
        memoryUse: Bool = false,
        performance: Bool = false
    ) {
        self.alignmentQuality = alignmentQuality
        self.seamQuality = seamQuality
        self.bitDepth = bitDepth
        self.colorAndLinearHandling = colorAndLinearHandling
        self.exportCorrectness = exportCorrectness
        self.memoryUse = memoryUse
        self.performance = performance
    }

    public var allPassed: Bool {
        alignmentQuality
            && seamQuality
            && bitDepth
            && colorAndLinearHandling
            && exportCorrectness
            && memoryUse
            && performance
    }

    public var missing: [String] {
        var values: [String] = []
        if !alignmentQuality { values.append("alignment quality") }
        if !seamQuality { values.append("seam quality") }
        if !bitDepth { values.append("bit depth") }
        if !colorAndLinearHandling { values.append("color/linear data handling") }
        if !exportCorrectness { values.append("export correctness") }
        if !memoryUse { values.append("memory use") }
        if !performance { values.append("performance") }
        return values
    }
}

public struct ParityGateResult: Codable, Equatable, Sendable {
    public var passed: Bool
    public var reason: String
    public var missing: [String]

    public init(passed: Bool, reason: String, missing: [String]) {
        self.passed = passed
        self.reason = reason
        self.missing = missing
    }
}

public enum ParityGate {
    public static func evaluate(result: StitchResult?, checklist: ParityChecklist? = nil) -> ParityGateResult {
        guard let result else {
            return ParityGateResult(
                passed: false,
                reason: "No stitch result exists.",
                missing: checklist?.missing ?? []
            )
        }

        let engineGate = result.diagnostics["completion_gate"]
        let enginePassed = engineGate?["passed"]?.boolValue ?? false
        let engineReason = engineGate?["reason"]?.stringValue
            ?? "The panorama engine did not provide a completion gate."

        guard enginePassed else {
            return ParityGateResult(
                passed: false,
                reason: engineReason,
                missing: missingAlgorithms(from: engineGate) + (checklist?.missing ?? [])
            )
        }

        if let checklist, !checklist.allPassed {
            return ParityGateResult(
                passed: false,
                reason: "A result exists, but release quality checks have not all passed.",
                missing: checklist.missing
            )
        }

        return ParityGateResult(passed: true, reason: "Release quality gate passed.", missing: [])
    }

    private static func missingAlgorithms(from gate: JSONValue?) -> [String] {
        guard let values = gate?["missing_algorithms"]?.arrayValue else {
            return []
        }
        return values.compactMap(\.stringValue)
    }
}
