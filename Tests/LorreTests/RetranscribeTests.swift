import Foundation
import Testing
@testable import Lorre

@MainActor
struct RetranscribeTests {
    private func draft(status: SessionStatus) -> NewSessionDraft {
        NewSessionDraft(title: "Overleg", status: status, recordingSource: .microphone, audioFileName: "audio.caf")
    }

    @Test func historyArchivesCurrentTranscriptWithoutOverwriting() throws {
        let directory = makeTemporaryRoot(named: "TranscriptHistory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try TranscriptHistory.archiveCurrentTranscript(in: directory) == nil)

        let current = directory.appendingPathComponent(TranscriptHistory.currentTranscriptFileName)
        try Data("first".utf8).write(to: current)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(try TranscriptHistory.archiveCurrentTranscript(in: directory, now: now))
        try Data("second".utf8).write(to: current)
        let second = try #require(try TranscriptHistory.archiveCurrentTranscript(in: directory, now: now))

        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(TranscriptHistory.archivedTranscripts(in: directory).count == 2)
        #expect(try String(contentsOf: current, encoding: .utf8) == "second")
    }

    @Test func retranscribeKeepsEditedVersionAndProducesNewTranscript() async throws {
        let root = makeTemporaryRoot(named: "Retranscribe")
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(draft(status: .ready))
        let directory = await store.sessionDirectoryURL(for: session.id)
        try Data("audio".utf8).write(to: directory.appendingPathComponent(session.audioFileName))
        let edited = TranscriptSegment(startMs: 0, endMs: 2_000, text: "Handmatig verbeterde zin", speakerId: nil)
        try await store.saveTranscript(
            TranscriptDocument(sessionId: session.id, sourceEngine: "Old", segments: [edited], speakers: [])
        )

        let model = AppViewModel(dependencies: makeTestDependencies(root: root, store: store, recorder: ControlledRecorderService()))
        await model.start()
        let ready = try #require(model.sessions.first { $0.id == session.id })
        #expect(model.canPerformSessionAction(.retranscribe, for: ready))
        #expect(!model.canPerformSessionAction(.retryProcessing, for: ready))
        #expect(model.sessionActions(for: .transcriptHeader, session: ready).contains { $0.action == .retranscribe })

        model.performSessionAction(.retranscribe, for: session.id)
        try await waitUntil {
            guard let transcript = try? await store.loadTranscript(sessionId: session.id) else { return false }
            return transcript.sourceEngine != "Old"
        }
        try await waitUntil { (try? await store.loadSession(id: session.id))?.status == .ready }

        let archived = try #require(TranscriptHistory.archivedTranscripts(in: directory).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: archived))
        #expect(previous.sourceEngine == "Old")
        #expect(previous.segments.map(\.text) == ["Handmatig verbeterde zin"])
    }

    @Test func retranscribeIsUnavailableWithoutRetainedAudio() async throws {
        let root = makeTemporaryRoot(named: "RetranscribeNoAudio")
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(draft(status: .ready))
        _ = try await store.updateSession(id: session.id) { $0.audioDeletedAt = Date() }

        let model = AppViewModel(dependencies: makeTestDependencies(root: root, store: store, recorder: ControlledRecorderService()))
        await model.start()
        let ready = try #require(model.sessions.first { $0.id == session.id })
        let state = model.sessionActionState(.retranscribe, for: ready)
        #expect(!state.isEnabled)
        #expect(state.disabledReason == "Source audio was deleted for this session.")
    }
}
