import Foundation
import XCTest
@testable import MyPTGuiCore

final class MetalRendererPathTests: XCTestCase {
    func testStandaloneAppBundleIncludesResourcesFrameworksAndExecutableDirectory() throws {
        let bundleRoot = URL(fileURLWithPath: "/Users/example/Applications/MyPTGui Native.app")
        let executableURL = bundleRoot
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("MyPTGuiNative")

        let candidates = try NativeEngineBridge.metalRendererDylibCandidates(
            bundleRoot: bundleRoot,
            executableURL: executableURL
        )

        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/MyPTGui Native.app/Contents/Resources/libmyptgui_metal.dylib"
        ))
        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/MyPTGui Native.app/Contents/Frameworks/libmyptgui_metal.dylib"
        ))
        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/MyPTGui Native.app/Contents/MacOS/libmyptgui_metal.dylib"
        ))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }
}
