// swift-tools-version: 6.0

import PackageDescription
import Foundation

let privateExtensions = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/MyPTGuiCore/Private/ProjectInputDecoder.swift").path)
let privateFlags: [SwiftSetting] = privateExtensions ? [.define("PANOLUME_PRIVATE_EXTENSIONS")] : []

let package = Package(
    name: "MyPTGuiNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MyPTGuiCore", targets: ["MyPTGuiCore"]),
        .library(name: "MyPTGuiRegressionSupport", targets: ["MyPTGuiRegressionSupport"]),
        .library(name: "MyPTGuiEngine", targets: ["MyPTGuiEngine"]),
        .executable(name: "MyPTGuiNative", targets: ["MyPTGuiApp"]),
        .executable(name: "MyPTGuiRegression", targets: ["MyPTGuiRegression"]),
        .executable(name: "MyPTGuiNativeSelfTest", targets: ["MyPTGuiNativeSelfTest"]),
    ],
    targets: [
        .target(
            name: "MyPTGuiEngine",
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
            name: "MyPTGuiBuildIdentity",
            plugins: [
                .plugin(name: "GenerateSourceFingerprintPlugin")
            ]
        ),
        .target(
            name: "MyPTGuiCore",
            dependencies: ["MyPTGuiEngine", "MyPTGuiBuildIdentity"],
            exclude: privateExtensions ? ["ImportedProjectModels.swift"] : [],
            swiftSettings: privateFlags
        ),
        .target(
            name: "MyPTGuiRegressionSupport",
            dependencies: ["MyPTGuiCore"]
        ),
        .executableTarget(
            name: "MyPTGuiApp",
            dependencies: ["MyPTGuiCore"]
        ),
        .executableTarget(
            name: "MyPTGuiRegression",
            dependencies: ["MyPTGuiCore", "MyPTGuiRegressionSupport"],
            exclude: privateExtensions ? ["ImportedProjectCommands.swift"] : [],
            swiftSettings: privateFlags
        ),
        .executableTarget(
            name: "MyPTGuiNativeSelfTest",
            dependencies: ["MyPTGuiCore", "MyPTGuiEngine"]
        ),
        .testTarget(
            name: "MyPTGuiCoreTests",
            dependencies: ["MyPTGuiCore", "MyPTGuiRegressionSupport", "MyPTGuiEngine"]
        ),
        .plugin(
            name: "GenerateSourceFingerprintPlugin",
            capability: .buildTool(),
            path: "Plugins/GenerateSourceFingerprintPlugin"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
