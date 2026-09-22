import XCTest
import PanoLumeEngine

final class AstroPSFModelTests: XCTestCase {
    func testIndependentEllipticalGaussianFitRecoversSyntheticCentroidAndCovariance() {
        XCTAssertEqual(panolume_astro_psf_characterization_self_test(), 1)
    }
}
