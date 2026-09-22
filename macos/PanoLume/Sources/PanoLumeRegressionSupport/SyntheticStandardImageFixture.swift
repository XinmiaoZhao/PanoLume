import CoreGraphics
import Foundation
import PanoLumeCore

/// A deterministic, native-only ordinary-image fixture used by release regression.
///
/// The three crops are exact, overlapping views into `reference`. Their known
/// translations make them a strict test of SIFT/homography selection and
/// rendering without introducing an external fixture or Python dependency.
public struct SyntheticStandardImageFixture: Sendable {
    public struct Crop: Sendable {
        public var pixels: PixelBufferInfo
        public var origin: CGPoint

        public init(pixels: PixelBufferInfo, origin: CGPoint) {
            self.pixels = pixels
            self.origin = origin
        }
    }

    public var reference: PixelBufferInfo
    public var crops: [Crop]

    public init(reference: PixelBufferInfo, crops: [Crop]) {
        self.reference = reference
        self.crops = crops
    }

    public static func make() -> SyntheticStandardImageFixture {
        let reference = makeReference(width: 720, height: 280)
        let cropWidth = 400
        let origins = [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 0), CGPoint(x: 320, y: 0)]
        let crops = origins.map { origin in
            Crop(
                pixels: crop(
                    reference,
                    x: Int(origin.x),
                    y: Int(origin.y),
                    width: cropWidth,
                    height: reference.height
                ),
                origin: origin
            )
        }
        return SyntheticStandardImageFixture(reference: reference, crops: crops)
    }

    private static func makeReference(width: Int, height: Int) -> PixelBufferInfo {
        var data = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * width * 4 + x * 4
                let hash = textureHash(x: x, y: y)
                let checker = ((x / 19 + y / 17) & 1) == 0 ? 24.0 : -18.0
                let verticalMark = x % 83 < 4 ? 34.0 : 0.0
                let horizontalMark = y % 61 < 3 ? 28.0 : 0.0
                let dx = Double(x - 517)
                let dy = Double(y - 173)
                let landmark = exp(-(dx * dx + dy * dy) / 1_150.0) * 58.0
                let noise0 = Double(hash & 0xff) - 127.5
                let noise1 = Double((hash >> 8) & 0xff) - 127.5
                let noise2 = Double((hash >> 16) & 0xff) - 127.5

                data[offset] = channel(
                    118.0 + checker + verticalMark + 0.31 * noise0
                        + 25.0 * sin(Double(x + 2 * y) * 0.041) + landmark
                )
                data[offset + 1] = channel(
                    112.0 - checker * 0.45 + horizontalMark + 0.29 * noise1
                        + 27.0 * cos(Double(2 * x - y) * 0.037)
                )
                data[offset + 2] = channel(
                    108.0 + checker * 0.25 + 0.33 * noise2
                        + 23.0 * sin(Double(x - 3 * y) * 0.029) + landmark * 0.55
                )
                data[offset + 3] = 255
            }
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    private static func textureHash(x: Int, y: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: x) &* 0x9e37_79b1
        value ^= UInt32(truncatingIfNeeded: y) &* 0x85eb_ca77
        value ^= UInt32(truncatingIfNeeded: x &* y) &* 0xc2b2_ae3d
        value ^= value >> 16
        value &*= 0x7feb_352d
        value ^= value >> 15
        value &*= 0x846c_a68b
        return value ^ (value >> 16)
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(min(250, max(5, Int(value.rounded()))))
    }

    private static func crop(
        _ source: PixelBufferInfo,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> PixelBufferInfo {
        precondition(x >= 0 && y >= 0 && x + width <= source.width && y + height <= source.height)
        var data = Data(count: width * height * 4)
        for row in 0..<height {
            let sourceStart = (y + row) * source.bytesPerRow + x * 4
            let destinationStart = row * width * 4
            data.replaceSubrange(
                destinationStart..<(destinationStart + width * 4),
                with: source.data[sourceStart..<(sourceStart + width * 4)]
            )
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }
}
