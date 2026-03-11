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

        var manifests: [SessionManifest] = []
        for url in urls {
            let sessionJSON = url.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: sessionJSON.path(percentEncoded: false)) else {
                continue
            }
            do {
                let data = try Data(contentsOf: sessionJSON)
                var manifest = try Self.decoder.decode(SessionManifest.self, from: data)
                if manifest.id.uuidString.lowercased() != url.lastPathComponent.lowercased() {
                    manifest.id = UUID(uuidString: url.lastPathComponent) ?? manifest.id
                }
                manifests.append(manifest)
            } catch {
                // Skip corrupted sessions for now; surface via status in a later recovery pass.
                continue
            }
        }

        return manifests.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func loadSession(id: UUID) async throws -> SessionManifest? {
        let url = sessionManifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(SessionManifest.self, from: data)
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
        try save(session)
    }

    func deleteSession(id: UUID) async throws {
        try ensureBaseDirectories()
        let sessionDir = sessionsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionDir.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: sessionDir)
    }

    func loadTranscript(sessionId: UUID) async throws -> TranscriptDocument? {
        let url = transcriptURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(TranscriptDocument.self, from: data)
    }

    func saveTranscript(_ transcript: TranscriptDocument) async throws {
        try ensureBaseDirectories()
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
