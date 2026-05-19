import Foundation

actor ProcessingCoordinator {
    private let store: any SessionStore
    private let transcriptionService: any TranscriptionService
    private let diarizationService: any SpeakerDiarizationService

    init(
        store: any SessionStore,
        transcriptionService: any TranscriptionService,
        diarizationService: any SpeakerDiarizationService
    ) {
        self.store = store
        self.transcriptionService = transcriptionService
        self.diarizationService = diarizationService
    }

    func process(
        sessionId: UUID,
        enableDiarization: Bool = true,
        diarizationExpectedSpeakers: DiarizationSpeakerCountHint = .auto,
        exportDiarizationDebugArtifact: Bool = false,
        deleteAudioAfterTranscription: Bool = false,
        onProgress: @escaping @Sendable (ProcessingUpdate) async -> Void
    ) async throws -> TranscriptDocument {
        guard var session = try await store.loadSession(id: sessionId) else {
            throw LorreError.sessionNotFound
        }

        do {
            try await updateSession(&session, status: .processing, phase: .preparing, label: "Preparing models", fraction: 0.05)
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .registry,
                    label: "Preparing models",
                    detail: "Checking model cache and runtime configuration…",
                    fraction: 0.05
                )
            )

            let transcriptionPrepRange: ClosedRange<Double> = enableDiarization ? 0.05...0.22 : 0.05...0.28
            try await transcriptionService.ensureModelsReady { update in
                await onProgress(self.scale(update, into: transcriptionPrepRange))
            }
            if enableDiarization {
                try await diarizationService.ensureModelsReady { update in
                    await onProgress(self.scale(update, into: 0.22...0.32))
                }
            }

            let sessionDir = await store.sessionDirectoryURL(for: sessionId)
            let audioURL = sessionDir.appendingPathComponent(session.audioFileName)

            try await updateSession(&session, status: .processing, phase: .transcribing, label: "Transcribing audio", fraction: 0.3)
            await onProgress(ProcessingUpdate(phase: .transcribing, label: "Transcribing audio", fraction: 0.3))
            let transcription = try await transcriptionService.transcribe(
                url: audioURL,
                sessionTitle: session.displayTitle,
                source: session.recordingSource
            )

            if enableDiarization {
                try await updateSession(
                    &session,
                    status: .processing,
                    phase: .assembling,
                    label: "Saving draft transcript",
                    fraction: 0.52
                )
                await onProgress(ProcessingUpdate(phase: .assembling, label: "Saving draft transcript", fraction: 0.52))

                let draftTranscript = TranscriptTextNormalizationSupport.normalize(
                    TranscriptAssembler.assemble(
                        sessionId: sessionId,
                        transcription: transcription,
                        diarization: nil
                    )
                )
                try await store.saveTranscript(draftTranscript)
                session.transcriptFileName = "transcript.json"
                session.updatedAt = Date()
                try await store.updateSession(session)

                try await updateSession(
                    &session,
                    status: .processing,
                    phase: .diarizing,
                    label: "Draft transcript ready • assigning speakers",
                    fraction: 0.58
                )
                await onProgress(
                    ProcessingUpdate(
                        phase: .diarizing,
                        label: "Draft transcript ready • assigning speakers",
                        fraction: 0.58
                    )
                )
            }

            let diarization: DiarizationResult?
            if enableDiarization {
                try await updateSession(&session, status: .processing, phase: .diarizing, label: "Assigning speakers", fraction: 0.6)
                await onProgress(ProcessingUpdate(phase: .diarizing, label: "Assigning speakers", fraction: 0.6))
                diarization = try await diarizationService.diarize(
                    url: audioURL,
                    expectedDurationSeconds: session.durationSeconds,
                    expectedSpeakers: diarizationExpectedSpeakers,
                    onProgress: { update in
                        await onProgress(self.scale(update, into: 0.60...0.80))
                    }
                )
            } else {
                try await updateSession(&session, status: .processing, phase: .diarizing, label: "Skipping speaker diarization", fraction: 0.6)
                await onProgress(ProcessingUpdate(phase: .diarizing, label: "Skipping speaker diarization", fraction: 0.6))
                diarization = nil
            }
            let adjustedDiarization = diarization?.applyingSpeakerCountHint(diarizationExpectedSpeakers)

            try await updateSession(&session, status: .processing, phase: .assembling, label: "Assembling transcript", fraction: 0.82)
            await onProgress(ProcessingUpdate(phase: .assembling, label: "Assembling transcript", fraction: 0.82))
            let transcript = TranscriptTextNormalizationSupport.normalize(
                TranscriptAssembler.assemble(
                    sessionId: sessionId,
                    transcription: transcription,
                    diarization: adjustedDiarization
                )
            )

            if exportDiarizationDebugArtifact {
                try await writeDiarizationDebugArtifact(
                    sessionId: sessionId,
                    sourceEngine: transcription.engineName,
                    transcription: transcription,
                    diarization: adjustedDiarization,
                    transcript: transcript,
                    expectedSpeakers: diarizationExpectedSpeakers
                )
            }

            try await updateSession(&session, status: .processing, phase: .saving, label: "Saving transcript", fraction: 0.95)
            await onProgress(ProcessingUpdate(phase: .saving, label: "Saving transcript", fraction: 0.95))
            try await store.saveTranscript(transcript)
            if deleteAudioAfterTranscription {
                try await deleteAudioArtifacts(for: session, in: sessionDir)
                session.audioDeletedAt = Date()
            } else {
                session.audioDeletedAt = nil
            }

            session.status = .ready
            session.transcriptFileName = "transcript.json"
            session.lastErrorMessage = nil
            session.updatedAt = Date()
            session.processing = ProcessingSummary(
                queuedAt: session.processing.queuedAt,
                startedAt: session.processing.startedAt,
                completedAt: Date(),
                progressPhase: nil,
                progressLabel: "Ready",
                progressFraction: 1
            )
            try await store.updateSession(session)
            await onProgress(ProcessingUpdate(phase: .saving, label: "Ready", fraction: 1))
            return transcript
        } catch {
            session.status = .error
            session.updatedAt = Date()
            session.lastErrorMessage = error.localizedDescription
            session.processing = ProcessingSummary(
                queuedAt: session.processing.queuedAt,
                startedAt: session.processing.startedAt,
                completedAt: Date(),
                progressPhase: nil,
                progressLabel: "Error",
                progressFraction: session.processing.progressFraction
            )
            try? await store.updateSession(session)
            throw LorreError.processingFailed(error.localizedDescription)
        }
    }

    func prepareModels(
        includeDiarization: Bool = true,
        onProgress: @escaping @Sendable (ProcessingUpdate) async -> Void
    ) async throws {
        await onProgress(
            ProcessingUpdate(
                phase: .preparing,
                component: .registry,
                label: "Preparing models",
                detail: "Checking model cache and runtime configuration…",
                fraction: 0.02
            )
        )
        let transcriptionRange: ClosedRange<Double> = includeDiarization ? 0.02...0.62 : 0.02...1.0
        try await transcriptionService.ensureModelsReady { update in
            await onProgress(self.scale(update, into: transcriptionRange))
        }
        if includeDiarization {
            try await diarizationService.ensureModelsReady { update in
                await onProgress(self.scale(update, into: 0.62...1.0))
            }
        }
    }

    private func deleteAudioArtifacts(for session: SessionManifest, in sessionDir: URL) async throws {
        let fileManager = FileManager.default
        var fileNames: [String] = []
        for candidate in [session.microphoneStemFileName, session.systemAudioStemFileName, session.audioFileName].compactMap({ $0 }) {
            if !fileNames.contains(candidate) {
                fileNames.append(candidate)
            }
        }

        for fileName in fileNames {
            let fileURL = sessionDir.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                throw LorreError.persistenceFailed("The transcript was saved, but Lorre could not delete \(fileName).")
            }
        }
    }

    private func updateSession(
        _ session: inout SessionManifest,
        status: SessionStatus,
        phase: ProcessingPhase,
        label: String,
        fraction: Double
    ) async throws {
        let now = Date()
        session.status = status
        session.updatedAt = now
        session.processing = ProcessingSummary(
            queuedAt: session.processing.queuedAt ?? now,
            startedAt: session.processing.startedAt ?? now,
            completedAt: nil,
            progressPhase: phase,
            progressLabel: label,
            progressFraction: fraction
        )
        try await store.updateSession(session)
    }

    private func writeDiarizationDebugArtifact(
        sessionId: UUID,
        sourceEngine: String,
        transcription: TranscriptionResult,
        diarization: DiarizationResult?,
        transcript: TranscriptDocument,
        expectedSpeakers: DiarizationSpeakerCountHint
    ) async throws {
        let sessionDir = await store.sessionDirectoryURL(for: sessionId)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let fileURL = sessionDir.appendingPathComponent("diarization-debug.json")

        let payload = DiarizationDebugArtifact(
            generatedAt: Date(),
            sessionId: sessionId,
            sourceEngine: sourceEngine,
            expectedSpeakers: expectedSpeakers.normalized(),
            transcriptionUtterances: transcription.utterances.map(DiarizationDebugArtifact.TranscriptionUtterancePayload.init),
            diarizationSpans: (diarization?.spans ?? []).map(DiarizationDebugArtifact.DiarizationSpanPayload.init),
            transcriptSegments: transcript.segments.map(DiarizationDebugArtifact.TranscriptSegmentPayload.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private func scale(_ update: ProcessingUpdate, into range: ClosedRange<Double>) -> ProcessingUpdate {
        let localFraction = min(max(update.fraction ?? 0, 0), 1)
        let scaledFraction = range.lowerBound + ((range.upperBound - range.lowerBound) * localFraction)
        return ProcessingUpdate(
            phase: update.phase,
            component: update.component,
            label: update.label,
            detail: update.detail,
            fraction: scaledFraction
        )
    }
}

private struct DiarizationDebugArtifact: Encodable {
    let generatedAt: Date
    let sessionId: UUID
    let sourceEngine: String
    let expectedSpeakers: DiarizationSpeakerCountHint
    let transcriptionUtterances: [TranscriptionUtterancePayload]
    let diarizationSpans: [DiarizationSpanPayload]
    let transcriptSegments: [TranscriptSegmentPayload]

    struct TranscriptionTokenPayload: Encodable {
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Double?

        init(_ token: TranscriptionTokenTiming) {
            self.startMs = token.startMs
            self.endMs = token.endMs
            self.text = token.text
            self.confidence = token.confidence
        }
    }

    struct TranscriptionUtterancePayload: Encodable {
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Double?
        let tokenTimings: [TranscriptionTokenPayload]

        init(_ utterance: TranscriptionUtterance) {
            self.startMs = utterance.startMs
            self.endMs = utterance.endMs
            self.text = utterance.text
            self.confidence = utterance.confidence
            self.tokenTimings = (utterance.tokenTimings ?? []).map(TranscriptionTokenPayload.init)
        }
    }

    struct DiarizationSpanPayload: Encodable {
        let startMs: Int
        let endMs: Int
        let speakerId: String
        let sourceSpeakerId: String?

        init(_ span: DiarizationSpan) {
            self.startMs = span.startMs
            self.endMs = span.endMs
            self.speakerId = span.speakerId
            self.sourceSpeakerId = span.sourceSpeakerId
        }
    }

    struct TranscriptSegmentPayload: Encodable {
        let startMs: Int
        let endMs: Int
        let text: String
        let speakerId: String?
        let sourceSpeakerId: String?
        let confidence: Double?

        init(_ segment: TranscriptSegment) {
            self.startMs = segment.startMs
            self.endMs = segment.endMs
            self.text = segment.text
            self.speakerId = segment.speakerId
            self.sourceSpeakerId = segment.sourceSpeakerId
            self.confidence = segment.confidence
        }
    }
}
