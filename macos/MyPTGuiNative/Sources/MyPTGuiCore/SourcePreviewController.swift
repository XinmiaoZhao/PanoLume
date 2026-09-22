import Combine
import Foundation

private struct SourcePreviewDisplaySignature: Equatable, Sendable {
    var displayStretch: Bool
    var strength: Double
    var blackPercentile: Double
    var whitePercentile: Double
    var gamma: Double

    init(settings: StitchSettings) {
        displayStretch = settings.displayStretch
        strength = settings.stretchStrength
        blackPercentile = settings.stretchBlackPercentile
        whitePercentile = settings.stretchWhitePercentile
        gamma = settings.stretchGamma
    }
}

/// Progressive source-image state shared by the sidebar and Sources page.
/// Native decoding happens in contexts separate from the stitching document;
/// the selected 2400 px previews use a small LRU while only one true
/// full-resolution RGBA buffer is retained.
@MainActor
public final class SourcePreviewController: ObservableObject {
    @Published public private(set) var selectedPixels: PixelBufferInfo?
    @Published public private(set) var selectedPhotoID: UUID?
    @Published public private(set) var selectedIsFullResolution = false
    @Published public private(set) var thumbnailPixels: [UUID: PixelBufferInfo] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var status = "Select a source image."
    @Published public private(set) var errorMessage: String?

    private let previewEngine: NativeEngineBridge?
    private let thumbnailEngine: NativeEngineBridge?
    private var previewCache: [UUID: PixelBufferInfo] = [:]
    private var previewLRU: [UUID] = []
    private var fullResolutionPhotoID: UUID?
    private var fullResolutionPixels: PixelBufferInfo?
    private var activePreviewJobID: UInt64?
    private var activeThumbnailJobID: UInt64?
    private var previewVersion: UInt64 = 0
    private var thumbnailVersion: UInt64 = 0
    private var nextJobID: UInt64 = 1
    private var knownPhotoIDs: [UUID] = []
    private var displaySignature: SourcePreviewDisplaySignature?

    public init() {
        previewEngine = try? NativeEngineBridge()
        thumbnailEngine = try? NativeEngineBridge()
        if previewEngine == nil || thumbnailEngine == nil {
            errorMessage = "A source-preview context could not be created."
        }
    }

    public func synchronize(
        photos: [PhotoAsset],
        selectedPhotoID: UUID?,
        settings: StitchSettings
    ) {
        let signature = SourcePreviewDisplaySignature(settings: settings)
        if displaySignature != signature {
            displaySignature = signature
            previewCache.removeAll(keepingCapacity: false)
            previewLRU.removeAll(keepingCapacity: false)
            thumbnailPixels.removeAll(keepingCapacity: false)
            fullResolutionPhotoID = nil
            fullResolutionPixels = nil
            selectedPixels = nil
            selectedIsFullResolution = false
        }

        let ids = photos.map(\.id)
        if ids != knownPhotoIDs {
            knownPhotoIDs = ids
            thumbnailVersion &+= 1
            if let activeThumbnailJobID {
                thumbnailEngine?.cancel(jobId: activeThumbnailJobID)
            }
            activeThumbnailJobID = nil
            let valid = Set(ids)
            previewCache = previewCache.filter { valid.contains($0.key) }
            previewLRU.removeAll { !valid.contains($0) }
            thumbnailPixels = thumbnailPixels.filter { valid.contains($0.key) }
            if let fullResolutionPhotoID, !valid.contains(fullResolutionPhotoID) {
                self.fullResolutionPhotoID = nil
                fullResolutionPixels = nil
            }
            startMissingThumbnails(photos: photos, settings: settings)
        } else if thumbnailPixels.count < photos.count {
            startMissingThumbnails(photos: photos, settings: settings)
        }

        guard let selectedPhotoID,
              let photo = photos.first(where: { $0.id == selectedPhotoID }) else {
            cancelSelectedLoad()
            self.selectedPhotoID = nil
            selectedPixels = nil
            selectedIsFullResolution = false
            status = photos.isEmpty ? "Add source images to begin." : "Select a source image."
            return
        }
        if self.selectedPhotoID != selectedPhotoID || selectedPixels == nil {
            select(photo: photo, settings: settings)
        }
    }

    public func requestFullResolution(
        photo: PhotoAsset,
        settings: StitchSettings
    ) {
        guard selectedPhotoID == photo.id,
              !selectedIsFullResolution,
              !isLoading else {
            return
        }
        if fullResolutionPhotoID == photo.id, let fullResolutionPixels {
            selectedPixels = fullResolutionPixels
            selectedIsFullResolution = true
            status = "Full resolution · \(fullResolutionPixels.width)×\(fullResolutionPixels.height)"
            return
        }
        fullResolutionPhotoID = nil
        fullResolutionPixels = nil
        startSelectedLoad(photo: photo, fullResolution: true, settings: settings)
    }

    public func cancelSelectedLoad() {
        previewVersion &+= 1
        if let activePreviewJobID {
            previewEngine?.cancel(jobId: activePreviewJobID)
        }
        activePreviewJobID = nil
        isLoading = false
    }

    private func select(photo: PhotoAsset, settings: StitchSettings) {
        cancelSelectedLoad()
        selectedPhotoID = photo.id
        errorMessage = nil
        if fullResolutionPhotoID == photo.id, let fullResolutionPixels {
            selectedPixels = fullResolutionPixels
            selectedIsFullResolution = true
            status = "Full resolution · \(fullResolutionPixels.width)×\(fullResolutionPixels.height)"
            return
        }
        selectedIsFullResolution = false
        fullResolutionPhotoID = nil
        fullResolutionPixels = nil
        if let cached = previewCache[photo.id] {
            touchPreviewCache(photo.id)
            selectedPixels = cached
            status = "Cached preview · \(cached.width)×\(cached.height)"
            return
        }
        selectedPixels = nil
        startSelectedLoad(photo: photo, fullResolution: false, settings: settings)
    }

    private func startSelectedLoad(
        photo: PhotoAsset,
        fullResolution: Bool,
        settings: StitchSettings
    ) {
        guard let previewEngine else {
            errorMessage = "The source-preview engine is unavailable."
            return
        }
        cancelSelectedLoad()
        previewVersion &+= 1
        let version = previewVersion
        let jobID = allocateJobID()
        activePreviewJobID = jobID
        isLoading = true
        errorMessage = nil
        status = fullResolution
            ? "Loading full-resolution source…"
            : "Loading 2400 px source preview…"
        var displaySettings = settings
        displaySettings.previewMaxSide = fullResolution ? 0 : 2400
        displaySettings.rawHalfSize = !fullResolution
        displaySettings.fullInputPreview = fullResolution

        Task.detached(priority: .userInitiated) { [previewEngine] in
            do {
                let loaded = try previewEngine.loadSourcePreview(
                    path: photo.url,
                    maxSide: 2400,
                    fullResolution: fullResolution,
                    settings: displaySettings,
                    jobID: jobID
                ) { event in
                    Task { @MainActor in
                        guard self.previewVersion == version,
                              self.activePreviewJobID == jobID,
                              self.selectedPhotoID == photo.id else { return }
                        self.status = event.stage
                    }
                }
                await MainActor.run {
                    guard self.previewVersion == version,
                          self.activePreviewJobID == jobID,
                          self.selectedPhotoID == photo.id else { return }
                    self.activePreviewJobID = nil
                    self.isLoading = false
                    self.errorMessage = nil
                    if fullResolution {
                        self.fullResolutionPhotoID = photo.id
                        self.fullResolutionPixels = loaded.pixels
                        self.selectedIsFullResolution = true
                        self.status = "Full resolution · \(loaded.pixels.width)×\(loaded.pixels.height)"
                    } else {
                        self.insertPreviewCache(loaded.pixels, for: photo.id)
                        self.selectedIsFullResolution = false
                        self.status = "Preview · \(loaded.pixels.width)×\(loaded.pixels.height)"
                    }
                    self.selectedPixels = loaded.pixels
                }
            } catch {
                await MainActor.run {
                    guard self.previewVersion == version,
                          self.activePreviewJobID == jobID,
                          self.selectedPhotoID == photo.id else { return }
                    self.activePreviewJobID = nil
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    if fullResolution {
                        self.status = "Full-resolution load failed; keeping the cached preview."
                    } else {
                        self.status = "Source preview failed."
                    }
                }
            }
        }
    }

    private func startMissingThumbnails(
        photos: [PhotoAsset],
        settings: StitchSettings
    ) {
        guard let thumbnailEngine else { return }
        let missing = photos.filter { thumbnailPixels[$0.id] == nil }
        guard !missing.isEmpty else { return }
        thumbnailVersion &+= 1
        let version = thumbnailVersion
        if let activeThumbnailJobID {
            thumbnailEngine.cancel(jobId: activeThumbnailJobID)
        }
        let jobs = missing.map { _ in allocateJobID() }
        activeThumbnailJobID = jobs.first
        var thumbnailSettings = settings
        thumbnailSettings.previewMaxSide = 320
        thumbnailSettings.rawHalfSize = true
        thumbnailSettings.fullInputPreview = false

        Task.detached(priority: .utility) { [thumbnailEngine] in
            for (offset, photo) in missing.enumerated() {
                guard !Task.isCancelled else { break }
                let jobID = jobs[offset]
                await MainActor.run {
                    guard self.thumbnailVersion == version else { return }
                    self.activeThumbnailJobID = jobID
                }
                do {
                    let loaded = try thumbnailEngine.loadSourcePreview(
                        path: photo.url,
                        maxSide: 320,
                        fullResolution: false,
                        settings: thumbnailSettings,
                        jobID: jobID,
                        progress: { _ in }
                    )
                    await MainActor.run {
                        guard self.thumbnailVersion == version else { return }
                        self.thumbnailPixels[photo.id] = loaded.pixels
                    }
                } catch {
                    // A thumbnail failure is non-fatal; the selected preview
                    // path reports the actionable decode reason if opened.
                }
            }
            await MainActor.run {
                guard self.thumbnailVersion == version else { return }
                self.activeThumbnailJobID = nil
            }
        }
    }

    private func allocateJobID() -> UInt64 {
        defer { nextJobID &+= 1 }
        return nextJobID
    }

    private func touchPreviewCache(_ id: UUID) {
        previewLRU.removeAll { $0 == id }
        previewLRU.append(id)
    }

    private func insertPreviewCache(_ pixels: PixelBufferInfo, for id: UUID) {
        previewCache[id] = pixels
        touchPreviewCache(id)
        while previewLRU.count > 4 {
            let evicted = previewLRU.removeFirst()
            previewCache.removeValue(forKey: evicted)
        }
    }
}
