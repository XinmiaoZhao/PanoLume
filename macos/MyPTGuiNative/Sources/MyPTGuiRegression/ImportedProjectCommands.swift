import Foundation
import MyPTGuiCore

extension RegressionCLI {
    static func runPTSReconstruct(arguments: [String]) -> Int32 {
        var projectURL: URL?
        var previewOutputURL: URL?
        var fullOutputURL: URL?
        var reportURL: URL?
        var skipPreview = false
        var diagnosticFullSide: Int?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--skip-preview" {
                skipPreview = true
                index += 1
                continue
            }
            if argument == "--full-side" {
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]), value >= 64 else {
                    fputs("pts-reconstruct --full-side requires an integer of at least 64\n", stderr)
                    return 2
                }
                diagnosticFullSide = value
                index += 1
                continue
            }
            guard ["--project", "--preview-output", "--full-output", "--report"].contains(argument) else {
                fputs("unknown pts-reconstruct argument: \(argument)\n", stderr)
                return 2
            }
            index += 1
            guard index < arguments.count else {
                fputs("pts-reconstruct requires a path after \(argument)\n", stderr)
                return 2
            }
            let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            switch argument {
            case "--project": projectURL = url
            case "--preview-output": previewOutputURL = url
            case "--full-output": fullOutputURL = url
            case "--report": reportURL = url
            default: break
            }
            index += 1
        }
        guard let projectURL, let reportURL,
              (skipPreview ? fullOutputURL != nil : previewOutputURL != nil) else {
            fputs("pts-reconstruct requires --project and --report, plus --preview-output unless --skip-preview is paired with --full-output\n", stderr)
            return 2
        }
        do {
            let project = try PTSProjectImporter.load(from: projectURL, checkFiles: true)
            guard project.connectedGraph else {
                throw NSError(
                    domain: "MyPTGuiRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "PTS image graph is disconnected"]
                )
            }
            guard project.residuals.passed else {
                throw NSError(
                    domain: "MyPTGuiRegression",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: String(
                        format: "PTS control-point angular gate failed (median %.6f°, P95 %.6f°, max %.6f°)",
                        project.residuals.medianDegrees,
                        project.residuals.p95Degrees,
                        project.residuals.maximumDegrees
                    )]
                )
            }
            let engine = try NativeEngineBridge()
            let preview: ImportedPanoramaRenderReport?
            if skipPreview {
                preview = nil
            } else if let previewOutputURL {
                preview = try engine.renderImportedProject(
                    request: ImportedPanoramaRenderRequest(
                        project: project,
                        outputURL: previewOutputURL,
                        outputWidth: project.previewWidth,
                        outputHeight: project.previewHeight,
                        fullResolutionSources: false
                    )
                ) { event in
                    fputs(String(format: "[pts preview] %5.1f%% %@\n", event.fraction * 100, event.stage), stderr)
                }
            } else {
                preview = nil
            }
            let full: ImportedPanoramaRenderReport?
            if let fullOutputURL {
                full = try engine.renderImportedProject(
                    request: ImportedPanoramaRenderRequest(
                        project: project,
                        outputURL: fullOutputURL,
                        outputWidth: diagnosticFullSide ?? project.fullWidth,
                        outputHeight: diagnosticFullSide ?? project.fullHeight,
                        fullResolutionSources: true
                    )
                ) { event in
                    fputs(String(format: "[pts full] %5.1f%% %@\n", event.fraction * 100, event.stage), stderr)
                }
            } else {
                full = nil
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            struct Report: Codable {
                var schemaVersion: Int
                var project: PTSImportedProject
                var preview: ImportedPanoramaRenderReport?
                var full: ImportedPanoramaRenderReport?
                enum CodingKeys: String, CodingKey {
                    case schemaVersion = "schema_version"
                    case project, preview, full
                }
            }
            var data = try encoder.encode(Report(
                schemaVersion: 1,
                project: project,
                preview: preview,
                full: full
            ))
            data.append(0x0a)
            try data.write(to: reportURL, options: .atomic)
            if let preview {
                print("PTS preview complete: \(preview.outputPath ?? "unknown") (\(preview.width ?? 0)×\(preview.height ?? 0))")
            }
            if let full {
                print("PTS full reconstruction complete: \(full.outputPath ?? "unknown") (\(full.width ?? 0)×\(full.height ?? 0))")
            }
            print("PTS reconstruction report: \(reportURL.path)")
            return 0
        } catch {
            fputs("pts-reconstruct failed: \(error.localizedDescription)\n", stderr)
            return 3
        }
    }
}
