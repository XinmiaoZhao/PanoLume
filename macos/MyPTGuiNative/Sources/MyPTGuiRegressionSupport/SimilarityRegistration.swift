import Foundation
import MyPTGuiCore

public struct SimilarityTransform: Codable, Equatable, Sendable {
    public var scale: Double
    public var rotationDegrees: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(
        scale: Double,
        rotationDegrees: Double = 0,
        offsetX: Double,
        offsetY: Double
    ) {
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    enum CodingKeys: String, CodingKey {
        case scale
        case rotationDegrees = "rotation_degrees"
        case offsetX = "offset_x"
        case offsetY = "offset_y"
    }
}

public struct SimilarityRegistrationResult: Codable, Equatable, Sendable {
    public var transform: SimilarityTransform
    public var trainingScore: Double
    public var heldOutScore: Double
    public var trainingSamples: Int
    public var heldOutSamples: Int
    public var heldOutInliers: Int
    public var heldOutInlierRatio: Double
    public var inlierThreshold: Double

    enum CodingKeys: String, CodingKey {
        case transform
        case trainingScore = "training_score"
        case heldOutScore = "held_out_score"
        case trainingSamples = "training_samples"
        case heldOutSamples = "held_out_samples"
        case heldOutInliers = "held_out_inliers"
        case heldOutInlierRatio = "held_out_inlier_ratio"
        case inlierThreshold = "inlier_threshold"
    }
}

public enum SimilarityRegistrar {
    private struct ScoreSummary {
        var score: Double
        var compared: Int
        var inliers: Int
    }

    /// Registers an independently rendered candidate to a larger or differently
    /// scaled reference. A coarse thumbnail search supplies the basin; the final
    /// scale/rotation/translation is optimized against one checkerboard half of
    /// full-resolution samples and reported on the held-out half.
    public static func register(
        reference: PixelBufferInfo,
        candidate: PixelBufferInfo
    ) -> SimilarityRegistrationResult {
        guard reference.width > 1, reference.height > 1,
              candidate.width > 1, candidate.height > 1 else {
            return SimilarityRegistrationResult(
                transform: SimilarityTransform(scale: 1, offsetX: 0, offsetY: 0),
                trainingScore: 0,
                heldOutScore: 0,
                trainingSamples: 0,
                heldOutSamples: 0,
                heldOutInliers: 0,
                heldOutInlierRatio: 0,
                inlierThreshold: 0.05
            )
        }

        let referenceThumb = resizeMaxSide(reference, maxSide: 256)
        let candidateThumb = resizeMaxSide(candidate, maxSide: 256)
        var bestThumbTransform = SimilarityTransform(scale: 1, offsetX: 0, offsetY: 0)
        var bestThumbScore = -Double.infinity
        for scaleStep in 35...65 {
            let scale = Double(scaleStep) * 0.02
            let scaledWidth = max(1, Int((Double(referenceThumb.width) * scale).rounded()))
            let scaledHeight = max(1, Int((Double(referenceThumb.height) * scale).rounded()))
            for offsetY in placementSamples(
                container: candidateThumb.height,
                content: scaledHeight,
                step: 4
            ) {
                for offsetX in placementSamples(
                    container: candidateThumb.width,
                    content: scaledWidth,
                    step: 4
                ) {
                    let transform = SimilarityTransform(
                        scale: scale,
                        offsetX: Double(offsetX),
                        offsetY: Double(offsetY)
                    )
                    let score = score(
                        reference: referenceThumb,
                        candidate: candidateThumb,
                        transform: transform,
                        sampleStride: 4,
                        checkerboardPhase: 0,
                        inlierThreshold: 0.05
                    ).score
                    if score > bestThumbScore {
                        bestThumbScore = score
                        bestThumbTransform = transform
                    }
                }
            }
        }

        let referenceThumbScale = Double(referenceThumb.width) / Double(reference.width)
        let candidateThumbScale = Double(candidateThumb.width) / Double(candidate.width)
        var transform = SimilarityTransform(
            scale: bestThumbTransform.scale * referenceThumbScale / candidateThumbScale,
            rotationDegrees: 0,
            offsetX: bestThumbTransform.offsetX / candidateThumbScale,
            offsetY: bestThumbTransform.offsetY / candidateThumbScale
        )
        var current = score(
            reference: reference,
            candidate: candidate,
            transform: transform,
            sampleStride: 8,
            checkerboardPhase: 0,
            inlierThreshold: 0.05
        )
        var scaleStep = 0.004
        var rotationStep = 0.08
        var offsetStep = 8.0
        for _ in 0..<11 {
            for _ in 0..<12 {
                let candidates = [
                    SimilarityTransform(scale: max(0.1, transform.scale - scaleStep), rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale + scaleStep, rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees - rotationStep, offsetX: transform.offsetX, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees + rotationStep, offsetX: transform.offsetX, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX - offsetStep, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX + offsetStep, offsetY: transform.offsetY),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX, offsetY: transform.offsetY - offsetStep),
                    SimilarityTransform(scale: transform.scale, rotationDegrees: transform.rotationDegrees, offsetX: transform.offsetX, offsetY: transform.offsetY + offsetStep),
                ]
                var improved = false
                for candidateTransform in candidates {
                    let candidateScore = score(
                        reference: reference,
                        candidate: candidate,
                        transform: candidateTransform,
                        sampleStride: 8,
                        checkerboardPhase: 0,
                        inlierThreshold: 0.05
                    )
                    if candidateScore.score > current.score + 1e-10 {
                        transform = candidateTransform
                        current = candidateScore
                        improved = true
                    }
                }
                if !improved { break }
            }
            scaleStep *= 0.5
            rotationStep *= 0.5
            offsetStep *= 0.5
        }

        let heldOut = score(
            reference: reference,
            candidate: candidate,
            transform: transform,
            sampleStride: 8,
            checkerboardPhase: 1,
            inlierThreshold: 0.05
        )
        return SimilarityRegistrationResult(
            transform: transform,
            trainingScore: current.score,
            heldOutScore: heldOut.score,
            trainingSamples: current.compared,
            heldOutSamples: heldOut.compared,
            heldOutInliers: heldOut.inliers,
            heldOutInlierRatio: heldOut.compared > 0
                ? Double(heldOut.inliers) / Double(heldOut.compared)
                : 0,
            inlierThreshold: 0.05
        )
    }

    public static func warpReference(
        _ reference: PixelBufferInfo,
        transform: SimilarityTransform,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> PixelBufferInfo {
        var data = Data(count: canvasWidth * canvasHeight * 4)
        let radians = transform.rotationDegrees * .pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let inverseScale = 1.0 / max(1e-12, transform.scale)
        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                let destination = (y * canvasWidth + x) * 4
                let dx = Double(x) - transform.offsetX
                let dy = Double(y) - transform.offsetY
                let referenceX = (cosine * dx + sine * dy) * inverseScale
                let referenceY = (-sine * dx + cosine * dy) * inverseScale
                if referenceX >= 0, referenceX < Double(reference.width - 1),
                   referenceY >= 0, referenceY < Double(reference.height - 1) {
                    for channel in 0..<3 {
                        data[destination + channel] = UInt8(
                            min(
                                255,
                                max(0, Int(bilinear(reference, x: referenceX, y: referenceY, channel: channel).rounded()))
                            )
                        )
                    }
                }
                data[destination + 3] = 255
            }
        }
        return PixelBufferInfo(
            data: data,
            width: canvasWidth,
            height: canvasHeight,
            bytesPerRow: canvasWidth * 4
        )
    }

    private static func score(
        reference: PixelBufferInfo,
        candidate: PixelBufferInfo,
        transform: SimilarityTransform,
        sampleStride: Int,
        checkerboardPhase: Int,
        inlierThreshold: Double
    ) -> ScoreSummary {
        let radians = transform.rotationDegrees * .pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let inverseScale = 1.0 / max(1e-12, transform.scale)
        var maskSamples = 0
        var compared = 0
        var inliers = 0
        var sumReference = 0.0
        var sumCandidate = 0.0
        var sumReferenceSquared = 0.0
        var sumCandidateSquared = 0.0
        var sumProduct = 0.0
        for y in stride(from: 0, to: candidate.height, by: sampleStride) {
            for x in stride(from: 0, to: candidate.width, by: sampleStride) {
                if ((((x / sampleStride) + (y / sampleStride)) & 1) != checkerboardPhase) { continue }
                let offset = y * candidate.bytesPerRow + x * 4
                let candidateValue = luminance(
                    candidate.data[offset],
                    candidate.data[offset + 1],
                    candidate.data[offset + 2]
                )
                if candidateValue <= 2.0 / 255.0 { continue }
                maskSamples += 1
                let dx = Double(x) - transform.offsetX
                let dy = Double(y) - transform.offsetY
                let referenceX = (cosine * dx + sine * dy) * inverseScale
                let referenceY = (-sine * dx + cosine * dy) * inverseScale
                guard referenceX >= 0, referenceX < Double(reference.width - 1),
                      referenceY >= 0, referenceY < Double(reference.height - 1) else { continue }
                let referenceValue = (
                    0.2126 * bilinear(reference, x: referenceX, y: referenceY, channel: 0)
                    + 0.7152 * bilinear(reference, x: referenceX, y: referenceY, channel: 1)
                    + 0.0722 * bilinear(reference, x: referenceX, y: referenceY, channel: 2)
                ) / 255.0
                compared += 1
                if abs(referenceValue - candidateValue) <= inlierThreshold { inliers += 1 }
                sumReference += referenceValue
                sumCandidate += candidateValue
                sumReferenceSquared += referenceValue * referenceValue
                sumCandidateSquared += candidateValue * candidateValue
                sumProduct += referenceValue * candidateValue
            }
        }
        guard compared > 1, maskSamples > 0 else {
            return ScoreSummary(score: -Double.infinity, compared: compared, inliers: inliers)
        }
        let count = Double(compared)
        let meanReference = sumReference / count
        let meanCandidate = sumCandidate / count
        let denominator = max(1.0, count - 1.0)
        let varianceReference = max(0, (sumReferenceSquared - count * meanReference * meanReference) / denominator)
        let varianceCandidate = max(0, (sumCandidateSquared - count * meanCandidate * meanCandidate) / denominator)
        let covariance = (sumProduct - count * meanReference * meanCandidate) / denominator
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        let ssim = ((2 * meanReference * meanCandidate + c1) * (2 * covariance + c2))
            / ((meanReference * meanReference + meanCandidate * meanCandidate + c1)
                * (varianceReference + varianceCandidate + c2))
        return ScoreSummary(
            score: ssim * count / Double(maskSamples),
            compared: compared,
            inliers: inliers
        )
    }

    private static func placementBounds(container: Int, content: Int) -> ClosedRange<Int> {
        min(0, container - content)...max(0, container - content)
    }

    private static func placementSamples(container: Int, content: Int, step: Int) -> [Int] {
        let bounds = placementBounds(container: container, content: content)
        var values = Array(stride(from: bounds.lowerBound, through: bounds.upperBound, by: max(1, step)))
        if values.last != bounds.upperBound { values.append(bounds.upperBound) }
        return values
    }

    private static func resizeMaxSide(_ pixels: PixelBufferInfo, maxSide: Int) -> PixelBufferInfo {
        let scale = min(1.0, Double(maxSide) / Double(max(pixels.width, pixels.height)))
        return resizeBilinear(
            pixels,
            width: max(1, Int((Double(pixels.width) * scale).rounded())),
            height: max(1, Int((Double(pixels.height) * scale).rounded()))
        )
    }

    private static func resizeBilinear(
        _ pixels: PixelBufferInfo,
        width: Int,
        height: Int
    ) -> PixelBufferInfo {
        var data = Data(count: width * height * 4)
        let scaleX = Double(pixels.width) / Double(width)
        let scaleY = Double(pixels.height) / Double(height)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * scaleY - 0.5
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * scaleX - 0.5
                let destination = (y * width + x) * 4
                for channel in 0..<4 {
                    data[destination + channel] = UInt8(
                        min(255, max(0, Int(bilinear(pixels, x: sourceX, y: sourceY, channel: channel).rounded())))
                    )
                }
            }
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    private static func bilinear(
        _ pixels: PixelBufferInfo,
        x: Double,
        y: Double,
        channel: Int
    ) -> Double {
        let clippedX = min(Double(pixels.width - 1), max(0, x))
        let clippedY = min(Double(pixels.height - 1), max(0, y))
        let x0 = Int(floor(clippedX))
        let y0 = Int(floor(clippedY))
        let x1 = min(pixels.width - 1, x0 + 1)
        let y1 = min(pixels.height - 1, y0 + 1)
        let wx = clippedX - Double(x0)
        let wy = clippedY - Double(y0)
        let p00 = Double(pixels.data[y0 * pixels.bytesPerRow + x0 * 4 + channel])
        let p10 = Double(pixels.data[y0 * pixels.bytesPerRow + x1 * 4 + channel])
        let p01 = Double(pixels.data[y1 * pixels.bytesPerRow + x0 * 4 + channel])
        let p11 = Double(pixels.data[y1 * pixels.bytesPerRow + x1 * 4 + channel])
        let top = p00 * (1 - wx) + p10 * wx
        let bottom = p01 * (1 - wx) + p11 * wx
        return top * (1 - wy) + bottom * wy
    }

    private static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255.0
    }
}
