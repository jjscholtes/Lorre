import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

struct MockTranscriptionService: TranscriptionService {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .asr,
                    label: "Mock ASR ready",
                    detail: "Using the mock transcription pipeline.",
                    fraction: 1.0
                )
            )
        }
        try await Task.sleep(for: .milliseconds(180))
    }

    func setVocabularyBoostingConfiguration(_ configuration: VocabularyBoostingConfiguration) async {
        _ = configuration
    }

    func transcribe(url: URL, sessionTitle: String, source: RecordingSource) async throws -> TranscriptionResult {
        _ = url
        _ = source
        try await Task.sleep(for: .milliseconds(500))

        let base = [
            "Thanks for joining. Let's capture the action items while they're fresh.",
            "We need a clean transcript with speaker labels and a quick export.",
            "I'll review the first pass and correct names before sending.",
            "Let's keep the workflow local and straightforward."
        ]
        let titleSeed = max(1, sessionTitle.count % base.count)
        let rotated = Array(base[titleSeed...] + base[..<titleSeed])

        var utterances: [TranscriptionUtterance] = []
        var cursor = 0
        for (index, line) in rotated.enumerated() {
            let duration = 2200 + (index * 450)
            utterances.append(
                TranscriptionUtterance(
                    startMs: cursor,
                    endMs: cursor + duration,
                    text: line,
                    confidence: 0.89 - (Double(index) * 0.04)
                )
            )
            cursor += duration + 500
        }

        return TranscriptionResult(engineName: "MockAsrService", utterances: utterances)
    }
}

struct MockSpeakerDiarizationService: SpeakerDiarizationService {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Mock diarization ready",
                    detail: "Using the mock speaker diarization pipeline.",
                    fraction: 1.0
                )
            )
        }
        try await Task.sleep(for: .milliseconds(140))
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        _ = speakers
    }

    func setDiarizationEngine(_ engine: DiarizationEngine) async {
        _ = engine
    }

    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint
    ) async throws -> DiarizationResult? {
        _ = url
        try await Task.sleep(for: .milliseconds(350))
        let totalMs = Int(max(12, expectedDurationSeconds ?? 14) * 1000)
        let span = max(2000, totalMs / 4)
        let speakerPool = speakerSequence(for: expectedSpeakers)
        var spans: [DiarizationSpan] = []
        var cursor = 0
        var i = 0
        while cursor < totalMs {
            let next = min(totalMs, cursor + span)
            spans.append(DiarizationSpan(startMs: cursor, endMs: next, speakerId: speakerPool[i % speakerPool.count]))
            cursor = next
            i += 1
        }
        return DiarizationResult(spans: spans)
    }

    private func speakerSequence(for hint: DiarizationSpeakerCountHint) -> [String] {
        let normalized = hint.normalized()
        let desiredCount: Int
        switch normalized.mode {
        case .auto:
            desiredCount = 3
        case .exact:
            desiredCount = normalized.exactCount ?? 3
        case .range:
            let lower = normalized.minCount ?? 2
            let upper = normalized.maxCount ?? lower
            desiredCount = max(lower, min(upper, 3))
        }

        let count = max(1, min(8, desiredCount))
        let speakers = (1...count).map { "S\($0)" }
        if speakers.count == 1 { return [speakers[0], speakers[0], speakers[0], speakers[0]] }
        if speakers.count == 2 { return [speakers[0], speakers[1], speakers[0], speakers[1]] }
        if speakers.count == 3 { return [speakers[0], speakers[1], speakers[0], speakers[2]] }
        return speakers
    }
}
