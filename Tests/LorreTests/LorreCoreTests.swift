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
                recordingSource: .microphoneAndSystemAudio,
                audioFileName: "audio.caf",
                microphoneStemFileName: "microphone.caf",
                systemAudioStemFileName: "system-audio.caf",
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
        XCTAssertEqual(loadedSessions.first?.recordingSource, .microphoneAndSystemAudio)
        XCTAssertEqual(loadedSessions.first?.audioFileName, "audio.caf")
        XCTAssertEqual(loadedSessions.first?.microphoneStemFileName, "microphone.caf")
        XCTAssertEqual(loadedSessions.first?.systemAudioStemFileName, "system-audio.caf")
        XCTAssertNil(loadedSessions.first?.audioDeletedAt)
        XCTAssertEqual(loadedSessions.first?.hasRetainedAudio, true)

        let loadedTranscript = try await store.loadTranscript(sessionId: created.id)
        XCTAssertEqual(loadedTranscript?.segments.first?.text, "Hello world")
        XCTAssertEqual(loadedTranscript?.speakers.first(where: { $0.id == "S1" })?.safeDisplayName, "Speaker S1")
    }

    func testMarkdownExporterIncludesSpeakerAndTimestamps() async throws {
        let exporter = MarkdownExportService()
        let session = SessionManifest(
            title: "Export Session",
            status: .ready,
            recordingSource: .systemAudio,
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
        XCTAssertTrue(markdown.contains("- Source: System audio"))
        XCTAssertTrue(markdown.contains("- Audio retained: Yes"))
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

    func testTranscriptAssemblerDoesNotSplitSentenceOnWeakMidUtteranceSpeakerBlip() {
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
            DiarizationSpan(startMs: 0, endMs: 1_680, speakerId: "S1"),
            DiarizationSpan(startMs: 1_680, endMs: 1_860, speakerId: "S2"),
            DiarizationSpan(startMs: 1_860, endMs: 3_600, speakerId: "S1")
        ])

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: diarization
        )

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerId, "S1")
        XCTAssertTrue(transcript.segments[0].text.localizedCaseInsensitiveContains("actually no that is different"))
    }

    func testWorkStageRouteUsesSelectionInsteadOfRecordingMode() {
        let readySession = SessionManifest(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            title: "Ready Session",
            status: .ready,
            recordingSource: .microphone,
            audioFileName: "audio.m4a",
            transcriptFileName: "transcript.json"
        )
        let processingSession = SessionManifest(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            title: "Processing Session",
            status: .processing,
            recordingSource: .microphone,
            audioFileName: "audio.m4a"
        )

        XCTAssertEqual(AppViewModel.makeWorkStageRoute(selectedSession: nil), .recorder)
        XCTAssertEqual(AppViewModel.makeWorkStageRoute(selectedSession: processingSession), .processing(processingSession.id))
        XCTAssertEqual(AppViewModel.makeWorkStageRoute(selectedSession: readySession), .transcript(readySession.id))
    }

    func testCuePlaybackPresentationMentionsActiveRecordingWhenArchiveAudioExists() {
        let presentation = AppViewModel.makeCuePlaybackPresentation(
            hasRetainedAudio: true,
            canControlPlayback: false,
            hasActiveRecording: true
        )

        XCTAssertEqual(presentation.statusLabel, "Playback paused during recording")
        XCTAssertTrue(presentation.description.localizedCaseInsensitiveContains("stop the active recording"))
        XCTAssertEqual(presentation.iconName, "record.circle.fill")
    }

    func testCuePlaybackPresentationPrioritizesPrivacyModeOverRecordingState() {
        let presentation = AppViewModel.makeCuePlaybackPresentation(
            hasRetainedAudio: false,
            canControlPlayback: false,
            hasActiveRecording: true
        )

        XCTAssertEqual(presentation.statusLabel, "Playback unavailable")
        XCTAssertTrue(presentation.description.localizedCaseInsensitiveContains("privacy mode"))
        XCTAssertEqual(presentation.iconName, "lock.fill")
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

    func testAppSettingsStorePersistsSelectedRecordingSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreRecordingSourceSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertEqual(initial.selectedRecordingSource, .microphone)

        _ = try await store.setSelectedRecordingSource(.microphoneAndSystemAudio)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.selectedRecordingSource, .microphoneAndSystemAudio)
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
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
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
        XCTAssertEqual(settings.selectedRecordingSource, .microphone)
        XCTAssertFalse(settings.isDeleteAudioAfterTranscriptionEnabled)
        XCTAssertFalse(settings.vocabularyBoosting.isEnabled)
        XCTAssertEqual(settings.vocabularyBoosting.simpleFormatTerms, "")
    }

    func testSessionManifestDecodesLegacyJSONWithoutRecordingSourceMetadata() throws {
        let legacyJSON = """
        {
          "audioFileName" : "audio.m4a",
          "createdAt" : "2026-02-23T10:20:01Z",
          "dirtyFlags" : {
            "speakerEdited" : false,
            "titleEdited" : false,
            "transcriptEdited" : false
          },
          "exports" : [],
          "id" : "5E3D20E5-D3B3-430D-980B-8699A28EC4C0",
          "processing" : {},
          "status" : "ready",
          "title" : "Legacy Session",
          "updatedAt" : "2026-02-23T10:21:01Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(SessionManifest.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(session.recordingSource, .microphone)
        XCTAssertNil(session.microphoneStemFileName)
        XCTAssertNil(session.systemAudioStemFileName)
        XCTAssertEqual(session.audioFileName, "audio.m4a")
        XCTAssertNil(session.audioDeletedAt)
        XCTAssertTrue(session.hasRetainedAudio)
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

    func testAppSettingsStorePersistsDeleteAudioAfterTranscriptionToggle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDeleteAudioSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertFalse(initial.isDeleteAudioAfterTranscriptionEnabled)

        _ = try await store.setDeleteAudioAfterTranscriptionEnabled(true)
        let enabled = try await store.load()
        XCTAssertTrue(enabled.isDeleteAudioAfterTranscriptionEnabled)

        _ = try await store.setDeleteAudioAfterTranscriptionEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.isDeleteAudioAfterTranscriptionEnabled)
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
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
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

    func testProcessingCoordinatorDeletesAudioArtifactsAfterSuccessfulTranscriptionWhenEnabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDeleteAudioAfterProcessingTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(
            NewSessionDraft(
                title: "Privacy Session",
                folderId: nil,
                status: .processing,
                durationSeconds: 8.0,
                recordingSource: .microphoneAndSystemAudio,
                audioFileName: "audio.m4a",
                microphoneStemFileName: "microphone.m4a",
                systemAudioStemFileName: "system-audio.m4a",
                recordedAt: Date()
            )
        )

        let sessionDir = await store.sessionDirectoryURL(for: session.id)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: sessionDir.appendingPathComponent("audio.m4a"))
        try Data("mic".utf8).write(to: sessionDir.appendingPathComponent("microphone.m4a"))
        try Data("sys".utf8).write(to: sessionDir.appendingPathComponent("system-audio.m4a"))

        let coordinator = ProcessingCoordinator(
            store: store,
            transcriptionService: MockTranscriptionService(),
            diarizationService: MockSpeakerDiarizationService()
        )

        _ = try await coordinator.process(
            sessionId: session.id,
            enableDiarization: true,
            diarizationExpectedSpeakers: .exact(2),
            exportDiarizationDebugArtifact: false,
            deleteAudioAfterTranscription: true,
            onProgress: { _ in }
        )

        let updated = try await store.loadSession(id: session.id)
        XCTAssertEqual(updated?.status, .ready)
        XCTAssertNotNil(updated?.audioDeletedAt)
        XCTAssertEqual(updated?.hasRetainedAudio, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("audio.m4a").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("microphone.m4a").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("system-audio.m4a").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.json").path(percentEncoded: false)))
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

    func testDiarizationSpeakerCountHintPresetsIncludeExactOne() {
        XCTAssertTrue(DiarizationSpeakerCountHint.tuningPresets.contains(.exact(1)))
    }

    func testDiarizationResultCollapsesToDominantSpeakerWhenExactOneIsRequested() {
        let diarization = DiarizationResult(
            spans: [
                DiarizationSpan(startMs: 0, endMs: 9_840, speakerId: "S5"),
                DiarizationSpan(startMs: 9_840, endMs: 12_112, speakerId: "S5"),
                DiarizationSpan(startMs: 19_200, endMs: 19_600, speakerId: "S7"),
                DiarizationSpan(startMs: 19_600, endMs: 21_040, speakerId: "S3"),
                DiarizationSpan(startMs: 21_040, endMs: 22_080, speakerId: "S6"),
                DiarizationSpan(startMs: 22_080, endMs: 23_119, speakerId: "S3")
            ],
            speakerProfiles: [
                SpeakerProfile.defaultProfile(id: "S3"),
                SpeakerProfile.defaultProfile(id: "S5"),
                SpeakerProfile.defaultProfile(id: "S6"),
                SpeakerProfile.defaultProfile(id: "S7")
            ]
        )

        let collapsed = diarization.applyingSpeakerCountHint(.exact(1))

        XCTAssertEqual(Set(collapsed.spans.map(\.speakerId)), ["S5"])
        XCTAssertEqual(collapsed.spans[0].sourceSpeakerId, "S5")
        XCTAssertEqual(collapsed.spans[2].sourceSpeakerId, "S7")
        XCTAssertEqual(collapsed.spans[3].sourceSpeakerId, "S3")
        XCTAssertEqual(collapsed.speakerProfiles.map(\.id), ["S5"])
    }

    func testAppViewModelStopRecordingDeletesDraftSessionWhenRecorderStopFails() async throws {
        let root = makeTemporaryRoot(named: "LorreStopFailureCleanupTests")
        let store = FileSessionStore(baseURL: root)
        let recorder = ControlledRecorderService(
            startDelay: .zero,
            stopBehavior: .failure("Synthetic stop failure")
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: makeTestDependencies(root: root, store: store, recorder: recorder))
        }

        await MainActor.run {
            viewModel.startRecordingTapped()
        }
        try await waitUntil {
            await MainActor.run { viewModel.isRecording }
        }

        await MainActor.run {
            viewModel.stopRecordingTapped()
        }
        try await waitUntil {
            await MainActor.run { !viewModel.isStoppingRecording }
        }

        let sessions = try await store.loadSessions()
        XCTAssertTrue(sessions.isEmpty)
        await MainActor.run {
            XCTAssertFalse(viewModel.isRecording)
            XCTAssertFalse(viewModel.isStartingRecording)
            XCTAssertEqual(viewModel.recorderStatusText, "Ready to record")
        }
    }

    func testAppViewModelIgnoresRepeatedStartWhileStartupIsInFlight() async throws {
        let root = makeTemporaryRoot(named: "LorreStartReentrancyTests")
        let recorder = ControlledRecorderService(startDelay: .milliseconds(200))
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: makeTestDependencies(root: root, recorder: recorder))
        }

        await MainActor.run {
            viewModel.startRecordingTapped()
            viewModel.startRecordingTapped()
        }

        try await waitUntil {
            await recorder.startCallCount == 1
        }

        await MainActor.run {
            XCTAssertTrue(viewModel.isStartingRecording)
            XCTAssertFalse(viewModel.isRecording)
        }

        try await waitUntil {
            await MainActor.run { viewModel.isRecording }
        }

        let startCallCount = await recorder.startCallCount
        XCTAssertEqual(startCallCount, 1)
    }

    func testAppViewModelRecordingSourceChangeIgnoresStaleAsyncSupportResults() async throws {
        let root = makeTemporaryRoot(named: "LorreRecordingSourceRaceTests")
        let recorder = ControlledRecorderService(
            supportBySource: [
                .microphone: true,
                .systemAudio: false
            ],
            supportDelayBySource: [
                .microphone: .milliseconds(20),
                .systemAudio: .milliseconds(250)
            ]
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: makeTestDependencies(root: root, recorder: recorder))
        }

        await MainActor.run {
            viewModel.setRecordingSource(.systemAudio)
            viewModel.setRecordingSource(.microphone)
        }

        try await waitUntil {
            await MainActor.run { viewModel.isLiveTranscriptionSupported }
        }

        await MainActor.run {
            XCTAssertEqual(viewModel.selectedRecordingSource, .microphone)
            XCTAssertTrue(viewModel.isLiveTranscriptionSupported)
        }
    }
}

private actor ControlledRecorderService: RecorderService {
    enum StopBehavior: Sendable {
        case succeed
        case failure(String)
    }

    private let startDelay: Duration
    private let stopBehavior: StopBehavior
    private let supportBySource: [RecordingSource: Bool]
    private let supportDelayBySource: [RecordingSource: Duration]
    private(set) var startCallCount = 0
    private var startedAt: Date?
    private var activeSource: RecordingSource = .microphone

    init(
        startDelay: Duration = .zero,
        stopBehavior: StopBehavior = .succeed,
        supportBySource: [RecordingSource: Bool] = [:],
        supportDelayBySource: [RecordingSource: Duration] = [:]
    ) {
        self.startDelay = startDelay
        self.stopBehavior = stopBehavior
        self.supportBySource = supportBySource
        self.supportDelayBySource = supportDelayBySource
    }

    func startRecording(_ request: RecordingRequest) async throws {
        startCallCount += 1
        guard startedAt == nil else {
            throw LorreError.recordingStartFailed("A recording is already active.")
        }
        if startDelay > .zero {
            try? await Task.sleep(for: startDelay)
        }
        startedAt = Date()
        activeSource = request.source
    }

    func cancelRecording() async throws {
        guard startedAt != nil else {
            throw LorreError.recordingNotStarted
        }
        startedAt = nil
    }

    func stopRecording(in directoryURL: URL, fileLayout: RecordingFileLayout) async throws -> RecordingCapture {
        guard let startedAt else {
            throw LorreError.recordingNotStarted
        }
        self.startedAt = nil

        switch stopBehavior {
        case let .failure(message):
            throw LorreError.recordingStopFailed(message)
        case .succeed:
            let endedAt = Date()
            let duration = max(0.5, endedAt.timeIntervalSince(startedAt))
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: directoryURL.appendingPathComponent(fileLayout.audioFileName))
            if activeSource == .microphoneAndSystemAudio {
                if let microphoneStemFileName = fileLayout.microphoneStemFileName {
                    try Data("mic".utf8).write(to: directoryURL.appendingPathComponent(microphoneStemFileName))
                }
                if let systemAudioStemFileName = fileLayout.systemAudioStemFileName {
                    try Data("sys".utf8).write(to: directoryURL.appendingPathComponent(systemAudioStemFileName))
                }
            }
            return RecordingCapture(startedAt: startedAt, endedAt: endedAt, durationSeconds: duration)
        }
    }

    func currentMeterLevel() async -> Double { 0.12 }

    func recordingFileLayout(for source: RecordingSource) async -> RecordingFileLayout {
        switch source {
        case .microphone, .systemAudio:
            return RecordingFileLayout(audioFileName: "audio.caf", microphoneStemFileName: nil, systemAudioStemFileName: nil)
        case .microphoneAndSystemAudio:
            return RecordingFileLayout(
                audioFileName: "audio.caf",
                microphoneStemFileName: "microphone.caf",
                systemAudioStemFileName: "system-audio.caf"
            )
        }
    }

    func supportsLiveTranscription(for source: RecordingSource) async -> Bool {
        if let delay = supportDelayBySource[source], delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return supportBySource[source] ?? false
    }

    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        _ = onProgress
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        _ = speakers
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async {
        _ = isEnabled
    }

    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview? { nil }

    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>? { nil }
}

private final class TestPlaybackService: AudioPlaybackService {
    var preparedURL: URL?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    var isPlaying: Bool = false
    var playbackRate: Double = 1.0

    func prepare(url: URL) throws {
        preparedURL = url
    }

    func play() throws {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        currentTimeSeconds = 0
    }

    func seek(to seconds: Double) {
        currentTimeSeconds = seconds
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
    }
}

private func makeTemporaryRoot(named prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func makeTestDependencies(
    root: URL,
    store: FileSessionStore? = nil,
    recorder: any RecorderService
) -> AppDependencies {
    let sessionStore = store ?? FileSessionStore(baseURL: root)
    let knownSpeakerStore = KnownSpeakerStore(baseURL: root)
    let settings = AppSettingsStore(baseURL: root)
    let transcription = MockTranscriptionService()
    let diarization = MockSpeakerDiarizationService()
    let speakerEnrollment = FluidAudioSpeakerEnrollmentService()
    let coordinator = ProcessingCoordinator(
        store: sessionStore,
        transcriptionService: transcription,
        diarizationService: diarization
    )
    return AppDependencies(
        store: sessionStore,
        knownSpeakerStore: knownSpeakerStore,
        settings: settings,
        recorder: recorder,
        transcription: transcription,
        diarization: diarization,
        speakerEnrollment: speakerEnrollment,
        playback: TestPlaybackService(),
        exporter: MarkdownExportService(),
        processingCoordinator: coordinator,
        metrics: LocalMetricsLogger(baseURL: root),
        fluidAudioStatus: "Test runtime",
        modelPreparationComponentsSummary: "Test components"
    )
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    pollingInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollingInterval)
    }
    XCTFail("Timed out waiting for condition")
    throw LorreError.persistenceFailed("Timed out waiting for condition")
}
