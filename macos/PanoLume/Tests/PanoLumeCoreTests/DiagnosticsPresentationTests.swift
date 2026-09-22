import XCTest
@testable import PanoLumeCore

final class DiagnosticsPresentationTests: XCTestCase {
    func testPresentationMapsNativeKeysToUserFacingSections() {
        let result = sampleResult()
        let gate = ParityGateResult(passed: true, reason: "certified", missing: [])

        let presentation = DiagnosticsPresentation.build(result: result, gate: gate)

        XCTAssertEqual(presentation.statusTitle, "Ready")
        XCTAssertEqual(presentation.sections.map(\.title), ["Overview", "Alignment", "Refinement", "Rendering"])
        XCTAssertEqual(metric("Geometry", in: presentation)?.value, "Camera panorama")
        XCTAssertEqual(metric("Geometry quality gate", in: presentation)?.value, "Passed")
        XCTAssertEqual(metric("Control points", in: presentation)?.value, "2")
        XCTAssertEqual(metric("Control-point P95", in: presentation)?.value, "1.45 px")
        XCTAssertEqual(metric("Manual control points", in: presentation)?.value, "1 input · 1 accepted · 0 rejected")
        XCTAssertEqual(metric("Star-edge recovery", in: presentation)?.value, "3 attempts · 1 accepted")
        XCTAssertEqual(metric("Rejected camera edges", in: presentation)?.value, "C1 a.raw ↔ C2 b.raw")
        XCTAssertEqual(metric("Camera tree rebuilds", in: presentation)?.value, "2 · final pass")
        XCTAssertEqual(metric("Re-optimization method", in: presentation)?.value, "Edited Pair Graph Camera Promotion")
        XCTAssertEqual(metric("Preview renderer", in: presentation)?.value, "Metal Quality")
    }

    func testDirtyGateOverridesStaleEngineCompletion() {
        let result = sampleResult()
        let gate = ParityGateResult(
            passed: false,
            reason: "Control points changed. Re-optimize before relying on this geometry.",
            missing: []
        )

        let presentation = DiagnosticsPresentation.build(
            result: result,
            gate: gate,
            controlPointsDirty: true
        )

        XCTAssertEqual(presentation.statusTitle, "Needs attention")
        XCTAssertEqual(presentation.statusMessage, gate.reason)
        XCTAssertEqual(metric("Control-point RMS", in: presentation)?.value, "Pending re-optimization")
        XCTAssertEqual(metric("Manual control points", in: presentation)?.value, "Pending re-optimization")
    }

    func testVerifiedCameraPresentsDraftFailureAsHistory() throws {
        var result = sampleResult()
        result.projectionGeometryState = .verifiedCamera
        result.geometryQualityGatePassed = true
        guard case .object(var diagnostics) = result.diagnostics else {
            return XCTFail("sample diagnostics must be an object")
        }
        diagnostics["camera_model"] = .object([
            "quality_gate_passed": .bool(false),
            "quality_gate_reason": .string("draft held-out count was below eight"),
        ])
        result.diagnostics = .object(diagnostics)

        let presentation = DiagnosticsPresentation.build(
            result: result,
            gate: ParityGateResult(passed: true, reason: "certified", missing: [])
        )

        let history = try XCTUnwrap(metric("Draft camera history", in: presentation))
        XCTAssertEqual(history.severity, .normal)
        XCTAssertTrue(history.value.contains("recovered by verified camera geometry"))
        XCTAssertNil(metric("Camera quality note", in: presentation))
    }

    func testOperationScopedExportMemoryIsDistinguishedFromProcessPeak() throws {
        let profile: JSONValue = .object([
            "renderer_used": .string("cpu"),
            "peak_memory_mb": .number(7800),
            "operation_peak_rss_mb": .number(1240),
            "operation_peak_rss_delta_mb": .number(320),
            "mapped_source_bytes_peak": .number(268_435_456),
            "spool_bytes_peak": .number(536_870_912),
            "active_source_leases_peak": .number(1),
            "cleanup_outcome": .string("completed"),
        ])

        let presentation = DiagnosticsPresentation.build(
            result: sampleResult(),
            gate: ParityGateResult(passed: true, reason: "certified", missing: []),
            exportProfile: profile
        )

        XCTAssertEqual(metric("Process peak memory", in: presentation)?.value, "7800 MB")
        XCTAssertEqual(metric("Export sampled peak", in: presentation)?.value, "1240 MB")
        XCTAssertEqual(metric("Export RSS increase", in: presentation)?.value, "320 MB")
        XCTAssertEqual(metric("Peak source leases", in: presentation)?.value, "1")
        XCTAssertTrue(try XCTUnwrap(metric("Temporary RGB16 spool", in: presentation)?.help).contains("Completed"))
    }

    func testManualControlPointCodableRoundTrip() throws {
        let point = ControlPoint(
            imageAIndex: 0,
            imageBIndex: 1,
            xA: 12.5,
            yA: 20.25,
            xB: 15.5,
            yB: 22.25,
            isManual: true
        )

        let decoded = try JSONDecoder().decode(
            ControlPoint.self,
            from: JSONEncoder().encode(point)
        )

        XCTAssertEqual(decoded, point)
        XCTAssertTrue(decoded.isManual)
    }

    func testAspectFitMappingAccountsForLetterboxOffsetsAndClampsEdges() throws {
        let mapper = AspectFitCoordinateMapper(
            imageSize: CGSize(width: 400, height: 200),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 300)
        )

        XCTAssertEqual(mapper.imageRect, CGRect(x: 0, y: 75, width: 300, height: 150))
        XCTAssertNil(mapper.imagePoint(fromViewPoint: CGPoint(x: 150, y: 30)))
        let center = try XCTUnwrap(mapper.imagePoint(fromViewPoint: CGPoint(x: 150, y: 150)))
        XCTAssertEqual(center.x, 200, accuracy: 0.001)
        XCTAssertEqual(center.y, 100, accuracy: 0.001)

        let bottomRight = try XCTUnwrap(mapper.imagePoint(fromViewPoint: CGPoint(x: 299.999, y: 224.999)))
        XCTAssertEqual(bottomRight.x, 399, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 199, accuracy: 0.001)
        let roundTrip = mapper.viewPoint(fromImagePoint: CGPoint(x: 200, y: 100))
        XCTAssertEqual(roundTrip.x, 150, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, 150, accuracy: 0.001)
    }

    func testPresentationBuildDoesNotEncodeDiagnosticsJSON() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("PanoLumeCore")
            .appendingPathComponent("DiagnosticsPresentation.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("JSONEncoder"),
            "Opening Diagnostics must derive typed metrics without encoding the complete native report."
        )
        XCTAssertFalse(
            source.contains("JSONSerialization"),
            "Opening Diagnostics must not serialize the complete native report through Foundation either."
        )
    }

    func testLargePresentationBuildStaysWithinInteractiveBudget() {
        let result = largeResult(controlPointCount: 11_500)
        let gate = ParityGateResult(passed: true, reason: "certified", missing: [])

        // Warm caches and one-time Foundation formatting before measuring the
        // same synchronous work performed when the Diagnostics tab opens.
        var performanceSink = DiagnosticsPresentation.build(result: result, gate: gate)

        let clock = ContinuousClock()
        var elapsedMilliseconds: [Double] = []
        for _ in 0..<5 {
            let start = clock.now
            performanceSink = DiagnosticsPresentation.build(result: result, gate: gate)
            let elapsed = start.duration(to: clock.now)
            elapsedMilliseconds.append(milliseconds(elapsed))
        }
        elapsedMilliseconds.sort()
        let medianMilliseconds = elapsedMilliseconds[elapsedMilliseconds.count / 2]
        print(String(
            format: "DiagnosticsPresentation 11,500-point median %.3f ms (samples: %@)",
            medianMilliseconds,
            elapsedMilliseconds.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        ))

        XCTAssertEqual(performanceSink.sections.count, 4)
        XCTAssertEqual(metric("Control points", in: performanceSink)?.value, "11500")
        XCTAssertLessThan(
            medianMilliseconds,
            100.0,
            "Diagnostics presentation median was \(medianMilliseconds) ms; the certification target is <=100 ms. Samples: \(elapsedMilliseconds)"
        )
    }

    private func sampleResult() -> StitchResult {
        StitchResult(
            handle: "diagnostic",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 1200, height: 600, channels: 3, bitDepth: 16),
            cameraParams: [],
            controlPoints: [
                ControlPoint(imageAIndex: 0, imageBIndex: 1, xA: 1, yA: 2, xB: 3, yB: 4, error: 0.5),
                ControlPoint(imageAIndex: 0, imageBIndex: 1, xA: 5, yA: 6, xB: 7, yB: 8, error: 1.5, isManual: true),
            ],
            sourceImages: [
                ResultSourceImage(handle: "a", path: "/tmp/a.raw", width: 100, height: 80, channels: 3, bitDepth: 16, status: .loaded, unsupportedReason: nil),
                ResultSourceImage(handle: "b", path: "/tmp/b.raw", width: 100, height: 80, channels: 3, bitDepth: 16, status: .loaded, unsupportedReason: nil),
            ],
            diagnostics: .object([
                "geometry": .string("camera"),
                "preview_status": .string("camera_projection_preview"),
                "blend_mode": .string("feather"),
                "preview_renderer_used": .string("metal_quality"),
                "preview_renderer_fallback": .bool(false),
                "geometry_gate": .object([
                    "passed": .bool(true),
                    "reason": .string("all selected edges passed P95"),
                ]),
                "reoptimization_method": .string("edited_pair_graph_camera_promotion"),
                "star_edge_recovery": .object([
                    "attempts": .number(3),
                    "accepted": .number(1),
                    "rejected_camera_edges": .array([
                        .object(["i": .number(0), "j": .number(1)]),
                    ]),
                    "camera_tree_attempts": .array([
                        .object(["success": .bool(false), "reason": .string("bad edge")]),
                        .object(["success": .bool(true), "reason": .string("passed")]),
                    ]),
                ]),
                "completion_gate": .object(["passed": .bool(true)]),
                "manual_point_filtering": .object([
                    "input": .number(1),
                    "accepted": .number(1),
                    "rejected": .number(0),
                    "reason": .string("all manual control points passed robust filtering"),
                ]),
            ])
        )
    }

    private func largeResult(controlPointCount: Int) -> StitchResult {
        let imageCount = 8
        let points = (0..<controlPointCount).map { index in
            let imageA = index % imageCount
            let imageB = (imageA + 1 + (index / imageCount) % (imageCount - 1)) % imageCount
            let deterministicError = Double((index &* 37) % 1_001) / 113.0
            return ControlPoint(
                imageAIndex: imageA,
                imageBIndex: imageB,
                xA: Double(index % 4_000),
                yA: Double((index &* 7) % 3_000),
                xB: Double((index &* 11) % 4_000),
                yB: Double((index &* 13) % 3_000),
                error: deterministicError,
                isManual: index % 97 == 0
            )
        }
        let images = (0..<imageCount).map { index in
            ResultSourceImage(
                handle: "source-\(index)",
                path: "/tmp/source-\(index).raw",
                width: 6_000,
                height: 4_000,
                channels: 3,
                bitDepth: 16,
                status: .loaded,
                unsupportedReason: nil
            )
        }
        // This deliberately large, user-invisible branch represents the full
        // native regression payload that Export JSON preserves. Typed
        // presentation must leave it untouched rather than walking or encoding
        // it when the tab opens.
        var fullEngineTrace: [JSONValue] = []
        fullEngineTrace.reserveCapacity(controlPointCount)
        for index in 0..<controlPointCount {
            let entry: [String: JSONValue] = [
                "pair": .number(Double(index % 28)),
                "residual_px": .number(Double((index &* 37) % 1_001) / 113.0),
                "inlier": .bool(index % 19 != 0),
                "stage": .string(index % 2 == 0 ? "robust_filter" : "local_refinement"),
            ]
            fullEngineTrace.append(.object(entry))
        }

        return StitchResult(
            handle: "large-diagnostics",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 12_000, height: 6_000, channels: 3, bitDepth: 16),
            cameraParams: [],
            controlPoints: points,
            sourceImages: images,
            diagnostics: .object([
                "geometry": .string("camera"),
                "preview_status": .string("camera_projection_preview"),
                "blend_mode": .string("multiband"),
                "preview_renderer_used": .string("metal_quality"),
                "preview_renderer_fallback": .bool(false),
                "completion_gate": .object(["passed": .bool(true)]),
                "star_projection_alignment": .object([
                    "high_confidence": .object(["p95": .number(0.84)]),
                    "mutual": .object(["p95": .number(1.27)]),
                ]),
                "manual_point_filtering": .object([
                    "input": .number(119),
                    "accepted": .number(116),
                    "rejected": .number(3),
                ]),
                "full_engine_trace": .array(fullEngineTrace),
            ])
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
    }

    private func metric(_ title: String, in presentation: DiagnosticsPresentation) -> DiagnosticMetric? {
        presentation.sections.flatMap(\.metrics).first { $0.title == title }
    }
}
