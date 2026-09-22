import AppKit
import CoreGraphics
import SwiftUI
import MyPTGuiCore

private struct ControlPointPairKey: Hashable, Identifiable {
    var imageA: Int
    var imageB: Int

    init(_ first: Int, _ second: Int) {
        imageA = min(first, second)
        imageB = max(first, second)
    }

    var id: String { "\(imageA)-\(imageB)" }
}

private struct ControlPointCanvasMarker: Identifiable, Equatable {
    var id: UUID
    var number: Int
    var position: CGPoint
    var isManual: Bool
    var error: Double
}

private struct ControlPointCanvas: NSViewRepresentable {
    var image: CGImage?
    var markers: [ControlPointCanvasMarker]
    var selectedID: UUID?
    var addMode: Bool
    var pendingPoint: CGPoint?
    var onSelect: (UUID) -> Void
    var onImageClick: (CGPoint) -> Void
    var onCancel: () -> Void
    var onDeleteSelected: (UUID) -> Void

    func makeNSView(context: Context) -> ControlPointCanvasNSView {
        let view = ControlPointCanvasNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ControlPointCanvasNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ControlPointCanvasNSView) {
        view.image = image
        view.markers = markers
        view.selectedID = selectedID
        view.addMode = addMode
        view.pendingPoint = pendingPoint
        view.onSelect = onSelect
        view.onImageClick = onImageClick
        view.onCancel = onCancel
        view.onDeleteSelected = onDeleteSelected
    }
}

private final class ControlPointCanvasNSView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var markers: [ControlPointCanvasMarker] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var addMode = false {
        didSet {
            if let window { window.invalidateCursorRects(for: self) }
            needsDisplay = true
        }
    }
    var pendingPoint: CGPoint? { didSet { needsDisplay = true } }
    var onSelect: (UUID) -> Void = { _ in }
    var onImageClick: (CGPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onDeleteSelected: (UUID) -> Void = { _ in }

    private var hoverViewPoint: CGPoint?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 260) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Control-point source image")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoverViewPoint = convert(event.locationInWindow, from: nil)
        if addMode { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoverViewPoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = geometry.imagePoint(fromViewPoint: point) else { return }
        if addMode {
            onImageClick(imagePoint)
            return
        }
        if let marker = nearestMarker(to: point, maximumDistance: 10) {
            onSelect(marker.id)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func deleteBackward(_ sender: Any?) {
        if let selectedID {
            onDeleteSelected(selectedID)
        } else {
            super.deleteBackward(sender)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: addMode ? .crosshair : .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        dirtyRect.fill()
        guard let image else { return }

        let rect = geometry.imageRect
        let nsImage = NSImage(cgImage: image, size: rect.size)
        NSGraphicsContext.current?.imageInterpolation = .high
        nsImage.draw(
            in: rect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        drawMarkers()
        drawPendingPoint()
        if addMode { drawLoupe() }
    }

    private var geometry: AspectFitCoordinateMapper {
        AspectFitCoordinateMapper(
            imageSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            bounds: bounds.insetBy(dx: 6, dy: 6)
        )
    }

    private func nearestMarker(to viewPoint: CGPoint, maximumDistance: CGFloat) -> ControlPointCanvasMarker? {
        markers.min { lhs, rhs in
            distance(geometry.viewPoint(fromImagePoint: lhs.position), viewPoint)
                < distance(geometry.viewPoint(fromImagePoint: rhs.position), viewPoint)
        }.flatMap { marker in
            distance(geometry.viewPoint(fromImagePoint: marker.position), viewPoint) <= maximumDistance ? marker : nil
        }
    }

    private func drawMarkers() {
        let showAllNumbers = markers.count <= 300
        for marker in markers {
            let center = geometry.viewPoint(fromImagePoint: marker.position)
            let selected = marker.id == selectedID
            let radius: CGFloat = selected ? 7 : 5
            let path = NSBezierPath(ovalIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            (marker.isManual ? NSColor.systemYellow : markerColor(marker.number)).withAlphaComponent(0.25).setFill()
            path.fill()
            (selected ? NSColor.white : (marker.isManual ? .systemYellow : markerColor(marker.number))).setStroke()
            path.lineWidth = selected ? 2.5 : 1.5
            path.stroke()

            if showAllNumbers || selected {
                let text = String(marker.number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: selected ? 11 : 9, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -3,
                ]
                text.draw(at: CGPoint(x: center.x + radius + 2, y: center.y - 7), withAttributes: attributes)
            }
        }
    }

    private func drawPendingPoint() {
        guard let pendingPoint else { return }
        let center = geometry.viewPoint(fromImagePoint: pendingPoint)
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        NSColor.systemYellow.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawLoupe() {
        guard let image,
              let hoverViewPoint,
              let imagePoint = geometry.imagePoint(fromViewPoint: hoverViewPoint) else { return }
        let diameter: CGFloat = 120
        var origin = CGPoint(x: hoverViewPoint.x + 18, y: hoverViewPoint.y + 18)
        if origin.x + diameter > bounds.maxX { origin.x = hoverViewPoint.x - diameter - 18 }
        if origin.y + diameter > bounds.maxY { origin.y = hoverViewPoint.y - diameter - 18 }
        let loupeRect = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: loupeRect).addClip()
        NSColor.black.setFill()
        loupeRect.fill()
        let baseScale = geometry.imageRect.width / max(CGFloat(image.width), 1)
        let scale = baseScale * 6
        let imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let destination = CGRect(
            x: loupeRect.midX - imagePoint.x * scale,
            y: loupeRect.midY - imagePoint.y * scale,
            width: imageSize.width,
            height: imageSize.height
        )
        NSImage(cgImage: image, size: imageSize).draw(
            in: destination,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(ovalIn: loupeRect)
        NSColor.white.setStroke()
        border.lineWidth = 2
        border.stroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: loupeRect.midX - 10, y: loupeRect.midY))
        crosshair.line(to: CGPoint(x: loupeRect.midX + 10, y: loupeRect.midY))
        crosshair.move(to: CGPoint(x: loupeRect.midX, y: loupeRect.midY - 10))
        crosshair.line(to: CGPoint(x: loupeRect.midX, y: loupeRect.midY + 10))
        NSColor.systemYellow.setStroke()
        crosshair.lineWidth = 1
        crosshair.stroke()
    }

    private func markerColor(_ number: Int) -> NSColor {
        NSColor(calibratedHue: CGFloat((number * 47) % 360) / 360, saturation: 0.82, brightness: 1, alpha: 1)
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

}

struct ControlPointsView: View {
    @ObservedObject var model: NativeWorkbenchModel
    @State private var selectedPair: ControlPointPairKey?
    @State private var selectedImageA: Int?
    @State private var selectedImageB: Int?
    @State private var selectedPointID: UUID?
    @State private var addMode = false
    @State private var pendingPointA: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let pair = selectedPair, let result = model.result {
                pairEditor(pair: pair, result: result)
            } else {
                ContentUnavailableView(
                    "No control-point pair",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Run a preview with at least two source images.")
                )
            }
        }
        .onAppear(perform: selectDefaultPair)
        .onChange(of: model.result?.handle) { _, _ in selectDefaultPair() }
        .onChange(of: selectedPair) { _, pair in
            cancelPendingPoint()
            selectedPointID = nil
            if let pair { model.loadControlPointImages(imageAIndex: pair.imageA, imageBIndex: pair.imageB) }
        }
        .onChange(of: selectedImageA) { _, _ in updatePairFromImageSelectors() }
        .onChange(of: selectedImageB) { _, _ in updatePairFromImageSelectors() }
        .onExitCommand(perform: cancelPendingPoint)
        .onDeleteCommand {
            if let selectedPointID {
                model.deleteControlPoint(id: selectedPointID)
                self.selectedPointID = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(model.result?.controlPoints.count ?? 0) control points")
                .font(.headline)
            if model.controlPointsDirty {
                Label("Edited", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("First image", selection: $selectedImageA) {
                ForEach(imageIndices.filter { $0 != selectedImageB }, id: \.self) { index in
                    imageChoiceLabel(index: index, counterpart: selectedImageB)
                        .tag(Optional(index))
                }
            }
            .frame(minWidth: 190, idealWidth: 250)
            Picker("Second image", selection: $selectedImageB) {
                ForEach(imageIndices.filter { $0 != selectedImageA }, id: \.self) { index in
                    imageChoiceLabel(index: index, counterpart: selectedImageA)
                        .tag(Optional(index))
                }
            }
            .frame(minWidth: 190, idealWidth: 250)
            .disabled(imageIndices.count < 2)
            .help("I = import order; C = canonical capture-time order. Filled markers indicate a pair with control points.")
            Toggle(isOn: $addMode) {
                Label("Add Point", systemImage: "plus.circle")
            }
            .toggleStyle(.button)
            .onChange(of: addMode) { _, enabled in
                if !enabled { pendingPointA = nil }
            }
            Button(role: .destructive) {
                guard let pair = selectedPair else { return }
                model.clearControlPoints(imageAIndex: pair.imageA, imageBIndex: pair.imageB)
                selectedPointID = nil
                cancelPendingPoint()
            } label: {
                Label("Clear Pair", systemImage: "trash")
            }
            .disabled(pointsForSelectedPair.isEmpty)
            Spacer()
            Button {
                cancelPendingPoint()
                model.rerenderFromControlPoints()
            } label: {
                Label("Re-optimize", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.canReoptimizeControlPoints)
        }
        .padding(10)
    }

    @ViewBuilder
    private func pairEditor(pair: ControlPointPairKey, result: StitchResult) -> some View {
        VStack(spacing: 0) {
            if let error = model.controlPointImageLoadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            HSplitView {
                sourcePanel(
                    title: sourceName(result, index: pair.imageA),
                    imageIndex: pair.imageA,
                    image: cgImage(from: model.controlPointImagePixels[pair.imageA]),
                    markers: markers(for: pair.imageA),
                    pendingPoint: pendingPointA,
                    click: { point in
                        guard addMode else { return }
                        pendingPointA = point
                    }
                )
                sourcePanel(
                    title: sourceName(result, index: pair.imageB),
                    imageIndex: pair.imageB,
                    image: cgImage(from: model.controlPointImagePixels[pair.imageB]),
                    markers: markers(for: pair.imageB),
                    pendingPoint: nil,
                    click: { point in
                        guard addMode, let first = pendingPointA else { return }
                        model.addControlPoint(
                            imageAIndex: pair.imageA,
                            imageBIndex: pair.imageB,
                            pointA: first,
                            pointB: point
                        )
                        pendingPointA = nil
                    }
                )
            }
            .overlay {
                if model.controlPointImagesLoading {
                    ProgressView("Loading source images…")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(minHeight: 280)

            Divider()
            pointList
                .frame(minHeight: 150, idealHeight: 210, maxHeight: 280)
        }
    }

    private func sourcePanel(
        title: String,
        imageIndex: Int,
        image: CGImage?,
        markers: [ControlPointCanvasMarker],
        pendingPoint: CGPoint?,
        click: @escaping (CGPoint) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(imageLabel(index: imageIndex))
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            ControlPointCanvas(
                image: image,
                markers: markers,
                selectedID: selectedPointID,
                addMode: addMode,
                pendingPoint: pendingPoint,
                onSelect: { selectedPointID = $0 },
                onImageClick: click,
                onCancel: cancelPendingPoint,
                onDeleteSelected: { id in
                    model.deleteControlPoint(id: id)
                    if selectedPointID == id { selectedPointID = nil }
                }
            )
        }
    }

    private var pointList: some View {
        List(selection: $selectedPointID) {
            ForEach(Array(pointsForSelectedPair.enumerated()), id: \.element.id) { offset, point in
                HStack(spacing: 10) {
                    Text("#\(offset + 1)")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                    Text("A (\(pointCoordinate(point, image: selectedPair?.imageA).x, specifier: "%.1f"), \(pointCoordinate(point, image: selectedPair?.imageA).y, specifier: "%.1f"))")
                    Text("B (\(pointCoordinate(point, image: selectedPair?.imageB).x, specifier: "%.1f"), \(pointCoordinate(point, image: selectedPair?.imageB).y, specifier: "%.1f"))")
                    if point.isManual {
                        Label("Manual", systemImage: "hand.point.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text(point.isManual && model.controlPointsDirty ? "Pending" : String(format: "%.2f px", point.error))
                        .monospacedDigit()
                        .foregroundStyle(point.error >= 5 ? .orange : .secondary)
                    Button(role: .destructive) {
                        model.deleteControlPoint(id: point.id)
                        if selectedPointID == point.id { selectedPointID = nil }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .tag(point.id)
            }
        }
    }

    private var allPairs: [ControlPointPairKey] {
        guard let result = model.result, result.sourceImages.count >= 2 else { return [] }
        return (0..<(result.sourceImages.count - 1)).flatMap { first in
            ((first + 1)..<result.sourceImages.count).map { ControlPointPairKey(first, $0) }
        }
    }

    private var imageIndices: [Int] {
        Array(model.result?.sourceImages.indices ?? 0..<0)
    }

    private var pointsForSelectedPair: [ControlPoint] {
        guard let pair = selectedPair else { return [] }
        return (model.result?.controlPoints ?? [])
            .filter { ControlPointPairKey($0.imageAIndex, $0.imageBIndex) == pair }
            .sorted { lhs, rhs in
                if abs(lhs.error - rhs.error) > 1e-9 { return lhs.error > rhs.error }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func markers(for imageIndex: Int) -> [ControlPointCanvasMarker] {
        pointsForSelectedPair.enumerated().map { offset, point in
            ControlPointCanvasMarker(
                id: point.id,
                number: offset + 1,
                position: pointCoordinate(point, image: imageIndex),
                isManual: point.isManual,
                error: point.error
            )
        }
    }

    private func pointCoordinate(_ point: ControlPoint, image: Int?) -> CGPoint {
        guard let image else { return .zero }
        if point.imageAIndex == image { return CGPoint(x: point.xA, y: point.yA) }
        if point.imageBIndex == image { return CGPoint(x: point.xB, y: point.yB) }
        return .zero
    }

    private func selectDefaultPair() {
        cancelPendingPoint()
        selectedPointID = nil
        let pairs = allPairs
        guard !pairs.isEmpty else { selectedPair = nil; return }
        let grouped = Dictionary(grouping: model.result?.controlPoints ?? []) {
            ControlPointPairKey($0.imageAIndex, $0.imageBIndex)
        }
        let previousPair = selectedPair
        let defaultPair = pairs.max { lhs, rhs in
            pairRisk(lhs, points: grouped[lhs] ?? []) < pairRisk(rhs, points: grouped[rhs] ?? [])
        } ?? pairs[0]
        selectedImageA = defaultPair.imageA
        selectedImageB = defaultPair.imageB
        selectedPair = defaultPair
        // A new result can have the same pair key as the old result, in which
        // case SwiftUI's onChange does not fire and the cache still needs to be
        // refreshed. Changed selections are loaded by the onChange handler.
        if previousPair == defaultPair {
            model.loadControlPointImages(imageAIndex: defaultPair.imageA, imageBIndex: defaultPair.imageB)
        }
    }

    private func pairRisk(_ pair: ControlPointPairKey, points: [ControlPoint]) -> Double {
        if let heldOut = model.result?.diagnostics["astro_refinement"]?["pairs"]?.arrayValue?.first(where: {
            Int($0["i"]?.numberValue ?? -1) == pair.imageA
                && Int($0["j"]?.numberValue ?? -1) == pair.imageB
        }) {
            return heldOut["pair_risk_ratio"]?.numberValue
                ?? heldOut["p95_px"]?.numberValue
                ?? pairP95(points)
        }
        return pairP95(points)
    }

    private func pairP95(_ points: [ControlPoint]) -> Double {
        let errors = points.map(\.error).filter(\.isFinite).sorted()
        guard !errors.isEmpty else { return -1 }
        let position = Double(errors.count - 1) * 0.95
        let low = Int(floor(position))
        let high = Int(ceil(position))
        if low == high { return errors[low] }
        let alpha = position - Double(low)
        return errors[low] * (1 - alpha) + errors[high] * alpha
    }

    @ViewBuilder
    private func imageChoiceLabel(index: Int, counterpart: Int?) -> some View {
        let pair = counterpart.map { ControlPointPairKey(index, $0) }
        let points = pair.map { pairPoints($0) } ?? []
        HStack(spacing: 6) {
            Image(systemName: points.isEmpty ? "circle" : "circle.fill")
                .foregroundStyle(pairQualityColor(pair: pair, points: points))
            Text(imageLabel(index: index))
            if pair != nil {
                Text("\(points.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func imageLabel(index: Int) -> String {
        guard let result = model.result, result.sourceImages.indices.contains(index) else {
            return "C\(index + 1) Unknown"
        }
        let path = result.sourceImages[index].path
        let importIndex = model.photos.firstIndex {
            $0.url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
        }.map { $0 + 1 }
        return "I\(importIndex.map(String.init) ?? "—") · C\(index + 1) · \(sourceName(result, index: index))"
    }

    private func pairPoints(_ pair: ControlPointPairKey) -> [ControlPoint] {
        (model.result?.controlPoints ?? []).filter {
            ControlPointPairKey($0.imageAIndex, $0.imageBIndex) == pair
        }
    }

    private func pairQualityColor(pair: ControlPointPairKey?, points: [ControlPoint]) -> Color {
        guard let pair, !points.isEmpty else { return .secondary }
        let risk = pairRisk(pair, points: points)
        if risk <= 1.0 { return .green }
        if risk <= 1.5 { return .yellow }
        return .red
    }

    private func updatePairFromImageSelectors() {
        guard let first = selectedImageA, let second = selectedImageB, first != second else {
            return
        }
        let pair = ControlPointPairKey(first, second)
        if selectedPair != pair {
            selectedPair = pair
        }
    }

    private func sourceName(_ result: StitchResult, index: Int) -> String {
        guard result.sourceImages.indices.contains(index) else { return "Unknown" }
        return URL(fileURLWithPath: result.sourceImages[index].path).lastPathComponent
    }

    private func cancelPendingPoint() {
        pendingPointA = nil
        addMode = false
    }

    private func cgImage(from pixels: PixelBufferInfo?) -> CGImage? {
        guard let pixels, pixels.width > 0, pixels.height > 0,
              let provider = CGDataProvider(data: pixels.data as CFData) else { return nil }
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
}
