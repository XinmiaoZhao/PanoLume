import Foundation
import XCTest
@testable import MyPTGuiCore

final class RegressionInfrastructureTests: XCTestCase {
    func testParityGateFailsClosedWithoutCertifiedCompletion() {
        let result = StitchResult(
            handle: "uncertified",
            projection: "equirectangular",
            panorama: PanoramaInfo(width: 32, height: 16, channels: 3, bitDepth: 16),
            cameraParams: [],
            controlPoints: [],
            sourceImages: [],
            diagnostics: .object([
                "completion_gate": .object([
                    "passed": .bool(false),
                    "reason": .string("source fingerprint mismatch"),
                    "missing_algorithms": .array([.string("certified_engine_source_fingerprint")]),
                ]),
            ])
        )

        let gate = ParityGate.evaluate(result: result)
        XCTAssertFalse(gate.passed)
        XCTAssertTrue(gate.missing.contains("certified_engine_source_fingerprint"))
    }

    func testSourceCertificationManifestHasDeterministicInputs() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot
            .appendingPathComponent("Docs/Certification/native-source-certification.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 2)
        if object["certification_status"] as? String == "uncertified" {
            XCTAssertEqual(object["certified_source_commit"] as? String, "uncertified")
            XCTAssertEqual(object["certified_source_fingerprint"] as? String, "uncertified")
            XCTAssertEqual(object["release_report_sha256"] as? String, "uncertified")
            XCTAssertEqual(object["metal_dylib_sha256"] as? String, "uncertified")
            XCTAssertEqual(object["metal_api_version"] as? Int, 0)
            let inputs = try XCTUnwrap(object["algorithm_source_files"] as? [String])
            XCTAssertEqual(inputs, inputs.sorted())
            XCTAssertEqual(Set(inputs).count, inputs.count)
            XCTAssertTrue(inputs.contains("macos/MyPTGuiNative/Sources/MyPTGuiCore/ProjectInputPayload.swift"))
            XCTAssertFalse(inputs.contains { $0.contains("/Private/") })
            return
        }
        XCTAssertEqual(object["certification_status"] as? String, "certified")
        XCTAssertEqual((object["certified_source_commit"] as? String)?.count, 40)
        XCTAssertEqual((object["certified_source_fingerprint"] as? String)?.count, 64)
        XCTAssertEqual((object["release_report_sha256"] as? String)?.count, 64)
        XCTAssertEqual((object["metal_dylib_sha256"] as? String)?.count, 64)
        XCTAssertEqual(object["metal_api_version"] as? Int, 2)
        let algorithmSourceFiles = try XCTUnwrap(
            object["algorithm_source_files"] as? [String]
        )
        XCTAssertEqual(
            algorithmSourceFiles,
            [
                "macos/MyPTGuiNative/Sources/MyPTGuiEngine/MyPTGuiEngine.mm",
                "macos/MyPTGuiNative/Sources/MyPTGuiEngine/include/MyPTGuiEngine.h",
                "native/metal_renderer/MyPTGuiMetalRenderer.mm",
                "scripts/build_metal_renderer.sh",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/AspectFitCoordinateMapper.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/BaselineManifest.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/DiagnosticsPresentation.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/DisplayStretch.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/EngineBridge.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/JSONValue.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/Models.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/NativeDependencies.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/ParityComparator.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/ParityGate.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiCore/WorkbenchModel.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiApp/ContentView.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiApp/ControlPointEditorView.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiApp/FilePanels.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiApp/MyPTGuiNativeApp.swift",
                "macos/MyPTGuiNative/Sources/MyPTGuiApp/PanoramaViewport.swift",
            ]
        )

        // This manifest certifies the previous API-v2 release. New sources are
        // deliberately absent so the current API-v4 build cannot inherit that
        // certification without a real promotion.
        XCTAssertFalse(algorithmSourceFiles.contains(
            "macos/MyPTGuiNative/Sources/MyPTGuiCore/SourcePreviewController.swift"
        ))
        XCTAssertFalse(algorithmSourceFiles.contains(
            "macos/MyPTGuiNative/Sources/MyPTGuiApp/SourceBrowserView.swift"
        ))
    }

    func testFingerprintGeneratorCoversEveryCurrentCoreAndAppSource() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let generatorURL = packageRoot
            .appendingPathComponent("Plugins/GenerateSourceFingerprintPlugin/generate-source-fingerprint.sh")
        let generator = try String(contentsOf: generatorURL, encoding: .utf8)

        XCTAssertTrue(generator.contains("find macos/MyPTGuiNative/Sources/MyPTGuiEngine"))
        XCTAssertTrue(generator.contains("macos/MyPTGuiNative/Sources/MyPTGuiCore macos/MyPTGuiNative/Sources/MyPTGuiApp"))
        XCTAssertTrue(generator.contains("find native/metal_renderer"))
        XCTAssertTrue(generator.contains("LC_ALL=C /usr/bin/sort -u"))
        XCTAssertTrue(generator.contains("Missing fingerprint input"))

        var currentSwiftSourceCount = 0
        for targetName in ["MyPTGuiCore", "MyPTGuiApp"] {
            let directory = packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent(targetName)
            for source in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) where source.pathExtension == "swift" {
                currentSwiftSourceCount += 1
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            }
        }
        XCTAssertGreaterThan(currentSwiftSourceCount, 0)
    }
}
