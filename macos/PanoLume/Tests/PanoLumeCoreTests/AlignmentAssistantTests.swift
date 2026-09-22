import XCTest
@testable import PanoLumeCore

final class AlignmentAssistantTests: XCTestCase {
    func testAssistantReportsOnlyObservedDisconnectedAndRejectedEvidence() {
        let result = makeResult(
            imageCount: 3,
            points: [],
            selectedEdges: [edge(0, 1, p95: 1.2)],
            rejectedEdges: [.object(["i": .number(0), "j": .number(1)])]
        )

        let suggestions = AlignmentAssistant.build(result: result, controlPointsDirty: false)

        XCTAssertTrue(suggestions.contains { $0.kind == .isolatedImage && $0.imageAIndex == 2 })
        XCTAssertTrue(suggestions.contains { $0.kind == .rejectedEdge && $0.imageAIndex == 0 && $0.imageBIndex == 1 })
        XCTAssertFalse(suggestions.contains { $0.imageAIndex == 1 && $0.imageBIndex == 2 })
    }

    func testConcentratedPointsSuggestEmptyDeterministicQuadrant() throws {
        var points: [ControlPoint] = []
        for index in 0..<6 {
            let coordinate = Double(10 + index)
            points.append(ControlPoint(
                imageAIndex: 0,
                imageBIndex: 1,
                xA: coordinate,
                yA: coordinate,
                xB: coordinate + 10,
                yB: coordinate + 10,
                error: 0.5
            ))
        }
        let result = makeResult(imageCount: 2, points: points, selectedEdges: [edge(0, 1, p95: 0.8)])

        let suggestion = try XCTUnwrap(
            AlignmentAssistant.build(result: result, controlPointsDirty: true)
                .first { $0.kind == .concentratedPoints }
        )

        XCTAssertEqual(suggestion.suggestedRegionA, NormalizedImageRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(suggestion.isStale)
        XCTAssertTrue(suggestion.actionLabel.contains("If real overlap exists"))
    }

    func testOrdinaryCameraEvidenceRemainsProductionLocked() throws {
        var result = makeResult(
            imageCount: 2,
            points: [],
            selectedEdges: [edge(0, 1, p95: 0.7, validation: 10, heldOut: 12)]
        )
        result.projectionGeometryState = .verifiedCamera
        result.geometryQualityGatePassed = true
        result.cameraParams = [camera(), camera()]
        guard case .object(var diagnostics) = result.diagnostics else {
            return XCTFail("diagnostics must be an object")
        }
        diagnostics["alignment_family"] = .string("sift")
        result.diagnostics = .object(diagnostics)

        let evidence = try XCTUnwrap(CameraVerificationEvidence.build(result: result))

        XCTAssertEqual(evidence.kind, .ordinaryHeldOut)
        XCTAssertTrue(evidence.qualityGatePassed)
        XCTAssertFalse(evidence.productionEligible)
        XCTAssertEqual(evidence.independentlyValidatedEdgeCount, 1)
    }

    private func edge(
        _ i: Int,
        _ j: Int,
        p95: Double,
        validation: Int = 0,
        heldOut: Int = 0
    ) -> JSONValue {
        .object([
            "i": .number(Double(i)),
            "j": .number(Double(j)),
            "adaptive_coverage_attempted": .bool(false),
            "adaptive_coverage_accepted": .bool(false),
            "adaptive_coverage_reject_reason": .string(""),
            "partitions": .object([
                "identity_association_p95_px": .number(p95),
                "validation_count": .number(Double(validation)),
                "final_held_out_count": .number(Double(heldOut)),
            ]),
        ])
    }

    private func camera() -> CameraParams {
        CameraParams(
            rotation: [0, 0, 0],
            translation: [0, 0, 0],
            focalLength: 100,
            k1: 0,
            k2: 0,
            k3: 0,
            p1: 0,
            p2: 0
        )
    }

    private func makeResult(
        imageCount: Int,
        points: [ControlPoint],
        selectedEdges: [JSONValue],
        rejectedEdges: [JSONValue] = []
    ) -> StitchResult {
        StitchResult(
            handle: "assistant",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 200, height: 100, channels: 3, bitDepth: 16),
            cameraParams: [],
            controlPoints: points,
            sourceImages: (0..<imageCount).map { index in
                ResultSourceImage(
                    handle: "image-\(index)",
                    path: "/tmp/image-\(index).tif",
                    width: 100,
                    height: 100,
                    channels: 3,
                    bitDepth: 16,
                    status: .loaded,
                    unsupportedReason: nil
                )
            },
            diagnostics: .object([
                "selected_edges": .array(selectedEdges),
                "star_edge_recovery": .object([
                    "rejected_camera_edges": .array(rejectedEdges),
                ]),
            ])
        )
    }
}
