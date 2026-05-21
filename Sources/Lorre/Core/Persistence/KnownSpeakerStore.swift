import Foundation

actor KnownSpeakerStore {
    private let baseURL: URL
    private let fileURL: URL
    private let samplesDirectoryURL: URL

    init(baseURL: URL = FileSessionStore.defaultBaseURL()) {
        self.baseURL = baseURL
        self.fileURL = baseURL.appendingPathComponent("known-speakers.json")
        self.samplesDirectoryURL = baseURL.appendingPathComponent("known-speaker-samples", isDirectory: true)
    }

    func load() async throws -> [KnownSpeaker] {
        try loadFromDisk()
    }

    private func loadFromDisk() throws -> [KnownSpeaker] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let speakers = try Self.decoder.decode([KnownSpeaker].self, from: data)
        return speakers.sorted(by: Self.sortComparator)
    }

    @discardableResult
    func saveNewSpeaker(
        displayName: String,
        embedding: [Float],
        referenceAudioURL: URL?,
        enrollmentData: KnownSpeakerEnrollmentData?,
        preferredVariant: SpeakerBadgeVariant? = nil
    ) async throws -> KnownSpeaker {
        var speakers = try loadFromDisk()
        let nextID = Self.nextSpeakerID(from: speakers)
        let variant = preferredVariant ?? Self.nextVariant(for: speakers.count)
        let referenceClip = try copyReferenceClipIfNeeded(
            speakerID: nextID,
            sourceURL: referenceAudioURL,
            enrollmentData: enrollmentData
        )
        let speaker = KnownSpeaker(
            id: nextID,
            displayName: displayName,
            embedding: embedding,
            styleVariant: variant,
            referenceClip: referenceClip
        )
        speakers.append(speaker)
        try saveAll(speakers)
        return speaker
    }

    @discardableResult
    func updateSpeaker(
        _ speaker: KnownSpeaker,
        replacingReferenceAudioAt sourceURL: URL? = nil,
        enrollmentData: KnownSpeakerEnrollmentData? = nil
    ) async throws -> KnownSpeaker {
        var speakers = try loadFromDisk()
        guard let index = speakers.firstIndex(where: { $0.id == speaker.id }) else {
            throw LorreError.persistenceFailed("Known speaker not found.")
        }
        var updatedSpeaker = speaker
        if let sourceURL {
            updatedSpeaker.referenceClip = try copyReferenceClipIfNeeded(
                speakerID: speaker.id,
                sourceURL: sourceURL,
                enrollmentData: enrollmentData
            )
        }
        speakers[index] = updatedSpeaker
        try saveAll(speakers)
        return updatedSpeaker
    }

    func deleteSpeaker(id: String) async throws {
        var speakers = try loadFromDisk()
        guard let speaker = speakers.first(where: { $0.id == id }) else {
            throw LorreError.persistenceFailed("Known speaker not found.")
        }
        speakers.removeAll { $0.id == id }
        try saveAll(speakers)
        try deleteReferenceClipIfPresent(speaker.referenceClip)
    }

    func referenceAudioURL(for speaker: KnownSpeaker) async -> URL? {
        guard let referenceClip = speaker.referenceClip else { return nil }
        guard let url = try? safeReferenceClipURL(for: referenceClip.storedFileName) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    private func saveAll(_ speakers: [KnownSpeaker]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoded = try Self.encoder.encode(speakers.sorted(by: Self.sortComparator))
        try AtomicFileWriter.write(encoded, to: fileURL)
    }

    private static func nextSpeakerID(from speakers: [KnownSpeaker]) -> String {
        let maxExisting = speakers.compactMap { speaker -> Int? in
            guard speaker.id.hasPrefix("K") else { return nil }
            return Int(speaker.id.dropFirst())
        }
        .max() ?? 0
        return "K\(maxExisting + 1)"
    }

    private static func nextVariant(for index: Int) -> SpeakerBadgeVariant {
        let cycle = SpeakerBadgeVariant.allCases
        return cycle[index % cycle.count]
    }

    private static func sortComparator(lhs: KnownSpeaker, rhs: KnownSpeaker) -> Bool {
        let nameOrder = lhs.safeDisplayName.localizedCaseInsensitiveCompare(rhs.safeDisplayName)
        if nameOrder == .orderedSame {
            return lhs.createdAt < rhs.createdAt
        }
        return nameOrder == .orderedAscending
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

    private func copyReferenceClipIfNeeded(
        speakerID: String,
        sourceURL: URL?,
        enrollmentData: KnownSpeakerEnrollmentData?
    ) throws -> KnownSpeakerReferenceClip? {
        guard let sourceURL, let enrollmentData else { return nil }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: samplesDirectoryURL, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let storedFileName = "\(speakerID).\(ext)"
        let destinationURL = try safeReferenceClipURL(for: storedFileName)
        let temporaryURL = samplesDirectoryURL.appendingPathComponent(".\(speakerID)-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        return KnownSpeakerReferenceClip(
            sourceFileName: sourceURL.lastPathComponent,
            storedFileName: storedFileName,
            durationSeconds: enrollmentData.durationSeconds,
            sampleRate: enrollmentData.sampleRate,
            importedAt: Date()
        )
    }

    private func deleteReferenceClipIfPresent(_ referenceClip: KnownSpeakerReferenceClip?) throws {
        guard let referenceClip else { return }
        let fileURL = try safeReferenceClipURL(for: referenceClip.storedFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func safeReferenceClipURL(for storedFileName: String) throws -> URL {
        let trimmed = storedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              !trimmed.contains(".."),
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            throw LorreError.persistenceFailed("Invalid known speaker reference clip path.")
        }

        let base = samplesDirectoryURL.standardizedFileURL
        let candidate = base.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        let basePath = Self.normalizedDirectoryPath(base.path(percentEncoded: false))
        let candidatePath = candidate.path(percentEncoded: false)
        guard candidatePath == basePath || candidatePath.hasPrefix(basePath + "/") else {
            throw LorreError.persistenceFailed("Known speaker reference clip is outside the samples directory.")
        }
        return candidate
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
