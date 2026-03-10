import Foundation

actor AppSettingsStore {
    private let fileURL: URL

    init(baseURL: URL = FileSessionStore.defaultBaseURL()) {
        self.fileURL = baseURL.appendingPathComponent("settings.json")
    }

    func load() async throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return AppSettings()
        }

        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(AppSettings.self, from: data)
    }

    @discardableResult
    func recordModelPreparation(_ snapshot: ModelPreparationSnapshot) async throws -> AppSettings {
        var settings = try await load()
        settings.modelPreparation = snapshot
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setModelRegistryConfiguration(_ configuration: ModelRegistryConfiguration) async throws -> AppSettings {
        var settings = try await load()
        settings.modelRegistryConfiguration = ModelRegistryConfiguration(
            customBaseURL: configuration.normalizedBaseURL
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setSpeakerDiarizationEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try await load()
        settings.isSpeakerDiarizationEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDiarizationExpectedSpeakerCountHint(_ hint: DiarizationSpeakerCountHint) async throws -> AppSettings {
        var settings = try await load()
        settings.diarizationExpectedSpeakerCountHint = hint.normalized()
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setDiarizationDebugExportEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try await load()
        settings.isDiarizationDebugExportEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async throws -> AppSettings {
        var settings = try await load()
        settings.isLiveTranscriptionEnabled = isEnabled
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func setTranscriptConfidenceVisible(_ isVisible: Bool) async throws -> AppSettings {
        var settings = try await load()
        settings.isTranscriptConfidenceVisible = isVisible
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    @discardableResult
    func saveVocabularyBoosting(_ configuration: VocabularyBoostingConfiguration) async throws -> AppSettings {
        var settings = try await load()
        settings.vocabularyBoosting = VocabularyBoostingConfiguration(
            isEnabled: configuration.isEnabled,
            simpleFormatTerms: configuration.simpleFormatTerms
        )
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    func loadFolders() async throws -> [SessionFolder] {
        let settings = try await load()
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

        var settings = try await load()
        let baseID = SessionFolder.makeID(from: trimmed)
        var candidateID = baseID
        var suffix = 2
        while settings.folders.contains(where: { $0.id == candidateID || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
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

        var settings = try await load()
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
        var settings = try await load()
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
        var settings = try await load()
        settings.sidebarExpandedViewFilterIDs = expandedViewFilterIDs
        settings.sidebarExpandedFolderIDs = expandedFolderIDs
        settings.updatedAt = Date()
        try save(settings)
        return settings
    }

    func save(_ settings: AppSettings) throws {
        let encoded = try Self.encoder.encode(settings)
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
