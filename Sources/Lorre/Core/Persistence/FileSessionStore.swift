import Foundation

actor FileSessionStore: SessionStore {
    private let baseURL: URL
    private let sessionsRootURL: URL

    init(baseURL: URL = FileSessionStore.defaultBaseURL()) {
        self.baseURL = baseURL
        self.sessionsRootURL = baseURL.appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultBaseURL() -> URL {
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("Lorre", isDirectory: true)
        }
        return fileManager.temporaryDirectory.appendingPathComponent("Lorre", isDirectory: true)
    }

    func loadSessions() async throws -> [SessionManifest] {
        try ensureBaseDirectories()

        let urls = try FileManager.default.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let manifests = await Task.detached(priority: .utility) {
            urls.compactMap { url -> SessionManifest? in
            let sessionJSON = url.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: sessionJSON.path(percentEncoded: false)) else {
                return nil
            }
            do {
                let data = try Data(contentsOf: sessionJSON)
                var manifest = try Self.decoder.decode(SessionManifest.self, from: data)
                if manifest.id.uuidString.lowercased() != url.lastPathComponent.lowercased() {
                    manifest.id = UUID(uuidString: url.lastPathComponent) ?? manifest.id
                }
                return manifest
            } catch {
                return Self.damagedSessionManifest(for: url, manifestURL: sessionJSON, error: error)
            }
            }
        }.value

        return manifests.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func loadSession(id: UUID) async throws -> SessionManifest? {
        try loadSessionFromDisk(id: id)
    }

    private func loadSessionFromDisk(id: UUID) throws -> SessionManifest? {
        let url = sessionManifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        var manifest = try Self.decoder.decode(SessionManifest.self, from: data)
        if manifest.id != id {
            manifest.id = id
        }
        return manifest
    }

    func createSession(_ draft: NewSessionDraft) async throws -> SessionManifest {
        try ensureBaseDirectories()
        let now = Date()
        let session = SessionManifest(
            title: draft.title,
            folderId: draft.folderId,
            status: draft.status,
            createdAt: now,
            updatedAt: now,
            recordedAt: draft.recordedAt,
            durationSeconds: draft.durationSeconds,
            recordingSource: draft.recordingSource,
            audioFileName: draft.audioFileName,
            microphoneStemFileName: draft.microphoneStemFileName,
            systemAudioStemFileName: draft.systemAudioStemFileName,
            transcriptFileName: nil,
            exports: [],
            processing: draft.status == .processing
                ? ProcessingSummary(
                    queuedAt: now,
                    startedAt: nil,
                    completedAt: nil,
                    progressPhase: .preparing,
                    progressLabel: "Queued",
                    progressFraction: 0
                )
                : .none,
            lastErrorMessage: nil,
            dirtyFlags: .clean
        )
        try save(session)
        return session
    }

    func updateSession(_ session: SessionManifest) async throws {
        try ensureBaseDirectories()
        guard FileManager.default.fileExists(atPath: sessionManifestURL(for: session.id).path(percentEncoded: false)) else {
            throw LorreError.sessionNotFound
        }
        try save(session)
    }

    func updateSession(
        id: UUID,
        _ transform: @Sendable (inout SessionManifest) throws -> Void
    ) async throws -> SessionManifest {
        try ensureBaseDirectories()
        guard var session = try loadSessionFromDisk(id: id) else {
            throw LorreError.sessionNotFound
        }
        try transform(&session)
        session.id = id
        try save(session)
        return session
    }

    func deleteSession(id: UUID) async throws {
        try ensureBaseDirectories()
        let sessionDir = sessionsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionDir.path(percentEncoded: false)) else { return }
        do {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: sessionDir, resultingItemURL: &trashedURL)
        } catch {
            try fileManager.removeItem(at: sessionDir)
        }
    }

    func loadTranscript(sessionId: UUID) async throws -> TranscriptDocument? {
        let url = transcriptURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(TranscriptDocument.self, from: data)
    }

    func saveTranscript(_ transcript: TranscriptDocument) async throws {
        try ensureBaseDirectories()
        guard FileManager.default.fileExists(atPath: sessionManifestURL(for: transcript.sessionId).path(percentEncoded: false)) else {
            throw LorreError.sessionNotFound
        }
        let url = transcriptURL(for: transcript.sessionId)
        let encoded = try Self.encoder.encode(transcript)
        try AtomicFileWriter.write(encoded, to: url)
    }

    func sessionDirectoryURL(for sessionId: UUID) async -> URL {
        sessionsRootURL.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    func exportDirectoryURL(for sessionId: UUID) async -> URL {
        sessionsRootURL
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
    }

    private func sessionManifestURL(for id: UUID) -> URL {
        sessionsRootURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private func transcriptURL(for sessionId: UUID) -> URL {
        sessionsRootURL
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
            .appendingPathComponent("transcript.json")
    }

    private func save(_ session: SessionManifest) throws {
        let sessionDir = sessionsRootURL.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("session.json")
        let encoded = try Self.encoder.encode(session)
        try AtomicFileWriter.write(encoded, to: url)
    }

    private func ensureBaseDirectories() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)
    }

    private static func damagedSessionManifest(for folderURL: URL, manifestURL: URL, error: Error) -> SessionManifest? {
        guard let id = UUID(uuidString: folderURL.lastPathComponent) else { return nil }
        let fileValues = try? manifestURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let fallbackDate = Date()
        let createdAt = fileValues?.creationDate ?? fileValues?.contentModificationDate ?? fallbackDate
        let updatedAt = fileValues?.contentModificationDate ?? createdAt
        return SessionManifest(
            id: id,
            title: "Damaged Session",
            status: .error,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recordingSource: .microphone,
            audioFileName: "__damaged_session_audio_unavailable__",
            audioDeletedAt: updatedAt,
            processing: ProcessingSummary(
                queuedAt: nil,
                startedAt: nil,
                completedAt: updatedAt,
                progressPhase: nil,
                progressLabel: "Recovery needed",
                progressFraction: nil
            ),
            lastErrorMessage: "Session metadata could not be read. Delete this session or inspect session.json in the session folder. \(error.localizedDescription)"
        )
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
