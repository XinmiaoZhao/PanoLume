import Foundation
import XCTest

final class EngineBridgeConcurrencyTests: XCTestCase {
    func testBridgeDoesNotStoreMutableJSONCodecs() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/PanoLumeCore/EngineBridge.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // NativeEngineBridge is @unchecked Sendable. Foundation's mutable JSON
        // codecs therefore must remain operation-local instead of stored state.
        let storedCodecPattern = #"(?m)^ {4}(?:(?:private|fileprivate|internal|public) )?(?:let|var) \w+\s*(?::\s*JSON(?:Encoder|Decoder)|=\s*JSON(?:Encoder|Decoder)\(\))"#
        let storedCodecRegex = try NSRegularExpression(pattern: storedCodecPattern)
        let sourceRange = NSRange(source.startIndex..., in: source)

        XCTAssertEqual(
            storedCodecRegex.numberOfMatches(in: source, range: sourceRange),
            0,
            "NativeEngineBridge must not share JSONEncoder or JSONDecoder instances across operations."
        )
        XCTAssertTrue(source.contains("let encoder = JSONEncoder()"))
        XCTAssertTrue(source.contains("let decoder = JSONDecoder()"))
    }
}
