import Foundation

public struct NormalizedImageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum AlignmentSuggestionKind: String, Codable, Equatable, Sendable {
    case isolatedImage
    case rejectedEdge
    case weakBridge
    case concentratedPoints
}

public struct AlignmentEvidence: Codable, Equatable, Sendable {
    public var metric: String
    public var value: String
    public var source: String

    public init(metric: String, value: String, source: String) {
        self.metric = metric
        self.value = value
        self.source = source
    }
}

public struct AlignmentSuggestion: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: AlignmentSuggestionKind
    public var severity: DiagnosticSeverity
    public var title: String
    public var summary: String
    public var imageAIndex: Int?
    public var imageBIndex: Int?
    public var suggestedRegionA: NormalizedImageRect?
    public var suggestedRegionB: NormalizedImageRect?
    public var evidence: [AlignmentEvidence]
    public var actionLabel: String
    public var isStale: Bool

    public init(
        id: String,
        kind: AlignmentSuggestionKind,
        severity: DiagnosticSeverity,
        title: String,
        summary: String,
        imageAIndex: Int? = nil,
        imageBIndex: Int? = nil,
        suggestedRegionA: NormalizedImageRect? = nil,
        suggestedRegionB: NormalizedImageRect? = nil,
        evidence: [AlignmentEvidence],
        actionLabel: String,
        isStale: Bool
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.summary = summary
        self.imageAIndex = imageAIndex
        self.imageBIndex = imageBIndex
        self.suggestedRegionA = suggestedRegionA
        self.suggestedRegionB = suggestedRegionB
        self.evidence = evidence
        self.actionLabel = actionLabel
        self.isStale = isStale
    }
}

public enum CameraVerificationKind: String, Codable, Equatable, Sendable {
    case fullResolutionAstro = "full_resolution_astro"
    case ordinaryHeldOut = "ordinary_held_out"
    case draftOnly = "draft_only"
    case unavailable
}

public struct CameraVerificationEvidence: Codable, Equatable, Sendable {
    public var kind: CameraVerificationKind
    public var qualityGatePassed: Bool
    public var selectedEdgeCount: Int
    public var independentlyValidatedEdgeCount: Int
    public var productionEligible: Bool
    public var reason: String

    public static func build(result: StitchResult?) -> CameraVerificationEvidence? {
        guard let result else { return nil }
        let selectedEdges = result.diagnostics["selected_edges"]?.arrayValue ?? []
        let validatedEdges = selectedEdges.filter {
            (($0["partitions"]?["validation_count"]?.numberValue ?? 0) > 0)
                && (($0["partitions"]?["final_held_out_count"]?.numberValue ?? 0) > 0)
        }.count
        let geometryPassed = result.projectionGeometryState == .verifiedCamera
            && result.geometryQualityGatePassed == true
        if result.astroRefinement?.state == .passed
            && result.astroRefinement?.qualityGatePassed == true
            && geometryPassed {
            return CameraVerificationEvidence(
                kind: .fullResolutionAstro,
                qualityGatePassed: true,
                selectedEdgeCount: selectedEdges.count,
                independentlyValidatedEdgeCount: validatedEdges,
                productionEligible: true,
                reason: "Independent full-resolution astro refinement passed."
            )
        }

        let alignmentFamily = result.diagnostics["alignment_family"]?.stringValue?.lowercased()
        if geometryPassed,
           result.cameraParams.count == result.sourceImages.count,
           alignmentFamily == "sift",
           !selectedEdges.isEmpty,
           validatedEdges == selectedEdges.count {
            return CameraVerificationEvidence(
                kind: .ordinaryHeldOut,
                qualityGatePassed: true,
                selectedEdgeCount: selectedEdges.count,
                independentlyValidatedEdgeCount: validatedEdges,
                productionEligible: false,
                reason: "Ordinary Camera has independent edge evidence, but production export remains locked until its focused certification is promoted."
            )
        }

        if !result.cameraParams.isEmpty {
            return CameraVerificationEvidence(
                kind: .draftOnly,
                qualityGatePassed: false,
                selectedEdgeCount: selectedEdges.count,
                independentlyValidatedEdgeCount: validatedEdges,
                productionEligible: false,
                reason: "Camera parameters exist without an authoritative production verification path."
            )
        }
        return CameraVerificationEvidence(
            kind: .unavailable,
            qualityGatePassed: false,
            selectedEdgeCount: selectedEdges.count,
            independentlyValidatedEdgeCount: validatedEdges,
            productionEligible: false,
            reason: "No verified Camera geometry is available."
        )
    }
}

public enum AlignmentAssistant {
    private struct PairKey: Hashable, Comparable {
        var low: Int
        var high: Int

        init(_ first: Int, _ second: Int) {
            low = min(first, second)
            high = max(first, second)
        }

        static func < (lhs: PairKey, rhs: PairKey) -> Bool {
            lhs.low == rhs.low ? lhs.high < rhs.high : lhs.low < rhs.low
        }
    }

    private struct EdgeEvidence {
        var pair: PairKey
        var p95: Double?
        var adaptiveAttempted: Bool
        var adaptiveAccepted: Bool
        var rejectReason: String
    }

    public static func build(result: StitchResult?, controlPointsDirty: Bool) -> [AlignmentSuggestion] {
        guard let result, result.sourceImages.count >= 2 else { return [] }
        let edges = parseEdges(result.diagnostics["selected_edges"]?.arrayValue ?? [])
        var suggestions: [AlignmentSuggestion] = []
        var adjacency = Array(repeating: Set<Int>(), count: result.sourceImages.count)
        for edge in edges where valid(edge.pair, count: adjacency.count) {
            adjacency[edge.pair.low].insert(edge.pair.high)
            adjacency[edge.pair.high].insert(edge.pair.low)
        }

        for index in adjacency.indices where adjacency[index].isEmpty {
            suggestions.append(AlignmentSuggestion(
                id: "isolated-\(index)",
                kind: .isolatedImage,
                severity: .error,
                title: "Image \(index + 1) is disconnected",
                summary: "No selected alignment edge connects this image to the current graph.",
                imageAIndex: index,
                evidence: [AlignmentEvidence(metric: "Selected degree", value: "0", source: "selected_edges graph")],
                actionLabel: "Review attempted edges and add points only where overlap is confirmed.",
                isStale: controlPointsDirty
            ))
        }

        let rejected = result.diagnostics["star_edge_recovery"]?["rejected_camera_edges"]?.arrayValue ?? []
        for value in rejected {
            guard let i = integer(value["i"]), let j = integer(value["j"]), i != j else { continue }
            let pair = PairKey(i, j)
            suggestions.append(AlignmentSuggestion(
                id: "rejected-\(pair.low)-\(pair.high)",
                kind: .rejectedEdge,
                severity: .warning,
                title: "Rejected edge \(pair.low + 1)–\(pair.high + 1)",
                summary: "The Camera rebuild explicitly rejected this observed edge; it is not an inferred missing pair.",
                imageAIndex: pair.low,
                imageBIndex: pair.high,
                evidence: [AlignmentEvidence(metric: "Edge state", value: "Rejected", source: "star_edge_recovery.rejected_camera_edges")],
                actionLabel: "Inspect this pair's retained and rejected control points.",
                isStale: controlPointsDirty
            ))
        }

        let bridges = bridgePairs(adjacency: adjacency)
        let finiteP95 = edges.compactMap(\.p95).sorted()
        let medianP95 = finiteP95.isEmpty ? nil : finiteP95[finiteP95.count / 2]
        for edge in edges where bridges.contains(edge.pair) {
            let directWeakness = edge.adaptiveAttempted && !edge.adaptiveAccepted
            let relativeWorst = edge.p95 != nil && medianP95 != nil && edge.p95! > medianP95!
            guard directWeakness || relativeWorst || !edge.rejectReason.isEmpty else { continue }
            var evidence = [AlignmentEvidence(metric: "Graph role", value: "Bridge", source: "selected_edges topology")]
            if let p95 = edge.p95 {
                evidence.append(AlignmentEvidence(metric: "Identity P95", value: String(format: "%.2f px", p95), source: "selected_edges.partitions"))
            }
            if !edge.rejectReason.isEmpty {
                evidence.append(AlignmentEvidence(metric: "Native note", value: edge.rejectReason, source: "adaptive_coverage_reject_reason"))
            }
            suggestions.append(AlignmentSuggestion(
                id: "bridge-\(edge.pair.low)-\(edge.pair.high)",
                kind: .weakBridge,
                severity: .warning,
                title: "Graph depends on edge \(edge.pair.low + 1)–\(edge.pair.high + 1)",
                summary: "Removing this comparatively weak observed edge disconnects the selected graph.",
                imageAIndex: edge.pair.low,
                imageBIndex: edge.pair.high,
                evidence: evidence,
                actionLabel: "Review point quality and spatial coverage on this pair.",
                isStale: controlPointsDirty
            ))
        }

        suggestions.append(contentsOf: concentratedPointSuggestions(result: result, isStale: controlPointsDirty))
        return suggestions.sorted {
            let rank: [DiagnosticSeverity: Int] = [.error: 0, .warning: 1, .normal: 2, .success: 3]
            let lhs = rank[$0.severity, default: 4]
            let rhs = rank[$1.severity, default: 4]
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    private static func parseEdges(_ values: [JSONValue]) -> [EdgeEvidence] {
        values.compactMap { value in
            guard let i = integer(value["i"]), let j = integer(value["j"]), i != j else { return nil }
            return EdgeEvidence(
                pair: PairKey(i, j),
                p95: value["partitions"]?["identity_association_p95_px"]?.numberValue,
                adaptiveAttempted: value["adaptive_coverage_attempted"]?.boolValue == true,
                adaptiveAccepted: value["adaptive_coverage_accepted"]?.boolValue == true,
                rejectReason: value["adaptive_coverage_reject_reason"]?.stringValue ?? ""
            )
        }
    }

    private static func concentratedPointSuggestions(result: StitchResult, isStale: Bool) -> [AlignmentSuggestion] {
        var grouped: [PairKey: [ControlPoint]] = [:]
        for point in result.controlPoints {
            grouped[PairKey(point.imageAIndex, point.imageBIndex), default: []].append(point)
        }
        return grouped.keys.sorted().compactMap { pair in
            guard valid(pair, count: result.sourceImages.count), let points = grouped[pair], points.count >= 4 else { return nil }
            let source = result.sourceImages[pair.low]
            guard source.width > 0, source.height > 0 else { return nil }
            var quadrants = [0, 0, 0, 0]
            for point in points {
                let x = point.imageAIndex == pair.low ? point.xA : point.xB
                let y = point.imageAIndex == pair.low ? point.yA : point.yB
                let column = x >= Double(source.width) * 0.5 ? 1 : 0
                let row = y >= Double(source.height) * 0.5 ? 1 : 0
                quadrants[row * 2 + column] += 1
            }
            guard let empty = quadrants.firstIndex(of: 0) else { return nil }
            let column = empty % 2
            let row = empty / 2
            let region = NormalizedImageRect(x: Double(column) * 0.5, y: Double(row) * 0.5, width: 0.5, height: 0.5)
            return AlignmentSuggestion(
                id: "coverage-\(pair.low)-\(pair.high)",
                kind: .concentratedPoints,
                severity: .warning,
                title: "Points are concentrated on pair \(pair.low + 1)–\(pair.high + 1)",
                summary: "One deterministic 2×2 source-image region contains no retained control points.",
                imageAIndex: pair.low,
                imageBIndex: pair.high,
                suggestedRegionA: region,
                evidence: [
                    AlignmentEvidence(metric: "Retained points", value: String(points.count), source: "typed control points"),
                    AlignmentEvidence(metric: "2×2 occupancy", value: quadrants.map(String.init).joined(separator: "/"), source: "source-image coordinates"),
                ],
                actionLabel: "If real overlap exists in the empty region, add a well-localized A–then–B point there.",
                isStale: isStale
            )
        }
    }

    private static func bridgePairs(adjacency: [Set<Int>]) -> Set<PairKey> {
        var time = 0
        var discovered = Array(repeating: -1, count: adjacency.count)
        var low = Array(repeating: -1, count: adjacency.count)
        var bridges: Set<PairKey> = []

        func visit(_ node: Int, parent: Int) {
            discovered[node] = time
            low[node] = time
            time += 1
            for neighbor in adjacency[node].sorted() {
                if discovered[neighbor] == -1 {
                    visit(neighbor, parent: node)
                    low[node] = min(low[node], low[neighbor])
                    if low[neighbor] > discovered[node] {
                        bridges.insert(PairKey(node, neighbor))
                    }
                } else if neighbor != parent {
                    low[node] = min(low[node], discovered[neighbor])
                }
            }
        }

        for node in adjacency.indices where discovered[node] == -1 {
            visit(node, parent: -1)
        }
        return bridges
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        value?.numberValue.map { Int($0.rounded()) }
    }

    private static func valid(_ pair: PairKey, count: Int) -> Bool {
        pair.low >= 0 && pair.high < count && pair.low < pair.high
    }
}
