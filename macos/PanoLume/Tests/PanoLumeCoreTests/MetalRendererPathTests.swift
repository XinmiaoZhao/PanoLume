import Foundation
import XCTest
@testable import PanoLumeCore

final class MetalRendererPathTests: XCTestCase {
    func testStandaloneAppBundleIncludesResourcesFrameworksAndExecutableDirectory() throws {
        let bundleRoot = URL(fileURLWithPath: "/Users/example/Applications/PanoLume Native.app")
        let executableURL = bundleRoot
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("PanoLume")

        let candidates = try NativeEngineBridge.metalRendererDylibCandidates(
            bundleRoot: bundleRoot,
            executableURL: executableURL
        )

        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/PanoLume Native.app/Contents/Resources/libpanolume_metal.dylib"
        ))
        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/PanoLume Native.app/Contents/Frameworks/libpanolume_metal.dylib"
        ))
        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/PanoLume Native.app/Contents/MacOS/libpanolume_metal.dylib"
        ))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }
}
