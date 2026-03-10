import Foundation
import XCTest
@testable import Lorre

final class LorreCoreTests: XCTestCase {
    func testFileSessionStoreRoundTripPersistsSessionAndTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)

        let created = try await store.createSession(
            NewSessionDraft(
                title: "Test Session",
                folderId: nil,
                status: .processing,
                durationSeconds: 12.5,
                audioFileName: "audio.m4a",
                recordedAt: Date()
            )
        )

        var session = created
        session.status = .ready
        session.transcriptFileName = "transcript.json"
        session.updatedAt = Date()
        try await store.updateSession(session)

        let transcript = TranscriptDocument(
            sessionId: created.id,
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1000, text: "Hello world", speakerId: "S1")
            ],
            speakers: [
                SpeakerProfile.defaultProfile(id: "S1"),
                SpeakerProfile.defaultProfile(id: "UNK")
            ]
        )
        try await store.saveTranscript(transcript)

        let loadedSessions = try await store.loadSessions()
        XCTAssertEqual(loadedSessions.count, 1)
        XCTAssertEqual(loadedSessions.first?.status, .ready)

        let loadedTranscript = try await store.loadTranscript(sessionId: created.id)
        XCTAssertEqual(loadedTranscript?.segments.first?.text, "Hello world")
        XCTAssertEqual(loadedTranscript?.speakers.first(where: { $0.id == "S1" })?.safeDisplayName, "Speaker S1")
    }

    func testMarkdownExporterIncludesSpeakerAndTimestamps() async throws {
        let exporter = MarkdownExportService()
        let session = SessionManifest(
            title: "Export Session",
            status: .ready,
            audioFileName: "audio.m4a",
            transcriptFileName: "transcript.json"
        )
        let transcript = TranscriptDocument(
            sessionId: session.id,
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1234, text: "First line", speakerId: "S1"),
                TranscriptSegment(startMs: 1500, endMs: 3200, text: "Second line", speakerId: "S2")
            ],
            speakers: [
                SpeakerProfile.defaultProfile(id: "S1"),
                SpeakerProfile.defaultProfile(id: "S2"),
                SpeakerProfile.defaultProfile(id: "UNK")
            ]
        )

        let markdown = exporter.render(session: session, transcript: transcript)
        XCTAssertTrue(markdown.contains("# Export Session"))
        XCTAssertTrue(markdown.contains("Speaker S1"))
        XCTAssertTrue(markdown.contains("`00:00.000 - 00:01.234`"))
        XCTAssertTrue(markdown.contains("Second line"))
    }

    func testTranscriptAssemblerAssignsSpeakerByLargestOverlap() {
        let sessionID = UUID()
        let transcription = TranscriptionResult(
            engineName: "TestEngine",
            utterances: [
                TranscriptionUtterance(startMs: 0, endMs: 2200, text: "Alpha", confidence: 0.9),
                TranscriptionUtterance(startMs: 2300, endMs: 5000, text: "Beta", confidence: 0.85)
            ]
        )
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 1200, speakerId: "S1"),
            DiarizationSpan(startMs: 1200, endMs: 2200, speakerId: "S2"),
            DiarizationSpan(startMs: 2300, endMs: 5000, speakerId: "S3")
        ])

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: diarization
        )

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].speakerId, "S1")
        XCTAssertEqual(transcript.segments[1].speakerId, "S3")
        XCTAssertTrue(transcript.speakers.contains(where: { $0.id == "UNK" }))
    }

    func testTranscriptAssemblerSplitsSentenceAtSpeakerTransition() {
        let sessionID = UUID()
        let transcription = TranscriptionResult(
            engineName: "TestEngine",
            utterances: [
                TranscriptionUtterance(
                    startMs: 0,
                    endMs: 10_000,
                    text: "Niet heel charismatisch. Geen man voor prachtige tv-toespraak. Nee, want uit een eerste pol kwam al dat 69% zegt hij niet datgene heeft wat een president nodig heeft.",
                    confidence: 0.96
                )
            ]
        )
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 6_400, speakerId: "S1"),
            DiarizationSpan(startMs: 6_400, endMs: 10_000, speakerId: "S2")
        ])

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: diarization
        )

        XCTAssertGreaterThanOrEqual(transcript.segments.count, 2)
        XCTAssertTrue(transcript.segments.contains(where: {
            $0.speakerId == "S1" && $0.text.localizedCaseInsensitiveContains("tv-toespraak")
        }))
        XCTAssertTrue(transcript.segments.contains(where: {
            $0.speakerId == "S2" && $0.text.localizedCaseInsensitiveContains("Nee, want")
        }))
    }

    func testTranscriptAssemblerUsesTokenTimingsToSplitMidSentenceSpeakerChange() {
        let sessionID = UUID()
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 3_600,
            text: "I think so yeah but actually no that is different",
            confidence: 0.95,
            tokenTimings: [
                TranscriptionTokenTiming(startMs: 0, endMs: 260, text: "I", confidence: 0.98),
                TranscriptionTokenTiming(startMs: 260, endMs: 620, text: " think", confidence: 0.97),
                TranscriptionTokenTiming(startMs: 620, endMs: 920, text: " so", confidence: 0.96),
                TranscriptionTokenTiming(startMs: 920, endMs: 1_260, text: " yeah", confidence: 0.95),
                TranscriptionTokenTiming(startMs: 1_260, endMs: 1_620, text: " but", confidence: 0.94),
                TranscriptionTokenTiming(startMs: 1_620, endMs: 2_240, text: " actually", confidence: 0.93),
                TranscriptionTokenTiming(startMs: 2_240, endMs: 2_560, text: " no", confidence: 0.93),
                TranscriptionTokenTiming(startMs: 2_560, endMs: 3_020, text: " that", confidence: 0.92),
                TranscriptionTokenTiming(startMs: 3_020, endMs: 3_260, text: " is", confidence: 0.92),
                TranscriptionTokenTiming(startMs: 3_260, endMs: 3_600, text: " different", confidence: 0.91)
            ]
        )
        let transcription = TranscriptionResult(engineName: "TestEngine", utterances: [utterance])
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 1_500, speakerId: "S1"),
            DiarizationSpan(startMs: 1_500, endMs: 3_600, speakerId: "S2")
        ])

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: diarization
        )

        XCTAssertGreaterThanOrEqual(transcript.segments.count, 2)
        XCTAssertTrue(transcript.segments.contains(where: {
            $0.speakerId == "S1" && $0.text.localizedCaseInsensitiveContains("yeah")
        }))
        XCTAssertTrue(transcript.segments.contains(where: {
            $0.speakerId == "S2" && $0.text.localizedCaseInsensitiveContains("actually")
        }))
    }

    func testLocalMetricsLoggerWritesJSONLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreMetricsTests-\(UUID().uuidString)", isDirectory: true)
        let logger = LocalMetricsLogger(baseURL: root)

        await logger.log(name: "app_opened")
        await logger.log(name: "record_started", sessionId: UUID(), attributes: ["source": "test"])

        let fileURL = root.appendingPathComponent("metrics.jsonl")
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"name\":\"app_opened\""))
        XCTAssertTrue(lines[1].contains("\"name\":\"record_started\""))
    }

    func testAppSettingsStorePersistsModelPreparationSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let empty = try await store.load()
        XCTAssertNil(empty.modelPreparation)

        let snapshot = ModelPreparationSnapshot(
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000),
            runtimeStatusSummary: "FluidAudio available",
            componentVersionsSummary: "ASR v3 • Silero VAD • Offline diarizer"
        )
        _ = try await store.recordModelPreparation(snapshot)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.modelPreparation, snapshot)
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testAppSettingsStorePersistsModelRegistryConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreRegistrySettingsTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertTrue(initial.modelRegistryConfiguration.isDefault)

        _ = try await store.setModelRegistryConfiguration(
            ModelRegistryConfiguration(customBaseURL: "https://models.internal.example.com///")
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.modelRegistryConfiguration.normalizedBaseURL, "https://models.internal.example.com")
        XCTAssertEqual(loaded.modelRegistryConfiguration.summaryLabel, "https://models.internal.example.com")
    }

    func testFileSessionStoreDeleteRemovesSessionDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDeleteTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)

        let created = try await store.createSession(
            NewSessionDraft(
                title: "Delete Me",
                folderId: nil,
                status: .ready,
                durationSeconds: nil,
                audioFileName: "audio.m4a",
                recordedAt: nil
            )
        )

        let sessionDir = await store.sessionDirectoryURL(for: created.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path(percentEncoded: false)))

        try await store.deleteSession(id: created.id)

        let loaded = try await store.loadSession(id: created.id)
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path(percentEncoded: false)))
    }

    func testAppSettingsStoreMigratesLegacySettingsWithoutFoldersField() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreLegacySettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let legacyJSON = """
        {
          "modelPreparation" : {
            "componentVersionsSummary" : "ASR v3 • Silero VAD • Offline diarizer",
            "preparedAt" : "2026-02-23T10:20:01Z",
            "runtimeStatusSummary" : "FluidAudio available"
          },
          "schemaVersion" : 1,
          "updatedAt" : "2026-02-23T10:20:01Z"
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: root.appendingPathComponent("settings.json"))

        let store = AppSettingsStore(baseURL: root)
        let initialFolders = try await store.loadFolders()
        XCTAssertEqual(initialFolders, [])

        _ = try await store.createFolder(named: "Interviews")
        let folders = try await store.loadFolders()

        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].name, "Interviews")
        let settings = try await store.load()
        XCTAssertEqual(settings.folders.count, 1)
        XCTAssertTrue(settings.isSpeakerDiarizationEnabled)
        XCTAssertEqual(settings.diarizationExpectedSpeakerCountHint, .auto)
        XCTAssertFalse(settings.isDiarizationDebugExportEnabled)
        XCTAssertTrue(settings.modelRegistryConfiguration.isDefault)
        XCTAssertFalse(settings.vocabularyBoosting.isEnabled)
        XCTAssertEqual(settings.vocabularyBoosting.simpleFormatTerms, "")
    }

    func testKnownSpeakerStoreRoundTripCopiesReferenceClipAndDeletesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreKnownSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        let store = KnownSpeakerStore(baseURL: root)

        let sourceURL = root.appendingPathComponent("alice.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("speaker-sample".utf8).write(to: sourceURL)

        let saved = try await store.saveNewSpeaker(
            displayName: "Alice",
            embedding: [0.1, 0.2, 0.3],
            referenceAudioURL: sourceURL,
            enrollmentData: KnownSpeakerEnrollmentData(
                embedding: [0.1, 0.2, 0.3],
                durationSeconds: 3.5,
                sampleRate: 16_000
            )
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.safeDisplayName, "Alice")
        XCTAssertEqual(loaded.first?.referenceClip?.sourceFileName, "alice.m4a")
        XCTAssertEqual(loaded.first?.referenceClip?.durationSeconds, 3.5)

        let storedReferenceURL = await store.referenceAudioURL(for: saved)
        XCTAssertNotNil(storedReferenceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedReferenceURL!.path(percentEncoded: false)))

        try await store.deleteSpeaker(id: saved.id)

        let afterDelete = try await store.load()
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedReferenceURL!.path(percentEncoded: false)))
    }

    func testKnownSpeakerStoreUpdateReplacesEmbeddingAndReferenceClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreKnownSpeakerUpdateTests-\(UUID().uuidString)", isDirectory: true)
        let store = KnownSpeakerStore(baseURL: root)

        let originalURL = root.appendingPathComponent("bob-original.m4a")
        let updatedURL = root.appendingPathComponent("bob-updated.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: originalURL)
        try Data("updated".utf8).write(to: updatedURL)

        let saved = try await store.saveNewSpeaker(
            displayName: "Bob",
            embedding: [0.1, 0.0, 0.9],
            referenceAudioURL: originalURL,
            enrollmentData: KnownSpeakerEnrollmentData(
                embedding: [0.1, 0.0, 0.9],
                durationSeconds: 2.0,
                sampleRate: 16_000
            )
        )

        var updatedSpeaker = saved
        updatedSpeaker.embedding = [0.9, 0.0, 0.1]
        updatedSpeaker.enrollmentCount = 2
        updatedSpeaker.updatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let updated = try await store.updateSpeaker(
            updatedSpeaker,
            replacingReferenceAudioAt: updatedURL,
            enrollmentData: KnownSpeakerEnrollmentData(
                embedding: [0.9, 0.0, 0.1],
                durationSeconds: 4.0,
                sampleRate: 16_000
            )
        )

        XCTAssertEqual(updated.embedding, [0.9, 0.0, 0.1])
        XCTAssertEqual(updated.enrollmentCount, 2)
        XCTAssertEqual(updated.referenceClip?.sourceFileName, "bob-updated.wav")
        XCTAssertEqual(updated.referenceClip?.durationSeconds, 4.0)

        let storedReferenceURL = await store.referenceAudioURL(for: updated)
        XCTAssertNotNil(storedReferenceURL)
        let storedData = try Data(contentsOf: storedReferenceURL!)
        XCTAssertEqual(String(decoding: storedData, as: UTF8.self), "updated")
    }

    func testAppSettingsStoreRenameDeleteFolderAndPersistSidebarExpansion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreFolderSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let interviews = try await store.createFolder(named: "Interviews")
        let notes = try await store.createFolder(named: "Notes")

        _ = try await store.saveSidebarExpansion(
            expandedViewFilterIDs: ["all", "ready"],
            expandedFolderIDs: [interviews.id, notes.id]
        )

        let renamed = try await store.renameFolder(id: interviews.id, to: "Client Interviews")
        XCTAssertEqual(renamed.id, interviews.id)
        XCTAssertEqual(renamed.name, "Client Interviews")

        try await store.deleteFolder(id: notes.id)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.folders.map(\.id), [interviews.id])
        XCTAssertEqual(loaded.folders.first?.name, "Client Interviews")
        XCTAssertEqual(loaded.sidebarExpandedViewFilterIDs, ["all", "ready"])
        XCTAssertEqual(loaded.sidebarExpandedFolderIDs, [interviews.id])
    }

    func testAppSettingsStoreRenameFolderRejectsDuplicateNamesCaseInsensitive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreFolderRenameDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        _ = try await store.createFolder(named: "Interviews")
        let notes = try await store.createFolder(named: "Notes")

        do {
            _ = try await store.renameFolder(id: notes.id, to: " interviews ")
            XCTFail("Expected duplicate-name rename to throw")
        } catch {
            guard case let LorreError.persistenceFailed(message) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("already exists"))
        }
    }

    func testAppSettingsStorePersistsSpeakerDiarizationToggle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDiarizationSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertTrue(initial.isSpeakerDiarizationEnabled)

        _ = try await store.setSpeakerDiarizationEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.isSpeakerDiarizationEnabled)

        _ = try await store.setSpeakerDiarizationEnabled(true)
        let enabled = try await store.load()
        XCTAssertTrue(enabled.isSpeakerDiarizationEnabled)
    }

    func testAppSettingsStorePersistsDiarizationTuningOptions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDiarizationTuningSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertEqual(initial.diarizationExpectedSpeakerCountHint, .auto)
        XCTAssertFalse(initial.isDiarizationDebugExportEnabled)

        _ = try await store.setDiarizationExpectedSpeakerCountHint(.range(min: 2, max: 4))
        _ = try await store.setDiarizationDebugExportEnabled(true)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.diarizationExpectedSpeakerCountHint, .range(min: 2, max: 4))
        XCTAssertTrue(loaded.isDiarizationDebugExportEnabled)
    }

    func testAppSettingsStorePersistsLiveTranscriptionToggle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreLiveTranscriptSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertFalse(initial.isLiveTranscriptionEnabled)

        _ = try await store.setLiveTranscriptionEnabled(true)
        let enabled = try await store.load()
        XCTAssertTrue(enabled.isLiveTranscriptionEnabled)

        _ = try await store.setLiveTranscriptionEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.isLiveTranscriptionEnabled)
    }

    func testAppSettingsStorePersistsVocabularyBoostingConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreVocabularyBoostingSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertFalse(initial.vocabularyBoosting.isEnabled)
        XCTAssertEqual(initial.vocabularyBoosting.simpleFormatTerms, "")

        let saved = try await store.saveVocabularyBoosting(
            VocabularyBoostingConfiguration(
                isEnabled: true,
                simpleFormatTerms: """
                Lorre: lore, lora
                FluidAudio
                """
            )
        )
        XCTAssertTrue(saved.vocabularyBoosting.isEnabled)
        XCTAssertTrue(saved.vocabularyBoosting.simpleFormatTerms.contains("Lorre"))

        let reloaded = try await store.load()
        XCTAssertTrue(reloaded.vocabularyBoosting.isEnabled)
        XCTAssertTrue(reloaded.vocabularyBoosting.simpleFormatTerms.contains("FluidAudio"))
    }

    func testProcessingCoordinatorWritesDiarizationDebugArtifactWhenEnabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDiarDebugArtifactTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(
            NewSessionDraft(
                title: "Debug Artifact Test",
                folderId: nil,
                status: .processing,
                durationSeconds: 8.0,
                audioFileName: "audio.m4a",
                recordedAt: Date()
            )
        )

        let coordinator = ProcessingCoordinator(
            store: store,
            transcriptionService: MockTranscriptionService(),
            diarizationService: MockSpeakerDiarizationService()
        )

        _ = try await coordinator.process(
            sessionId: session.id,
            enableDiarization: true,
            diarizationExpectedSpeakers: .exact(2),
            exportDiarizationDebugArtifact: true,
            onProgress: { _ in }
        )

        let sessionDir = await store.sessionDirectoryURL(for: session.id)
        let debugURL = sessionDir.appendingPathComponent("diarization-debug.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugURL.path(percentEncoded: false)))

        let data = try Data(contentsOf: debugURL)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"expectedSpeakers\""))
        XCTAssertTrue(text.contains("\"mode\" : \"exact\""))
        XCTAssertTrue(text.contains("\"transcriptSegments\""))
        XCTAssertTrue(text.contains("\"diarizationSpans\""))
    }

    func testTranscriptAssemblerPreservesRelabeledSpeakerAndSourceSpeakerID() {
        let sessionID = UUID()
        let transcription = TranscriptionResult(
            engineName: "TestEngine",
            utterances: [
                TranscriptionUtterance(startMs: 0, endMs: 2_000, text: "Hello there", confidence: 0.95)
            ]
        )
        let diarization = DiarizationResult(
            spans: [
                DiarizationSpan(startMs: 0, endMs: 2_000, speakerId: "K1", sourceSpeakerId: "S2")
            ],
            speakerProfiles: [
                SpeakerProfile(
                    id: "K1",
                    displayName: "Alice",
                    styleVariant: .outline,
                    isUserRenamed: true
                )
            ]
        )

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: diarization
        )

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerId, "K1")
        XCTAssertEqual(transcript.segments[0].sourceSpeakerId, "S2")
        XCTAssertEqual(transcript.speaker(for: "K1").safeDisplayName, "Alice")
    }
}
