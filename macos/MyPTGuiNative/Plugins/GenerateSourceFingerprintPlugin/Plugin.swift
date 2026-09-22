import Foundation
import PackagePlugin

@main
struct GenerateSourceFingerprintPlugin: BuildToolPlugin {
    private func collectSourceInputs(
        roots: [URL],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var inputs: [URL] = roots
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            while let file = enumerator.nextObject() as? URL {
                guard allowedExtensions.contains(file.pathExtension.lowercased()),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                inputs.append(file)
            }
        }
        return inputs
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let packageRoot = context.package.directoryURL
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = packageRoot
            .appending(path: "Plugins")
            .appending(path: "GenerateSourceFingerprintPlugin")
            .appending(path: "generate-source-fingerprint.sh")
        let output = context.pluginWorkDirectoryURL
            .appending(path: "GeneratedSourceFingerprint.swift")
        let sourceRoots = [
            repositoryRoot.appending(path: "macos/MyPTGuiNative/Sources/MyPTGuiEngine"),
            repositoryRoot.appending(path: "macos/MyPTGuiNative/Sources/MyPTGuiCore"),
            repositoryRoot.appending(path: "macos/MyPTGuiNative/Sources/MyPTGuiApp"),
            repositoryRoot.appending(path: "native/metal_renderer"),
        ]
        let allowedExtensions: Set<String> = [
            "c", "cc", "cpp", "h", "hpp", "m", "mm", "metal", "swift",
        ]
        var inputs = collectSourceInputs(roots: sourceRoots, allowedExtensions: allowedExtensions)
        inputs.append(script)
        inputs.append(repositoryRoot.appending(path: "scripts/build_metal_renderer.sh"))
        inputs.append(packageRoot.appending(path: "Docs/Certification/native-source-certification.json"))
        inputs.sort { $0.path < $1.path }
        return [
            .buildCommand(
                displayName: "Generating deterministic PanoLume source fingerprint",
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    script.path,
                    packageRoot.path,
                    context.pluginWorkDirectoryURL.path,
                ],
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}
