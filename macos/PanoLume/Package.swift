// swift-tools-version: 6.0

import PackageDescription
import Foundation

let privateExtensions = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/PanoLumeCore/Private/ProjectInputDecoder.swift").path)
let privateFlags: [SwiftSetting] = privateExtensions ? [.define("PANOLUME_PRIVATE_EXTENSIONS")] : []

let package = Package(
    name: "PanoLume",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PanoLumeCore", targets: ["PanoLumeCore"]),
        .library(name: "PanoLumeRegressionSupport", targets: ["PanoLumeRegressionSupport"]),
        .library(name: "PanoLumeEngine", targets: ["PanoLumeEngine"]),
        .executable(name: "PanoLume", targets: ["PanoLumeApp"]),
        .executable(name: "PanoLumeRegression", targets: ["PanoLumeRegression"]),
        .executable(name: "PanoLumeSelfTest", targets: ["PanoLumeSelfTest"]),
    ],
    targets: [
        .target(
            name: "PanoLumeEngine",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I/opt/homebrew/include",
                    "-I/opt/homebrew/opt/opencv@4/include/opencv4",
                    "-I/opt/homebrew/include/opencv4",
                    "-I/opt/homebrew/include/eigen3",
                    "-I/usr/local/include",
                    "-I/usr/local/opt/opencv@4/include/opencv4",
                    "-I/usr/local/include/opencv4",
                    "-I/usr/local/include/eigen3",
                    "-DGLOG_USE_GLOG_EXPORT",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedLibrary("raw"),
                .linkedLibrary("opencv_calib3d"),
                .linkedLibrary("opencv_core"),
                .linkedLibrary("opencv_features2d"),
                .linkedLibrary("opencv_flann"),
                .linkedLibrary("opencv_imgproc"),
                .linkedLibrary("opencv_stitching"),
                .linkedLibrary("ceres"),
                .linkedLibrary("glog"),
                .linkedLibrary("tiff"),
                .unsafeFlags([
                    "-L/opt/homebrew/opt/opencv@4/lib",
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/opt/opencv@4/lib",
                    "-L/usr/local/lib",
                ])
            ]
        ),
        .target(
            name: "PanoLumeBuildIdentity",
            plugins: [
                .plugin(name: "GenerateSourceFingerprintPlugin")
            ]
        ),
        .target(
            name: "PanoLumeCore",
            dependencies: ["PanoLumeEngine", "PanoLumeBuildIdentity"],
            exclude: privateExtensions ? ["ImportedProjectModels.swift"] : [],
            swiftSettings: privateFlags
        ),
        .target(
            name: "PanoLumeRegressionSupport",
            dependencies: ["PanoLumeCore"]
        ),
        .executableTarget(
            name: "PanoLumeApp",
            dependencies: ["PanoLumeCore"]
        ),
        .executableTarget(
            name: "PanoLumeRegression",
            dependencies: ["PanoLumeCore", "PanoLumeRegressionSupport"],
            exclude: privateExtensions ? ["ImportedProjectCommands.swift"] : [],
            swiftSettings: privateFlags
        ),
        .executableTarget(
            name: "PanoLumeSelfTest",
            dependencies: ["PanoLumeCore", "PanoLumeEngine"]
        ),
        .testTarget(
            name: "PanoLumeCoreTests",
            dependencies: ["PanoLumeCore", "PanoLumeRegressionSupport", "PanoLumeEngine"]
        ),
        .plugin(
            name: "GenerateSourceFingerprintPlugin",
            capability: .buildTool(),
            path: "Plugins/GenerateSourceFingerprintPlugin"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
