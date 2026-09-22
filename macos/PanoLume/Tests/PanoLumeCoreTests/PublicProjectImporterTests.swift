import Foundation
import ImageIO
import PanoLumeEngine
import UniformTypeIdentifiers
import XCTest
@testable import PanoLumeCore

final class PublicProjectImporterTests: XCTestCase {
    func testPlaintextV55ProjectBuildsConnectedCameraGraph() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("panolume-pts-\(UUID().uuidString).pts")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let lens: [String: Any] = [
            "lens": ["params": [
                "projection": "rectilinear", "focallength": 20.0,
                "sensordiagonal": 43.266, "a": 0, "b": 0, "c": 0,
                "croprectanglesize": NSNull(),
            ]],
            "shift": ["params": ["longside": 0, "shortside": 0]],
            "shear": ["params": ["hshear": 0, "vshear": 0]],
        ]
        func group(_ filename: String) -> [String: Any] {
            [
                "size": [7008, 4672], "globallens": 0, "maskbitmap": NSNull(),
                "individuallens": NSNull(), "individualshift": NSNull(),
                "individualshear": NSNull(), "blendweight": 100,
                "position": ["params": [
                    "yaw": 0, "pitch": 0, "roll": 0,
                    "vpx": 0, "vpy": 0, "vpd": 0, "vppan": 0, "vptilt": 0,
                ]],
                "images": [[
                    "filename": filename, "include": true,
                    "photometric": ["whitepoint": ["temperature": 5000]],
                ]],
            ]
        }
        let root: [String: Any] = [
            "$schema": "https://www.ptgui.com/schemas/project_v55.schema.json",
            "software": "PTGui Pro 13.9", "fileversion": 55,
            "project": [
                "pathseparator": "/", "portraitcameraorientation": "counterclockwise",
                "panoramaparams": [
                    "projection": "stereographic", "hfov": 270, "vfov": 270,
                    "outputcrop": [0, 0, 1, 1],
                ],
                "globallenses": [lens],
                "blend": [
                    "engine": "zerooverlap", "seamfinding": true,
                    "seamfindingprecision": -3, "maskpushseams": true,
                ],
                "imagegroups": [group("a.tif"), group("b.tif")],
                "controlpoints": [["t": 0, "0": [0, 0, 3504, 2336], "1": [1, 0, 3504, 2336]]],
                "optimizer": ["simplemodesettings": ["anchorimagegroup": 0]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: temporary)

        let project = try PTSProjectImporter.load(from: temporary, checkFiles: false)

        XCTAssertEqual(project.images.count, 2)
        XCTAssertEqual(project.controlPoints.count, 1)
        XCTAssertEqual(project.connectedPairCount, 1)
        XCTAssertTrue(project.connectedGraph)
        XCTAssertTrue(project.residuals.passed)
        XCTAssertEqual(project.previewWidth, 4096)
        XCTAssertEqual(project.fullWidth, project.fullHeight)
        XCTAssertEqual(project.blendSettings.engine, "zerooverlap")
        XCTAssertEqual(project.blendSettings.seamFindingPrecision, -3)
    }
    func testReconstructionSizingPreservesAspectRatioAndBounds() throws {
        let medium = try PTSReconstructionSizing.dimensions(
            fullWidth: 37_598,
            fullHeight: 18_799,
            requestedLongEdge: 16_384
        )
        XCTAssertEqual(medium.width, 16_384)
        XCTAssertEqual(medium.height, 8_192)
        XCTAssertEqual(
            PTSReconstructionSizing.estimatedUncompressedBytes(
                width: medium.width,
                height: medium.height
            ),
            1_073_741_824
        )
        let full = try PTSReconstructionSizing.dimensions(
            fullWidth: 37_598,
            fullHeight: 37_598,
            requestedLongEdge: 37_598
        )
        XCTAssertEqual(full.width, 37_598)
        XCTAssertEqual(full.height, 37_598)
        XCTAssertThrowsError(try PTSReconstructionSizing.dimensions(
            fullWidth: 37_598,
            fullHeight: 37_598,
            requestedLongEdge: 2_048
        ))
        XCTAssertThrowsError(try PTSReconstructionSizing.dimensions(
            fullWidth: 37_598,
            fullHeight: 37_598,
            requestedLongEdge: 40_000
        ))
    }
    func testPlainReaderRejectsUnknownContainer() {
        XCTAssertThrowsError(try ProjectInputPayload.plaintext(Data([0, 1, 2, 3])))
        XCTAssertThrowsError(try ProjectInputPayload.plaintext(Data("not JSON".utf8)))
        XCTAssertNoThrow(try ProjectInputPayload.plaintext(Data("{}".utf8)))
    }
    func testInjectedReaderReceivesOriginalBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([9, 8, 7]).write(to: url)
        XCTAssertThrowsError(try PTSProjectImporter.load(from: url, checkFiles: false, decoder: { data in
            XCTAssertEqual(data, Data([9, 8, 7]))
            throw PTSImportError.unsupported("injected-reader-called")
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("injected-reader-called"))
        }
    }
    func testStereographicProjectionRoundTrip() {
        XCTAssertEqual(panolume_pts_projection_characterization_self_test(), 1)
    }
}
