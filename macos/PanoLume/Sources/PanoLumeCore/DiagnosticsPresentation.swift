import Foundation

public enum DiagnosticSeverity: String, Codable, Equatable, Hashable, Sendable {
    case normal
    case success
    case warning
    case error
}

public struct DiagnosticMetric: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var help: String?
    public var severity: DiagnosticSeverity

    public init(
        id: String,
        title: String,
        value: String,
        help: String? = nil,
        severity: DiagnosticSeverity = .normal
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.help = help
        self.severity = severity
    }
}

public struct DiagnosticSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var metrics: [DiagnosticMetric]

    public init(id: String, title: String, metrics: [DiagnosticMetric]) {
        self.id = id
        self.title = title
        self.metrics = metrics
    }
}

/// A compact, user-facing snapshot derived once per stitch result. The engine's
/// full diagnostics JSON remains unchanged for regression and export, while the
/// SwiftUI diagnostics tab avoids encoding and laying out that document.
public struct DiagnosticsPresentation: Equatable, Sendable {
    public var statusTitle: String
    public var statusMessage: String
    public var statusSeverity: DiagnosticSeverity
    public var sections: [DiagnosticSection]
    public var alignmentSuggestions: [AlignmentSuggestion]
    public var cameraVerification: CameraVerificationEvidence?

    public static func build(
        result: StitchResult?,
        gate: ParityGateResult,
        exportProfile: JSONValue? = nil,
        controlPointsDirty: Bool = false
    ) -> DiagnosticsPresentation {
        guard let result else {
            return DiagnosticsPresentation(
                statusTitle: "No preview yet",
                statusMessage: "Add at least two images and run Preview to see alignment diagnostics.",
                statusSeverity: .normal,
                sections: [],
                alignmentSuggestions: [],
                cameraVerification: nil
            )
        }

        let diagnostics = result.diagnostics
        let geometry = diagnostics["geometry"]?.stringValue ?? "Not available"
        let previewStatus = diagnostics["preview_status"]?.stringValue ?? "Not available"
        let engineCompletionPassed = diagnostics["completion_gate"]?["passed"]?.boolValue ?? true
        let completionPassed = gate.passed && engineCompletionPassed
        let failureReason = diagnostics["preview_failure_reason"]?.stringValue
        let statusTitle = completionPassed ? "Ready" : "Needs attention"
        let statusMessage = failureReason ?? (completionPassed
            ? "The current preview completed its geometry quality checks."
            : gate.reason)

        let pointStatistics = summarizeControlPoints(result.controlPoints)
        let pointRMS = pointStatistics.rms
        let pointP95 = pointStatistics.p95
        let worstPair = pointStatistics.worstPair
        let manualFilter = diagnostics["manual_point_filtering"]
        let manualInput = intValue(manualFilter?["input"])
        let manualAccepted = intValue(manualFilter?["accepted"])
        let manualRejected = intValue(manualFilter?["rejected"])

        let highConfidence = diagnostics["star_projection_alignment"]?["high_confidence"]
        let mutual = diagnostics["star_projection_alignment"]?["mutual"]
        let renderProfile = exportProfile ?? diagnostics["export_profile"]

        var overviewMetrics = [
            DiagnosticMetric(id: "images", title: "Source images", value: String(result.sourceImages.count)),
            DiagnosticMetric(
                id: "output",
                title: "Preview output",
                value: "\(result.panorama.width) × \(result.panorama.height)"
            ),
            DiagnosticMetric(id: "geometry", title: "Geometry", value: friendlyGeometry(geometry)),
            DiagnosticMetric(id: "projection", title: "Projection", value: friendlyName(result.projection)),
            DiagnosticMetric(
                id: "preview-status",
                title: "Preview status",
                value: friendlyName(previewStatus),
                severity: completionPassed ? .success : .warning
            ),
        ]
        if let geometryGate = diagnostics["geometry_gate"] {
            let passed = geometryGate["passed"]?.boolValue == true
            overviewMetrics.append(DiagnosticMetric(
                id: "geometry-gate",
                title: "Geometry quality gate",
                value: passed ? "Passed" : "Failed",
                help: geometryGate["reason"]?.stringValue,
                severity: passed ? .success : .error
            ))
        }
        let overview = DiagnosticSection(id: "overview", title: "Overview", metrics: overviewMetrics)

        var alignmentMetrics = [
            DiagnosticMetric(id: "cp-count", title: "Control points", value: String(result.controlPoints.count)),
            DiagnosticMetric(
                id: "cp-rms",
                title: "Control-point RMS",
                value: controlPointsDirty ? "Pending re-optimization" : pixelText(pointRMS),
                help: "Root-mean-square alignment error. Lower is better; a few outliers can raise this value.",
                severity: severityForPixels(pointRMS, warning: 2.0, error: 5.0)
            ),
            DiagnosticMetric(
                id: "cp-p95",
                title: "Control-point P95",
                value: controlPointsDirty ? "Pending re-optimization" : pixelText(pointP95),
                help: "95% of retained control points have an error at or below this value.",
                severity: severityForPixels(pointP95, warning: 3.0, error: 5.0)
            ),
            DiagnosticMetric(
                id: "worst-pair",
                title: "Worst image pair",
                value: controlPointsDirty
                    ? "Pending re-optimization"
                    : (worstPair.map { "\($0.label) · \(pixelText($0.p95))" } ?? "Not available"),
                help: "The image pair with the largest P95 error among retained control points.",
                severity: severityForPixels(worstPair?.p95, warning: 3.0, error: 5.0)
            ),
            DiagnosticMetric(
                id: "trusted-stars",
                title: "Trusted-star P95",
                value: pixelText(highConfidence?["p95"]?.numberValue),
                help: "Projection error for the strongest mutually supported star matches.",
                severity: severityForPixels(highConfidence?["p95"]?.numberValue, warning: 3.0, error: 5.0)
            ),
            DiagnosticMetric(
                id: "mutual-stars",
                title: "Mutual-star P95",
                value: pixelText(mutual?["p95"]?.numberValue),
                help: "Projection error across all bidirectionally matched stars; this is more sensitive to local weak regions.",
                severity: severityForPixels(mutual?["p95"]?.numberValue, warning: 4.0, error: 6.0)
            ),
        ]
        if let reason = diagnostics["camera_model"]?["quality_gate_reason"]?.stringValue, !reason.isEmpty {
            let finalCameraVerified = result.projectionGeometryState == .verifiedCamera
                && result.geometryQualityGatePassed == true
            alignmentMetrics.append(DiagnosticMetric(
                id: "camera-quality-reason",
                title: finalCameraVerified ? "Draft camera history" : "Camera quality note",
                value: finalCameraVerified
                    ? "Draft gate failed; recovered by verified camera geometry. \(reason)"
                    : reason,
                help: finalCameraVerified
                    ? "This note belongs to the earlier preview attempt. The authoritative final camera geometry passed its independent gate."
                    : nil,
                severity: finalCameraVerified
                    ? .normal
                    : (diagnostics["camera_model"]?["quality_gate_passed"]?.boolValue == false ? .warning : .normal)
            ))
        }
        if let recovery = diagnostics["star_edge_recovery"] {
            let attempts = intValue(recovery["attempts"]) ?? 0
            let accepted = intValue(recovery["accepted"]) ?? 0
            alignmentMetrics.append(DiagnosticMetric(
                id: "star-edge-recovery",
                title: "Star-edge recovery",
                value: "\(attempts) attempts · \(accepted) accepted",
                help: "Deterministic mutual-vote star matching is used only to recover missing or failed edges.",
                severity: accepted > 0 ? .success : (attempts > 0 ? .warning : .normal)
            ))
            let rejectedEdges = recovery["rejected_camera_edges"]?.arrayValue ?? []
            if !rejectedEdges.isEmpty {
                alignmentMetrics.append(DiagnosticMetric(
                    id: "rejected-camera-edges",
                    title: "Rejected camera edges",
                    value: pairList(rejectedEdges, sourceImages: result.sourceImages),
                    help: "Camera optimization rejected these quality-gate failures before rebuilding its spanning tree.",
                    severity: .success
                ))
            }
            let treeAttempts = recovery["camera_tree_attempts"]?.arrayValue ?? []
            if let finalAttempt = treeAttempts.last {
                let succeeded = finalAttempt["success"]?.boolValue == true
                alignmentMetrics.append(DiagnosticMetric(
                    id: "camera-tree-attempts",
                    title: "Camera tree rebuilds",
                    value: "\(treeAttempts.count) · \(succeeded ? "final pass" : "final failure")",
                    help: finalAttempt["reason"]?.stringValue,
                    severity: succeeded ? .success : .warning
                ))
            }
        }

        var refinementMetrics: [DiagnosticMetric] = []
        if let method = diagnostics["reoptimization_method"]?.stringValue, !method.isEmpty {
            refinementMetrics.append(DiagnosticMetric(
                id: "reoptimization-method",
                title: "Re-optimization method",
                value: friendlyName(method),
                help: "The edited pair graph is rebuilt before the geometry family is selected again."
            ))
        }
        for (key, title) in [
            ("guided_star_refinement", "Guided star refinement"),
            ("local_star_refinement", "Local star refinement"),
            ("texture_sift_refinement", "Texture refinement"),
        ] {
            guard let report = diagnostics[key] else { continue }
            let accepted = report["accepted"]?.boolValue ?? report["success"]?.boolValue
            let added = intValue(report["added_control_points"])
            let value: String
            if let accepted {
                value = accepted ? "Accepted\(added.map { " · +\($0) points" } ?? "")" : "Not accepted"
            } else {
                value = "Reported"
            }
            refinementMetrics.append(DiagnosticMetric(
                id: key,
                title: title,
                value: value,
                help: report["reason"]?.stringValue,
                severity: accepted == false ? .warning : .normal
            ))
        }
        refinementMetrics.append(DiagnosticMetric(
            id: "manual-points",
            title: "Manual control points",
            value: controlPointsDirty
                ? "Pending re-optimization"
                : (manualInput.map {
                    "\($0) input · \(manualAccepted ?? 0) accepted · \(manualRejected ?? 0) rejected"
                } ?? "No re-optimization report"),
            help: controlPointsDirty
                ? "The acceptance report belongs to the previous geometry. Re-optimize to robustly filter the edited points."
                : manualFilter?["reason"]?.stringValue,
            severity: controlPointsDirty || (manualRejected ?? 0) > 0 ? .warning : .normal
        ))

        var renderingMetrics = [
            DiagnosticMetric(
                id: "blend",
                title: "Blend",
                value: friendlyName(diagnostics["blend_mode"]?.stringValue ?? "Not available")
            ),
            DiagnosticMetric(
                id: "renderer",
                title: "Preview renderer",
                value: friendlyName(diagnostics["preview_renderer_used"]?.stringValue ?? "Not available")
            ),
            DiagnosticMetric(
                id: "fallback",
                title: "Renderer fallback",
                value: diagnostics["preview_renderer_fallback"]?.boolValue == true ? "Yes" : "No",
                help: diagnostics["preview_renderer_fallback_reason"]?.stringValue
                    ?? "Fallback means the requested GPU path could not be used and a compatible renderer was selected.",
                severity: diagnostics["preview_renderer_fallback"]?.boolValue == true ? .warning : .normal
            ),
        ]
        if let renderProfile {
            renderingMetrics.append(contentsOf: [
                DiagnosticMetric(
                    id: "export-renderer",
                    title: "Last export renderer",
                    value: friendlyName(renderProfile["renderer_used"]?.stringValue ?? "Not available")
                ),
                DiagnosticMetric(
                    id: "export-time",
                    title: "Last export time",
                    value: secondsText(renderProfile["total_seconds"]?.numberValue)
                ),
                DiagnosticMetric(
                    id: "export-memory",
                    title: "Process peak memory",
                    value: memoryText(renderProfile["peak_memory_mb"]?.numberValue),
                    help: "Historical process high-water mark retained for compatibility; it may include work before this export."
                ),
                DiagnosticMetric(
                    id: "export-operation-memory",
                    title: "Export sampled peak",
                    value: memoryText(renderProfile["operation_peak_rss_mb"]?.numberValue),
                    help: "Resident memory sampled only while the current export operation was active."
                ),
                DiagnosticMetric(
                    id: "export-operation-delta",
                    title: "Export RSS increase",
                    value: memoryText(renderProfile["operation_peak_rss_delta_mb"]?.numberValue)
                ),
                DiagnosticMetric(
                    id: "export-source-leases",
                    title: "Peak source leases",
                    value: integerText(renderProfile["active_source_leases_peak"]?.numberValue),
                    help: "Maximum number of simultaneously resident full-resolution source leases."
                ),
                DiagnosticMetric(
                    id: "export-mapped-sources",
                    title: "Peak mapped sources",
                    value: byteText(renderProfile["mapped_source_bytes_peak"]?.numberValue)
                ),
                DiagnosticMetric(
                    id: "export-spool",
                    title: "Temporary RGB16 spool",
                    value: byteText(renderProfile["spool_bytes_peak"]?.numberValue),
                    help: renderProfile["cleanup_outcome"]?.stringValue.map { "Cleanup: \(friendlyName($0))" }
                ),
            ])
        }

        return DiagnosticsPresentation(
            statusTitle: statusTitle,
            statusMessage: statusMessage,
            statusSeverity: completionPassed ? .success : .warning,
            sections: [
                overview,
                DiagnosticSection(id: "alignment", title: "Alignment", metrics: alignmentMetrics),
                DiagnosticSection(id: "refinement", title: "Refinement", metrics: refinementMetrics),
                DiagnosticSection(id: "rendering", title: "Rendering", metrics: renderingMetrics),
            ],
            alignmentSuggestions: AlignmentAssistant.build(
                result: result,
                controlPointsDirty: controlPointsDirty
            ),
            cameraVerification: CameraVerificationEvidence.build(result: result)
        )
    }
}

private extension DiagnosticsPresentation {
    struct PairKey: Hashable {
        var low: Int
        var high: Int
    }

    struct PairSummary {
        var label: String
        var p95: Double
    }

    struct ControlPointSummary {
        var rms: Double?
        var p95: Double?
        var worstPair: PairSummary?
    }

    /// Builds all control-point metrics in one pass. P95 uses in-place
    /// selection below instead of sorting the complete point set every time
    /// the diagnostics tab is opened.
    static func summarizeControlPoints(_ points: [ControlPoint]) -> ControlPointSummary {
        var finiteErrors: [Double] = []
        finiteErrors.reserveCapacity(points.count)
        var pairErrors: [PairKey: [Double]] = [:]
        var sumOfSquares = 0.0

        for point in points where point.error.isFinite {
            let error = point.error
            finiteErrors.append(error)
            sumOfSquares += error * error
            let low = min(point.imageAIndex, point.imageBIndex)
            let high = max(point.imageAIndex, point.imageBIndex)
            pairErrors[PairKey(low: low, high: high), default: []].append(error)
        }

        var worstPair: PairSummary?
        for (key, errors) in pairErrors {
            guard let p95 = percentile(errors, fraction: 0.95) else { continue }
            if worstPair == nil || p95 > worstPair!.p95 {
                worstPair = PairSummary(label: "\(key.low + 1)–\(key.high + 1)", p95: p95)
            }
        }

        return ControlPointSummary(
            rms: finiteErrors.isEmpty
                ? nil
                : sqrt(sumOfSquares / Double(finiteErrors.count)),
            p95: percentile(finiteErrors, fraction: 0.95),
            worstPair: worstPair
        )
    }

    static func pairList(
        _ edges: [JSONValue],
        sourceImages: [ResultSourceImage]
    ) -> String {
        edges.compactMap { edge -> String? in
            guard let first = edge["i"]?.numberValue.map({ Int($0.rounded()) }),
                  let second = edge["j"]?.numberValue.map({ Int($0.rounded()) }) else {
                return nil
            }
            func label(_ index: Int) -> String {
                guard sourceImages.indices.contains(index) else { return "C\(index + 1)" }
                let name = URL(fileURLWithPath: sourceImages[index].path).lastPathComponent
                return "C\(index + 1) \(name)"
            }
            return "\(label(first)) ↔ \(label(second))"
        }.joined(separator: ", ")
    }

    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let position = Double(values.count - 1) * min(max(fraction, 0), 1)
        let low = Int(floor(position))
        let high = Int(ceil(position))
        var scratch = values
        let lowValue = nthValue(&scratch, at: low)
        if low == high { return lowValue }
        let highValue = nthValue(&scratch, at: high)
        let alpha = position - Double(low)
        return lowValue * (1 - alpha) + highValue * alpha
    }

    /// Deterministic three-way quickselect. Engine errors are finite before
    /// reaching this helper, and the three-way partition keeps repeated error
    /// values linear instead of degenerating into single-element partitions.
    static func nthValue(_ values: inout [Double], at target: Int) -> Double {
        var lower = 0
        var upper = values.count - 1

        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let pivot = median(values[lower], values[middle], values[upper])
            var less = lower
            var scan = lower
            var greater = upper

            while scan <= greater {
                if values[scan] < pivot {
                    values.swapAt(less, scan)
                    less += 1
                    scan += 1
                } else if values[scan] > pivot {
                    values.swapAt(scan, greater)
                    greater -= 1
                } else {
                    scan += 1
                }
            }

            if target < less {
                upper = less - 1
            } else if target > greater {
                lower = greater + 1
            } else {
                return values[target]
            }
        }

        return values[lower]
    }

    static func median(_ first: Double, _ second: Double, _ third: Double) -> Double {
        if first < second {
            if second < third { return second }
            return first < third ? third : first
        }
        if first < third { return first }
        return second < third ? third : second
    }

    static func intValue(_ value: JSONValue?) -> Int? {
        value?.numberValue.map { Int($0.rounded()) }
    }

    static func pixelText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return String(format: "%.2f px", value)
    }

    static func secondsText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return String(format: "%.2f s", value)
    }

    static func memoryText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return String(format: "%.0f MB", value)
    }

    static func integerText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return String(Int(value.rounded()))
    }

    static func byteText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .memory)
    }

    static func friendlyGeometry(_ value: String) -> String {
        switch value.lowercased() {
        case "camera": return "Camera panorama"
        case "homography": return "Planar / homography"
        default: return friendlyName(value)
        }
    }

    static func friendlyName(_ value: String) -> String {
        guard value != "Not available" else { return value }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func severityForPixels(_ value: Double?, warning: Double, error: Double) -> DiagnosticSeverity {
        guard let value, value.isFinite else { return .normal }
        if value >= error { return .error }
        if value >= warning { return .warning }
        return .normal
    }
}
