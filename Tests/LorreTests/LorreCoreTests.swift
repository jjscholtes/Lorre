import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
import Testing
@testable import Lorre

@Suite("LorreCoreTests")
struct LorreCoreTests {

    @Test
    func testFormattersUseHourFieldsForLongDurations() {
        XCTAssertEqual(Formatters.duration(14_400), "04:00:00")
        XCTAssertEqual(Formatters.timestamp(ms: 14_400_123), "04:00:00.123")
    }

    #if canImport(AVFoundation)

    @Test
    func testMixToCanonicalFileKeepsDifferentSampleRatesOnTargetTimeline() throws {
        let root = makeTemporaryRoot(named: "LorreMixTimelineTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let microphoneURL = root.appendingPathComponent("microphone.caf")
        let systemURL = root.appendingPathComponent("system.caf")
        let mixedURL = root.appendingPathComponent("mixed.caf")
        let durationSeconds = 3.0
        let impulseSeconds = 2.0

        try writeImpulseAudio(
            to: microphoneURL,
            sampleRate: 48_000,
            durationSeconds: durationSeconds,
            impulseSeconds: impulseSeconds
        )
        try writeImpulseAudio(
            to: systemURL,
            sampleRate: 44_100,
            durationSeconds: durationSeconds,
            impulseSeconds: impulseSeconds
        )

        try RecorderAudioUtilities.mixToCanonicalFile(
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            destinationURL: mixedURL
        )

        let mixedSamples = try RecorderAudioUtilities.loadSamples(
            from: mixedURL,
            targetFormat: RecorderAudioUtilities.previewFormat
        )
        let expectedFrameCount = Int(durationSeconds * RecorderAudioUtilities.previewFormat.sampleRate)
        let expectedImpulseIndex = Int(impulseSeconds * RecorderAudioUtilities.previewFormat.sampleRate)
        let peakIndex = mixedSamples.indices.max { abs(mixedSamples[$0]) < abs(mixedSamples[$1]) }

        XCTAssertLessThanOrEqual(abs(mixedSamples.count - expectedFrameCount), 2)
        XCTAssertNotNil(peakIndex)
        XCTAssertLessThanOrEqual(abs((peakIndex ?? 0) - expectedImpulseIndex), 4)
    }

    private func writeImpulseAudio(
        to url: URL,
        sampleRate: Double,
        durationSeconds: Double,
        impulseSeconds: Double
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Could not create test audio format")
            return
        }
        let frameCount = Int((durationSeconds * sampleRate).rounded())
        var samples = Array(repeating: Float(0), count: frameCount)
        let impulseIndex = min(max(0, Int((impulseSeconds * sampleRate).rounded())), frameCount - 1)
        samples[impulseIndex] = 1
        let buffer = try RecorderAudioUtilities.makePCMBuffer(from: samples, format: format)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    #endif


    @Test
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
        XCTAssertEqual(loadedTranscript?.alternatives, [])
    }


    @Test
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


    @Test
    func testMarkdownExporterEscapesUserControlledMarkdown() {
        let exporter = MarkdownExportService()
        let session = SessionManifest(
            title: "# Heading\n<script>",
            status: .ready,
            audioFileName: "audio.m4a"
        )
        let transcript = TranscriptDocument(
            sessionId: session.id,
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1000, text: "# not a heading <script>", speakerId: "S1")
            ],
            speakers: [
                SpeakerProfile.defaultProfile(id: "S1")
            ]
        )

        let markdown = exporter.render(session: session, transcript: transcript)
        XCTAssertTrue(markdown.contains("# \\# Heading &lt;script&gt;"))
        XCTAssertTrue(markdown.contains("\\# not a heading &lt;script&gt;"))
    }


    @Test
    func testMarkdownExporterUsesSafeCodeSpanForSpeakerIDsWithBackticks() {
        let exporter = MarkdownExportService()
        let session = SessionManifest(
            title: "Export Session",
            status: .ready,
            audioFileName: "audio.m4a"
        )
        let transcript = TranscriptDocument(
            sessionId: session.id,
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1000, text: "hello", speakerId: "S`1")
            ],
            speakers: [
                SpeakerProfile(id: "S`1", displayName: "Speaker Backtick", styleVariant: .filled, isUserRenamed: false)
            ]
        )

        let markdown = exporter.render(session: session, transcript: transcript)

        XCTAssertTrue(markdown.contains("### Speaker Backtick (``S`1``)"))
        XCTAssertFalse(markdown.contains("`S\\`1`"))
    }


    @Test
    func testAutomaticExportFileNameBuilderUsesTopicPhraseFromTranscript() {
        let sessionID = UUID()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 6, hour: 14, minute: 32))!
        let session = SessionManifest(
            id: sessionID,
            title: "Session Jun 6",
            status: .ready,
            recordedAt: now,
            durationSeconds: 42 * 60,
            recordingSource: .microphoneAndSystemAudio,
            audioFileName: "audio.caf",
            transcriptFileName: "transcript.json"
        )
        let transcript = TranscriptDocument(
            sessionId: sessionID,
            languageHint: "nl",
            sourceEngine: "Test",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 4_000,
                    text: "Vandaag bespreken we de onboarding flow, pricing pagina en openstaande bugs.",
                    speakerId: "S1"
                ),
                TranscriptSegment(
                    startMs: 4_000,
                    endMs: 8_000,
                    text: "Daarna pakken we korte vragen.",
                    speakerId: "S2"
                )
            ],
            speakers: [
                .defaultProfile(id: "S1"),
                .defaultProfile(id: "S2")
            ]
        )

        let fileName = AutomaticExportFileNameBuilder.fileName(
            session: session,
            transcript: transcript,
            template: "{date}-{speaker_count}-{smart_title}",
            now: now
        )

        XCTAssertEqual(
            fileName,
            "2026-06-06-2spk-onboarding-flow-pricing-pagina-openstaande-bugs.md"
        )
    }


    @Test
    func testAutomaticExportFileNameBuilderFallsBackToRankedKeywordsAndTemplateTokens() {
        let sessionID = UUID()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 6, hour: 9, minute: 5))!
        let session = SessionManifest(
            id: sessionID,
            title: "Fallback Session",
            status: .ready,
            recordedAt: now,
            durationSeconds: 75,
            recordingSource: .microphone,
            audioFileName: "audio.caf",
            transcriptFileName: "transcript.json"
        )
        let transcript = TranscriptDocument(
            sessionId: sessionID,
            languageHint: "en",
            sourceEngine: "Test",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 5_000,
                    text: "We need a clean transcript with speaker labels and a quick export.",
                    speakerId: "S1"
                )
            ],
            speakers: [.defaultProfile(id: "S1")]
        )

        let fileName = AutomaticExportFileNameBuilder.fileName(
            session: session,
            transcript: transcript,
            template: "{datetime}-{duration}-{keywords}.md",
            now: now
        )

        XCTAssertEqual(fileName, "2026-06-06-09-05-1m-need-clean-transcript-speaker-labels-quick.md")
    }


    @Test
    func testDiarizationSpeakerLabelNormalizerAvoidsNumericCollisions() {
        XCTAssertEqual(DiarizationSpeakerLabelNormalizer.normalize("0"), "S1")
        XCTAssertEqual(DiarizationSpeakerLabelNormalizer.normalize("1"), "S2")
        XCTAssertEqual(DiarizationSpeakerLabelNormalizer.normalize("2"), "S3")
        XCTAssertEqual(DiarizationSpeakerLabelNormalizer.normalize("S2"), "S2")
        XCTAssertEqual(DiarizationSpeakerLabelNormalizer.normalize(""), "UNK")
    }


    @Test
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


    @Test
    func testTranscriptAssemblerCarriesAlternativeDrafts() {
        let sessionID = UUID()
        let alternative = TranscriptAlternative(
            engineName: "MockCohereQualityPass",
            languageCode: "en",
            text: "Cohere read only draft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            processingSeconds: 1.2
        )
        let transcription = TranscriptionResult(
            engineName: "TestEngine",
            utterances: [
                TranscriptionUtterance(startMs: 0, endMs: 1200, text: "Primary timed row", confidence: 0.91)
            ],
            languageCode: "nl",
            alternatives: [alternative]
        )

        let transcript = TranscriptAssembler.assemble(
            sessionId: sessionID,
            transcription: transcription,
            diarization: nil
        )

        XCTAssertEqual(transcript.segments.map(\.text), ["Primary timed row"])
        XCTAssertEqual(transcript.languageHint, "nl")
        XCTAssertEqual(transcript.alternatives, [alternative])
    }


    @Test
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


    @Test
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


    @Test
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

    @MainActor

    @Test
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

    @MainActor

    @Test
    func testSessionActionModelMatchesSessionState() async throws {
        let root = makeTemporaryRoot(named: "LorreSessionActionModelTests")
        let store = FileSessionStore(baseURL: root)
        let ready = try await store.createSession(
            NewSessionDraft(
                title: "Ready",
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
        let processing = try await store.createSession(
            NewSessionDraft(
                title: "Processing",
                folderId: nil,
                status: .processing,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )
        let retryableError = try await store.createSession(
            NewSessionDraft(
                title: "Retryable",
                folderId: nil,
                status: .error,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )
        var transcriptOnlyError = try await store.createSession(
            NewSessionDraft(
                title: "Transcript Only",
                folderId: nil,
                status: .error,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )
        transcriptOnlyError.audioDeletedAt = Date()
        try await store.updateSession(transcriptOnlyError)

        let viewModel = AppViewModel(
            dependencies: makeTestDependencies(
                root: root,
                store: store,
                recorder: ControlledRecorderService()
            )
        )
        await viewModel.start()

        let transcript = TranscriptDocument(
            sessionId: ready.id,
            sourceEngine: "Test",
            segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: "Ready transcript", speakerId: "S1")],
            speakers: [.defaultProfile(id: "S1")]
        )

        XCTAssertTrue(viewModel.canPerformSessionAction(.exportTranscript, for: ready, transcript: transcript))
        XCTAssertFalse(viewModel.canPerformSessionAction(.exportTranscript, for: ready, transcript: nil))

        let processingActions = viewModel.sessionActions(for: .processingStage, session: processing).map(\.action)
        XCTAssertEqual(processingActions, [.revealFiles])

        XCTAssertTrue(viewModel.canPerformSessionAction(.retryProcessing, for: retryableError))
        XCTAssertFalse(viewModel.canPerformSessionAction(.retryProcessing, for: transcriptOnlyError))
        XCTAssertEqual(
            viewModel.sessionActionState(.retryProcessing, for: transcriptOnlyError).disabledReason,
            "Source audio was deleted for this session."
        )
    }

    @MainActor

    @Test
    func testRetryProcessingImmediatelyMovesFailedSessionToProcessingState() async throws {
        let root = makeTemporaryRoot(named: "LorreRetryLocalStateTests")
        let store = FileSessionStore(baseURL: root)
        let failed = try await store.createSession(
            NewSessionDraft(
                title: "Failed",
                folderId: nil,
                status: .error,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )
        try Data("audio".utf8).write(
            to: (await store.sessionDirectoryURL(for: failed.id)).appendingPathComponent("audio.m4a")
        )

        let viewModel = AppViewModel(
            dependencies: makeTestDependencies(
                root: root,
                store: store,
                recorder: ControlledRecorderService()
            )
        )
        await viewModel.start()

        XCTAssertEqual(viewModel.workStageRoute, .transcript(failed.id))

        viewModel.retryProcessing(failed.id)

        XCTAssertEqual(viewModel.workStageRoute, .processing(failed.id))
        XCTAssertTrue(viewModel.sessionsForViewBrowser(.processing).contains(where: { $0.id == failed.id }))
        XCTAssertFalse(viewModel.sessionsForViewBrowser(.errors).contains(where: { $0.id == failed.id }))
        XCTAssertEqual(viewModel.processingSummary(for: viewModel.selectedSession!).progressLabel, "Queued")
    }

    @MainActor

    @Test
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

    @MainActor

    @Test
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

    @MainActor

    @Test
    func testImportFailureRemovesCreatedSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreImportFailureCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let viewModel = AppViewModel(
            dependencies: makeTestDependencies(
                root: root,
                store: store,
                recorder: ControlledRecorderService()
            )
        )

        await viewModel.start()
        let missingURL = root.appendingPathComponent("missing-source.m4a")
        viewModel.importAudioPickerCompleted(.success(missingURL))

        try await waitUntil {
            await MainActor.run {
                viewModel.banner?.title == "Import failed"
            }
        }

        let sessions = try await store.loadSessions()
        XCTAssertTrue(sessions.isEmpty)
    }


    @Test
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


    @Test
    func testLocalMetricsLoggerSanitizesSensitiveAttributes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreMetricsSanitizerTests-\(UUID().uuidString)", isDirectory: true)
        let logger = LocalMetricsLogger(baseURL: root)

        await logger.log(
            name: "privacy_check",
            attributes: [
                "app": "Zoom",
                "custom_base_url": "https://models.internal.example.com/private",
                "duration_seconds": "12.34",
                "error": "Could not read /Users/alice/Secret Call.m4a",
                "file": "Client Alice Call.m4a",
                "folder_id": "client-research",
                "notes": "private note text",
                "source": "microphone",
                "speaker_name": "Alice",
                "target_app": "Notes",
                "target_bundle": "com.apple.Notes"
            ]
        )

        let fileURL = root.appendingPathComponent("metrics.jsonl")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(LocalMetricEvent.self, from: data)

        XCTAssertEqual(event.attributes["app_present"], "true")
        XCTAssertEqual(event.attributes["custom_base_url_configured"], "true")
        XCTAssertEqual(event.attributes["duration_seconds"], "12.34")
        XCTAssertEqual(event.attributes["error"], "redacted")
        XCTAssertEqual(event.attributes["file_extension"], "m4a")
        XCTAssertEqual(event.attributes["folder_id"], "redacted")
        XCTAssertEqual(event.attributes["source"], "microphone")
        XCTAssertEqual(event.attributes["speaker_name_present"], "true")
        XCTAssertEqual(event.attributes["target_app_present"], "true")
        XCTAssertEqual(event.attributes["target_bundle_present"], "true")
        XCTAssertNil(event.attributes["app"])
        XCTAssertNil(event.attributes["custom_base_url"])
        XCTAssertNil(event.attributes["file"])
        XCTAssertNil(event.attributes["notes"])
        XCTAssertNil(event.attributes["speaker_name"])
        XCTAssertNil(event.attributes["target_app"])
        XCTAssertNil(event.attributes["target_bundle"])
    }


    @Test
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
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
    }


    @Test
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


    @Test
    func testModelRegistryConfigurationRequiresHTTPSURL() throws {
        _ = try ModelRegistryConfiguration().validatedForModelDownloads()

        let https = try ModelRegistryConfiguration(
            customBaseURL: "https://models.internal.example.com///"
        ).validatedForModelDownloads()
        XCTAssertEqual(https.normalizedBaseURL, "https://models.internal.example.com")

        XCTAssertThrowsError(
            try ModelRegistryConfiguration(customBaseURL: "http://models.internal.example.com").validatedForModelDownloads()
        )
        XCTAssertThrowsError(
            try ModelRegistryConfiguration(customBaseURL: "ftp://models.internal.example.com").validatedForModelDownloads()
        )
        XCTAssertThrowsError(
            try ModelRegistryConfiguration(customBaseURL: "custom://models.internal.example.com").validatedForModelDownloads()
        )
        XCTAssertThrowsError(
            try ModelRegistryConfiguration(customBaseURL: "https:///models").validatedForModelDownloads()
        )
    }


    @Test
    func testAppSettingsStoreRejectsNonHTTPSModelRegistryConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreRegistryRejectionTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        do {
            _ = try await store.setModelRegistryConfiguration(
                ModelRegistryConfiguration(customBaseURL: "http://models.internal.example.com")
            )
            XCTFail("Expected non-HTTPS registry URL to be rejected.")
        } catch {
        }

        let loaded = try await store.load()
        XCTAssertTrue(loaded.modelRegistryConfiguration.isDefault)
    }


    @Test
    func testSafeSessionFileResolverRejectsTraversalAndNestedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreSafeSessionFileTests-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let valid = try SafeSessionFileResolver.fileURL(named: "audio.m4a", in: sessionDirectory)
        XCTAssertEqual(valid.standardizedFileURL, sessionDirectory.appendingPathComponent("audio.m4a").standardizedFileURL)

        for invalidName in ["", "../audio.m4a", "../../audio.m4a", "nested/audio.m4a", "nested\\audio.m4a", "/tmp/audio.m4a", "~/.ssh/id_rsa"] {
            XCTAssertThrowsError(
                try SafeSessionFileResolver.fileURL(named: invalidName, in: sessionDirectory),
                "Expected \(invalidName) to be rejected."
            )
        }
    }


    @Test
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


    @Test
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


    @Test
    func testFileSessionStoreDoesNotRecreateDeletedSessionOnUpdateOrTranscriptSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDeletedSessionMutationTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let created = try await store.createSession(
            NewSessionDraft(
                title: "Deleted Session",
                folderId: nil,
                status: .processing,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )
        let sessionDir = await store.sessionDirectoryURL(for: created.id)

        try await store.deleteSession(id: created.id)

        do {
            try await store.updateSession(created)
            XCTFail("Expected updateSession to reject deleted session")
        } catch LorreError.sessionNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transcript = TranscriptDocument(
            sessionId: created.id,
            sourceEngine: "TestEngine",
            segments: [TranscriptSegment(startMs: 0, endMs: 500, text: "orphan", speakerId: "S1")],
            speakers: [SpeakerProfile.defaultProfile(id: "S1")]
        )
        do {
            try await store.saveTranscript(transcript)
            XCTFail("Expected saveTranscript to reject deleted session")
        } catch LorreError.sessionNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path(percentEncoded: false)))
    }


    @Test
    func testFileSessionStoreSurfacesDamagedSessionManifests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDamagedSessionTests-\(UUID().uuidString)", isDirectory: true)
        let damagedID = UUID()
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(damagedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: sessionDir.appendingPathComponent("session.json"))

        let store = FileSessionStore(baseURL: root)
        let sessions = try await store.loadSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, damagedID)
        XCTAssertEqual(sessions.first?.status, .error)
        XCTAssertEqual(sessions.first?.displayTitle, "Damaged Session")
        XCTAssertEqual(sessions.first?.hasRetainedAudio, false)
        XCTAssertTrue(sessions.first?.lastErrorMessage?.contains("Session metadata could not be read") == true)
    }


    @Test
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
          "isLiveTranscriptionEnabled" : false,
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
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(settings.isSpeakerDiarizationEnabled)
        XCTAssertEqual(settings.diarizationEngine, .offlineVbx)
        XCTAssertTrue(settings.isLiveTranscriptionEnabled)
        XCTAssertEqual(settings.diarizationExpectedSpeakerCountHint, .auto)
        XCTAssertFalse(settings.isDiarizationDebugExportEnabled)
        XCTAssertTrue(settings.modelRegistryConfiguration.isDefault)
        XCTAssertEqual(settings.selectedRecordingSource, .microphone)
        XCTAssertFalse(settings.isDeleteAudioAfterTranscriptionEnabled)
        XCTAssertFalse(settings.vocabularyBoosting.isEnabled)
        XCTAssertEqual(settings.vocabularyBoosting.simpleFormatTerms, "")
        XCTAssertEqual(settings.batchTranscription, BatchTranscriptionConfiguration())
        XCTAssertEqual(settings.liveTranscriptionPreset, .balanced)
        XCTAssertEqual(settings.automaticMarkdownExport, AutomaticMarkdownExportConfiguration())
        XCTAssertEqual(settings.globalDictation, GlobalDictationConfiguration())
    }


    @Test
    func testAppSettingsStoreRejectsDuplicateFolderNamesWithoutHanging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDuplicateFolderTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        _ = try await store.createFolder(named: "Interviews")

        do {
            _ = try await store.createFolder(named: " interviews ")
            XCTFail("Expected duplicate folder creation to fail")
        } catch LorreError.persistenceFailed(let message) {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("already exists"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let folders = try await store.loadFolders()
        XCTAssertEqual(folders.count, 1)
    }


    @Test
    func testSessionStoreAtomicTransformPreservesConcurrentSessionFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreAtomicSessionUpdateTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let created = try await store.createSession(
            NewSessionDraft(
                title: "Original",
                folderId: nil,
                status: .processing,
                durationSeconds: nil,
                recordingSource: .microphone,
                audioFileName: "audio.m4a",
                microphoneStemFileName: nil,
                systemAudioStemFileName: nil,
                recordedAt: nil
            )
        )

        async let renamed: SessionManifest = store.updateSession(id: created.id) { session in
            session.title = "Renamed"
            session.dirtyFlags.titleEdited = true
        }
        async let progressed: SessionManifest = store.updateSession(id: created.id) { session in
            session.processing = ProcessingSummary(
                queuedAt: session.processing.queuedAt,
                startedAt: Date(),
                completedAt: nil,
                progressPhase: .transcribing,
                progressLabel: "Transcribing",
                progressFraction: 0.4
            )
        }

        _ = try await (renamed, progressed)
        let loaded = try await store.loadSession(id: created.id)
        XCTAssertEqual(loaded?.title, "Renamed")
        XCTAssertEqual(loaded?.processing.progressLabel, "Transcribing")
        XCTAssertEqual(loaded?.dirtyFlags.titleEdited, true)
    }


    @Test
    func testTranscriptDocumentDecodesLegacyJSONWithEmptyAlternatives() throws {
        let legacyJSON = """
        {
          "schemaVersion" : 1,
          "sessionId" : "5E3D20E5-D3B3-430D-980B-8699A28EC4C0",
          "sourceEngine" : "FluidAudio-AsrManager-v3",
          "segments" : [
            {
              "id" : "11111111-1111-1111-1111-111111111111",
              "startMs" : 0,
              "endMs" : 1200,
              "text" : "Legacy transcript",
              "speakerId" : "S1",
              "isEdited" : false
            }
          ],
          "speakers" : [
            {
              "id" : "S1",
              "displayName" : "Speaker S1",
              "styleVariant" : "filled",
              "isUserRenamed" : false
            }
          ],
          "createdAt" : "2026-02-23T10:20:01Z",
          "updatedAt" : "2026-02-23T10:21:01Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let transcript = try decoder.decode(TranscriptDocument.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(transcript.languageHint, "en")
        XCTAssertEqual(transcript.alternatives, [])
        XCTAssertEqual(transcript.segments.first?.text, "Legacy transcript")
    }


    @Test
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


    @Test
    func testSessionManifestRequiresPersistedID() throws {
        let legacyJSONWithoutID = """
        {
          "audioFileName" : "audio.m4a",
          "createdAt" : "2026-02-23T10:20:01Z",
          "dirtyFlags" : {
            "speakerEdited" : false,
            "titleEdited" : false,
            "transcriptEdited" : false
          },
          "exports" : [],
          "processing" : {},
          "status" : "ready",
          "title" : "Missing ID",
          "updatedAt" : "2026-02-23T10:21:01Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(SessionManifest.self, from: Data(legacyJSONWithoutID.utf8)))
    }


    @Test
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


    @Test
    func testKnownSpeakerStoreRejectsReferenceClipTraversalLoadedFromJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreKnownSpeakerTraversalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = KnownSpeakerStore(baseURL: root)
        let speaker = KnownSpeaker(
            id: "K1",
            displayName: "Mallory",
            embedding: [0.1],
            styleVariant: .filled,
            referenceClip: KnownSpeakerReferenceClip(
                sourceFileName: "sample.m4a",
                storedFileName: "../../outside.m4a",
                durationSeconds: 1,
                sampleRate: 16_000,
                importedAt: Date()
            )
        )

        let url = await store.referenceAudioURL(for: speaker)
        XCTAssertNil(url)
    }


    @Test
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


    @Test
    func testKnownSpeakerStoreKeepsExistingReferenceClipWhenReplacementCopyFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreKnownSpeakerAtomicReplaceTests-\(UUID().uuidString)", isDirectory: true)
        let store = KnownSpeakerStore(baseURL: root)

        let originalURL = root.appendingPathComponent("carol-original.m4a")
        let missingReplacementURL = root.appendingPathComponent("missing-replacement.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: originalURL)

        let saved = try await store.saveNewSpeaker(
            displayName: "Carol",
            embedding: [0.1, 0.2, 0.3],
            referenceAudioURL: originalURL,
            enrollmentData: KnownSpeakerEnrollmentData(
                embedding: [0.1, 0.2, 0.3],
                durationSeconds: 2.5,
                sampleRate: 16_000
            )
        )
        let storedReferenceURL = await store.referenceAudioURL(for: saved)
        XCTAssertNotNil(storedReferenceURL)

        do {
            _ = try await store.updateSpeaker(
                saved,
                replacingReferenceAudioAt: missingReplacementURL,
                enrollmentData: KnownSpeakerEnrollmentData(
                    embedding: [0.3, 0.2, 0.1],
                    durationSeconds: 3.0,
                    sampleRate: 16_000
                )
            )
            XCTFail("Expected missing replacement clip to throw")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: storedReferenceURL!.path(percentEncoded: false)))
            let retainedData = try Data(contentsOf: storedReferenceURL!)
            XCTAssertEqual(String(decoding: retainedData, as: UTF8.self), "original")
        }
    }


    @Test
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


    @Test
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


    @Test
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


    @Test
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


    @Test
    func testAppSettingsStorePersistsDiarizationEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDiarizationEngineSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertEqual(initial.diarizationEngine, .offlineVbx)

        _ = try await store.setDiarizationEngine(.sortformer)
        let sortformer = try await store.load()
        XCTAssertEqual(sortformer.diarizationEngine, .sortformer)

        _ = try await store.setDiarizationEngine(.lsEend)
        let lsEend = try await store.load()
        XCTAssertEqual(lsEend.diarizationEngine, .lsEend)
    }


    @Test
    func testAppSettingsStorePersistsLiveTranscriptionToggle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreLiveTranscriptSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertTrue(initial.isLiveTranscriptionEnabled)

        _ = try await store.setLiveTranscriptionEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.isLiveTranscriptionEnabled)

        _ = try await store.setLiveTranscriptionEnabled(true)
        let enabled = try await store.load()
        XCTAssertTrue(enabled.isLiveTranscriptionEnabled)
    }


    @Test
    func testAppSettingsStorePersistsBatchTranscriptionConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreBatchTranscriptionSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertEqual(initial.batchTranscription, BatchTranscriptionConfiguration())

        _ = try await store.setBatchTranscriptionConfiguration(
            BatchTranscriptionConfiguration(
                mode: .parakeetV3WithCohereQualityPass,
                languageCode: "NL",
                parallelChunkConcurrency: 12
            )
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.batchTranscription.mode, .parakeetV3WithCohereQualityPass)
        XCTAssertEqual(loaded.batchTranscription.languageCode, "nl")
        XCTAssertEqual(loaded.batchTranscription.parallelChunkConcurrency, 8)
    }


    @Test
    func testParakeetV2BatchModeIsEnglishOnly() async throws {
        XCTAssertTrue(
            BatchTranscriptionConfiguration.availableModes(forLanguageCode: "EN")
                .contains(.parakeetV2English)
        )
        XCTAssertFalse(
            BatchTranscriptionConfiguration.availableModes(forLanguageCode: "NL")
                .contains(.parakeetV2English)
        )

        let normalized = BatchTranscriptionConfiguration(
            mode: .parakeetV2English,
            languageCode: "nl",
            parallelChunkConcurrency: 4
        )
        XCTAssertEqual(normalized.mode, .parakeetV3)
        XCTAssertEqual(normalized.languageCode, "nl")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreParakeetV2EnglishOnlyTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)
        _ = try await store.setBatchTranscriptionConfiguration(
            BatchTranscriptionConfiguration(
                mode: .parakeetV2English,
                languageCode: "en",
                parallelChunkConcurrency: 2
            )
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.batchTranscription.mode, .parakeetV2English)
        XCTAssertEqual(loaded.batchTranscription.languageCode, "en")
    }


    @Test
    func testAppSettingsStorePersistsLiveTranscriptionPreset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreLivePresetSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertEqual(initial.liveTranscriptionPreset, .balanced)

        _ = try await store.setLiveTranscriptionPreset(.nemotronBalanced)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.liveTranscriptionPreset, .nemotronBalanced)
    }


    @Test
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


    @Test
    func testAppSettingsStorePersistsAutomaticMarkdownExportConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreAutoMarkdownExportSettingTests-\(UUID().uuidString)", isDirectory: true)
        let exportFolder = root.appendingPathComponent("exports", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertFalse(initial.automaticMarkdownExport.isEnabled)
        XCTAssertNil(initial.automaticMarkdownExport.folderPath)
        XCTAssertEqual(
            initial.automaticMarkdownExport.fileNameTemplate,
            AutomaticMarkdownExportConfiguration.defaultFileNameTemplate
        )

        _ = try await store.setAutomaticMarkdownExportFolderURL(exportFolder)
        let configured = try await store.load()
        XCTAssertTrue(configured.automaticMarkdownExport.isEnabled)
        XCTAssertEqual(
            configured.automaticMarkdownExport.folderPath,
            exportFolder.standardizedFileURL.path(percentEncoded: false)
        )

        _ = try await store.setAutomaticMarkdownExportEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.automaticMarkdownExport.isEnabled)
        XCTAssertEqual(
            disabled.automaticMarkdownExport.folderPath,
            exportFolder.standardizedFileURL.path(percentEncoded: false)
        )

        _ = try await store.setAutomaticMarkdownExportFileNameTemplate("{datetime}-{speaker_count}-{keywords}")
        let templated = try await store.load()
        XCTAssertFalse(templated.automaticMarkdownExport.isEnabled)
        XCTAssertEqual(templated.automaticMarkdownExport.fileNameTemplate, "{datetime}-{speaker_count}-{keywords}")
    }


    @Test
    func testAppSettingsStorePersistsGlobalDictationConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreGlobalDictationSettingTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppSettingsStore(baseURL: root)

        let initial = try await store.load()
        XCTAssertFalse(initial.globalDictation.isEnabled)
        XCTAssertEqual(initial.globalDictation.shortcut, .optionShiftD)

        _ = try await store.saveGlobalDictationConfiguration(
            GlobalDictationConfiguration(
                isEnabled: true,
                shortcut: .commandOptionShiftD
            )
        )
        let configured = try await store.load()
        XCTAssertTrue(configured.globalDictation.isEnabled)
        XCTAssertEqual(configured.globalDictation.shortcut, .commandOptionShiftD)

        _ = try await store.setGlobalDictationShortcut(.optionShiftSpace)
        let shortcutChanged = try await store.load()
        XCTAssertEqual(shortcutChanged.globalDictation.shortcut, .optionShiftSpace)

        _ = try await store.setGlobalDictationEnabled(false)
        let disabled = try await store.load()
        XCTAssertFalse(disabled.globalDictation.isEnabled)
        XCTAssertEqual(disabled.globalDictation.shortcut, .optionShiftSpace)
    }


    @Test
    func testAppSettingsMigratesLegacyControlGlobalDictationShortcut() async throws {
        let legacyJSON = """
        {
          "schemaVersion" : 6,
          "globalDictation" : {
            "isEnabled" : true,
            "shortcut" : "controlOptionD",
            "retainsSnippets" : false
          }
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertTrue(settings.globalDictation.isEnabled)
        XCTAssertEqual(settings.globalDictation.shortcut, .optionShiftD)
    }


    @Test
    func testAppViewModelGlobalDictationShortcutChoicesAvoidControl() async throws {
        let root = makeTemporaryRoot(named: "LorreGlobalDictationShortcutChoiceTests")
        let viewModel = await MainActor.run {
            AppViewModel(
                dependencies: makeTestDependencies(
                    root: root,
                    recorder: ControlledRecorderService()
                )
            )
        }

        await MainActor.run {
            XCTAssertEqual(
                viewModel.globalDictationShortcutChoices,
                [.optionShiftD, .optionShiftSpace, .commandOptionShiftD]
            )
            XCTAssertFalse(viewModel.globalDictationShortcutChoices.contains(.controlOptionD))
            XCTAssertFalse(viewModel.globalDictationShortcutChoices.contains(.controlOptionSpace))
            XCTAssertFalse(viewModel.globalDictationShortcutChoices.contains(.controlOptionCommandD))
        }
    }


    @Test
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


    @Test
    func testVocabularyBoostingSimpleFormatParserNormalizesRuntimeTerms() {
        let configuration = VocabularyBoostingConfiguration(
            isEnabled: true,
            simpleFormatTerms: """
            # Domain terms
              Lorre: lore, lora,

            FluidAudio
            : ignored
            """
        )

        XCTAssertEqual(
            configuration.simpleFormatEntries,
            [
                VocabularyBoostingEntry(term: "Lorre", aliases: ["lore", "lora"]),
                VocabularyBoostingEntry(term: "FluidAudio", aliases: [])
            ]
        )
        XCTAssertEqual(configuration.runtimeSimpleFormatTerms, "Lorre: lore, lora\nFluidAudio")
    }


    @Test
    func testMockCohereQualityPassPreservesPrimaryTranscriptAndAddsAlternative() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreMockCohereQualityPassTests-\(UUID().uuidString)", isDirectory: true)
        let audioURL = root.appendingPathComponent("audio.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mock-audio".utf8).write(to: audioURL)

        let service = MockTranscriptionService()
        await service.setBatchTranscriptionConfiguration(
            BatchTranscriptionConfiguration(
                mode: .parakeetV3WithCohereQualityPass,
                languageCode: "nl"
            )
        )

        let result = try await service.transcribe(url: audioURL, sessionTitle: "Quality Pass", source: .microphone)

        XCTAssertFalse(result.utterances.isEmpty)
        XCTAssertEqual(result.engineName, "MockAsrService")
        XCTAssertEqual(result.languageCode, "nl")
        XCTAssertEqual(result.alternatives.count, 1)
        XCTAssertEqual(result.alternatives.first?.engineName, "MockCohereQualityPass")
        XCTAssertEqual(result.alternatives.first?.languageCode, "nl")
    }


    @Test
    func testUnavailableTranscriptionServiceFailsInsteadOfReturningMockTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreUnavailableTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        let audioURL = root.appendingPathComponent("audio.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audioURL)

        let service = UnavailableTranscriptionService()

        do {
            _ = try await service.transcribe(url: audioURL, sessionTitle: "Unavailable", source: .microphone)
            XCTFail("Expected unavailable transcription to throw instead of returning mock text.")
        } catch let error as LorreError {
            XCTAssertTrue(error.localizedDescription.contains("FluidAudio is not linked"))
        }
    }

    #if canImport(AVFoundation) && canImport(FluidAudio)

    @Test
    func testFluidAudioLivePresetMapsToSelectedStreamingModel() {
        XCTAssertEqual(
            FluidAudioLiveStreamingRecognizer.livePreviewModelFolderName(for: .lowLatency),
            "parakeet-eou-streaming/160ms"
        )
        XCTAssertEqual(
            FluidAudioLiveStreamingRecognizer.livePreviewModelFolderName(for: .balanced),
            "parakeet-eou-streaming/320ms"
        )
        XCTAssertEqual(
            FluidAudioLiveStreamingRecognizer.livePreviewModelFolderName(for: .highAccuracy),
            "parakeet-eou-streaming/1280ms"
        )
        XCTAssertEqual(
            FluidAudioLiveStreamingRecognizer.livePreviewModelFolderName(for: .nemotronBalanced),
            "nemotron-streaming/560ms"
        )
        XCTAssertEqual(
            FluidAudioLiveStreamingRecognizer.livePreviewModelFolderName(for: .nemotronHighAccuracy),
            "nemotron-streaming/1120ms"
        )
        XCTAssertEqual(FluidAudioLiveStreamingRecognizer.livePreviewDebounceMilliseconds(for: .balanced), 1280)
        XCTAssertEqual(FluidAudioLiveStreamingRecognizer.livePreviewDebounceMilliseconds(for: .nemotronBalanced), 0)
    }


    @Test
    func testLiveSpeakerHintConfidenceUsesClampedActivity() {
        XCTAssertEqual(FluidAudioLiveStreamingRecognizer.normalizedLiveSpeakerActivity(-0.4), 0)
        XCTAssertEqual(FluidAudioLiveStreamingRecognizer.normalizedLiveSpeakerActivity(0.72), 0.72)
        XCTAssertEqual(FluidAudioLiveStreamingRecognizer.normalizedLiveSpeakerActivity(1.4), 1)
    }
    #endif


    @Test
    func testTranscriptTextNormalizationSupportNormalizesSegmentTextPreservingMetadata() {
        let sessionID = UUID()
        let original = TranscriptDocument(
            sessionId: sessionID,
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 1200,
                    text: "two hundred dollars",
                    speakerId: "S1",
                    sourceSpeakerId: "S1",
                    confidence: 0.92
                ),
                TranscriptSegment(
                    startMs: 1200,
                    endMs: 2200,
                    text: "plain text",
                    speakerId: "S2",
                    sourceSpeakerId: "S2",
                    confidence: 0.88
                )
            ],
            speakers: [.defaultProfile(id: "S1"), .defaultProfile(id: "S2")]
        )

        let normalized = TranscriptTextNormalizationSupport.normalize(original) { text in
            switch text {
            case "two hundred dollars":
                return "$200"
            default:
                return text
            }
        }

        XCTAssertEqual(normalized.sessionId, original.sessionId)
        XCTAssertEqual(normalized.sourceEngine, original.sourceEngine)
        XCTAssertEqual(normalized.segments[0].text, "$200")
        XCTAssertEqual(normalized.segments[0].startMs, original.segments[0].startMs)
        XCTAssertEqual(normalized.segments[0].endMs, original.segments[0].endMs)
        XCTAssertEqual(normalized.segments[0].speakerId, original.segments[0].speakerId)
        XCTAssertEqual(normalized.segments[0].confidence, original.segments[0].confidence)
        XCTAssertEqual(normalized.segments[1].text, "plain text")
    }


    @Test
    func testTranscriptTextNormalizationSupportIgnoresEmptyNormalizerOutput() {
        let original = TranscriptDocument(
            sessionId: UUID(),
            sourceEngine: "TestEngine",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1000, text: "keep me", speakerId: "S1")
            ],
            speakers: [.defaultProfile(id: "S1")]
        )

        let normalized = TranscriptTextNormalizationSupport.normalize(original) { _ in
            "   "
        }

        XCTAssertEqual(normalized, original)
    }


    @Test
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


    @Test
    func testProcessingCoordinatorPublishesDiarizationRunProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreDiarizationProgressTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(
            NewSessionDraft(
                title: "Diarization Progress Test",
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
        let collector = ProcessingUpdateCollector()
        let coordinator = ProcessingCoordinator(
            store: store,
            transcriptionService: MockTranscriptionService(),
            diarizationService: MockSpeakerDiarizationService()
        )

        _ = try await coordinator.process(
            sessionId: session.id,
            enableDiarization: true,
            diarizationExpectedSpeakers: .exact(2),
            onProgress: { update in
                await collector.append(update)
            }
        )

        let diarizationUpdates = await collector.snapshot().filter { $0.phase == .diarizing }
        XCTAssertTrue(
            diarizationUpdates.contains { update in
                update.component == .diarization
                    && update.label == "Assigning mock speakers"
                    && (update.fraction ?? 0) > 0.60
                    && (update.fraction ?? 1) <= 0.80
            }
        )
    }


    @Test
    func testProcessingCoordinatorCancellationDoesNotRecreateDeletedSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorreProcessingCancellationTests-\(UUID().uuidString)", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let session = try await store.createSession(
            NewSessionDraft(
                title: "Cancellation Test",
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

        let task = Task {
            try await coordinator.process(
                sessionId: session.id,
                enableDiarization: true,
                diarizationExpectedSpeakers: .exact(2),
                onProgress: { _ in }
            )
        }

        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        try await store.deleteSession(id: session.id)

        do {
            _ = try await task.value
            XCTFail("Expected processing task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let loadedSession = try await store.loadSession(id: session.id)
        XCTAssertNil(loadedSession)
        let sessionDir = await store.sessionDirectoryURL(for: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path(percentEncoded: false)))
    }


    @Test
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


    @Test
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


    @Test
    func testDiarizationSpeakerCountHintPresetsIncludeExactOne() {
        XCTAssertTrue(DiarizationSpeakerCountHint.tuningPresets.contains(.exact(1)))
    }


    @Test
    func testFluidAudioDiarizationServiceQualityTunedConfigEnablesEmbeddingSkipStrategy() {
        let config = FluidAudioDiarizationService.makeQualityTunedConfig(expectedSpeakers: .auto)

        XCTAssertEqual(config.segmentationStepRatio, 0.1)
        XCTAssertEqual(config.minSegmentDuration, 0.45)
        XCTAssertEqual(config.clusteringThreshold, 0.54)
        XCTAssertEqual(config.minGapDuration, 0.18)

        switch config.embeddingSkipStrategy {
        case let .maskSimilarity(threshold):
            XCTAssertEqual(threshold, FluidAudioDiarizationService.qualityTunedEmbeddingSkipThreshold)
        case .none:
            XCTFail("Expected mask-similarity embedding skipping for quality-tuned diarization.")
        }
    }


    @Test
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


    @Test
    func testAppViewModelAutomaticallyExportsMarkdownAfterProcessing() async throws {
        let root = makeTemporaryRoot(named: "LorreAutoMarkdownExportFlowTests")
        let exportFolder = root.appendingPathComponent("auto-md", isDirectory: true)
        let store = FileSessionStore(baseURL: root)
        let dependencies = makeTestDependencies(
            root: root,
            store: store,
            recorder: ControlledRecorderService()
        )
        _ = try await dependencies.settings.saveAutomaticMarkdownExportConfiguration(
            AutomaticMarkdownExportConfiguration(
                isEnabled: true,
                folderPath: exportFolder.path(percentEncoded: false),
                fileNameTemplate: "{date}-{keywords}"
            )
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            XCTAssertTrue(viewModel.isAutomaticMarkdownExportEnabled)
            viewModel.startRecordingTapped()
        }
        try await waitUntil {
            await MainActor.run { viewModel.isRecording }
        }

        await MainActor.run {
            viewModel.stopRecordingTapped()
        }
        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run {
                viewModel.selectedSession?.status == .ready
                    && viewModel.selectedSession?.exports.contains(where: { $0.format == .markdown }) == true
            }
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: exportFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let markdownFiles = files.filter { $0.pathExtension == "md" }
        XCTAssertEqual(markdownFiles.count, 1)
        let expectedFileName = await MainActor.run {
            AutomaticExportFileNameBuilder.fileName(
                session: viewModel.selectedSession!,
                transcript: viewModel.activeTranscript!,
                template: "{date}-{keywords}"
            )
        }
        XCTAssertEqual(markdownFiles[0].lastPathComponent, expectedFileName)

        let markdown = try String(contentsOf: markdownFiles[0], encoding: .utf8)
        XCTAssertTrue(markdown.contains("We need a clean transcript"))
        await MainActor.run {
            XCTAssertEqual(viewModel.banner?.title, "Markdown exported")
            XCTAssertTrue(viewModel.exportMessage?.contains("Auto-exported Markdown") == true)
        }
    }


    @Test
    func testAppViewModelGlobalDictationHotkeyTranscribesAndInsertsText() async throws {
        let root = makeTemporaryRoot(named: "LorreGlobalDictationFlowTests")
        let recorder = ControlledRecorderService()
        let hotKey = TestGlobalDictationHotKeyService()
        let insertion = TestGlobalTextInsertionService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            globalDictationHotKey: hotKey,
            globalTextInsertion: insertion
        )
        _ = try await dependencies.settings.saveGlobalDictationConfiguration(
            GlobalDictationConfiguration(isEnabled: true, shortcut: .optionShiftD)
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            XCTAssertTrue(viewModel.isGlobalDictationEnabled)
            XCTAssertEqual(hotKey.registeredShortcut, .optionShiftD)
            hotKey.fire()
        }

        try await waitUntil {
            await MainActor.run { viewModel.globalDictationPhase == .listening }
        }

        await MainActor.run {
            hotKey.fire()
        }

        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run { viewModel.globalDictationPhase == .inserted }
        }

        await MainActor.run {
            XCTAssertTrue(insertion.promptRequests.last == true)
            XCTAssertTrue(insertion.insertedText?.contains("We need a clean transcript") == true)
            XCTAssertEqual(viewModel.banner?.title, "Dictation inserted")
        }
    }

    @Test
    func testAppViewModelGlobalDictationUsesOriginalTargetWhenFocusChangesBeforeInsert() async throws {
        let root = makeTemporaryRoot(named: "LorreGlobalDictationOriginalTargetTests")
        let recorder = ControlledRecorderService()
        let hotKey = TestGlobalDictationHotKeyService()
        let insertion = TestGlobalTextInsertionService()
        let originalTarget = GlobalTextInsertionTarget(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 42,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let laterTarget = GlobalTextInsertionTarget(
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            processIdentifier: 84,
            capturedAt: Date(timeIntervalSince1970: 1_100)
        )
        await MainActor.run {
            insertion.preparation = .ready(originalTarget)
        }
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            globalDictationHotKey: hotKey,
            globalTextInsertion: insertion
        )
        _ = try await dependencies.settings.saveGlobalDictationConfiguration(
            GlobalDictationConfiguration(isEnabled: true, shortcut: .optionShiftD)
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            hotKey.fire()
        }

        try await waitUntil {
            await MainActor.run { viewModel.globalDictationPhase == .listening }
        }

        await MainActor.run {
            insertion.preparation = .ready(laterTarget)
            hotKey.fire()
        }

        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run { viewModel.globalDictationPhase == .inserted }
        }

        await MainActor.run {
            XCTAssertEqual(insertion.insertedTarget, originalTarget)
            XCTAssertEqual(viewModel.globalDictationTargetLabel, originalTarget.displayName)
        }
    }


    @Test
    func testAppViewModelGlobalDictationShowsFailureStateWhenAccessibilityIsMissing() async throws {
        let root = makeTemporaryRoot(named: "LorreGlobalDictationPermissionTests")
        let hotKey = TestGlobalDictationHotKeyService()
        let insertion = TestGlobalTextInsertionService()
        await MainActor.run {
            insertion.preparation = .missingAccessibilityPermission
        }
        let dependencies = makeTestDependencies(
            root: root,
            recorder: ControlledRecorderService(),
            globalDictationHotKey: hotKey,
            globalTextInsertion: insertion
        )
        _ = try await dependencies.settings.saveGlobalDictationConfiguration(
            GlobalDictationConfiguration(isEnabled: true, shortcut: .optionShiftD)
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            hotKey.fire()
        }

        try await waitUntil {
            await MainActor.run { viewModel.globalDictationPhase == .failed }
        }

        await MainActor.run {
            XCTAssertTrue(insertion.promptRequests.last == true)
            XCTAssertEqual(viewModel.globalDictationTargetLabel, "Accessibility")
            XCTAssertTrue(viewModel.globalDictationStatusLine.localizedCaseInsensitiveContains("Accessibility"))
            XCTAssertEqual(viewModel.banner?.title, "Cannot start global dictation")
        }
    }

    @Test
    func testAppViewModelGlobalDictationKeepsTranscriptAvailableWhenInsertionFails() async throws {
        let root = makeTemporaryRoot(named: "LorreGlobalDictationInsertionFallbackTests")
        let recorder = ControlledRecorderService()
        let hotKey = TestGlobalDictationHotKeyService()
        let insertion = TestGlobalTextInsertionService()
        await MainActor.run {
            insertion.insertionResult = .failed(
                code: "no_editable_target",
                message: "No editable text field was detected in Notes."
            )
        }
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            globalDictationHotKey: hotKey,
            globalTextInsertion: insertion
        )
        _ = try await dependencies.settings.saveGlobalDictationConfiguration(
            GlobalDictationConfiguration(isEnabled: true, shortcut: .optionShiftD)
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            hotKey.fire()
        }

        try await waitUntil {
            await MainActor.run { viewModel.globalDictationPhase == .listening }
        }

        await MainActor.run {
            hotKey.fire()
        }

        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run { viewModel.globalDictationPhase == .failed }
        }

        await MainActor.run {
            XCTAssertTrue(viewModel.globalDictationTranscriptText.contains("We need a clean transcript"))
            XCTAssertEqual(viewModel.banner?.title, "Dictation insertion failed")
            viewModel.copyGlobalDictationTranscriptToClipboard()
            XCTAssertEqual(insertion.copiedText, viewModel.globalDictationTranscriptText)
        }
    }


    @Test
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


    @Test
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


    @Test
    func testAppSettingsStorePersistsCallWatcherConfiguration() async throws {
        let root = makeTemporaryRoot(named: "LorreCallWatcherSettingsTests")
        let store = AppSettingsStore(baseURL: root)

        _ = try await store.saveCallWatcherConfiguration(
            CallWatcherConfiguration(
                isEnabled: true,
                defaultRecordingSource: .systemAudio,
                cooldownSeconds: 120
            )
        )

        let loaded = try await store.load()
        XCTAssertTrue(loaded.callWatcher.isEnabled)
        XCTAssertEqual(loaded.callWatcher.defaultRecordingSource, .systemAudio)
        XCTAssertEqual(loaded.callWatcher.cooldownSeconds, 120)
    }

    @Test
    func testAppViewModelRequestsCallPromptNotificationAuthorizationWhenRestoredEnabled() async throws {
        let root = makeTemporaryRoot(named: "LorreRestoredCallWatcherNotificationTests")
        let settings = AppSettingsStore(baseURL: root)
        _ = try await settings.saveCallWatcherConfiguration(
            CallWatcherConfiguration(isEnabled: true)
        )
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()

        try await waitUntil {
            callWatcher.isSubscribed && notifications.authorizationRequestCount > 0
        }
    }


    @Test
    func testAppViewModelStartsRecordingFromCallPrompt() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptStartTests")
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let dependencies = makeTestDependencies(root: root, recorder: recorder, callWatcher: callWatcher)
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "com.google.Chrome:3",
            appBundleID: "com.google.Chrome",
            appDisplayName: "Google Chrome",
            confidenceScore: 90,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.browserCallWindowTitle]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            await MainActor.run { viewModel.callPromptCandidate != nil }
        }

        await MainActor.run {
            XCTAssertEqual(viewModel.callPromptCandidate?.appDisplayName, "Google Chrome")
            viewModel.acceptCallPromptTapped()
        }

        try await waitUntil {
            await recorder.lastStartRequest != nil
        }

        let request = await recorder.lastStartRequest
        XCTAssertEqual(request?.source, .microphoneAndSystemAudio)
    }

    @Test
    func testAppViewModelStartsRecordingFromCallPromptNotificationAction() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptNotificationStartTests")
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        try await waitUntil {
            notifications.isActionStreamSubscribed
        }
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "com.microsoft.edgemac:3",
            appBundleID: "com.microsoft.edgemac",
            appDisplayName: "Microsoft Edge",
            confidenceScore: 90,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.captureDeviceInUse]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            notifications.shownCandidates.contains(where: { $0.fingerprint == candidate.fingerprint })
        }

        notifications.emit(.accept(fingerprint: candidate.fingerprint))

        try await waitUntil {
            await recorder.lastStartRequest != nil
        }

        let request = await recorder.lastStartRequest
        XCTAssertEqual(request?.source, .microphoneAndSystemAudio)
        XCTAssertTrue(notifications.removedFingerprints.contains(candidate.fingerprint))
    }

    @Test
    func testAppViewModelCallPromptFallsBackToInAppWhenNotificationsAreDenied() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptNotificationDeniedTests")
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        notifications.authorizationGranted = false
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "com.google.Chrome:3",
            appBundleID: "com.google.Chrome",
            appDisplayName: "Google Chrome",
            confidenceScore: 90,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.browserCallWindowTitle]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            await MainActor.run {
                viewModel.callPromptCandidate?.fingerprint == candidate.fingerprint
                    && viewModel.callWatcherStatusLine.contains("Notifications unavailable")
            }
        }

        await MainActor.run {
            XCTAssertTrue(notifications.shownCandidates.isEmpty)
            XCTAssertEqual(viewModel.banner?.title, "Call detected")
        }
    }

    @Test
    func testAppViewModelIgnoresDuplicateCallPromptNotificationAccepts() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptDuplicateAcceptTests")
        let recorder = ControlledRecorderService(startDelay: .milliseconds(200))
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "us.zoom.xos:3",
            appBundleID: "us.zoom.xos",
            appDisplayName: "Zoom",
            confidenceScore: 95,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.knownCommunicationAppForeground, .captureDeviceInUse]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            notifications.shownCandidates.contains(where: { $0.fingerprint == candidate.fingerprint })
        }

        notifications.emit(.accept(fingerprint: candidate.fingerprint))
        notifications.emit(.accept(fingerprint: candidate.fingerprint))

        try await waitUntil {
            await recorder.startCallCount == 1
        }
        try await Task.sleep(for: .milliseconds(100))

        let startCallCount = await recorder.startCallCount
        XCTAssertEqual(startCallCount, 1)
    }

    @Test
    func testAppViewModelDismissedCallPromptSuppressesWatcherPrompt() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptDismissSuppressTests")
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "com.microsoft.edgemac:3",
            appBundleID: "com.microsoft.edgemac",
            appDisplayName: "Microsoft Edge",
            confidenceScore: 90,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.captureDeviceInUse]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            await MainActor.run { viewModel.callPromptCandidate?.fingerprint == candidate.fingerprint }
        }

        await MainActor.run {
            viewModel.dismissCallPromptTapped()
        }

        try await waitUntil {
            callWatcher.suppressedPrompts.contains {
                $0.fingerprint == candidate.fingerprint && $0.cooldownSeconds == 600
            }
        }
        XCTAssertTrue(notifications.removedFingerprints.contains(candidate.fingerprint))
    }

    @Test
    func testAppViewModelRemovesCallPromptNotificationWhenCandidateEnds() async throws {
        let root = makeTemporaryRoot(named: "LorreCallPromptNotificationEndTests")
        let recorder = ControlledRecorderService()
        let callWatcher = TestCallWatcherService()
        let notifications = TestCallPromptNotificationService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            callWatcher: callWatcher,
            callPromptNotifications: notifications
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }

        await viewModel.start()
        await MainActor.run {
            viewModel.setCallWatcherEnabled(true)
        }
        try await waitUntil {
            callWatcher.isSubscribed
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "com.microsoft.edgemac:3",
            appBundleID: "com.microsoft.edgemac",
            appDisplayName: "Microsoft Edge",
            confidenceScore: 90,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.captureDeviceInUse]
        )

        callWatcher.emit(.candidateDetected(candidate))

        try await waitUntil {
            notifications.shownCandidates.contains(where: { $0.fingerprint == candidate.fingerprint })
        }

        callWatcher.emit(.candidateEnded(fingerprint: candidate.fingerprint))

        try await waitUntil {
            notifications.removedFingerprints.contains(candidate.fingerprint)
        }

        await MainActor.run {
            XCTAssertNil(viewModel.callPromptCandidate)
        }
    }


    @Test
    func testAppViewModelPassesLivePreviewRequestWhenSupportedAndEnabledByDefault() async throws {
        let root = makeTemporaryRoot(named: "LorreLivePreviewStartRequestTests")
        let recorder = ControlledRecorderService(
            supportBySource: [
                .microphone: true
            ]
        )
        let viewModel = await MainActor.run {
            AppViewModel(dependencies: makeTestDependencies(root: root, recorder: recorder))
        }

        await viewModel.start()
        try await waitUntil {
            await MainActor.run { viewModel.isLiveTranscriptionSupported && viewModel.isLiveTranscriptionEnabled }
        }

        await MainActor.run {
            viewModel.startRecordingTapped()
        }

        try await waitUntil {
            await recorder.lastStartRequest != nil
        }

        let request = await recorder.lastStartRequest
        XCTAssertEqual(request?.source, .microphone)
        XCTAssertEqual(request?.liveTranscriptionEnabled, true)
    }


    @Test
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
