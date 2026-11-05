import Foundation

struct TranscriptSearchHit: Identifiable, Equatable, Sendable {
    let sessionID: UUID
    let sessionTitle: String
    let segmentID: UUID
    let startMs: Int
    let text: String
    var id: UUID { segmentID }
}

actor TranscriptSearchIndex {
    private struct Entry {
        let updatedAt: Date
        let segments: [TranscriptSegment]
    }
    private var entries: [UUID: Entry] = [:]

    func search(_ query: String, sessions: [SessionManifest], store: any SessionStore) async -> [TranscriptSearchHit] {
        let ids = Set(sessions.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        var hits: [TranscriptSearchHit] = []
        for session in sessions where session.status == .ready || session.status == .error {
            guard !Task.isCancelled else { return [] }
            if entries[session.id]?.updatedAt != session.updatedAt {
                guard let transcript = try? await store.loadTranscript(sessionId: session.id),
                      transcript.sessionId == session.id, !Task.isCancelled else { continue }
                entries[session.id] = Entry(updatedAt: session.updatedAt, segments: transcript.segments)
            }
            for segment in entries[session.id]?.segments ?? [] {
                let text = segment.text
                guard let match = text.range(of: query, options: [.caseInsensitive], locale: .current) else { continue }
                let start = text.index(match.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(match.upperBound, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
                let excerpt = (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
                hits.append(TranscriptSearchHit(sessionID: session.id, sessionTitle: session.displayTitle,
                                                segmentID: segment.id, startMs: segment.startMs, text: excerpt))
            }
        }
        return hits
    }

    func invalidate(_ id: UUID) { entries[id] = nil }
}
