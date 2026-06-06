import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    static let unfiledFolderSelectionID = "__UNFILED__"

    @Published private(set) var sessions: [SessionManifest] = [] {
        didSet { rebuildDerivedSessionStateIfNeeded() }
    }
    @Published private(set) var folders: [SessionFolder] = [] {
        didSet { rebuildDerivedSessionStateIfNeeded() }
    }
    @Published var searchQuery: String = "" {
        didSet { rebuildDerivedSessionStateIfNeeded() }
    }
    @Published var selectedFilter: ShelfFilter = .all {
        didSet { rebuildDerivedSessionStateIfNeeded() }
    }
    @Published var selectedFolderID: String? {
        didSet { rebuildDerivedSessionStateIfNeeded() }
    }
    @Published var selectedSessionID: UUID?
    @Published var expandedViewFilters: Set<ShelfFilter> = [.all]
    @Published var expandedFolderIDs: Set<String> = [AppViewModel.unfiledFolderSelectionID]
    @Published private(set) var activeTranscript: TranscriptDocument?
    @Published private(set) var isLoading = true
    @Published private(set) var isRecording = false
    @Published private(set) var isStartingRecording = false
    @Published private(set) var isStoppingRecording = false
    @Published private(set) var recordingElapsedSeconds: Double = 0
    @Published private(set) var liveMeterSamples: [Double] = Array(repeating: 0.08, count: 28)
    @Published private(set) var recorderStatusText: String = "Ready to record"
    @Published var banner: AppBanner?
    @Published private(set) var exportMessage: String?
    @Published private(set) var isAudioPlaying = false
    @Published private(set) var playbackCurrentSeconds: Double = 0
    @Published private(set) var playbackDurationSeconds: Double = 0
    @Published private(set) var playbackRate: Double = 1.0
    @Published private(set) var playbackWaveformBins: [Double] = []
    @Published private(set) var isPlaybackWaveformLoading = false
    @Published private(set) var activePlaybackSegmentID: UUID?
    @Published private(set) var fluidAudioStatus: String
    @Published private(set) var runtimeCapabilities: RuntimeCapabilities
    @Published private(set) var modelPreparationState: ModelPreparationState = .unknown
    @Published private(set) var modelPreparationStatusLine: String = "Models not prepared yet"
    @Published private(set) var modelPreparationDetailLine: String = "Models may download on first transcription."
    @Published private(set) var modelPreparationProgress: Double?
    @Published private(set) var modelPreparationLastPreparedAt: Date?
    @Published var modelRegistryCustomBaseURL: String = ""
    @Published private(set) var isSpeakerDiarizationEnabled: Bool = true
    @Published private(set) var diarizationEngine: DiarizationEngine = .offlineVbx
    @Published private(set) var diarizationExpectedSpeakerCountHint: DiarizationSpeakerCountHint = .auto
    @Published private(set) var isDiarizationDebugExportEnabled: Bool = false
    @Published private(set) var isVocabularyBoostingEnabled: Bool = false
    @Published var customVocabularySimpleFormatTerms: String = ""
    @Published private(set) var batchTranscriptionConfiguration = BatchTranscriptionConfiguration()
    @Published private(set) var liveTranscriptionPreset: LiveTranscriptionPreset = .balanced
    @Published private(set) var selectedRecordingSource: RecordingSource = .microphone
    @Published private(set) var isLiveTranscriptionSupported: Bool = false
    @Published private(set) var isLiveTranscriptionEnabled: Bool = false
    @Published private(set) var isDeleteAudioAfterTranscriptionEnabled: Bool = false
    @Published private(set) var isTranscriptConfidenceVisible: Bool = false
    @Published private(set) var automaticMarkdownExportConfiguration = AutomaticMarkdownExportConfiguration()
    @Published var automaticMarkdownExportFileNameTemplate = AutomaticMarkdownExportConfiguration.defaultFileNameTemplate
    @Published private(set) var callWatcherConfiguration = CallWatcherConfiguration()
    @Published private(set) var callWatcherStatusLine: String = "Off"
    @Published private(set) var callPromptCandidate: CallDetectionCandidate?
    @Published private(set) var globalDictationConfiguration = GlobalDictationConfiguration()
    @Published private(set) var globalDictationPhase: GlobalDictationPhase = .idle
    @Published private(set) var globalDictationElapsedSeconds: Double = 0
    @Published private(set) var globalDictationMeterSamples: [Double] = Array(repeating: 0.08, count: 28)
    @Published private(set) var globalDictationTranscriptText: String = ""
    @Published private(set) var globalDictationTargetLabel: String?
    @Published private(set) var globalDictationStatusLine: String = "Ready"
    @Published private(set) var liveTranscriptPreview: LiveTranscriptPreview?
    @Published private(set) var knownSpeakers: [KnownSpeaker] = []
    @Published var knownSpeakerDraftName: String = ""
    @Published private(set) var knownSpeakerLibraryStatusLine: String = "No known speakers enrolled yet."
    @Published private(set) var knownSpeakerOperationDescription: String?
    @Published private(set) var isKnownSpeakerOperationInFlight = false
    @Published private(set) var processingProgressSnapshots: [UUID: ProcessingSummary] = [:]

    private let dependencies: AppDependencies
    private var started = false
    private var recordingClockTask: Task<Void, Never>?
    private var liveMeterTask: Task<Void, Never>?
    private var callWatcherTask: Task<Void, Never>?
    private var callPromptNotificationTask: Task<Void, Never>?
    private var globalDictationClockTask: Task<Void, Never>?
    private var globalDictationMeterTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var waveformLoadTask: Task<Void, Never>?
    private var recordingSourceChangeTask: Task<Void, Never>?
    private var currentRecordingStartedAt: Date?
    private var activeRecordingSource: RecordingSource?
    private var currentGlobalDictationStartedAt: Date?
    private var currentGlobalDictationTarget: GlobalTextInsertionTarget?
    private var callPromptCandidatesByFingerprint: [String: CallDetectionCandidate] = [:]
    private var handledCallPromptActionFingerprints: Set<String> = []
    private var currentProcessingTasks: [UUID: Task<Void, Never>] = [:]
    private var currentProcessingTaskTokens: [UUID: UUID] = [:]
    private let transcriptPersistenceQueue = TranscriptPersistenceQueue()
    private var transcriptPersistenceVersions: [UUID: Int] = [:]
    private var cachedFilteredSessions: [SessionManifest] = []
    private var cachedViewBrowserSessions: [ShelfFilter: [SessionManifest]] = [:]
    private var cachedFolderBrowserSessions: [String: [SessionManifest]] = [:]
    private var cachedAllFolderBrowserSessions: [SessionManifest] = []
    private var cachedViewCounts: [ShelfFilter: Int] = [:]
    private var sidebarExpansionSaveTask: Task<Void, Never>?
    private var waveformCache: [UUID: [Double]] = [:]
    private var isBatchingDerivedSessionState = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.fluidAudioStatus = dependencies.fluidAudioStatus
        self.runtimeCapabilities = dependencies.runtimeCapabilities
        self.playbackRate = dependencies.playback.playbackRate
        self.modelPreparationState = .idle
        if dependencies.runtimeCapabilities.usesMockPipeline {
            self.modelPreparationStatusLine = "Mock processing pipeline active"
            self.modelPreparationDetailLine = "Model preparation completes instantly in mock mode."
        }
    }

    deinit {
        recordingClockTask?.cancel()
        liveMeterTask?.cancel()
        callWatcherTask?.cancel()
        callPromptNotificationTask?.cancel()
        globalDictationClockTask?.cancel()
        globalDictationMeterTask?.cancel()
        playbackMonitorTask?.cancel()
        waveformLoadTask?.cancel()
        recordingSourceChangeTask?.cancel()
        sidebarExpansionSaveTask?.cancel()
        currentProcessingTasks.values.forEach { $0.cancel() }
    }

    func start() async {
        guard !started else { return }
        started = true
        dependencies.playback.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
        await refreshLiveTranscriptionSupport(for: selectedRecordingSource)
        await restoreModelPreparationStateFromSettings()
        registerGlobalDictationHotKeyIfNeeded()
        startCallPromptNotificationActions()
        startCallWatcherIfNeeded()
        await reloadKnownSpeakers()
        await reloadFolders()
        await reloadSessions(selectMostRecentIfNeeded: true)
        isLoading = false
        await dependencies.metrics.log(name: "app_opened", attributes: ["fluid_audio": fluidAudioStatus])
    }

    var filteredSessions: [SessionManifest] { cachedFilteredSessions }

    var modelRegistrySummaryLabel: String {
        currentModelRegistryConfiguration().summaryLabel
    }

    var isCustomModelRegistryConfigured: Bool {
        !currentModelRegistryConfiguration().isDefault
    }

    var isAutomaticMarkdownExportEnabled: Bool {
        automaticMarkdownExportConfiguration.isEnabled
    }

    var hasAutomaticMarkdownExportFolder: Bool {
        automaticMarkdownExportConfiguration.hasFolder
    }

    var automaticMarkdownExportFolderLabel: String {
        automaticMarkdownExportConfiguration.folderDisplayName
    }

    var automaticMarkdownExportFolderPath: String? {
        automaticMarkdownExportConfiguration.folderPath
    }

    var automaticMarkdownExportSummary: String {
        if automaticMarkdownExportConfiguration.isEnabled {
            return "Writes a Markdown copy after each transcript finishes."
        }
        if automaticMarkdownExportConfiguration.hasFolder {
            return "Folder selected. Turn on automatic Markdown export to use it."
        }
        return "Choose a folder to enable automatic Markdown export."
    }

    var automaticMarkdownExportFileNamePreview: String {
        if let session = selectedSession, let transcript = activeTranscript {
            return AutomaticExportFileNameBuilder.fileName(
                session: session,
                transcript: transcript,
                template: automaticMarkdownExportFileNameTemplate
            )
        }
        return AutomaticExportFileNameBuilder.previewFileName(
            template: automaticMarkdownExportFileNameTemplate
        )
    }

    var automaticMarkdownExportTemplateSummary: String {
        "Tokens: {date}, {time}, {datetime}, {smart_title}, {keywords}, {session_title}, {speaker_count}, {language}."
    }

    var isCallWatcherEnabled: Bool {
        callWatcherConfiguration.isEnabled
    }

    var callWatcherDefaultSourceLabel: String {
        callWatcherConfiguration.defaultRecordingSource.label
    }

    var callWatcherSummary: String {
        if callWatcherConfiguration.isEnabled {
            return callWatcherStatusLine
        }
        return "Off. Enable it to get a prompt when Lorre sees likely call activity."
    }

    var callPromptDetail: String {
        guard let candidate = callPromptCandidate else { return "" }
        return "Likely call in \(candidate.appDisplayName). Start \(candidate.recommendedRecordingSource.label.lowercased()) recording?"
    }

    var isGlobalDictationEnabled: Bool {
        globalDictationConfiguration.isEnabled
    }

    var globalDictationShortcutChoices: [GlobalDictationShortcutChoice] {
        [.optionShiftD, .optionShiftSpace, .commandOptionShiftD]
    }

    var globalDictationShortcutLabel: String {
        globalDictationConfiguration.shortcut.label
    }

    var globalDictationSummary: String {
        if globalDictationConfiguration.isEnabled {
            return "Press \(globalDictationShortcutLabel) in another app to dictate into the focused text field."
        }
        return "Off. Enable it to dictate short snippets into other macOS apps."
    }

    var isGlobalDictationBusy: Bool {
        globalDictationPhase.isBusy
    }

    var isGlobalDictationOverlayVisible: Bool {
        globalDictationPhase != .idle
    }

    var globalDictationTitle: String {
        switch globalDictationPhase {
        case .idle:
            return "Global Dictation"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .inserting:
            return "Inserting text"
        case .inserted:
            return "Text inserted"
        case .failed:
            return "Dictation needs attention"
        }
    }

    var globalDictationDetail: String {
        switch globalDictationPhase {
        case .idle:
            return globalDictationSummary
        case .listening:
            return "Dictating for \(globalDictationTargetLabel ?? "focused app"). Press \(globalDictationShortcutLabel) again or choose Stop to insert."
        case .transcribing:
            return globalDictationStatusLine
        case .inserting:
            return "Sending text to \(globalDictationTargetLabel ?? "focused app")."
        case .inserted:
            return "Inserted into \(globalDictationTargetLabel ?? "the focused text field")."
        case .failed:
            if globalDictationTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return globalDictationStatusLine
            }
            return "\(globalDictationStatusLine) The dictated text is still available to copy."
        }
    }

    var customVocabularyTermLineCount: Int {
        VocabularyBoostingConfiguration(simpleFormatTerms: customVocabularySimpleFormatTerms)
            .simpleFormatEntries
            .count
    }

    var selectedSession: SessionManifest? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var hasActiveRecording: Bool {
        isRecording || isStoppingRecording
    }

    var isLiveEngineSelectionLocked: Bool {
        isStartingRecording || isRecording || isStoppingRecording || isGlobalDictationBusy
    }

    var isBrowsingArchivedSessionWhileRecording: Bool {
        hasActiveRecording && selectedSession != nil
    }

    var workStageRoute: WorkStageRoute {
        Self.makeWorkStageRoute(selectedSession: selectedSession)
    }

    var recorderShelfActionLabel: String {
        if hasActiveRecording {
            return selectedSession == nil ? "Recorder Open" : "Open Recorder"
        }
        if isStartingRecording {
            return "Starting…"
        }
        return "New Recording"
    }

    var activeRecordingHeadline: String {
        if isStoppingRecording {
            return "Finalizing active recording"
        }
        return "Active recording"
    }

    var activeRecordingDetail: String {
        if isStoppingRecording {
            return "Lorre is closing the capture and preparing a new session."
        }
        if selectedSession != nil {
            return "Capture stays live while you review archived recordings or export finished transcripts."
        }
        return "Capture is live. You can open older recordings without stopping."
    }

    var activeRecordingSourceBadge: String {
        (activeRecordingSource ?? selectedRecordingSource).shortLabel.uppercased()
    }

    var hasReadyTranscriptStage: Bool {
        if let session = selectedSession {
            return session.status == .ready || session.status == .error
        }
        return false
    }

    var visibleStageTitle: String {
        if hasActiveRecording && selectedSession == nil { return "Recorder" }
        if let session = selectedSession { return session.displayTitle }
        return "Recorder"
    }

    var visibleStageStatusLine: String {
        if isStartingRecording {
            return "Starting capture…"
        }
        if isRecording {
            return "Recording live • audio is stored locally"
        }
        if isStoppingRecording {
            return "Stopping capture and preparing session…"
        }
        if let session = selectedSession {
            if session.status == .processing {
                return processingSummary(for: session).progressLabel ?? "Processing"
            }
            if session.status == .error {
                return session.lastErrorMessage ?? "Processing failed"
            }
            if session.status == .ready {
                if !session.hasRetainedAudio {
                    return "Transcript ready • source audio deleted for privacy"
                }
                return activeTranscript?.segments.isEmpty == false
                    ? "Transcript ready for review"
                    : "Session ready"
            }
            return session.status.label
        }
        return recorderStatusText
    }

    var canControlPlayback: Bool {
        guard !isStartingRecording, !isRecording, !isStoppingRecording else { return false }
        guard let session = selectedSession else { return false }
        guard session.hasRetainedAudio else { return false }
        return session.status == .ready || session.status == .error
    }

    var playbackProgressFraction: Double {
        guard playbackDurationSeconds > 0 else { return 0 }
        return min(max(playbackCurrentSeconds / playbackDurationSeconds, 0), 1)
    }

    var playbackTimeLine: String {
        let current = Formatters.duration(playbackCurrentSeconds)
        let total = Formatters.duration(playbackDurationSeconds)
        return "\(current) / \(total)"
    }

    var playbackRateLabel: String {
        switch playbackRate {
        case 0.75:
            return "0.75x"
        case 1.25:
            return "1.25x"
        case 1.5:
            return "1.5x"
        default:
            return "1.0x"
        }
    }

    static func makeWorkStageRoute(selectedSession: SessionManifest?) -> WorkStageRoute {
        guard let session = selectedSession else { return .recorder }
        if session.status == .processing {
            return .processing(session.id)
        }
        return .transcript(session.id)
    }

    static func makeCuePlaybackPresentation(
        hasRetainedAudio: Bool,
        canControlPlayback: Bool,
        hasActiveRecording: Bool
    ) -> CuePlaybackPresentation {
        if !hasRetainedAudio {
            return CuePlaybackPresentation(
                statusLabel: "Playback unavailable",
                description: "Privacy Mode deleted the source audio for this session, so cue playback is unavailable.",
                iconName: "lock.fill"
            )
        }
        if hasActiveRecording {
            return CuePlaybackPresentation(
                statusLabel: "Playback paused during recording",
                description: "Stop the active recording before cueing or playing archived audio from this session.",
                iconName: "record.circle.fill"
            )
        }
        if !canControlPlayback {
            return CuePlaybackPresentation(
                statusLabel: "Cue Playback",
                description: "Cue playback becomes available once the session is ready.",
                iconName: "clock.fill"
            )
        }
        return CuePlaybackPresentation(
            statusLabel: "Cue Playback",
            description: "Click a fragment or timestamp to play from that point.",
            iconName: "play.fill"
        )
    }

    func sessionActions(
        for surface: SessionActionSurface,
        session: SessionManifest,
        transcript: TranscriptDocument? = nil
    ) -> [SessionActionState] {
        let actions: [SessionAction]
        switch surface {
        case .shelfContextMenu:
            actions = session.status == .error
                ? [.revealFiles, .retryProcessing, .rename, .moveToFolder, .delete]
                : [.revealFiles, .rename, .moveToFolder, .delete]
        case .transcriptHeader:
            actions = session.status == .error
                ? [.moveToFolder, .revealFiles, .retryProcessing, .rename, .delete, .exportTranscript]
                : [.moveToFolder, .revealFiles, .rename, .delete, .exportTranscript]
        case .processingStage:
            actions = [.revealFiles]
        case .errorState:
            actions = [.retryProcessing, .revealFiles, .delete]
        }
        return actions.map { sessionActionState($0, for: session, transcript: transcript) }
    }

    func sessionActionState(
        _ action: SessionAction,
        for session: SessionManifest,
        transcript: TranscriptDocument? = nil
    ) -> SessionActionState {
        let exists = sessions.contains(where: { $0.id == session.id })
        guard exists else {
            return SessionActionState(action: action, isEnabled: false, disabledReason: "Session is no longer available.")
        }

        switch action {
        case .moveToFolder, .revealFiles, .rename, .delete:
            return SessionActionState(action: action, isEnabled: true, disabledReason: nil)
        case .retryProcessing:
            guard session.status == .error else {
                return SessionActionState(action: action, isEnabled: false, disabledReason: "Only failed sessions can be retried.")
            }
            guard session.hasRetainedAudio else {
                return SessionActionState(action: action, isEnabled: false, disabledReason: "Source audio was deleted for this session.")
            }
            return SessionActionState(action: action, isEnabled: true, disabledReason: nil)
        case .exportTranscript:
            guard session.status == .ready else {
                return SessionActionState(action: action, isEnabled: false, disabledReason: "Export is available after processing completes.")
            }
            guard transcript != nil else {
                return SessionActionState(action: action, isEnabled: false, disabledReason: "No transcript is loaded for export.")
            }
            return SessionActionState(action: action, isEnabled: true, disabledReason: nil)
        }
    }

    func canPerformSessionAction(
        _ action: SessionAction,
        for session: SessionManifest,
        transcript: TranscriptDocument? = nil
    ) -> Bool {
        sessionActionState(action, for: session, transcript: transcript).isEnabled
    }

    func performSessionAction(_ action: SessionAction, for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let state = sessionActionState(action, for: session, transcript: activeTranscript)
        guard state.isEnabled else { return }

        switch action {
        case .revealFiles:
            revealFiles(for: sessionID)
        case .retryProcessing:
            retryProcessing(sessionID)
        case .delete:
            deleteSession(sessionID)
        case .exportTranscript:
            if selectedSessionID != sessionID {
                selectSession(session)
                return
            }
            exportSelectedSessionWithDefaultShortcut()
        case .moveToFolder, .rename:
            break
        }
    }

    func count(for filter: ShelfFilter) -> Int {
        cachedViewCounts[filter] ?? 0
    }

    func countForFolder(_ folderID: String?) -> Int {
        sessionsForFolderBrowser(folderID).count
    }

    func folderName(for folderID: String?) -> String {
        guard let folderID else { return "Unfiled" }
        return folders.first(where: { $0.id == folderID })?.name ?? folderID
    }

    func sessionsForFolderBrowser(_ folderID: String?) -> [SessionManifest] {
        guard let folderID else { return cachedAllFolderBrowserSessions }
        return cachedFolderBrowserSessions[folderID] ?? []
    }

    func sessionsForViewBrowser(_ filter: ShelfFilter) -> [SessionManifest] {
        cachedViewBrowserSessions[filter] ?? []
    }

    func toggleSidebarViewExpansion(_ filter: ShelfFilter) {
        if expandedViewFilters.contains(filter) {
            expandedViewFilters.remove(filter)
        } else {
            expandedViewFilters.insert(filter)
        }
        persistSidebarExpansionState()
    }

    func toggleSidebarFolderExpansion(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
        persistSidebarExpansionState()
    }

    func selectFolderFilter(_ folderID: String?) {
        // "Open folder" should feel deterministic: show the folder contents, not a stale
        // status/search-filtered view from a previous shelf state.
        isBatchingDerivedSessionState = true
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchQuery = ""
        }
        selectedFilter = .all
        selectedFolderID = folderID
        isBatchingDerivedSessionState = false
        rebuildDerivedSessionState()

        let sessionsInFolder = sessions.filter { session in
            if let folderID {
                if folderID == Self.unfiledFolderSelectionID {
                    return session.folderId == nil
                }
                return session.folderId == folderID
            }
            return true
        }

        if let current = selectedSession, sessionsInFolder.contains(where: { $0.id == current.id }) {
            return
        }
        // Folder selection should reveal the list, not force-open a recording.
        selectSession(nil)
    }

    func openFolderForSelectedSession() {
        guard let session = selectedSession else { return }
        let targetFolderID = session.folderId ?? Self.unfiledFolderSelectionID
        selectFolderFilter(targetFolderID)
        banner = nil
        exportMessage = nil

        Task { [dependencies] in
            await dependencies.metrics.log(
                name: "folder_opened_from_session",
                sessionId: session.id,
                attributes: ["folder_id": targetFolderID]
            )
        }
    }

    func moveSession(_ sessionID: UUID, to folderID: String?) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard session.folderId != folderID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let updatedSession = try await self.dependencies.store.updateSession(id: sessionID) { session in
                    session.folderId = folderID
                    session.updatedAt = Date()
                }
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    if self.selectedSessionID == updatedSession.id {
                        self.selectedSessionID = updatedSession.id
                    }
                    let label = self.folderName(for: folderID)
                    self.banner = AppBanner(kind: .success, title: "Moved to folder", message: "\(updatedSession.displayTitle) → \(label)")
                }
                await self.dependencies.metrics.log(
                    name: "session_moved_to_folder",
                    sessionId: updatedSession.id,
                    attributes: ["folder_id": folderID ?? "unfiled"]
                )
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Move to folder failed")
                }
                await self.dependencies.metrics.log(
                    name: "session_move_to_folder_failed",
                    sessionId: session.id,
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func selectSession(_ session: SessionManifest?) {
        stopPlaybackAndResetState()
        liveTranscriptPreview = nil
        selectedSessionID = session?.id
        banner = nil
        exportMessage = nil
        startWaveformLoading(for: session)
        if let session {
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "session_opened",
                    sessionId: session.id,
                    attributes: ["status": session.status.rawValue]
                )
            }
        }
        Task {
            await loadTranscriptForSelectedSession()
        }
    }

    func showRecorderScreenTapped() {
        selectSession(nil)
    }

    func startRecordingTapped() {
        startRecording(source: selectedRecordingSource, startReason: "manual")
    }

    func acceptCallPromptTapped() {
        guard let candidate = callPromptCandidate else { return }
        guard claimCallPromptAction(for: candidate) else { return }
        callWatcherStatusLine = "Recording from call prompt"
        startRecording(source: candidate.recommendedRecordingSource, startReason: "call_prompt")
        Task { [dependencies] in
            await dependencies.metrics.log(
                name: "call_prompt_accepted",
                attributes: [
                    "app": candidate.appDisplayName,
                    "confidence": "\(candidate.confidenceScore)",
                    "source": candidate.recommendedRecordingSource.rawValue
                ]
            )
        }
    }

    func dismissCallPromptTapped() {
        guard let candidate = callPromptCandidate else { return }
        guard claimCallPromptAction(for: candidate) else { return }
        callWatcherStatusLine = callWatcherConfiguration.isEnabled ? "Dismissed. Listening for a new call." : "Off"
        Task { [dependencies, cooldownSeconds = callWatcherConfiguration.cooldownSeconds] in
            await dependencies.callWatcher.suppressPrompt(for: candidate, cooldownSeconds: cooldownSeconds)
            await dependencies.metrics.log(
                name: "call_prompt_dismissed",
                attributes: [
                    "app": candidate.appDisplayName,
                    "confidence": "\(candidate.confidenceScore)"
                ]
            )
        }
    }

    func disableCallWatcherFromPromptTapped() {
        if let candidate = callPromptCandidate {
            _ = claimCallPromptAction(for: candidate)
        }
        callPromptCandidate = nil
        setCallWatcherEnabled(false)
    }

    private func startRecording(source: RecordingSource, startReason: String) {
        guard !isStartingRecording, !isRecording, !isStoppingRecording, !isGlobalDictationBusy else { return }
        let enableLiveTranscript = isLiveTranscriptionSupported && isLiveTranscriptionEnabled
        stopPlaybackAndResetState()
        banner = nil
        exportMessage = nil
        selectedSessionID = nil
        activeTranscript = nil
        isStartingRecording = true
        activeRecordingSource = source
        recorderStatusText = "Starting capture…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
                await self.pushKnownSpeakersToServices()
                await self.dependencies.recorder.setLiveTranscriptionEnabled(enableLiveTranscript)
                try await self.dependencies.recorder.startRecording(
                    RecordingRequest(source: source, liveTranscriptionEnabled: enableLiveTranscript)
                )
                await self.dependencies.metrics.log(
                    name: "record_started",
                    attributes: ["source": source.rawValue, "start_reason": startReason]
                )
                self.liveTranscriptPreview = nil
                self.isStartingRecording = false
                self.isRecording = true
                self.isStoppingRecording = false
                self.recordingElapsedSeconds = 0
                self.currentRecordingStartedAt = Date()
                self.recorderStatusText = "Recording live"
                self.startRecordingTimers()
            } catch {
                if let lorreError = error as? LorreError {
                    if case .recordingSourceSelectionCancelled = lorreError {
                        self.isStartingRecording = false
                        self.activeRecordingSource = nil
                        self.recorderStatusText = "Ready to record"
                        await self.dependencies.metrics.log(
                            name: "record_source_selection_cancelled",
                            attributes: ["source": source.rawValue, "start_reason": startReason]
                        )
                        return
                    }
                }
                self.isStartingRecording = false
                self.activeRecordingSource = nil
                self.presentError(error, defaultTitle: "Could not start recording")
                await self.dependencies.metrics.log(
                    name: "record_start_failed",
                    attributes: [
                        "source": source.rawValue,
                        "start_reason": startReason,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func cancelRecordingTapped() {
        guard isRecording, !isStoppingRecording else { return }
        isStoppingRecording = true
        recorderStatusText = "Discarding recording…"
        stopRecordingTimers()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.recorder.cancelRecording()
                await self.dependencies.metrics.log(name: "record_cancelled")

                self.isRecording = false
                self.isStoppingRecording = false
                self.currentRecordingStartedAt = nil
                self.activeRecordingSource = nil
                self.liveTranscriptPreview = nil
                self.recordingElapsedSeconds = 0
                self.recorderStatusText = "Ready to record"
                self.selectedSessionID = nil
                self.activeTranscript = nil
                self.banner = AppBanner(
                    kind: .info,
                    title: "Recording cancelled",
                    message: "The in-progress session was deleted and the recording was discarded."
                )
            } catch {
                self.isRecording = false
                self.isStoppingRecording = false
                self.currentRecordingStartedAt = nil
                self.activeRecordingSource = nil
                self.liveTranscriptPreview = nil
                self.recordingElapsedSeconds = 0
                self.recorderStatusText = "Ready to record"
                self.presentError(error, defaultTitle: "Could not cancel recording")
                await self.dependencies.metrics.log(
                    name: "record_cancel_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func stopRecordingTapped() {
        guard isRecording, !isStoppingRecording else { return }
        isStoppingRecording = true
        recorderStatusText = "Stopping capture…"
        if var preview = liveTranscriptPreview, isLiveTranscriptionEnabled {
            preview.isFinalizing = true
            liveTranscriptPreview = preview
        }
        stopRecordingTimers()

        Task { [weak self] in
            guard let self else { return }
            var createdSessionID: UUID?
            do {
                let source = self.activeRecordingSource ?? self.selectedRecordingSource
                let now = Date()
                let fileLayout = await self.dependencies.recorder.recordingFileLayout(for: source)
                let title = "Session \(now.formatted(date: .abbreviated, time: .shortened))"
                let draft = NewSessionDraft(
                    title: title,
                    folderId: self.currentDraftFolderID(),
                    status: .processing,
                    durationSeconds: self.recordingElapsedSeconds,
                    recordingSource: source,
                    audioFileName: fileLayout.audioFileName,
                    microphoneStemFileName: fileLayout.microphoneStemFileName,
                    systemAudioStemFileName: fileLayout.systemAudioStemFileName,
                    recordedAt: now
                )
                var session = try await self.dependencies.store.createSession(draft)
                createdSessionID = session.id
                let sessionDirectory = await self.dependencies.store.sessionDirectoryURL(for: session.id)
                let capture = try await self.dependencies.recorder.stopRecording(
                    in: sessionDirectory,
                    fileLayout: fileLayout
                )
                session = try await self.dependencies.store.updateSession(id: session.id) { session in
                    session.durationSeconds = capture.durationSeconds
                    session.recordedAt = capture.endedAt
                    session.updatedAt = Date()
                }
                await self.dependencies.metrics.log(
                    name: "record_stopped",
                    sessionId: session.id,
                    attributes: [
                        "source": session.recordingSource.rawValue,
                        "duration_seconds": String(format: "%.2f", capture.durationSeconds)
                    ]
                )

                self.isRecording = false
                self.isStoppingRecording = false
                self.currentRecordingStartedAt = nil
                self.activeRecordingSource = nil
                self.liveTranscriptPreview = nil
                self.recorderStatusText = "Processing recording"
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                self.selectedSessionID = session.id
                await self.loadTranscriptForSelectedSession()
                self.launchProcessing(for: session.id)
            } catch {
                if let createdSessionID {
                    try? await self.dependencies.store.deleteSession(id: createdSessionID)
                    await self.reloadSessions(selectMostRecentIfNeeded: false)
                }
                self.isRecording = false
                self.isStoppingRecording = false
                self.currentRecordingStartedAt = nil
                self.activeRecordingSource = nil
                self.liveTranscriptPreview = nil
                self.recorderStatusText = "Ready to record"
                self.presentError(error, defaultTitle: "Could not stop recording")
                await self.dependencies.metrics.log(
                    name: "record_stop_failed",
                    attributes: [
                        "source": self.selectedRecordingSource.rawValue,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    func importAudioPickerCompleted(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            importAudioFile(at: url)
        case let .failure(error):
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                Task { [dependencies] in
                    await dependencies.metrics.log(name: "audio_import_cancelled")
                }
                return
            }
            presentError(error, defaultTitle: "Import failed")
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "audio_import_picker_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func exportSelectedSession(format: ExportFormat) {
        guard let session = selectedSession else { return }
        guard let transcript = activeTranscript else {
            banner = AppBanner(kind: .error, title: "No transcript yet", message: "Wait until processing completes before exporting.")
            return
        }
        guard session.status == .ready else { return }
        guard let destinationURL = chooseExportDestinationURL(session: session, format: format) else {
            Task { [dependencies] in
                await dependencies.metrics.log(name: "export_cancelled", sessionId: session.id, attributes: ["format": format.rawValue])
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let exportedURL = try await self.dependencies.exporter.export(
                    session: session,
                    transcript: transcript,
                    format: format,
                    destinationURL: destinationURL
                )

                let updated = try await self.dependencies.store.updateSession(id: session.id) { session in
                    session.exports.append(
                        ExportRecord(format: format, fileName: exportedURL.lastPathComponent)
                    )
                    session.updatedAt = Date()
                    session.dirtyFlags = .clean
                }
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                self.selectedSessionID = updated.id
                self.exportMessage = "Exported \(format.label) to \(exportedURL.lastPathComponent)"
                self.banner = AppBanner(kind: .success, title: "Export complete", message: exportedURL.path(percentEncoded: false))
                await self.dependencies.metrics.log(
                    name: "export_succeeded",
                    sessionId: updated.id,
                    attributes: ["format": format.rawValue, "file": exportedURL.lastPathComponent]
                )
            } catch {
                self.presentError(error, defaultTitle: "Export failed")
                await self.dependencies.metrics.log(
                    name: "export_failed",
                    sessionId: session.id,
                    attributes: ["format": format.rawValue, "error": error.localizedDescription]
                )
            }
        }
    }

    func exportSelectedSessionWithDefaultShortcut() {
        exportSelectedSession(format: .markdown)
    }

    func toggleSelectedSessionPlayback() {
        guard canControlPlayback else { return }
        guard let session = selectedSession else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePlaybackIfNeeded(for: session)
                if self.dependencies.playback.isPlaying {
                    self.dependencies.playback.pause()
                    self.refreshPlaybackState()
                    self.stopPlaybackMonitor()
                    await self.dependencies.metrics.log(name: "playback_paused", sessionId: session.id)
                } else {
                    try self.dependencies.playback.play()
                    self.refreshPlaybackState()
                    self.startPlaybackMonitor(sessionID: session.id)
                    await self.dependencies.metrics.log(name: "playback_started", sessionId: session.id)
                }
            } catch {
                self.presentError(error, defaultTitle: "Playback unavailable")
                await self.dependencies.metrics.log(
                    name: "playback_toggle_failed",
                    sessionId: session.id,
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func stopSelectedSessionPlayback() {
        guard selectedSession != nil else { return }
        dependencies.playback.stop()
        stopPlaybackMonitor()
        refreshPlaybackState()
    }

    func pauseSelectedSessionPlayback() {
        guard selectedSession != nil else { return }
        dependencies.playback.pause()
        stopPlaybackMonitor()
        refreshPlaybackState()
    }

    func seekSelectedSessionPlayback(to startMs: Int, autoplay: Bool = true) {
        guard canControlPlayback else { return }
        guard let session = selectedSession else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePlaybackIfNeeded(for: session)
                self.dependencies.playback.seek(to: Double(startMs) / 1000)
                self.refreshPlaybackState()
                if autoplay {
                    try self.dependencies.playback.play()
                    self.refreshPlaybackState()
                    self.startPlaybackMonitor(sessionID: session.id)
                }
                await self.dependencies.metrics.log(
                    name: "playback_seek",
                    sessionId: session.id,
                    attributes: ["start_ms": "\(startMs)", "autoplay": autoplay ? "true" : "false"]
                )
            } catch {
                self.presentError(error, defaultTitle: "Playback unavailable")
            }
        }
    }

    func seekSelectedSessionPlayback(toSeconds seconds: Double, autoplay: Bool = true) {
        let clampedMs = Int(max(0, (seconds * 1000).rounded()))
        seekSelectedSessionPlayback(to: clampedMs, autoplay: autoplay)
    }

    func seekSelectedSessionPlaybackBy(deltaSeconds: Double) {
        guard canControlPlayback else { return }
        guard let session = selectedSession else { return }
        let wasPlaying = isAudioPlaying

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePlaybackIfNeeded(for: session)
                self.dependencies.playback.seek(to: self.dependencies.playback.currentTimeSeconds + deltaSeconds)
                self.refreshPlaybackState()
                if wasPlaying {
                    try self.dependencies.playback.play()
                    self.refreshPlaybackState()
                    self.startPlaybackMonitor(sessionID: session.id)
                }
            } catch {
                self.presentError(error, defaultTitle: "Playback unavailable")
            }
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let normalized = min(max(rate, 0.75), 1.5)
        dependencies.playback.setPlaybackRate(normalized)
        refreshPlaybackState()

        if let session = selectedSession {
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "playback_rate_changed",
                    sessionId: session.id,
                    attributes: ["rate": String(format: "%.2f", normalized)]
                )
            }
        }
    }

    func revealSelectedSessionFiles() {
        guard let sessionID = selectedSession?.id else { return }
        revealFiles(for: sessionID)
    }

    func deleteSelectedSessionConfirmed() {
        guard let sessionID = selectedSession?.id else { return }
        deleteSession(sessionID)
    }

    func isPlaybackSegmentActive(_ segmentID: UUID) -> Bool {
        activePlaybackSegmentID == segmentID
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let folder = try await self.dependencies.settings.createFolder(named: trimmed)
                await self.reloadFolders()
                await MainActor.run {
                    self.selectedFolderID = folder.id
                    self.expandedFolderIDs.insert(folder.id)
                    self.banner = AppBanner(kind: .success, title: "Folder created", message: folder.name)
                }
                self.persistSidebarExpansionState()
                await self.dependencies.metrics.log(name: "folder_created", attributes: ["folder_id": folder.id])
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Could not create folder")
                }
                await self.dependencies.metrics.log(
                    name: "folder_create_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func renameFolder(_ folderID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard folders.contains(where: { $0.id == folderID }) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let renamed = try await self.dependencies.settings.renameFolder(id: folderID, to: trimmed)
                await self.reloadFolders()
                await MainActor.run {
                    self.banner = AppBanner(kind: .success, title: "Folder renamed", message: renamed.name)
                }
                await self.dependencies.metrics.log(
                    name: "folder_renamed",
                    attributes: ["folder_id": folderID]
                )
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Could not rename folder")
                }
            }
        }
    }

    func deleteFolder(_ folderID: String) {
        guard folders.contains(where: { $0.id == folderID }) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let affected = self.sessions.filter { $0.folderId == folderID }
                for session in affected {
                    _ = try await self.dependencies.store.updateSession(id: session.id) { session in
                        session.folderId = nil
                        session.updatedAt = Date()
                    }
                }

                try await self.dependencies.settings.deleteFolder(id: folderID)
                await self.reloadFolders()
                await self.reloadSessions(selectMostRecentIfNeeded: false)

                await MainActor.run {
                    if self.selectedFolderID == folderID {
                        self.selectedFolderID = nil
                    }
                    self.expandedFolderIDs.remove(folderID)
                    self.banner = AppBanner(
                        kind: .success,
                        title: "Folder deleted",
                        message: affected.isEmpty
                            ? "Folder removed."
                            : "\(affected.count) recording(s) moved to Unfiled."
                    )
                }
                self.persistSidebarExpansionState()

                await self.dependencies.metrics.log(
                    name: "folder_deleted",
                    attributes: ["folder_id": folderID, "moved_sessions": "\(affected.count)"]
                )
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Could not delete folder")
                }
            }
        }
    }

    func moveSelectedSessionToFolder(_ folderID: String?) {
        guard let sessionID = selectedSession?.id else { return }
        moveSession(sessionID, to: folderID)
    }

    func renameSelectedSession(to newName: String) {
        guard let sessionID = selectedSession?.id else { return }
        renameSession(sessionID, to: newName)
    }

    func saveSelectedSessionNotes(_ notes: String) {
        guard let sessionID = selectedSession?.id else { return }
        saveSessionNotes(sessionID, notes: notes)
    }

    func renameSession(_ sessionID: UUID, to newName: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard session.title != trimmed else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let updatedSession = try await self.dependencies.store.updateSession(id: sessionID) { session in
                    session.title = trimmed
                    session.updatedAt = Date()
                    session.dirtyFlags.titleEdited = true
                }
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    self.banner = AppBanner(kind: .success, title: "Session renamed", message: trimmed)
                }
                await self.dependencies.metrics.log(name: "session_renamed", sessionId: updatedSession.id)
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Rename failed")
                }
            }
        }
    }

    func saveSessionNotes(_ sessionID: UUID, notes: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let original = sessions[index]
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        guard sessions[index].notes != normalized else { return }

        var updated = sessions[index]
        updated.notes = normalized
        updated.updatedAt = Date()
        sessions[index] = updated
        let updatedAt = updated.updatedAt

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.store.updateSession(id: sessionID) { session in
                    session.notes = normalized
                    session.updatedAt = updatedAt
                }
                await self.dependencies.metrics.log(
                    name: "session_notes_saved",
                    sessionId: sessionID,
                    attributes: ["has_notes": normalized == nil ? "false" : "true"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .success,
                        title: normalized == nil ? "Notes cleared" : "Notes saved",
                        message: normalized == nil
                            ? "Session notes were removed."
                            : "Session notes saved locally."
                    )
                }
            } catch {
                await MainActor.run {
                    if let restoreIndex = self.sessions.firstIndex(where: { $0.id == sessionID }) {
                        self.sessions[restoreIndex] = original
                    }
                    self.presentError(error, defaultTitle: "Could not save notes")
                }
                await self.reloadSessions(selectMostRecentIfNeeded: false)
            }
        }
    }

    func revealFiles(for sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        Task { [weak self] in
            guard let self else { return }
            let folderURL = await self.dependencies.store.sessionDirectoryURL(for: sessionID)
            let opened: Bool
            #if canImport(AppKit)
            opened = NSWorkspace.shared.open(folderURL)
            #else
            opened = false
            #endif

            if opened {
                await self.dependencies.metrics.log(name: "session_reveal_files", sessionId: sessionID)
            } else {
                await MainActor.run {
                    self.presentError(
                        LorreError.revealFilesFailed("Finder could not open \(folderURL.lastPathComponent)."),
                        defaultTitle: "Could not open Finder"
                    )
                }
            }
        }
    }

    func deleteSession(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let wasSelected = (selectedSessionID == sessionID)

        currentProcessingTasks[sessionID]?.cancel()
        currentProcessingTasks[sessionID] = nil
        currentProcessingTaskTokens[sessionID] = nil
        if wasSelected {
            stopPlaybackAndResetState()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.store.deleteSession(id: sessionID)
                await self.dependencies.metrics.log(name: "session_deleted", sessionId: sessionID)
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    if wasSelected {
                        self.selectedSessionID = nil
                        self.activeTranscript = nil
                        self.playbackWaveformBins = []
                    }
                    self.banner = AppBanner(kind: .success, title: "Session deleted", message: session.displayTitle)
                }
            } catch {
                await MainActor.run {
                    self.presentError(
                        LorreError.deleteSessionFailed(error.localizedDescription),
                        defaultTitle: "Delete failed"
                    )
                }
                await self.dependencies.metrics.log(
                    name: "session_delete_failed",
                    sessionId: sessionID,
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func clearBanner() {
        banner = nil
    }

    func prepareModelsTapped() {
        guard modelPreparationState != .preparing else { return }

        modelPreparationState = .preparing
        modelPreparationStatusLine = "Preparing models"
        modelPreparationDetailLine = "Downloading and warming ASR, VAD, speaker enrollment, and live preview models if needed…"
        modelPreparationProgress = 0.02

        Task { [weak self] in
            guard let self else { return }
            await self.dependencies.metrics.log(name: "models_prepare_started")

            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
                await self.dependencies.diarization.setDiarizationEngine(await MainActor.run { self.diarizationEngine })
                await self.pushKnownSpeakersToServices()
                let includeDiarization = await MainActor.run { self.isSpeakerDiarizationEnabled }
                try await self.dependencies.processingCoordinator.prepareModels(includeDiarization: includeDiarization) { [weak self] update in
                    guard let self else { return }
                    await MainActor.run {
                        self.modelPreparationState = .preparing
                        self.modelPreparationStatusLine = update.label
                        self.modelPreparationDetailLine = update.detail ?? self.fluidAudioStatus
                        self.modelPreparationProgress = min(0.78, (update.fraction ?? 0) * 0.78)
                    }
                }

                if self.supportsAdvancedFluidAudioFeatures {
                    try await self.dependencies.speakerEnrollment.ensureModelsReady { [weak self] update in
                        guard let self else { return }
                        await MainActor.run {
                            self.modelPreparationState = .preparing
                            self.modelPreparationStatusLine = update.label
                            self.modelPreparationDetailLine = update.detail ?? self.fluidAudioStatus
                            self.modelPreparationProgress = 0.78 + ((update.fraction ?? 0) * 0.12)
                        }
                    }
                } else {
                    await MainActor.run {
                        self.modelPreparationProgress = max(self.modelPreparationProgress ?? 0.0, 0.90)
                    }
                }

                if await MainActor.run(body: { self.isLiveTranscriptionSupported }) {
                    await MainActor.run {
                        self.modelPreparationState = .preparing
                        self.modelPreparationStatusLine = "Warming live transcription"
                        self.modelPreparationDetailLine = "Preparing \(self.liveTranscriptionPreset.label) streaming models for fast recorder startup…"
                        self.modelPreparationProgress = max(self.modelPreparationProgress ?? 0.0, 0.90)
                    }
                    try await self.dependencies.recorder.prepareLiveTranscriptionEngine { [weak self] update in
                        guard let self else { return }
                        await MainActor.run {
                            self.modelPreparationState = .preparing
                            self.modelPreparationStatusLine = update.label
                            self.modelPreparationDetailLine = update.detail ?? self.fluidAudioStatus
                            self.modelPreparationProgress = 0.90 + ((update.fraction ?? 0) * 0.10)
                        }
                    }
                }

                let snapshot = self.makeModelPreparationSnapshot(preparedAt: Date())
                do {
                    _ = try await self.dependencies.settings.recordModelPreparation(snapshot)
                } catch {
                    await self.dependencies.metrics.log(
                        name: "models_prepare_settings_write_failed",
                        attributes: ["error": error.localizedDescription]
                    )
                }

                await MainActor.run {
                    self.applyModelPreparationReadyState(snapshot: snapshot)
                    self.banner = AppBanner(
                        kind: .success,
                        title: "Models ready",
                        message: "FluidAudio models are prepared and ready for local transcription."
                    )
                }
                await self.dependencies.metrics.log(name: "models_prepare_succeeded")
            } catch {
                await MainActor.run {
                    self.modelPreparationState = .error(error.localizedDescription)
                    self.modelPreparationStatusLine = "Model preparation failed"
                    self.modelPreparationDetailLine = error.localizedDescription
                    self.modelPreparationProgress = nil
                    self.presentError(error, defaultTitle: "Model preparation failed")
                }
                await self.dependencies.metrics.log(
                    name: "models_prepare_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func updateSegmentText(sessionID: UUID, segmentID: UUID, text: String) {
        guard var transcript = activeTranscript, transcript.sessionId == sessionID else { return }
        guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        guard transcript.segments[index].text != text else { return }
        transcript.segments[index].text = text
        transcript.segments[index].isEdited = true
        transcript.segments[index].lastEditedAt = Date()
        transcript.updatedAt = Date()
        activeTranscript = transcript
        markSessionDirty(sessionID: sessionID, transcriptEdited: true)
        persistTranscript(transcript, sessionID: sessionID)
    }

    func assignSpeaker(sessionID: UUID, segmentID: UUID, speakerID: String) {
        guard var transcript = activeTranscript, transcript.sessionId == sessionID else { return }
        guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        transcript.segments[index].speakerId = speakerID
        transcript.segments[index].sourceSpeakerId = speakerID
        transcript.segments[index].isEdited = true
        transcript.segments[index].lastEditedAt = Date()
        transcript.updatedAt = Date()
        activeTranscript = transcript
        markSessionDirty(sessionID: sessionID, transcriptEdited: true, speakerEdited: true)
        persistTranscript(transcript, sessionID: sessionID)
    }

    func renameSpeaker(sessionID: UUID, speakerID: String, to newName: String) {
        guard var transcript = activeTranscript, transcript.sessionId == sessionID else { return }
        let normalized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        transcript.speakers[index].displayName = normalized.isEmpty ? transcript.speakers[index].safeDisplayName : normalized
        transcript.speakers[index].isUserRenamed = true
        transcript.updatedAt = Date()
        activeTranscript = transcript
        markSessionDirty(sessionID: sessionID, speakerEdited: true)
        persistTranscript(transcript, sessionID: sessionID)
    }

    func retryProcessingSelectedSession() {
        guard let session = selectedSession else { return }
        retryProcessing(session.id)
    }

    func retryProcessing(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard canPerformSessionAction(.retryProcessing, for: session) else {
            let reason = sessionActionState(.retryProcessing, for: session).disabledReason ?? "This session cannot be retried."
            banner = AppBanner(kind: .error, title: "Retry unavailable", message: reason)
            return
        }
        launchProcessing(for: session.id)
    }

    func setSpeakerDiarizationEnabled(_ isEnabled: Bool) {
        guard isSpeakerDiarizationEnabled != isEnabled else { return }
        isSpeakerDiarizationEnabled = isEnabled

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setSpeakerDiarizationEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "diarization_setting_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Speaker diarization \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "New processing runs will assign speaker IDs automatically when available."
                            : "New processing runs will skip speaker diarization for faster transcription."
                    )
                }
            } catch {
                await MainActor.run {
                    self.isSpeakerDiarizationEnabled.toggle()
                    self.presentError(error, defaultTitle: "Could not save processing option")
                }
            }
        }
    }

    func setDiarizationExpectedSpeakerCountHint(_ hint: DiarizationSpeakerCountHint) {
        let normalized = hint.normalized()
        guard diarizationExpectedSpeakerCountHint != normalized else { return }
        let previous = diarizationExpectedSpeakerCountHint
        diarizationExpectedSpeakerCountHint = normalized

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setDiarizationExpectedSpeakerCountHint(normalized)
                await self.dependencies.metrics.log(
                    name: "diarization_expected_speakers_changed",
                    attributes: ["hint": normalized.detailLabel]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Expected speakers set to \(normalized.detailLabel)",
                        message: "New processing runs will use this speaker-count hint for diarization clustering."
                    )
                }
            } catch {
                await MainActor.run {
                    self.diarizationExpectedSpeakerCountHint = previous
                    self.presentError(error, defaultTitle: "Could not save diarization speaker hint")
                }
            }
        }
    }

    func setDiarizationEngine(_ engine: DiarizationEngine) {
        guard diarizationEngine != engine else { return }
        let previous = diarizationEngine
        diarizationEngine = engine

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setDiarizationEngine(engine)
                await self.dependencies.diarization.setDiarizationEngine(engine)
                await self.dependencies.metrics.log(
                    name: "diarization_engine_changed",
                    attributes: ["engine": engine.rawValue]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Diarization engine set to \(engine.detailLabel)",
                        message: engine.settingsSummary
                    )
                }
            } catch {
                await self.dependencies.diarization.setDiarizationEngine(previous)
                await MainActor.run {
                    self.diarizationEngine = previous
                    self.presentError(error, defaultTitle: "Could not save diarization engine")
                }
            }
        }
    }

    func setDiarizationDebugExportEnabled(_ isEnabled: Bool) {
        guard isDiarizationDebugExportEnabled != isEnabled else { return }
        let previous = isDiarizationDebugExportEnabled
        isDiarizationDebugExportEnabled = isEnabled

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setDiarizationDebugExportEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "diarization_debug_export_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Diarization debug export \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "New processing runs will save diarization-debug.json in each session folder."
                            : "Processing runs will no longer write diarization debug sidecar files."
                    )
                }
            } catch {
                await MainActor.run {
                    self.isDiarizationDebugExportEnabled = previous
                    self.presentError(error, defaultTitle: "Could not save debug export option")
                }
            }
        }
    }

    func setVocabularyBoostingEnabled(_ isEnabled: Bool) {
        guard isVocabularyBoostingAvailable else {
            banner = AppBanner(
                kind: .info,
                title: "Vocabulary boosting unavailable",
                message: "This build cannot apply vocabulary terms during batch transcription. Your saved term list is preserved."
            )
            return
        }
        guard isVocabularyBoostingEnabled != isEnabled else { return }
        let previous = isVocabularyBoostingEnabled
        isVocabularyBoostingEnabled = isEnabled

        Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = await MainActor.run { self.currentVocabularyBoostingConfiguration() }
                _ = try await self.dependencies.settings.saveVocabularyBoosting(configuration)
                await self.dependencies.transcription.setVocabularyBoostingConfiguration(configuration)
                await self.dependencies.metrics.log(
                    name: "vocabulary_boosting_setting_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Vocabulary boosting \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "Batch post-pass transcription will apply your curated vocabulary list when terms are provided."
                            : "Batch post-pass transcription will run without vocabulary biasing."
                    )
                }
            } catch {
                await MainActor.run {
                    self.isVocabularyBoostingEnabled = previous
                    self.presentError(error, defaultTitle: "Could not save ASR option")
                }
            }
        }
    }

    func saveCustomVocabularyTerms() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = await MainActor.run { self.currentVocabularyBoostingConfiguration() }
                let lineCount = await MainActor.run { self.customVocabularyTermLineCount }
                _ = try await self.dependencies.settings.saveVocabularyBoosting(configuration)
                await self.dependencies.transcription.setVocabularyBoostingConfiguration(configuration)
                await self.dependencies.metrics.log(
                    name: "vocabulary_terms_saved",
                    attributes: [
                        "enabled": configuration.isEnabled ? "true" : "false",
                        "lines": "\(lineCount)"
                    ]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: self.isVocabularyBoostingAvailable ? .success : .info,
                        title: self.isVocabularyBoostingAvailable ? "Vocabulary saved" : "Vocabulary saved for later",
                        message: self.isVocabularyBoostingAvailable
                            ? (
                                lineCount == 0
                                    ? "No custom terms configured. Batch transcription will use base Parakeet decoding unless you add terms."
                                    : "Saved \(lineCount) vocabulary entr\(lineCount == 1 ? "y" : "ies"). Use `term: alias1, alias2` for common variants."
                            )
                            : "Saved \(lineCount) term entr\(lineCount == 1 ? "y" : "ies"), but this build cannot apply them during transcription."
                    )
                }
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Could not save vocabulary terms")
                }
            }
        }
    }

    func setBatchTranscriptionMode(_ mode: BatchTranscriptionMode) {
        let updated = BatchTranscriptionConfiguration(
            mode: mode,
            languageCode: batchTranscriptionConfiguration.languageCode,
            parallelChunkConcurrency: batchTranscriptionConfiguration.parallelChunkConcurrency
        )
        guard updated != batchTranscriptionConfiguration else { return }
        let previous = batchTranscriptionConfiguration
        batchTranscriptionConfiguration = updated

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setBatchTranscriptionConfiguration(updated)
                await self.dependencies.transcription.setBatchTranscriptionConfiguration(updated)
                await self.dependencies.metrics.log(
                    name: "batch_transcription_mode_changed",
                    attributes: ["mode": updated.mode.rawValue]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Transcription mode updated",
                        message: updated.mode.settingsSummary
                    )
                }
            } catch {
                await MainActor.run {
                    self.batchTranscriptionConfiguration = previous
                    self.presentError(error, defaultTitle: "Could not save ASR mode")
                }
            }
        }
    }

    func setBatchTranscriptionLanguageCode(_ languageCode: String) {
        let updated = BatchTranscriptionConfiguration(
            mode: batchTranscriptionConfiguration.mode,
            languageCode: languageCode,
            parallelChunkConcurrency: batchTranscriptionConfiguration.parallelChunkConcurrency
        )
        guard updated != batchTranscriptionConfiguration else { return }
        let previous = batchTranscriptionConfiguration
        let fellBackFromEnglishOnlyMode = previous.mode.isEnglishOnly && updated.mode != previous.mode
        batchTranscriptionConfiguration = updated

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setBatchTranscriptionConfiguration(updated)
                await self.dependencies.transcription.setBatchTranscriptionConfiguration(updated)
                if fellBackFromEnglishOnlyMode {
                    await MainActor.run {
                        self.banner = AppBanner(
                            kind: .info,
                            title: "Switched to Parakeet v3",
                            message: "Parakeet v2 is English-only, so \(updated.languageCode.uppercased()) uses the multilingual v3 model."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.batchTranscriptionConfiguration = previous
                    self.presentError(error, defaultTitle: "Could not save ASR language")
                }
            }
        }
    }

    func setLiveTranscriptionPreset(_ preset: LiveTranscriptionPreset) {
        guard !isLiveEngineSelectionLocked else {
            banner = AppBanner(
                kind: .info,
                title: "Live engine locked",
                message: "Finish or cancel the active recording before changing the live engine."
            )
            return
        }
        guard liveTranscriptionPreset != preset else { return }
        let previous = liveTranscriptionPreset
        liveTranscriptionPreset = preset

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setLiveTranscriptionPreset(preset)
                await self.dependencies.recorder.setLiveTranscriptionPreset(preset)
                await self.dependencies.metrics.log(
                    name: "live_transcription_preset_changed",
                    attributes: ["preset": preset.rawValue]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Live preview preset updated",
                        message: preset.settingsSummary
                    )
                }
            } catch {
                await self.dependencies.recorder.setLiveTranscriptionPreset(previous)
                await MainActor.run {
                    self.liveTranscriptionPreset = previous
                    self.presentError(error, defaultTitle: "Could not save live preview preset")
                }
            }
        }
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) {
        guard isLiveTranscriptionSupported else {
            banner = AppBanner(
                kind: .info,
                title: "Live transcript unavailable",
                message: "This build cannot run live transcription. Post-processing transcription remains available."
            )
            return
        }
        guard isLiveTranscriptionEnabled != isEnabled else { return }

        let previous = isLiveTranscriptionEnabled
        isLiveTranscriptionEnabled = isEnabled
        if !isEnabled {
            liveTranscriptPreview = nil
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setLiveTranscriptionEnabled(isEnabled)
                await self.dependencies.recorder.setLiveTranscriptionEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "live_transcript_setting_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Live transcript \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "New recordings can show a live preview while recording. After stop, Lorre runs the selected final transcript pass."
                            : "Recordings will skip live transcript preview and process after stop as before."
                    )
                }
            } catch {
                await self.dependencies.recorder.setLiveTranscriptionEnabled(previous)
                await MainActor.run {
                    self.isLiveTranscriptionEnabled = previous
                    self.presentError(error, defaultTitle: "Could not save recording option")
                }
            }
        }
    }

    func setDeleteAudioAfterTranscriptionEnabled(_ isEnabled: Bool) {
        guard isDeleteAudioAfterTranscriptionEnabled != isEnabled else { return }

        let previous = isDeleteAudioAfterTranscriptionEnabled
        isDeleteAudioAfterTranscriptionEnabled = isEnabled

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setDeleteAudioAfterTranscriptionEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "delete_audio_after_transcription_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: isEnabled ? "Privacy mode enabled" : "Privacy mode disabled",
                        message: isEnabled
                            ? "After the transcript finishes saving, Lorre will delete the source audio and keep only the transcript and exports."
                            : "Lorre will keep the recorded audio after transcription so playback and waveform review stay available."
                    )
                }
            } catch {
                await MainActor.run {
                    self.isDeleteAudioAfterTranscriptionEnabled = previous
                    self.presentError(error, defaultTitle: "Could not save recording option")
                }
            }
        }
    }

    func setRecordingSource(_ source: RecordingSource) {
        guard !isStartingRecording, !isRecording, !isStoppingRecording, !isGlobalDictationBusy else { return }
        guard selectedRecordingSource != source else { return }

        let previousSource = selectedRecordingSource
        let previousSupport = isLiveTranscriptionSupported
        selectedRecordingSource = source

        recordingSourceChangeTask?.cancel()
        recordingSourceChangeTask = Task { [weak self] in
            guard let self else { return }
            let supported = await self.dependencies.recorder.supportsLiveTranscription(for: source)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.selectedRecordingSource == source else { return }
                self.isLiveTranscriptionSupported = supported
                if !supported {
                    self.liveTranscriptPreview = nil
                }
            }

            do {
                _ = try await self.dependencies.settings.setSelectedRecordingSource(source)
                guard !Task.isCancelled else { return }
                await self.dependencies.metrics.log(
                    name: "recording_source_changed",
                    attributes: ["source": source.rawValue]
                )
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.selectedRecordingSource == source else { return }
                    self.selectedRecordingSource = previousSource
                    self.isLiveTranscriptionSupported = previousSupport
                    self.presentError(error, defaultTitle: "Could not save recording option")
                }
            }
        }
    }

    func setTranscriptConfidenceVisible(_ isVisible: Bool) {
        guard isTranscriptConfidenceVisible != isVisible else { return }
        let previous = isTranscriptConfidenceVisible
        isTranscriptConfidenceVisible = isVisible

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setTranscriptConfidenceVisible(isVisible)
                await self.dependencies.metrics.log(
                    name: "transcript_confidence_visibility_changed",
                    attributes: ["visible": isVisible ? "true" : "false"]
                )
            } catch {
                await MainActor.run {
                    self.isTranscriptConfidenceVisible = previous
                    self.presentError(error, defaultTitle: "Could not save transcript option")
                }
            }
        }
    }

    func setAutomaticMarkdownExportEnabled(_ isEnabled: Bool) {
        guard automaticMarkdownExportConfiguration.isEnabled != isEnabled else { return }
        guard !isEnabled || automaticMarkdownExportConfiguration.hasFolder else {
            banner = AppBanner(
                kind: .info,
                title: "Choose export folder",
                message: "Select a folder before turning on automatic Markdown export."
            )
            return
        }

        let previous = automaticMarkdownExportConfiguration
        automaticMarkdownExportConfiguration = AutomaticMarkdownExportConfiguration(
            isEnabled: isEnabled,
            folderPath: previous.folderPath,
            fileNameTemplate: previous.fileNameTemplate
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setAutomaticMarkdownExportEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "automatic_markdown_export_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Automatic Markdown export \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "New transcripts will export to \(self.automaticMarkdownExportFolderLabel)."
                            : "New transcripts will stay in Lorre until you export them manually."
                    )
                }
            } catch {
                await MainActor.run {
                    self.automaticMarkdownExportConfiguration = previous
                    self.presentError(error, defaultTitle: "Could not save export setting")
                }
            }
        }
    }

    func chooseAutomaticMarkdownExportFolder() {
        guard let folderURL = chooseAutomaticMarkdownExportFolderURL() else { return }
        setAutomaticMarkdownExportFolder(folderURL)
    }

    func clearAutomaticMarkdownExportFolder() {
        setAutomaticMarkdownExportFolder(nil)
    }

    func setAutomaticMarkdownExportFolder(_ folderURL: URL?) {
        let previous = automaticMarkdownExportConfiguration
        let updated = AutomaticMarkdownExportConfiguration(
            isEnabled: folderURL != nil,
            folderPath: folderURL?.path(percentEncoded: false),
            fileNameTemplate: previous.fileNameTemplate
        )
        guard updated != previous else { return }
        automaticMarkdownExportConfiguration = updated

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setAutomaticMarkdownExportFolderURL(folderURL)
                await self.dependencies.metrics.log(
                    name: "automatic_markdown_export_folder_changed",
                    attributes: [
                        "configured": folderURL == nil ? "false" : "true"
                    ]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: folderURL == nil ? "Automatic export folder cleared" : "Automatic export folder set",
                        message: folderURL == nil
                            ? "Automatic Markdown export is off until you choose another folder."
                            : "New transcripts will export Markdown to \(self.automaticMarkdownExportFolderLabel)."
                    )
                }
            } catch {
                await MainActor.run {
                    self.automaticMarkdownExportConfiguration = previous
                    self.presentError(error, defaultTitle: "Could not save export folder")
                }
            }
        }
    }

    func saveAutomaticMarkdownExportFileNameTemplate() {
        let previous = automaticMarkdownExportConfiguration
        let normalizedTemplate = AutomaticMarkdownExportConfiguration.normalizedFileNameTemplate(
            automaticMarkdownExportFileNameTemplate
        )
        let updated = AutomaticMarkdownExportConfiguration(
            isEnabled: previous.isEnabled,
            folderPath: previous.folderPath,
            fileNameTemplate: normalizedTemplate
        )
        guard updated != previous || automaticMarkdownExportFileNameTemplate != normalizedTemplate else { return }

        automaticMarkdownExportConfiguration = updated
        automaticMarkdownExportFileNameTemplate = normalizedTemplate

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setAutomaticMarkdownExportFileNameTemplate(normalizedTemplate)
                await self.dependencies.metrics.log(
                    name: "automatic_markdown_export_template_changed"
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Export filename template saved",
                        message: "Preview: \(self.automaticMarkdownExportFileNamePreview)"
                    )
                }
            } catch {
                await MainActor.run {
                    self.automaticMarkdownExportConfiguration = previous
                    self.automaticMarkdownExportFileNameTemplate = previous.fileNameTemplate
                    self.presentError(error, defaultTitle: "Could not save filename template")
                }
            }
        }
    }

    func resetAutomaticMarkdownExportFileNameTemplate() {
        automaticMarkdownExportFileNameTemplate = AutomaticMarkdownExportConfiguration.defaultFileNameTemplate
        saveAutomaticMarkdownExportFileNameTemplate()
    }

    func setCallWatcherEnabled(_ isEnabled: Bool) {
        guard callWatcherConfiguration.isEnabled != isEnabled else { return }
        let previous = callWatcherConfiguration
        let updated = CallWatcherConfiguration(
            isEnabled: isEnabled,
            defaultRecordingSource: previous.defaultRecordingSource,
            cooldownSeconds: previous.cooldownSeconds
        )
        callWatcherConfiguration = updated
        if let candidate = callPromptCandidate {
            removeCallPromptNotification(fingerprint: candidate.fingerprint)
        }
        callPromptCandidate = nil
        startCallWatcherIfNeeded()
        if isEnabled {
            requestCallPromptNotificationAuthorization()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setCallWatcherEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "call_watcher_enabled_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Call Watcher \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "Lorre will ask before recording when it sees likely call activity."
                            : "Lorre will only record when you start manually."
                    )
                }
            } catch {
                await MainActor.run {
                    self.callWatcherConfiguration = previous
                    self.startCallWatcherIfNeeded()
                    self.presentError(error, defaultTitle: "Could not save Call Watcher setting")
                }
            }
        }
    }

    func setCallWatcherDefaultRecordingSource(_ source: RecordingSource) {
        guard callWatcherConfiguration.defaultRecordingSource != source else { return }
        let previous = callWatcherConfiguration
        let updated = CallWatcherConfiguration(
            isEnabled: previous.isEnabled,
            defaultRecordingSource: source,
            cooldownSeconds: previous.cooldownSeconds
        )
        callWatcherConfiguration = updated
        if updated.isEnabled {
            startCallWatcherIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setCallWatcherDefaultRecordingSource(source)
                await self.dependencies.metrics.log(
                    name: "call_watcher_default_source_changed",
                    attributes: ["source": source.rawValue]
                )
            } catch {
                await MainActor.run {
                    self.callWatcherConfiguration = previous
                    self.startCallWatcherIfNeeded()
                    self.presentError(error, defaultTitle: "Could not save Call Watcher source")
                }
            }
        }
    }

    func setGlobalDictationEnabled(_ isEnabled: Bool) {
        guard globalDictationConfiguration.isEnabled != isEnabled else { return }
        let previous = globalDictationConfiguration
        var updated = previous
        updated.isEnabled = isEnabled

        globalDictationConfiguration = updated
        do {
            try applyGlobalDictationHotKeyRegistration(for: updated)
        } catch {
            globalDictationConfiguration = previous
            registerGlobalDictationHotKeyIfNeeded()
            presentError(error, defaultTitle: "Could not enable global dictation")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setGlobalDictationEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "global_dictation_setting_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Global dictation \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "Press \(self.globalDictationShortcutLabel) from another app to dictate into the focused text field."
                            : "The global shortcut is no longer active."
                    )
                }
            } catch {
                await MainActor.run {
                    self.globalDictationConfiguration = previous
                    self.registerGlobalDictationHotKeyIfNeeded()
                    self.presentError(error, defaultTitle: "Could not save global dictation setting")
                }
            }
        }
    }

    func setGlobalDictationShortcut(_ shortcut: GlobalDictationShortcutChoice) {
        guard globalDictationConfiguration.shortcut != shortcut else { return }
        let previous = globalDictationConfiguration
        var updated = previous
        updated.shortcut = shortcut

        globalDictationConfiguration = updated
        do {
            try applyGlobalDictationHotKeyRegistration(for: updated)
        } catch {
            globalDictationConfiguration = previous
            registerGlobalDictationHotKeyIfNeeded()
            presentError(error, defaultTitle: "Could not set global dictation shortcut")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setGlobalDictationShortcut(shortcut)
                await self.dependencies.metrics.log(
                    name: "global_dictation_shortcut_changed",
                    attributes: ["shortcut": shortcut.rawValue]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Global dictation shortcut updated",
                        message: "Use \(shortcut.label) to start or stop dictation."
                    )
                }
            } catch {
                await MainActor.run {
                    self.globalDictationConfiguration = previous
                    self.registerGlobalDictationHotKeyIfNeeded()
                    self.presentError(error, defaultTitle: "Could not save global dictation shortcut")
                }
            }
        }
    }

    func startGlobalDictationTapped() {
        startGlobalDictation()
    }

    func stopGlobalDictationTapped() {
        stopGlobalDictationAndInsert()
    }

    func cancelGlobalDictationTapped() {
        guard globalDictationPhase == .listening else { return }
        globalDictationPhase = .failed
        globalDictationStatusLine = "Cancelling dictation…"
        stopGlobalDictationTimers()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.recorder.cancelRecording()
                await self.dependencies.metrics.log(name: "global_dictation_cancelled")
                await MainActor.run {
                    self.resetGlobalDictationState()
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Dictation cancelled",
                        message: "No text was inserted."
                    )
                }
            } catch {
                await MainActor.run {
                    self.globalDictationPhase = .failed
                    self.globalDictationStatusLine = error.localizedDescription
                    self.presentError(error, defaultTitle: "Could not cancel dictation")
                }
                await self.dependencies.metrics.log(
                    name: "global_dictation_cancel_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    func dismissGlobalDictationOverlay() {
        guard !globalDictationPhase.isBusy else { return }
        resetGlobalDictationState()
    }

    func copyGlobalDictationTranscriptToClipboard() {
        let text = globalDictationTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dependencies.globalTextInsertion.copyToClipboard(text)
        banner = AppBanner(
            kind: .success,
            title: "Dictation copied",
            message: "The dictated text is on the clipboard."
        )
        Task { [dependencies] in
            await dependencies.metrics.log(name: "global_dictation_fallback_copied")
        }
    }

    func openGlobalDictationAccessibilitySettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        #endif
        banner = AppBanner(
            kind: .info,
            title: "Accessibility settings",
            message: "Enable Lorre under Privacy & Security > Accessibility. If it is already enabled but still blocked, remove Lorre and add this Lorre.app again."
        )
    }

    func saveModelRegistryConfiguration() {
        let previous = modelRegistryCustomBaseURL
        let configuration: ModelRegistryConfiguration
        do {
            configuration = try validatedModelRegistryConfiguration()
        } catch {
            presentError(error, defaultTitle: "Invalid model registry")
            return
        }
        modelRegistryCustomBaseURL = configuration.normalizedBaseURL ?? ""
        applyCurrentRuntimeConfiguration()

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.dependencies.settings.setModelRegistryConfiguration(configuration)
                await self.dependencies.metrics.log(
                    name: "model_registry_configuration_saved",
                    attributes: ["custom_base_url": configuration.normalizedBaseURL ?? "default"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .success,
                        title: configuration.isDefault ? "Model registry reset" : "Model registry updated",
                        message: configuration.isDefault
                            ? "Lorre will use the default Hugging Face registry."
                            : "Lorre will download models from \(configuration.summaryLabel)."
                    )
                }
            } catch {
                await MainActor.run {
                    self.modelRegistryCustomBaseURL = previous
                    self.applyCurrentRuntimeConfiguration()
                    self.presentError(error, defaultTitle: "Could not save model registry")
                }
            }
        }
    }

    func resetModelRegistryConfiguration() {
        modelRegistryCustomBaseURL = ""
        saveModelRegistryConfiguration()
    }

    func importKnownSpeaker() {
        guard let sourceURL = chooseKnownSpeakerSampleURL(title: "Choose Speaker Enrollment Clip") else {
            return
        }
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedName = normalizedKnownSpeakerName(
            from: knownSpeakerDraftName,
            fallback: fallbackName.isEmpty ? "Known Speaker" : fallbackName
        )
        enrollKnownSpeaker(
            displayName: selectedName,
            sourceURL: sourceURL,
            replacing: nil
        )
    }

    func reenrollKnownSpeaker(_ speakerID: String) {
        guard let speaker = knownSpeakers.first(where: { $0.id == speakerID }) else { return }
        guard let sourceURL = chooseKnownSpeakerSampleURL(
            title: "Choose Updated Enrollment Clip for \(speaker.safeDisplayName)"
        ) else {
            return
        }
        enrollKnownSpeaker(
            displayName: speaker.safeDisplayName,
            sourceURL: sourceURL,
            replacing: speaker
        )
    }

    func deleteKnownSpeaker(_ speakerID: String) {
        guard let speaker = knownSpeakers.first(where: { $0.id == speakerID }) else { return }
        isKnownSpeakerOperationInFlight = true
        knownSpeakerOperationDescription = "Removing \(speaker.safeDisplayName)…"

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.knownSpeakerStore.deleteSpeaker(id: speakerID)
                await self.reloadKnownSpeakers()
                await self.dependencies.metrics.log(
                    name: "known_speaker_deleted",
                    attributes: ["speaker_id": speakerID]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .success,
                        title: "Speaker removed",
                        message: "\(speaker.safeDisplayName) will no longer be used for automatic labeling."
                    )
                    self.isKnownSpeakerOperationInFlight = false
                    self.knownSpeakerOperationDescription = nil
                }
            } catch {
                await MainActor.run {
                    self.isKnownSpeakerOperationInFlight = false
                    self.knownSpeakerOperationDescription = nil
                    self.presentError(error, defaultTitle: "Could not remove speaker")
                }
            }
        }
    }

    func speakerSummaryBins(for transcript: TranscriptDocument?) -> [IndexRailSpeakerBin] {
        guard let transcript else { return [] }
        let counts = Dictionary(grouping: transcript.segments, by: { $0.speakerId ?? "UNK" })
            .mapValues(\.count)
        return transcript.speakers.compactMap { speaker in
            guard let count = counts[speaker.id], count > 0 else { return nil }
            return IndexRailSpeakerBin(id: speaker.id, variant: speaker.styleVariant, weight: Double(count))
        }
    }

    func processingSummary(for session: SessionManifest) -> ProcessingSummary {
        processingProgressSnapshots[session.id] ?? session.processing
    }

    private func startGlobalDictation() {
        guard globalDictationConfiguration.isEnabled else {
            banner = AppBanner(
                kind: .info,
                title: "Global dictation is off",
                message: "Enable Global Dictation in settings before using the shortcut."
            )
            return
        }
        guard !isStartingRecording, !isRecording, !isStoppingRecording, !isGlobalDictationBusy else {
            banner = AppBanner(
                kind: .info,
                title: "Dictation unavailable",
                message: "Finish the active recording or dictation before starting another capture."
            )
            return
        }

        let preparation = dependencies.globalTextInsertion.prepareTarget(promptForPermission: true)
        guard case let .ready(target) = preparation else {
            let code = preparation.failureCode ?? "unknown"
            globalDictationPhase = .failed
            globalDictationElapsedSeconds = 0
            globalDictationTranscriptText = ""
            globalDictationTargetLabel = code == "missing_accessibility_permission" ? "Accessibility" : "Target"
            globalDictationStatusLine = preparation.userFacingMessage
            banner = AppBanner(
                kind: .error,
                title: "Cannot start global dictation",
                message: preparation.userFacingMessage
            )
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "global_dictation_permission_or_target_blocked",
                    attributes: ["reason": code]
                )
            }
            return
        }

        stopPlaybackAndResetState()
        banner = nil
        exportMessage = nil
        currentGlobalDictationTarget = target
        currentGlobalDictationStartedAt = Date()
        globalDictationElapsedSeconds = 0
        globalDictationTranscriptText = ""
        globalDictationTargetLabel = target.displayName
        globalDictationStatusLine = "Listening for speech"
        globalDictationMeterSamples = Array(repeating: 0.08, count: 28)
        globalDictationPhase = .listening

        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
                await self.dependencies.recorder.setLiveTranscriptionEnabled(false)
                try await self.dependencies.recorder.startRecording(
                    RecordingRequest(source: .microphone, liveTranscriptionEnabled: false)
                )
                await self.dependencies.metrics.log(
                    name: "global_dictation_started",
                    attributes: [
                        "target_app": target.appName,
                        "target_bundle": target.bundleIdentifier ?? "unknown"
                    ]
                )
                await MainActor.run {
                    self.startGlobalDictationTimers()
                }
            } catch {
                await MainActor.run {
                    self.stopGlobalDictationTimers()
                    self.globalDictationPhase = .failed
                    self.globalDictationStatusLine = error.localizedDescription
                    self.currentGlobalDictationStartedAt = nil
                    self.currentGlobalDictationTarget = nil
                    self.presentError(error, defaultTitle: "Could not start global dictation")
                }
                await self.dependencies.metrics.log(
                    name: "global_dictation_start_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func stopGlobalDictationAndInsert() {
        guard globalDictationPhase == .listening,
              let target = currentGlobalDictationTarget else {
            return
        }

        globalDictationPhase = .transcribing
        globalDictationStatusLine = "Stopping capture…"
        stopGlobalDictationTimers()

        Task { [weak self] in
            guard let self else { return }
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LorreGlobalDictation-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }

            do {
                let fileLayout = await self.dependencies.recorder.recordingFileLayout(for: .microphone)
                let capture = try await self.dependencies.recorder.stopRecording(
                    in: temporaryDirectory,
                    fileLayout: fileLayout
                )
                let audioURL = temporaryDirectory.appendingPathComponent(fileLayout.audioFileName)

                await MainActor.run {
                    self.globalDictationStatusLine = "Preparing local speech model…"
                }
                try await self.dependencies.transcription.ensureModelsReady { [weak self] update in
                    guard let self else { return }
                    await MainActor.run {
                        self.globalDictationStatusLine = update.label
                    }
                }

                await MainActor.run {
                    self.globalDictationStatusLine = "Transcribing dictated text…"
                }
                let result = try await self.dependencies.transcription.transcribe(
                    url: audioURL,
                    sessionTitle: "Global Dictation",
                    source: .microphone
                )
                let text = GlobalDictationTextFormatter.insertionText(from: result)
                guard !text.isEmpty else {
                    throw LorreError.processingFailed("No speech was transcribed. Try again closer to the microphone.")
                }

                await MainActor.run {
                    self.globalDictationTranscriptText = text
                    self.globalDictationPhase = .inserting
                    self.globalDictationStatusLine = "Inserting text…"
                }

                let insertionTarget = target
                await MainActor.run {
                    self.globalDictationTargetLabel = insertionTarget.displayName
                    self.globalDictationStatusLine = "Inserting text into \(insertionTarget.displayName)…"
                }
                let insertion = await self.dependencies.globalTextInsertion.insert(text, into: insertionTarget)
                await MainActor.run {
                    switch insertion {
                    case .inserted:
                        self.globalDictationPhase = .inserted
                        self.globalDictationStatusLine = "Inserted \(text.count) characters."
                        self.banner = AppBanner(
                            kind: .success,
                            title: "Dictation inserted",
                            message: "Text was inserted into \(insertionTarget.displayName)."
                        )
                    case let .failed(code, message):
                        self.globalDictationPhase = .failed
                        self.globalDictationStatusLine = message
                        self.banner = AppBanner(
                            kind: .error,
                            title: "Dictation insertion failed",
                            message: "\(message) Use Copy in the dictation overlay to keep the text."
                        )
                        Task { [dependencies] in
                            await dependencies.metrics.log(
                                name: "global_dictation_insertion_failed",
                                attributes: ["reason": code]
                            )
                        }
                    }
                }

                if case .inserted = insertion {
                    await self.dependencies.metrics.log(
                        name: "global_dictation_inserted",
                        attributes: [
                            "target_app": insertionTarget.appName,
                            "duration_seconds": String(format: "%.2f", capture.durationSeconds),
                            "characters": "\(text.count)"
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    self.globalDictationPhase = .failed
                    self.globalDictationStatusLine = error.localizedDescription
                    self.presentError(error, defaultTitle: "Global dictation failed")
                }
                await self.dependencies.metrics.log(
                    name: "global_dictation_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }

            await MainActor.run {
                self.currentGlobalDictationStartedAt = nil
                self.currentGlobalDictationTarget = nil
            }
        }
    }

    private func globalDictationHotKeyPressed() {
        if globalDictationPhase == .listening {
            stopGlobalDictationAndInsert()
            return
        }
        guard !globalDictationPhase.isBusy else { return }
        if globalDictationPhase == .inserted || globalDictationPhase == .failed {
            resetGlobalDictationState()
        }
        startGlobalDictation()
    }

    private func applyGlobalDictationHotKeyRegistration(for configuration: GlobalDictationConfiguration) throws {
        dependencies.globalDictationHotKey.unregister()
        guard configuration.isEnabled else { return }
        try dependencies.globalDictationHotKey.register(shortcut: configuration.shortcut) { [weak self] in
            self?.globalDictationHotKeyPressed()
        }
    }

    private func registerGlobalDictationHotKeyIfNeeded() {
        do {
            try applyGlobalDictationHotKeyRegistration(for: globalDictationConfiguration)
        } catch {
            globalDictationConfiguration.isEnabled = false
            presentError(error, defaultTitle: "Global dictation shortcut unavailable")
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "global_dictation_hotkey_registration_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func launchProcessing(for sessionID: UUID) {
        currentProcessingTasks[sessionID]?.cancel()
        markSessionProcessingLocally(sessionID: sessionID)
        let taskToken = UUID()
        currentProcessingTaskTokens[sessionID] = taskToken
        currentProcessingTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
                await self.dependencies.diarization.setDiarizationEngine(await MainActor.run { self.diarizationEngine })
                await self.pushKnownSpeakersToServices()
                let deleteAudioAfterTranscription = self.isDeleteAudioAfterTranscriptionEnabled
                let transcript = try await self.dependencies.processingCoordinator.process(
                    sessionId: sessionID,
                    enableDiarization: self.isSpeakerDiarizationEnabled,
                    diarizationExpectedSpeakers: self.diarizationExpectedSpeakerCountHint,
                    exportDiarizationDebugArtifact: self.isDiarizationDebugExportEnabled,
                    deleteAudioAfterTranscription: deleteAudioAfterTranscription,
                    onProgress: { [weak self] update in
                        guard let self else { return }
                        await MainActor.run {
                            if self.selectedSessionID == sessionID {
                                self.recorderStatusText = update.label
                            }
                            self.applyProcessingProgressLocally(sessionID: sessionID, update: update)
                        }
                        if update.label.lowercased().contains("draft transcript ready") || update.phase == .diarizing {
                            await self.loadProcessingTranscriptPreviewIfAvailable(sessionID: sessionID)
                        }
                    }
                )

                await MainActor.run {
                    if self.selectedSessionID == sessionID {
                        self.activeTranscript = transcript
                        self.exportMessage = nil
                    }
                }
                _ = await self.exportMarkdownAutomaticallyIfNeeded(sessionID: sessionID, transcript: transcript)
                await self.dependencies.metrics.log(
                    name: "processing_succeeded",
                    sessionId: sessionID,
                    attributes: [
                        "segments": "\(transcript.segments.count)",
                        "audio_retained": deleteAudioAfterTranscription ? "false" : "true"
                    ]
                )
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    if self.selectedSessionID == sessionID {
                        self.startWaveformLoading(for: self.selectedSession)
                    }
                }
            } catch is CancellationError {
                let isCurrentTask = await MainActor.run {
                    self.currentProcessingTaskTokens[sessionID] == taskToken
                }
                guard isCurrentTask else { return }
                await self.reloadSessions(selectMostRecentIfNeeded: false)
            } catch {
                let isCurrentTask = await MainActor.run {
                    self.currentProcessingTaskTokens[sessionID] == taskToken
                }
                guard isCurrentTask else { return }
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Processing failed")
                }
                await self.dependencies.metrics.log(
                    name: "processing_failed",
                    sessionId: sessionID,
                    attributes: ["error": error.localizedDescription]
                )
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    if self.selectedSessionID == sessionID {
                        self.startWaveformLoading(for: self.selectedSession)
                    }
                }
            }

            await MainActor.run {
                guard self.currentProcessingTaskTokens[sessionID] == taskToken else { return }
                self.currentProcessingTasks[sessionID] = nil
                self.currentProcessingTaskTokens[sessionID] = nil
            }
        }
    }

    private func importAudioFile(at sourceURL: URL) {
        guard !isRecording, !isStoppingRecording, !isGlobalDictationBusy else { return }

        banner = nil
        exportMessage = nil
        recorderStatusText = "Importing audio…"
        applyCurrentRuntimeConfiguration()

        Task { [weak self] in
            guard let self else { return }
            var createdSessionID: UUID?
            await self.dependencies.metrics.log(
                name: "audio_import_started",
                attributes: ["file": sourceURL.lastPathComponent]
            )

            let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let fileValues = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let recordedAt = fileValues?.contentModificationDate ?? Date()
                let extensionComponent = normalizedImportedAudioExtension(from: sourceURL)
                let title = importedSessionTitle(from: sourceURL)

                let draft = NewSessionDraft(
                    title: title,
                    folderId: self.currentDraftFolderID(),
                    status: .processing,
                    durationSeconds: nil,
                    recordingSource: .microphone,
                    audioFileName: "audio.\(extensionComponent)",
                    microphoneStemFileName: nil,
                    systemAudioStemFileName: nil,
                    recordedAt: recordedAt
                )
                var session = try await self.dependencies.store.createSession(draft)
                createdSessionID = session.id

                let sessionDirectory = await self.dependencies.store.sessionDirectoryURL(for: session.id)
                let destinationURL = sessionDirectory.appendingPathComponent(session.audioFileName)

                try self.copyImportedAudio(from: sourceURL, to: destinationURL)

                session = try await self.dependencies.store.updateSession(id: session.id) { session in
                    session.updatedAt = Date()
                }

                await MainActor.run {
                    self.recorderStatusText = "Processing imported audio"
                    self.banner = AppBanner(
                        kind: .success,
                        title: "Audio imported",
                        message: "\(sourceURL.lastPathComponent) was added as a local session."
                    )
                }

                await self.dependencies.metrics.log(
                    name: "audio_import_succeeded",
                    sessionId: session.id,
                    attributes: [
                        "file": sourceURL.lastPathComponent,
                        "extension": extensionComponent
                    ]
                )

                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    self.selectedSessionID = session.id
                }
                await self.loadTranscriptForSelectedSession()
                self.launchProcessing(for: session.id)
            } catch {
                if let createdSessionID {
                    try? await self.dependencies.store.deleteSession(id: createdSessionID)
                    await self.reloadSessions(selectMostRecentIfNeeded: false)
                }
                await MainActor.run {
                    self.recorderStatusText = "Ready to record"
                    self.presentError(error, defaultTitle: "Import failed")
                }
                await self.dependencies.metrics.log(
                    name: "audio_import_failed",
                    attributes: [
                        "file": sourceURL.lastPathComponent,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func loadTranscriptForSelectedSession() async {
        guard let session = selectedSession else {
            activeTranscript = nil
            return
        }
        let requestedSessionID = session.id
        do {
            let transcript = try await dependencies.store.loadTranscript(sessionId: requestedSessionID)
            guard selectedSessionID == requestedSessionID else { return }
            activeTranscript = transcript
        } catch {
            guard selectedSessionID == requestedSessionID else { return }
            activeTranscript = nil
            presentError(error, defaultTitle: "Could not load transcript")
        }
    }

    private func loadProcessingTranscriptPreviewIfAvailable(sessionID: UUID) async {
        guard selectedSessionID == sessionID else { return }
        guard let session = selectedSession, session.id == sessionID, session.status == .processing else { return }
        do {
            if let transcript = try await dependencies.store.loadTranscript(sessionId: sessionID) {
                activeTranscript = transcript
            }
        } catch {
            // Draft transcript is optional during processing; ignore missing/partial writes here.
        }
    }

    private func reloadSessions(selectMostRecentIfNeeded: Bool) async {
        do {
            let loaded = try await dependencies.store.loadSessions()
            sessions = loaded
            let processingIDs = Set(loaded.filter { $0.status == .processing }.map(\.id))
            processingProgressSnapshots = processingProgressSnapshots.filter { processingIDs.contains($0.key) }

            if let selectedSessionID, !loaded.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                activeTranscript = nil
            }

            if selectMostRecentIfNeeded, self.selectedSessionID == nil {
                self.selectedSessionID = loaded.first(where: { $0.status == .ready })?.id
                    ?? loaded.first(where: { $0.status == .processing })?.id
                    ?? loaded.first?.id
                await loadTranscriptForSelectedSession()
                self.startWaveformLoading(for: self.selectedSession)
            }
        } catch {
            presentError(error, defaultTitle: "Could not load sessions")
        }
    }

    private func reloadFolders() async {
        do {
            folders = try await dependencies.settings.loadFolders()
            if let selectedFolderID,
               selectedFolderID != Self.unfiledFolderSelectionID,
               !folders.contains(where: { $0.id == selectedFolderID }) {
                self.selectedFolderID = nil
            }
        } catch {
            presentError(error, defaultTitle: "Could not load folders")
        }
    }

    private func filterMatches(_ session: SessionManifest) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .processing:
            return session.status == .processing
        case .ready:
            return session.status == .ready
        case .errors:
            return session.status == .error
        }
    }

    private func folderMatches(_ session: SessionManifest) -> Bool {
        guard let selectedFolderID else { return true }
        if selectedFolderID == Self.unfiledFolderSelectionID {
            return session.folderId == nil
        }
        return session.folderId == selectedFolderID
    }

    private func markSessionDirty(sessionID: UUID, transcriptEdited: Bool = false, speakerEdited: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].dirtyFlags.transcriptEdited = sessions[index].dirtyFlags.transcriptEdited || transcriptEdited
        sessions[index].dirtyFlags.speakerEdited = sessions[index].dirtyFlags.speakerEdited || speakerEdited
        sessions[index].updatedAt = Date()
    }

    private func applyProcessingProgressLocally(sessionID: UUID, update: ProcessingUpdate) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let now = Date()
        let previous = processingProgressSnapshots[sessionID] ?? session.processing
        processingProgressSnapshots[sessionID] = ProcessingSummary(
            queuedAt: previous.queuedAt ?? now,
            startedAt: previous.startedAt ?? now,
            completedAt: nil,
            progressPhase: update.phase,
            progressLabel: update.label,
            progressFraction: update.fraction ?? previous.progressFraction
        )
    }

    private func markSessionProcessingLocally(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let now = Date()
        var session = sessions[index]
        let previous = processingProgressSnapshots[sessionID] ?? session.processing
        let summary = ProcessingSummary(
            queuedAt: previous.queuedAt ?? now,
            startedAt: previous.startedAt,
            completedAt: nil,
            progressPhase: .preparing,
            progressLabel: "Queued",
            progressFraction: 0
        )
        session.status = .processing
        session.lastErrorMessage = nil
        session.processing = summary
        session.updatedAt = now
        sessions[index] = session
        processingProgressSnapshots[sessionID] = summary
        if selectedSessionID == sessionID {
            activeTranscript = nil
        }
    }

    private func persistTranscript(_ transcript: TranscriptDocument, sessionID: UUID) {
        let version = (transcriptPersistenceVersions[sessionID] ?? 0) + 1
        transcriptPersistenceVersions[sessionID] = version
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriptPersistenceQueue.save(transcript, using: self.dependencies.store)
                guard self.transcriptPersistenceVersions[sessionID] == version else {
                    return
                }
                if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
                    let updated = try await self.dependencies.store.updateSession(id: sessionID) { session in
                        session.dirtyFlags.transcriptEdited = false
                        session.dirtyFlags.speakerEdited = false
                        session.transcriptFileName = "transcript.json"
                        session.updatedAt = Date()
                    }
                    self.sessions[index] = updated
                }
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Save failed")
                }
            }
        }
    }

    private func preparePlaybackIfNeeded(for session: SessionManifest) async throws {
        guard session.hasRetainedAudio else {
            throw LorreError.playbackFailed("This session deleted its source audio after transcription for privacy.")
        }
        let sessionDirectory = await dependencies.store.sessionDirectoryURL(for: session.id)
        let audioURL = sessionDirectory.appendingPathComponent(session.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw LorreError.playbackFailed("Audio file is missing for this session.")
        }

        if dependencies.playback.preparedURL != audioURL {
            dependencies.playback.stop()
            try dependencies.playback.prepare(url: audioURL)
        }
        refreshPlaybackState()
    }

    private func refreshPlaybackState() {
        isAudioPlaying = dependencies.playback.isPlaying
        playbackCurrentSeconds = dependencies.playback.currentTimeSeconds
        playbackDurationSeconds = dependencies.playback.durationSeconds
        playbackRate = dependencies.playback.playbackRate
        updateActivePlaybackSegment()
    }

    private func updateActivePlaybackSegment() {
        guard let transcript = activeTranscript else {
            activePlaybackSegmentID = nil
            return
        }
        let currentMs = Int((playbackCurrentSeconds * 1000).rounded())
        activePlaybackSegmentID = transcript.segments.first { segment in
            currentMs >= segment.startMs && currentMs < max(segment.startMs + 1, segment.endMs)
        }?.id
    }

    private func startPlaybackMonitor(sessionID: UUID) {
        stopPlaybackMonitor()
        playbackMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    guard self.selectedSessionID == sessionID else {
                        self.stopPlaybackMonitor()
                        return
                    }
                    self.refreshPlaybackState()
                    if !self.isAudioPlaying {
                        self.stopPlaybackMonitor()
                    }
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopPlaybackMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
    }

    private func handlePlaybackFinished() {
        stopPlaybackMonitor()
        dependencies.playback.stop()
        refreshPlaybackState()
    }

    private func stopPlaybackAndResetState() {
        dependencies.playback.stop()
        stopPlaybackMonitor()
        isAudioPlaying = false
        playbackCurrentSeconds = 0
        playbackDurationSeconds = 0
        playbackRate = dependencies.playback.playbackRate
        activePlaybackSegmentID = nil
        if selectedSessionID == nil {
            waveformLoadTask?.cancel()
            waveformLoadTask = nil
            isPlaybackWaveformLoading = false
            playbackWaveformBins = []
        }
    }

    private func startWaveformLoading(for session: SessionManifest?) {
        waveformLoadTask?.cancel()
        waveformLoadTask = nil
        isPlaybackWaveformLoading = false

        guard let session else {
            playbackWaveformBins = []
            return
        }

        guard session.hasRetainedAudio else {
            waveformCache.removeValue(forKey: session.id)
            playbackWaveformBins = []
            return
        }

        if let cached = waveformCache[session.id] {
            playbackWaveformBins = cached
            return
        }

        guard session.status == .ready || session.status == .error else {
            playbackWaveformBins = []
            return
        }

        playbackWaveformBins = []
        isPlaybackWaveformLoading = true

        waveformLoadTask = Task { [weak self] in
            guard let self else { return }
            let sessionDirectory = await self.dependencies.store.sessionDirectoryURL(for: session.id)
            let audioURL = sessionDirectory.appendingPathComponent(session.audioFileName)
            guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
                await MainActor.run {
                    guard self.selectedSessionID == session.id else { return }
                    self.isPlaybackWaveformLoading = false
                    self.playbackWaveformBins = []
                }
                return
            }

            let bins = await Task.detached(priority: .utility) {
                (try? AudioWaveformExtractor.makeBins(from: audioURL, binCount: 96)) ?? []
            }.value

            await MainActor.run {
                guard self.selectedSessionID == session.id else { return }
                self.isPlaybackWaveformLoading = false
                self.playbackWaveformBins = bins
                if !bins.isEmpty {
                    self.waveformCache[session.id] = bins
                }
            }
        }
    }

    private func startRecordingTimers() {
        stopRecordingTimers()

        recordingClockTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    if let started = self.currentRecordingStartedAt {
                        let roundedSeconds = Double(Int(Date().timeIntervalSince(started)))
                        if self.recordingElapsedSeconds != roundedSeconds {
                            self.recordingElapsedSeconds = roundedSeconds
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        liveMeterTask = Task { [weak self] in
            guard let self else { return }
            if let monitorStream = await self.dependencies.recorder.makeLiveMonitorStream() {
                for await event in monitorStream {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if let next = event.meterLevel {
                            var samples = self.liveMeterSamples
                            samples.append(next)
                            if samples.count > 28 {
                                samples.removeFirst(samples.count - 28)
                            }
                            self.liveMeterSamples = samples
                        }

                        if self.isLiveTranscriptionEnabled {
                            if let preview = event.preview, self.liveTranscriptPreview != preview {
                                self.liveTranscriptPreview = preview
                            }
                        } else if self.liveTranscriptPreview != nil {
                            self.liveTranscriptPreview = nil
                        }
                    }
                }
                return
            }

            while !Task.isCancelled {
                let next = await self.dependencies.recorder.currentMeterLevel()
                let livePreview = await self.dependencies.recorder.currentLiveTranscriptPreview()
                await MainActor.run {
                    var samples = self.liveMeterSamples
                    samples.append(next)
                    if samples.count > 28 {
                        samples.removeFirst(samples.count - 28)
                    }
                    self.liveMeterSamples = samples
                    if self.isLiveTranscriptionEnabled {
                        if self.liveTranscriptPreview != livePreview {
                            self.liveTranscriptPreview = livePreview
                        }
                    } else if self.liveTranscriptPreview != nil {
                        self.liveTranscriptPreview = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }

    private func stopRecordingTimers() {
        recordingClockTask?.cancel()
        recordingClockTask = nil
        liveMeterTask?.cancel()
        liveMeterTask = nil
    }

    private func startGlobalDictationTimers() {
        stopGlobalDictationTimers()

        globalDictationClockTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    if let started = self.currentGlobalDictationStartedAt {
                        let roundedSeconds = Double(Int(Date().timeIntervalSince(started)))
                        if self.globalDictationElapsedSeconds != roundedSeconds {
                            self.globalDictationElapsedSeconds = roundedSeconds
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        globalDictationMeterTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let next = await self.dependencies.recorder.currentMeterLevel()
                await MainActor.run {
                    var samples = self.globalDictationMeterSamples
                    samples.append(next)
                    if samples.count > 28 {
                        samples.removeFirst(samples.count - 28)
                    }
                    self.globalDictationMeterSamples = samples
                }
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }

    private func stopGlobalDictationTimers() {
        globalDictationClockTask?.cancel()
        globalDictationClockTask = nil
        globalDictationMeterTask?.cancel()
        globalDictationMeterTask = nil
    }

    private func resetGlobalDictationState() {
        stopGlobalDictationTimers()
        globalDictationPhase = .idle
        globalDictationElapsedSeconds = 0
        globalDictationMeterSamples = Array(repeating: 0.08, count: 28)
        globalDictationTranscriptText = ""
        globalDictationTargetLabel = nil
        globalDictationStatusLine = "Ready"
        currentGlobalDictationStartedAt = nil
        currentGlobalDictationTarget = nil
    }

    private func presentError(_ error: Error, defaultTitle: String) {
        let mapped = UserFacingErrorMapper.map(error, defaultTitle: defaultTitle)
        banner = AppBanner(kind: .error, title: mapped.title, message: mapped.message)
    }

    private func exportMarkdownAutomaticallyIfNeeded(
        sessionID: UUID,
        transcript: TranscriptDocument
    ) async -> URL? {
        let configuration = automaticMarkdownExportConfiguration
        guard configuration.isEnabled, let folderURL = configuration.folderURL else {
            return nil
        }

        do {
            guard let session = try await dependencies.store.loadSession(id: sessionID) else {
                throw LorreError.sessionNotFound
            }

            let suggestedFileName = dependencies.exporter.suggestedFileName(session: session, format: .markdown)
            let automaticFileName = AutomaticExportFileNameBuilder.fileName(
                session: session,
                transcript: transcript,
                template: configuration.fileNameTemplate
            )
            let destinationURL = uniqueExportDestinationURL(
                in: folderURL,
                suggestedFileName: automaticFileName.isEmpty ? suggestedFileName : automaticFileName
            )
            let exportedURL = try await dependencies.exporter.export(
                session: session,
                transcript: transcript,
                format: .markdown,
                destinationURL: destinationURL
            )

            _ = try await dependencies.store.updateSession(id: sessionID) { session in
                session.exports.append(
                    ExportRecord(format: .markdown, fileName: exportedURL.lastPathComponent)
                )
                session.updatedAt = Date()
            }

            exportMessage = "Auto-exported Markdown to \(exportedURL.lastPathComponent)"
            banner = AppBanner(
                kind: .success,
                title: "Markdown exported",
                message: exportedURL.path(percentEncoded: false)
            )
            await dependencies.metrics.log(
                name: "automatic_markdown_export_succeeded",
                sessionId: sessionID,
                attributes: ["file": exportedURL.lastPathComponent]
            )
            return exportedURL
        } catch {
            banner = AppBanner(
                kind: .error,
                title: "Automatic export failed",
                message: "Transcript saved, but Lorre could not write Markdown to \(configuration.folderDisplayName). \(error.localizedDescription)"
            )
            await dependencies.metrics.log(
                name: "automatic_markdown_export_failed",
                sessionId: sessionID,
                attributes: ["error": error.localizedDescription]
            )
            return nil
        }
    }

    private func uniqueExportDestinationURL(in folderURL: URL, suggestedFileName: String) -> URL {
        let candidate = folderURL.appendingPathComponent(suggestedFileName, isDirectory: false)
        let path = candidate.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return candidate
        }

        let baseName = candidate.deletingPathExtension().lastPathComponent
        let pathExtension = candidate.pathExtension
        for suffix in 2...999 {
            let fileName = pathExtension.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(pathExtension)"
            let next = folderURL.appendingPathComponent(fileName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: next.path(percentEncoded: false)) {
                return next
            }
        }
        return folderURL.appendingPathComponent(UUID().uuidString + ".md", isDirectory: false)
    }

    private func chooseExportDestinationURL(session: SessionManifest, format: ExportFormat) -> URL? {
        #if canImport(AppKit)
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = dependencies.exporter.suggestedFileName(session: session, format: format)
        savePanel.allowedContentTypes = [utType(for: format)]
        let response = savePanel.runModal()
        guard response == .OK else { return nil }
        return savePanel.url
        #else
        return nil
        #endif
    }

    private func chooseAutomaticMarkdownExportFolderURL() -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose Automatic Markdown Export Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
        #else
        return nil
        #endif
    }

    private func utType(for format: ExportFormat) -> UTType {
        switch format {
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .plainText:
            return .plainText
        case .json:
            return .json
        }
    }

    private func importedSessionTitle(from sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "Imported \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        return base
    }

    private func currentDraftFolderID() -> String? {
        guard let selectedFolderID else { return nil }
        if selectedFolderID == Self.unfiledFolderSelectionID {
            return nil
        }
        return folders.contains(where: { $0.id == selectedFolderID }) ? selectedFolderID : nil
    }

    private func normalizedImportedAudioExtension(from sourceURL: URL) -> String {
        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(ext.unicodeScalars.filter { allowed.contains($0) })
        return sanitized.isEmpty ? "m4a" : sanitized
    }

    private func copyImportedAudio(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw LorreError.importFailed(error.localizedDescription)
        }
    }

    private func restoreModelPreparationStateFromSettings() async {
        do {
            let settings = try await dependencies.settings.load()
            let restoredRecordingSource = settings.selectedRecordingSource
            let restoredLiveSupported = await dependencies.recorder.supportsLiveTranscription(for: restoredRecordingSource)
            let restoredLiveEnabled = settings.isLiveTranscriptionEnabled && restoredLiveSupported
            let restoredVocabularyBoosting = settings.vocabularyBoosting
            let restoredBatchTranscription = settings.batchTranscription.normalized
            let restoredLivePreset = settings.liveTranscriptionPreset
            let restoredModelRegistry = settings.modelRegistryConfiguration
            let restoredDiarizationEngine = settings.diarizationEngine
            let restoredAutomaticMarkdownExport = settings.automaticMarkdownExport
            let restoredCallWatcher = settings.callWatcher
            let restoredGlobalDictation = settings.globalDictation
            FluidAudioRuntimeConfiguration.apply(modelRegistry: restoredModelRegistry)
            await dependencies.diarization.setDiarizationEngine(restoredDiarizationEngine)
            await dependencies.transcription.setBatchTranscriptionConfiguration(restoredBatchTranscription)
            await dependencies.recorder.setLiveTranscriptionPreset(restoredLivePreset)
            await dependencies.recorder.setLiveTranscriptionEnabled(restoredLiveEnabled)
            await dependencies.transcription.setVocabularyBoostingConfiguration(restoredVocabularyBoosting)
            await MainActor.run {
                self.modelRegistryCustomBaseURL = restoredModelRegistry.normalizedBaseURL ?? ""
                self.selectedRecordingSource = restoredRecordingSource
                self.isLiveTranscriptionSupported = restoredLiveSupported
                self.isSpeakerDiarizationEnabled = settings.isSpeakerDiarizationEnabled
                self.diarizationEngine = restoredDiarizationEngine
                self.diarizationExpectedSpeakerCountHint = settings.diarizationExpectedSpeakerCountHint.normalized()
                self.isDiarizationDebugExportEnabled = settings.isDiarizationDebugExportEnabled
                self.isVocabularyBoostingEnabled = restoredVocabularyBoosting.isEnabled
                self.customVocabularySimpleFormatTerms = restoredVocabularyBoosting.simpleFormatTerms
                self.batchTranscriptionConfiguration = restoredBatchTranscription
                self.liveTranscriptionPreset = restoredLivePreset
                self.isLiveTranscriptionEnabled = restoredLiveEnabled
                self.isDeleteAudioAfterTranscriptionEnabled = settings.isDeleteAudioAfterTranscriptionEnabled
                self.isTranscriptConfidenceVisible = settings.isTranscriptConfidenceVisible
                self.automaticMarkdownExportConfiguration = restoredAutomaticMarkdownExport
                self.automaticMarkdownExportFileNameTemplate = restoredAutomaticMarkdownExport.fileNameTemplate
                self.callWatcherConfiguration = restoredCallWatcher
                self.callWatcherStatusLine = restoredCallWatcher.isEnabled ? "Listening for calls…" : "Off"
                self.globalDictationConfiguration = restoredGlobalDictation
                if let snapshot = settings.modelPreparation {
                    self.applyModelPreparationReadyState(snapshot: snapshot)
                }
                let restoredViewFilters = Set(
                    settings.sidebarExpandedViewFilterIDs.compactMap(ShelfFilter.init(rawValue:))
                )
                self.expandedViewFilters = restoredViewFilters.isEmpty ? [.all] : restoredViewFilters

                let restoredFolderIDs = Set(settings.sidebarExpandedFolderIDs)
                self.expandedFolderIDs = restoredFolderIDs.isEmpty
                    ? [Self.unfiledFolderSelectionID]
                    : restoredFolderIDs
            }
        } catch {
            await dependencies.metrics.log(
                name: "settings_load_failed",
                attributes: ["error": error.localizedDescription]
            )
        }
    }

    private func startCallWatcherIfNeeded() {
        callWatcherTask?.cancel()
        callWatcherTask = nil
        callPromptCandidate = nil
        callPromptCandidatesByFingerprint.removeAll()
        handledCallPromptActionFingerprints.removeAll()

        guard callWatcherConfiguration.isEnabled else {
            callWatcherStatusLine = "Off"
            return
        }

        let configuration = callWatcherConfiguration
        callWatcherStatusLine = "Listening for calls…"
        callWatcherTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.dependencies.callWatcher.makeDetectionStream(configuration: configuration)
            for await event in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.handleCallDetectionEvent(event)
                }
            }
        }
    }

    private func startCallPromptNotificationActions() {
        guard callPromptNotificationTask == nil else { return }
        callPromptNotificationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.dependencies.callPromptNotifications.makeActionStream()
            for await action in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.handleCallPromptNotificationAction(action)
                }
            }
        }
    }

    private func handleCallDetectionEvent(_ event: CallDetectionEvent) {
        switch event {
        case let .candidateDetected(candidate):
            guard callWatcherConfiguration.isEnabled else { return }
            guard !isStartingRecording, !isRecording, !isStoppingRecording, !isGlobalDictationBusy else {
                callWatcherStatusLine = "Call-like activity detected. Recorder is busy."
                return
            }
            guard callPromptCandidatesByFingerprint[candidate.fingerprint] == nil,
                  !handledCallPromptActionFingerprints.contains(candidate.fingerprint)
            else {
                return
            }

            callPromptCandidatesByFingerprint[candidate.fingerprint] = candidate
            callPromptCandidate = candidate
            callWatcherStatusLine = "Call-like activity detected in \(candidate.appDisplayName)"
            Task { [weak self, dependencies] in
                let didShowNotification = await dependencies.callPromptNotifications.showCallPrompt(for: candidate)
                if !didShowNotification {
                    await MainActor.run {
                        guard let self,
                              self.callPromptCandidate?.fingerprint == candidate.fingerprint,
                              self.callWatcherConfiguration.isEnabled
                        else {
                            return
                        }
                        self.callWatcherStatusLine = "Call detected in \(candidate.appDisplayName). Notifications unavailable; showing the prompt in Lorre."
                        self.banner = AppBanner(
                            kind: .info,
                            title: "Call detected",
                            message: "Notification permission is unavailable, so the recording prompt is shown in Lorre."
                        )
                        self.requestUserAttentionForCallPromptFallback()
                    }
                    await dependencies.metrics.log(
                        name: "call_prompt_notification_unavailable",
                        attributes: [
                            "app": candidate.appDisplayName,
                            "confidence": "\(candidate.confidenceScore)"
                        ]
                    )
                }
                await dependencies.metrics.log(
                    name: "call_prompt_shown",
                    attributes: [
                        "app": candidate.appDisplayName,
                        "confidence": "\(candidate.confidenceScore)",
                        "source": candidate.recommendedRecordingSource.rawValue,
                        "surface": "in_app",
                        "notification": didShowNotification ? "true" : "false"
                    ]
                )
            }

        case let .candidateEnded(fingerprint):
            removeCallPromptNotification(fingerprint: fingerprint)
            callPromptCandidatesByFingerprint[fingerprint] = nil
            handledCallPromptActionFingerprints.remove(fingerprint)
            if callPromptCandidate?.fingerprint == fingerprint {
                callPromptCandidate = nil
            }
            callWatcherStatusLine = callWatcherConfiguration.isEnabled ? "Listening for calls…" : "Off"
        }
    }

    private func callPromptCandidate(for fingerprint: String) -> CallDetectionCandidate? {
        if callPromptCandidate?.fingerprint == fingerprint {
            return callPromptCandidate
        }
        return callPromptCandidatesByFingerprint[fingerprint]
    }

    private func claimCallPromptAction(for candidate: CallDetectionCandidate) -> Bool {
        guard !handledCallPromptActionFingerprints.contains(candidate.fingerprint) else {
            return false
        }
        handledCallPromptActionFingerprints.insert(candidate.fingerprint)
        callPromptCandidatesByFingerprint[candidate.fingerprint] = nil
        if callPromptCandidate?.fingerprint == candidate.fingerprint {
            callPromptCandidate = nil
        }
        removeCallPromptNotification(fingerprint: candidate.fingerprint)
        return true
    }

    private func requestUserAttentionForCallPromptFallback() {
        #if canImport(AppKit)
        NSApplication.shared.requestUserAttention(.informationalRequest)
        #endif
    }

    private func handleCallPromptNotificationAction(_ action: CallPromptNotificationAction) {
        switch action {
        case let .accept(fingerprint):
            guard let candidate = callPromptCandidate(for: fingerprint),
                  claimCallPromptAction(for: candidate)
            else {
                return
            }
            callWatcherStatusLine = "Recording from call prompt"
            startRecording(source: candidate.recommendedRecordingSource, startReason: "call_prompt")
            Task { [dependencies] in
                await dependencies.metrics.log(
                    name: "call_prompt_accepted",
                    attributes: [
                        "app": candidate.appDisplayName,
                        "confidence": "\(candidate.confidenceScore)",
                        "source": candidate.recommendedRecordingSource.rawValue
                    ]
                )
            }
        case let .dismiss(fingerprint):
            guard let candidate = callPromptCandidate(for: fingerprint),
                  claimCallPromptAction(for: candidate)
            else {
                return
            }
            callWatcherStatusLine = callWatcherConfiguration.isEnabled ? "Dismissed. Listening for a new call." : "Off"
            Task { [dependencies, cooldownSeconds = callWatcherConfiguration.cooldownSeconds] in
                await dependencies.callWatcher.suppressPrompt(for: candidate, cooldownSeconds: cooldownSeconds)
                await dependencies.metrics.log(
                    name: "call_prompt_dismissed",
                    attributes: [
                        "app": candidate.appDisplayName,
                        "confidence": "\(candidate.confidenceScore)"
                    ]
                )
            }
        case let .disable(fingerprint):
            guard let candidate = callPromptCandidate(for: fingerprint) else { return }
            _ = claimCallPromptAction(for: candidate)
            disableCallWatcherFromPromptTapped()
        }
    }

    private func requestCallPromptNotificationAuthorization() {
        Task { [weak self, dependencies] in
            let granted = await dependencies.callPromptNotifications.requestAuthorizationIfNeeded()
            guard !granted else { return }
            await dependencies.metrics.log(name: "call_prompt_notification_permission_blocked")
            await MainActor.run {
                guard let self,
                      self.callWatcherConfiguration.isEnabled,
                      self.callPromptCandidate == nil
                else {
                    return
                }
                self.callWatcherStatusLine = "Listening for calls; notification permission is blocked."
                self.banner = AppBanner(
                    kind: .info,
                    title: "Notification permission blocked",
                    message: "Call Watcher will still show prompts inside Lorre, but macOS notifications are unavailable."
                )
            }
        }
    }

    private func removeCallPromptNotification(fingerprint: String) {
        Task { [dependencies] in
            await dependencies.callPromptNotifications.removeCallPrompt(fingerprint: fingerprint)
        }
    }

    private func refreshLiveTranscriptionSupport(for source: RecordingSource) async {
        let supported = await dependencies.recorder.supportsLiveTranscription(for: source)
        await MainActor.run {
            self.isLiveTranscriptionSupported = supported
        }
    }

    private func currentVocabularyBoostingConfiguration() -> VocabularyBoostingConfiguration {
        VocabularyBoostingConfiguration(
            isEnabled: isVocabularyBoostingEnabled,
            simpleFormatTerms: customVocabularySimpleFormatTerms
        )
    }

    private func currentModelRegistryConfiguration() -> ModelRegistryConfiguration {
        ModelRegistryConfiguration(customBaseURL: modelRegistryCustomBaseURL)
    }

    private func validatedModelRegistryConfiguration() throws -> ModelRegistryConfiguration {
        let configuration = currentModelRegistryConfiguration()
        guard let normalizedBaseURL = configuration.normalizedBaseURL else {
            return configuration
        }

        guard let url = URL(string: normalizedBaseURL),
              let scheme = url.scheme,
              !scheme.isEmpty,
              let host = url.host,
              !host.isEmpty else {
            throw LorreError.persistenceFailed("Enter a full registry base URL, for example https://huggingface.co.")
        }
        return configuration
    }

    private func applyCurrentRuntimeConfiguration() {
        FluidAudioRuntimeConfiguration.apply(modelRegistry: currentModelRegistryConfiguration())
    }

    private func reloadKnownSpeakers() async {
        do {
            let speakers = try await dependencies.knownSpeakerStore.load()
            self.knownSpeakers = speakers
            self.knownSpeakerLibraryStatusLine = knownSpeakerLibrarySummary(for: speakers)
            await pushKnownSpeakersToServices()
        } catch {
            presentError(error, defaultTitle: "Could not load speaker library")
            self.knownSpeakers = []
            self.knownSpeakerLibraryStatusLine = knownSpeakerLibrarySummary(for: [])
            await pushKnownSpeakersToServices()
        }
    }

    private func pushKnownSpeakersToServices() async {
        await dependencies.diarization.setKnownSpeakers(knownSpeakers)
        await dependencies.recorder.setKnownSpeakers(knownSpeakers)
    }

    private func knownSpeakerLibrarySummary(for speakers: [KnownSpeaker]) -> String {
        guard !speakers.isEmpty else {
            return "No enrolled speakers yet. Add a short clean voice sample to relabel recurring speakers automatically."
        }

        let totalEnrollments = speakers.reduce(0) { $0 + $1.enrollmentCount }
        return "\(speakers.count) enrolled speaker\(speakers.count == 1 ? "" : "s") available for offline relabeling and live speaker hints (\(totalEnrollments) enrollment clip\(totalEnrollments == 1 ? "" : "s"))."
    }

    private func normalizedKnownSpeakerName(from rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func enrollKnownSpeaker(
        displayName: String,
        sourceURL: URL,
        replacing existingSpeaker: KnownSpeaker?
    ) {
        isKnownSpeakerOperationInFlight = true
        knownSpeakerOperationDescription = existingSpeaker == nil
            ? "Enrolling \(displayName)…"
            : "Updating \(displayName)…"
        applyCurrentRuntimeConfiguration()

        Task { [weak self] in
            guard let self else { return }
            let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                if self.supportsAdvancedFluidAudioFeatures {
                    try await self.dependencies.speakerEnrollment.ensureModelsReady { [weak self] update in
                        guard let self else { return }
                        await MainActor.run {
                            self.knownSpeakerOperationDescription = update.detail ?? update.label
                        }
                    }
                }

                let enrollment = try await self.dependencies.speakerEnrollment.makeEnrollment(from: sourceURL)
                if let existingSpeaker {
                    var updatedSpeaker = existingSpeaker
                    updatedSpeaker.displayName = displayName
                    updatedSpeaker.embedding = enrollment.embedding
                    updatedSpeaker.updatedAt = Date()
                    updatedSpeaker.enrollmentCount += 1
                    _ = try await self.dependencies.knownSpeakerStore.updateSpeaker(
                        updatedSpeaker,
                        replacingReferenceAudioAt: sourceURL,
                        enrollmentData: enrollment
                    )
                } else {
                    _ = try await self.dependencies.knownSpeakerStore.saveNewSpeaker(
                        displayName: displayName,
                        embedding: enrollment.embedding,
                        referenceAudioURL: sourceURL,
                        enrollmentData: enrollment
                    )
                }

                await self.reloadKnownSpeakers()
                await self.dependencies.metrics.log(
                    name: existingSpeaker == nil ? "known_speaker_enrolled" : "known_speaker_reenrolled",
                    attributes: ["speaker_name": displayName]
                )

                await MainActor.run {
                    self.knownSpeakerDraftName = existingSpeaker == nil ? "" : self.knownSpeakerDraftName
                    self.isKnownSpeakerOperationInFlight = false
                    self.knownSpeakerOperationDescription = nil
                    self.banner = AppBanner(
                        kind: .success,
                        title: existingSpeaker == nil ? "Speaker enrolled" : "Speaker updated",
                        message: "\(displayName) is now available for automatic speaker labeling."
                    )
                }
            } catch {
                await MainActor.run {
                    self.isKnownSpeakerOperationInFlight = false
                    self.knownSpeakerOperationDescription = nil
                    self.presentError(error, defaultTitle: existingSpeaker == nil ? "Could not enroll speaker" : "Could not update speaker")
                }
            }
        }
    }

    private var supportsAdvancedFluidAudioFeatures: Bool {
        runtimeCapabilities.supportsSpeakerEnrollment
    }

    var isVocabularyBoostingAvailable: Bool {
        runtimeCapabilities.supportsVocabularyBoosting
    }

    var isVocabularyBoostingEffectivelyEnabled: Bool {
        isVocabularyBoostingAvailable && isVocabularyBoostingEnabled
    }

    var vocabularyBoostingSupportSummary: String {
        if isVocabularyBoostingAvailable {
            return isVocabularyBoostingEnabled
                ? "Uses your custom word list to improve recognition."
                : "Leave off unless you need better recognition for names or special terms."
        }

        return "Stored for later, but inactive in this build."
    }

    private func chooseKnownSpeakerSampleURL(title: String) -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Use Clip"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    private func applyModelPreparationReadyState(snapshot: ModelPreparationSnapshot) {
        modelPreparationState = .ready
        modelPreparationStatusLine = "Models ready"
        modelPreparationDetailLine = formattedModelPreparationDetail(snapshot)
        modelPreparationProgress = 1.0
        modelPreparationLastPreparedAt = snapshot.preparedAt
    }

    private func makeModelPreparationSnapshot(preparedAt: Date) -> ModelPreparationSnapshot {
        ModelPreparationSnapshot(
            preparedAt: preparedAt,
            runtimeStatusSummary: dependencies.fluidAudioStatus,
            componentVersionsSummary: dependencies.modelPreparationComponentsSummary
        )
    }

    private func formattedModelPreparationDetail(_ snapshot: ModelPreparationSnapshot) -> String {
        let timestamp = snapshot.preparedAt.formatted(date: .abbreviated, time: .shortened)
        return "Last prepared \(timestamp) • \(snapshot.componentVersionsSummary)"
    }

    private func persistSidebarExpansionState() {
        let viewFilterIDs = expandedViewFilters.map(\.rawValue).sorted()
        let folderIDs = expandedFolderIDs.sorted()
        sidebarExpansionSaveTask?.cancel()
        sidebarExpansionSaveTask = Task { [dependencies] in
            do {
                _ = try await dependencies.settings.saveSidebarExpansion(
                    expandedViewFilterIDs: viewFilterIDs,
                    expandedFolderIDs: folderIDs
                )
            } catch {
                await dependencies.metrics.log(
                    name: "sidebar_expansion_save_failed",
                    attributes: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func rebuildDerivedSessionState() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allSessions = sessions

        cachedViewCounts = [
            .all: allSessions.count,
            .processing: allSessions.filter { $0.status == .processing }.count,
            .ready: allSessions.filter { $0.status == .ready }.count,
            .errors: allSessions.filter { $0.status == .error }.count
        ]

        let searchMatched: [SessionManifest]
        if query.isEmpty {
            searchMatched = allSessions
        } else {
            searchMatched = allSessions.filter { session in
                let haystack = [
                    session.displayTitle,
                    session.status.label,
                    folderName(for: session.folderId),
                    session.lastErrorMessage ?? ""
                ].joined(separator: " ").lowercased()
                return haystack.contains(query)
            }
        }

        cachedAllFolderBrowserSessions = searchMatched
        var folderBuckets: [String: [SessionManifest]] = [:]
        for session in searchMatched {
            let key = session.folderId ?? Self.unfiledFolderSelectionID
            folderBuckets[key, default: []].append(session)
        }
        cachedFolderBrowserSessions = folderBuckets

        cachedViewBrowserSessions = [
            .all: searchMatched,
            .processing: searchMatched.filter { $0.status == .processing },
            .ready: searchMatched.filter { $0.status == .ready },
            .errors: searchMatched.filter { $0.status == .error }
        ]

        let filteredByView = cachedViewBrowserSessions[selectedFilter] ?? []
        if let selectedFolderID {
            if selectedFolderID == Self.unfiledFolderSelectionID {
                cachedFilteredSessions = filteredByView.filter { $0.folderId == nil }
            } else {
                cachedFilteredSessions = filteredByView.filter { $0.folderId == selectedFolderID }
            }
        } else {
            cachedFilteredSessions = filteredByView
        }
    }

    private func rebuildDerivedSessionStateIfNeeded() {
        guard !isBatchingDerivedSessionState else { return }
        rebuildDerivedSessionState()
    }
}
