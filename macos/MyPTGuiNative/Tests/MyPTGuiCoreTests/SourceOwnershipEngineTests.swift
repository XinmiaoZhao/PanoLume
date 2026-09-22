import XCTest
import MyPTGuiEngine

final class SourceOwnershipEngineTests: XCTestCase {
    func testSourceOwnershipCharacterization() {
        XCTAssertEqual(myptgui_source_ownership_characterization_self_test(), 1)
    }
}
