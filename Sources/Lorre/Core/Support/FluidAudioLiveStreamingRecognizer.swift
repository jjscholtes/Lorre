import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

#if canImport(AVFoundation) && canImport(FluidAudio)
private final class LiveSerialProgressDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func submit(
        _ update: ProcessingUpdate,
        to onProgress: @escaping @Sendable (ProcessingUpdate) async -> Void
    ) {
        lock.lock()
        let previous = tail
        let task = Task {
            await previous?.value
            await onProgress(update)
        }
        tail = task
        lock.unlock()
    }

    func drain() async {
        await currentTail()?.value
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

final class LiveTranscriptionPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension LiveTranscriptionPreset {
    var modelRepository: Repo {
        switch self {
        case .lowLatency: .parakeetEou160
        case .balanced: .parakeetEou320
        case .highAccuracy: .parakeetEou1280
        case .nemotronBalanced: .nemotronStreaming560
        case .nemotronHighAccuracy: .nemotronStreaming1120
        case .dutchUnified: .nemotronUnified
        }
    }

    var eouSettings: (chunkSize: StreamingChunkSize, debounceMs: Int)? {
        switch self {
        case .lowLatency: (.ms160, 1120)
        case .balanced: (.ms320, 1280)
        case .highAccuracy: (.ms1280, 1920)
        default: nil
        }
    }
}

actor FluidAudioLiveStreamingRecognizer {
    private enum StreamingUpdate {
        case listening
        case endOfUtterance
        case cumulative(String)
    }

    private enum StreamingASRManager {
        case parakeet(StreamingEouAsrManager)
        case nemotron(StreamingNemotronAsrManager)
        case unified(StreamingUnifiedAsrManager)

        func process(audioBuffer: AVAudioPCMBuffer) async throws -> StreamingUpdate {
            switch self {
            case .parakeet(let manager):
                _ = try await manager.process(audioBuffer: audioBuffer)
                return await manager.eouDetected ? .endOfUtterance : .listening
            case .nemotron(let manager):
                _ = try await manager.process(audioBuffer: audioBuffer)
                return .listening
            case .unified(let manager):
                try await manager.appendAudio(audioBuffer)
                try await manager.processBufferedAudio()
                guard await !manager.consumeTokenTimings().isEmpty else { return .listening }
                return .cumulative(await manager.getPartialTranscript())
            }
        }

        func finish() async throws -> String {
            switch self {
            case .parakeet(let manager):
                return try await manager.finish()
            case .nemotron(let manager):
                return try await manager.finish()
            case .unified(let manager):
                return try await manager.finish()
            }
        }

        func reset() async throws {
            switch self {
            case .parakeet(let manager):
                await manager.reset()
            case .nemotron(let manager):
                await manager.reset()
            case .unified(let manager):
                try await manager.reset()
            }
        }
    }

    private struct LiveSpeakerAssignment: Sendable, Equatable {
        let speakerID: String
        let displayName: String
        let distance: Float
    }

    private let audioConverter = AudioConverter()
    private let speakerEnrollmentService: any SpeakerEnrollmentService
    private let knownSpeakerReferenceAudioProvider: (@Sendable (KnownSpeaker) async -> URL?)?

    private var streamingManager: StreamingASRManager?
    private var vadManager: VadManager?
    private var requestedPreset: LiveTranscriptionPreset
    private var preparedPreset: LiveTranscriptionPreset?
    private var preview = LiveTranscriptPreview()
    private var previewHandler: (@Sendable (LiveTranscriptPreview) -> Void)?
    private var isStreaming = false
    private let punctuationCommitLayer = PunctuationCommitLayer(debounceTimeout: 1.8, commitOnTimeout: true)

    private var knownSpeakers: [KnownSpeaker] = []
    private var sortformerModels: SortformerModels?
    private var sortformerDiarizer: SortformerDiarizer?
    private var sortformerNeedsReprime = true
    private var speakerAssignmentsBySlot: [Int: LiveSpeakerAssignment] = [:]
    private var activeSpeakerSlot: Int?
    private var recentSlotSamples: [Float] = []
    private var lastSpeakerHintLookupAt: Date?

    private var vadStreamState: VadStreamState?
    private var vadRemainderSamples: [Float] = []
    private var gateSpeechSeenForCurrentUtterance = false

    init(
        speakerEnrollmentService: any SpeakerEnrollmentService = FluidAudioSpeakerEnrollmentService(),
        knownSpeakerReferenceAudioProvider: (@Sendable (KnownSpeaker) async -> URL?)? = nil,
        preset: LiveTranscriptionPreset = .balanced
    ) {
        self.speakerEnrollmentService = speakerEnrollmentService
        self.knownSpeakerReferenceAudioProvider = knownSpeakerReferenceAudioProvider
        self.requestedPreset = preset
    }

    static func livePreviewModelFolderName(for preset: LiveTranscriptionPreset) -> String {
        preset.modelRepository.folderName
    }

    static func livePreviewDebounceMilliseconds(for preset: LiveTranscriptionPreset) -> Int {
        preset.eouSettings?.debounceMs ?? 0
    }

    static func normalizedLiveSpeakerActivity(_ activity: Float) -> Float {
        max(0, min(1, activity))
    }

    func setPreset(_ preset: LiveTranscriptionPreset) async {
        guard requestedPreset != preset else { return }
        requestedPreset = preset
        guard preparedPreset != preset else { return }
        if isStreaming {
            return
        }
        streamingManager = nil
        preparedPreset = nil
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        knownSpeakers = speakers.sorted { $0.safeDisplayName.localizedCaseInsensitiveCompare($1.safeDisplayName) == .orderedAscending }
        sortformerNeedsReprime = !knownSpeakers.isEmpty
        sortformerDiarizer = nil
        resetSpeakerHintTracking()
        if !isStreaming {
            clearSpeakerHintIfNeeded()
        }
    }

    func prepareModels(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        try await ensureManagersPrepared(onProgress: onProgress)
    }

    func prepareModels() async throws {
        try await prepareModels(onProgress: nil)
    }

    func start(onPreview: @escaping @Sendable (LiveTranscriptPreview) -> Void) async throws {
        try await ensureManagersPrepared(onProgress: nil)
        try await streamingManager?.reset()
        previewHandler = onPreview
        preview = LiveTranscriptPreview(
            confirmedText: "",
            partialText: "",
            isFinalizing: false,
            errorMessage: nil,
            activeSpeakerID: nil,
            activeSpeakerDisplayName: nil,
            activeSpeakerConfidence: nil,
            updatedAt: Date()
        )
        isStreaming = true
        vadRemainderSamples.removeAll(keepingCapacity: true)
        gateSpeechSeenForCurrentUtterance = false
        resetSpeakerHintTracking()
        if let vadManager {
            vadStreamState = await vadManager.makeStreamState()
        } else {
            vadStreamState = nil
        }
        await punctuationCommitLayer.setUpdateCallback { [weak self] update in
            Task { await self?.handleCommitLayerUpdate(update) }
        }
        await punctuationCommitLayer.reset()
        emitPreview()
    }

    func ingest(_ bufferBox: LiveTranscriptionPCMBufferBox) async {
        guard isStreaming else { return }
        guard let streamingManager else { return }

        do {
            let samples = try audioConverter.resampleBuffer(bufferBox.buffer)
            try await updateLiveSpeakerState(with: samples)

            if !(try await shouldFeedToAsr(samples)) {
                return
            }

            switch try await streamingManager.process(audioBuffer: bufferBox.buffer) {
            case .listening:
                break
            case .endOfUtterance:
                try await finalizeDetectedUtterance(using: streamingManager)
            case .cumulative(let text):
                guard text != preview.partialText else { return }
                preview.partialText = text
                preview.updatedAt = Date()
                emitPreview()
            }
        } catch is CancellationError {
            return
        } catch {
            isStreaming = false
            gateSpeechSeenForCurrentUtterance = false
            vadRemainderSamples.removeAll(keepingCapacity: false)
            resetSpeakerHintTracking()
            preview.errorMessage = "Live transcript error: \(error.localizedDescription)"
            preview.isFinalizing = false
            preview.updatedAt = Date()
            emitPreview()
        }
    }

    @discardableResult
    func finish() async throws -> LiveTranscriptPreview {
        preview.isFinalizing = true
        preview.updatedAt = Date()
        emitPreview()

        defer {
            isStreaming = false
            previewHandler = nil
            gateSpeechSeenForCurrentUtterance = false
            vadRemainderSamples.removeAll(keepingCapacity: false)
            resetSpeakerHintTracking()
            clearSpeakerHintIfNeeded()
            if !knownSpeakers.isEmpty {
                sortformerNeedsReprime = true
                sortformerDiarizer = nil
            }
        }

        guard let streamingManager else {
            preview.isFinalizing = false
            preview.updatedAt = Date()
            emitPreview()
            return preview
        }

        do {
            let finalChunk = try await streamingManager.finish()
            let trimmedFinalChunk = finalChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .unified = streamingManager {
                // Unified returns the entire recording, including text already previewed.
                preview.confirmedText = trimmedFinalChunk
                preview.partialText = ""
            } else {
                if !trimmedFinalChunk.isEmpty {
                    _ = await punctuationCommitLayer.processPartialText(trimmedFinalChunk)
                }
                let update = await punctuationCommitLayer.processEOU()
                applyCommitLayerUpdate(update, at: Date())
            }
            preview.isFinalizing = false
            preview.errorMessage = nil
            try await streamingManager.reset()
            if let vadManager {
                vadStreamState = await vadManager.makeStreamState()
            } else {
                vadStreamState = nil
            }
            emitPreview()
            return preview
        } catch {
            preview.isFinalizing = false
            preview.errorMessage = error.localizedDescription
            preview.updatedAt = Date()
            emitPreview()
            throw error
        }
    }

    func cancel() async {
        isStreaming = false
        previewHandler = nil
        vadRemainderSamples.removeAll(keepingCapacity: false)
        gateSpeechSeenForCurrentUtterance = false
        resetSpeakerHintTracking()
        clearSpeakerHintIfNeeded()
        try? await streamingManager?.reset()
        await punctuationCommitLayer.reset()
        if let vadManager {
            vadStreamState = await vadManager.makeStreamState()
        } else {
            vadStreamState = nil
        }
        if !knownSpeakers.isEmpty {
            sortformerNeedsReprime = true
            sortformerDiarizer = nil
        }
        preview = LiveTranscriptPreview()
    }

    func latestPreview() -> LiveTranscriptPreview {
        preview
    }

    private func ensureManagersPrepared(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if !isStreaming, let preparedPreset, preparedPreset != requestedPreset {
            streamingManager = nil
            self.preparedPreset = nil
        }

        let needsSpeakerHints = !knownSpeakers.isEmpty && knownSpeakerReferenceAudioProvider != nil
        let livePreviewReady = streamingManager != nil && vadManager != nil
        let speakerHintReady = !needsSpeakerHints || (sortformerDiarizer != nil && !sortformerNeedsReprime)

        if livePreviewReady, speakerHintReady {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Live preview ready",
                        detail: needsSpeakerHints
                            ? "Streaming ASR, VAD, and live speaker hints are ready."
                            : "Streaming ASR and VAD are ready."
                    )
                )
            }
            return
        }

        let selectedPreset = preparedPreset ?? requestedPreset

        if streamingManager == nil {
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live preview",
                        detail: "Checking \(selectedPreset.label) streaming models…",
                        fraction: 0.02
                    )
                )
            }

            let progressDispatcher = LiveSerialProgressDispatcher()
            let manager = try await makeStreamingManager(for: selectedPreset) { progress in
                guard let onProgress else { return }
                let update = FluidAudioProgressSupport.makeUpdate(
                    phase: .preparing,
                    component: .livePreview,
                    label: "Preparing live preview",
                    progress: progress
                )
                let scaled = FluidAudioProgressSupport.scale(update, into: 0.0...0.52)
                progressDispatcher.submit(scaled, to: onProgress)
            }
            await progressDispatcher.drain()
            try Task.checkCancellation()
            guard requestedPreset == selectedPreset else { throw CancellationError() }
            streamingManager = manager
            preparedPreset = selectedPreset
        }

        if vadManager == nil {
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .vad,
                        label: "Preparing live VAD",
                        detail: "Loading VAD for live speech gating…",
                        fraction: 0.58
                    )
                )
            }
            let progressDispatcher = LiveSerialProgressDispatcher()
            vadManager = try await VadManager(
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .vad,
                        label: "Preparing live VAD",
                        progress: progress
                    )
                    let scaled = FluidAudioProgressSupport.scale(update, into: 0.46...0.76)
                    progressDispatcher.submit(scaled, to: onProgress)
                }
            )
            await progressDispatcher.drain()
        }

        if let vadManager, vadStreamState == nil {
            vadStreamState = await vadManager.makeStreamState()
        }

        if needsSpeakerHints {
            try await ensureSortformerPrepared(onProgress: onProgress)
        } else {
            sortformerDiarizer = nil
            sortformerNeedsReprime = false
            resetSpeakerHintTracking()
            clearSpeakerHintIfNeeded()
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Live preview ready",
                        detail: "Streaming ASR and VAD are ready. Add known speakers to enable live speaker hints."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                FluidAudioProgressSupport.readyUpdate(
                    phase: .preparing,
                    component: .livePreview,
                    label: "Live preview ready",
                    detail: "Streaming ASR, VAD, and warm-started live speaker hints are ready."
                )
            )
        }
    }

    private func ensureSortformerPrepared(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if sortformerModels == nil {
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live speaker hints",
                        detail: "Downloading Sortformer streaming diarization models…",
                        fraction: 0.78
                    )
                )
            }
            let progressDispatcher = LiveSerialProgressDispatcher()
            sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: Self.liveSortformerConfig,
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live speaker hints",
                        progress: progress
                    )
                    let scaled = FluidAudioProgressSupport.scale(update, into: 0.76...0.93)
                    progressDispatcher.submit(scaled, to: onProgress)
                }
            )
            await progressDispatcher.drain()
        }

        guard let sortformerModels else {
            throw LorreError.processingFailed("Sortformer live diarization models are unavailable.")
        }

        guard sortformerNeedsReprime || sortformerDiarizer == nil else {
            return
        }

        let diarizer = SortformerDiarizer(config: Self.liveSortformerConfig)
        diarizer.initialize(models: sortformerModels)

        let primingSamples = try await loadPrimingSamples()
        if primingSamples.isEmpty {
            sortformerDiarizer = diarizer
            sortformerNeedsReprime = false
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Live speaker hints ready",
                        detail: "No usable reference clips were found, so speaker priming was skipped.",
                        fraction: 1.0
                    )
                )
            }
            return
        }

        for (index, primingSample) in primingSamples.enumerated() {
            if let onProgress {
                let progress = 0.93 + (0.07 * Double(index) / Double(max(primingSamples.count, 1)))
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Priming live speaker hints",
                        detail: "Priming \(primingSample.speaker.safeDisplayName)…",
                        fraction: min(progress, 0.995)
                    )
                )
            }
            _ = try diarizer.enrollSpeaker(
                withAudio: primingSample.samples,
                sourceSampleRate: nil,
                named: primingSample.speaker.safeDisplayName,
                overwritingAssignedSpeakerName: false
            )
        }

        sortformerDiarizer = diarizer
        sortformerNeedsReprime = false
        resetSpeakerHintTracking()
    }

    private func loadPrimingSamples() async throws -> [(speaker: KnownSpeaker, samples: [Float])] {
        guard let knownSpeakerReferenceAudioProvider else { return [] }

        var primingSamples: [(speaker: KnownSpeaker, samples: [Float])] = []
        for speaker in knownSpeakers {
            guard let referenceURL = await knownSpeakerReferenceAudioProvider(speaker) else { continue }
            let samples = try audioConverter.resampleAudioFile(referenceURL)
            let trimmed = Self.trimSpeakerSamples(samples)
            let effectiveSamples = trimmed.isEmpty ? samples : trimmed
            guard effectiveSamples.count >= speakerHintMinimumSamples else { continue }
            primingSamples.append((speaker, Array(effectiveSamples.prefix(maxPrimingSamples))))
        }
        return primingSamples
    }

    private func resetSpeakerHintTracking() {
        speakerAssignmentsBySlot.removeAll(keepingCapacity: false)
        activeSpeakerSlot = nil
        recentSlotSamples.removeAll(keepingCapacity: false)
        lastSpeakerHintLookupAt = nil
    }

    private func handlePartialCallbackText(_ text: String) async {
        guard isStreaming, preparedPreset != .dutchUnified else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview.partialText = ""
            preview.isFinalizing = false
            preview.errorMessage = nil
            preview.updatedAt = Date()
            emitPreview()
            return
        }
        let update = await punctuationCommitLayer.processPartialText(trimmed)
        applyCommitLayerUpdate(update, at: update.timestamp)
        preview.isFinalizing = false
        preview.errorMessage = nil
        emitPreview()
    }

    private func handleCommitLayerUpdate(_ update: CommitLayerUpdate) async {
        guard isStreaming, preparedPreset != .dutchUnified else { return }
        applyCommitLayerUpdate(update, at: update.timestamp)
        preview.isFinalizing = false
        preview.errorMessage = nil
        emitPreview()
    }

    private func shouldFeedToAsr(_ samples: [Float]) async throws -> Bool {
        guard isStreaming else { return false }
        guard let vadManager else { return true }

        if gateSpeechSeenForCurrentUtterance {
            return true
        }

        guard !samples.isEmpty else { return false }
        vadRemainderSamples.append(contentsOf: samples)

        let initialState: VadStreamState
        if let vadStreamState {
            initialState = vadStreamState
        } else {
            initialState = await vadManager.makeStreamState()
        }
        var state = initialState
        var shouldOpenGate = false

        while vadRemainderSamples.count >= VadManager.chunkSize {
            let chunk = Array(vadRemainderSamples.prefix(VadManager.chunkSize))
            vadRemainderSamples.removeFirst(VadManager.chunkSize)
            let result = try await vadManager.processStreamingChunk(
                chunk,
                state: state,
                config: Self.liveVadConfig
            )
            state = result.state
            if result.state.triggered || result.event?.isStart == true {
                shouldOpenGate = true
            }
        }

        vadStreamState = state
        if shouldOpenGate {
            gateSpeechSeenForCurrentUtterance = true
        }

        // Reliability first: keep streaming ASR fed even if VAD misses the onset.
        // VAD is still used as a hint for gating state / future tuning, but not as a hard blocker.
        return true
    }

    private func updateLiveSpeakerState(with samples: [Float]) async throws {
        guard let sortformerDiarizer, !knownSpeakers.isEmpty else { return }
        guard !samples.isEmpty else { return }

        let result = try sortformerDiarizer.process(samples: samples, sourceSampleRate: nil)
        guard let strongest = strongestSpeaker(from: result) else {
            clearSpeakerHintIfNeeded()
            activeSpeakerSlot = nil
            recentSlotSamples.removeAll(keepingCapacity: false)
            lastSpeakerHintLookupAt = nil
            return
        }

        if activeSpeakerSlot != strongest.slot {
            activeSpeakerSlot = strongest.slot
            recentSlotSamples.removeAll(keepingCapacity: true)
            lastSpeakerHintLookupAt = nil
        }

        recentSlotSamples.append(contentsOf: samples)
        if recentSlotSamples.count > maxSpeakerHintWindowSamples {
            recentSlotSamples.removeFirst(recentSlotSamples.count - maxSpeakerHintWindowSamples)
        }

        if let assignment = speakerAssignmentsBySlot[strongest.slot] {
            applySpeakerHint(assignment, probability: strongest.probability)
            return
        }

        guard recentSlotSamples.count >= speakerHintMinimumSamples else { return }

        let now = Date()
        if let lastSpeakerHintLookupAt,
           now.timeIntervalSince(lastSpeakerHintLookupAt) < speakerHintLookupInterval {
            return
        }
        lastSpeakerHintLookupAt = now

        let embedding = try await speakerEnrollmentService.extractEmbedding(from: recentSlotSamples)
        guard let match = matchKnownSpeaker(for: embedding) else {
            clearSpeakerHintIfNeeded()
            return
        }

        let assignment = LiveSpeakerAssignment(
            speakerID: match.speaker.id,
            displayName: match.speaker.safeDisplayName,
            distance: match.distance
        )
        speakerAssignmentsBySlot[strongest.slot] = assignment
        applySpeakerHint(assignment, probability: strongest.probability)
    }

    private func strongestSpeaker(from update: DiarizerTimelineUpdate?) -> (slot: Int, probability: Float)? {
        guard let update else { return nil }

        let candidate: DiarizerSegment?
        if !update.tentativeSegments.isEmpty {
            candidate = update.tentativeSegments.max { lhs, rhs in
                if lhs.endFrame == rhs.endFrame {
                    return lhs.activity < rhs.activity
                }
                return lhs.endFrame < rhs.endFrame
            }
        } else {
            candidate = update.finalizedSegments.max { lhs, rhs in
                if lhs.endFrame == rhs.endFrame {
                    return lhs.activity < rhs.activity
                }
                return lhs.endFrame < rhs.endFrame
            }
        }

        guard let candidate else {
            return nil
        }
        let activity = Self.normalizedLiveSpeakerActivity(candidate.activity)
        guard activity >= liveSpeakerActivationThreshold else { return nil }
        return (slot: candidate.speakerIndex, probability: activity)
    }

    private func matchKnownSpeaker(for embedding: [Float]) -> (speaker: KnownSpeaker, distance: Float)? {
        let matches = knownSpeakers.map { speaker in
            (speaker: speaker, distance: KnownSpeakerSimilarity.cosineDistance(embedding, speaker.embedding))
        }
        .filter { $0.distance.isFinite }
        .sorted { lhs, rhs in
            if lhs.distance == rhs.distance {
                return lhs.speaker.safeDisplayName.localizedCaseInsensitiveCompare(rhs.speaker.safeDisplayName) == .orderedAscending
            }
            return lhs.distance < rhs.distance
        }

        guard let best = matches.first, best.distance <= liveSpeakerMatchThreshold else { return nil }
        return best
    }

    private func applySpeakerHint(_ assignment: LiveSpeakerAssignment, probability: Float) {
        let normalizedDistance = max(0, min(1, 1 - (assignment.distance / liveSpeakerMatchThreshold)))
        let confidence = Double(normalizedDistance) * Double(max(0, min(1, probability)))

        if preview.activeSpeakerID == assignment.speakerID,
           preview.activeSpeakerDisplayName == assignment.displayName,
           preview.activeSpeakerConfidence == confidence {
            return
        }

        preview.activeSpeakerID = assignment.speakerID
        preview.activeSpeakerDisplayName = assignment.displayName
        preview.activeSpeakerConfidence = confidence
        preview.updatedAt = Date()
        emitPreview()
    }

    private func clearSpeakerHintIfNeeded() {
        guard preview.activeSpeakerID != nil || preview.activeSpeakerDisplayName != nil || preview.activeSpeakerConfidence != nil else {
            return
        }
        preview.activeSpeakerID = nil
        preview.activeSpeakerDisplayName = nil
        preview.activeSpeakerConfidence = nil
        preview.updatedAt = Date()
        emitPreview()
    }

    private func finalizeDetectedUtterance(using streamingManager: StreamingASRManager) async throws {
        let text = try await streamingManager.finish()
        let now = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = await punctuationCommitLayer.processPartialText(trimmed)
        }
        let update = await punctuationCommitLayer.processEOU()
        applyCommitLayerUpdate(update, at: now)
        preview.isFinalizing = false
        preview.errorMessage = nil
        emitPreview()
        try await streamingManager.reset()
        gateSpeechSeenForCurrentUtterance = false
        activeSpeakerSlot = nil
        recentSlotSamples.removeAll(keepingCapacity: false)
        lastSpeakerHintLookupAt = nil
    }

    private func applyCommitLayerUpdate(_ update: CommitLayerUpdate, at timestamp: Date) {
        preview.confirmedText = update.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.partialText = update.ghostText.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.updatedAt = timestamp
    }

    private func emitPreview() {
        let snapshot = preview
        previewHandler?(snapshot)
    }

    private func makeStreamingManager(
        for preset: LiveTranscriptionPreset,
        progressHandler: @escaping ProgressHandler
    ) async throws -> StreamingASRManager {
        let base = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        if preset == .dutchUnified {
            let config = UnifiedConfig(chunkFrames: 7, rightFrames: 7, family: .nemotronMultilingual(.nl))
            let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: .fp16)
            try await manager.loadModels(to: base, progressHandler: progressHandler)
            return .unified(manager)
        }

        let repo = preset.modelRepository
        try await ModelHub.download(repo, to: base, progressHandler: progressHandler)
        let modelDir = base.appendingPathComponent(repo.folderName, isDirectory: true)
        if let settings = preset.eouSettings {
            let manager = StreamingEouAsrManager(
                chunkSize: settings.chunkSize,
                eouDebounceMs: settings.debounceMs
            )
            try await manager.loadModels(from: modelDir)
            await manager.setPartialCallback { [weak self] partial in
                Task { await self?.handlePartialCallbackText(partial) }
            }
            return .parakeet(manager)
        }

        let chunkSize: NemotronChunkSize = preset == .nemotronBalanced ? .ms560 : .ms1120
        let manager = StreamingNemotronAsrManager(requestedChunkSize: chunkSize)
        try await manager.loadModels(from: modelDir)
        await manager.setPartialCallback { [weak self] partial in
            Task { await self?.handlePartialCallbackText(partial) }
        }
        return .nemotron(manager)
    }

    private static func trimSpeakerSamples(_ samples: [Float]) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) >= 0.003 }),
              let last = samples.lastIndex(where: { abs($0) >= 0.003 }) else {
            return samples
        }

        let lower = max(0, first - 1_600)
        let upper = min(samples.count - 1, last + 1_600)
        return Array(samples[lower...upper])
    }

    private static let liveVadConfig = VadSegmentationConfig(
        minSpeechDuration: 0.12,
        minSilenceDuration: 0.45,
        maxSpeechDuration: 20.0,
        speechPadding: 0.06
    )

    private let liveSpeakerActivationThreshold: Float = 0.40
    private let liveSpeakerMatchThreshold: Float = 0.36
    private let speakerHintLookupInterval: TimeInterval = 0.75
    private let speakerHintMinimumSamples = 16_000
    private let maxSpeakerHintWindowSamples = 16_000 * 6
    private let maxPrimingSamples = 16_000 * 12
    private static let liveSortformerConfig = SortformerConfig.balancedV2_1
}
#endif
