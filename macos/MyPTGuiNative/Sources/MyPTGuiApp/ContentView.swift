import SwiftUI
import CoreGraphics
import AppKit
import MyPTGuiCore

struct ContentView: View {
    @ObservedObject var model: NativeWorkbenchModel

    var body: some View {
        NavigationSplitView {
            PhotoSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            CenterWorkspace(model: model)
        } detail: {
            InspectorPanel(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    PhotoImporter.importPhotos(into: model)
                } label: {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }
                Button {
                    model.runPreview()
                } label: {
                    Label("Run Preview", systemImage: "play.fill")
                }
                Button {
                    ExportPanel.exportFullResolution(from: model)
                } label: {
                    Label("Export Full-Res", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExportFullResolution)
            }
        }
    }
}

private struct PhotoSidebar: View {
    @ObservedObject var model: NativeWorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    PhotoImporter.importPhotos(into: model)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button(role: .destructive) {
                    model.clearPhotos()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.photos.isEmpty)
            }
            .padding(8)

            List(selection: $model.selectedPhotoID) {
                ForEach(model.photos) { photo in
                    HStack {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(photo.displayName)
                                .lineLimit(1)
                            Text(photoStatus(photo))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let reason = photo.unsupportedReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .tag(photo.id)
                }
                .onDelete(perform: model.removePhotos)
            }

            StatusFooter(model: model)
                .padding(8)
        }
    }

    private func photoStatus(_ photo: PhotoAsset) -> String {
        switch photo.loadStatus {
        case .loaded:
            return "\(photo.originalWidth)x\(photo.originalHeight) original · \(photo.url.path)"
        case .unsupportedUntilLibraw:
            return "RAW unsupported until LibRaw · \(photo.url.path)"
        case .loadFailed:
            return "Load failed · \(photo.url.path)"
        case .notLoaded:
            return "Not loaded · \(photo.url.path)"
        }
    }
}

private struct CenterWorkspace: View {
    @ObservedObject var model: NativeWorkbenchModel
    @State private var selectedTab = "preview"
    @StateObject private var sourcePreviewController = SourcePreviewController()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Panorama").tag("preview")
                Text("Sources").tag("sources")
                Text("Control Points").tag("control")
                Text("Diagnostics").tag("diagnostics")
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch selectedTab {
            case "sources":
                SourceBrowserView(model: model, controller: sourcePreviewController)
            case "control":
                ControlPointsView(model: model)
            case "diagnostics":
                DiagnosticsView(model: model)
            default:
                PanoramaPreview(model: model)
            }
        }
    }
}

private struct PanoramaPreview: View {
    @ObservedObject var model: NativeWorkbenchModel
    @State private var showGuides = false
    @StateObject private var viewportController = PanoramaViewportController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewportController.fit()
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("0", modifiers: [.command])
                Button {
                    viewportController.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("-", modifiers: [.command])
                Button {
                    viewportController.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("+", modifiers: [.command])
                Button {
                    viewportController.actualSize()
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("1", modifiers: [.command])
                .help("Actual Size (one image pixel per screen point)")
                Toggle("Guides", isOn: $showGuides)
                Slider(
                    value: Binding(
                        get: { Double(viewportController.relativeZoom) },
                        set: { viewportController.setRelativeZoom(CGFloat($0)) }
                    ),
                    in: 0.10...16.0
                )
                    .frame(width: 180)
                Text("\(Int((viewportController.imagePixelScale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Toggle("Blend after drag", isOn: $model.settings.blendAfterProjectionDrag)
                    .help("When off, release saves geometry for export and keeps the Fast preview frame.")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            PanoramaCanvas(
                model: model,
                result: model.result,
                previewPixels: model.previewPixels,
                previewFrameVersion: model.previewFrameVersion,
                showGuides: showGuides,
                viewportController: viewportController
            )
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

private struct PanoramaCanvas: View {
    @ObservedObject var model: NativeWorkbenchModel
    var result: StitchResult?
    var previewPixels: PixelBufferInfo?
    var previewFrameVersion: UInt64
    var showGuides: Bool
    let viewportController: PanoramaViewportController
    @State private var displayedImage: CGImage?

    var body: some View {
        ZStack {
            if let result {
                Color.black.opacity(0.82)
                PanoramaViewport(
                    cgImage: displayedImage,
                    showGuides: showGuides,
                    projectionDragEnabled: model.settings.projectionDragEnabled && model.canDragProjection,
                    minimumRelativeZoom: 0.10,
                    maximumRelativeZoom: 16.0,
                    controller: viewportController,
                    onProjectionDragBegan: {
                        model.startProjectionDrag()
                    },
                    onProjectionDragChanged: { translation, rollOnly in
                        model.updateProjectionDrag(translation: translation, rollOnly: rollOnly)
                    },
                    onProjectionDragEnded: { translation, rollOnly in
                        model.finishProjectionDrag(translation: translation, rollOnly: rollOnly)
                    }
                )
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.panorama.width)x\(result.panorama.height)")
                        Text(result.projection)
                        Text(previewStatusLine(result))
                    }
                    .font(.caption)
                    .padding(8)
                    .foregroundStyle(.white.opacity(0.9))
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    if model.settings.projectionDragEnabled {
                        Text("pitch \(model.projectionPose.pitchDegrees, specifier: "%.2f")° · yaw \(model.projectionPose.yawDegrees, specifier: "%.2f")° · roll \(model.projectionPose.rollDegrees, specifier: "%.2f")°")
                            .font(.caption2.monospacedDigit())
                            .padding(7)
                            .foregroundStyle(.white.opacity(0.92))
                            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !model.projectionRenderStatus.isEmpty {
                        Text(model.projectionRenderStatus)
                            .font(.caption2)
                            .padding(7)
                            .foregroundStyle(.white.opacity(0.92))
                            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if result.projectionGeometryState == .unverifiedCameraDraft {
                        Rectangle()
                            .strokeBorder(Color.red.opacity(0.9), lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if result.projectionGeometryState == .unverifiedCameraDraft {
                        Label(
                            "Unverified Camera draft — projection drag is diagnostic; export remains locked",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.86), in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                    }
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
                ContentUnavailableView(
                    "No Panorama Preview",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Add photos and run a preview. Production export unlocks only for an exactly certified build.")
                )
            }
        }
        .onAppear {
            displayedImage = cgImage(from: previewPixels)
        }
        .onChange(of: previewFrameVersion) { _, _ in
            displayedImage = cgImage(from: previewPixels)
        }
    }

    private func cgImage(from pixels: PixelBufferInfo?) -> CGImage? {
        guard let pixels, pixels.width > 0, pixels.height > 0 else {
            return nil
        }
        guard let provider = CGDataProvider(data: pixels.data as CFData) else {
            return nil
        }
        return CGImage(
            width: pixels.width,
            height: pixels.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixels.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func previewStatusLine(_ result: StitchResult) -> String {
        let geometry = result.diagnostics["geometry"]?.stringValue ?? "unknown"
        let status = result.diagnostics["preview_status"]?.stringValue ?? "unknown"
        if let reason = result.diagnostics["preview_failure_reason"]?.stringValue, !reason.isEmpty {
            return "\(geometry) · \(status) · \(reason)"
        }
        return "\(geometry) · \(status)"
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: NativeWorkbenchModel
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var exportError: String?
    @State private var presentation = DiagnosticsPresentation.build(
        result: nil,
        gate: ParityGate.evaluate(result: nil)
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(presentation.statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(severityColor(presentation.statusSeverity))
                Spacer()
                Button {
                    isExporting = true
                    exportStatus = nil
                    let started = DiagnosticsExporter.export(model.result) { outputURL, errorMessage in
                        isExporting = false
                        exportError = errorMessage
                        if let outputURL {
                            exportStatus = "Exported \(outputURL.lastPathComponent)"
                        }
                    }
                    if !started { isExporting = false }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export JSON", systemImage: "doc.badge.arrow.up")
                    }
                }
                .disabled(model.result == nil || isExporting)
            }
            .padding(10)

            Text(presentation.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if let exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(presentation.sections) { section in
                        GroupBox(section.title) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(minimum: 180), alignment: .topLeading),
                                    GridItem(.flexible(minimum: 180), alignment: .topLeading),
                                ],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(section.metrics) { metric in
                                    DiagnosticMetricView(metric: metric)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    if let verification = presentation.cameraVerification {
                        GroupBox("Camera Verification") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verification.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.headline)
                                Text(verification.reason)
                                    .font(.callout)
                                Text("\(verification.independentlyValidatedEdgeCount) of \(verification.selectedEdgeCount) selected edges carry independent validation and final-held-out evidence.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if verification.kind == .ordinaryHeldOut && !verification.productionEligible {
                                    Label("Production export remains fail-closed until focused ordinary-Camera certification is promoted.", systemImage: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    GroupBox("Alignment Assistant") {
                        if presentation.alignmentSuggestions.isEmpty {
                            Label("No evidence-backed alignment suggestions for the current result.", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(presentation.alignmentSuggestions) { suggestion in
                                    AlignmentSuggestionView(suggestion: suggestion)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(10)
            }
        }
        .onAppear(perform: refreshPresentation)
        .onChange(of: model.result?.handle) { _, _ in refreshPresentation() }
        .onChange(of: model.previewFrameVersion) { _, _ in refreshPresentation() }
        .onChange(of: model.controlPointsDirty) { _, _ in refreshPresentation() }
        .onChange(of: model.lastExportProfile) { _, _ in refreshPresentation() }
        .onChange(of: model.parityGate) { _, _ in refreshPresentation() }
        .alert("Diagnostics Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The diagnostics report could not be written.")
        }
    }

    private var statusSymbol: String {
        switch presentation.statusSeverity {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .normal: return "info.circle"
        }
    }

    private func refreshPresentation() {
        presentation = DiagnosticsPresentation.build(
            result: model.result,
            gate: model.parityGate,
            exportProfile: model.lastExportProfile,
            controlPointsDirty: model.controlPointsDirty
        )
    }
}

private struct AlignmentSuggestionView: View {
    var suggestion: AlignmentSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: suggestion.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severityColor(suggestion.severity))
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.headline)
                Text(suggestion.summary)
                    .font(.callout)
                ForEach(Array(suggestion.evidence.enumerated()), id: \.offset) { _, evidence in
                    Text("\(evidence.metric): \(evidence.value) · \(evidence.source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(suggestion.actionLabel)
                    .font(.caption)
                    .foregroundStyle(.tint)
                if let region = suggestion.suggestedRegionA {
                    Text(String(format: "Suggested source-A region: x %.0f%%…%.0f%%, y %.0f%%…%.0f%%", region.x * 100, (region.x + region.width) * 100, region.y * 100, (region.y + region.height) * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if suggestion.isStale {
                    Label("Evidence predates the current control-point edits; re-optimize before relying on it.", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticMetricView: View {
    var metric: DiagnosticMetric

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(severityColor(metric.severity))
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let help = metric.help, !help.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(help)
                    }
                }
                Text(metric.value)
                    .font(.callout)
                    .foregroundStyle(metric.severity == .error ? Color.red : Color.primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func severityColor(_ severity: DiagnosticSeverity) -> Color {
    switch severity {
    case .success: return .green
    case .warning: return .orange
    case .error: return .red
    case .normal: return .secondary
    }
}

private struct InspectorPanel: View {
    @ObservedObject var model: NativeWorkbenchModel

    var body: some View {
        Form {
            Section("Actions") {
                Button {
                    model.runPreview()
                } label: {
                    Label("Run Preview", systemImage: "play.fill")
                }
                Button {
                    ExportPanel.exportFullResolution(from: model)
                } label: {
                    Label("Export Full-Res", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExportFullResolution)
            }

            Section("Preview") {
                Picker("Projection", selection: $model.settings.projection) {
                    Text("Equirectangular").tag("equirectangular")
                    Text("Cylindrical").tag("cylindrical")
                    Text("Rectilinear").tag("rectilinear")
                }
                Picker("Blend", selection: $model.settings.blendMode) {
                    Text("Feather").tag("feather")
                    Text("Multiband").tag("multiband")
                    Text("Source Ownership (Experimental)").tag("source_ownership")
                }
                Stepper("Max Input Side \(model.settings.previewMaxSide) px", value: $model.settings.previewMaxSide, in: 800...8000, step: 200)
                Stepper("Max Output \(model.settings.maxOutputPixels / 1_000_000) MP", value: $model.settings.maxOutputPixels, in: 4_000_000...500_000_000, step: 4_000_000)
                Stepper("Max Side \(model.settings.maxOutputSide) px", value: $model.settings.maxOutputSide, in: 2000...40000, step: 1000)
                Toggle("RAW Half Size", isOn: $model.settings.rawHalfSize)
                Toggle("Full Input Preview", isOn: $model.settings.fullInputPreview)
                Toggle("Display Stretch", isOn: $model.settings.displayStretch)
                Picker("Preview Renderer", selection: $model.settings.previewRendererBackend) {
                    Text("Auto").tag("auto")
                    Text("CPU").tag("cpu")
                    Text("Metal Fast").tag("metal_fast")
                    Text("Metal Quality").tag("metal_quality")
                }
                Slider(value: $model.settings.stretchStrength, in: 0...2) {
                    Text("Stretch Strength")
                }
            }

            Section("Align") {
                Picker("Mode", selection: $model.settings.alignmentMode) {
                    Text("Auto").tag("auto")
                    Text("Stars").tag("stars")
                    Text("SIFT").tag("sift")
                }
                Picker("Geometry", selection: $model.settings.astroGeometry) {
                    Text("Auto").tag("auto")
                    Text("Camera").tag("camera")
                    Text("Homography").tag("homography")
                }
                Picker("Star Search", selection: $model.settings.astroSkyMode) {
                    Text("Auto Sky").tag("auto_sky")
                    Text("Full Frame").tag("full_frame")
                }
                Stepper("Star Threshold \(model.settings.starThreshold, specifier: "%.1f")", value: $model.settings.starThreshold, in: 1...20, step: 0.5)
                Stepper("Max Stars \(model.settings.maxMatchStars)", value: $model.settings.maxMatchStars, in: 50...2000, step: 50)
                Stepper("Match Tolerance \(model.settings.matchPixelTolerance, specifier: "%.1f") px", value: $model.settings.matchPixelTolerance, in: 1...30, step: 0.5)
                Picker("Star Transform", selection: $model.settings.starTransformModel) {
                    Text("Similarity").tag("similarity")
                    Text("Homography").tag("homography")
                }
            }

            Section("Camera") {
                Toggle("Optimize Focal", isOn: $model.settings.optimizeFocal)
                Toggle("Optimize Distortion", isOn: $model.settings.optimizeDistortion)
                Stepper("Max Iterations \(model.settings.optimizerMaxIterations)", value: $model.settings.optimizerMaxIterations, in: 10...1000, step: 10)
                HStack {
                    Button("Choose Lens Profile…") {
                        LensProfilePanel.choose(into: model)
                    }
                    Button("Clear") {
                        LensProfilePanel.clear(from: model)
                    }
                    .disabled(model.settings.lensCalibrationPrior == nil)
                }
                if let prior = model.settings.lensCalibrationPrior {
                    Text(prior.profileName)
                        .lineLimit(2)
                    Text("\(prior.lensName) · SHA-256 \(prior.sha256.prefix(12))…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let warning = prior.warning {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Pose") {
                Toggle("Drag Projection", isOn: $model.settings.projectionDragEnabled)
                    .disabled(!model.canDragProjection)
                if !model.canDragProjection {
                    Text(model.projectionDragUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Reset Projection") {
                    model.resetProjectionPose()
                }
                .disabled(!model.canDragProjection)
            }

            Section("Diagnostics") {
                Text("Status: \(diagnosticString("preview_status"))")
                Text("Geometry: \(diagnosticString("geometry"))")
                if !model.astroRefinementStatus.isEmpty {
                    Text("Astro refinement: \(model.astroRefinementStatus)")
                }
                if !model.manualPointRefinementRecords.isEmpty {
                    let accepted = model.manualPointRefinementRecords.filter(\.accepted).count
                    Text("Manual points: \(accepted)/\(model.manualPointRefinementRecords.count) accepted")
                }
                Text("High-conf P95: \(starProjectionText("high_confidence")) px")
                Text("Mutual P95: \(starProjectionText("mutual")) px")
                if let reason = model.result?.diagnostics["preview_failure_reason"]?.stringValue {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Export") {
                Picker("Renderer", selection: $model.exportSettings.rendererBackend) {
                    Text("Auto").tag("auto")
                    Text("CPU Quality").tag("cpu")
                    Text(metalRendererLabel("Metal Quality", quality: true)).tag("metal_quality")
                    Text(metalRendererLabel("Metal Fast", quality: false)).tag("metal_fast")
                    Text("Full-Resolution Diagnostic").tag("fullres_camera_strip_tiff_diagnostic")
                }
                Picker("Bit Depth", selection: $model.exportSettings.bitDepth) {
                    Text("16-bit").tag(16)
                    Text("8-bit").tag(8)
                }
                Stepper(
                    model.exportSettings.workingSetBudgetMB == 0
                        ? "Working Set: Auto"
                        : "Working Set: \(model.exportSettings.workingSetBudgetMB) MB",
                    value: $model.exportSettings.workingSetBudgetMB,
                    in: 0...8192,
                    step: 256
                )
                .help("Zero uses one eighth of physical memory, clamped to 512–2048 MB. A forced low budget fails before an oversized source decode.")
                Toggle("Apply Preview Stretch", isOn: $model.exportSettings.applyPreviewStretch)
                if !model.canExportFullResolution {
                    Text(model.fullResolutionExportUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.exportSettings.rendererBackend == "fullres_camera_strip_tiff_diagnostic" {
                    Text("Diagnostic export only; production parity incomplete.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let url = model.lastExportURL {
                    Text("Last export: \(url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let profile = model.lastExportProfile {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Renderer: \(stringText(profile, "renderer_requested")) -> \(stringText(profile, "renderer_used")) · CPU fallback \(boolText(profile, "cpu_fallback"))")
                        Text("Output: \(integerText(profile, "width"))x\(integerText(profile, "height")) · \(integerText(profile, "bit_depth"))-bit")
                        Text("Time: \(decimalText(profile, "total_seconds"))s · Process peak: \(decimalText(profile, "peak_memory_mb")) MB")
                        Text("Export sampled peak: \(decimalText(profile, "operation_peak_rss_mb")) MB · Increase: \(decimalText(profile, "operation_peak_rss_delta_mb")) MB")
                        Text("Budget: \(decimalText(profile, "working_set_budget_effective_mb")) MB · Source leases: \(integerText(profile, "active_source_leases_peak"))")
                        Text("Overlap: \(integerText(profile, "overlap_pixels")) px · Mean diff \(decimalText(profile, "mean_overlap_absdiff"))")
                        if let reason = profile["renderer_fallback_reason"]?.stringValue {
                            Text(reason)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Release Status") {
                Text(model.capabilities?.nativeAlgorithmParity == true ? "Certified for production export" : "Development build — production export locked")
                    .foregroundStyle(model.capabilities?.nativeAlgorithmParity == true ? .green : .orange)
                Text("Metal renderer: \(model.capabilities?.nativeMetalRendererAvailable == true ? "available" : "unavailable") · quality \(model.capabilities?.nativeMetalQualityAvailable == true ? "available" : "unavailable")")
                    .font(.caption)
                    .foregroundStyle(model.capabilities?.nativeMetalRendererAvailable == true ? Color.secondary : Color.orange)
                Text("Preview GPU: \(model.capabilities?.nativePreviewGPUAvailable == true ? "available" : "not active")")
                    .font(.caption)
                    .foregroundStyle(model.capabilities?.nativePreviewGPUAvailable == true ? Color.secondary : Color.orange)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func integerText(_ profile: JSONValue, _ key: String) -> String {
        guard let value = profile[key]?.numberValue else {
            return "n/a"
        }
        return String(Int(value.rounded()))
    }

    private func decimalText(_ profile: JSONValue, _ key: String) -> String {
        guard let value = profile[key]?.numberValue else {
            return "n/a"
        }
        return String(format: "%.3f", value)
    }

    private func stringText(_ profile: JSONValue, _ key: String) -> String {
        profile[key]?.stringValue ?? "n/a"
    }

    private func boolText(_ profile: JSONValue, _ key: String) -> String {
        guard let value = profile[key]?.boolValue else {
            return "n/a"
        }
        return value ? "yes" : "no"
    }

    private func metalRendererLabel(_ base: String, quality: Bool) -> String {
        let available = quality
            ? model.capabilities?.nativeMetalQualityAvailable == true
            : model.capabilities?.nativeMetalRendererAvailable == true
        return available ? base : "\(base) (CPU fallback)"
    }

    private func diagnosticString(_ key: String) -> String {
        model.result?.diagnostics[key]?.stringValue ?? "n/a"
    }

    private func starProjectionText(_ key: String) -> String {
        guard let value = model.result?.diagnostics["star_projection_alignment"]?[key]?["p95"]?.numberValue else {
            return "n/a"
        }
        return String(format: "%.3f", value)
    }
}

private struct StatusFooter: View {
    @ObservedObject var model: NativeWorkbenchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.jobState {
            case .idle:
                Text("Ready")
            case .running(let stage, let fraction):
                ProgressView(value: fraction)
                Text(stage)
                    .font(.caption)
            case .completed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
