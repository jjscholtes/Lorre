import Foundation
import OSLog

struct LocalMetricEvent: Codable, Sendable {
    var name: String
    var sessionId: UUID?
    var timestamp: Date
    var attributes: [String: String]
}

actor LocalMetricsLogger {
    private let fileURL: URL
    private let logger = Logger(subsystem: "Lorre", category: "metrics")
    private let encoder: JSONEncoder
    private let maxLogBytes: UInt64 = 2 * 1024 * 1024

    init(baseURL: URL = FileSessionStore.defaultBaseURL()) {
        self.fileURL = baseURL.appendingPathComponent("metrics.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func log(name: String, sessionId: UUID? = nil, attributes: [String: String] = [:]) async {
        let sanitizedAttributes = Self.sanitizedAttributes(attributes)
        let event = LocalMetricEvent(
            name: name,
            sessionId: sessionId,
            timestamp: Date(),
            attributes: sanitizedAttributes
        )

        logger.info("event=\(name, privacy: .public) session=\(sessionId?.uuidString ?? "-", privacy: .public)")

        do {
            let line = try encoder.encode(event) + Data([0x0A])
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rotateIfNeeded(incomingBytes: UInt64(line.count))
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("metrics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) throws {
        let fileManager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let currentSize = attributes[.size] as? UInt64 ?? 0
        guard currentSize + incomingBytes > maxLogBytes else { return }

        let rotatedURL = fileURL.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(fileURL.pathExtension)
        if fileManager.fileExists(atPath: rotatedURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: fileURL, to: rotatedURL)
    }

    private static func sanitizedAttributes(_ attributes: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for key in attributes.keys.sorted() {
            guard let value = attributes[key] else { continue }
            switch key {
            case "file":
                sanitized["file_extension"] = sanitizedFileExtension(from: value)
            case "speaker_name":
                sanitized["speaker_name_present"] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
            case "target_app":
                sanitized["target_app_present"] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
            case "target_bundle":
                sanitized["target_bundle_present"] = value == "unknown" ? "false" : "true"
            case "app":
                sanitized["app_present"] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
            case "custom_base_url":
                sanitized["custom_base_url_configured"] = value == "default" ? "false" : "true"
            case "folder_id":
                sanitized["folder_id"] = value == "unfiled" || value == "__UNFILED__" ? "unfiled" : "redacted"
            case "error":
                sanitized["error"] = "redacted"
            default:
                if allowedAttributeKeys.contains(key) {
                    sanitized[key] = sanitizedScalar(value)
                }
            }
        }
        return sanitized
    }

    private static func sanitizedFileExtension(from value: String) -> String {
        let ext = (value as NSString).pathExtension.lowercased()
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(ext.unicodeScalars.filter { allowed.contains($0) })
        return sanitized.isEmpty ? "none" : sanitized
    }

    private static func sanitizedScalar(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(120))
    }

    private static let allowedAttributeKeys: Set<String> = [
        "audio_retained",
        "autoplay",
        "characters",
        "confidence",
        "configured",
        "duration_seconds",
        "enabled",
        "engine",
        "extension",
        "fluid_audio",
        "format",
        "has_notes",
        "hint",
        "lines",
        "mode",
        "moved_sessions",
        "notification",
        "preset",
        "rate",
        "reason",
        "segments",
        "shortcut",
        "source",
        "start_ms",
        "start_reason",
        "status",
        "surface",
        "visible"
    ]
}
