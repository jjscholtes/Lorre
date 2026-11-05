import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import Lorre

@MainActor
struct RecoveryAndSearchTests {
    private func draft(status: SessionStatus) -> NewSessionDraft {
        NewSessionDraft(title: "Meeting", status: status, recordingSource: .microphone, audioFileName: "audio.caf")
    }

    @Test func interruptedSessionsOfferRetryOnlyWithRetainedSource() async throws {
        let root = makeTemporaryRoot(named: "Interrupted")
        let store = FileSessionStore(baseURL: root)
        let interrupted = try await store.createSession(draft(status: .processing))
        let missing = try await store.createSession(draft(status: .recording))
        let dir = await store.sessionDirectoryURL(for: interrupted.id)
        try Data("audio".utf8).write(to: dir.appendingPathComponent(interrupted.audioFileName))
        let model = AppViewModel(dependencies: makeTestDependencies(root: root, store: store, recorder: ControlledRecorderService()))
        await model.start()
        let failed = try #require(model.sessions.first { $0.id == interrupted.id })
        let unavailable = try #require(model.sessions.first { $0.id == missing.id })
        #expect(failed.status == .error)
        #expect(unavailable.status == .error)
        #expect(model.canPerformSessionAction(.retryProcessing, for: failed))
        #expect(!model.canPerformSessionAction(.retryProcessing, for: unavailable))
        model.retryProcessing(failed.id)
        try await waitUntil { (try? await store.loadSession(id: failed.id))?.status == .ready }
    }

    @Test func archiveSearchFindsEditedTextAndOpensTimestampWithoutAudio() async throws {
        let root = makeTemporaryRoot(named: "ArchiveSearch")
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(draft(status: .ready))
        _ = try await store.updateSession(id: session.id) { $0.audioDeletedAt = Date() }
        let segment = TranscriptSegment(startMs: 42_000, endMs: 45_000, text: "Afspraak in Delft", speakerId: nil)
        try await store.saveTranscript(TranscriptDocument(sessionId: session.id, sourceEngine: "Test", segments: [segment], speakers: []))
        let model = AppViewModel(dependencies: makeTestDependencies(root: root, store: store, recorder: ControlledRecorderService()))
        await model.start()
        model.selectSession(nil)
        model.searchQuery = "DELFT"
        try await waitUntil { await model.transcriptSearchHits.count == 1 }
        let hit = try #require(model.transcriptSearchHits.first)
        #expect(hit.startMs == 42_000)
        #expect(model.filteredSessions.map(\.id) == [session.id])
        model.openSearchHit(hit)
        try await waitUntil { await model.activeTranscript?.sessionId == session.id }
        #expect(model.searchScrollTarget?.segmentID == segment.id)
        #expect(!model.canControlPlayback)
        model.updateSegmentText(sessionID: session.id, segmentID: segment.id, text: "Afspraak in Leiden")
        try await waitUntil { await model.transcriptSearchHits.isEmpty }
        model.searchQuery = "leiden"
        try await waitUntil { await model.transcriptSearchHits.first?.text == "Afspraak in Leiden" }
    }

    @Test func correctedNameSurvivesSegmentAssemblyPersistenceAndExport() async throws {
        let root = makeTemporaryRoot(named: "VocabularyExport")
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(draft(status: .ready))
        let tokens = ["Bel", " schol", " tus", " morgen."].enumerated().map { index, text in
            TokenTiming(token: text, tokenId: index, startTime: Double(index), endTime: Double(index) + 0.5, confidence: 0.9)
        }
        let result = ASRResult(text: "Bel Scholtes morgen.", confidence: 0.9, duration: 4, processingTime: 1,
                               tokenTimings: tokens, ctcAppliedTerms: ["Scholtes"])
        let utterances = await FluidAudioTranscriptionService().buildUtterances(from: result, speechWindows: nil, fallbackEndMs: 4_000)
        let name = try #require(utterances.flatMap { $0.tokenTimings ?? [] }.first { $0.text.contains("Scholtes") })
        #expect(name.startMs == 1_000)
        #expect(name.endMs == 2_500)
        let transcript = TranscriptAssembler.assemble(sessionId: session.id,
            transcription: TranscriptionResult(engineName: "Parakeet+Vocabulary", utterances: utterances), diarization: nil)
        try await store.saveTranscript(transcript)
        let saved = try #require(try await store.loadTranscript(sessionId: session.id))
        #expect(saved.segments.contains { $0.text.contains("Scholtes") })
        let url = try await MarkdownExportService().export(session: session, transcript: saved, format: .markdown,
                                                           destinationURL: root.appendingPathComponent("meeting.md"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Scholtes"))
    }
}
