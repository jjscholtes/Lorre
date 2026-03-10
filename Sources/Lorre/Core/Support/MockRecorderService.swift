import Foundation

actor MockRecorderService: RecorderService {
    private var startedAt: Date?
    private var syntheticLevel: Double = 0.15

    func requestMicrophonePermission() async -> Bool {
        true
    }

    func startRecording() async throws {
        guard startedAt == nil else {
            throw LorreError.recordingStartFailed("A recording is already active.")
        }
        startedAt = Date()
    }

    func cancelRecording() async throws {
        guard startedAt != nil else {
            throw LorreError.recordingNotStarted
        }
        startedAt = nil
    }

    func stopRecording(to url: URL) async throws -> RecordingCapture {
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
            try AtomicFileWriter.write(Data(placeholder.utf8), to: url)
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

    func preferredRecordingFileExtension() async -> String {
        "m4a"
    }

    func supportsLiveTranscription() async -> Bool {
        false
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
