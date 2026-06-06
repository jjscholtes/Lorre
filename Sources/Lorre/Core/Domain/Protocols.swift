import Foundation

protocol SessionStore: Sendable {
    func loadSessions() async throws -> [SessionManifest]
    func loadSession(id: UUID) async throws -> SessionManifest?
    func createSession(_ draft: NewSessionDraft) async throws -> SessionManifest
    func updateSession(_ session: SessionManifest) async throws
    func updateSession(
        id: UUID,
        _ transform: @Sendable (inout SessionManifest) throws -> Void
    ) async throws -> SessionManifest
    func deleteSession(id: UUID) async throws
    func loadTranscript(sessionId: UUID) async throws -> TranscriptDocument?
    func saveTranscript(_ transcript: TranscriptDocument) async throws
    func sessionDirectoryURL(for sessionId: UUID) async -> URL
    func exportDirectoryURL(for sessionId: UUID) async -> URL
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
    var onPlaybackFinished: (@Sendable () -> Void)? { get set }
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

protocol CallWatcherService: Sendable {
    func makeDetectionStream(configuration: CallWatcherConfiguration) async -> AsyncStream<CallDetectionEvent>
    func suppressPrompt(for candidate: CallDetectionCandidate, cooldownSeconds: Int) async
}

enum CallPromptNotificationAction: Equatable, Sendable {
    case accept(fingerprint: String)
    case dismiss(fingerprint: String)
    case disable(fingerprint: String)
}

protocol CallPromptNotificationService: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func showCallPrompt(for candidate: CallDetectionCandidate) async -> Bool
    func removeCallPrompt(fingerprint: String) async
    func makeActionStream() async -> AsyncStream<CallPromptNotificationAction>
}

protocol GlobalDictationHotKeyService: AnyObject, Sendable {
    func register(
        shortcut: GlobalDictationShortcutChoice,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws

    func unregister()
}

protocol GlobalTextInsertionService: Sendable {
    @MainActor
    func prepareTarget(promptForPermission: Bool) -> GlobalTextInsertionPreparation

    @MainActor
    func insert(_ text: String, into target: GlobalTextInsertionTarget) async -> GlobalTextInsertionResult

    @MainActor
    func copyToClipboard(_ text: String)
}
