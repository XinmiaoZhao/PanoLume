import Foundation

public struct StitchMetrics: Codable, Equatable, Sendable {
    public var controlPointCount: Int
    public var selectedEdges: Int
    public var panoramaWidth: Int
    public var panoramaHeight: Int
    public var alignmentRMS: Double?
    public var alignmentP95: Double?
    public var bitDepth: Int?
    public var exportSeconds: Double?
    public var peakMemoryMB: Double?
    public var overlapPixels: Int?
    public var meanOverlapAbsdiff: Double?
    public var maxOverlapAbsdiff: Double?
    public var highConfidenceStarCount: Int?
    public var highConfidenceStarP95: Double?
    public var mutualStarP95: Double?

    public init(
        controlPointCount: Int,
        selectedEdges: Int,
        panoramaWidth: Int,
        panoramaHeight: Int,
        alignmentRMS: Double? = nil,
        alignmentP95: Double? = nil,
        bitDepth: Int? = nil,
        exportSeconds: Double? = nil,
        peakMemoryMB: Double? = nil,
        overlapPixels: Int? = nil,
        meanOverlapAbsdiff: Double? = nil,
        maxOverlapAbsdiff: Double? = nil,
        highConfidenceStarCount: Int? = nil,
        highConfidenceStarP95: Double? = nil,
        mutualStarP95: Double? = nil
    ) {
        self.controlPointCount = controlPointCount
        self.selectedEdges = selectedEdges
        self.panoramaWidth = panoramaWidth
        self.panoramaHeight = panoramaHeight
        self.alignmentRMS = alignmentRMS
        self.alignmentP95 = alignmentP95
        self.bitDepth = bitDepth
        self.exportSeconds = exportSeconds
        self.peakMemoryMB = peakMemoryMB
        self.overlapPixels = overlapPixels
        self.meanOverlapAbsdiff = meanOverlapAbsdiff
        self.maxOverlapAbsdiff = maxOverlapAbsdiff
        self.highConfidenceStarCount = highConfidenceStarCount
        self.highConfidenceStarP95 = highConfidenceStarP95
        self.mutualStarP95 = mutualStarP95
    }
}

public struct ParityComparison: Codable, Equatable, Sendable {
    public var passed: Bool
    public var failures: [String]

    public init(passed: Bool, failures: [String]) {
        self.passed = passed
        self.failures = failures
    }
}

public struct ParityThresholds: Codable, Equatable, Sendable {
    public var maxAlignmentRMSRegression: Double
    public var maxAlignmentP95Regression: Double
    public var minControlPointRatio: Double
    public var maxExportTimeRatio: Double
    public var maxPeakMemoryRatio: Double
    public var maxHighConfidenceStarP95Regression: Double
    public var maxMutualStarP95Regression: Double

    public init(
        maxAlignmentRMSRegression: Double = 0.05,
        maxAlignmentP95Regression: Double = 0.10,
        minControlPointRatio: Double = 0.95,
        maxExportTimeRatio: Double = 1.10,
        maxPeakMemoryRatio: Double = 1.10,
        maxHighConfidenceStarP95Regression: Double = 0.5,
        maxMutualStarP95Regression: Double = 1.0
    ) {
        self.maxAlignmentRMSRegression = maxAlignmentRMSRegression
        self.maxAlignmentP95Regression = maxAlignmentP95Regression
        self.minControlPointRatio = minControlPointRatio
        self.maxExportTimeRatio = maxExportTimeRatio
        self.maxPeakMemoryRatio = maxPeakMemoryRatio
        self.maxHighConfidenceStarP95Regression = maxHighConfidenceStarP95Regression
        self.maxMutualStarP95Regression = maxMutualStarP95Regression
    }
}

public enum ParityComparator {
    public static func compare(
        baseline: StitchMetrics,
        candidate: StitchMetrics,
        thresholds: ParityThresholds = ParityThresholds()
    ) -> ParityComparison {
        var failures: [String] = []

        if candidate.controlPointCount < Int(Double(baseline.controlPointCount) * thresholds.minControlPointRatio) {
            failures.append("control point count regressed: baseline \(baseline.controlPointCount), candidate \(candidate.controlPointCount)")
        }
        if candidate.selectedEdges < baseline.selectedEdges {
            failures.append("selected edge count regressed: baseline \(baseline.selectedEdges), candidate \(candidate.selectedEdges)")
        }
        if candidate.panoramaWidth <= 0 || candidate.panoramaHeight <= 0 {
            failures.append("candidate panorama dimensions are invalid")
        }
        if let base = baseline.alignmentRMS {
            if let current = candidate.alignmentRMS {
                if current > base + thresholds.maxAlignmentRMSRegression {
                    failures.append("alignment RMS regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("alignment RMS missing in candidate")
            }
        }
        if let base = baseline.alignmentP95 {
            if let current = candidate.alignmentP95 {
                if current > base + thresholds.maxAlignmentP95Regression {
                    failures.append("alignment P95 regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("alignment P95 missing in candidate")
            }
        }
        if let base = baseline.bitDepth {
            if let current = candidate.bitDepth {
                if current < base {
                    failures.append("bit depth regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("bit depth missing in candidate")
            }
        }
        if let base = baseline.exportSeconds {
            if let current = candidate.exportSeconds {
                if current > base * thresholds.maxExportTimeRatio {
                    failures.append("export time regressed: baseline \(base)s, candidate \(current)s")
                }
            } else {
                failures.append("export time missing in candidate")
            }
        }
        if let base = baseline.peakMemoryMB {
            if let current = candidate.peakMemoryMB {
                if current > base * thresholds.maxPeakMemoryRatio {
                    failures.append("peak memory regressed: baseline \(base)MB, candidate \(current)MB")
                }
            } else {
                failures.append("peak memory missing in candidate")
            }
        }
        if let base = baseline.highConfidenceStarCount {
            if let current = candidate.highConfidenceStarCount {
                if current < Int(Double(base) * thresholds.minControlPointRatio) {
                    failures.append("high-confidence star count regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("high-confidence star count missing in candidate")
            }
        }
        if let base = baseline.highConfidenceStarP95 {
            if let current = candidate.highConfidenceStarP95 {
                if current > base + thresholds.maxHighConfidenceStarP95Regression {
                    failures.append("high-confidence star P95 regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("high-confidence star P95 missing in candidate")
            }
        }
        if let base = baseline.mutualStarP95 {
            if let current = candidate.mutualStarP95 {
                if current > base + thresholds.maxMutualStarP95Regression {
                    failures.append("mutual star P95 regressed: baseline \(base), candidate \(current)")
                }
            } else {
                failures.append("mutual star P95 missing in candidate")
            }
        }

        return ParityComparison(passed: failures.isEmpty, failures: failures)
    }
}
