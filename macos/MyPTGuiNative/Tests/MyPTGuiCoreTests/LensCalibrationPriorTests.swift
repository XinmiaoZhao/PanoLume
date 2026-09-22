import XCTest
@testable import MyPTGuiCore

final class LensCalibrationPriorTests: XCTestCase {
    func testLCPIsParsedConvertedHashedAndDetachedFromSourcePath() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
          xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
          <rdf:RDF><rdf:Description stCamera:Make="SONY"
            stCamera:CameraPrettyName="Viltrox" stCamera:LensPrettyName="Viltrox AF 16mm F1.8 FE"
            stCamera:ProfileName="Synthetic Viltrox" stCamera:FocalLength="16"
            stCamera:ApertureValue="2">
            <stCamera:PerspectiveModel><rdf:Description stCamera:Version="2"
              stCamera:ScaleFactor="0.991427" stCamera:RadialDistortParam1="0.025712"
              stCamera:RadialDistortParam2="-0.02162" stCamera:RadialDistortParam3="0.003522"/>
            </stCamera:PerspectiveModel>
          </rdf:Description></rdf:RDF>
        </x:xmpmeta>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panolume-lens-prior-\(UUID().uuidString).lcp")
        try Data(xml.utf8).write(to: url)
        let prior = try LensCalibrationPriorLoader.load(
            from: url,
            targetFocalLengthMM: 16,
            targetFNumber: 2,
            targetCameraMake: "NIKON CORPORATION"
        )
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(prior.profileName, "Synthetic Viltrox")
        XCTAssertEqual(prior.lensName, "Viltrox AF 16mm F1.8 FE")
        XCTAssertEqual(prior.focalLengthMM, 16, accuracy: 1e-12)
        XCTAssertEqual(prior.apertureFNumber ?? 0, 2, accuracy: 1e-12)
        XCTAssertEqual(prior.radialParameters, [0.025712, -0.02162, 0.003522])
        XCTAssertEqual(prior.convertedFocalScale, 0.991427, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(prior.conversionMaxErrorPixels, 0.05)
        XCTAssertEqual(prior.sha256.count, 64)
        XCTAssertTrue(prior.cameraMakeMismatch)
        XCTAssertEqual(prior.priorWeight, 0.15, accuracy: 1e-12)

        let roundTrip = try JSONDecoder().decode(
            LensCalibrationPrior.self,
            from: JSONEncoder().encode(prior)
        )
        XCTAssertEqual(roundTrip, prior)
    }

    func testCompactExplicitFocalPerspectiveModelIsConvertedWithPrincipalPoint() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
          xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
          <rdf:RDF><rdf:Description stCamera:Make="NIKON CORPORATION"
            stCamera:CameraPrettyName="NIKON Z 7" stCamera:LensPrettyName="Viltrox AF 16mm F1.8 Z"
            stCamera:ProfileName="Synthetic Nikon Viltrox" stCamera:FocalLength="16"
            stCamera:ApertureValue="2" stCamera:SensorFormatFactor="1"
            stCamera:ImageWidth="8288" stCamera:ImageLength="5520">
            <stCamera:PerspectiveModel stCamera:Version="2"
              stCamera:FocalLengthX="0.465987" stCamera:FocalLengthY="0.465987"
              stCamera:ImageXCenter="0.497434" stCamera:ImageYCenter="0.49653"
              stCamera:RadialDistortParam1="0.007915"
              stCamera:RadialDistortParam2="-0.024485"
              stCamera:RadialDistortParam3="0.011332"/>
          </rdf:Description></rdf:RDF>
        </x:xmpmeta>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panolume-explicit-focal-prior-\(UUID().uuidString).lcp")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prior = try LensCalibrationPriorLoader.load(
            from: url,
            targetFocalLengthMM: 16,
            targetFNumber: 2,
            targetCameraMake: "NIKON CORPORATION"
        )

        XCTAssertEqual(prior.focalLengthX ?? 0, 0.465987, accuracy: 1e-12)
        XCTAssertEqual(prior.focalLengthY ?? 0, 0.465987, accuracy: 1e-12)
        XCTAssertEqual(prior.convertedPrincipalOffsetX ?? 0, -0.002566, accuracy: 1e-12)
        XCTAssertEqual(prior.convertedPrincipalOffsetY ?? 0, -0.00347, accuracy: 1e-12)
        XCTAssertEqual(prior.convertedK1, 0.007915, accuracy: 1e-9)
        XCTAssertEqual(prior.convertedK2, -0.024485, accuracy: 1e-9)
        XCTAssertEqual(prior.convertedK3, 0.011332, accuracy: 1e-9)
        XCTAssertEqual(prior.convertedP1, 0, accuracy: 1e-10)
        XCTAssertEqual(prior.convertedP2, 0, accuracy: 1e-10)
        XCTAssertLessThanOrEqual(prior.conversionMaxErrorPixels, 0.05)
        XCTAssertFalse(prior.cameraMakeMismatch)
        XCTAssertEqual(prior.priorWeight, 0.35, accuracy: 1e-12)
    }
}
