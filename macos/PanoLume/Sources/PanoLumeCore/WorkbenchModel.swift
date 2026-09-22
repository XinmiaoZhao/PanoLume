import Combine
import Foundation

/// Monotonic identity for the semantic document state used by asynchronous
/// native operations. Operation-specific versions coalesce work of one kind;
/// this revision additionally prevents a result from an older document/edit
/// state from replacing newer control-point edits.
struct WorkbenchDocumentRevision: Equatable, Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate var value: UInt64
    }

    private(set) var value: UInt64 = 0

    var currentTicket: Ticket {
        Ticket(value: value)
    }

    @discardableResult
    mutating func advance() -> Ticket {
        value &+= 1
        return currentTicket
    }

    func accepts(_ ticket: Ticket) -> Bool {
        ticket.value == value
    }
}

enum ProjectionRequestKind: Equatable, Sendable {
    case drag
    case release
}

/// A single native projection-render lane with latest-wins drag coalescing.
/// Release work is a barrier: once queued or active, lower-quality drag frames
/// cannot supersede it or become publishable after it commits.
struct ProjectionRequestLane<Request: Sendable>: Sendable {
    struct Entry: Sendable {
        let version: UInt64
        let kind: ProjectionRequestKind
        let request: Request
    }

    struct EnqueueOutcome: Sendable {
        let entry: Entry
        let shouldCancelActive: Bool
    }

    private(set) var active: Entry?
    private(set) var pending: Entry?
    private(set) var latestVersion: UInt64 = 0

    var isBusy: Bool {
        active != nil || pending != nil
    }

    var acceptsDrag: Bool {
        active?.kind != .release && pending?.kind != .release
    }

    /// Returns nil only when a release barrier is already queued or running.
    /// Such a drag frame is intentionally dropped without advancing the lane
    /// version, so the release remains eligible to publish its committed frame.
    mutating func enqueue(_ request: Request, kind: ProjectionRequestKind) -> EnqueueOutcome? {
        if kind == .drag,
           active?.kind == .release || pending?.kind == .release {
            return nil
        }

        latestVersion &+= 1
        let entry = Entry(version: latestVersion, kind: kind, request: request)
        pending = entry
        // Drag rendering keeps one active frame and one latest pending frame.
        // Cancelling the active native job for every pointer event starves the
        // renderer under a fast mouse/trackpad stream. A release remains a
        // strict barrier and is the only enqueue that revokes active work.
        return EnqueueOutcome(
            entry: entry,
            shouldCancelActive: kind == .release && active != nil
        )
    }

    mutating func activateNext() -> Entry? {
        guard active == nil, let pending else {
            return nil
        }
        self.pending = nil
        active = pending
        return pending
    }

    func accepts(_ entry: Entry) -> Bool {
        guard active?.version == entry.version else {
            return false
        }
        if pending?.kind == .release {
            return false
        }
        // An active drag frame remains useful even when a newer drag is
        // pending. Publishing it prevents a continuous event stream from
        // withholding every frame until the pointer stops. Release entries
        // still require exact latest-version ownership.
        return entry.kind == .drag || latestVersion == entry.version
    }

    @discardableResult
    mutating func finish(_ entry: Entry) -> Bool {
        guard active?.version == entry.version else {
            return false
        }
        active = nil
        return true
    }

    /// Revokes publication rights and queued work while retaining the active
    /// entry until its detached native call has really exited.
    mutating func invalidate() {
        latestVersion &+= 1
        pending = nil
    }
}

private struct ProjectionRenderRequest: Sendable {
    var documentTicket: WorkbenchDocumentRevision.Ticket
    var pose: PoseAdjustment
    var quality: RenderQuality
    var result: StitchResult
    var settings: StitchSettings
}

/// Pure policy for projection-render settings. Keeping this separate from the
/// scheduler makes the quality tiers deterministic and directly testable
/// without constructing a native engine context.
enum ProjectionRenderPolicy {
    static func settings(
        for quality: RenderQuality,
        imageCount: Int,
        base: StitchSettings
    ) -> StitchSettings {
        var resolved = base
        if quality == .dragPreview {
            let limits: (inputSide: Int, outputPixels: Int, outputSide: Int)
            switch imageCount {
            case ...3:
                limits = (640, 900_000, 2_560)
            case 4:
                limits = (480, 900_000, 1_920)
            default:
                limits = (280, 320_000, 960)
            }
            resolved.previewMaxSide = cappedPositive(resolved.previewMaxSide, at: limits.inputSide)
            resolved.maxOutputPixels = cappedPositive(resolved.maxOutputPixels, at: limits.outputPixels)
            resolved.maxOutputSide = cappedPositive(resolved.maxOutputSide, at: limits.outputSide)
            resolved.fullInputPreview = false
            resolved.blendMode = "fast"
            resolved.previewRendererBackend = "metal_fast"
        } else if resolved.blendMode == "multiband" {
            // Metal does not implement multiband. Being explicit here keeps the
            // UI status and engine diagnostics honest instead of reporting a
            // renderer fallback for an unsupported combination.
            resolved.previewRendererBackend = "cpu"
        } else if resolved.previewRendererBackend == "auto" {
            resolved.previewRendererBackend = "metal_quality"
        }
        return resolved
    }

    private static func cappedPositive(_ userLimit: Int, at dragLimit: Int) -> Int {
        userLimit > 0 ? min(userLimit, dragLimit) : dragLimit
    }
}

/// Production export is intentionally stricter than candidate-certification
/// tooling. The GUI must remain fail-closed whenever the running binary no
/// longer matches a promoted certification, even if its current preview is
/// otherwise geometrically valid.
enum ProductionExportCertificationPolicy {
    static func unavailableReason(
        nativeAlgorithmParity: Bool?,
        parityGate: ParityGateResult
    ) -> String? {
        guard nativeAlgorithmParity == true else {
            return "This development build is locked for production export until its exact engine and Metal identity passes release certification."
        }
        guard parityGate.passed else {
            return "Production export is blocked by the parity gate: \(parityGate.reason)"
        }
        return nil
    }
}

@MainActor
public final class NativeWorkbenchModel: ObservableObject {
    @Published public private(set) var photos: [PhotoAsset] = []
    @Published public var selectedPhotoID: UUID?
    @Published public var settings = StitchSettings()
    @Published public var exportSettings = ExportSettings()
    @Published public private(set) var result: StitchResult?
    @Published public private(set) var previewPixels: PixelBufferInfo?
    @Published public private(set) var previewFrameVersion: UInt64 = 0
    @Published public private(set) var progress: ProgressEvent?
    @Published public private(set) var jobState: RenderJobState = .idle
    @Published public private(set) var capabilities: EngineCapabilities?
    @Published public private(set) var parityGate = ParityGate.evaluate(result: nil)
    @Published public private(set) var lastExportURL: URL?
    @Published public private(set) var lastExportProfile: JSONValue?
    @Published public private(set) var projectionPose: PoseAdjustment = .zero
    @Published public private(set) var projectionVisualFeedback: ProjectionVisualFeedback = .zero
    @Published public private(set) var projectionRenderStatus = ""
    @Published public private(set) var astroRefinementState: AstroRefinementState = .notRequired
    @Published public private(set) var astroRefinementStatus = ""
    @Published public private(set) var manualPointRefinementRecords: [AstroManualPointRecord] = []
    @Published public private(set) var controlPointsDirty = false
    @Published public private(set) var controlPointImagePixels: [Int: PixelBufferInfo] = [:]
    @Published public private(set) var controlPointImagesLoading = false
    @Published public private(set) var controlPointImageLoadError: String?
    @Published public private(set) var projectionDragUnavailableReason = "Run a successful camera preview before dragging projection."

    private let engine: NativeEngineBridge
    private var projectionDragStartPose: PoseAdjustment = .zero
    private var projectionPresentedPose: PoseAdjustment = .zero
    private var projectionRequestLane = ProjectionRequestLane<ProjectionRenderRequest>()
    private let projectionDragSensitivityRadians = 0.0015
    private var nextNativeJobID: UInt64 = 1
    private var activeLoadJobID: UInt64?
    private var activePreviewJobID: UInt64?
    private var activeProjectionJobID: UInt64?
    private var activeExportJobID: UInt64?
    private var activeAstroRefinementJobID: UInt64?
    private var activeAstroApplyJobID: UInt64?
    private var astroRefinementEngine: NativeEngineBridge?
    private var astroRefinementVersion = 0
    private var controlPointImageCache: [Int: PixelBufferInfo] = [:]
    private var controlPointImageLRU: [Int] = []
    private var controlPointImageLoadVersion: UInt64 = 0
    private var documentRevision = WorkbenchDocumentRevision()
    private var loadOperationVersion = 0
    private var previewOperationVersion = 0
    private var exportOperationVersion = 0

    public init(engine: NativeEngineBridge? = nil) {
        let resolvedEngine: NativeEngineBridge
        do {
            resolvedEngine = try engine ?? NativeEngineBridge()
        } catch {
            resolvedEngine = try! NativeEngineBridge()
            jobState = .failed(error.localizedDescription)
        }
        self.engine = resolvedEngine
        do {
            capabilities = try NativeEngineBridge.capabilities()
        } catch {
            jobState = .failed(error.localizedDescription)
        }
    }

    /// Cancels native work and invalidates every completion callback that could
    /// still target the current document.  The C++ context serializes work, so
    /// a newly queued request cannot race its predecessor's handle storage.
    public func cancelActiveWork() {
        invalidateNativeOperations()
        progress = nil
        projectionVisualFeedback = .zero
        projectionRenderStatus = ""
        astroRefinementState = .notRequired
        astroRefinementStatus = ""
        manualPointRefinementRecords = []
        jobState = .idle
    }

    private func allocateNativeJobID() -> UInt64 {
        defer { nextNativeJobID &+= 1 }
        return nextNativeJobID
    }

    private func cancelNativeJob(_ jobID: UInt64?) {
        guard let jobID else {
            return
        }
        engine.cancel(jobId: jobID)
    }

    private func cancelAstroRefinement() {
        if let jobID = activeAstroRefinementJobID {
            astroRefinementEngine?.cancel(jobId: jobID)
        }
        if let jobID = activeAstroApplyJobID {
            engine.cancel(jobId: jobID)
        }
        activeAstroRefinementJobID = nil
        activeAstroApplyJobID = nil
        astroRefinementEngine = nil
        astroRefinementVersion &+= 1
    }

    private func invalidateNativeOperations() {
        cancelNativeJob(activeLoadJobID)
        cancelNativeJob(activePreviewJobID)
        cancelNativeJob(activeProjectionJobID)
        cancelNativeJob(activeExportJobID)
        cancelAstroRefinement()
        activeLoadJobID = nil
        activePreviewJobID = nil
        activeProjectionJobID = nil
        activeExportJobID = nil
        loadOperationVersion &+= 1
        previewOperationVersion &+= 1
        exportOperationVersion &+= 1
        projectionRequestLane.invalidate()
    }

    /// Starts a semantic document change and invalidates every native operation
    /// that could publish a result derived from the previous revision. The
    /// active projection request object stays referenced until its detached task
    /// really finishes; only its acceptance ticket and native job are revoked.
    @discardableResult
    private func beginDocumentChange() -> (
        ticket: WorkbenchDocumentRevision.Ticket,
        cancelledWork: Bool
    ) {
        let cancelledWork = activePreviewJobID != nil
            || activeProjectionJobID != nil
            || activeExportJobID != nil
            || activeAstroRefinementJobID != nil
            || activeAstroApplyJobID != nil
            || projectionRequestLane.isBusy

        cancelNativeJob(activePreviewJobID)
        cancelNativeJob(activeProjectionJobID)
        cancelNativeJob(activeExportJobID)
        cancelAstroRefinement()
        activePreviewJobID = nil
        activeProjectionJobID = nil
        activeExportJobID = nil
        previewOperationVersion &+= 1
        projectionRequestLane.invalidate()
        exportOperationVersion &+= 1
        progress = nil
        projectionRenderStatus = ""

        return (documentRevision.advance(), cancelledWork)
    }

    private func acceptsDocumentTicket(_ ticket: WorkbenchDocumentRevision.Ticket) -> Bool {
        documentRevision.accepts(ticket)
    }

    public func addPhotos(_ urls: [URL]) {
        let existing = Set(photos.map(\.url))
        let additions = urls
            .filter { !existing.contains($0) }
            .map { PhotoAsset(url: $0) }
        photos.append(contentsOf: additions)
        if selectedPhotoID == nil {
            selectedPhotoID = photos.first?.id
        }
        clearResult()
        if !additions.isEmpty {
            loadNativeImages(for: additions.map(\.url))
        }
    }

    public func removePhotos(at offsets: IndexSet) {
        photos.removeOffsets(offsets)
        if let selectedPhotoID,
           !photos.contains(where: { $0.id == selectedPhotoID }) {
            self.selectedPhotoID = photos.first?.id
        }
        clearResult()
    }

    public func clearPhotos() {
        photos.removeAll()
        selectedPhotoID = nil
        clearResult()
    }

    public func runPreview() {
        guard photos.count >= 2 else {
            jobState = .failed("Load at least two photos before running preview.")
            return
        }
        let documentTicket = beginDocumentChange().ticket
        projectionVisualFeedback = .zero
        let operationVersion = previewOperationVersion
        let jobID = allocateNativeJobID()
        activePreviewJobID = jobID
        let urls = photos.map(\.url)
        let handles = photos.compactMap(\.nativeHandle)
        let settings = effectivePreviewSettings()
        jobState = .running("Starting preview", 0.0)

        Task.detached { [engine] in
            do {
                let response: EngineOperationResponse
                if handles.count == urls.count && !settings.fullInputPreview {
                    response = try engine.runPreviewFromLoadedImages(
                        imageHandles: handles,
                        paths: urls,
                        settings: settings,
                        jobID: jobID
                    ) { event in
                        Task { @MainActor in
                            guard self.acceptsDocumentTicket(documentTicket),
                                  self.previewOperationVersion == operationVersion,
                                  self.activePreviewJobID == jobID else {
                                return
                            }
                            self.progress = event
                            self.jobState = .running(event.stage, event.fraction)
                        }
                    }
                } else {
                    response = try engine.runPreview(paths: urls, settings: settings, jobID: jobID) { event in
                        Task { @MainActor in
                            guard self.acceptsDocumentTicket(documentTicket),
                                  self.previewOperationVersion == operationVersion,
                                  self.activePreviewJobID == jobID else {
                                return
                            }
                            self.progress = event
                            self.jobState = .running(event.stage, event.fraction)
                        }
                    }
                }
                let previewPixels: PixelBufferInfo?
                if let result = response.result {
                    var displaySettings = settings
                    if Self.usesGeneralPhotoDisplay(result) {
                        displaySettings.displayStretch = false
                    }
                    previewPixels = try? engine.copyResultRGBA(resultHandle: result.handle, settings: displaySettings)
                } else {
                    previewPixels = nil
                }
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.previewOperationVersion == operationVersion,
                          self.activePreviewJobID == jobID else {
                        return
                    }
                    self.activePreviewJobID = nil
                    guard let rendered = response.result else {
                        self.jobState = .failed("Preview completed without a result; the previous document was preserved.")
                        return
                    }
                    self.resetControlPointImageCache()
                    self.result = rendered
                    self.replacePreviewPixels(previewPixels)
                    self.parityGate = ParityGate.evaluate(result: rendered)
                    self.projectionPose = .zero
                    self.projectionPresentedPose = .zero
                    self.projectionVisualFeedback = .zero
                    self.projectionRenderStatus = ""
                    self.controlPointsDirty = false
                    self.refreshProjectionDragAvailability()
                    let previewStatus = rendered.diagnostics["preview_status"]?.stringValue
                    if previewStatus == "draft_camera_preview" || previewStatus == "unverified_camera_draft" {
                        self.astroRefinementState = .draftPendingFullResolution
                        self.astroRefinementStatus = previewStatus == "unverified_camera_draft"
                            ? "Unverified Camera draft — recovering full-resolution star identities"
                            : "Draft camera preview — validating full-resolution stars"
                        self.jobState = .running(self.astroRefinementStatus, 0.0)
                        self.startAstroRefinement(
                            draft: rendered,
                            settings: settings,
                            documentTicket: documentTicket,
                            keepControlPointsDirtyUntilPass: false
                        )
                    } else if rendered.diagnostics["geometry_gate"]?["passed"]?.boolValue == false {
                        let reason = rendered.diagnostics["geometry_gate"]?["reason"]?.stringValue
                            ?? "The generated geometry did not pass its quality gate."
                        self.jobState = .failed(reason)
                    } else {
                        self.jobState = .completed(response.message)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.previewOperationVersion == operationVersion,
                          self.activePreviewJobID == jobID else {
                        return
                    }
                    self.activePreviewJobID = nil
                    self.jobState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func loadNativeImages(for urls: [URL]) {
        cancelNativeJob(activeLoadJobID)
        activeLoadJobID = nil
        loadOperationVersion &+= 1
        let operationVersion = loadOperationVersion
        let jobID = allocateNativeJobID()
        activeLoadJobID = jobID
        let settings = effectivePreviewSettings()
        jobState = .running("Loading image metadata", 0.0)
        Task.detached { [engine] in
            do {
                let response = try engine.loadImages(paths: urls, settings: settings, jobID: jobID) { event in
                    Task { @MainActor in
                        guard self.loadOperationVersion == operationVersion,
                              self.activeLoadJobID == jobID else {
                            return
                        }
                        self.progress = event
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                await MainActor.run {
                    guard self.loadOperationVersion == operationVersion,
                          self.activeLoadJobID == jobID else {
                        return
                    }
                    self.activeLoadJobID = nil
                    self.applyLoadedImages(response.images)
                    self.jobState = .completed(response.message)
                }
            } catch {
                await MainActor.run {
                    guard self.loadOperationVersion == operationVersion,
                          self.activeLoadJobID == jobID else {
                        return
                    }
                    self.activeLoadJobID = nil
                    self.jobState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func applyLoadedImages(_ loadedImages: [NativeImageInfo]) {
        let byPath = Dictionary(uniqueKeysWithValues: loadedImages.map { ($0.path, $0) })
        for index in photos.indices {
            guard let info = byPath[photos[index].url.path] else {
                continue
            }
            photos[index].nativeHandle = info.handle
            photos[index].width = info.width
            photos[index].height = info.height
            photos[index].originalWidth = info.originalWidth ?? info.width
            photos[index].originalHeight = info.originalHeight ?? info.height
            photos[index].loadStatus = info.status
            photos[index].unsupportedReason = info.unsupportedReason
            photos[index].cameraMake = info.cameraMake
            photos[index].cameraModel = info.cameraModel
            photos[index].lensName = info.lensName
            photos[index].focalLengthMM = info.focalLengthMM
            photos[index].apertureFNumber = info.apertureFNumber
        }
    }

    private static func manualRecordsAfterPairRefit(
        submitted: [ControlPoint],
        accepted: [ControlPoint],
        globalFailure: String
    ) -> [AstroManualPointRecord] {
        let manualSubmitted = submitted.filter(\.isManual)
        let manualAccepted = accepted.filter(\.isManual)
        var used = Set<Int>()
        func coordinateDistanceSquared(_ lhs: ControlPoint, _ rhs: ControlPoint) -> Double? {
            let sameOrder = lhs.imageAIndex == rhs.imageAIndex && lhs.imageBIndex == rhs.imageBIndex
            let reverseOrder = lhs.imageAIndex == rhs.imageBIndex && lhs.imageBIndex == rhs.imageAIndex
            guard sameOrder || reverseOrder else { return nil }
            let rhsXA = sameOrder ? rhs.xA : rhs.xB
            let rhsYA = sameOrder ? rhs.yA : rhs.yB
            let rhsXB = sameOrder ? rhs.xB : rhs.xA
            let rhsYB = sameOrder ? rhs.yB : rhs.yA
            return pow(lhs.xA - rhsXA, 2)
                + pow(lhs.yA - rhsYA, 2)
                + pow(lhs.xB - rhsXB, 2)
                + pow(lhs.yB - rhsYB, 2)
        }
        return manualSubmitted.enumerated().map { index, point in
            let match = manualAccepted.indices
                .filter { !used.contains($0) }
                .compactMap { acceptedIndex -> (Int, Double)? in
                    guard let distance = coordinateDistanceSquared(point, manualAccepted[acceptedIndex]) else {
                        return nil
                    }
                    return (acceptedIndex, distance)
                }
                .min { $0.1 < $1.1 }
            if let match, match.1 <= 0.01 {
                used.insert(match.0)
                return AstroManualPointRecord(
                    index: index,
                    accepted: true,
                    error: manualAccepted[match.0].error,
                    reason: "Accepted by robust pair refit; global Camera gate failed: \(globalFailure)"
                )
            }
            return AstroManualPointRecord(
                index: index,
                accepted: false,
                error: nil,
                reason: "Rejected as an invalid, duplicate, or robust pair-refit outlier"
            )
        }
    }

    nonisolated private static func manualRecordsAfterFullRefinement(
        submitted: [ControlPoint],
        pairRefitAccepted: [ControlPoint],
        refinementRecords: [AstroManualPointRecord]
    ) -> [AstroManualPointRecord] {
        let manualSubmitted = submitted.filter(\.isManual)
        let manualAccepted = pairRefitAccepted.filter(\.isManual)
        var used = Set<Int>()
        func coordinateDistanceSquared(_ lhs: ControlPoint, _ rhs: ControlPoint) -> Double? {
            let sameOrder = lhs.imageAIndex == rhs.imageAIndex && lhs.imageBIndex == rhs.imageBIndex
            let reverseOrder = lhs.imageAIndex == rhs.imageBIndex && lhs.imageBIndex == rhs.imageAIndex
            guard sameOrder || reverseOrder else { return nil }
            let rhsXA = sameOrder ? rhs.xA : rhs.xB
            let rhsYA = sameOrder ? rhs.yA : rhs.yB
            let rhsXB = sameOrder ? rhs.xB : rhs.xA
            let rhsYB = sameOrder ? rhs.yB : rhs.yA
            return pow(lhs.xA - rhsXA, 2)
                + pow(lhs.yA - rhsYA, 2)
                + pow(lhs.xB - rhsXB, 2)
                + pow(lhs.yB - rhsYB, 2)
        }
        return manualSubmitted.enumerated().map { inputIndex, point in
            let match = manualAccepted.indices
                .filter { !used.contains($0) }
                .compactMap { acceptedIndex -> (Int, Double)? in
                    guard let distance = coordinateDistanceSquared(point, manualAccepted[acceptedIndex]) else {
                        return nil
                    }
                    return (acceptedIndex, distance)
                }
                .min { $0.1 < $1.1 }
            guard let match, match.1 <= 0.01 else {
                return AstroManualPointRecord(
                    index: inputIndex,
                    accepted: false,
                    error: nil,
                    reason: "Rejected as an invalid, duplicate, or robust pair-refit outlier"
                )
            }
            used.insert(match.0)
            guard refinementRecords.indices.contains(match.0) else {
                return AstroManualPointRecord(
                    index: inputIndex,
                    accepted: false,
                    error: nil,
                    reason: "Accepted by pair refit but missing from full-resolution manual-point accounting"
                )
            }
            let refined = refinementRecords[match.0]
            return AstroManualPointRecord(
                index: inputIndex,
                accepted: refined.accepted,
                error: refined.error,
                reason: refined.reason
            )
        }
    }

    public func rerenderFromControlPoints() {
        guard let result else {
            jobState = .failed("Run preview before re-optimizing control points.")
            return
        }
        let documentTicket = beginDocumentChange().ticket
        let operationVersion = previewOperationVersion
        let jobID = allocateNativeJobID()
        activePreviewJobID = jobID
        let settings = settings
        let preservedPose = projectionPose
        jobState = .running("Starting re-optimization", 0.0)
        Task.detached { [engine] in
            do {
                let response = try engine.rerenderFromControlPoints(result: result, settings: settings, jobID: jobID) { event in
                    Task { @MainActor in
                        guard self.acceptsDocumentTicket(documentTicket),
                              self.previewOperationVersion == operationVersion,
                              self.activePreviewJobID == jobID else {
                            return
                        }
                        self.progress = event
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                let previewPixels: PixelBufferInfo?
                if let result = response.result {
                    var displaySettings = settings
                    if Self.usesGeneralPhotoDisplay(result) {
                        displaySettings.displayStretch = false
                    }
                    previewPixels = try? engine.copyResultRGBA(resultHandle: result.handle, settings: displaySettings)
                } else {
                    previewPixels = nil
                }
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.previewOperationVersion == operationVersion,
                          self.activePreviewJobID == jobID else {
                        return
                    }
                    self.activePreviewJobID = nil
                    guard let rendered = response.result else {
                        self.jobState = .failed("Re-optimize completed without a result; edited control points were preserved.")
                        return
                    }
                    self.result = rendered
                    self.replacePreviewPixels(previewPixels)
                    self.parityGate = ParityGate.evaluate(result: rendered)
                    self.projectionPresentedPose = .zero
                    self.updateProjectionVisualFeedback()
                    if !response.success {
                        self.controlPointsDirty = true
                        self.astroRefinementState = .failed
                        self.astroRefinementStatus = response.message
                        self.manualPointRefinementRecords = Self.manualRecordsAfterPairRefit(
                            submitted: result.controlPoints,
                            accepted: rendered.controlPoints,
                            globalFailure: response.message
                        )
                        self.refreshProjectionDragAvailability()
                        self.jobState = .failed(response.message)
                        return
                    }
                    let rerenderStatus = rendered.diagnostics["preview_status"]?.stringValue
                    let isDraft = rerenderStatus == "draft_camera_preview"
                        || rerenderStatus == "unverified_camera_draft"
                    self.controlPointsDirty = isDraft
                    self.refreshProjectionDragAvailability()
                    if isDraft {
                        self.astroRefinementState = .draftPendingFullResolution
                        self.astroRefinementStatus = "Edited draft ready — validating full-resolution stars"
                        self.jobState = .running(self.astroRefinementStatus, 0.0)
                        self.startAstroRefinement(
                            draft: rendered,
                            settings: settings,
                            documentTicket: documentTicket,
                            keepControlPointsDirtyUntilPass: true,
                            submittedControlPoints: result.controlPoints
                        )
                    } else {
                        self.controlPointsDirty = false
                        self.jobState = .completed(response.message)
                    }
                    if !isDraft, !preservedPose.isZero, self.canDragProjection {
                        self.projectionPose = preservedPose
                        self.renderProjectionPreview(pose: preservedPose, quality: .committedPreview)
                    } else if !self.canDragProjection {
                        self.projectionPose = .zero
                        self.projectionPresentedPose = .zero
                        self.projectionVisualFeedback = .zero
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.previewOperationVersion == operationVersion,
                          self.activePreviewJobID == jobID else {
                        return
                    }
                    self.activePreviewJobID = nil
                    self.jobState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func startAstroRefinement(
        draft: StitchResult,
        settings: StitchSettings,
        documentTicket: WorkbenchDocumentRevision.Ticket,
        keepControlPointsDirtyUntilPass: Bool,
        submittedControlPoints: [ControlPoint]? = nil
    ) {
        cancelAstroRefinement()
        let refinementEngine: NativeEngineBridge
        do {
            refinementEngine = try NativeEngineBridge()
        } catch {
            astroRefinementState = .failed
            astroRefinementStatus = error.localizedDescription
            controlPointsDirty = keepControlPointsDirtyUntilPass
            jobState = .failed(error.localizedDescription)
            return
        }
        astroRefinementVersion &+= 1
        let version = astroRefinementVersion
        let refinementJobID = allocateNativeJobID()
        let applyJobID = allocateNativeJobID()
        activeAstroRefinementJobID = refinementJobID
        activeAstroApplyJobID = applyJobID
        astroRefinementEngine = refinementEngine
        astroRefinementState = .refiningFullResolution
        manualPointRefinementRecords = []

        Task.detached { [engine, refinementEngine] in
            do {
                let refinement = try refinementEngine.refineAstroFullResolution(
                    result: draft,
                    settings: settings,
                    jobID: refinementJobID
                ) { event in
                    Task { @MainActor in
                        guard self.acceptsDocumentTicket(documentTicket),
                              self.astroRefinementVersion == version,
                              self.activeAstroRefinementJobID == refinementJobID else {
                            return
                        }
                        self.progress = event
                        self.astroRefinementStatus = event.stage
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                let manualRecords = submittedControlPoints.map {
                    Self.manualRecordsAfterFullRefinement(
                        submitted: $0,
                        pairRefitAccepted: draft.controlPoints,
                        refinementRecords: refinement.manualPoints
                    )
                } ?? refinement.manualPoints

                guard refinement.passed else {
                    await MainActor.run {
                        guard self.acceptsDocumentTicket(documentTicket),
                              self.astroRefinementVersion == version,
                              self.activeAstroRefinementJobID == refinementJobID else {
                            return
                        }
                        self.activeAstroRefinementJobID = nil
                        self.activeAstroApplyJobID = nil
                        self.astroRefinementEngine = nil
                        self.astroRefinementState = .failed
                        self.astroRefinementStatus = refinement.message
                        self.manualPointRefinementRecords = manualRecords
                        self.controlPointsDirty = keepControlPointsDirtyUntilPass
                        if var failedDraft = self.result,
                           failedDraft.handle == draft.handle {
                            failedDraft.astroRefinement = refinement.astroRefinement
                            if case .object(var diagnostics) = failedDraft.diagnostics,
                               let encoded = try? JSONEncoder().encode(refinement.astroRefinement),
                               let value = try? JSONDecoder().decode(JSONValue.self, from: encoded) {
                                diagnostics["astro_refinement"] = value
                                failedDraft.diagnostics = .object(diagnostics)
                            }
                            self.result = failedDraft
                        }
                        self.refreshProjectionDragAvailability()
                        self.jobState = .failed(refinement.message)
                    }
                    return
                }

                let applied = try engine.applyAstroRefinement(
                    to: draft,
                    refinement: refinement,
                    jobID: applyJobID
                ) { event in
                    Task { @MainActor in
                        guard self.acceptsDocumentTicket(documentTicket),
                              self.astroRefinementVersion == version,
                              self.activeAstroApplyJobID == applyJobID else {
                            return
                        }
                        self.progress = event
                        self.astroRefinementStatus = event.stage
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                let pixels: PixelBufferInfo?
                if let refinedResult = applied.result {
                    pixels = try? engine.copyResultRGBA(resultHandle: refinedResult.handle, settings: settings)
                } else {
                    pixels = nil
                }
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.astroRefinementVersion == version,
                          self.activeAstroApplyJobID == applyJobID,
                          let refinedResult = applied.result else {
                        return
                    }
                    self.activeAstroRefinementJobID = nil
                    self.activeAstroApplyJobID = nil
                    self.astroRefinementEngine = nil
                    self.result = refinedResult
                    self.replacePreviewPixels(pixels)
                    self.parityGate = ParityGate.evaluate(result: refinedResult)
                    self.astroRefinementState = .passed
                    self.astroRefinementStatus = refinement.message
                    self.manualPointRefinementRecords = manualRecords
                    self.controlPointsDirty = false
                    self.refreshProjectionDragAvailability()
                    self.jobState = .completed(applied.message)
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.astroRefinementVersion == version else {
                        return
                    }
                    self.activeAstroRefinementJobID = nil
                    self.activeAstroApplyJobID = nil
                    self.astroRefinementEngine = nil
                    self.astroRefinementState = error.localizedDescription.localizedCaseInsensitiveContains("cancel")
                        ? .cancelled
                        : .failed
                    self.astroRefinementStatus = error.localizedDescription
                    self.controlPointsDirty = keepControlPointsDirtyUntilPass
                    self.refreshProjectionDragAvailability()
                    self.jobState = .failed(error.localizedDescription)
                }
            }
        }
    }

    public func deleteControlPoints(at offsets: IndexSet) {
        guard var result else { return }
        let previousCount = result.controlPoints.count
        result.controlPoints.removeOffsets(offsets)
        guard result.controlPoints.count != previousCount else { return }
        self.result = result
        markControlPointsDirty(message: "Control points edited; re-optimize before export.")
    }

    public func deleteControlPoint(id: UUID) {
        guard var result,
              let index = result.controlPoints.firstIndex(where: { $0.id == id }) else {
            return
        }
        result.controlPoints.remove(at: index)
        self.result = result
        markControlPointsDirty(message: "Control point deleted; re-optimize before export.")
    }

    public func addControlPoint(
        imageAIndex: Int,
        imageBIndex: Int,
        pointA: CGPoint,
        pointB: CGPoint
    ) {
        guard var result,
              imageAIndex != imageBIndex,
              result.sourceImages.indices.contains(imageAIndex),
              result.sourceImages.indices.contains(imageBIndex) else {
            jobState = .failed("Choose two valid source images before adding a control point.")
            return
        }
        let firstIsCanonical = imageAIndex < imageBIndex
        let low = min(imageAIndex, imageBIndex)
        let high = max(imageAIndex, imageBIndex)
        let lowSource = result.sourceImages[low]
        let highSource = result.sourceImages[high]
        let lowPoint = clampedControlPoint(
            firstIsCanonical ? pointA : pointB,
            width: lowSource.width,
            height: lowSource.height
        )
        let highPoint = clampedControlPoint(
            firstIsCanonical ? pointB : pointA,
            width: highSource.width,
            height: highSource.height
        )
        result.controlPoints.append(ControlPoint(
            imageAIndex: low,
            imageBIndex: high,
            xA: lowPoint.x,
            yA: lowPoint.y,
            xB: highPoint.x,
            yB: highPoint.y,
            error: 0,
            isManual: true
        ))
        self.result = result
        markControlPointsDirty(message: "Manual control point added; re-optimize before export.")
    }

    public func clearControlPoints(imageAIndex: Int, imageBIndex: Int) {
        guard var result,
              imageAIndex != imageBIndex,
              result.sourceImages.indices.contains(imageAIndex),
              result.sourceImages.indices.contains(imageBIndex) else {
            return
        }
        let low = min(imageAIndex, imageBIndex)
        let high = max(imageAIndex, imageBIndex)
        let previousCount = result.controlPoints.count
        result.controlPoints.removeAll { point in
            min(point.imageAIndex, point.imageBIndex) == low
                && max(point.imageAIndex, point.imageBIndex) == high
        }
        guard result.controlPoints.count != previousCount else { return }
        self.result = result
        markControlPointsDirty(message: "Control points for images \(low + 1) and \(high + 1) were cleared.")
    }

    public var canReoptimizeControlPoints: Bool {
        guard controlPointsDirty, let result else { return false }
        if case .running = jobState { return false }
        let geometry = result.diagnostics["geometry"]?.stringValue ?? ""
        if geometry == "camera" {
            return result.controlPoints.count >= max(8, result.sourceImages.count * 4)
        }
        return result.controlPoints.count >= 4
    }

    public func loadControlPointImages(imageAIndex: Int, imageBIndex: Int) {
        guard let result,
              imageAIndex != imageBIndex,
              result.sourceImages.indices.contains(imageAIndex),
              result.sourceImages.indices.contains(imageBIndex) else {
            controlPointImageLoadVersion &+= 1
            controlPointImagesLoading = false
            controlPointImageLoadError = "The selected source-image pair is unavailable."
            return
        }
        // Every selection receives a version, including an all-cache-hit
        // selection. Otherwise an older in-flight pair can finish later and
        // replace the cache-hit pair that is currently visible.
        controlPointImageLoadVersion &+= 1
        let version = controlPointImageLoadVersion
        let requestedIndices = [imageAIndex, imageBIndex]
        var available: [Int: PixelBufferInfo] = [:]
        for index in requestedIndices {
            if let pixels = controlPointImageCache[index] {
                available[index] = pixels
                touchControlPointCache(index)
            }
        }
        controlPointImagePixels = available
        controlPointImageLoadError = nil
        if available.count == requestedIndices.count {
            controlPointImagesLoading = false
            return
        }

        let handles: [(Int, String)] = requestedIndices.compactMap { index in
            result.sourceImages[index].handle.map { (index, $0) }
        }
        guard handles.count == requestedIndices.count else {
            controlPointImagesLoading = false
            controlPointImageLoadError = "Source-image handles are unavailable. Run Preview again."
            return
        }

        let resultHandle = result.handle
        var settings = effectivePreviewSettings()
        if Self.usesGeneralPhotoDisplay(result) {
            settings.displayStretch = false
        }
        let missing = handles.filter { available[$0.0] == nil }
        controlPointImagesLoading = true
        Task.detached { [engine] in
            do {
                var loaded: [Int: PixelBufferInfo] = [:]
                for (index, handle) in missing {
                    let isStillRequested = await MainActor.run {
                        self.controlPointImageLoadVersion == version
                            && self.result?.handle == resultHandle
                    }
                    guard isStillRequested else { return }
                    if let pixels = try engine.copyImageRGBA(imageHandle: handle, settings: settings) {
                        loaded[index] = pixels
                    }
                }
                await MainActor.run {
                    guard self.controlPointImageLoadVersion == version,
                          self.result?.handle == resultHandle else { return }
                    for (index, pixels) in loaded {
                        self.insertControlPointCache(pixels, index: index)
                    }
                    self.controlPointImagePixels = Dictionary(
                        uniqueKeysWithValues: requestedIndices.compactMap { index in
                            self.controlPointImageCache[index].map { (index, $0) }
                        }
                    )
                    self.controlPointImagesLoading = false
                    if self.controlPointImagePixels.count != requestedIndices.count {
                        self.controlPointImageLoadError = "One or both source images did not return display pixels."
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.controlPointImageLoadVersion == version,
                          self.result?.handle == resultHandle else { return }
                    self.controlPointImagesLoading = false
                    self.controlPointImageLoadError = error.localizedDescription
                }
            }
        }
    }

    public func startProjectionDrag() {
        guard settings.projectionDragEnabled, canDragProjection else {
            refreshProjectionDragAvailability()
            return
        }
        projectionDragStartPose = projectionPose
    }

    public func updateProjectionDrag(translation: CGSize, rollOnly: Bool) {
        guard settings.projectionDragEnabled, canDragProjection else {
            refreshProjectionDragAvailability()
            return
        }
        // Pointer events delivered after mouse-up must not move the presented
        // pose away from the release geometry that is already queued/active.
        guard projectionRequestLane.acceptsDrag else { return }
        let pose = poseFromDragTranslation(translation, rollOnly: rollOnly)
        projectionPose = pose
        updateProjectionVisualFeedback()
        renderProjectionPreview(pose: pose, quality: .dragPreview)
    }

    public func finishProjectionDrag(translation: CGSize, rollOnly: Bool) {
        guard settings.projectionDragEnabled, canDragProjection else {
            refreshProjectionDragAvailability()
            return
        }
        let pose = poseFromDragTranslation(translation, rollOnly: rollOnly)
        projectionPose = pose
        updateProjectionVisualFeedback()
        renderProjectionPreview(
            pose: pose,
            quality: settings.blendAfterProjectionDrag ? .committedPreview : .geometryCommit
        )
    }

    public func resetProjectionPose() {
        guard canDragProjection else {
            refreshProjectionDragAvailability()
            return
        }
        projectionPose = .zero
        projectionDragStartPose = .zero
        updateProjectionVisualFeedback()
        renderProjectionPreview(pose: .zero, quality: .committedPreview)
    }

    public func renderProjectionPreview(pose: PoseAdjustment, quality: RenderQuality = .dragPreview) {
        guard let result else {
            return
        }
        guard canDragProjection else {
            refreshProjectionDragAvailability()
            jobState = .failed(projectionDragUnavailableReason)
            return
        }
        guard quality != .dragPreview || projectionRequestLane.acceptsDrag else {
            return
        }
        let documentTicket: WorkbenchDocumentRevision.Ticket
        if quality == .dragPreview {
            documentTicket = documentRevision.currentTicket
        } else {
            // Committed and geometry-only renders mutate the export geometry.
            // They therefore supersede preview/re-optimize/export work based on
            // the previous document state.
            documentTicket = beginDocumentChange().ticket
        }
        projectionPose = pose
        updateProjectionVisualFeedback()
        let request = ProjectionRenderRequest(
            documentTicket: documentTicket,
            pose: pose,
            quality: quality,
            result: result,
            settings: projectionSettings(for: quality, imageCount: result.sourceImages.count)
        )

        // The lane assigns a version at enqueue time. A release replaces any
        // queued drag frame and becomes a barrier against later low-quality
        // frames until its commit has finished.
        let kind: ProjectionRequestKind = quality == .dragPreview ? .drag : .release
        guard let enqueue = projectionRequestLane.enqueue(request, kind: kind) else {
            return
        }
        projectionRenderStatus = statusWhileRendering(request)
        if enqueue.shouldCancelActive {
            cancelNativeJob(activeProjectionJobID)
        } else {
            dispatchNextProjectionRequest()
        }
    }

    public func exportFullResolution(to outputURL: URL) {
        // The UI normally disables export while these jobs run. Keep the model
        // guard as well so a shortcut/programmatic call cannot replace a real
        // running status with a spurious export failure.
        guard activePreviewJobID == nil,
              activeProjectionJobID == nil,
              !projectionRequestLane.isBusy,
              activeExportJobID == nil else {
            return
        }
        guard let result else {
            jobState = .failed("Run preview before exporting full resolution.")
            return
        }
        guard canExportFullResolution else {
            jobState = .failed(fullResolutionExportUnavailableReason)
            return
        }
        let documentTicket = documentRevision.currentTicket
        var exportSettings = exportSettings
        if exportSettings.applyPreviewStretch {
            exportSettings.stretchStrength = settings.stretchStrength
            exportSettings.stretchBlackPercentile = settings.stretchBlackPercentile
            exportSettings.stretchWhitePercentile = settings.stretchWhitePercentile
            exportSettings.stretchGamma = settings.stretchGamma
        } else {
            exportSettings.stretchStrength = 0.0
        }
        cancelNativeJob(activeExportJobID)
        activeExportJobID = nil
        exportOperationVersion &+= 1
        let operationVersion = exportOperationVersion
        let jobID = allocateNativeJobID()
        activeExportJobID = jobID
        jobState = .running("Starting export", 0.0)
        lastExportURL = nil
        lastExportProfile = nil
        Task.detached { [engine] in
            do {
                let response = try engine.exportFullResolution(result: result, outputURL: outputURL, settings: exportSettings, jobID: jobID) { event in
                    Task { @MainActor in
                        guard self.acceptsDocumentTicket(documentTicket),
                              self.exportOperationVersion == operationVersion,
                              self.activeExportJobID == jobID else {
                            return
                        }
                        self.progress = event
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.exportOperationVersion == operationVersion,
                          self.activeExportJobID == jobID else {
                        return
                    }
                    self.activeExportJobID = nil
                    self.lastExportURL = outputURL
                    self.lastExportProfile = response.result?.diagnostics["export_profile"]
                    self.jobState = .completed(response.message)
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsDocumentTicket(documentTicket),
                          self.exportOperationVersion == operationVersion,
                          self.activeExportJobID == jobID else {
                        return
                    }
                    self.activeExportJobID = nil
                    var message = error.localizedDescription
                    if exportSettings.rendererBackend != "fullres_camera_strip_tiff_diagnostic" {
                        message += " Check the renderer selection, output path, and dependency report."
                    }
                    self.jobState = .failed(message)
                }
            }
        }
    }

    private func clearResult() {
        invalidateNativeOperations()
        engine.resetProjectionSession()
        documentRevision.advance()
        resetControlPointImageCache()
        result = nil
        replacePreviewPixels(nil)
        progress = nil
        parityGate = ParityGate.evaluate(result: nil)
        lastExportURL = nil
        lastExportProfile = nil
        projectionPose = .zero
        projectionDragStartPose = .zero
        projectionPresentedPose = .zero
        projectionVisualFeedback = .zero
        projectionRenderStatus = ""
        astroRefinementState = .notRequired
        astroRefinementStatus = ""
        manualPointRefinementRecords = []
        projectionDragUnavailableReason = "Run a successful camera preview before dragging projection."
        controlPointsDirty = false
        jobState = .idle
    }

    public var canDragProjection: Bool {
        ProjectionGeometryPolicy.canDrag(
            result: result,
            controlPointsDirty: controlPointsDirty,
            refinementState: astroRefinementState,
            refinementActive: activeAstroRefinementJobID != nil || activeAstroApplyJobID != nil
        )
    }

    public var canExportFullResolution: Bool {
        fullResolutionExportUnavailableReason.isEmpty
    }

    public var fullResolutionExportUnavailableReason: String {
        guard let result else {
            return "Run a successful camera preview before exporting full resolution."
        }
        if let certificationReason = ProductionExportCertificationPolicy.unavailableReason(
            nativeAlgorithmParity: capabilities?.nativeAlgorithmParity,
            parityGate: parityGate
        ) {
            return certificationReason
        }
        if activePreviewJobID != nil {
            return "Wait for the current preview or re-optimize operation to finish before exporting."
        }
        if activeProjectionJobID != nil || projectionRequestLane.isBusy {
            return "Wait for the current projection render to finish before exporting."
        }
        if activeExportJobID != nil {
            return "A full-resolution export is already running."
        }
        if controlPointsDirty {
            return "Control points were edited. Re-optimize before exporting full resolution."
        }
        let status = result.diagnostics["preview_status"]?.stringValue ?? "unknown"
        let geometry = result.diagnostics["geometry"]?.stringValue ?? "unknown"
        let geometryGatePassed = result.geometryQualityGatePassed == true
        if result.projectionGeometryState != .verifiedCamera
            || !geometryGatePassed
            || status != "camera_projection_preview"
            || geometry != "camera" {
            return "Full-resolution camera export requires camera_projection_preview; current status is \(status), geometry is \(geometry)."
        }
        if result.astroRefinement?.state != .passed
            || result.astroRefinement?.qualityGatePassed != true {
            return "Full-resolution export requires a passing independent full-resolution astro refinement."
        }
        if result.cameraParams.isEmpty || result.cameraParams.count != result.sourceImages.count {
            return "Full-resolution camera export requires matching camera parameters for every source image."
        }
        return ""
    }

    private func refreshProjectionDragAvailability() {
        guard let result else {
            projectionDragUnavailableReason = "Run a successful camera preview before dragging projection."
            return
        }
        let status = result.diagnostics["preview_status"]?.stringValue ?? "unknown"
        let isFailedUnverifiedDraft = (result.projectionGeometryState == .unverifiedCameraDraft
                || status == "draft_camera_preview"
                || status == "unverified_camera_draft")
            && astroRefinementState == .failed
        if controlPointsDirty && !isFailedUnverifiedDraft {
            projectionDragUnavailableReason = "Re-optimize edited control points before changing projection geometry."
            return
        }
        if result.cameraParams.isEmpty {
            let reason = result.diagnostics["camera_model"]?["reason"]?.stringValue
                ?? result.diagnostics["preview_failure_reason"]?.stringValue
                ?? "Camera parameters are not available for this preview."
            projectionDragUnavailableReason = reason
            return
        }
        if activeAstroRefinementJobID != nil || activeAstroApplyJobID != nil {
            projectionDragUnavailableReason = "Full-resolution star refinement must finish before projection drag."
            return
        }
        if status == "camera_projection_preview" && !controlPointsDirty {
            projectionDragUnavailableReason = ""
            return
        }
        if isFailedUnverifiedDraft {
            projectionDragUnavailableReason = ""
            return
        }
        projectionDragUnavailableReason = "Projection drag requires a renderable Camera draft; current status is \(status)."
    }

    private func effectivePreviewSettings() -> StitchSettings {
        var resolved = settings
        if resolved.fullInputPreview {
            resolved.previewMaxSide = 0
            resolved.rawHalfSize = false
        }
        return resolved
    }

    nonisolated private static func usesGeneralPhotoDisplay(_ result: StitchResult) -> Bool {
        switch result.diagnostics["alignment_family"]?.stringValue {
        case "sift":
            return true
        default:
            return false
        }
    }

    private func markControlPointsDirty(message: String) {
        let change = beginDocumentChange()
        controlPointsDirty = true
        parityGate = ParityGateResult(
            passed: false,
            reason: "Control points changed. Re-optimize before relying on this geometry.",
            missing: []
        )
        refreshProjectionDragAvailability()
        if change.cancelledWork {
            jobState = .completed(
                "\(message) In-progress preview, projection, or export work was cancelled before it could replace this edit."
            )
        } else {
            // `completed` describes the synchronous edit, not a native render.
            jobState = .completed(message)
        }
    }

    private func clampedControlPoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), CGFloat(max(width - 1, 0))),
            y: min(max(point.y, 0), CGFloat(max(height - 1, 0)))
        )
    }

    private func resetControlPointImageCache() {
        controlPointImageLoadVersion &+= 1
        controlPointImageCache.removeAll(keepingCapacity: false)
        controlPointImageLRU.removeAll(keepingCapacity: false)
        controlPointImagePixels = [:]
        controlPointImagesLoading = false
        controlPointImageLoadError = nil
    }

    private func touchControlPointCache(_ index: Int) {
        controlPointImageLRU.removeAll { $0 == index }
        controlPointImageLRU.append(index)
    }

    private func insertControlPointCache(_ pixels: PixelBufferInfo, index: Int) {
        controlPointImageCache[index] = pixels
        touchControlPointCache(index)
        while controlPointImageLRU.count > 4 {
            let evicted = controlPointImageLRU.removeFirst()
            controlPointImageCache.removeValue(forKey: evicted)
        }
    }

    private func replacePreviewPixels(_ pixels: PixelBufferInfo?) {
        previewPixels = pixels
        previewFrameVersion &+= 1
    }

    private func poseFromDragTranslation(_ translation: CGSize, rollOnly: Bool) -> PoseAdjustment {
        let radiansToDegrees = 180.0 / Double.pi
        let dx = Double(translation.width)
        let dy = Double(translation.height)
        if rollOnly {
            return PoseAdjustment(
                pitchDegrees: projectionDragStartPose.pitchDegrees,
                yawDegrees: projectionDragStartPose.yawDegrees,
                rollDegrees: projectionDragStartPose.rollDegrees + dx * projectionDragSensitivityRadians * radiansToDegrees
            )
        }
        return PoseAdjustment(
            pitchDegrees: projectionDragStartPose.pitchDegrees + dy * projectionDragSensitivityRadians * radiansToDegrees,
            yawDegrees: projectionDragStartPose.yawDegrees - dx * projectionDragSensitivityRadians * radiansToDegrees,
            rollDegrees: projectionDragStartPose.rollDegrees
        )
    }

    private func projectionSettings(for quality: RenderQuality, imageCount: Int) -> StitchSettings {
        ProjectionRenderPolicy.settings(for: quality, imageCount: imageCount, base: settings)
    }

    private func dispatchNextProjectionRequest() {
        guard let entry = projectionRequestLane.activateNext() else {
            return
        }
        let request = entry.request
        let jobID = allocateNativeJobID()
        activeProjectionJobID = jobID

        if request.quality == .dragPreview {
            dispatchDragProjectionRequest(entry, jobID: jobID)
        } else {
            dispatchCommittedProjectionRequest(entry, jobID: jobID)
        }
    }

    private func dispatchDragProjectionRequest(
        _ entry: ProjectionRequestLane<ProjectionRenderRequest>.Entry,
        jobID: UInt64
    ) {
        let request = entry.request
        Task.detached { [engine] in
            do {
                let pixels = try engine.renderProjectionDragPreviewPixels(
                    result: request.result,
                    poseAdjustment: request.pose,
                    settings: request.settings,
                    jobID: jobID
                ) { event in
                    Task { @MainActor in
                        guard self.isLatestProjectionRequest(entry, jobID: jobID) else {
                            return
                        }
                        self.progress = event
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                await MainActor.run {
                    if self.isLatestProjectionRequest(entry, jobID: jobID) {
                        if let pixels {
                            self.replacePreviewPixels(pixels)
                            self.projectionPresentedPose = request.pose
                            self.updateProjectionVisualFeedback()
                            self.projectionRenderStatus = "Fast preview · Metal Fast or CPU fallback"
                            self.jobState = .completed("Projection drag preview rendered.")
                        } else {
                            self.jobState = .failed("Projection drag preview did not return pixels. Run preview again and confirm camera geometry is valid.")
                        }
                    }
                    self.finishProjectionRequest(entry, jobID: jobID)
                }
            } catch {
                await MainActor.run {
                    if self.isLatestProjectionRequest(entry, jobID: jobID) {
                        self.jobState = .failed(error.localizedDescription)
                    }
                    self.finishProjectionRequest(entry, jobID: jobID)
                }
            }
        }
    }

    private func dispatchCommittedProjectionRequest(
        _ entry: ProjectionRequestLane<ProjectionRenderRequest>.Entry,
        jobID: UInt64
    ) {
        let request = entry.request
        Task.detached { [engine] in
            do {
                let response = try engine.renderProjectionPreview(
                    result: request.result,
                    poseAdjustment: request.pose,
                    quality: request.quality,
                    settings: request.settings,
                    jobID: jobID
                ) { event in
                    Task { @MainActor in
                        guard self.isLatestProjectionRequest(entry, jobID: jobID) else {
                            return
                        }
                        self.progress = event
                        self.jobState = .running(event.stage, event.fraction)
                    }
                }
                let pixels: PixelBufferInfo?
                // A result-to-RGBA conversion can be sizeable for the committed
                // frame and also holds the serialized native context lock. Skip
                // that work when pointer input has already superseded this
                // request; its pixels would be discarded on the main actor.
                let isStillLatest = await MainActor.run {
                    self.isLatestProjectionRequest(entry, jobID: jobID)
                }
                if isStillLatest,
                   request.quality != .geometryCommit,
                   let rendered = response.result {
                    pixels = try? engine.copyResultRGBA(
                        resultHandle: rendered.handle,
                        settings: request.settings
                    )
                } else {
                    pixels = nil
                }
                await MainActor.run {
                    if self.isLatestProjectionRequest(entry, jobID: jobID) {
                        if let rendered = response.result {
                            self.result = rendered
                            self.parityGate = ParityGate.evaluate(result: rendered)
                            self.refreshProjectionDragAvailability()
                        }
                        if let pixels {
                            self.replacePreviewPixels(pixels)
                            self.projectionPresentedPose = request.pose
                            self.updateProjectionVisualFeedback()
                        }
                        if response.result == nil {
                            self.projectionRenderStatus = "Projection render returned no result"
                            self.jobState = .failed("Projection render completed without a result.")
                        } else if request.quality == .committedPreview, pixels == nil {
                            self.projectionRenderStatus = "Geometry saved · blended preview pixels unavailable"
                            self.jobState = .failed("Projection geometry was saved, but the blended preview could not be displayed.")
                        } else {
                            self.projectionRenderStatus = self.statusAfterRendering(request, result: response.result)
                            self.jobState = .completed(response.message)
                        }
                    }
                    self.finishProjectionRequest(entry, jobID: jobID)
                }
            } catch {
                await MainActor.run {
                    if self.isLatestProjectionRequest(entry, jobID: jobID) {
                        self.jobState = .failed(error.localizedDescription)
                    }
                    self.finishProjectionRequest(entry, jobID: jobID)
                }
            }
        }
    }

    private func isLatestProjectionRequest(
        _ entry: ProjectionRequestLane<ProjectionRenderRequest>.Entry,
        jobID: UInt64
    ) -> Bool {
        acceptsDocumentTicket(entry.request.documentTicket)
            && projectionRequestLane.accepts(entry)
            && activeProjectionJobID == jobID
    }

    private func finishProjectionRequest(
        _ entry: ProjectionRequestLane<ProjectionRenderRequest>.Entry,
        jobID: UInt64
    ) {
        guard projectionRequestLane.finish(entry) else {
            return
        }
        if activeProjectionJobID == jobID {
            activeProjectionJobID = nil
        }
        dispatchNextProjectionRequest()
    }

    private func updateProjectionVisualFeedback() {
        // A 2-D transform of the finished raster is not a projection preview:
        // it detaches pixels from the coverage border and lies about crop
        // geometry. Until a native/Metal spherical reprojection frame arrives,
        // keep the last truthful projected frame in place.
        projectionVisualFeedback = .zero
    }

    private func statusWhileRendering(_ request: ProjectionRenderRequest) -> String {
        switch request.quality {
        case .dragPreview:
            return "Rendering Fast preview · Metal Fast with CPU fallback"
        case .geometryCommit:
            return "Saving geometry · keeping the Fast preview frame"
        case .committedPreview:
            if request.settings.blendMode == "multiband" {
                return "Blending after drag · CPU Multiband"
            }
            return "Blending after drag · \(rendererTitle(request.settings.previewRendererBackend))"
        case .export:
            return "Committing projection for export"
        }
    }

    private func statusAfterRendering(_ request: ProjectionRenderRequest, result: StitchResult?) -> String {
        if request.quality == .geometryCommit {
            return "Geometry saved · Fast preview retained until the next blend"
        }
        let renderer = result?.diagnostics["preview_renderer_used"]?.stringValue
            ?? request.settings.previewRendererBackend
        let fallback = result?.diagnostics["preview_renderer_fallback"]?.boolValue == true
        let suffix = fallback ? " · CPU fallback" : ""
        if request.settings.blendMode == "multiband" {
            return "Blended after drag · CPU Multiband"
        }
        return "Blended after drag · \(rendererTitle(renderer))\(suffix)"
    }

    private func rendererTitle(_ renderer: String) -> String {
        switch renderer {
        case "metal_quality":
            return "Metal Quality"
        case "metal_fast":
            return "Metal Fast"
        case "cpu", "opencv_cpu_camera_projection":
            return "CPU"
        default:
            return renderer.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private extension Array {
    mutating func removeOffsets(_ offsets: IndexSet) {
        for index in offsets.sorted(by: >) where indices.contains(index) {
            remove(at: index)
        }
    }
}
