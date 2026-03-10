import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

#if canImport(FluidAudio)
actor FluidAudioSpeakerEnrollmentService: SpeakerEnrollmentService {
    private let audioConverter = AudioConverter()
    private var diarizer: DiarizerManager?
    private var prepared = false

    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        if prepared, diarizer != nil {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .speakerEnrollment,
                        label: "Speaker enrollment ready",
                        detail: "Embedding extractor models are already loaded."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .speakerEnrollment,
                    label: "Preparing speaker enrollment",
                    detail: "Checking diarizer embedding models…",
                    fraction: 0.02
                )
            )
        }

        let models = try await DiarizerModels.load(
            progressHandler: { progress in
                guard let onProgress else { return }
                let update = FluidAudioProgressSupport.makeUpdate(
                    phase: .preparing,
                    component: .speakerEnrollment,
                    label: "Preparing speaker enrollment",
                    progress: progress
                )
                Task {
                    await onProgress(update)
                }
            }
        )

        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        self.diarizer = diarizer
        self.prepared = true

        if let onProgress {
            await onProgress(
                FluidAudioProgressSupport.readyUpdate(
                    phase: .preparing,
                    component: .speakerEnrollment,
                    label: "Speaker enrollment ready",
                    detail: "Embedding extractor prepared from \(ModelRegistry.baseURL)."
                )
            )
        }
    }

    func makeEnrollment(from audioURL: URL) async throws -> KnownSpeakerEnrollmentData {
        let samples = try audioConverter.resampleAudioFile(audioURL)
        let trimmedSamples = Self.trimOuterSilence(samples)
        let effectiveSamples = trimmedSamples.isEmpty ? samples : trimmedSamples
        let durationSeconds = Double(effectiveSamples.count) / 16_000.0

        guard durationSeconds >= 1.2 else {
            throw LorreError.processingFailed(
                "Voice sample is too short. Use at least 1.2 seconds of a single speaker."
            )
        }

        let embedding = try await extractEmbedding(from: effectiveSamples)
        return KnownSpeakerEnrollmentData(
            embedding: embedding,
            durationSeconds: durationSeconds,
            sampleRate: 16_000
        )
    }

    func extractEmbedding(from audioSamples: [Float]) async throws -> [Float] {
        try await ensureModelsReady(onProgress: nil)
        guard let diarizer else {
            throw LorreError.processingFailed("Speaker enrollment models are not initialized.")
        }

        let normalizedSamples = Self.trimOuterSilence(audioSamples)
        let effectiveSamples = normalizedSamples.isEmpty ? audioSamples : normalizedSamples
        guard effectiveSamples.count >= 16_000 else {
            throw LorreError.processingFailed(
                "Not enough speech was detected to enroll this speaker reliably."
            )
        }

        return try diarizer.extractSpeakerEmbedding(from: effectiveSamples)
    }

    private static func trimOuterSilence(
        _ samples: [Float],
        threshold: Float = 0.003,
        keepPaddingSamples: Int = 1_600
    ) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else {
            return samples
        }

        let lower = max(0, first - keepPaddingSamples)
        let upper = min(samples.count - 1, last + keepPaddingSamples)
        return Array(samples[lower...upper])
    }
}
#else
actor FluidAudioSpeakerEnrollmentService: SpeakerEnrollmentService {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        _ = onProgress
        throw LorreError.processingFailed("Speaker enrollment is unavailable in this build.")
    }

    func makeEnrollment(from audioURL: URL) async throws -> KnownSpeakerEnrollmentData {
        _ = audioURL
        throw LorreError.processingFailed("Speaker enrollment is unavailable in this build.")
    }

    func extractEmbedding(from audioSamples: [Float]) async throws -> [Float] {
        _ = audioSamples
        throw LorreError.processingFailed("Speaker enrollment is unavailable in this build.")
    }
}
#endif
