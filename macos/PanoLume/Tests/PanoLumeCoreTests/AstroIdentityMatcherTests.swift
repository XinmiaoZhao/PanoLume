import PanoLumeEngine
import XCTest

final class AstroIdentityMatcherTests: XCTestCase {
    func testRotationInvariantDescriptorAndMinimumCostAssignmentCharacterization() {
        XCTAssertEqual(panolume_identity_matcher_characterization_self_test(), 1)
    }
}
