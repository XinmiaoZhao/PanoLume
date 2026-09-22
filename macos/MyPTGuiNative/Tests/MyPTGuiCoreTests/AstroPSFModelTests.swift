import XCTest
import MyPTGuiEngine

final class AstroPSFModelTests: XCTestCase {
    func testIndependentEllipticalGaussianFitRecoversSyntheticCentroidAndCovariance() {
        XCTAssertEqual(myptgui_astro_psf_characterization_self_test(), 1)
    }
}
