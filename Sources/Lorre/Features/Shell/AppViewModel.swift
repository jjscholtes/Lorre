import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all
    case processing
    case ready
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Sessions"
        case .processing: "Processing"
        case .ready: "Ready"
        case .errors: "Errors"
        }
    }

    var iconName: String {
        switch self {
        case .all: "tray.full"
        case .processing: "gearshape.2"
        case .ready: "doc.text"
        case .errors: "exclamationmark.triangle"
        }
    }
}

struct AppBanner: Identifiable {
    enum Kind {
        case info
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

enum ModelPreparationState: Equatable {
    case unknown
    case idle
    case preparing
    case ready
    case error(String)
}

@MainActor
final class AppViewModel: ObservableObject {
    static let unfiledFolderSelectionID = "__UNFILED__"

    @Published private(set) var sessions: [SessionManifest] = [] {
        didSet { rebuildDerivedSessionState() }
    }
    @Published private(set) var folders: [SessionFolder] = [] {
        didSet { rebuildDerivedSessionState() }
    }
    @Published var searchQuery: String = "" {
        didSet { rebuildDerivedSessionState() }
    }
    @Published var selectedFilter: ShelfFilter = .all {
        didSet { rebuildDerivedSessionState() }
    }
    @Published var selectedFolderID: String? {
        didSet { rebuildDerivedSessionState() }
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
    @Published private(set) var modelPreparationState: ModelPreparationState = .unknown
    @Published private(set) var modelPreparationStatusLine: String = "Models not prepared yet"
    @Published private(set) var modelPreparationDetailLine: String = "Models may download on first transcription."
    @Published private(set) var modelPreparationProgress: Double?
    @Published var modelRegistryCustomBaseURL: String = ""
    @Published private(set) var isSpeakerDiarizationEnabled: Bool = true
    @Published private(set) var diarizationExpectedSpeakerCountHint: DiarizationSpeakerCountHint = .auto
    @Published private(set) var isDiarizationDebugExportEnabled: Bool = false
    @Published private(set) var isVocabularyBoostingEnabled: Bool = false
    @Published var customVocabularySimpleFormatTerms: String = ""
    @Published private(set) var selectedRecordingSource: RecordingSource = .microphone
    @Published private(set) var isLiveTranscriptionSupported: Bool = false
    @Published private(set) var isLiveTranscriptionEnabled: Bool = false
    @Published private(set) var isDeleteAudioAfterTranscriptionEnabled: Bool = false
    @Published private(set) var isTranscriptConfidenceVisible: Bool = false
    @Published private(set) var liveTranscriptPreview: LiveTranscriptPreview?
    @Published private(set) var knownSpeakers: [KnownSpeaker] = []
    @Published var knownSpeakerDraftName: String = ""
    @Published private(set) var knownSpeakerLibraryStatusLine: String = "No known speakers enrolled yet."
    @Published private(set) var knownSpeakerOperationDescription: String?
    @Published private(set) var isKnownSpeakerOperationInFlight = false

    private let dependencies: AppDependencies
    private var started = false
    private var recordingClockTask: Task<Void, Never>?
    private var liveMeterTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var waveformLoadTask: Task<Void, Never>?
    private var recordingSourceChangeTask: Task<Void, Never>?
    private var currentRecordingStartedAt: Date?
    private var currentProcessingTasks: [UUID: Task<Void, Never>] = [:]
    private var cachedFilteredSessions: [SessionManifest] = []
    private var cachedViewBrowserSessions: [ShelfFilter: [SessionManifest]] = [:]
    private var cachedFolderBrowserSessions: [String: [SessionManifest]] = [:]
    private var cachedAllFolderBrowserSessions: [SessionManifest] = []
    private var cachedViewCounts: [ShelfFilter: Int] = [:]
    private var sidebarExpansionSaveTask: Task<Void, Never>?
    private var waveformCache: [UUID: [Double]] = [:]

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.fluidAudioStatus = dependencies.fluidAudioStatus
        self.playbackRate = dependencies.playback.playbackRate
        self.modelPreparationState = .idle
        if dependencies.fluidAudioStatus.lowercased().contains("mock") {
            self.modelPreparationStatusLine = "Mock processing pipeline active"
            self.modelPreparationDetailLine = "Model preparation completes instantly in mock mode."
        }
    }

    deinit {
        recordingClockTask?.cancel()
        liveMeterTask?.cancel()
        playbackMonitorTask?.cancel()
        waveformLoadTask?.cancel()
        recordingSourceChangeTask?.cancel()
        sidebarExpansionSaveTask?.cancel()
        currentProcessingTasks.values.forEach { $0.cancel() }
    }

    func start() async {
        guard !started else { return }
        started = true
        await refreshLiveTranscriptionSupport(for: selectedRecordingSource)
        await restoreModelPreparationStateFromSettings()
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

    var customVocabularyTermLineCount: Int {
        customVocabularySimpleFormatTerms
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    var selectedSession: SessionManifest? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var hasReadyTranscriptStage: Bool {
        if let session = selectedSession {
            return session.status == .ready || session.status == .error
        }
        return false
    }

    var visibleStageTitle: String {
        if isRecording { return "Recorder" }
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
                return session.processing.progressLabel ?? "Processing"
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
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchQuery = ""
        }
        selectedFilter = .all
        selectedFolderID = folderID

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
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard session.folderId != folderID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                session.folderId = folderID
                session.updatedAt = Date()
                try await self.dependencies.store.updateSession(session)
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    if self.selectedSessionID == session.id {
                        self.selectedSessionID = session.id
                    }
                    let label = self.folderName(for: folderID)
                    self.banner = AppBanner(kind: .success, title: "Moved to folder", message: "\(session.displayTitle) → \(label)")
                }
                await self.dependencies.metrics.log(
                    name: "session_moved_to_folder",
                    sessionId: session.id,
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
        guard !isStartingRecording, !isRecording, !isStoppingRecording else { return }
        selectSession(nil)
    }

    func startRecordingTapped() {
        guard !isStartingRecording, !isRecording, !isStoppingRecording else { return }
        let source = selectedRecordingSource
        let enableLiveTranscript = isLiveTranscriptionSupported && isLiveTranscriptionEnabled
        stopPlaybackAndResetState()
        banner = nil
        exportMessage = nil
        isStartingRecording = true
        recorderStatusText = "Starting capture…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
                await self.pushKnownSpeakersToServices()
                await self.dependencies.recorder.setLiveTranscriptionEnabled(enableLiveTranscript)
                try await self.dependencies.recorder.startRecording(RecordingRequest(source: source))
                await self.dependencies.metrics.log(
                    name: "record_started",
                    attributes: ["source": source.rawValue]
                )
                self.selectedSessionID = nil
                self.activeTranscript = nil
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
                        self.recorderStatusText = "Ready to record"
                        await self.dependencies.metrics.log(
                            name: "record_source_selection_cancelled",
                            attributes: ["source": source.rawValue]
                        )
                        return
                    }
                }
                self.isStartingRecording = false
                self.presentError(error, defaultTitle: "Could not start recording")
                await self.dependencies.metrics.log(
                    name: "record_start_failed",
                    attributes: [
                        "source": source.rawValue,
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
                let source = self.selectedRecordingSource
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
                session.durationSeconds = capture.durationSeconds
                session.recordedAt = capture.endedAt
                session.updatedAt = Date()
                try await self.dependencies.store.updateSession(session)
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

                var updated = session
                updated.exports.append(
                    ExportRecord(format: format, fileName: exportedURL.lastPathComponent)
                )
                updated.updatedAt = Date()
                updated.dirtyFlags = .clean
                try await self.dependencies.store.updateSession(updated)
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
                for var session in affected {
                    session.folderId = nil
                    session.updatedAt = Date()
                    try await self.dependencies.store.updateSession(session)
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
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard session.title != trimmed else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                session.title = trimmed
                session.updatedAt = Date()
                session.dirtyFlags.titleEdited = true
                try await self.dependencies.store.updateSession(session)
                await self.reloadSessions(selectMostRecentIfNeeded: false)
                await MainActor.run {
                    self.banner = AppBanner(kind: .success, title: "Session renamed", message: trimmed)
                }
                await self.dependencies.metrics.log(name: "session_renamed", sessionId: session.id)
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

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.store.updateSession(updated)
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

        if wasSelected {
            currentProcessingTasks[sessionID]?.cancel()
            currentProcessingTasks[sessionID] = nil
            stopPlaybackAndResetState()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.store.deleteSession(id: sessionID)
                await self.dependencies.metrics.log(name: "session_deleted", sessionId: sessionID)
                await self.reloadSessions(selectMostRecentIfNeeded: wasSelected)
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
                        self.modelPreparationDetailLine = "Preparing Parakeet EOU streaming models for fast recorder startup…"
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
        guard session.status == .error else { return }
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
                        kind: .success,
                        title: "Vocabulary saved",
                        message: lineCount == 0
                            ? "No custom terms configured. Batch transcription will use base Parakeet decoding unless you add terms."
                            : "Saved \(lineCount) vocabulary entr\(lineCount == 1 ? "y" : "ies"). Use `term: alias1, alias2` for common variants."
                    )
                }
            } catch {
                await MainActor.run {
                    self.presentError(error, defaultTitle: "Could not save vocabulary terms")
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
                await self.dependencies.recorder.setLiveTranscriptionEnabled(isEnabled)
                _ = try await self.dependencies.settings.setLiveTranscriptionEnabled(isEnabled)
                await self.dependencies.metrics.log(
                    name: "live_transcript_setting_changed",
                    attributes: ["enabled": isEnabled ? "true" : "false"]
                )
                await MainActor.run {
                    self.banner = AppBanner(
                        kind: .info,
                        title: "Live transcript \(isEnabled ? "enabled" : "disabled")",
                        message: isEnabled
                            ? "New recordings can show an English-optimized live preview while recording. A multilingual v3 post-pass still runs after stop."
                            : "Recordings will skip live transcript preview and process after stop as before."
                    )
                }
            } catch {
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
        guard !isStartingRecording, !isRecording, !isStoppingRecording else { return }
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
            return IndexRailSpeakerBin(variant: speaker.styleVariant, weight: Double(count))
        }
    }

    private func launchProcessing(for sessionID: UUID) {
        currentProcessingTasks[sessionID]?.cancel()
        currentProcessingTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.applyCurrentRuntimeConfiguration()
                }
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
                            self.recorderStatusText = update.label
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
            } catch {
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
                self.currentProcessingTasks[sessionID] = nil
            }
        }
    }

    private func importAudioFile(at sourceURL: URL) {
        guard !isRecording, !isStoppingRecording else { return }

        banner = nil
        exportMessage = nil
        recorderStatusText = "Importing audio…"
        applyCurrentRuntimeConfiguration()

        Task { [weak self] in
            guard let self else { return }
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

                let sessionDirectory = await self.dependencies.store.sessionDirectoryURL(for: session.id)
                let destinationURL = sessionDirectory.appendingPathComponent(session.audioFileName)

                try self.copyImportedAudio(from: sourceURL, to: destinationURL)

                session.updatedAt = Date()
                try await self.dependencies.store.updateSession(session)

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
        do {
            activeTranscript = try await dependencies.store.loadTranscript(sessionId: session.id)
        } catch {
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
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let now = Date()
        sessions[index].status = .processing
        sessions[index].lastErrorMessage = nil
        sessions[index].updatedAt = now
        sessions[index].processing = ProcessingSummary(
            queuedAt: sessions[index].processing.queuedAt ?? now,
            startedAt: sessions[index].processing.startedAt ?? now,
            completedAt: nil,
            progressPhase: update.phase,
            progressLabel: update.label,
            progressFraction: update.fraction ?? sessions[index].processing.progressFraction
        )
    }

    private func persistTranscript(_ transcript: TranscriptDocument, sessionID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dependencies.store.saveTranscript(transcript)
                if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
                    self.sessions[index].dirtyFlags.transcriptEdited = false
                    self.sessions[index].dirtyFlags.speakerEdited = false
                    self.sessions[index].transcriptFileName = "transcript.json"
                    self.sessions[index].updatedAt = Date()
                    try await self.dependencies.store.updateSession(self.sessions[index])
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
                        self.recordingElapsedSeconds = Date().timeIntervalSince(started)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
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

    private func presentError(_ error: Error, defaultTitle: String) {
        let mapped = UserFacingErrorMapper.map(error, defaultTitle: defaultTitle)
        banner = AppBanner(kind: .error, title: mapped.title, message: mapped.message)
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
            let restoredModelRegistry = settings.modelRegistryConfiguration
            FluidAudioRuntimeConfiguration.apply(modelRegistry: restoredModelRegistry)
            await dependencies.recorder.setLiveTranscriptionEnabled(restoredLiveEnabled)
            await dependencies.transcription.setVocabularyBoostingConfiguration(restoredVocabularyBoosting)
            await MainActor.run {
                self.modelRegistryCustomBaseURL = restoredModelRegistry.normalizedBaseURL ?? ""
                self.selectedRecordingSource = restoredRecordingSource
                self.isLiveTranscriptionSupported = restoredLiveSupported
                self.isSpeakerDiarizationEnabled = settings.isSpeakerDiarizationEnabled
                self.diarizationExpectedSpeakerCountHint = settings.diarizationExpectedSpeakerCountHint.normalized()
                self.isDiarizationDebugExportEnabled = settings.isDiarizationDebugExportEnabled
                self.isVocabularyBoostingEnabled = restoredVocabularyBoosting.isEnabled
                self.customVocabularySimpleFormatTerms = restoredVocabularyBoosting.simpleFormatTerms
                self.isLiveTranscriptionEnabled = restoredLiveEnabled
                self.isDeleteAudioAfterTranscriptionEnabled = settings.isDeleteAudioAfterTranscriptionEnabled
                self.isTranscriptConfidenceVisible = settings.isTranscriptConfidenceVisible
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
        let normalized = fluidAudioStatus.lowercased()
        return normalized.contains("available") && !normalized.contains("unavailable") && !normalized.contains("mock")
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
}
