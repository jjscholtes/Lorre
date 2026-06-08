import Foundation

enum SafeSessionFileResolver {
    static func fileURL(named fileName: String, in sessionDirectoryURL: URL) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              !trimmed.contains(".."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("~") else {
            throw LorreError.persistenceFailed("Invalid session file path.")
        }

        let base = sessionDirectoryURL.standardizedFileURL
        let candidate = base.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        let basePath = normalizedDirectoryPath(base.path(percentEncoded: false))
        let candidatePath = candidate.path(percentEncoded: false)
        guard candidatePath != basePath, candidatePath.hasPrefix(basePath + "/") else {
            throw LorreError.persistenceFailed("Session file is outside the session directory.")
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
