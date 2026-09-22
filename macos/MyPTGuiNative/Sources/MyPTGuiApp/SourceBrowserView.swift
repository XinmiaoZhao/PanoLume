import AppKit
import CoreGraphics
import MyPTGuiCore
import SwiftUI

struct SourceBrowserView: View {
    @ObservedObject var model: NativeWorkbenchModel
    @ObservedObject var controller: SourcePreviewController
    @StateObject private var viewportController = PanoramaViewportController()
    @State private var displayedImage: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color.black.opacity(0.82)
                if displayedImage != nil {
                    PanoramaViewport(
                        cgImage: displayedImage,
                        projectionDragEnabled: false,
                        minimumRelativeZoom: 0.05,
                        maximumRelativeZoom: 32,
                        controller: viewportController
                    )
                } else if controller.isLoading {
                    ProgressView(controller.status)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ContentUnavailableView(
                        "No source selected",
                        systemImage: "photo",
                        description: Text(controller.status)
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) {
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
            }

            Divider()
            thumbnailRail
                .frame(height: 104)
        }
        .onAppear {
            synchronize()
            displayedImage = Self.cgImage(from: controller.selectedPixels)
        }
        .onDisappear {
            controller.cancelSelectedLoad()
        }
        .onChange(of: model.photos) { _, _ in synchronize() }
        .onChange(of: model.selectedPhotoID) { _, _ in synchronize() }
        .onChange(of: model.settings) { _, _ in synchronize() }
        .onChange(of: viewportController.imagePixelScale) { _, scale in
            guard scale >= 0.85 else { return }
            requestFullResolution()
        }
        .onReceive(controller.$selectedPixels) { pixels in
            displayedImage = Self.cgImage(from: pixels)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    viewportController.fit()
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    viewportController.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button {
                    viewportController.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Slider(
                    value: Binding(
                        get: { Double(viewportController.relativeZoom) },
                        set: { viewportController.setRelativeZoom(CGFloat($0)) }
                    ),
                    in: 0.05...32
                )
                .frame(width: 140)
                Text("\(Int((viewportController.imagePixelScale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
                Spacer()
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if selectedPhoto != nil {
                    if controller.selectedIsFullResolution {
                        Label("Full resolution", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Load Full Resolution") {
                            requestFullResolution()
                        }
                        .disabled(controller.isLoading || controller.selectedPixels == nil)
                    }
                }
            }

            HStack(spacing: 8) {
                if let photo = selectedPhoto {
                    Text(photo.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    Text("\(photo.originalWidth)×\(photo.originalHeight) original")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var thumbnailRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.photos) { photo in
                    Button {
                        model.selectedPhotoID = photo.id
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                if let image = Self.cgImage(from: controller.thumbnailPixels[photo.id]) {
                                    Image(decorative: image, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 92, height: 66)
                            .clipped()
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(
                                        model.selectedPhotoID == photo.id ? Color.accentColor : Color.secondary.opacity(0.35),
                                        lineWidth: model.selectedPhotoID == photo.id ? 3 : 1
                                    )
                            }
                            Text(photo.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 92)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(photo.displayName)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private var selectedPhoto: PhotoAsset? {
        guard let id = model.selectedPhotoID else { return nil }
        return model.photos.first { $0.id == id }
    }

    private func synchronize() {
        if model.selectedPhotoID == nil {
            model.selectedPhotoID = model.photos.first?.id
        }
        controller.synchronize(
            photos: model.photos,
            selectedPhotoID: model.selectedPhotoID,
            settings: model.settings
        )
    }

    private func requestFullResolution() {
        guard let photo = selectedPhoto else { return }
        controller.requestFullResolution(photo: photo, settings: model.settings)
    }

    private static func cgImage(from pixels: PixelBufferInfo?) -> CGImage? {
        guard let pixels,
              pixels.width > 0,
              pixels.height > 0,
              let provider = CGDataProvider(data: pixels.data as CFData) else {
            return nil
        }
        return CGImage(
            width: pixels.width,
            height: pixels.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixels.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
