import Foundation
import XCTest
import MyPTGuiRegressionSupport

final class SyntheticStandardImageFixtureTests: XCTestCase {
    func testFixtureIsDeterministicAndEachCropIsAnExactReferenceView() {
        let first = SyntheticStandardImageFixture.make()
        let second = SyntheticStandardImageFixture.make()

        XCTAssertEqual(first.reference.width, 720)
        XCTAssertEqual(first.reference.height, 280)
        XCTAssertEqual(first.reference.data, second.reference.data)
        XCTAssertEqual(first.crops.count, 3)
        XCTAssertEqual(first.crops.map(\.origin.x), [0, 160, 320])

        for (cropIndex, crop) in first.crops.enumerated() {
            XCTAssertEqual(crop.pixels.width, 400)
            XCTAssertEqual(crop.pixels.height, first.reference.height)
            XCTAssertEqual(crop.pixels.data, second.crops[cropIndex].pixels.data)

            let originX = Int(crop.origin.x)
            for row in 0..<crop.pixels.height {
                let referenceStart = row * first.reference.bytesPerRow + originX * 4
                let cropStart = row * crop.pixels.bytesPerRow
                XCTAssertEqual(
                    crop.pixels.data[cropStart..<(cropStart + crop.pixels.bytesPerRow)],
                    first.reference.data[referenceStart..<(referenceStart + crop.pixels.bytesPerRow)]
                )
            }
        }

        XCTAssertNotEqual(first.crops[0].pixels.data, first.crops[1].pixels.data)
        XCTAssertNotEqual(first.crops[1].pixels.data, first.crops[2].pixels.data)
    }
}
