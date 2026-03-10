import Foundation

struct MarkdownExportService: ExportService {
    func export(
        session: SessionManifest,
        transcript: TranscriptDocument,
        format: ExportFormat,
        destinationURL: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try renderData(session: session, transcript: transcript, format: format)
        do {
            try AtomicFileWriter.write(data, to: destinationURL)
        } catch {
            throw LorreError.exportFailed(error.localizedDescription)
        }
        return destinationURL
    }

    func suggestedFileName(session: SessionManifest, format: ExportFormat) -> String {
        let name = sanitizedBaseName(session.displayTitle)
        return "\(name)-\(exportTimestampString(Date())).\(format.fileExtension)"
    }

    func render(session: SessionManifest, transcript: TranscriptDocument) -> String {
        var lines: [String] = []
        lines.append("# \(session.displayTitle)")
        lines.append("")
        lines.append("- Status: \(session.status.label)")
        if let recordedAt = session.recordedAt {
            lines.append("- Recorded: \(recordedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let duration = session.durationSeconds {
            lines.append("- Duration: \(Formatters.duration(duration))")
        }
        lines.append("- Exported: \(Date().formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        lines.append("## Transcript")
        lines.append("")

        for segment in transcript.segments {
            let speaker = transcript.speaker(for: segment.speakerId)
            let timestamp = "\(Formatters.timestamp(ms: segment.startMs)) - \(Formatters.timestamp(ms: segment.endMs))"
            lines.append("### \(speaker.safeDisplayName) (`\(speaker.id)`)")
            lines.append("")
            lines.append("`\(timestamp)`")
            lines.append("")
            lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    func renderPlainText(session: SessionManifest, transcript: TranscriptDocument) -> String {
        var lines: [String] = []
        lines.append(session.displayTitle)
        lines.append(String(repeating: "=", count: max(8, session.displayTitle.count)))
        lines.append("")
        lines.append("Status: \(session.status.label)")
        if let recordedAt = session.recordedAt {
            lines.append("Recorded: \(recordedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let duration = session.durationSeconds {
            lines.append("Duration: \(Formatters.duration(duration))")
        }
        lines.append("")

        for segment in transcript.segments {
            let speaker = transcript.speaker(for: segment.speakerId)
            let timestamp = "\(Formatters.timestamp(ms: segment.startMs)) - \(Formatters.timestamp(ms: segment.endMs))"
            lines.append("[\(timestamp)] \(speaker.safeDisplayName) (\(speaker.id))")
            lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    func renderJSON(session: SessionManifest, transcript: TranscriptDocument) throws -> Data {
        struct ExportPayload: Codable {
            let session: SessionManifest
            let transcript: TranscriptDocument
            let exportedAt: Date
        }

        let payload = ExportPayload(session: session, transcript: transcript, exportedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func renderData(session: SessionManifest, transcript: TranscriptDocument, format: ExportFormat) throws -> Data {
        switch format {
        case .markdown:
            return Data(render(session: session, transcript: transcript).utf8)
        case .plainText:
            return Data(renderPlainText(session: session, transcript: transcript).utf8)
        case .json:
            return try renderJSON(session: session, transcript: transcript)
        }
    }

    private func sanitizedBaseName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Transcript" : trimmed
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        let scalars = fallback.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let raw = String(scalars)
        let collapsed = raw.replacingOccurrences(of: "  ", with: " ")
        return collapsed
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .prefix(64)
            .description
    }

    private func exportTimestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
