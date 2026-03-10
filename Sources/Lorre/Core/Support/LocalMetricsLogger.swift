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
}
