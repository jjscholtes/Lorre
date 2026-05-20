import Foundation

protocol SessionStore: Sendable {
    func loadSessions() async throws -> [SessionManifest]
    func loadSession(id: UUID) async throws -> SessionManifest?
    func createSession(_ draft: NewSessionDraft) async throws -> SessionManifest
    func updateSession(_ session: SessionManifest) async throws
    /// Atomically load the latest manifest for `id`, apply `apply` to it, and persist the
    /// result. Conforming actors should run the entire load-mutate-save without yielding so
    /// concurrent callers cannot clobber each other's edits.
    @discardableResult
    func updateSession(id: UUID, apply: @Sendable (inout SessionManifest) -> Void) async throws -> SessionManifest
    func deleteSession(id: UUID) async throws
    func loadTranscript(sessionId: UUID) async throws -> TranscriptDocument?
    func saveTranscript(_ transcript: TranscriptDocument) async throws
    func sessionDirectoryURL(for sessionId: UUID) async -> URL
    func exportDirectoryURL(for sessionId: UUID) async -> URL
}

extension SessionStore {
    /// Fallback for conformers that haven't overridden the atomic API. Non-actor conformers
    /// (or any caller that doesn't go through this method) will still race; the FileSessionStore
    /// override is the only impl that actually serializes load + save.
    @discardableResult
    func updateSession(id: UUID, apply: @Sendable (inout SessionManifest) -> Void) async throws -> SessionManifest {
        guard var manifest = try await loadSession(id: id) else {
            throw LorreError.sessionNotFound
        }
        apply(&manifest)
        try await updateSession(manifest)
        return manifest
    }
}

protocol RecorderService: Sendable {
    func startRecording(_ request: RecordingRequest) async throws
    func cancelRecording() async throws
    func stopRecording(in directoryURL: URL, fileLayout: RecordingFileLayout) async throws -> RecordingCapture
    func currentMeterLevel() async -> Double
    func recordingFileLayout(for source: RecordingSource) async -> RecordingFileLayout
    func supportsLiveTranscription(for source: RecordingSource) async -> Bool
    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async
    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async
    func setLiveTranscriptionPreset(_ preset: LiveTranscriptionPreset) async
    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview?
    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>?
}

protocol TranscriptionService: Sendable {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setVocabularyBoostingConfiguration(_ configuration: VocabularyBoostingConfiguration) async
    func setBatchTranscriptionConfiguration(_ configuration: BatchTranscriptionConfiguration) async
    func transcribe(url: URL, sessionTitle: String, source: RecordingSource) async throws -> TranscriptionResult
}

protocol SpeakerDiarizationService: Sendable {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws
    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async
    func setDiarizationEngine(_ engine: DiarizationEngine) async
    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint,
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
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
