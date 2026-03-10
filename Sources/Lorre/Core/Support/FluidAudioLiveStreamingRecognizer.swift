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

    private let audioConverter = AudioConverter()
    private var eouManager: StreamingEouAsrManager?
    private var vadManager: VadManager?
    private var preparedPreset: LivePreset?
    private var preview = LiveTranscriptPreview()
    private var previewHandler: (@Sendable (LiveTranscriptPreview) -> Void)?
    private var isStreaming = false

    private var vadStreamState: VadStreamState?
    private var vadRemainderSamples: [Float] = []
    private var gateSpeechSeenForCurrentUtterance = false

    func prepareModels() async throws {
        try await ensureManagersPrepared()
    }

    func start(onPreview: @escaping @Sendable (LiveTranscriptPreview) -> Void) async throws {
        try await ensureManagersPrepared()
        self.previewHandler = onPreview
        self.preview = LiveTranscriptPreview(
            confirmedText: "",
            partialText: "",
            isFinalizing: false,
            errorMessage: nil,
            updatedAt: Date()
        )
        self.isStreaming = true
        self.vadRemainderSamples.removeAll(keepingCapacity: true)
        self.gateSpeechSeenForCurrentUtterance = false
        if let vadManager {
            self.vadStreamState = await vadManager.makeStreamState()
        } else {
            self.vadStreamState = nil
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
            if !(try await shouldFeedToAsr(bufferBox.buffer)) {
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
        if let eouManager {
            await eouManager.reset()
        }
        if let vadManager {
            vadStreamState = await vadManager.makeStreamState()
        } else {
            vadStreamState = nil
        }
        preview = LiveTranscriptPreview()
    }

    func latestPreview() -> LiveTranscriptPreview {
        preview
    }

    private func ensureManagersPrepared() async throws {
        guard eouManager == nil || vadManager == nil else { return }

        let selectedPreset: LivePreset
        if let preparedPreset {
            selectedPreset = preparedPreset
        } else {
            selectedPreset = try await selectAndPreparePreset()
        }

        if eouManager == nil {
            let manager = StreamingEouAsrManager(
                chunkSize: selectedPreset.chunkSize,
                eouDebounceMs: selectedPreset.eouDebounceMs
            )
            let modelDir = try await Self.ensureEouModelDirectory(for: selectedPreset.repo)
            try await manager.loadModels(modelDir: modelDir)
            await manager.setPartialCallback { [weak self] partial in
                Task { await self?.handlePartialCallbackText(partial) }
            }
            self.eouManager = manager
            self.preparedPreset = selectedPreset
        }

        if vadManager == nil {
            self.vadManager = try await VadManager()
        }

        if let vadManager, vadStreamState == nil {
            self.vadStreamState = await vadManager.makeStreamState()
        }
    }

    private func selectAndPreparePreset() async throws -> LivePreset {
        for preset in LivePreset.allCases {
            do {
                let _ = try await Self.ensureEouModelDirectory(for: preset.repo)
                return preset
            } catch {
                if preset == LivePreset.allCases.last {
                    throw error
                }
            }
        }
        return .lowLatency
    }

    private static func ensureEouModelDirectory(for repo: Repo) async throws -> URL {
        let base = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(repo, to: base)
        return base.appendingPathComponent(repo.folderName, isDirectory: true)
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

    private func shouldFeedToAsr(_ buffer: AVAudioPCMBuffer) async throws -> Bool {
        guard isStreaming else { return false }
        guard let vadManager else { return true }

        if gateSpeechSeenForCurrentUtterance {
            return true
        }

        let samples = try audioConverter.resampleBuffer(buffer)
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

    private static let liveVadConfig = VadSegmentationConfig(
        minSpeechDuration: 0.12,
        minSilenceDuration: 0.45,
        maxSpeechDuration: 20.0,
        speechPadding: 0.06
    )
}
#endif
