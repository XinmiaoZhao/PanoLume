import CryptoKit
import Foundation
import ImageIO

public enum PTSProjectImporter {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let previewSide = 4096

    public static func load(from url: URL, checkFiles: Bool = true, decoder: ProjectInputDecoder = ProjectInputPayload.read) throws -> PTSImportedProject {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= maximumFileBytes else { throw PTSImportError.fileTooLarge(byteCount) }
        let source = try Data(contentsOf: url, options: [.mappedIfSafe])
        let payload = try decoder(source)
        let container = payload.container
        let plaintext = payload.data

        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: plaintext)
        } catch {
            throw PTSImportError.invalidProject("The decoded PTS is not valid UTF-8 JSON: \(error.localizedDescription)")
        }
        let root = try object(rootValue, "root")
        guard try string(root["$schema"], "root.$schema") == "https://www.ptgui.com/schemas/project_v55.schema.json" else {
            throw PTSImportError.unsupported("Only the PTGui 13 v55 JSON schema is supported by this importer.")
        }
        let fileVersion = try integer(root["fileversion"], "root.fileversion")
        guard fileVersion == 55 else {
            throw PTSImportError.unsupported("Unsupported PTGui project file version \(fileVersion); expected v55.")
        }
        let project = try object(root["project"], "root.project")
        let panorama = try object(project["panoramaparams"], "project.panoramaparams")
        let projection = try string(panorama["projection"], "project.panoramaparams.projection")
        guard projection == "stereographic" else {
            throw PTSImportError.unsupported("PTS reconstruction currently supports stereographic panorama output only; found \(projection).")
        }
        let hfov = try finite(panorama["hfov"], "project.panoramaparams.hfov")
        let vfov = try finite(panorama["vfov"], "project.panoramaparams.vfov")
        guard hfov > 0, hfov < 360, vfov > 0, vfov < 360 else {
            throw PTSImportError.invalidProject("Panorama FOV must be finite and between 0 and 360 degrees.")
        }
        let outputCrop = try numberArray(panorama["outputcrop"], "project.panoramaparams.outputcrop")
        guard outputCrop == [0, 0, 1, 1] else {
            throw PTSImportError.unsupported("The first native PTS renderer requires the complete [0,0,1,1] output crop.")
        }

        let globalLenses = try array(project["globallenses"], "project.globallenses")
        let blend = try object(project["blend"], "project.blend")
        let blendEngine = try string(blend["engine"], "project.blend.engine")
        guard blendEngine == "zerooverlap" else {
            throw PTSImportError.unsupported(
                "PTS reconstruction currently supports the zerooverlap blend engine only; found \(blendEngine)."
            )
        }
        let seamFinding = (blend["seamfinding"] as? Bool) ?? true
        guard seamFinding else {
            throw PTSImportError.unsupported("PTS reconstruction requires optimum seam finding to be enabled.")
        }
        let seamFindingPrecision = try integer(
            blend["seamfindingprecision"],
            "project.blend.seamfindingprecision"
        )
        guard (-6...0).contains(seamFindingPrecision) else {
            throw PTSImportError.unsupported(
                "PTS seam finding precision must be between -6 and 0; found \(seamFindingPrecision)."
            )
        }
        let blendSettings = PTSImportedBlendSettings(
            engine: blendEngine,
            seamFinding: seamFinding,
            seamFindingPrecision: seamFindingPrecision,
            maskPushSeams: (blend["maskpushseams"] as? Bool) ?? false
        )
        let groups = try array(project["imagegroups"], "project.imagegroups")
        guard !groups.isEmpty, groups.count <= 2048 else {
            throw PTSImportError.invalidProject("PTS must contain between 1 and 2048 image groups.")
        }
        let separator = (project["pathseparator"] as? String) ?? "/"
        let portraitOrientation = (project["portraitcameraorientation"] as? String) ?? "clockwise"
        var images: [PTSImportedImage] = []
        var endpointIndex: [String: Int] = [:]
        for (groupIndex, groupValue) in groups.enumerated() {
            let group = try object(groupValue, "project.imagegroups[\(groupIndex)]")
            let size = try integerArray(group["size"], "project.imagegroups[\(groupIndex)].size")
            guard size.count == 2, size[0] > 0, size[1] > 0 else {
                throw PTSImportError.invalidProject("Image group \(groupIndex) has an invalid size.")
            }
            guard group["maskbitmap"] == nil || group["maskbitmap"] is NSNull else {
                throw PTSImportError.unsupported("Image group \(groupIndex) contains a mask bitmap; masks are not silently discarded.")
            }
            let globalLensIndex = try integer(group["globallens"], "project.imagegroups[\(groupIndex)].globallens")
            guard globalLenses.indices.contains(globalLensIndex) else {
                throw PTSImportError.invalidProject("Image group \(groupIndex) references missing global lens \(globalLensIndex).")
            }
            let globalLens = try object(globalLenses[globalLensIndex], "project.globallenses[\(globalLensIndex)]")
            let selectedLens = try componentParams(
                nonNull(group["individuallens"]) ?? globalLens["lens"],
                "effective lens for group \(groupIndex)"
            )
            let selectedShift = try componentParams(
                nonNull(group["individualshift"]) ?? globalLens["shift"],
                "effective shift for group \(groupIndex)"
            )
            let selectedShear = try componentParams(
                nonNull(group["individualshear"]) ?? globalLens["shear"],
                "effective shear for group \(groupIndex)"
            )
            guard try string(selectedLens["projection"], "lens.projection") == "rectilinear" else {
                throw PTSImportError.unsupported("Image group \(groupIndex) does not use a rectilinear source lens.")
            }
            for coefficient in ["a", "b", "c"] {
                guard abs(try finite(selectedLens[coefficient], "lens.\(coefficient)")) <= 1e-12 else {
                    throw PTSImportError.unsupported("Image group \(groupIndex) has nonzero PTGui \(coefficient) distortion.")
                }
            }
            guard abs(try finite(selectedShear["hshear"], "shear.hshear")) <= 1e-12,
                  abs(try finite(selectedShear["vshear"], "shear.vshear")) <= 1e-12 else {
                throw PTSImportError.unsupported("Image group \(groupIndex) has nonzero shear.")
            }
            guard selectedLens["croprectanglesize"] == nil || selectedLens["croprectanglesize"] is NSNull else {
                throw PTSImportError.unsupported("Image group \(groupIndex) has a source crop rectangle.")
            }
            let position = try componentParams(group["position"], "project.imagegroups[\(groupIndex)].position")
            for parameter in ["vpx", "vpy", "vpd", "vppan", "vptilt"] {
                guard abs(try finite(position[parameter], "position.\(parameter)")) <= 1e-12 else {
                    throw PTSImportError.unsupported("Image group \(groupIndex) has nonzero viewpoint parameter \(parameter).")
                }
            }
            let yaw = try finite(position["yaw"], "position.yaw")
            let pitch = try finite(position["pitch"], "position.pitch")
            let roll = try finite(position["roll"], "position.roll")
            let positionObject = try object(group["position"], "project.imagegroups[\(groupIndex)].position")
            let positionFlags = try optionalObject(
                positionObject["optimizerflags"],
                "project.imagegroups[\(groupIndex)].position.optimizerflags"
            )
            let focalMM = try finite(selectedLens["focallength"], "lens.focallength")
            let sensorDiagonalMM = try finite(selectedLens["sensordiagonal"], "lens.sensordiagonal")
            guard focalMM > 0, sensorDiagonalMM > 0 else {
                throw PTSImportError.invalidProject("Image group \(groupIndex) has invalid focal length or sensor diagonal.")
            }
            let pixelDiagonal = hypot(Double(size[0]), Double(size[1]))
            let focalPixels = focalMM * pixelDiagonal / sensorDiagonalMM
            let shiftLong = try finite(selectedShift["longside"], "shift.longside")
            let shiftShort = try finite(selectedShift["shortside"], "shift.shortside")
            let relativeShift: (Double, Double)
            if size[1] > size[0] {
                relativeShift = portraitOrientation == "counterclockwise"
                    ? (shiftShort, -shiftLong)
                    : (-shiftShort, shiftLong)
            } else {
                relativeShift = (shiftLong, shiftShort)
            }
            let principalX = Double(size[0]) * 0.5 + relativeShift.0 * pixelDiagonal
            let principalY = Double(size[1]) * 0.5 + relativeShift.1 * pixelDiagonal
            let groupImages = try array(group["images"], "project.imagegroups[\(groupIndex)].images")
            guard !groupImages.isEmpty else {
                throw PTSImportError.invalidProject("Image group \(groupIndex) is empty.")
            }
            for (imageIndex, imageValue) in groupImages.enumerated() {
                let image = try object(imageValue, "project.imagegroups[\(groupIndex)].images[\(imageIndex)]")
                if let include = image["include"] as? Bool, !include { continue }
                let filename = try string(image["filename"], "image.filename")
                let resolvedPath = try resolveSourcePath(
                    filename,
                    separator: separator,
                    projectURL: url,
                    expectedWidth: size[0],
                    expectedHeight: size[1],
                    checkFiles: checkFiles
                )
                let photometric = try optionalObject(image["photometric"], "image.photometric")
                let whitepoint = try optionalObject(photometric?["whitepoint"], "image.photometric.whitepoint")
                let temperature = try whitepoint.map { try finite($0["temperature"], "image.photometric.whitepoint.temperature") }
                let flattenedIndex = images.count
                endpointIndex["\(groupIndex):\(imageIndex)"] = flattenedIndex
                images.append(PTSImportedImage(
                    index: flattenedIndex,
                    groupIndex: groupIndex,
                    imageIndex: imageIndex,
                    path: resolvedPath,
                    width: size[0],
                    height: size[1],
                    yawDegrees: yaw,
                    pitchDegrees: pitch,
                    rollDegrees: roll,
                    focalLengthPixels: focalPixels,
                    principalX: principalX,
                    principalY: principalY,
                    blendWeight: try finite(group["blendweight"] ?? 100, "group.blendweight"),
                    whiteBalanceTemperature: temperature,
                    optimizeYaw: (positionFlags?["yaw"] as? Bool) ?? false,
                    optimizePitch: (positionFlags?["pitch"] as? Bool) ?? false,
                    optimizeRoll: (positionFlags?["roll"] as? Bool) ?? false
                ))
            }
        }
        guard !images.isEmpty else { throw PTSImportError.invalidProject("PTS contains no included images.") }

        let rawPoints = try array(project["controlpoints"], "project.controlpoints")
        guard rawPoints.count <= 250_000 else {
            throw PTSImportError.invalidProject("PTS contains more than 250,000 control points.")
        }
        var controlPoints: [PTSImportedControlPoint] = []
        for (pointIndex, pointValue) in rawPoints.enumerated() {
            let point = try object(pointValue, "project.controlpoints[\(pointIndex)]")
            guard try integer(point["t"], "control point type") == 0 else {
                throw PTSImportError.unsupported("Control point \(pointIndex) is not a normal point pair.")
            }
            let a = try numberArray(point["0"], "control point 0")
            let b = try numberArray(point["1"], "control point 1")
            guard a.count == 4, b.count == 4 else {
                throw PTSImportError.invalidProject("Control point \(pointIndex) has malformed endpoints.")
            }
            let keyA = "\(Int(a[0])):\(Int(a[1]))"
            let keyB = "\(Int(b[0])):\(Int(b[1]))"
            guard let imageA = endpointIndex[keyA], let imageB = endpointIndex[keyB] else {
                throw PTSImportError.invalidProject("Control point \(pointIndex) references an excluded or missing image.")
            }
            controlPoints.append(PTSImportedControlPoint(
                imageAIndex: imageA, imageBIndex: imageB,
                xA: a[2], yA: a[3], xB: b[2], yB: b[3]
            ))
        }
        let graph = graphSummary(imageCount: images.count, points: controlPoints)
        let residuals = controlPointResiduals(images: images, points: controlPoints)
        let centerFocal = images.map(\.focalLengthPixels).sorted()[images.count / 2]
        let fullWidth = max(1, Int((4 * centerFocal * tan(hfov * .pi / 720)).rounded()))
        let fullHeight = max(1, Int((4 * centerFocal * tan(vfov * .pi / 720)).rounded()))
        let optimizer = try optionalObject(project["optimizer"], "project.optimizer")
        let simpleMode = try optionalObject(optimizer?["simplemodesettings"], "project.optimizer.simplemodesettings")
        let anchorGroup = (simpleMode?["anchorimagegroup"] as? NSNumber)?.intValue ?? 0
        let anchorImageIndex = images.firstIndex { $0.groupIndex == anchorGroup } ?? 0

        return PTSImportedProject(
            schemaVersion: 2,
            projectPath: url.standardizedFileURL.path,
            container: container,
            sourceSHA256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            plaintextSHA256: SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined(),
            software: (root["software"] as? String) ?? "unknown",
            fileVersion: fileVersion,
            projection: projection,
            horizontalFOVDegrees: hfov,
            verticalFOVDegrees: vfov,
            previewWidth: previewSide,
            previewHeight: previewSide,
            fullWidth: fullWidth,
            fullHeight: fullHeight,
            anchorImageIndex: anchorImageIndex,
            blendSettings: blendSettings,
            images: images,
            controlPoints: controlPoints,
            connectedPairCount: graph.pairCount,
            connectedGraph: graph.connected,
            residuals: residuals
        )
    }



    private static func resolveSourcePath(
        _ filename: String,
        separator: String,
        projectURL: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        checkFiles: Bool
    ) throws -> String {
        let normalized = separator == "\\" ? filename.replacingOccurrences(of: "\\", with: "/") : filename
        let projectDirectory = projectURL.deletingLastPathComponent().standardizedFileURL
        let referencedURL = normalized.hasPrefix("/")
            ? URL(fileURLWithPath: normalized).standardizedFileURL
            : projectDirectory.appendingPathComponent(normalized).standardizedFileURL
        guard checkFiles else { return referencedURL.path }

        if FileManager.default.fileExists(atPath: referencedURL.path) {
            try validateSourceDimensions(
                referencedURL,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
            return referencedURL.path
        }

        let basename = URL(fileURLWithPath: normalized).lastPathComponent
        var candidates: [URL] = []
        var seen = Set<String>()
        func appendCandidate(_ candidate: URL) {
            let standardized = candidate.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else { return }
            candidates.append(standardized)
        }
        appendCandidate(projectDirectory.appendingPathComponent(basename))
        if let enumerator = FileManager.default.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let candidate as URL in enumerator where candidate.lastPathComponent == basename {
                appendCandidate(candidate)
            }
        }
        var matching: [URL] = []
        var dimensionDescriptions: [String] = []
        for candidate in candidates {
            if let dimensions = sourceDimensions(candidate) {
                dimensionDescriptions.append("\(candidate.path) is \(dimensions.width)×\(dimensions.height)")
                if dimensions.width == expectedWidth, dimensions.height == expectedHeight {
                    matching.append(candidate)
                }
            }
        }
        if matching.count == 1 { return matching[0].path }
        if matching.count > 1 {
            throw PTSImportError.invalidProject(
                "Referenced source is missing and relocation is ambiguous for \(basename): "
                    + matching.map(\.path).joined(separator: ", ")
            )
        }
        if !candidates.isEmpty {
            throw PTSImportError.invalidProject(
                "No relocated \(basename) matches the declared \(expectedWidth)×\(expectedHeight) dimensions. "
                    + dimensionDescriptions.joined(separator: "; ")
            )
        }
        throw PTSImportError.invalidProject("Referenced source image does not exist: \(referencedURL.path)")
    }

    private static func validateSourceDimensions(
        _ url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        guard let dimensions = sourceDimensions(url) else {
            throw PTSImportError.invalidProject("Referenced source image metadata cannot be read: \(url.path)")
        }
        guard dimensions.width == expectedWidth, dimensions.height == expectedHeight else {
            throw PTSImportError.invalidProject(
                "Referenced source image dimension mismatch for \(url.path): PTS declares "
                    + "\(expectedWidth)×\(expectedHeight), file is \(dimensions.width)×\(dimensions.height)."
            )
        }
    }

    private static func sourceDimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return (width.intValue, height.intValue)
    }

    private static func graphSummary(
        imageCount: Int,
        points: [PTSImportedControlPoint]
    ) -> (pairCount: Int, connected: Bool) {
        var pairs = Set<String>()
        var adjacency = Array(repeating: Set<Int>(), count: imageCount)
        for point in points where point.imageAIndex != point.imageBIndex {
            let lo = min(point.imageAIndex, point.imageBIndex)
            let hi = max(point.imageAIndex, point.imageBIndex)
            pairs.insert("\(lo):\(hi)")
            adjacency[lo].insert(hi)
            adjacency[hi].insert(lo)
        }
        var visited = Set<Int>()
        var queue = imageCount > 0 ? [0] : []
        while let current = queue.popLast() {
            guard visited.insert(current).inserted else { continue }
            queue.append(contentsOf: adjacency[current].filter { !visited.contains($0) })
        }
        return (pairs.count, visited.count == imageCount)
    }

    private struct Vector3 {
        var x: Double
        var y: Double
        var z: Double
        func dot(_ other: Vector3) -> Double { x * other.x + y * other.y + z * other.z }
        func normalized() -> Vector3 {
            let length = sqrt(dot(self))
            return Vector3(x: x / length, y: y / length, z: z / length)
        }
    }

    private static func worldRay(image: PTSImportedImage, x: Double, y: Double) -> Vector3 {
        let source = Vector3(
            x: (x - image.principalX) / image.focalLengthPixels,
            y: (y - image.principalY) / image.focalLengthPixels,
            z: 1
        ).normalized()
        let yaw = image.yawDegrees * .pi / 180
        let pitch = image.pitchDegrees * .pi / 180
        let roll = image.rollDegrees * .pi / 180
        let rz = Vector3(
            x: cos(roll) * source.x - sin(roll) * source.y,
            y: sin(roll) * source.x + cos(roll) * source.y,
            z: source.z
        )
        let rx = Vector3(
            x: rz.x,
            y: cos(pitch) * rz.y - sin(pitch) * rz.z,
            z: sin(pitch) * rz.y + cos(pitch) * rz.z
        )
        return Vector3(
            x: cos(yaw) * rx.x + sin(yaw) * rx.z,
            y: rx.y,
            z: -sin(yaw) * rx.x + cos(yaw) * rx.z
        ).normalized()
    }

    private static func controlPointResiduals(
        images: [PTSImportedImage],
        points: [PTSImportedControlPoint]
    ) -> PTSControlPointResiduals {
        let values = points.map { point -> Double in
            let a = worldRay(image: images[point.imageAIndex], x: point.xA, y: point.yA)
            let b = worldRay(image: images[point.imageBIndex], x: point.xB, y: point.yB)
            return acos(max(-1, min(1, a.dot(b)))) * 180 / .pi
        }.sorted()
        guard !values.isEmpty else {
            return PTSControlPointResiduals(medianDegrees: .infinity, p95Degrees: .infinity, maximumDegrees: .infinity, passed: false)
        }
        func percentile(_ p: Double) -> Double {
            let index = Int((Double(values.count - 1) * p).rounded(.up))
            return values[min(values.count - 1, max(0, index))]
        }
        let median = percentile(0.5)
        let p95 = percentile(0.95)
        let maximum = values.last ?? .infinity
        return PTSControlPointResiduals(
            medianDegrees: median,
            p95Degrees: p95,
            maximumDegrees: maximum,
            passed: median <= 0.15 && p95 <= 0.35 && maximum <= 0.60
        )
    }

    private static func nonNull(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    private static func object(_ value: Any?, _ location: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw PTSImportError.invalidProject("\(location) must be an object.")
        }
        return result
    }

    private static func optionalObject(_ value: Any?, _ location: String) throws -> [String: Any]? {
        guard let value = nonNull(value) else { return nil }
        return try object(value, location)
    }

    private static func array(_ value: Any?, _ location: String) throws -> [Any] {
        guard let result = value as? [Any] else {
            throw PTSImportError.invalidProject("\(location) must be an array.")
        }
        return result
    }

    private static func componentParams(_ value: Any?, _ location: String) throws -> [String: Any] {
        let component = try object(value, location)
        return try object(component["params"], "\(location).params")
    }

    private static func string(_ value: Any?, _ location: String) throws -> String {
        guard let result = value as? String, !result.isEmpty else {
            throw PTSImportError.invalidProject("\(location) must be a nonempty string.")
        }
        return result
    }

    private static func finite(_ value: Any?, _ location: String) throws -> Double {
        guard let number = value as? NSNumber else {
            throw PTSImportError.invalidProject("\(location) must be numeric.")
        }
        let result = number.doubleValue
        guard result.isFinite else { throw PTSImportError.invalidProject("\(location) must be finite.") }
        return result
    }

    private static func integer(_ value: Any?, _ location: String) throws -> Int {
        let number = try finite(value, location)
        guard number.rounded() == number else {
            throw PTSImportError.invalidProject("\(location) must be an integer.")
        }
        return Int(number)
    }

    private static func numberArray(_ value: Any?, _ location: String) throws -> [Double] {
        try array(value, location).enumerated().map { try finite($0.element, "\(location)[\($0.offset)]") }
    }

    private static func integerArray(_ value: Any?, _ location: String) throws -> [Int] {
        try array(value, location).enumerated().map { try integer($0.element, "\(location)[\($0.offset)]") }
    }
}
