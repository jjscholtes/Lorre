import Foundation
import Testing
@testable import Lorre

private func issueSourceLocation(
    fileID: String,
    filePath: String,
    line: Int,
    column: Int
) -> SourceLocation {
    SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
}

private func assertionMessage(
    _ assertion: String,
    _ detail: String,
    _ message: String
) -> Comment {
    let suffix = message.isEmpty ? "" : ": \(message)"
    return Comment(rawValue: "\(assertion) failed: \(detail)\(suffix)")
}

func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    let value1 = try expression1()
    let value2 = try expression2()
    if value1 != value2 {
        Issue.record(
            assertionMessage("XCTAssertEqual", "\(String(describing: value1)) is not equal to \(String(describing: value2))", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    if try !expression() {
        Issue.record(
            assertionMessage("XCTAssertTrue", "expression is false", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    if try expression() {
        Issue.record(
            assertionMessage("XCTAssertFalse", "expression is true", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    let value = try expression()
    if value != nil {
        Issue.record(
            assertionMessage("XCTAssertNil", "\(String(describing: value)) is not nil", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    let value = try expression()
    if value == nil {
        Issue.record(
            assertionMessage("XCTAssertNotNil", "expression is nil", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    let value1 = try expression1()
    let value2 = try expression2()
    if value1 > value2 {
        Issue.record(
            assertionMessage("XCTAssertLessThanOrEqual", "\(String(describing: value1)) is greater than \(String(describing: value2))", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) rethrows {
    let value1 = try expression1()
    let value2 = try expression2()
    if value1 < value2 {
        Issue.record(
            assertionMessage("XCTAssertGreaterThanOrEqual", "\(String(describing: value1)) is less than \(String(describing: value2))", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }
}

func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) {
    do {
        _ = try expression()
        Issue.record(
            assertionMessage("XCTAssertThrowsError", "expression did not throw", message()),
            sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    } catch {
        return
    }
}

func XCTFail(
    _ message: @autoclosure () -> String = "",
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
) {
    Issue.record(
        assertionMessage("XCTFail", "failure recorded", message()),
        sourceLocation: issueSourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
}

actor ControlledRecorderService: RecorderService {
    enum StopBehavior: Sendable {
        case succeed
        case failure(String)
    }

    private let startDelay: Duration
    private let stopBehavior: StopBehavior
    private let supportBySource: [RecordingSource: Bool]
    private let supportDelayBySource: [RecordingSource: Duration]
    private(set) var startCallCount = 0
    private(set) var lastStartRequest: RecordingRequest?
    private var startedAt: Date?
    private var activeSource: RecordingSource = .microphone

    init(
        startDelay: Duration = .zero,
        stopBehavior: StopBehavior = .succeed,
        supportBySource: [RecordingSource: Bool] = [:],
        supportDelayBySource: [RecordingSource: Duration] = [:]
    ) {
        self.startDelay = startDelay
        self.stopBehavior = stopBehavior
        self.supportBySource = supportBySource
        self.supportDelayBySource = supportDelayBySource
    }

    func startRecording(_ request: RecordingRequest) async throws {
        startCallCount += 1
        lastStartRequest = request
        guard startedAt == nil else {
            throw LorreError.recordingStartFailed("A recording is already active.")
        }
        if startDelay > .zero {
            try? await Task.sleep(for: startDelay)
        }
        startedAt = Date()
        activeSource = request.source
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
        self.startedAt = nil

        switch stopBehavior {
        case let .failure(message):
            throw LorreError.recordingStopFailed(message)
        case .succeed:
            let endedAt = Date()
            let duration = max(0.5, endedAt.timeIntervalSince(startedAt))
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: directoryURL.appendingPathComponent(fileLayout.audioFileName))
            if activeSource == .microphoneAndSystemAudio {
                if let microphoneStemFileName = fileLayout.microphoneStemFileName {
                    try Data("mic".utf8).write(to: directoryURL.appendingPathComponent(microphoneStemFileName))
                }
                if let systemAudioStemFileName = fileLayout.systemAudioStemFileName {
                    try Data("sys".utf8).write(to: directoryURL.appendingPathComponent(systemAudioStemFileName))
                }
            }
            return RecordingCapture(startedAt: startedAt, endedAt: endedAt, durationSeconds: duration)
        }
    }

    func currentMeterLevel() async -> Double { 0.12 }

    func recordingFileLayout(for source: RecordingSource) async -> RecordingFileLayout {
        switch source {
        case .microphone, .systemAudio:
            return RecordingFileLayout(audioFileName: "audio.caf", microphoneStemFileName: nil, systemAudioStemFileName: nil)
        case .microphoneAndSystemAudio:
            return RecordingFileLayout(
                audioFileName: "audio.caf",
                microphoneStemFileName: "microphone.caf",
                systemAudioStemFileName: "system-audio.caf"
            )
        }
    }

    func supportsLiveTranscription(for source: RecordingSource) async -> Bool {
        if let delay = supportDelayBySource[source], delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return supportBySource[source] ?? false
    }

    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        _ = onProgress
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        _ = speakers
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async {
        _ = isEnabled
    }

    func setLiveTranscriptionPreset(_ preset: LiveTranscriptionPreset) async {
        _ = preset
    }

    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview? { nil }

    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>? { nil }
}

actor TestSpeakerEnrollmentService: SpeakerEnrollmentService {
    private(set) var ensureModelsReadyCallCount = 0
    private(set) var makeEnrollmentCallCount = 0
    private(set) var extractEmbeddingCallCount = 0

    func snapshotEnsureModelsReadyCallCount() -> Int {
        ensureModelsReadyCallCount
    }

    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        ensureModelsReadyCallCount += 1
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .speakerEnrollment,
                    label: "Speaker enrollment ready",
                    detail: "Test speaker enrollment service is ready.",
                    fraction: 1.0
                )
            )
        }
    }

    func makeEnrollment(from audioURL: URL) async throws -> KnownSpeakerEnrollmentData {
        _ = audioURL
        makeEnrollmentCallCount += 1
        return KnownSpeakerEnrollmentData(
            embedding: [0.1, 0.2, 0.3],
            durationSeconds: 1.0,
            sampleRate: 16_000
        )
    }

    func extractEmbedding(from audioSamples: [Float]) async throws -> [Float] {
        _ = audioSamples
        extractEmbeddingCallCount += 1
        return [0.1, 0.2, 0.3]
    }
}

final class TestPlaybackService: AudioPlaybackService {
    var onPlaybackFinished: (@Sendable () -> Void)?
    var preparedURL: URL?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    var isPlaying: Bool = false
    var playbackRate: Double = 1.0

    func prepare(url: URL) throws {
        preparedURL = url
    }

    func play() throws {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        currentTimeSeconds = 0
    }

    func seek(to seconds: Double) {
        currentTimeSeconds = seconds
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
    }
}

final class TestGlobalDictationHotKeyService: GlobalDictationHotKeyService, @unchecked Sendable {
    private(set) var registeredShortcut: GlobalDictationShortcutChoice?
    private var handler: (@MainActor @Sendable () -> Void)?
    var shouldFailRegistration = false

    func register(
        shortcut: GlobalDictationShortcutChoice,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {
        if shouldFailRegistration {
            throw LorreError.persistenceFailed("Shortcut unavailable.")
        }
        registeredShortcut = shortcut
        self.handler = handler
    }

    func unregister() {
        registeredShortcut = nil
        handler = nil
    }

    func fire() {
        Task { @MainActor in
            self.handler?()
        }
    }
}

@MainActor
final class TestGlobalTextInsertionService: GlobalTextInsertionService {
    var preparation: GlobalTextInsertionPreparation = .ready(
        GlobalTextInsertionTarget(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 42,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
    )
    var insertionResult: GlobalTextInsertionResult = .inserted
    private(set) var insertedText: String?
    private(set) var copiedText: String?

    func prepareTarget(promptForPermission: Bool) -> GlobalTextInsertionPreparation {
        _ = promptForPermission
        return preparation
    }

    func insert(_ text: String, into target: GlobalTextInsertionTarget) async -> GlobalTextInsertionResult {
        _ = target
        insertedText = text
        return insertionResult
    }

    func copyToClipboard(_ text: String) {
        copiedText = text
    }
}

final class TestCallWatcherService: CallWatcherService, @unchecked Sendable {
    private var continuation: AsyncStream<CallDetectionEvent>.Continuation?
    var isSubscribed: Bool {
        continuation != nil
    }

    func makeDetectionStream(configuration: CallWatcherConfiguration) async -> AsyncStream<CallDetectionEvent> {
        _ = configuration
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ event: CallDetectionEvent) {
        continuation?.yield(event)
    }
}

final class TestCallPromptNotificationService: CallPromptNotificationService, @unchecked Sendable {
    private var actionContinuation: AsyncStream<CallPromptNotificationAction>.Continuation?
    var authorizationRequestCount = 0
    var shownCandidates: [CallDetectionCandidate] = []
    var removedFingerprints: [String] = []
    var isActionStreamSubscribed: Bool {
        actionContinuation != nil
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequestCount += 1
        return true
    }

    func showCallPrompt(for candidate: CallDetectionCandidate) async -> Bool {
        shownCandidates.append(candidate)
        return true
    }

    func removeCallPrompt(fingerprint: String) async {
        removedFingerprints.append(fingerprint)
    }

    func makeActionStream() async -> AsyncStream<CallPromptNotificationAction> {
        AsyncStream { continuation in
            self.actionContinuation = continuation
        }
    }

    func emit(_ action: CallPromptNotificationAction) {
        actionContinuation?.yield(action)
    }
}

actor ProcessingUpdateCollector {
    private var updates: [ProcessingUpdate] = []

    func append(_ update: ProcessingUpdate) {
        updates.append(update)
    }

    func snapshot() -> [ProcessingUpdate] {
        updates
    }
}

func makeTemporaryRoot(named prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

func makeTestDependencies(
    root: URL,
    store: FileSessionStore? = nil,
    recorder: any RecorderService,
    transcription: any TranscriptionService = MockTranscriptionService(),
    diarization: any SpeakerDiarizationService = MockSpeakerDiarizationService(),
    speakerEnrollment: any SpeakerEnrollmentService = TestSpeakerEnrollmentService(),
    callWatcher: any CallWatcherService = DisabledCallWatcherService(),
    callPromptNotifications: any CallPromptNotificationService = DisabledCallPromptNotificationService(),
    globalDictationHotKey: any GlobalDictationHotKeyService = TestGlobalDictationHotKeyService(),
    globalTextInsertion: any GlobalTextInsertionService = TestGlobalTextInsertionService(),
    runtimeCapabilities: RuntimeCapabilities = .mock,
    fluidAudioStatus: String = "Test runtime",
    modelPreparationComponentsSummary: String = "Test components"
) -> AppDependencies {
    let sessionStore = store ?? FileSessionStore(baseURL: root)
    let knownSpeakerStore = KnownSpeakerStore(baseURL: root)
    let settings = AppSettingsStore(baseURL: root)
    let coordinator = ProcessingCoordinator(
        store: sessionStore,
        transcriptionService: transcription,
        diarizationService: diarization
    )
    return AppDependencies(
        store: sessionStore,
        knownSpeakerStore: knownSpeakerStore,
        settings: settings,
        recorder: recorder,
        transcription: transcription,
        diarization: diarization,
        speakerEnrollment: speakerEnrollment,
        playback: TestPlaybackService(),
        exporter: MarkdownExportService(),
        callWatcher: callWatcher,
        callPromptNotifications: callPromptNotifications,
        globalDictationHotKey: globalDictationHotKey,
        globalTextInsertion: globalTextInsertion,
        processingCoordinator: coordinator,
        metrics: LocalMetricsLogger(baseURL: root),
        fluidAudioStatus: fluidAudioStatus,
        runtimeCapabilities: runtimeCapabilities,
        modelPreparationComponentsSummary: modelPreparationComponentsSummary
    )
}

func waitUntil(
    timeout: Duration = .seconds(2),
    pollingInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollingInterval)
    }
    XCTFail("Timed out waiting for condition")
    throw LorreError.persistenceFailed("Timed out waiting for condition")
}
