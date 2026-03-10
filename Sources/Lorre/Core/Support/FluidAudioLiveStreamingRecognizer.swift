import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

#if canImport(AVFoundation) && canImport(FluidAudio)
final class LiveTranscriptionPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

actor FluidAudioLiveStreamingRecognizer {
    private enum LivePreset: CaseIterable {
        case balanced
        case lowLatency

        var chunkSize: StreamingChunkSize {
            switch self {
            case .balanced: return .ms320
            case .lowLatency: return .ms160
            }
        }

        var eouDebounceMs: Int {
            switch self {
            case .balanced: return 1280
            case .lowLatency: return 1120
            }
        }

        var repo: Repo {
            switch self {
            case .balanced: return .parakeetEou320
            case .lowLatency: return .parakeetEou160
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

    private var eouManager: StreamingEouAsrManager?
    private var vadManager: VadManager?
    private var preparedPreset: LivePreset?
    private var preview = LiveTranscriptPreview()
    private var previewHandler: (@Sendable (LiveTranscriptPreview) -> Void)?
    private var isStreaming = false

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
        knownSpeakerReferenceAudioProvider: (@Sendable (KnownSpeaker) async -> URL?)? = nil
    ) {
        self.speakerEnrollmentService = speakerEnrollmentService
        self.knownSpeakerReferenceAudioProvider = knownSpeakerReferenceAudioProvider
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
        if let eouManager {
            await eouManager.reset()
        }
        emitPreview()
    }

    func ingest(_ bufferBox: LiveTranscriptionPCMBufferBox) async {
        guard isStreaming else { return }
        guard let eouManager else { return }

        do {
            let samples = try audioConverter.resampleBuffer(bufferBox.buffer)
            try await updateLiveSpeakerState(with: samples)

            if !(try await shouldFeedToAsr(samples)) {
                return
            }

            _ = try await eouManager.process(audioBuffer: bufferBox.buffer)
            let eouDetected = await eouManager.eouDetected
            if eouDetected {
                try await finalizeDetectedUtterance(using: eouManager)
            }
        } catch is CancellationError {
            return
        } catch {
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

        guard let eouManager else {
            preview.isFinalizing = false
            preview.updatedAt = Date()
            emitPreview()
            return preview
        }

        do {
            let finalChunk = try await eouManager.finish()
            appendConfirmedUtterance(finalChunk, at: Date())
            preview.partialText = ""
            preview.isFinalizing = false
            preview.errorMessage = nil
            preview.updatedAt = Date()
            await eouManager.reset()
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
        if let eouManager {
            await eouManager.reset()
        }
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
        let needsSpeakerHints = !knownSpeakers.isEmpty && knownSpeakerReferenceAudioProvider != nil
        let livePreviewReady = eouManager != nil && vadManager != nil
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

        let selectedPreset: LivePreset
        if let preparedPreset {
            selectedPreset = preparedPreset
        } else {
            selectedPreset = try await selectAndPreparePreset()
        }

        if eouManager == nil {
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live preview",
                        detail: "Checking Parakeet streaming models…",
                        fraction: 0.02
                    )
                )
            }

            let modelDir = try await Self.ensureEouModelDirectory(
                for: selectedPreset.repo,
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live preview",
                        progress: progress
                    )
                    let scaled = FluidAudioProgressSupport.scale(update, into: 0.0...0.46)
                    Task {
                        await onProgress(scaled)
                    }
                }
            )

            let manager = StreamingEouAsrManager(
                chunkSize: selectedPreset.chunkSize,
                eouDebounceMs: selectedPreset.eouDebounceMs
            )
            if let onProgress {
                await onProgress(
                    ProcessingUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Loading live preview models",
                        detail: "Opening streaming ASR models from disk…",
                        fraction: 0.52
                    )
                )
            }
            try await manager.loadModels(modelDir: modelDir)
            await manager.setPartialCallback { [weak self] partial in
                Task { await self?.handlePartialCallbackText(partial) }
            }
            eouManager = manager
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
                    Task {
                        await onProgress(scaled)
                    }
                }
            )
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
            sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: .default,
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .livePreview,
                        label: "Preparing live speaker hints",
                        progress: progress
                    )
                    let scaled = FluidAudioProgressSupport.scale(update, into: 0.76...0.93)
                    Task {
                        await onProgress(scaled)
                    }
                }
            )
        }

        guard let sortformerModels else {
            throw LorreError.processingFailed("Sortformer live diarization models are unavailable.")
        }

        guard sortformerNeedsReprime || sortformerDiarizer == nil else {
            return
        }

        let diarizer = SortformerDiarizer(config: .default)
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
            try diarizer.primeWithAudio(primingSample.samples)
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

    private func handlePartialCallbackText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if preview.updatedAt == nil {
                preview.updatedAt = Date()
                emitPreview()
            }
            return
        }
        preview.partialText = trimmed
        preview.isFinalizing = false
        preview.errorMessage = nil
        preview.updatedAt = Date()
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

        let result = try sortformerDiarizer.processSamples(samples)
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

    private func strongestSpeaker(from chunk: SortformerChunkResult?) -> (slot: Int, probability: Float)? {
        guard let chunk else { return nil }

        let probabilities: [Float]
        if chunk.tentativeFrameCount > 0 {
            let start = max(0, chunk.tentativePredictions.count - 4)
            probabilities = Array(chunk.tentativePredictions[start...])
        } else if chunk.frameCount > 0 {
            let start = max(0, chunk.speakerPredictions.count - 4)
            probabilities = Array(chunk.speakerPredictions[start...])
        } else {
            return nil
        }

        guard probabilities.count == 4 else { return nil }
        guard let maxEntry = probabilities.enumerated().max(by: { $0.element < $1.element }) else {
            return nil
        }
        guard maxEntry.element >= liveSpeakerActivationThreshold else { return nil }
        return (slot: maxEntry.offset, probability: maxEntry.element)
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

    private func finalizeDetectedUtterance(using eouManager: StreamingEouAsrManager) async throws {
        let text = try await eouManager.finish()
        let now = Date()
        appendConfirmedUtterance(text, at: now)
        preview.partialText = ""
        preview.isFinalizing = false
        preview.errorMessage = nil
        preview.updatedAt = now
        emitPreview()
        await eouManager.reset()
        gateSpeechSeenForCurrentUtterance = false
        activeSpeakerSlot = nil
        recentSlotSamples.removeAll(keepingCapacity: false)
        lastSpeakerHintLookupAt = nil
    }

    private func appendConfirmedUtterance(_ text: String, at timestamp: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview.updatedAt = timestamp
            return
        }

        let existing = preview.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            preview.confirmedText = trimmed
        } else if existing != trimmed && !existing.hasSuffix(trimmed) {
            preview.confirmedText = "\(existing) \(trimmed)"
        } else {
            preview.confirmedText = existing
        }
        preview.updatedAt = timestamp
    }

    private func emitPreview() {
        let snapshot = preview
        previewHandler?(snapshot)
    }

    private func selectAndPreparePreset() async throws -> LivePreset {
        for preset in LivePreset.allCases {
            do {
                _ = try await Self.ensureEouModelDirectory(for: preset.repo, progressHandler: nil)
                return preset
            } catch {
                if preset == LivePreset.allCases.last {
                    throw error
                }
            }
        }
        return .lowLatency
    }

    private static func ensureEouModelDirectory(
        for repo: Repo,
        progressHandler: DownloadUtils.ProgressHandler?
    ) async throws -> URL {
        let base = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(repo, to: base, progressHandler: progressHandler)
        return base.appendingPathComponent(repo.folderName, isDirectory: true)
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
}
#endif
