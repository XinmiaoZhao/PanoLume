import AppKit
import Foundation
import UniformTypeIdentifiers
import PanoLumeCore

enum PhotoImporter {
    @MainActor
    static func importPhotos(into model: NativeWorkbenchModel) {
        let panel = NSOpenPanel()
        panel.title = "Open Photos"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = imageTypes
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                model.addPhotos(urls)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static var imageTypes: [UTType] {
        var types: [UTType] = [.jpeg, .png, .tiff, .bmp]
        for ext in ["cr2", "nef", "arw", "dng", "raf", "orf", "rw2", "pef"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}

@MainActor
enum PTSProjectPanel {
    private static var project: PTSImportedProject?
    private static var previewWindow: NSWindow?
    private static var importRequestID: UInt64 = 0
    private static var sourceAuthorizationURL: URL?
    private static var sourceAuthorizationScopeActive = false

    private enum SourceAuthorizationResult {
        case notNeeded
        case selected(URL)
        case cancelled
    }

    static func importAndPreview() {
        let panel = NSOpenPanel()
        panel.title = "Import PTGui Project"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pts") ?? .data]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importRequestID &+= 1
            let requestID = importRequestID
            project = nil
            Task {
                do {
                    let unchecked = try await Task.detached(priority: .userInitiated) {
                        try PTSProjectImporter.load(from: url, checkFiles: false)
                    }.value
                    guard requestID == importRequestID else { return }
                    let authorization = await requestSourceFolderAuthorizationIfNeeded(
                        for: unchecked,
                        projectURL: url
                    )
                    guard requestID == importRequestID else { return }
                    switch authorization {
                    case .cancelled:
                        return
                    case .notNeeded:
                        releaseSourceAuthorization()
                    case let .selected(folderURL):
                        retainSourceAuthorization(folderURL)
                    }
                    let result = try await Task.detached(priority: .userInitiated) {
                        let imported = try PTSProjectImporter.load(from: url, checkFiles: true)
                        guard imported.connectedGraph, imported.residuals.passed else {
                            throw PTSImportError.invalidProject(
                                String(
                                    format: "Geometry gate failed: connected=%@, median %.4f°, P95 %.4f°, max %.4f°.",
                                    imported.connectedGraph ? "yes" : "no",
                                    imported.residuals.medianDegrees,
                                    imported.residuals.p95Degrees,
                                    imported.residuals.maximumDegrees
                                )
                            )
                        }
                        let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "panolume_pts_\(imported.sourceSHA256.prefix(12))_preview.tif"
                        )
                        let engine = try NativeEngineBridge()
                        let report = try engine.renderImportedProject(
                            request: ImportedPanoramaRenderRequest(
                                project: imported,
                                outputURL: previewURL,
                                outputWidth: imported.previewWidth,
                                outputHeight: imported.previewHeight,
                                fullResolutionSources: false
                            ),
                            progress: { _ in }
                        )
                        return (imported, previewURL, report)
                    }.value
                    guard requestID == importRequestID else { return }
                    project = result.0
                    showPreview(at: result.1, project: result.0, report: result.2)
                } catch {
                    guard requestID == importRequestID else { return }
                    showError(title: "PTS Import or Preview Failed", error: error)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func requestSourceFolderAuthorizationIfNeeded(
        for imported: PTSImportedProject,
        projectURL: URL
    ) async -> SourceAuthorizationResult {
        let projectDirectory = projectURL.deletingLastPathComponent().standardizedFileURL
        let projectPrefix = projectDirectory.path.hasSuffix("/")
            ? projectDirectory.path
            : projectDirectory.path + "/"
        let sourcePaths = imported.images.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        guard sourcePaths.contains(where: { !$0.hasPrefix(projectPrefix) }) else {
            return .notNeeded
        }

        let expectedRoot = commonSourceDirectory(for: imported.images.map(\.path))
        let panel = NSOpenPanel()
        panel.title = "Authorize PTS Source Images"
        panel.message = "This project references \(imported.images.count) source images outside the PTS folder. Select their containing folder so PanoLume can read them."
        panel.prompt = "Authorize Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        // Directory panels cannot select the folder they are currently displaying.
        // Start one level above the inferred common root so the intended folder is
        // visible and can be authorized with a single selection.
        panel.directoryURL = expectedRoot?.deletingLastPathComponent()
        let response = await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
        guard response == .OK, let selected = panel.url?.standardizedFileURL else {
            return .cancelled
        }
        let selectedPrefix = selected.path.hasSuffix("/") ? selected.path : selected.path + "/"
        guard sourcePaths.allSatisfy({ $0.hasPrefix(selectedPrefix) }) else {
            showError(
                title: "Wrong Source Folder",
                error: PTSImportError.invalidProject(
                    "The selected folder does not contain every source path referenced by this PTS project."
                )
            )
            return .cancelled
        }
        return .selected(selected)
    }

    private static func commonSourceDirectory(for paths: [String]) -> URL? {
        guard var common = paths.first.map({
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL
        }) else { return nil }
        for path in paths.dropFirst() {
            let candidate = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            while candidate != common.path,
                  !candidate.hasPrefix(common.path.hasSuffix("/") ? common.path : common.path + "/"),
                  common.path != "/" {
                common.deleteLastPathComponent()
            }
        }
        return common
    }

    private static func retainSourceAuthorization(_ url: URL) {
        releaseSourceAuthorization()
        sourceAuthorizationURL = url
        sourceAuthorizationScopeActive = url.startAccessingSecurityScopedResource()
    }

    private static func releaseSourceAuthorization() {
        if sourceAuthorizationScopeActive {
            sourceAuthorizationURL?.stopAccessingSecurityScopedResource()
        }
        sourceAuthorizationScopeActive = false
        sourceAuthorizationURL = nil
    }

    static func reconstructFullResolution() {
        guard let project else {
            let alert = NSAlert()
            alert.messageText = "No Imported PTGui Project"
            alert.informativeText = "Import and validate a PTGui project before reconstructing it."
            alert.runModal()
            return
        }
        guard let dimensions = chooseReconstructionDimensions(for: project) else { return }
        let panel = NSSavePanel()
        panel.title = "Reconstruct Imported PTGui Project"
        panel.nameFieldStringValue = "pts_reconstructed_\(dimensions.width)x\(dimensions.height).tif"
        panel.allowedContentTypes = [.tiff]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let outputURL = panel.url else { return }
            let diagnosticsURL = outputURL.deletingLastPathComponent().appendingPathComponent(
                outputURL.deletingPathExtension().lastPathComponent + "_diagnostics",
                isDirectory: true
            )
            Task {
                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        let engine = try NativeEngineBridge()
                        return try engine.renderImportedProject(
                            request: ImportedPanoramaRenderRequest(
                                project: project,
                                outputURL: outputURL,
                                outputWidth: dimensions.width,
                                outputHeight: dimensions.height,
                                fullResolutionSources: true,
                                diagnosticsDirectoryURL: diagnosticsURL
                            ),
                            progress: { _ in }
                        )
                    }.value
                    let alert = NSAlert()
                    alert.messageText = "PTS Reconstruction Complete"
                    let geometry = report.geometryRefinement?.adopted == true
                        ? "Strict control-point geometry refinement was adopted."
                        : "Saved PTS geometry was retained: \(report.geometryRefinement?.fallbackReason ?? "refinement was unavailable")."
                    alert.informativeText = "\(report.width ?? 0)×\(report.height ?? 0), 16-bit RGBA\n\(geometry)\nZero-overlap high-frequency dual-source pixels: \(report.zeroOverlap?.highFrequencyDualSourcePixelCount ?? -1)\nDiagnostic hotspot crops: \(report.diagnosticCropPaths?.count ?? 0)\n\(outputURL.path)"
                    alert.runModal()
                } catch {
                    showError(title: "PTS Reconstruction Failed", error: error)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func chooseReconstructionDimensions(
        for project: PTSImportedProject
    ) -> (width: Int, height: Int)? {
        let fullLongEdge = max(project.fullWidth, project.fullHeight)
        let recommended = min(PTSReconstructionSizing.recommendedLongEdge, fullLongEdge)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let longEdgeField = NSTextField(string: String(recommended))
        longEdgeField.alignment = .right
        longEdgeField.setAccessibilityLabel("Output long edge in pixels")
        let sizeSummary = NSTextField(labelWithString: "")
        sizeSummary.textColor = .secondaryLabelColor
        sizeSummary.maximumNumberOfLines = 2

        let availablePresets = PTSReconstructionSizing.presetLongEdges.filter { $0 < fullLongEdge }
        for edge in availablePresets {
            let title = edge == PTSReconstructionSizing.recommendedLongEdge
                ? "\(edge) px — Recommended"
                : "\(edge) px"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = edge
        }
        popup.addItem(withTitle: "Full recovered size — \(project.fullWidth)×\(project.fullHeight)")
        popup.lastItem?.representedObject = fullLongEdge
        popup.addItem(withTitle: "Custom long edge")
        popup.lastItem?.representedObject = -1
        if let recommendedIndex = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == recommended
        }) {
            popup.selectItem(at: recommendedIndex)
        } else {
            popup.selectItem(at: max(0, popup.numberOfItems - 2))
        }
        popup.setAccessibilityLabel("Output size preset")

        func updateSummary() {
            guard let requested = Int(longEdgeField.stringValue),
                  let dimensions = try? PTSReconstructionSizing.dimensions(
                    fullWidth: project.fullWidth,
                    fullHeight: project.fullHeight,
                    requestedLongEdge: requested
                  ) else {
                sizeSummary.stringValue = "Enter a long edge from 4096 through \(fullLongEdge) pixels."
                return
            }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let bytes = PTSReconstructionSizing.estimatedUncompressedBytes(
                width: dimensions.width,
                height: dimensions.height
            )
            sizeSummary.stringValue = "Output: \(dimensions.width)×\(dimensions.height), approximately \(formatter.string(fromByteCount: bytes)) uncompressed."
        }

        @MainActor
        final class SelectionTarget: NSObject {
            let popup: NSPopUpButton
            let field: NSTextField
            let update: () -> Void

            init(popup: NSPopUpButton, field: NSTextField, update: @escaping () -> Void) {
                self.popup = popup
                self.field = field
                self.update = update
            }

            @objc func selectionChanged() {
                if let edge = popup.selectedItem?.representedObject as? Int, edge > 0 {
                    field.stringValue = String(edge)
                }
                update()
            }

            @objc func fieldChanged() {
                popup.selectItem(at: popup.numberOfItems - 1)
                update()
            }
        }
        let target = SelectionTarget(popup: popup, field: longEdgeField, update: updateSummary)
        popup.target = target
        popup.action = #selector(SelectionTarget.selectionChanged)
        longEdgeField.target = target
        longEdgeField.action = #selector(SelectionTarget.fieldChanged)

        let fieldRow = NSStackView(views: [
            NSTextField(labelWithString: "Long edge:"),
            longEdgeField,
            NSTextField(labelWithString: "pixels"),
        ])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        longEdgeField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let stack = NSStackView(views: [popup, fieldRow, sizeSummary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.widthAnchor.constraint(equalToConstant: 430).isActive = true
        popup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sizeSummary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateSummary()

        while true {
            let alert = NSAlert()
            alert.messageText = "Choose Reconstruction Size"
            alert.informativeText = "The renderer will read the original 16-bit TIFF sources. 16384 px is recommended for a detailed, more manageable master."
            alert.accessoryView = stack
            alert.addButton(withTitle: "Continue…")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do {
                guard let requested = Int(longEdgeField.stringValue) else {
                    throw PTSImportError.invalidProject("Output long edge must be a whole number of pixels.")
                }
                return try PTSReconstructionSizing.dimensions(
                    fullWidth: project.fullWidth,
                    fullHeight: project.fullHeight,
                    requestedLongEdge: requested
                )
            } catch {
                showError(title: "Invalid Reconstruction Size", error: error)
            }
        }
    }

    private static func showPreview(
        at url: URL,
        project: PTSImportedProject,
        report: ImportedPanoramaRenderReport
    ) {
        guard let image = NSImage(contentsOf: url) else {
            showError(
                title: "PTS Preview Failed",
                error: PTSImportError.invalidProject("The rendered preview could not be opened.")
            )
            return
        }
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            format: "PTS Preview — %d images, %d points, median %.4f°",
            project.images.count,
            project.controlPoints.count,
            project.residuals.medianDegrees
        )
        window.contentView = imageView
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        if report.warnings?.isEmpty == false {
            let alert = NSAlert()
            alert.messageText = "PTS Preview Warnings"
            alert.informativeText = report.warnings?.joined(separator: "\n") ?? ""
            alert.runModal()
        }
    }

    private static func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

enum LensProfilePanel {
    @MainActor
    static func choose(into model: NativeWorkbenchModel) {
        let panel = NSOpenPanel()
        panel.title = "Choose Lens Profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "lcp") ?? .xml]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let targetMake = model.photos.compactMap(\.cameraMake).first { !$0.isEmpty }
                    let targetFocalLength = model.photos.compactMap(\.focalLengthMM).first {
                        $0.isFinite && $0 > 0
                    }
                    let targetFNumber = model.photos.compactMap(\.apertureFNumber).first {
                        $0.isFinite && $0 > 0
                    }
                    let prior = try LensCalibrationPriorLoader.load(
                        from: url,
                        targetFocalLengthMM: targetFocalLength,
                        targetFNumber: targetFNumber,
                        targetCameraMake: targetMake
                    )
                    model.settings.lensCalibrationPrior = prior
                    // Retained only for archive/legacy compatibility. The
                    // optimizer consumes the immutable parsed values above.
                    model.settings.lensProfilePath = url.path
                    model.settings.lensProfileName = prior.profileName
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Lens Profile Rejected"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @MainActor
    static func clear(from model: NativeWorkbenchModel) {
        model.settings.lensCalibrationPrior = nil
        model.settings.lensProfilePath = nil
        model.settings.lensProfileName = nil
    }
}

enum ExportPanel {
    @MainActor
    static func exportFullResolution(from model: NativeWorkbenchModel) {
        guard model.canExportFullResolution else {
            let alert = NSAlert()
            alert.messageText = "Full-Resolution Export Unavailable"
            alert.informativeText = model.fullResolutionExportUnavailableReason
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Full-Resolution Panorama"
        panel.nameFieldStringValue = "panorama_fullres.tiff"
        panel.allowedContentTypes = [.tiff]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                model.exportFullResolution(to: url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

enum DiagnosticsExporter {
    /// Returns true when the user chose a destination and a background write
    /// was started. Completion is always delivered on the main actor.
    @discardableResult
    @MainActor
    static func export(
        _ result: StitchResult?,
        completion: @escaping @MainActor (_ outputURL: URL?, _ errorMessage: String?) -> Void
    ) -> Bool {
        guard let result else {
            return false
        }
        let panel = NSSavePanel()
        panel.title = "Export PanoLume Diagnostics"
        panel.nameFieldStringValue = "panolume_diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }
        let snapshot = result
        Task.detached {
            do {
                try prettyJSONData(snapshot).write(to: url, options: .atomic)
                await MainActor.run {
                    completion(url, nil)
                }
            } catch {
                _ = await MainActor.run {
                    completion(nil, error.localizedDescription)
                }
            }
        }
        return true
    }

    nonisolated private static func prettyJSONData(_ result: StitchResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(result)
    }
}
