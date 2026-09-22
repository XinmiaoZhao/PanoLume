import XCTest
import PanoLumeEngine

final class SourceOwnershipEngineTests: XCTestCase {
    func testSourceOwnershipCharacterization() {
        XCTAssertEqual(panolume_source_ownership_characterization_self_test(), 1)
    }
}
