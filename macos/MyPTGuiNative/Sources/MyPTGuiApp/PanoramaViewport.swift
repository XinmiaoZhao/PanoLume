import AppKit
import CoreGraphics
import SwiftUI

/// The imperative side of ``PanoramaViewport``. Keep one controller alive in
/// the owning SwiftUI view and use it for toolbar and keyboard zoom commands.
@MainActor
final class PanoramaViewportController: ObservableObject {
    @Published private(set) var relativeZoom: CGFloat = 1.0
    @Published private(set) var isFit: Bool = true
    /// Screen points per pixel in the currently displayed raster.
    @Published private(set) var imagePixelScale: CGFloat = 1.0

    private weak var viewport: PanoramaViewportScrollView?

    func zoomIn() {
        viewport?.zoom(byRelativeFactor: 1.25, aroundWindowPoint: nil)
    }

    func zoomOut() {
        viewport?.zoom(byRelativeFactor: 1.0 / 1.25, aroundWindowPoint: nil)
    }

    func fit() {
        viewport?.fitImage()
    }

    func actualSize() {
        viewport?.setImagePixelScale(1.0, aroundWindowPoint: nil)
    }

    func setRelativeZoom(_ zoom: CGFloat) {
        viewport?.setRelativeZoom(zoom, aroundWindowPoint: nil)
    }

    func setImagePixelScale(_ scale: CGFloat) {
        viewport?.setImagePixelScale(scale, aroundWindowPoint: nil)
    }

    fileprivate func attach(to viewport: PanoramaViewportScrollView) {
        self.viewport = viewport
        viewportDidChange(
            relativeZoom: viewport.currentRelativeZoom,
            imagePixelScale: viewport.magnification
        )
    }

    fileprivate func detach(from viewport: PanoramaViewportScrollView) {
        if self.viewport === viewport {
            self.viewport = nil
        }
    }

    fileprivate func viewportDidChange(relativeZoom: CGFloat, imagePixelScale: CGFloat) {
        let finiteZoom = relativeZoom.isFinite ? relativeZoom : 1.0
        let normalizedZoom = max(finiteZoom, 0.000_1)
        if abs(self.relativeZoom - normalizedZoom) > 0.000_1 {
            self.relativeZoom = normalizedZoom
        }
        let newIsFit = abs(normalizedZoom - 1.0) <= 0.001
        if isFit != newIsFit {
            isFit = newIsFit
        }
        let finitePixelScale = imagePixelScale.isFinite ? max(imagePixelScale, 0.000_1) : 1.0
        if abs(self.imagePixelScale - finitePixelScale) > 0.000_1 {
            self.imagePixelScale = finitePixelScale
        }
    }
}

/// An AppKit-backed panorama surface with native trackpad navigation.
///
/// Primary-button drags are reserved for projection adjustment. Precise
/// scrolling pans; a mouse wheel zooms; pinch gestures zoom around the pointer;
/// and Space-primary-drag or middle-button-drag pans as a mouse fallback.
@MainActor
struct PanoramaViewport: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let image: CGImage?
    var showGuides: Bool
    var projectionDragEnabled: Bool
    var minimumRelativeZoom: CGFloat
    var maximumRelativeZoom: CGFloat
    let controller: PanoramaViewportController
    var onProjectionDragBegan: @MainActor () -> Void
    var onProjectionDragChanged: @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void
    var onProjectionDragEnded: @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void

    init(
        cgImage: CGImage?,
        showGuides: Bool = false,
        projectionDragEnabled: Bool = true,
        minimumRelativeZoom: CGFloat = 0.10,
        maximumRelativeZoom: CGFloat = 16.0,
        controller: PanoramaViewportController,
        onProjectionDragBegan: @escaping @MainActor () -> Void = {},
        onProjectionDragChanged: @escaping @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void = { _, _ in },
        onProjectionDragEnded: @escaping @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void = { _, _ in }
    ) {
        image = cgImage
        self.showGuides = showGuides
        self.projectionDragEnabled = projectionDragEnabled
        self.minimumRelativeZoom = minimumRelativeZoom
        self.maximumRelativeZoom = maximumRelativeZoom
        self.controller = controller
        self.onProjectionDragBegan = onProjectionDragBegan
        self.onProjectionDragChanged = onProjectionDragChanged
        self.onProjectionDragEnded = onProjectionDragEnded
    }

    init(
        nsImage: NSImage?,
        showGuides: Bool = false,
        projectionDragEnabled: Bool = true,
        minimumRelativeZoom: CGFloat = 0.10,
        maximumRelativeZoom: CGFloat = 16.0,
        controller: PanoramaViewportController,
        onProjectionDragBegan: @escaping @MainActor () -> Void = {},
        onProjectionDragChanged: @escaping @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void = { _, _ in },
        onProjectionDragEnded: @escaping @MainActor (_ translation: CGSize, _ rollOnly: Bool) -> Void = { _, _ in }
    ) {
        self.init(
            cgImage: Self.cgImage(from: nsImage),
            showGuides: showGuides,
            projectionDragEnabled: projectionDragEnabled,
            minimumRelativeZoom: minimumRelativeZoom,
            maximumRelativeZoom: maximumRelativeZoom,
            controller: controller,
            onProjectionDragBegan: onProjectionDragBegan,
            onProjectionDragChanged: onProjectionDragChanged,
            onProjectionDragEnded: onProjectionDragEnded
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PanoramaViewportScrollView()
        applyConfiguration(to: scrollView)
        scrollView.replaceImage(image)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let scrollView = nsView as? PanoramaViewportScrollView else {
            return
        }
        applyConfiguration(to: scrollView)
        if !scrollView.isDisplayingSameImage(image) {
            scrollView.replaceImage(image)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        guard let scrollView = nsView as? PanoramaViewportScrollView else {
            return
        }
        scrollView.viewportController = nil
    }

    private func applyConfiguration(to scrollView: PanoramaViewportScrollView) {
        scrollView.minimumRelativeZoom = max(0.001, minimumRelativeZoom)
        scrollView.maximumRelativeZoom = max(scrollView.minimumRelativeZoom, maximumRelativeZoom)
        scrollView.projectionDragEnabled = projectionDragEnabled
        scrollView.panoramaDocumentView.showGuides = showGuides
        scrollView.onProjectionDragBegan = onProjectionDragBegan
        scrollView.onProjectionDragChanged = onProjectionDragChanged
        scrollView.onProjectionDragEnded = onProjectionDragEnded
        scrollView.viewportController = controller
    }

    private static func cgImage(from image: NSImage?) -> CGImage? {
        guard let image else {
            return nil
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

private struct PanoramaViewportState {
    var normalizedCenter: CGPoint
    var relativeZoom: CGFloat
}

private enum PanoramaPointerInteraction {
    case idle
    case projectionPending(startWindowPoint: CGPoint)
    case projection(startWindowPoint: CGPoint)
    case pan(lastWindowPoint: CGPoint)
}

/// `NSView` deinitializers are nonisolated under Swift 6. Let a small
/// Sendable lifetime token own removal of the otherwise untyped AppKit event
/// monitor so teardown remains deterministic without reaching into main-actor
/// state from `deinit`.
private final class PanoramaEventMonitorToken: @unchecked Sendable {
    private let monitor: Any

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    deinit {
        NSEvent.removeMonitor(monitor)
    }
}

/// Allows the image to remain centered when its magnified size is smaller than
/// the viewport. Negative clip origins are intentional in that case.
private final class PanoramaCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else {
            return constrained
        }

        let documentFrame = documentView.frame
        if proposedBounds.width >= documentFrame.width {
            constrained.origin.x = documentFrame.midX - proposedBounds.width / 2.0
        }
        if proposedBounds.height >= documentFrame.height {
            constrained.origin.y = documentFrame.midY - proposedBounds.height / 2.0
        }
        return constrained
    }
}

private final class PanoramaDocumentView: NSView {
    var image: CGImage? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(image == nil ? "Empty panorama viewport" : "Panorama preview")
        }
    }

    var showGuides = false {
        didSet {
            if oldValue != showGuides {
                needsDisplay = true
            }
        }
    }

    weak var panoramaScrollView: PanoramaViewportScrollView?
    private var pointerInteraction = PanoramaPointerInteraction.idle

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Empty panorama viewport")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image else {
            return
        }

        let scale = max(panoramaScrollView?.magnification ?? 1.0, 0.000_1)
        drawTransparencyCheckerboard(scale: scale)
        let drawableImage = NSImage(cgImage: image, size: bounds.size)
        NSGraphicsContext.current?.imageInterpolation = .high
        drawableImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        if showGuides {
            drawGuides()
        }
        drawCanvasBorder(scale: scale)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        if case .pan = pointerInteraction {
            cursor = .closedHand
        } else if panoramaScrollView?.isSpacePressed == true {
            cursor = .openHand
        } else if panoramaScrollView?.projectionDragEnabled == true {
            cursor = .crosshair
        } else {
            cursor = .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = panoramaScrollView else {
            return
        }
        window?.makeFirstResponder(self)
        if scrollView.isSpacePressed {
            pointerInteraction = .pan(lastWindowPoint: event.locationInWindow)
            window?.invalidateCursorRects(for: self)
        } else if scrollView.projectionDragEnabled {
            pointerInteraction = .projectionPending(startWindowPoint: event.locationInWindow)
        } else {
            pointerInteraction = .idle
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = panoramaScrollView else {
            return
        }
        switch pointerInteraction {
        case .projectionPending(let startWindowPoint):
            pointerInteraction = .projection(startWindowPoint: startWindowPoint)
            scrollView.onProjectionDragBegan()
            scrollView.onProjectionDragChanged(
                projectionTranslation(from: startWindowPoint, to: event.locationInWindow),
                event.modifierFlags.contains(.shift)
            )
        case .projection(let startWindowPoint):
            scrollView.onProjectionDragChanged(
                projectionTranslation(from: startWindowPoint, to: event.locationInWindow),
                event.modifierFlags.contains(.shift)
            )
        case .pan(let lastWindowPoint):
            scrollView.panDocument(
                byWindowDelta: CGSize(
                    width: event.locationInWindow.x - lastWindowPoint.x,
                    height: event.locationInWindow.y - lastWindowPoint.y
                )
            )
            pointerInteraction = .pan(lastWindowPoint: event.locationInWindow)
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let scrollView = panoramaScrollView else {
            pointerInteraction = .idle
            return
        }
        if case .projection(let startWindowPoint) = pointerInteraction {
            scrollView.onProjectionDragEnded(
                projectionTranslation(from: startWindowPoint, to: event.locationInWindow),
                event.modifierFlags.contains(.shift)
            )
        }
        pointerInteraction = .idle
        window?.invalidateCursorRects(for: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        pointerInteraction = .pan(lastWindowPoint: event.locationInWindow)
        window?.invalidateCursorRects(for: self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2,
              let scrollView = panoramaScrollView,
              case .pan(let lastWindowPoint) = pointerInteraction else {
            super.otherMouseDragged(with: event)
            return
        }
        scrollView.panDocument(
            byWindowDelta: CGSize(
                width: event.locationInWindow.x - lastWindowPoint.x,
                height: event.locationInWindow.y - lastWindowPoint.y
            )
        )
        pointerInteraction = .pan(lastWindowPoint: event.locationInWindow)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        pointerInteraction = .idle
        window?.invalidateCursorRects(for: self)
    }

    private func projectionTranslation(from start: CGPoint, to current: CGPoint) -> CGSize {
        // SwiftUI's DragGesture reports positive height while dragging down;
        // AppKit window coordinates increase upward.
        CGSize(width: current.x - start.x, height: start.y - current.y)
    }

    private func drawGuides() {
        let scale = max(panoramaScrollView?.magnification ?? 1.0, 0.001)
        let path = NSBezierPath()
        for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            let x = bounds.width * fraction
            path.move(to: CGPoint(x: x, y: bounds.minY))
            path.line(to: CGPoint(x: x, y: bounds.maxY))

            let y = bounds.height * fraction
            path.move(to: CGPoint(x: bounds.minX, y: y))
            path.line(to: CGPoint(x: bounds.maxX, y: y))
        }

        path.lineWidth = 2.0 / scale
        NSColor.black.withAlphaComponent(0.48).setStroke()
        path.stroke()
        path.lineWidth = 1.0 / scale
        NSColor.white.withAlphaComponent(0.68).setStroke()
        path.stroke()
    }

    private func drawTransparencyCheckerboard(scale: CGFloat) {
        let tile = max(2.0, 12.0 / max(scale, 0.001))
        NSColor(calibratedWhite: 0.20, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        var row = 0
        var y = bounds.minY
        while y < bounds.maxY {
            var column = 0
            var x = bounds.minX
            while x < bounds.maxX {
                if (row + column).isMultiple(of: 2) {
                    NSRect(
                        x: x,
                        y: y,
                        width: min(tile, bounds.maxX - x),
                        height: min(tile, bounds.maxY - y)
                    ).fill()
                }
                column += 1
                x += tile
            }
            row += 1
            y += tile
        }
    }

    private func drawCanvasBorder(scale: CGFloat) {
        let lineWidth = 1.0 / max(scale, 0.001)
        let border = NSBezierPath(rect: bounds.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5))
        border.lineWidth = lineWidth
        NSColor(calibratedWhite: 0.62, alpha: 0.92).setStroke()
        border.stroke()
    }
}

private final class PanoramaViewportScrollView: NSScrollView {
    fileprivate let panoramaDocumentView = PanoramaDocumentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    fileprivate var projectionDragEnabled = true
    fileprivate var minimumRelativeZoom: CGFloat = 0.10
    fileprivate var maximumRelativeZoom: CGFloat = 16.0
    fileprivate var onProjectionDragBegan: @MainActor () -> Void = {}
    fileprivate var onProjectionDragChanged: @MainActor (CGSize, Bool) -> Void = { _, _ in }
    fileprivate var onProjectionDragEnded: @MainActor (CGSize, Bool) -> Void = { _, _ in }

    fileprivate weak var viewportController: PanoramaViewportController? {
        didSet {
            if oldValue !== viewportController {
                oldValue?.detach(from: self)
                viewportController?.attach(to: self)
            }
        }
    }

    private var keyEventMonitor: PanoramaEventMonitorToken?
    private var isConfigured = false

    fileprivate var isSpacePressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: 49)
    }

    fileprivate var currentRelativeZoom: CGFloat {
        guard panoramaDocumentView.image != nil else {
            return 1.0
        }
        return magnification / max(fitMagnification, 0.000_1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeKeyEventMonitor()
        } else {
            installKeyEventMonitorIfNeeded()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = abs(frame.size.width - newSize.width) > 0.5 || abs(frame.size.height - newSize.height) > 0.5
        let preservedState = isConfigured && sizeChanged ? viewportState() : nil
        super.setFrameSize(newSize)
        if let preservedState, panoramaDocumentView.image != nil {
            layoutSubtreeIfNeeded()
            restoreViewportState(preservedState)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            super.scrollWheel(with: event)
            return
        }

        guard panoramaDocumentView.image != nil else {
            return
        }
        let wheelDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard wheelDelta != 0 else {
            return
        }
        let boundedDelta = min(max(wheelDelta, -6.0), 6.0)
        zoom(byRelativeFactor: pow(1.12, boundedDelta), aroundWindowPoint: event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        guard panoramaDocumentView.image != nil else {
            return
        }
        let factor = max(0.05, 1.0 + event.magnification)
        zoom(byRelativeFactor: factor, aroundWindowPoint: event.locationInWindow)
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(currentRelativeZoom - 1.0) <= 0.001 {
            setRelativeZoom(2.0, aroundWindowPoint: event.locationInWindow)
        } else {
            fitImage()
        }
    }

    fileprivate func isDisplayingSameImage(_ image: CGImage?) -> Bool {
        switch (panoramaDocumentView.image, image) {
        case (nil, nil):
            return true
        case let (current?, replacement?):
            return current === replacement
                && current.width == replacement.width
                && current.height == replacement.height
        default:
            return false
        }
    }

    fileprivate func replaceImage(_ image: CGImage?) {
        let hadImage = panoramaDocumentView.image != nil
        let preservedState = hadImage ? viewportState() : nil

        panoramaDocumentView.image = image
        let imageSize = image.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 1, height: 1)
        panoramaDocumentView.frame = NSRect(origin: .zero, size: imageSize)
        panoramaDocumentView.bounds = NSRect(origin: .zero, size: imageSize)
        recalculateMagnificationLimits()

        if let preservedState, image != nil {
            restoreViewportState(preservedState)
        } else if image != nil {
            fitImage()
        } else {
            magnification = 1.0
            reportViewportChange()
        }
    }

    fileprivate func zoom(byRelativeFactor factor: CGFloat, aroundWindowPoint point: CGPoint?) {
        guard factor.isFinite, factor > 0, panoramaDocumentView.image != nil else {
            return
        }
        setRelativeZoom(currentRelativeZoom * factor, aroundWindowPoint: point)
    }

    fileprivate func setRelativeZoom(_ relativeZoom: CGFloat, aroundWindowPoint point: CGPoint?) {
        guard relativeZoom.isFinite, panoramaDocumentView.image != nil else {
            return
        }
        recalculateMagnificationLimits()
        let boundedRelativeZoom = min(max(relativeZoom, minimumRelativeZoom), maximumRelativeZoom)
        let newMagnification = boundedRelativeZoom * fitMagnification
        let anchor = point.map { panoramaDocumentView.convert($0, from: nil) }
            ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(newMagnification, centeredAt: anchor)
        panoramaDocumentView.needsDisplay = true
        reportViewportChange()
    }

    fileprivate func setImagePixelScale(_ scale: CGFloat, aroundWindowPoint point: CGPoint?) {
        guard scale.isFinite, scale > 0, panoramaDocumentView.image != nil else {
            return
        }
        recalculateMagnificationLimits()
        let relative = scale / max(fitMagnification, 0.000_1)
        setRelativeZoom(relative, aroundWindowPoint: point)
    }

    fileprivate func fitImage() {
        guard panoramaDocumentView.image != nil else {
            return
        }
        recalculateMagnificationLimits()
        let imageCenter = CGPoint(x: panoramaDocumentView.bounds.midX, y: panoramaDocumentView.bounds.midY)
        setMagnification(fitMagnification, centeredAt: imageCenter)
        panoramaDocumentView.needsDisplay = true
        reportViewportChange()
    }

    fileprivate func panDocument(byWindowDelta delta: CGSize) {
        guard panoramaDocumentView.image != nil else {
            return
        }
        let scale = max(magnification, 0.000_1)
        var origin = contentView.bounds.origin
        origin.x -= delta.width / scale
        origin.y += delta.height / scale
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private var fitMagnification: CGFloat {
        let imageSize = panoramaDocumentView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else {
            return 1.0
        }
        return max(0.000_1, min(contentSize.width / imageSize.width, contentSize.height / imageSize.height))
    }

    private func configure() {
        guard !isConfigured else {
            return
        }
        isConfigured = true

        drawsBackground = true
        backgroundColor = .black
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .automatic
        usesPredominantAxisScrolling = false
        allowsMagnification = true

        let clipView = PanoramaCenteringClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = .black
        contentView = clipView
        documentView = panoramaDocumentView
        panoramaDocumentView.panoramaScrollView = self
        recalculateMagnificationLimits()
    }

    private func viewportState() -> PanoramaViewportState {
        let size = panoramaDocumentView.bounds.size
        guard size.width > 0, size.height > 0, panoramaDocumentView.image != nil else {
            return PanoramaViewportState(normalizedCenter: CGPoint(x: 0.5, y: 0.5), relativeZoom: 1.0)
        }
        let visibleBounds = contentView.bounds
        return PanoramaViewportState(
            normalizedCenter: CGPoint(
                x: min(max(visibleBounds.midX / size.width, 0.0), 1.0),
                y: min(max(visibleBounds.midY / size.height, 0.0), 1.0)
            ),
            relativeZoom: currentRelativeZoom
        )
    }

    private func restoreViewportState(_ state: PanoramaViewportState) {
        guard panoramaDocumentView.image != nil else {
            return
        }
        recalculateMagnificationLimits()
        let boundedRelativeZoom = min(max(state.relativeZoom, minimumRelativeZoom), maximumRelativeZoom)
        let imageSize = panoramaDocumentView.bounds.size
        let center = CGPoint(
            x: imageSize.width * min(max(state.normalizedCenter.x, 0.0), 1.0),
            y: imageSize.height * min(max(state.normalizedCenter.y, 0.0), 1.0)
        )
        setMagnification(boundedRelativeZoom * fitMagnification, centeredAt: center)
        panoramaDocumentView.needsDisplay = true
        reportViewportChange()
    }

    private func recalculateMagnificationLimits() {
        let fit = fitMagnification
        let newMinimum = max(0.000_1, fit * minimumRelativeZoom)
        let newMaximum = max(newMinimum, fit * maximumRelativeZoom)
        // Keep the NSScrollView invariant valid while moving between images
        // whose fit scales differ by orders of magnitude.
        if newMinimum > maxMagnification {
            maxMagnification = newMaximum
            minMagnification = newMinimum
        } else {
            minMagnification = newMinimum
            maxMagnification = newMaximum
        }
    }

    private func reportViewportChange() {
        viewportController?.viewportDidChange(
            relativeZoom: currentRelativeZoom,
            imagePixelScale: magnification
        )
    }

    private func installKeyEventMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.keyCode == 49,
                  self.window?.firstResponder === self.panoramaDocumentView else {
                return event
            }
            self.panoramaDocumentView.window?.invalidateCursorRects(for: self.panoramaDocumentView)
            // Space is a viewport modifier while the panorama owns focus. Do
            // not also let it activate a SwiftUI button or scroll the page.
            return nil
        }) else {
            return
        }
        keyEventMonitor = PanoramaEventMonitorToken(monitor)
    }

    private func removeKeyEventMonitor() {
        keyEventMonitor = nil
    }
}
