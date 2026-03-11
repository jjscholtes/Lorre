import Foundation

actor MockRecorderService: RecorderService {
    private var startedAt: Date?
    private var syntheticLevel: Double = 0.15
    private var activeSource: RecordingSource = .microphone

    func startRecording(_ request: RecordingRequest) async throws {
        guard startedAt == nil else {
            throw LorreError.recordingStartFailed("A recording is already active.")
        }
        activeSource = request.source
        startedAt = Date()
    }

    func cancelRecording() async throws {
        guard startedAt != nil else {
            throw LorreError.recordingNotStarted
        }
        startedAt = nil
    }

    func stopRecording(in directoryURL: URL, fileLayout: RecordingFileLayout) async throws -> RecordingCapture {
        guard let startedAt else {
            throw LorreError.recordingNotStarted
        }
        let endedAt = Date()
        self.startedAt = nil

        let duration = max(0.8, endedAt.timeIntervalSince(startedAt))
        let placeholder = """
        MOCK_AUDIO_CAPTURE
        startedAt=\(startedAt.ISO8601Format())
        endedAt=\(endedAt.ISO8601Format())
        durationSeconds=\(duration)
        """
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let canonicalURL = directoryURL.appendingPathComponent(fileLayout.audioFileName)
            try AtomicFileWriter.write(Data(placeholder.utf8), to: canonicalURL)

            if activeSource == .microphoneAndSystemAudio {
                if let microphoneStemFileName = fileLayout.microphoneStemFileName {
                    try AtomicFileWriter.write(Data("MOCK_MIC_STEM".utf8), to: directoryURL.appendingPathComponent(microphoneStemFileName))
                }
                if let systemAudioStemFileName = fileLayout.systemAudioStemFileName {
                    try AtomicFileWriter.write(Data("MOCK_SYSTEM_STEM".utf8), to: directoryURL.appendingPathComponent(systemAudioStemFileName))
                }
            }
        } catch {
            throw LorreError.recordingStopFailed(error.localizedDescription)
        }

        return RecordingCapture(startedAt: startedAt, endedAt: endedAt, durationSeconds: duration)
    }

    func currentMeterLevel() async -> Double {
        if startedAt == nil { return 0.05 }
        syntheticLevel = min(1, max(0.08, syntheticLevel + Double.random(in: -0.22...0.22)))
        return syntheticLevel
    }

    func recordingFileLayout(for source: RecordingSource) async -> RecordingFileLayout {
        switch source {
        case .microphone, .systemAudio:
            return RecordingFileLayout(audioFileName: "audio.m4a", microphoneStemFileName: nil, systemAudioStemFileName: nil)
        case .microphoneAndSystemAudio:
            return RecordingFileLayout(
                audioFileName: "audio.m4a",
                microphoneStemFileName: "microphone.m4a",
                systemAudioStemFileName: "system-audio.m4a"
            )
        }
    }

    func supportsLiveTranscription(for source: RecordingSource) async -> Bool {
        _ = source
        return false
    }

    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .livePreview,
                    label: "Live preview unavailable",
                    detail: "This build does not include the live preview engine.",
                    fraction: 1.0
                )
            )
        }
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        _ = speakers
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async {
        _ = isEnabled
    }

    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview? {
        nil
    }

    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>? {
        nil
    }
}
