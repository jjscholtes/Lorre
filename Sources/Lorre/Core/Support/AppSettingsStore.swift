import Foundation

actor AppSettingsStore {
    private let fileURL: URL

    init(baseURL: URL = FileSessionStore.defaultBaseURL()) {
        self.fileURL = baseURL.appendingPathComponent("settings.json")
    }

    func load() async throws -> AppSettings {
        try loadFromDisk()
    }

    private func loadFromDisk() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return AppSettings()
        }

        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(AppSettings.self, from: data).migratedToCurrentSchema
    }

    @discardableResult
    func recordModelPreparation(_ snapshot: ModelPreparationSnapshot) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.modelPreparation = snapshot
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setModelRegistryConfiguration(_ configuration: ModelRegistryConfiguration) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.modelRegistryConfiguration = ModelRegistryConfiguration(
            customBaseURL: configuration.normalizedBaseURL
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setSelectedRecordingSource(_ source: RecordingSource) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.selectedRecordingSource = source
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setSpeakerDiarizationEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.isSpeakerDiarizationEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDiarizationEngine(_ engine: DiarizationEngine) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.diarizationEngine = engine
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDiarizationExpectedSpeakerCountHint(_ hint: DiarizationSpeakerCountHint) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.diarizationExpectedSpeakerCountHint = hint.normalized()
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDiarizationDebugExportEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.isDiarizationDebugExportEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.isLiveTranscriptionEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDeleteAudioAfterTranscriptionEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.isDeleteAudioAfterTranscriptionEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setTranscriptConfidenceVisible(_ isVisible: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.isTranscriptConfidenceVisible = isVisible
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func saveAutomaticMarkdownExportConfiguration(
        _ configuration: AutomaticMarkdownExportConfiguration
    ) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.automaticMarkdownExport = configuration
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setAutomaticMarkdownExportEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.automaticMarkdownExport = AutomaticMarkdownExportConfiguration(
            isEnabled: isEnabled,
            folderPath: settings.automaticMarkdownExport.folderPath,
            fileNameTemplate: settings.automaticMarkdownExport.fileNameTemplate
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setAutomaticMarkdownExportFolderURL(_ folderURL: URL?) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.automaticMarkdownExport = AutomaticMarkdownExportConfiguration(
            isEnabled: folderURL != nil,
            folderPath: folderURL?.path(percentEncoded: false),
            fileNameTemplate: settings.automaticMarkdownExport.fileNameTemplate
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setAutomaticMarkdownExportFileNameTemplate(_ template: String) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.automaticMarkdownExport = AutomaticMarkdownExportConfiguration(
            isEnabled: settings.automaticMarkdownExport.isEnabled,
            folderPath: settings.automaticMarkdownExport.folderPath,
            fileNameTemplate: template
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func saveGlobalDictationConfiguration(
        _ configuration: GlobalDictationConfiguration
    ) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.globalDictation = configuration
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setGlobalDictationEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.globalDictation.isEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setGlobalDictationShortcut(_ shortcut: GlobalDictationShortcutChoice) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.globalDictation.shortcut = shortcut
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func saveCallWatcherConfiguration(_ configuration: CallWatcherConfiguration) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.callWatcher = configuration
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setCallWatcherEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.callWatcher = CallWatcherConfiguration(
            isEnabled: isEnabled,
            defaultRecordingSource: settings.callWatcher.defaultRecordingSource,
            cooldownSeconds: settings.callWatcher.cooldownSeconds
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setCallWatcherDefaultRecordingSource(_ source: RecordingSource) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.callWatcher = CallWatcherConfiguration(
            isEnabled: settings.callWatcher.isEnabled,
            defaultRecordingSource: source,
            cooldownSeconds: settings.callWatcher.cooldownSeconds
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func saveVocabularyBoosting(_ configuration: VocabularyBoostingConfiguration) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.vocabularyBoosting = VocabularyBoostingConfiguration(
            isEnabled: configuration.isEnabled,
            simpleFormatTerms: configuration.simpleFormatTerms
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setBatchTranscriptionConfiguration(_ configuration: BatchTranscriptionConfiguration) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.batchTranscription = configuration.normalized
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setLiveTranscriptionPreset(_ preset: LiveTranscriptionPreset) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.liveTranscriptionPreset = preset
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    func loadFolders() async throws -> [SessionFolder] {
        let settings = try loadFromDisk()
        return settings.folders.sorted { lhs, rhs in
            if lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    func createFolder(named name: String) async throws -> SessionFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LorreError.persistenceFailed("Folder name cannot be empty.")
        }

        var settings = try loadFromDisk()
        let duplicateName = settings.folders.contains { folder in
            folder.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicateName else {
            throw LorreError.persistenceFailed("A folder with that name already exists.")
        }

        let baseID = SessionFolder.makeID(from: trimmed)
        var candidateID = baseID
        var suffix = 2
        while settings.folders.contains(where: { $0.id == candidateID }) {
            candidateID = "\(baseID)-\(suffix)"
            suffix += 1
        }

        let folder = SessionFolder(id: candidateID, name: trimmed)
        settings.folders.append(folder)
        settings.updatedAt = Date()
        try save(settings)
        return folder
    }

    @discardableResult
    func renameFolder(id: String, to newName: String) async throws -> SessionFolder {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LorreError.persistenceFailed("Folder name cannot be empty.")
        }

        var settings = try loadFromDisk()
        guard let index = settings.folders.firstIndex(where: { $0.id == id }) else {
            throw LorreError.persistenceFailed("Folder not found.")
        }
        let duplicate = settings.folders.contains { folder in
            folder.id != id && folder.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicate else {
            throw LorreError.persistenceFailed("A folder with that name already exists.")
        }

        settings.folders[index].name = trimmed
        settings.updatedAt = Date()
        try save(settings)
        return settings.folders[index]
    }

    func deleteFolder(id: String) async throws {
        var settings = try loadFromDisk()
        let before = settings.folders.count
        settings.folders.removeAll { $0.id == id }
        guard settings.folders.count != before else {
            throw LorreError.persistenceFailed("Folder not found.")
        }
        settings.updatedAt = Date()
        settings.sidebarExpandedFolderIDs.removeAll { $0 == id }
        try save(settings)
    }

    @discardableResult
    func saveSidebarExpansion(expandedViewFilterIDs: [String], expandedFolderIDs: [String]) async throws -> AppSettings {
        var settings = try loadFromDisk()
        settings.sidebarExpandedViewFilterIDs = expandedViewFilterIDs
        settings.sidebarExpandedFolderIDs = expandedFolderIDs
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    func save(_ settings: AppSettings) throws {
        let encoded = try Self.encoder.encode(settings.migratedToCurrentSchema)
        try AtomicFileWriter.write(encoded, to: fileURL)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
