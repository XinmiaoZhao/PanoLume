import MyPTGuiEngine
import XCTest

final class LocalWarpModelTests: XCTestCase {
    func testKnownSmoothWarpRecoveryRespectsDisplacementAndJacobianBounds() {
        XCTAssertEqual(myptgui_local_warp_characterization_self_test(), 1)
    }
}
