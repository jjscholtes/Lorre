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
        let event = LocalMetricEvent(
            name: name,
            sessionId: sessionId,
            timestamp: Date(),
            attributes: attributes
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
}
