import Foundation

/// Keeps earlier transcript versions of a session next to its current `transcript.json`.
///
/// Re-transcribing replaces the current transcript. Archiving first means manual edits and
/// results from an older model stay on disk, in `transcript-history/` inside the session folder.
enum TranscriptHistory {
    static let directoryName = "transcript-history"
    static let currentTranscriptFileName = "transcript.json"

    /// Copies the current transcript into the history folder.
    /// - Returns: The archived file, or `nil` when the session has no transcript yet.
    @discardableResult
    static func archiveCurrentTranscript(in sessionDirectory: URL, now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        let current = sessionDirectory.appendingPathComponent(currentTranscriptFileName)
        guard fileManager.fileExists(atPath: current.path(percentEncoded: false)) else { return nil }

        let historyDirectory = sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let stamp = timestamp(for: now)
        var destination = historyDirectory.appendingPathComponent("transcript-\(stamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = historyDirectory.appendingPathComponent("transcript-\(stamp)-\(suffix).json")
            suffix += 1
        }
        try fileManager.copyItem(at: current, to: destination)
        return destination
    }

    /// Archived transcript files, oldest first.
    static func archivedTranscripts(in sessionDirectory: URL) -> [URL] {
        let historyDirectory = sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// UTC timestamp with milliseconds, so names sort chronologically, e.g. `20261105T214512345Z`.
    static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }
}
