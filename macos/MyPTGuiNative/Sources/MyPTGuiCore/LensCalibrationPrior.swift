import Foundation
import CryptoKit

public struct LensCalibrationPrior: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profileName: String
    public var cameraMake: String
    public var cameraPrettyName: String?
    public var lensName: String
    public var focalLengthMM: Double
    public var apertureFNumber: Double?
    public var perspectiveModelVersion: Int
    public var scaleFactor: Double
    public var focalLengthX: Double?
    public var focalLengthY: Double?
    public var imageXCenter: Double?
    public var imageYCenter: Double?
    public var radialParameters: [Double]
    public var convertedFocalScale: Double
    public var convertedK1: Double
    public var convertedK2: Double
    public var convertedK3: Double
    public var convertedP1: Double
    public var convertedP2: Double
    public var convertedPrincipalOffsetX: Double?
    public var convertedPrincipalOffsetY: Double?
    public var conversionMaxErrorPixels: Double
    public var sha256: String
    public var sourceFilename: String
    public var cameraMakeMismatch: Bool
    public var priorWeight: Double
    public var warning: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, profileName, cameraMake, cameraPrettyName, lensName
        case focalLengthMM, apertureFNumber, perspectiveModelVersion, scaleFactor
        case focalLengthX, focalLengthY, imageXCenter, imageYCenter
        case radialParameters, convertedFocalScale, convertedK1, convertedK2, convertedK3
        case convertedP1, convertedP2, convertedPrincipalOffsetX, convertedPrincipalOffsetY
        case conversionMaxErrorPixels, sha256, sourceFilename
        case cameraMakeMismatch, priorWeight, warning
    }
}

public enum LensCalibrationPriorError: LocalizedError {
    case unreadable(String)
    case malformedXML(String)
    case unsupportedPerspectiveModel
    case invalidParameters
    case conversionTooInaccurate(Double)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): return "Lens Profile could not be read: \(message)"
        case .malformedXML(let message): return "Lens Profile XML is invalid: \(message)"
        case .unsupportedPerspectiveModel: return "Lens Profile contains no supported Adobe PerspectiveModel."
        case .invalidParameters: return "Lens Profile contains invalid focal, scale, or radial parameters."
        case .conversionTooInaccurate(let error):
            return String(format: "Lens Profile conversion error %.4f px exceeds 0.05 px.", error)
        }
    }
}

public enum LensCalibrationPriorLoader {
    public static func load(
        from url: URL,
        targetFocalLengthMM: Double? = nil,
        targetFNumber: Double? = nil,
        targetCameraMake: String? = nil
    ) throws -> LensCalibrationPrior {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LensCalibrationPriorError.unreadable(error.localizedDescription)
        }
        let delegate = LCPParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw LensCalibrationPriorError.malformedXML(
                parser.parserError?.localizedDescription ?? "unknown parser error"
            )
        }
        let supportedCandidates = delegate.candidates.filter { $0.version == 2 }
        guard !supportedCandidates.isEmpty else {
            throw LensCalibrationPriorError.unsupportedPerspectiveModel
        }
        let desiredFocal = targetFocalLengthMM ?? supportedCandidates[0].focalLengthMM
        let desiredAperture = targetFNumber
            ?? supportedCandidates[0].apertureFNumber
            ?? 1.0
        let candidate = supportedCandidates.min { lhs, rhs in
            let left = abs(lhs.focalLengthMM - desiredFocal) * 4.0
                + abs((lhs.apertureFNumber ?? desiredAperture) - desiredAperture)
            let right = abs(rhs.focalLengthMM - desiredFocal) * 4.0
                + abs((rhs.apertureFNumber ?? desiredAperture) - desiredAperture)
            return left < right
        }!
        guard candidate.focalLengthMM > 0,
              candidate.radial.count == 3,
              candidate.radial.allSatisfy(\.isFinite) else {
            throw LensCalibrationPriorError.invalidParameters
        }
        let conversion = try convertAdobePerspectiveModel(candidate)
        let normalizedProfileMake = normalizedMake(candidate.cameraMake)
        let normalizedTargetMake = targetCameraMake.map(normalizedMake)
        let mismatch = normalizedTargetMake.map {
            !$0.isEmpty && !normalizedProfileMake.isEmpty
                && !$0.contains(normalizedProfileMake)
                && !normalizedProfileMake.contains($0)
        } ?? false
        let warning: String?
        if mismatch, let targetCameraMake {
            warning = "Profile body \(candidate.cameraMake) does not match \(targetCameraMake); coefficients are a weak initialization only."
        } else {
            warning = "External LCP calibration remains a weak prior tied to its recorded camera body and capture settings."
        }
        return LensCalibrationPrior(
            schemaVersion: 1,
            profileName: candidate.profileName,
            cameraMake: candidate.cameraMake,
            cameraPrettyName: candidate.cameraPrettyName,
            lensName: candidate.lensName,
            focalLengthMM: candidate.focalLengthMM,
            apertureFNumber: candidate.apertureFNumber,
            perspectiveModelVersion: candidate.version,
            scaleFactor: candidate.scaleFactor ?? conversion.focalScale,
            focalLengthX: candidate.focalLengthX,
            focalLengthY: candidate.focalLengthY,
            imageXCenter: candidate.imageXCenter,
            imageYCenter: candidate.imageYCenter,
            radialParameters: candidate.radial,
            convertedFocalScale: conversion.focalScale,
            convertedK1: conversion.k1,
            convertedK2: conversion.k2,
            convertedK3: conversion.k3,
            convertedP1: conversion.p1,
            convertedP2: conversion.p2,
            convertedPrincipalOffsetX: conversion.principalOffsetX,
            convertedPrincipalOffsetY: conversion.principalOffsetY,
            conversionMaxErrorPixels: conversion.maxErrorPixels,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sourceFilename: url.lastPathComponent,
            cameraMakeMismatch: mismatch,
            priorWeight: mismatch ? 0.15 : 0.35,
            warning: warning
        )
    }

    private static func normalizedMake(_ value: String) -> String {
        value.uppercased().filter(\.isLetter)
    }

    private struct Conversion {
        var focalScale: Double
        var k1: Double
        var k2: Double
        var k3: Double
        var p1: Double
        var p2: Double
        var principalOffsetX: Double?
        var principalOffsetY: Double?
        var maxErrorPixels: Double
    }

    // Adobe PerspectiveModel and PanoLume Brown–Conrady use different model
    // contracts. Sample the Adobe radial mapping across a full-frame 16 mm
    // focal plane, then solve the internal radial basis instead of copying
    // coefficients by field name. ScaleFactor is kept as focal initialization.
    private static func convertAdobePerspectiveModel(_ candidate: LCPParserDelegate.Candidate) throws -> Conversion {
        if let scaleFactor = candidate.scaleFactor, scaleFactor > 0 {
            return try convertScaleFactorPerspectiveModel(
                radial: candidate.radial,
                scaleFactor: scaleFactor,
                focalLengthMM: candidate.focalLengthMM
            )
        }
        return try convertExplicitFocalPerspectiveModel(candidate)
    }

    private static func convertScaleFactorPerspectiveModel(
        radial: [Double],
        scaleFactor: Double,
        focalLengthMM: Double
    ) throws -> Conversion {
        var normal = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var rhs = Array(repeating: 0.0, count: 3)
        struct DenseSample {
            var x: Double
            var y: Double
            var adobeX: Double
            var adobeY: Double
        }
        var samples: [DenseSample] = []
        let maxX = 18.0 / focalLengthMM
        let maxY = 12.0 / focalLengthMM
        for row in 0...32 {
            for column in 0...32 {
                let x = -maxX + 2 * maxX * Double(column) / 32
                let y = -maxY + 2 * maxY * Double(row) / 32
                let r2 = x * x + y * y
                if r2 < 1e-12 { continue }
                let basis = [r2, r2 * r2, r2 * r2 * r2]
                // PerspectiveModel v2 evaluates its own mapping first. Keep
                // that operation distinct from the internal model even though
                // both currently share a radial polynomial basis.
                let adobeShape = 1 + radial[0] * basis[0]
                    + radial[1] * basis[1] + radial[2] * basis[2]
                let adobeX = scaleFactor * x * adobeShape
                let adobeY = scaleFactor * y * adobeShape
                let target = adobeShape - 1
                samples.append(DenseSample(
                    x: x,
                    y: y,
                    adobeX: adobeX,
                    adobeY: adobeY
                ))
                for i in 0..<3 {
                    rhs[i] += basis[i] * target
                    for j in 0..<3 { normal[i][j] += basis[i] * basis[j] }
                }
            }
        }
        guard let coefficients = solve3x3(normal, rhs), coefficients.allSatisfy(\.isFinite) else {
            throw LensCalibrationPriorError.invalidParameters
        }
        let representativeFocalPixels = 5520.0 * focalLengthMM / 24.0
        var maxError = 0.0
        for sample in samples {
            let r2 = sample.x * sample.x + sample.y * sample.y
            let internalShape = 1 + coefficients[0] * r2
                + coefficients[1] * r2 * r2
                + coefficients[2] * r2 * r2 * r2
            let internalX = scaleFactor * sample.x * internalShape
            let internalY = scaleFactor * sample.y * internalShape
            let error = hypot(
                internalX - sample.adobeX,
                internalY - sample.adobeY
            ) * representativeFocalPixels
            maxError = max(maxError, error)
        }
        guard maxError <= 0.05 + 1e-9 else {
            throw LensCalibrationPriorError.conversionTooInaccurate(maxError)
        }
        return Conversion(
            focalScale: scaleFactor,
            k1: coefficients[0],
            k2: coefficients[1],
            k3: coefficients[2],
            p1: 0,
            p2: 0,
            principalOffsetX: nil,
            principalOffsetY: nil,
            maxErrorPixels: maxError
        )
    }

    // Newer mirrorless LCPs replace ScaleFactor with calibrated normalized
    // FocalLengthX/Y and ImageX/YCenter values. Build the Adobe mapping in the
    // recorded pixel frame and fit all five internal Brown–Conrady terms. This
    // also makes unsupported anisotropy observable through the 0.05 px error
    // gate instead of silently treating FocalLengthX as ScaleFactor.
    private static func convertExplicitFocalPerspectiveModel(
        _ candidate: LCPParserDelegate.Candidate
    ) throws -> Conversion {
        guard let focalLengthX = candidate.focalLengthX, focalLengthX > 0,
              let focalLengthY = candidate.focalLengthY ?? candidate.focalLengthX,
              focalLengthY > 0,
              let imageWidth = candidate.imageWidth, imageWidth > 0,
              let imageHeight = candidate.imageHeight, imageHeight > 0 else {
            throw LensCalibrationPriorError.invalidParameters
        }
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let maximumDimension = max(width, height)
        let adobeFocalX = focalLengthX * maximumDimension
        let adobeFocalY = focalLengthY * maximumDimension
        let internalFocal = sqrt(adobeFocalX * adobeFocalY)
        let sensorFormatFactor = candidate.sensorFormatFactor ?? 1.0
        let nominalFocal = candidate.focalLengthMM * sensorFormatFactor
            * hypot(width, height) / 43.266615305567875
        let focalScale = internalFocal / nominalFocal
        let centerX = (candidate.imageXCenter ?? 0.5) * width
        let centerY = (candidate.imageYCenter ?? 0.5) * height
        guard focalScale.isFinite, focalScale > 0.5, focalScale < 2.0,
              centerX.isFinite, centerY.isFinite else {
            throw LensCalibrationPriorError.invalidParameters
        }

        struct DenseSample {
            var x: Double
            var y: Double
            var targetDX: Double
            var targetDY: Double
        }
        var normal = Array(repeating: Array(repeating: 0.0, count: 5), count: 5)
        var rhs = Array(repeating: 0.0, count: 5)
        var samples: [DenseSample] = []
        for row in 0...32 {
            for column in 0...32 {
                let pixelX = width * Double(column) / 32.0
                let pixelY = height * Double(row) / 32.0
                let adobeX = (pixelX - centerX) / adobeFocalX
                let adobeY = (pixelY - centerY) / adobeFocalY
                let adobeR2 = adobeX * adobeX + adobeY * adobeY
                let adobeShape = 1 + candidate.radial[0] * adobeR2
                    + candidate.radial[1] * adobeR2 * adobeR2
                    + candidate.radial[2] * adobeR2 * adobeR2 * adobeR2
                let sourceX = centerX + adobeX * adobeShape * adobeFocalX
                let sourceY = centerY + adobeY * adobeShape * adobeFocalY
                let x = (pixelX - centerX) / internalFocal
                let y = (pixelY - centerY) / internalFocal
                let r2 = x * x + y * y
                let xBasis = [
                    x * r2,
                    x * r2 * r2,
                    x * r2 * r2 * r2,
                    2 * x * y,
                    r2 + 2 * x * x
                ]
                let yBasis = [
                    y * r2,
                    y * r2 * r2,
                    y * r2 * r2 * r2,
                    r2 + 2 * y * y,
                    2 * x * y
                ]
                let targetDX = (sourceX - pixelX) / internalFocal
                let targetDY = (sourceY - pixelY) / internalFocal
                samples.append(DenseSample(x: x, y: y, targetDX: targetDX, targetDY: targetDY))
                for i in 0..<5 {
                    rhs[i] += xBasis[i] * targetDX + yBasis[i] * targetDY
                    for j in 0..<5 {
                        normal[i][j] += xBasis[i] * xBasis[j] + yBasis[i] * yBasis[j]
                    }
                }
            }
        }
        guard let coefficients = solveLinearSystem(normal, rhs),
              coefficients.allSatisfy(\.isFinite) else {
            throw LensCalibrationPriorError.invalidParameters
        }
        var maxError = 0.0
        for sample in samples {
            let r2 = sample.x * sample.x + sample.y * sample.y
            let radial = coefficients[0] * r2 + coefficients[1] * r2 * r2
                + coefficients[2] * r2 * r2 * r2
            let fittedDX = sample.x * radial + 2 * coefficients[3] * sample.x * sample.y
                + coefficients[4] * (r2 + 2 * sample.x * sample.x)
            let fittedDY = sample.y * radial + coefficients[3] * (r2 + 2 * sample.y * sample.y)
                + 2 * coefficients[4] * sample.x * sample.y
            maxError = max(
                maxError,
                hypot(fittedDX - sample.targetDX, fittedDY - sample.targetDY) * internalFocal
            )
        }
        guard maxError <= 0.05 + 1e-9 else {
            throw LensCalibrationPriorError.conversionTooInaccurate(maxError)
        }
        return Conversion(
            focalScale: focalScale,
            k1: coefficients[0],
            k2: coefficients[1],
            k3: coefficients[2],
            p1: coefficients[3],
            p2: coefficients[4],
            principalOffsetX: centerX / width - 0.5,
            principalOffsetY: centerY / height - 0.5,
            maxErrorPixels: maxError
        )
    }

    private static func solveLinearSystem(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        guard !matrix.isEmpty, matrix.count == vector.count,
              matrix.allSatisfy({ $0.count == matrix.count }) else { return nil }
        var a = matrix
        var b = vector
        for pivot in 0..<a.count {
            guard let best = (pivot..<a.count).max(by: {
                abs(a[$0][pivot]) < abs(a[$1][pivot])
            }), abs(a[best][pivot]) > 1e-15 else { return nil }
            if best != pivot {
                a.swapAt(best, pivot)
                b.swapAt(best, pivot)
            }
            let diagonal = a[pivot][pivot]
            for column in pivot..<a.count { a[pivot][column] /= diagonal }
            b[pivot] /= diagonal
            for row in 0..<a.count where row != pivot {
                let factor = a[row][pivot]
                for column in pivot..<a.count { a[row][column] -= factor * a[pivot][column] }
                b[row] -= factor * b[pivot]
            }
        }
        return b
    }

    private static func solve3x3(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = matrix
        var b = vector
        for pivot in 0..<3 {
            guard let best = (pivot..<3).max(by: { abs(a[$0][pivot]) < abs(a[$1][pivot]) }),
                  abs(a[best][pivot]) > 1e-15 else { return nil }
            if best != pivot {
                a.swapAt(best, pivot)
                b.swapAt(best, pivot)
            }
            let diagonal = a[pivot][pivot]
            for column in pivot..<3 { a[pivot][column] /= diagonal }
            b[pivot] /= diagonal
            for row in 0..<3 where row != pivot {
                let factor = a[row][pivot]
                for column in pivot..<3 { a[row][column] -= factor * a[pivot][column] }
                b[row] -= factor * b[pivot]
            }
        }
        return b
    }
}

private final class LCPParserDelegate: NSObject, XMLParserDelegate {
    struct Candidate {
        var profileName = "Unnamed Lens Profile"
        var cameraMake = "Unknown"
        var cameraPrettyName: String?
        var lensName = "Unknown Lens"
        var focalLengthMM = 0.0
        var apertureFNumber: Double?
        var version = 0
        var scaleFactor: Double?
        var focalLengthX: Double?
        var focalLengthY: Double?
        var imageXCenter: Double?
        var imageYCenter: Double?
        var imageWidth: Int?
        var imageHeight: Int?
        var sensorFormatFactor: Double?
        var radial: [Double] = []
    }

    var candidates: [Candidate] = []
    private var current = Candidate()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if attributeDict["stCamera:ProfileName"] != nil
            || attributeDict["stCamera:FocalLength"] != nil {
            current.profileName = attributeDict["stCamera:ProfileName"] ?? current.profileName
            current.cameraMake = attributeDict["stCamera:Make"] ?? current.cameraMake
            current.cameraPrettyName = attributeDict["stCamera:CameraPrettyName"] ?? current.cameraPrettyName
            current.lensName = attributeDict["stCamera:LensPrettyName"]
                ?? attributeDict["stCamera:Lens"] ?? current.lensName
            current.focalLengthMM = Double(attributeDict["stCamera:FocalLength"] ?? "")
                ?? current.focalLengthMM
            current.imageWidth = Int(attributeDict["stCamera:ImageWidth"] ?? "")
                ?? current.imageWidth
            current.imageHeight = Int(attributeDict["stCamera:ImageLength"] ?? "")
                ?? current.imageHeight
            current.sensorFormatFactor = Double(attributeDict["stCamera:SensorFormatFactor"] ?? "")
                ?? current.sensorFormatFactor
            if let apex = Double(attributeDict["stCamera:ApertureValue"] ?? "") {
                current.apertureFNumber = pow(2.0, apex / 2.0)
            }
        }
        guard let first = Double(attributeDict["stCamera:RadialDistortParam1"] ?? ""),
              let second = Double(attributeDict["stCamera:RadialDistortParam2"] ?? ""),
              let third = Double(attributeDict["stCamera:RadialDistortParam3"] ?? "") else { return }
        let scale = Double(attributeDict["stCamera:ScaleFactor"] ?? "")
        let focalLengthX = Double(attributeDict["stCamera:FocalLengthX"] ?? "")
        guard scale != nil || focalLengthX != nil else { return }
        var candidate = current
        candidate.version = Int(attributeDict["stCamera:Version"] ?? "2") ?? 2
        candidate.scaleFactor = scale
        candidate.focalLengthX = focalLengthX
        candidate.focalLengthY = Double(attributeDict["stCamera:FocalLengthY"] ?? "")
        candidate.imageXCenter = Double(attributeDict["stCamera:ImageXCenter"] ?? "")
        candidate.imageYCenter = Double(attributeDict["stCamera:ImageYCenter"] ?? "")
        candidate.radial = [first, second, third]
        candidates.append(candidate)
    }
}
