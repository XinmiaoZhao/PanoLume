import PanoLumeEngine
import XCTest

final class LocalWarpModelTests: XCTestCase {
    func testKnownSmoothWarpRecoveryRespectsDisplacementAndJacobianBounds() {
        XCTAssertEqual(panolume_local_warp_characterization_self_test(), 1)
    }
}
