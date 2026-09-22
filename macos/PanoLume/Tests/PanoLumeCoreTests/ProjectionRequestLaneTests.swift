import XCTest
@testable import PanoLumeCore

final class ProjectionRequestLaneTests: XCTestCase {
    func testConsecutiveDragsKeepOnlyNewestPendingRequest() throws {
        var lane = ProjectionRequestLane<String>()
        _ = try XCTUnwrap(lane.enqueue("drag-1", kind: .drag))
        let active = try XCTUnwrap(lane.activateNext())

        _ = try XCTUnwrap(lane.enqueue("drag-2", kind: .drag))
        let newest = try XCTUnwrap(lane.enqueue("drag-3", kind: .drag))

        XCTAssertEqual(lane.active?.request, "drag-1")
        XCTAssertEqual(lane.pending?.request, "drag-3")
        XCTAssertEqual(lane.pending?.version, newest.entry.version)
        XCTAssertFalse(newest.shouldCancelActive)
        XCTAssertTrue(lane.accepts(active))
    }

    func testReleaseReplacesPendingDragAndRejectsLaterDragUntilCommit() throws {
        var lane = ProjectionRequestLane<String>()
        _ = try XCTUnwrap(lane.enqueue("active-drag", kind: .drag))
        let activeDrag = try XCTUnwrap(lane.activateNext())
        _ = try XCTUnwrap(lane.enqueue("pending-drag", kind: .drag))

        let releaseOutcome = try XCTUnwrap(lane.enqueue("release", kind: .release))
        let releaseVersion = releaseOutcome.entry.version

        XCTAssertTrue(releaseOutcome.shouldCancelActive)
        XCTAssertEqual(lane.pending?.request, "release")
        XCTAssertEqual(lane.pending?.kind, .release)
        XCTAssertFalse(lane.acceptsDrag)
        XCTAssertNil(lane.enqueue("late-drag", kind: .drag))
        XCTAssertEqual(lane.latestVersion, releaseVersion)

        XCTAssertTrue(lane.finish(activeDrag))
        let release = try XCTUnwrap(lane.activateNext())
        XCTAssertEqual(release.request, "release")
        XCTAssertTrue(lane.accepts(release))
        XCTAssertFalse(lane.acceptsDrag)
        XCTAssertTrue(lane.finish(release))
        XCTAssertTrue(lane.acceptsDrag)
    }

    func testActiveDragCanPublishWhileNewestDragWaits() throws {
        var lane = ProjectionRequestLane<String>()
        _ = try XCTUnwrap(lane.enqueue("old-active", kind: .drag))
        let oldActive = try XCTUnwrap(lane.activateNext())

        let latest = try XCTUnwrap(lane.enqueue("latest", kind: .drag))

        XCTAssertFalse(latest.shouldCancelActive)
        XCTAssertTrue(lane.accepts(oldActive))
        XCTAssertTrue(lane.finish(oldActive))
        XCTAssertFalse(lane.accepts(oldActive))

        let latestActive = try XCTUnwrap(lane.activateNext())
        XCTAssertEqual(latestActive.version, latest.entry.version)
        XCTAssertTrue(lane.accepts(latestActive))
    }

    func testCommittedReleasePermanentlyRejectsOlderLowResolutionEntry() throws {
        var lane = ProjectionRequestLane<String>()
        _ = try XCTUnwrap(lane.enqueue("low-resolution", kind: .drag))
        let lowResolution = try XCTUnwrap(lane.activateNext())
        _ = try XCTUnwrap(lane.enqueue("high-quality-release", kind: .release))

        XCTAssertFalse(lane.accepts(lowResolution))
        XCTAssertTrue(lane.finish(lowResolution))

        let release = try XCTUnwrap(lane.activateNext())
        XCTAssertTrue(lane.accepts(release))
        XCTAssertTrue(lane.finish(release))

        // This models a delayed drag callback arriving after the release frame
        // was published and its lane entry completed.
        XCTAssertFalse(lane.accepts(lowResolution))
        XCTAssertFalse(lane.finish(lowResolution))
    }
}
