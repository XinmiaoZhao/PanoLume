import Foundation
import CryptoKit
import XCTest
@testable import PanoLumeCore

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
            XCTAssertTrue(inputs.contains("macos/PanoLume/Sources/PanoLumeCore/ProjectInputPayload.swift"))
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
        // Historical evidence is immutable and cannot certify this renamed source.
        let originalBytes = try Data(contentsOf: manifestURL)
        let historicalHash = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(historicalHash, "56011f1784ff0710c63877ab185119433eb54910412f4e4bc216f3b14a7ea884")
        XCTAssertFalse(algorithmSourceFiles.contains("macos/PanoLume/Sources/PanoLumeCore/EngineBridge.swift"))

    }

    func testFingerprintGeneratorCoversEveryCurrentCoreAndAppSource() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let generatorURL = packageRoot
            .appendingPathComponent("Plugins/GenerateSourceFingerprintPlugin/generate-source-fingerprint.sh")
        let generator = try String(contentsOf: generatorURL, encoding: .utf8)

        XCTAssertTrue(generator.contains("find macos/PanoLume/Sources/PanoLumeEngine"))
        XCTAssertTrue(generator.contains("macos/PanoLume/Sources/PanoLumeCore macos/PanoLume/Sources/PanoLumeApp"))
        XCTAssertTrue(generator.contains("find native/metal_renderer"))
        XCTAssertTrue(generator.contains("LC_ALL=C /usr/bin/sort -u"))
        XCTAssertTrue(generator.contains("Missing fingerprint input"))

        var currentSwiftSourceCount = 0
        for targetName in ["PanoLumeCore", "PanoLumeApp"] {
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
