import Foundation
import XCTest
@testable import PanoLumeRegressionSupport
import PanoLumeCore

final class SimilarityRegistrationTests: XCTestCase {
    func testRecoversKnownFullResolutionSimilarityTransform() {
        let reference = patternedPixels(width: 256, height: 180)
        let expected = SimilarityTransform(
            scale: 0.723,
            rotationDegrees: 0.35,
            offsetX: 18.25,
            offsetY: 12.75
        )
        let candidate = SimilarityRegistrar.warpReference(
            reference,
            transform: expected,
            canvasWidth: 220,
            canvasHeight: 160
        )

        let result = SimilarityRegistrar.register(reference: reference, candidate: candidate)

        XCTAssertEqual(result.transform.scale, expected.scale, accuracy: 0.006)
        XCTAssertEqual(result.transform.rotationDegrees, expected.rotationDegrees, accuracy: 0.12)
        XCTAssertEqual(result.transform.offsetX, expected.offsetX, accuracy: 0.6)
        XCTAssertEqual(result.transform.offsetY, expected.offsetY, accuracy: 0.6)
        XCTAssertGreaterThan(result.heldOutSamples, 100)
        XCTAssertGreaterThan(result.heldOutInlierRatio, 0.98)
        XCTAssertGreaterThan(result.heldOutScore, 0.98)
    }

    private func patternedPixels(width: Int, height: Int) -> PixelBufferInfo {
        var data = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let dx = Double(x - 164)
                let dy = Double(y - 83)
                let spot = exp(-(dx * dx + dy * dy) / 1_250.0) * 55.0
                let bar = (x > 34 && x < 78 && y > 42 && y < 139) ? 38.0 : 0.0
                let red = 118.0 + 48.0 * sin(Double(x) * 0.091)
                    + 31.0 * cos(Double(y) * 0.137) + spot
                let green = 112.0 + 44.0 * cos(Double(x + y) * 0.057)
                    + 35.0 * sin(Double(y) * 0.103) + bar
                let blue = 105.0 + 42.0 * sin(Double(x - 2 * y) * 0.047)
                    + 29.0 * cos(Double(x) * 0.151) + spot * 0.6
                data[index] = channel(red)
                data[index + 1] = channel(green)
                data[index + 2] = channel(blue)
                data[index + 3] = 255
            }
        }
        return PixelBufferInfo(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    private func channel(_ value: Double) -> UInt8 {
        UInt8(min(250, max(5, Int(value.rounded()))))
    }
}
