import Foundation

protocol SessionStore: Sendable {
    func loadSessions() async throws -> [SessionManifest]
    func loadSession(id: UUID) async throws -> SessionManifest?
    func createSession(_ draft: NewSessionDraft) async throws -> SessionManifest
    func updateSession(_ session: SessionManifest) async throws
    func deleteSession(id: UUID) async throws
    func loadTranscript(sessionId: UUID) async throws -> TranscriptDocument?
    func saveTranscript(_ transcript: TranscriptDocument) async throws
    func sessionDirectoryURL(for sessionId: UUID) async -> URL
    func exportDirectoryURL(for sessionId: UUID) async -> URL
}

protocol RecorderService: Sendable {
    func requestMicrophonePermission() async -> Bool
    func startRecording() async throws
    func cancelRecording() async throws
    func stopRecording(to url: URL) async throws -> RecordingCapture
    func currentMeterLevel() async -> Double
    func preferredRecordingFileExtension() async -> String
    func supportsLiveTranscription() async -> Bool
    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async
    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async
    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview?
    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>?
}

protocol TranscriptionService: Sendable {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setVocabularyBoostingConfiguration(_ configuration: VocabularyBoostingConfiguration) async
    func transcribe(url: URL, sessionTitle: String) async throws -> TranscriptionResult
}

protocol SpeakerDiarizationService: Sendable {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async
    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint
    ) async throws -> DiarizationResult?
}

protocol SpeakerEnrollmentService: Sendable {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func makeEnrollment(from audioURL: URL) async throws -> KnownSpeakerEnrollmentData
    func extractEmbedding(from audioSamples: [Float]) async throws -> [Float]
}

protocol ExportService: Sendable {
    func export(
        session: SessionManifest,
        transcript: TranscriptDocument,
        format: ExportFormat,
        destinationURL: URL
    ) async throws -> URL
    func suggestedFileName(session: SessionManifest, format: ExportFormat) -> String
}

protocol AudioPlaybackService: AnyObject {
    var preparedURL: URL? { get }
    var currentTimeSeconds: Double { get }
    var durationSeconds: Double { get }
    var isPlaying: Bool { get }
    var playbackRate: Double { get }

    func prepare(url: URL) throws
    func play() throws
    func pause()
    func stop()
    func seek(to seconds: Double)
    func setPlaybackRate(_ rate: Double)
}
