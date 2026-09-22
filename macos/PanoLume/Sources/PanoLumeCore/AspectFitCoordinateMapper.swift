import CoreGraphics

/// Converts between source-image pixels and an aspect-fit view rectangle,
/// including centered letterbox offsets. Control-point editing and tests share
/// this implementation so Retina/view layout cannot silently shift clicks.
public struct AspectFitCoordinateMapper: Equatable, Sendable {
    public var imageSize: CGSize
    public var bounds: CGRect

    public init(imageSize: CGSize, bounds: CGRect) {
        self.imageSize = imageSize
        self.bounds = bounds
    }

    public var imageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    public func imagePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(
            x: min(max((point.x - rect.minX) * imageSize.width / rect.width, 0), max(imageSize.width - 1, 0)),
            y: min(max((point.y - rect.minY) * imageSize.height / rect.height, 0), max(imageSize.height - 1, 0))
        )
    }

    public func viewPoint(fromImagePoint point: CGPoint) -> CGPoint {
        let rect = imageRect
        guard imageSize.width > 0, imageSize.height > 0 else { return rect.origin }
        return CGPoint(
            x: rect.minX + point.x * rect.width / imageSize.width,
            y: rect.minY + point.y * rect.height / imageSize.height
        )
    }
}
