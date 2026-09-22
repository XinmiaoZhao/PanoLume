import MyPTGuiEngine
import XCTest

final class AstroIdentityMatcherTests: XCTestCase {
    func testRotationInvariantDescriptorAndMinimumCostAssignmentCharacterization() {
        XCTAssertEqual(myptgui_identity_matcher_characterization_self_test(), 1)
    }
}
