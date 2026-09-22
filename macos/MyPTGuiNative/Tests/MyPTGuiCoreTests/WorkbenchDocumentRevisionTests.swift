import XCTest
@testable import MyPTGuiCore

final class WorkbenchDocumentRevisionTests: XCTestCase {
    func testCurrentTicketIsAcceptedUntilDocumentAdvances() {
        var revision = WorkbenchDocumentRevision()
        let original = revision.currentTicket

        XCTAssertTrue(revision.accepts(original))

        let edited = revision.advance()

        XCTAssertFalse(revision.accepts(original))
        XCTAssertTrue(revision.accepts(edited))
    }

    func testEveryEditInvalidatesAllOlderOperationTickets() {
        var revision = WorkbenchDocumentRevision()
        let preview = revision.advance()
        let reoptimize = revision.advance()
        let projectionCommit = revision.advance()

        XCTAssertFalse(revision.accepts(preview))
        XCTAssertFalse(revision.accepts(reoptimize))
        XCTAssertTrue(revision.accepts(projectionCommit))

        let controlPointEdit = revision.advance()

        XCTAssertFalse(revision.accepts(projectionCommit))
        XCTAssertTrue(revision.accepts(controlPointEdit))
    }

    func testReadOnlyExportTicketIsInvalidatedByNextEdit() {
        var revision = WorkbenchDocumentRevision()
        let export = revision.currentTicket

        _ = revision.advance()

        XCTAssertFalse(revision.accepts(export))
    }
}
