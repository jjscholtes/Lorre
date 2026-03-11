import Foundation

enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case processing
    case ready
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .recording: "Recording"
        case .processing: "Processing"
        case .ready: "Ready"
        case .error: "Error"
        }
    }
}

enum ProcessingPhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case transcribing
    case diarizing
    case assembling
    case saving

    var label: String {
        switch self {
        case .preparing: "Preparing models"
        case .transcribing: "Transcribing audio"
        case .diarizing: "Assigning speakers"
        case .assembling: "Assembling transcript"
        case .saving: "Saving transcript"
        }
    }
}

enum ProcessingComponent: String, Codable, CaseIterable, Sendable {
    case registry
    case asr
    case vad
    case diarization
    case livePreview
    case speakerEnrollment

    var label: String {
        switch self {
        case .registry: "Registry"
        case .asr: "ASR"
        case .vad: "VAD"
        case .diarization: "Diarization"
        case .livePreview: "Live Preview"
        case .speakerEnrollment: "Speaker Enrollment"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case markdown
    case plainText
    case json

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .json: "json"
        }
    }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .json: "JSON"
        }
    }
}

enum RecordingSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio
    case microphoneAndSystemAudio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .microphoneAndSystemAudio: "Microphone + system audio"
        }
    }

    var shortLabel: String {
        switch self {
        case .microphone: "Mic"
        case .systemAudio: "System"
        case .microphoneAndSystemAudio: "Mic + Sys"
        }
    }

    var includesMicrophone: Bool {
        switch self {
        case .microphone, .microphoneAndSystemAudio:
            true
        case .systemAudio:
            false
        }
    }

    var includesSystemAudio: Bool {
        switch self {
        case .systemAudio, .microphoneAndSystemAudio:
            true
        case .microphone:
            false
        }
    }
}

enum SpeakerBadgeVariant: String, Codable, CaseIterable, Sendable {
    case filled
    case outline
    case doubleOutline
    case dashed
}

struct SessionDirtyFlags: Codable, Equatable, Sendable {
    var titleEdited: Bool = false
    var transcriptEdited: Bool = false
    var speakerEdited: Bool = false

    static let clean = SessionDirtyFlags()

    var hasChanges: Bool {
        titleEdited || transcriptEdited || speakerEdited
    }
}

struct ProcessingSummary: Codable, Equatable, Sendable {
    var queuedAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var progressPhase: ProcessingPhase?
    var progressLabel: String?
    var progressFraction: Double?

    static let none = ProcessingSummary(
        queuedAt: nil,
        startedAt: nil,
        completedAt: nil,
        progressPhase: nil,
        progressLabel: nil,
        progressFraction: nil
    )
}

struct ExportRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var format: ExportFormat
    var fileName: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        format: ExportFormat,
        fileName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.format = format
        self.fileName = fileName
        self.createdAt = createdAt
    }
}

struct SessionManifest: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var folderId: String?
    var status: SessionStatus
    var createdAt: Date
    var updatedAt: Date
    var recordedAt: Date?
    var durationSeconds: Double?
    var notes: String?
    var recordingSource: RecordingSource
    var audioFileName: String
    var microphoneStemFileName: String?
    var systemAudioStemFileName: String?
    var transcriptFileName: String?
    var exports: [ExportRecord]
    var processing: ProcessingSummary
    var lastErrorMessage: String?
    var dirtyFlags: SessionDirtyFlags

    init(
        id: UUID = UUID(),
        title: String,
        folderId: String? = nil,
        status: SessionStatus,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recordedAt: Date? = nil,
        durationSeconds: Double? = nil,
        notes: String? = nil,
        recordingSource: RecordingSource = .microphone,
        audioFileName: String,
        microphoneStemFileName: String? = nil,
        systemAudioStemFileName: String? = nil,
        transcriptFileName: String? = nil,
        exports: [ExportRecord] = [],
        processing: ProcessingSummary = .none,
        lastErrorMessage: String? = nil,
        dirtyFlags: SessionDirtyFlags = .clean
    ) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.notes = notes
        self.recordingSource = recordingSource
        self.audioFileName = audioFileName
        self.microphoneStemFileName = microphoneStemFileName
        self.systemAudioStemFileName = systemAudioStemFileName
        self.transcriptFileName = transcriptFileName
        self.exports = exports
        self.processing = processing
        self.lastErrorMessage = lastErrorMessage
        self.dirtyFlags = dirtyFlags
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Session" : trimmed
    }

    var normalizedNotes: String {
        notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case folderId
        case status
        case createdAt
        case updatedAt
        case recordedAt
        case durationSeconds
        case notes
        case recordingSource
        case audioFileName
        case microphoneStemFileName
        case systemAudioStemFileName
        case transcriptFileName
        case exports
        case processing
        case lastErrorMessage
        case dirtyFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.folderId = try container.decodeIfPresent(String.self, forKey: .folderId)
        self.status = try container.decode(SessionStatus.self, forKey: .status)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.recordedAt = try container.decodeIfPresent(Date.self, forKey: .recordedAt)
        self.durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.recordingSource = try container.decodeIfPresent(RecordingSource.self, forKey: .recordingSource) ?? .microphone
        self.audioFileName = try container.decode(String.self, forKey: .audioFileName)
        self.microphoneStemFileName = try container.decodeIfPresent(String.self, forKey: .microphoneStemFileName)
        self.systemAudioStemFileName = try container.decodeIfPresent(String.self, forKey: .systemAudioStemFileName)
        self.transcriptFileName = try container.decodeIfPresent(String.self, forKey: .transcriptFileName)
        self.exports = try container.decodeIfPresent([ExportRecord].self, forKey: .exports) ?? []
        self.processing = try container.decodeIfPresent(ProcessingSummary.self, forKey: .processing) ?? .none
        self.lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        self.dirtyFlags = try container.decodeIfPresent(SessionDirtyFlags.self, forKey: .dirtyFlags) ?? .clean
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(recordedAt, forKey: .recordedAt)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(recordingSource, forKey: .recordingSource)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encodeIfPresent(microphoneStemFileName, forKey: .microphoneStemFileName)
        try container.encodeIfPresent(systemAudioStemFileName, forKey: .systemAudioStemFileName)
        try container.encodeIfPresent(transcriptFileName, forKey: .transcriptFileName)
        try container.encode(exports, forKey: .exports)
        try container.encode(processing, forKey: .processing)
        try container.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try container.encode(dirtyFlags, forKey: .dirtyFlags)
    }
}

struct SpeakerProfile: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var styleVariant: SpeakerBadgeVariant
    var isUserRenamed: Bool

    var isKnownSpeaker: Bool {
        id != "UNK" && !id.uppercased().hasPrefix("S")
    }

    var safeDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return id == "UNK" ? "Unknown speaker" : "Unassigned"
        }
        return trimmed
    }

    static func defaultProfile(id: String) -> SpeakerProfile {
        let variant: SpeakerBadgeVariant
        switch id {
        case "S1": variant = .filled
        case "S2": variant = .outline
        case "S3": variant = .doubleOutline
        default: variant = .dashed
        }
        return SpeakerProfile(
            id: id,
            displayName: id == "UNK" ? "Unknown speaker" : "Speaker \(id)",
            styleVariant: variant,
            isUserRenamed: false
        )
    }
}

struct KnownSpeakerReferenceClip: Codable, Equatable, Sendable {
    var sourceFileName: String
    var storedFileName: String
    var durationSeconds: Double
    var sampleRate: Int
    var importedAt: Date
}

struct KnownSpeakerEnrollmentData: Equatable, Sendable {
    var embedding: [Float]
    var durationSeconds: Double
    var sampleRate: Int
}

struct KnownSpeaker: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var embedding: [Float]
    var styleVariant: SpeakerBadgeVariant
    var createdAt: Date
    var updatedAt: Date
    var enrollmentCount: Int
    var referenceClip: KnownSpeakerReferenceClip?

    init(
        id: String,
        displayName: String,
        embedding: [Float],
        styleVariant: SpeakerBadgeVariant,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        enrollmentCount: Int = 1,
        referenceClip: KnownSpeakerReferenceClip? = nil
    ) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.embedding = embedding
        self.styleVariant = styleVariant
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enrollmentCount = max(1, enrollmentCount)
        self.referenceClip = referenceClip
    }

    var safeDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var speakerProfile: SpeakerProfile {
        SpeakerProfile(
            id: id,
            displayName: safeDisplayName,
            styleVariant: styleVariant,
            isUserRenamed: true
        )
    }
}

struct ModelRegistryConfiguration: Codable, Equatable, Sendable {
    var customBaseURL: String?

    init(customBaseURL: String? = nil) {
        self.customBaseURL = Self.normalize(customBaseURL)
    }

    var normalizedBaseURL: String? {
        Self.normalize(customBaseURL)
    }

    var isDefault: Bool {
        normalizedBaseURL == nil
    }

    var summaryLabel: String {
        normalizedBaseURL ?? "https://huggingface.co"
    }

    static func normalize(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? nil : normalized
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var startMs: Int
    var endMs: Int
    var text: String
    var speakerId: String?
    var sourceSpeakerId: String?
    var confidence: Double?
    var isEdited: Bool
    var lastEditedAt: Date?

    init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        text: String,
        speakerId: String?,
        sourceSpeakerId: String? = nil,
        confidence: Double? = nil,
        isEdited: Bool = false,
        lastEditedAt: Date? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
        self.sourceSpeakerId = sourceSpeakerId
        self.confidence = confidence
        self.isEdited = isEdited
        self.lastEditedAt = lastEditedAt
    }
}

struct TranscriptDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var sessionId: UUID
    var languageHint: String?
    var sourceEngine: String
    var segments: [TranscriptSegment]
    var speakers: [SpeakerProfile]
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        sessionId: UUID,
        languageHint: String? = "en",
        sourceEngine: String,
        segments: [TranscriptSegment],
        speakers: [SpeakerProfile],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.languageHint = languageHint
        self.sourceEngine = sourceEngine
        self.segments = segments
        self.speakers = speakers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func speaker(for id: String?) -> SpeakerProfile {
        guard let id else {
            return speakers.first(where: { $0.id == "UNK" }) ?? .defaultProfile(id: "UNK")
        }
        return speakers.first(where: { $0.id == id }) ?? .defaultProfile(id: id)
    }
}

struct NewSessionDraft: Sendable {
    var title: String
    var folderId: String?
    var status: SessionStatus
    var durationSeconds: Double?
    var recordingSource: RecordingSource
    var audioFileName: String
    var microphoneStemFileName: String?
    var systemAudioStemFileName: String?
    var recordedAt: Date?
}

struct RecordingFileLayout: Equatable, Sendable {
    var audioFileName: String
    var microphoneStemFileName: String?
    var systemAudioStemFileName: String?
}

struct RecordingRequest: Sendable {
    var source: RecordingSource
}

struct RecordingCapture: Sendable {
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
}

struct RecorderLiveMonitorEvent: Equatable, Sendable {
    var meterLevel: Double?
    var preview: LiveTranscriptPreview?
}

struct LiveTranscriptPreview: Equatable, Sendable {
    var confirmedText: String
    var partialText: String
    var isFinalizing: Bool
    var errorMessage: String?
    var activeSpeakerID: String?
    var activeSpeakerDisplayName: String?
    var activeSpeakerConfidence: Double?
    var updatedAt: Date?

    init(
        confirmedText: String = "",
        partialText: String = "",
        isFinalizing: Bool = false,
        errorMessage: String? = nil,
        activeSpeakerID: String? = nil,
        activeSpeakerDisplayName: String? = nil,
        activeSpeakerConfidence: Double? = nil,
        updatedAt: Date? = nil
    ) {
        self.confirmedText = confirmedText
        self.partialText = partialText
        self.isFinalizing = isFinalizing
        self.errorMessage = errorMessage
        self.activeSpeakerID = activeSpeakerID
        self.activeSpeakerDisplayName = activeSpeakerDisplayName
        self.activeSpeakerConfidence = activeSpeakerConfidence
        self.updatedAt = updatedAt
    }

    var hasContent: Bool {
        !confirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSpeakerHint: Bool {
        !(activeSpeakerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var combinedText: String {
        let confirmed = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if confirmed.isEmpty { return partial }
        if partial.isEmpty { return confirmed }
        return "\(confirmed) \(partial)"
    }
}

struct TranscriptionTokenTiming: Equatable, Sendable {
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
}

struct TranscriptionUtterance: Equatable, Sendable {
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var tokenTimings: [TranscriptionTokenTiming]? = nil
}

struct TranscriptionResult: Equatable, Sendable {
    var engineName: String
    var utterances: [TranscriptionUtterance]
}

struct DiarizationSpan: Equatable, Sendable {
    var startMs: Int
    var endMs: Int
    var speakerId: String
    var sourceSpeakerId: String? = nil
}

struct DiarizationResult: Equatable, Sendable {
    var spans: [DiarizationSpan]
    var speakerProfiles: [SpeakerProfile] = []
}

struct DiarizationSpeakerCountHint: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case auto
        case exact
        case range
    }

    var mode: Mode
    var exactCount: Int?
    var minCount: Int?
    var maxCount: Int?

    static let auto = DiarizationSpeakerCountHint(mode: .auto, exactCount: nil, minCount: nil, maxCount: nil)

    static var tuningPresets: [DiarizationSpeakerCountHint] {
        [
            .auto,
            .exact(1),
            .exact(2),
            .exact(3),
            .exact(4),
            .range(min: 2, max: 4),
            .range(min: 2, max: 6)
        ]
    }

    static func exact(_ count: Int) -> DiarizationSpeakerCountHint {
        DiarizationSpeakerCountHint(mode: .exact, exactCount: count, minCount: nil, maxCount: nil).normalized()
    }

    static func range(min: Int, max: Int) -> DiarizationSpeakerCountHint {
        DiarizationSpeakerCountHint(mode: .range, exactCount: nil, minCount: min, maxCount: max).normalized()
    }

    func normalized() -> DiarizationSpeakerCountHint {
        let clamp: (Int?) -> Int? = { value in
            guard let value else { return nil }
            return min(20, max(1, value))
        }

        switch mode {
        case .auto:
            return .auto
        case .exact:
            guard let exact = clamp(exactCount) else { return .auto }
            return DiarizationSpeakerCountHint(mode: .exact, exactCount: exact, minCount: nil, maxCount: nil)
        case .range:
            let minValue = clamp(minCount)
            let maxValue = clamp(maxCount)
            guard var lower = minValue ?? maxValue, var upper = maxValue ?? minValue else {
                return .auto
            }
            if lower > upper { swap(&lower, &upper) }
            return DiarizationSpeakerCountHint(mode: .range, exactCount: nil, minCount: lower, maxCount: upper)
        }
    }

    var shortLabel: String {
        switch normalized() {
        case .auto:
            return "Auto"
        case let value where value.mode == .exact:
            return "=\(value.exactCount ?? 0)"
        case let value where value.mode == .range:
            return "\(value.minCount ?? 0)-\(value.maxCount ?? 0)"
        default:
            return "Auto"
        }
    }

    var detailLabel: String {
        switch normalized() {
        case .auto:
            return "Auto"
        case let value where value.mode == .exact:
            return "Exact \(value.exactCount ?? 0)"
        case let value where value.mode == .range:
            return "Range \(value.minCount ?? 0)-\(value.maxCount ?? 0)"
        default:
            return "Auto"
        }
    }
}

struct ProcessingUpdate: Sendable {
    var phase: ProcessingPhase
    var component: ProcessingComponent?
    var label: String
    var detail: String?
    var fraction: Double?

    init(
        phase: ProcessingPhase,
        component: ProcessingComponent? = nil,
        label: String,
        detail: String? = nil,
        fraction: Double? = nil
    ) {
        self.phase = phase
        self.component = component
        self.label = label
        self.detail = detail
        self.fraction = fraction
    }
}

struct ModelPreparationSnapshot: Codable, Equatable, Sendable {
    var preparedAt: Date
    var runtimeStatusSummary: String
    var componentVersionsSummary: String
}

struct VocabularyBoostingConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var simpleFormatTerms: String

    init(
        isEnabled: Bool = false,
        simpleFormatTerms: String = ""
    ) {
        self.isEnabled = isEnabled
        self.simpleFormatTerms = simpleFormatTerms
    }
}

struct SessionFolder: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var createdAt: Date

    init(id: String? = nil, name: String, createdAt: Date = Date()) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = normalizedName.isEmpty ? "New Folder" : normalizedName
        self.name = fallback
        self.id = id ?? SessionFolder.makeID(from: fallback)
        self.createdAt = createdAt
    }

    static func makeID(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = trimmed.split { !$0.isLetter && !$0.isNumber }
        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? UUID().uuidString.lowercased() : slug
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var updatedAt: Date
    var modelPreparation: ModelPreparationSnapshot?
    var modelRegistryConfiguration: ModelRegistryConfiguration
    var selectedRecordingSource: RecordingSource
    var isSpeakerDiarizationEnabled: Bool
    var diarizationExpectedSpeakerCountHint: DiarizationSpeakerCountHint
    var isDiarizationDebugExportEnabled: Bool
    var isLiveTranscriptionEnabled: Bool
    var isTranscriptConfidenceVisible: Bool
    var vocabularyBoosting: VocabularyBoostingConfiguration
    var folders: [SessionFolder]
    var sidebarExpandedViewFilterIDs: [String]
    var sidebarExpandedFolderIDs: [String]

    init(
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        modelPreparation: ModelPreparationSnapshot? = nil,
        modelRegistryConfiguration: ModelRegistryConfiguration = .init(),
        selectedRecordingSource: RecordingSource = .microphone,
        isSpeakerDiarizationEnabled: Bool = true,
        diarizationExpectedSpeakerCountHint: DiarizationSpeakerCountHint = .auto,
        isDiarizationDebugExportEnabled: Bool = false,
        isLiveTranscriptionEnabled: Bool = false,
        isTranscriptConfidenceVisible: Bool = false,
        vocabularyBoosting: VocabularyBoostingConfiguration = .init(),
        folders: [SessionFolder] = [],
        sidebarExpandedViewFilterIDs: [String] = [],
        sidebarExpandedFolderIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.modelPreparation = modelPreparation
        self.modelRegistryConfiguration = modelRegistryConfiguration
        self.selectedRecordingSource = selectedRecordingSource
        self.isSpeakerDiarizationEnabled = isSpeakerDiarizationEnabled
        self.diarizationExpectedSpeakerCountHint = diarizationExpectedSpeakerCountHint.normalized()
        self.isDiarizationDebugExportEnabled = isDiarizationDebugExportEnabled
        self.isLiveTranscriptionEnabled = isLiveTranscriptionEnabled
        self.isTranscriptConfidenceVisible = isTranscriptConfidenceVisible
        self.vocabularyBoosting = vocabularyBoosting
        self.folders = folders
        self.sidebarExpandedViewFilterIDs = sidebarExpandedViewFilterIDs
        self.sidebarExpandedFolderIDs = sidebarExpandedFolderIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case modelPreparation
        case modelRegistryConfiguration
        case selectedRecordingSource
        case isSpeakerDiarizationEnabled
        case diarizationExpectedSpeakerCountHint
        case isDiarizationDebugExportEnabled
        case isLiveTranscriptionEnabled
        case isTranscriptConfidenceVisible
        case vocabularyBoosting
        case folders
        case sidebarExpandedViewFilterIDs
        case sidebarExpandedFolderIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.modelPreparation = try container.decodeIfPresent(ModelPreparationSnapshot.self, forKey: .modelPreparation)
        self.modelRegistryConfiguration = try container.decodeIfPresent(ModelRegistryConfiguration.self, forKey: .modelRegistryConfiguration) ?? .init()
        self.selectedRecordingSource = try container.decodeIfPresent(RecordingSource.self, forKey: .selectedRecordingSource) ?? .microphone
        self.isSpeakerDiarizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSpeakerDiarizationEnabled) ?? true
        self.diarizationExpectedSpeakerCountHint = (
            try container.decodeIfPresent(DiarizationSpeakerCountHint.self, forKey: .diarizationExpectedSpeakerCountHint)
        )?.normalized() ?? .auto
        self.isDiarizationDebugExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .isDiarizationDebugExportEnabled) ?? false
        self.isLiveTranscriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLiveTranscriptionEnabled) ?? false
        self.isTranscriptConfidenceVisible = try container.decodeIfPresent(Bool.self, forKey: .isTranscriptConfidenceVisible) ?? false
        self.vocabularyBoosting = try container.decodeIfPresent(VocabularyBoostingConfiguration.self, forKey: .vocabularyBoosting) ?? .init()
        self.folders = try container.decodeIfPresent([SessionFolder].self, forKey: .folders) ?? []
        self.sidebarExpandedViewFilterIDs = try container.decodeIfPresent([String].self, forKey: .sidebarExpandedViewFilterIDs) ?? []
        self.sidebarExpandedFolderIDs = try container.decodeIfPresent([String].self, forKey: .sidebarExpandedFolderIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(modelPreparation, forKey: .modelPreparation)
        try container.encode(modelRegistryConfiguration, forKey: .modelRegistryConfiguration)
        try container.encode(selectedRecordingSource, forKey: .selectedRecordingSource)
        try container.encode(isSpeakerDiarizationEnabled, forKey: .isSpeakerDiarizationEnabled)
        try container.encode(diarizationExpectedSpeakerCountHint.normalized(), forKey: .diarizationExpectedSpeakerCountHint)
        try container.encode(isDiarizationDebugExportEnabled, forKey: .isDiarizationDebugExportEnabled)
        try container.encode(isLiveTranscriptionEnabled, forKey: .isLiveTranscriptionEnabled)
        try container.encode(isTranscriptConfidenceVisible, forKey: .isTranscriptConfidenceVisible)
        try container.encode(vocabularyBoosting, forKey: .vocabularyBoosting)
        try container.encode(folders, forKey: .folders)
        try container.encode(sidebarExpandedViewFilterIDs, forKey: .sidebarExpandedViewFilterIDs)
        try container.encode(sidebarExpandedFolderIDs, forKey: .sidebarExpandedFolderIDs)
    }
}
