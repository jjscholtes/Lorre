import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

enum FluidAudioIntegrationProbe {
    static var isAvailable: Bool {
        #if canImport(FluidAudio)
        true
        #else
        false
        #endif
    }

    static var statusSummary: String {
        #if canImport(FluidAudio)
        if runtimeCapabilities.supportsTextNormalization {
            return "FluidAudio available (ASR + VAD + diarization + ITN enabled)"
        }
        return "FluidAudio available (ASR + VAD + diarization enabled; \(TextNormalizationRuntimeSupport.runtimeSummary.lowercased()))"
        #else
        return "FluidAudio adapter seam ready (package not linked in this prototype build)"
        #endif
    }

    static var runtimeCapabilities: RuntimeCapabilities {
        #if canImport(FluidAudio)
        let textNormalizationState = TextNormalizationRuntimeSupport.runtimeState
        return RuntimeCapabilities(
            pipeline: .fluidAudio,
            supportsSpeechToText: true,
            supportsVoiceActivityDetection: true,
            supportsSpeakerDiarization: true,
            supportsSpeakerEnrollment: true,
            supportsLivePreview: true,
            supportsTextNormalization: textNormalizationState.isNativeAvailable,
            supportsVocabularyBoosting: true,
            supportsCohereQualityPass: true
        )
        #else
        return .mock
        #endif
    }

    #if canImport(FluidAudio)
    static func referencedTypes() -> [Any.Type] {
        [
            AsrManager.self,
            VadManager.self,
            OfflineDiarizerManager.self,
            SortformerDiarizer.self,
            LSEENDDiarizer.self
        ]
    }
    #endif
}

#if canImport(FluidAudio)
actor FluidAudioTranscriptionService: TranscriptionService {
    private final class AsrManagerBox: @unchecked Sendable {
        let manager: AsrManager

        init(manager: AsrManager) {
            self.manager = manager
        }

        func transcribe(_ url: URL, language: Language?) async throws -> ASRResult {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(url, decoderState: &decoderState, language: language)
        }
    }

    private final class VadManagerBox: @unchecked Sendable {
        let manager: VadManager

        init(manager: VadManager) {
            self.manager = manager
        }

        func segmentSpeechWindows(
            _ samples: [Float],
            config: VadSegmentationConfig
        ) async throws -> [(start: Double, end: Double)] {
            let segments = try await manager.segmentSpeech(samples, config: config)
            return segments.map { segment in
                (start: Double(segment.startTime), end: Double(segment.endTime))
            }
        }
    }

    private struct SpeechWindow: Sendable {
        var start: Double
        var end: Double
    }

    private var managerBox: AsrManagerBox?
    private var vadManagerBox: VadManagerBox?
    private var initialized = false
    private var vocabularyBoostingConfiguration = VocabularyBoostingConfiguration()
    private var batchTranscriptionConfiguration = BatchTranscriptionConfiguration()

    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        if initialized {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .asr,
                        label: "ASR + VAD ready",
                        detail: "Transcription models are already prepared."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .asr,
                    label: "Preparing ASR models",
                    detail: "Checking ASR cache and download registry…",
                    fraction: 0.01
                )
            )
        }

        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: { progress in
                guard let onProgress else { return }
                let update = FluidAudioProgressSupport.makeUpdate(
                    phase: .preparing,
                    component: .asr,
                    label: "Preparing ASR models",
                    progress: progress
                )
                let scaled = FluidAudioProgressSupport.scale(update, into: 0.0...0.78)
                Task {
                    await onProgress(scaled)
                }
            }
        )
        let manager = AsrManager(
            config: ASRConfig(
                parallelChunkConcurrency: batchTranscriptionConfiguration.parallelChunkConcurrency,
                streamingEnabled: true
            )
        )
        try await manager.loadModels(models)
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .vad,
                    label: "Preparing VAD model",
                    detail: "ASR ready. Loading voice-activity detector…",
                    fraction: 0.80
                )
            )
        }
        let vadManager = try await VadManager(
            progressHandler: { progress in
                guard let onProgress else { return }
                let update = FluidAudioProgressSupport.makeUpdate(
                    phase: .preparing,
                    component: .vad,
                    label: "Preparing VAD model",
                    progress: progress
                )
                let scaled = FluidAudioProgressSupport.scale(update, into: 0.78...1.0)
                Task {
                    await onProgress(scaled)
                }
            }
        )

        self.managerBox = AsrManagerBox(manager: manager)
        self.vadManagerBox = VadManagerBox(manager: vadManager)
        self.initialized = true
    }

    func setVocabularyBoostingConfiguration(_ configuration: VocabularyBoostingConfiguration) async {
        vocabularyBoostingConfiguration = configuration
    }

    func setBatchTranscriptionConfiguration(_ configuration: BatchTranscriptionConfiguration) async {
        let normalized = configuration.normalized
        let concurrencyChanged = normalized.parallelChunkConcurrency != batchTranscriptionConfiguration.parallelChunkConcurrency
        batchTranscriptionConfiguration = normalized
        if concurrencyChanged {
            managerBox = nil
            initialized = false
        }
    }

    func transcribe(url: URL, sessionTitle: String, source: RecordingSource) async throws -> TranscriptionResult {
        try await ensureModelsReady(onProgress: nil)
        guard let managerBox else {
            throw LorreError.processingFailed("ASR manager is not initialized.")
        }

        _ = sessionTitle
        _ = source
        var result = try await managerBox.transcribe(
            url,
            language: parakeetLanguage(for: batchTranscriptionConfiguration.languageCode)
        )
        result = await applyVocabularyBoostingIfNeeded(to: result, audioURL: url)
        let speechWindows = await loadSpeechWindowsIfAvailable(from: url)
        let utterances = buildUtterances(from: result, speechWindows: speechWindows)
        let alternatives = await makeAlternativesIfNeeded(for: url)
        let languageCode = batchTranscriptionConfiguration.languageCode
        let engineName = result.ctcAppliedTerms?.isEmpty == false
            ? "FluidAudio-AsrManager-v3+Vocabulary"
            : "FluidAudio-AsrManager-v3"

        if !utterances.isEmpty {
            return TranscriptionResult(
                engineName: engineName,
                utterances: utterances,
                languageCode: languageCode,
                alternatives: alternatives
            )
        }

        let trimmed = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let fallbackText = trimmed.isEmpty ? "No speech detected." : trimmed
        return TranscriptionResult(
            engineName: engineName,
            utterances: [
                TranscriptionUtterance(startMs: 0, endMs: 1000, text: fallbackText, confidence: nil)
            ],
            languageCode: languageCode,
            alternatives: alternatives
        )
    }

    private func applyVocabularyBoostingIfNeeded(to result: ASRResult, audioURL: URL) async -> ASRResult {
        guard vocabularyBoostingConfiguration.isEnabled else { return result }
        let terms = vocabularyBoostingConfiguration.runtimeSimpleFormatTerms
        guard !terms.isEmpty else { return result }
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else { return result }

        do {
            let vocabURL = try writeRuntimeVocabularyFile(terms)
            let (customVocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabURL.path)
            guard !customVocab.terms.isEmpty else { return result }

            let samples = try AudioConverter().resampleAudioFile(audioURL)
            let blankId = ctcModels.vocabulary.count
            let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: customVocab,
                minScore: nil
            )
            guard !spotResult.logProbs.isEmpty else { return result }

            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: customVocab,
                config: .default,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
            )
            let output = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs,
                frameDuration: spotResult.frameDuration
            )
            guard output.wasModified else { return result }
            let applied = output.replacements
                .filter(\.shouldReplace)
                .compactMap(\.replacementWord)
            let detected = spotResult.detections.map(\.term.text)
            return result.withRescoring(text: output.text, detected: detected, applied: applied)
        } catch {
            return result
        }
    }

    private func writeRuntimeVocabularyFile(_ terms: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lorre", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("custom-vocabulary.txt")
        try terms.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeAlternativesIfNeeded(for url: URL) async -> [TranscriptAlternative] {
        guard batchTranscriptionConfiguration.mode == .parakeetV3WithCohereQualityPass else {
            return []
        }
        guard let language = cohereLanguage(for: batchTranscriptionConfiguration.languageCode) else {
            return []
        }
        guard #available(macOS 14, iOS 17, *) else {
            return []
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let modelDir = try await ensureCohereModelDirectory()
            let models = try await CoherePipeline.loadModels(
                encoderDir: modelDir,
                decoderDir: modelDir,
                vocabDir: modelDir,
                decoderVariant: .v2
            )
            let result = try await CoherePipeline().transcribeLong(
                audio: samples,
                models: models,
                language: language
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                TranscriptAlternative(
                    engineName: "FluidAudio-CohereTranscribe-v2",
                    languageCode: language.rawValue,
                    text: text,
                    processingSeconds: result.totalSeconds
                )
            ]
        } catch {
            return []
        }
    }

    private func ensureCohereModelDirectory() async throws -> URL {
        let modelsBaseDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(.cohereTranscribeCoreml, to: modelsBaseDirectory)
        return modelsBaseDirectory.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    private func parakeetLanguage(for languageCode: String) -> Language? {
        switch BatchTranscriptionConfiguration.normalizedLanguageCode(languageCode) {
        case "en": return .english
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        case "it": return .italian
        case "pt": return .portuguese
        case "pl": return .polish
        default: return nil
        }
    }

    private func cohereLanguage(for languageCode: String) -> CohereAsrConfig.Language? {
        switch BatchTranscriptionConfiguration.normalizedLanguageCode(languageCode) {
        case "en": return .english
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        case "it": return .italian
        case "pt": return .portuguese
        case "nl": return .dutch
        case "pl": return .polish
        default: return nil
        }
    }

    private func loadSpeechWindowsIfAvailable(from url: URL) async -> [SpeechWindow]? {
        guard let vadManagerBox else { return nil }

        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let config = VadSegmentationConfig(
                minSpeechDuration: 0.18,
                minSilenceDuration: 0.38,
                maxSpeechDuration: 12.0,
                speechPadding: 0.08
            )
            let segments = try await vadManagerBox.segmentSpeechWindows(samples, config: config)
            let windows = segments.compactMap { segment -> SpeechWindow? in
                let start = max(0.0, segment.start)
                let end = max(start, segment.end)
                guard end > start else { return nil }
                return SpeechWindow(start: start, end: end)
            }
            return windows.isEmpty ? nil : windows
        } catch {
            // Fall back to token-gap segmentation if VAD model load/inference fails.
            return nil
        }
    }

    private func buildUtterances(from result: ASRResult, speechWindows: [SpeechWindow]?) -> [TranscriptionUtterance] {
        let tokenTimings = result.tokenTimings ?? []
        if tokenTimings.isEmpty {
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                TranscriptionUtterance(
                    startMs: 0,
                    endMs: 1000,
                    text: text,
                    confidence: Double(result.confidence),
                    tokenTimings: nil
                )
            ]
        }

        var utterances: [TranscriptionUtterance] = []
        var bufferText = ""
        var bufferStart: Double?
        var bufferEnd: Double?
        var bufferSpeechWindowIndex: Int?
        var confidences: [Float] = []
        var bufferTokenTimings: [TranscriptionTokenTiming] = []
        let gapThreshold: Double = (speechWindows?.isEmpty == false) ? 0.55 : 0.8
        let maxSegmentDuration: Double = 8.5
        let tokenWindowIndices: [Int?] = {
            guard let speechWindows, !speechWindows.isEmpty else {
                return Array(repeating: nil, count: tokenTimings.count)
            }
            return tokenTimings.map { token in
                speechWindowIndex(
                    forTokenStart: token.startTime,
                    end: token.endTime,
                    speechWindows: speechWindows
                )
            }
        }()

        func flush() {
            let text = bufferText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard var start = bufferStart, var end = bufferEnd, !text.isEmpty else {
                bufferText = ""
                bufferStart = nil
                bufferEnd = nil
                bufferSpeechWindowIndex = nil
                confidences.removeAll(keepingCapacity: true)
                bufferTokenTimings.removeAll(keepingCapacity: true)
                return
            }

            if let speechWindows,
               let bufferSpeechWindowIndex,
               speechWindows.indices.contains(bufferSpeechWindowIndex) {
                let window = speechWindows[bufferSpeechWindowIndex]
                start = max(start, window.start)
                end = min(end, window.end)
            }

            guard end > start else {
                bufferText = ""
                bufferStart = nil
                bufferEnd = nil
                bufferSpeechWindowIndex = nil
                confidences.removeAll(keepingCapacity: true)
                bufferTokenTimings.removeAll(keepingCapacity: true)
                return
            }

            let meanConfidence: Double?
            if confidences.isEmpty {
                meanConfidence = nil
            } else {
                meanConfidence = Double(confidences.reduce(0, +)) / Double(confidences.count)
            }

            let utteranceStartMs = max(0, Int(start * 1000))
            let utteranceEndMs = max(utteranceStartMs + 1, Int(end * 1000))
            let clippedTokenTimings = bufferTokenTimings.compactMap { token -> TranscriptionTokenTiming? in
                let clippedStart = max(utteranceStartMs, token.startMs)
                let clippedEnd = min(utteranceEndMs, token.endMs)
                guard clippedEnd > clippedStart else { return nil }
                return TranscriptionTokenTiming(
                    startMs: clippedStart,
                    endMs: clippedEnd,
                    text: token.text,
                    confidence: token.confidence
                )
            }

            utterances.append(
                TranscriptionUtterance(
                    startMs: utteranceStartMs,
                    endMs: utteranceEndMs,
                    text: text,
                    confidence: meanConfidence,
                    tokenTimings: clippedTokenTimings.isEmpty ? nil : clippedTokenTimings
                )
            )
            bufferText = ""
            bufferStart = nil
            bufferEnd = nil
            bufferSpeechWindowIndex = nil
            confidences.removeAll(keepingCapacity: true)
            bufferTokenTimings.removeAll(keepingCapacity: true)
        }

        for (index, token) in tokenTimings.enumerated() {
            if bufferStart == nil {
                bufferStart = token.startTime
            }
            bufferEnd = token.endTime
            if bufferSpeechWindowIndex == nil {
                bufferSpeechWindowIndex = tokenWindowIndices[index]
            }
            bufferText += token.token
            confidences.append(token.confidence)
            let tokenStartMs = max(0, Int((token.startTime * 1000).rounded()))
            let tokenEndMs = max(tokenStartMs + 1, Int((token.endTime * 1000).rounded()))
            bufferTokenTimings.append(
                TranscriptionTokenTiming(
                    startMs: tokenStartMs,
                    endMs: tokenEndMs,
                    text: token.token,
                    confidence: Double(token.confidence)
                )
            )

            let next = tokenTimings.indices.contains(index + 1) ? tokenTimings[index + 1] : nil
            let gapToNext: Double = next.map { max(0.0, $0.startTime - token.endTime) } ?? 0
            let currentDuration = (bufferEnd ?? token.endTime) - (bufferStart ?? token.startTime)
            let punctuationBoundary = token.token.contains(".") || token.token.contains("!") || token.token.contains("?")
            let largeGapBoundary = gapToNext >= gapThreshold
            let durationBoundary = currentDuration >= maxSegmentDuration && punctuationBoundary
            let speechWindowBoundary = index < tokenTimings.count - 1 && tokenWindowIndices[index] != tokenWindowIndices[index + 1]
            let finalToken = index == tokenTimings.count - 1
            let intraWordContinuationBoundary = next.map { nextToken in
                looksLikeIntraWordContinuation(currentToken: token.token, nextToken: nextToken.token)
            } ?? false

            let shouldFlush =
                finalToken ||
                ((speechWindowBoundary || largeGapBoundary || durationBoundary) && !intraWordContinuationBoundary)

            if shouldFlush {
                flush()
            }
        }

        if utterances.isEmpty {
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return normalizePunctuationArtifacts(in: [
                TranscriptionUtterance(
                    startMs: 0,
                    endMs: max(1, Int((tokenTimings.last?.endTime ?? 1) * 1000)),
                    text: text,
                    confidence: Double(result.confidence),
                    tokenTimings: nil
                )
            ])
        }

        return normalizePunctuationArtifacts(in: utterances)
    }

    private func normalizePunctuationArtifacts(in utterances: [TranscriptionUtterance]) -> [TranscriptionUtterance] {
        guard !utterances.isEmpty else { return [] }

        var normalized: [TranscriptionUtterance] = []
        normalized.reserveCapacity(utterances.count)

        for var utterance in utterances {
            utterance.text = collapseEdgeWhitespace(in: utterance.text)
            let trimmed = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let (prefixPunctuation, remainderText) = splitLeadingPunctuationPrefix(from: utterance.text),
               !normalized.isEmpty {
                var previous = normalized.removeLast()
                previous.text = appendPunctuation(prefixPunctuation, to: previous.text)
                previous.endMs = max(previous.endMs, utterance.startMs)
                normalized.append(previous)
                utterance.text = remainderText
            }

            let currentTrimmed = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentTrimmed.isEmpty else { continue }

            if isPunctuationOnlyToken(currentTrimmed), !normalized.isEmpty {
                var previous = normalized.removeLast()
                previous.text = appendPunctuation(currentTrimmed, to: previous.text)
                previous.endMs = max(previous.endMs, utterance.endMs)
                previous.confidence = mergedConfidence(previous.confidence, utterance.confidence)
                normalized.append(previous)
                continue
            }

            utterance.text = currentTrimmed
            normalized.append(utterance)
        }

        // If the first row was punctuation-only and couldn't be merged initially, attach it to the next row.
        if normalized.count >= 2,
           let first = normalized.first,
           isPunctuationOnlyToken(first.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            var rows = normalized
            let punctuation = rows.removeFirst().text.trimmingCharacters(in: .whitespacesAndNewlines)
            var next = rows.removeFirst()
            next.text = "\(punctuation) \(next.text)".trimmingCharacters(in: .whitespacesAndNewlines)
            next.startMs = min(first.startMs, next.startMs)
            next.confidence = mergedConfidence(first.confidence, next.confidence)
            rows.insert(next, at: 0)
            return rows
        }

        return normalized
    }

    private func splitLeadingPunctuationPrefix(from text: String) -> (String, String)? {
        let trimmedLeading = text.drop(while: { $0.isWhitespace })
        guard !trimmedLeading.isEmpty else { return nil }

        let punctuationSet = CharacterSet(charactersIn: ".,!?;:…")
        var prefixEnd = trimmedLeading.startIndex
        while prefixEnd < trimmedLeading.endIndex,
              let scalar = trimmedLeading[prefixEnd].unicodeScalars.first,
              punctuationSet.contains(scalar) {
            prefixEnd = trimmedLeading.index(after: prefixEnd)
        }

        guard prefixEnd > trimmedLeading.startIndex else { return nil }

        let prefix = String(trimmedLeading[..<prefixEnd])
        let remainder = String(trimmedLeading[prefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        return (prefix, remainder)
    }

    private func isPunctuationOnlyToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var hasPunctuation = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                return false
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                hasPunctuation = true
            }
        }
        return hasPunctuation
    }

    private func appendPunctuation(_ punctuation: String, to text: String) -> String {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPunctuation = punctuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPunctuation.isEmpty else { return cleanedText }
        if cleanedText.isEmpty { return cleanedPunctuation }
        return cleanedText + cleanedPunctuation
    }

    private func mergedConfidence(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return (l + r) / 2
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }

    private func collapseEdgeWhitespace(in text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeIntraWordContinuation(currentToken: String, nextToken: String) -> Bool {
        guard let currentLast = currentToken.last,
              let nextFirst = nextToken.first else { return false }

        if nextFirst.isWhitespace { return false }
        if !currentLast.isLetter && !currentLast.isNumber { return false }
        if !nextFirst.isLetter && !nextFirst.isNumber { return false }

        // Typical artifact: "Do" + "ordat" split by timing/VAD boundary.
        // If the next token starts lowercase without a leading space, treat it as same-word continuation.
        if nextFirst.isLetter, nextFirst.isLowercase {
            return true
        }

        return false
    }

    private func speechWindowIndex(
        forTokenStart start: Double,
        end: Double,
        speechWindows: [SpeechWindow]
    ) -> Int? {
        guard !speechWindows.isEmpty else { return nil }
        let midpoint = (start + end) / 2

        if let midpointMatch = speechWindows.firstIndex(where: { midpoint >= $0.start && midpoint <= $0.end }) {
            return midpointMatch
        }

        var bestIndex: Int?
        var bestOverlap: Double = 0
        for (index, window) in speechWindows.enumerated() {
            let overlap = min(end, window.end) - max(start, window.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = index
            }
        }
        return bestOverlap > 0 ? bestIndex : nil
    }
}

actor FluidAudioDiarizationService: SpeakerDiarizationService {
    static let qualityTunedEmbeddingSkipThreshold: Float = 0.95

    private final class OfflineDiarizerManagerBox: @unchecked Sendable {
        let manager: OfflineDiarizerManager

        init(manager: OfflineDiarizerManager) {
            self.manager = manager
        }

        func diarizeSpans(
            audio: [Float],
            progressCallback: (@Sendable (Int, Int) -> Void)? = nil
        ) async throws -> [(start: Double, end: Double, speakerId: String)] {
            let result = try await manager.process(audio: audio, progressCallback: progressCallback)
            return result.segments.map { segment in
                (
                    start: Double(segment.startTimeSeconds),
                    end: Double(segment.endTimeSeconds),
                    speakerId: segment.speakerId
                )
            }
        }

        func diarizeSpans(
            url: URL,
            progressCallback: (@Sendable (Int, Int) -> Void)? = nil
        ) async throws -> [(start: Double, end: Double, speakerId: String)] {
            let result = try await manager.process(url, progressCallback: progressCallback)
            return result.segments.map { segment in
                (
                    start: Double(segment.startTimeSeconds),
                    end: Double(segment.endTimeSeconds),
                    speakerId: segment.speakerId
                )
            }
        }
    }

    private final class AsyncProgressDispatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []

        func submit(
            _ update: ProcessingUpdate,
            to onProgress: @escaping @Sendable (ProcessingUpdate) async -> Void
        ) {
            let task = Task {
                await onProgress(update)
            }
            lock.lock()
            tasks.append(task)
            lock.unlock()
        }

        func drain() async {
            let pendingTasks = takePendingTasks()
            for task in pendingTasks {
                await task.value
            }
        }

        private func takePendingTasks() -> [Task<Void, Never>] {
            lock.lock()
            defer { lock.unlock() }
            let pendingTasks = tasks
            tasks.removeAll()
            return pendingTasks
        }
    }

    private let enrollmentService: any SpeakerEnrollmentService
    private var diarizationEngine: DiarizationEngine = .offlineVbx
    private var offlineManagerBox: OfflineDiarizerManagerBox?
    private var offlinePreparedSpeakerHint: DiarizationSpeakerCountHint = .auto
    private var sortformerModels: SortformerModels?
    private var sortformerDiarizer: SortformerDiarizer?
    private var lsEendModel: LSEENDModel?
    private var lsEendDiarizer: LSEENDDiarizer?
    private var knownSpeakers: [KnownSpeaker] = []
    private let representativeAudioLimitSeconds: Double = 10.0
    private let knownSpeakerMatchThreshold: Float = 0.36
    private static let diarizationInputSampleRate = 16_000.0
    private static let sortformerConfig = SortformerConfig.balancedV2_1

    init(enrollmentService: any SpeakerEnrollmentService) {
        self.enrollmentService = enrollmentService
    }

    static func makeQualityTunedConfig(expectedSpeakers: DiarizationSpeakerCountHint) -> OfflineDiarizerConfig {
        // Favor transcript readability over ultra-fine turn segmentation. The default config can
        // over-fragment one person into several short clusters, which then chops sentences apart.
        var config = OfflineDiarizerConfig.default.withSpeakers(min: 1, max: 8)
        let normalizedHint = expectedSpeakers.normalized()
        switch normalizedHint.mode {
        case .auto:
            break
        case .exact:
            if let exact = normalizedHint.exactCount {
                config = config.withSpeakers(exactly: exact)
            }
        case .range:
            config = config.withSpeakers(min: normalizedHint.minCount, max: normalizedHint.maxCount)
        }
        config.segmentationStepRatio = 0.1
        // At this overlap, neighboring segmentation windows are often redundant enough to reuse
        // embeddings without sacrificing transcript-level speaker readability.
        config.embeddingSkipStrategy = .maskSimilarity(threshold: qualityTunedEmbeddingSkipThreshold)
        config.minSegmentDuration = 0.45
        // Slightly lower the clustering threshold so one speaker is less likely to be split into
        // multiple synthetic speaker IDs across neighboring sentences.
        config.clusteringThreshold = 0.54
        // Stitch brief pauses back together so sentence-level rows stay intact more often.
        config.minGapDuration = 0.18
        return config
    }

    private func qualityTunedConfig(expectedSpeakers: DiarizationSpeakerCountHint) -> OfflineDiarizerConfig {
        Self.makeQualityTunedConfig(expectedSpeakers: expectedSpeakers)
    }

    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        switch diarizationEngine {
        case .offlineVbx:
            try await ensureOfflineModelsReady(expectedSpeakers: .auto, onProgress: onProgress)
        case .sortformer:
            try await ensureSortformerPrepared(onProgress: onProgress)
        case .lsEend:
            try await ensureLSEENDPrepared(onProgress: onProgress)
        }
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        knownSpeakers = speakers.sorted { $0.id < $1.id }
    }

    func setDiarizationEngine(_ engine: DiarizationEngine) async {
        diarizationEngine = engine
    }

    private func ensureOfflineModelsReady(
        expectedSpeakers: DiarizationSpeakerCountHint,
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        let normalizedHint = expectedSpeakers.normalized()
        if offlineManagerBox != nil, normalizedHint == offlinePreparedSpeakerHint {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .diarization,
                        label: "Diarization ready",
                        detail: "Offline diarization models are already prepared."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Preparing diarization models",
                    detail: "Checking offline speaker models…",
                    fraction: 0.01
                )
            )
        }

        let manager = OfflineDiarizerManager(config: qualityTunedConfig(expectedSpeakers: normalizedHint))
        let models = try await OfflineDiarizerModels.load(
            progressHandler: { progress in
                guard let onProgress else { return }
                let update = FluidAudioProgressSupport.makeUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Preparing diarization models",
                    progress: progress
                )
                let scaled = FluidAudioProgressSupport.scale(update, into: 0.0...0.94)
                Task {
                    await onProgress(scaled)
                }
            }
        )
        manager.initialize(models: models)
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Warming diarization models",
                    detail: "Running an initial speaker pass to reduce first-use latency…",
                    fraction: 0.97
                )
            )
        }
        do {
            _ = try await manager.process(audio: Array(repeating: 0, count: 32_000))
        } catch OfflineDiarizationError.noSpeechDetected {
            // Expected for silence-only warmup audio; the model graph has still been exercised.
        } catch {
            throw error
        }
        self.offlineManagerBox = OfflineDiarizerManagerBox(manager: manager)
        self.offlinePreparedSpeakerHint = normalizedHint
        if let onProgress {
            await onProgress(
                FluidAudioProgressSupport.readyUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Diarization ready",
                    detail: "Offline speaker models are warmed and ready."
                )
            )
        }
    }

    private func ensureSortformerPrepared(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        if sortformerDiarizer != nil {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .diarization,
                        label: "Diarization ready",
                        detail: "Sortformer diarization is already prepared."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Preparing diarization models",
                    detail: "Checking Sortformer diarization models…",
                    fraction: 0.01
                )
            )
        }

        if sortformerModels == nil {
            sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: Self.sortformerConfig,
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .diarization,
                        label: "Preparing diarization models",
                        progress: progress
                    )
                    Task {
                        await onProgress(update)
                    }
                }
            )
        }

        guard let sortformerModels else {
            throw LorreError.processingFailed("Sortformer diarization models are unavailable.")
        }

        let diarizer = SortformerDiarizer(config: Self.sortformerConfig)
        diarizer.initialize(models: sortformerModels)
        sortformerDiarizer = diarizer

        if let onProgress {
            await onProgress(
                FluidAudioProgressSupport.readyUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Diarization ready",
                    detail: "Sortformer diarization models are loaded."
                )
            )
        }
    }

    private func ensureLSEENDPrepared(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        if lsEendDiarizer != nil {
            if let onProgress {
                await onProgress(
                    FluidAudioProgressSupport.readyUpdate(
                        phase: .preparing,
                        component: .diarization,
                        label: "Diarization ready",
                        detail: "LS-EEND diarization is already prepared."
                    )
                )
            }
            return
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Preparing diarization models",
                    detail: "Checking LS-EEND diarization models…",
                    fraction: 0.01
                )
            )
        }

        if lsEendModel == nil {
            lsEendModel = try await LSEENDModel.loadFromHuggingFace(
                variant: .dihard3,
                progressHandler: { progress in
                    guard let onProgress else { return }
                    let update = FluidAudioProgressSupport.makeUpdate(
                        phase: .preparing,
                        component: .diarization,
                        label: "Preparing diarization models",
                        progress: progress
                    )
                    Task {
                        await onProgress(update)
                    }
                }
            )
        }

        guard let lsEendModel else {
            throw LorreError.processingFailed("LS-EEND diarization models are unavailable.")
        }

        let diarizer = LSEENDDiarizer()
        try diarizer.initialize(model: lsEendModel)
        lsEendDiarizer = diarizer

        if let onProgress {
            await onProgress(
                FluidAudioProgressSupport.readyUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Diarization ready",
                    detail: "LS-EEND diarization models are loaded."
                )
            )
        }
    }

    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint,
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws -> DiarizationResult? {
        _ = expectedDurationSeconds
        let spans: [DiarizationSpan]
        let audioData: [Float]?
        let engineLabel: String
        switch diarizationEngine {
        case .offlineVbx:
            engineLabel = "offline VBx"
            spans = try await diarizeOffline(url: url, expectedSpeakers: expectedSpeakers, onProgress: onProgress)
            audioData = knownSpeakers.isEmpty ? nil : try AudioConverter().resampleAudioFile(url)
        case .sortformer:
            engineLabel = "Sortformer"
            let loadedAudioData = try AudioConverter().resampleAudioFile(url)
            spans = try await diarizeSortformer(audioData: loadedAudioData, onProgress: onProgress)
            audioData = loadedAudioData
        case .lsEend:
            engineLabel = "LS-EEND"
            let loadedAudioData = try AudioConverter().resampleAudioFile(url)
            spans = try await diarizeLSEEND(audioData: loadedAudioData, onProgress: onProgress)
            audioData = loadedAudioData
        }

        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .diarizing,
                    component: .diarization,
                    label: "Finished \(engineLabel) diarization",
                    detail: "Found \(spans.count) speaker span\(spans.count == 1 ? "" : "s").",
                    fraction: knownSpeakers.isEmpty ? 1.0 : 0.88
                )
            )
        }
        guard !spans.isEmpty else { return nil }
        guard let audioData else {
            return DiarizationResult(spans: spans, speakerProfiles: [])
        }

        if let onProgress, !knownSpeakers.isEmpty {
            await onProgress(
                ProcessingUpdate(
                    phase: .diarizing,
                    component: .diarization,
                    label: "Matching known speakers",
                    detail: "Comparing diarized speaker spans with saved speaker profiles.",
                    fraction: 0.92
                )
            )
        }
        let relabeled = try await relabelKnownSpeakers(in: spans, audioData: audioData)
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .diarizing,
                    component: .diarization,
                    label: "Speaker assignment complete",
                    detail: "Speaker labels are ready for transcript assembly.",
                    fraction: 1.0
                )
            )
        }
        return DiarizationResult(spans: relabeled.spans, speakerProfiles: relabeled.profiles)
    }

    private func diarizeOffline(
        url: URL,
        expectedSpeakers: DiarizationSpeakerCountHint,
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws -> [DiarizationSpan] {
        try await ensureOfflineModelsReady(expectedSpeakers: expectedSpeakers, onProgress: nil)
        guard let offlineManagerBox else {
            throw LorreError.processingFailed("Offline diarizer is not initialized.")
        }

        let progressDispatcher = AsyncProgressDispatcher()
        let diarizedSpans: [(start: Double, end: Double, speakerId: String)]
        do {
            diarizedSpans = try await offlineManagerBox.diarizeSpans(
                url: url,
                progressCallback: { processedChunks, totalChunks in
                    guard let onProgress else { return }
                    let update = Self.chunkProgressUpdate(
                        engine: "offline VBx",
                        processedChunks: processedChunks,
                        totalChunks: totalChunks
                    )
                    progressDispatcher.submit(update, to: onProgress)
                }
            )
        } catch {
            await progressDispatcher.drain()
            throw error
        }
        await progressDispatcher.drain()

        return diarizedSpans.compactMap { segment -> DiarizationSpan? in
            let start = segment.start
            let end = segment.end
            guard end > start else { return nil }
            let startMs = max(0, Int(start * 1000))
            let endMs = max(startMs + 1, Int(end * 1000))
            guard endMs > startMs else { return nil }
            let sourceSpeakerID = normalizedClusterLabel(from: segment.speakerId)
            return DiarizationSpan(
                startMs: startMs,
                endMs: endMs,
                speakerId: sourceSpeakerID,
                sourceSpeakerId: sourceSpeakerID
            )
        }
    }

    private func diarizeSortformer(
        audioData: [Float],
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws -> [DiarizationSpan] {
        try await ensureSortformerPrepared(onProgress: nil)
        guard let sortformerDiarizer else {
            throw LorreError.processingFailed("Sortformer diarizer is not initialized.")
        }

        sortformerDiarizer.reset()
        let progressDispatcher = AsyncProgressDispatcher()
        let timeline: DiarizerTimeline
        do {
            timeline = try sortformerDiarizer.processComplete(
                audioData,
                sourceSampleRate: Self.diarizationInputSampleRate,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true,
                progressCallback: { processedSamples, totalSamples, chunksProcessed in
                    guard let onProgress else { return }
                    let update = Self.sampleProgressUpdate(
                        engine: "Sortformer",
                        processedSamples: processedSamples,
                        totalSamples: totalSamples,
                        chunksProcessed: chunksProcessed
                    )
                    progressDispatcher.submit(update, to: onProgress)
                }
            )
        } catch {
            await progressDispatcher.drain()
            throw error
        }
        await progressDispatcher.drain()

        return diarizerSpans(from: timeline.speakers.values.flatMap(\.finalizedSegments))
    }

    private func diarizeLSEEND(
        audioData: [Float],
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws -> [DiarizationSpan] {
        try await ensureLSEENDPrepared(onProgress: nil)
        guard let lsEendDiarizer else {
            throw LorreError.processingFailed("LS-EEND diarizer is not initialized.")
        }

        lsEendDiarizer.reset()
        let progressDispatcher = AsyncProgressDispatcher()
        let timeline: DiarizerTimeline
        do {
            timeline = try lsEendDiarizer.processComplete(
                audioData,
                sourceSampleRate: Self.diarizationInputSampleRate,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true,
                progressCallback: { processedSamples, totalSamples, chunksProcessed in
                    guard let onProgress else { return }
                    let update = Self.sampleProgressUpdate(
                        engine: "LS-EEND",
                        processedSamples: processedSamples,
                        totalSamples: totalSamples,
                        chunksProcessed: chunksProcessed
                    )
                    progressDispatcher.submit(update, to: onProgress)
                }
            )
        } catch {
            await progressDispatcher.drain()
            throw error
        }
        await progressDispatcher.drain()

        return diarizerSpans(from: timeline.speakers.values.flatMap(\.finalizedSegments))
    }

    private static func chunkProgressUpdate(
        engine: String,
        processedChunks: Int,
        totalChunks: Int
    ) -> ProcessingUpdate {
        let safeTotal = max(totalChunks, 1)
        let safeProcessed = min(max(processedChunks, 0), safeTotal)
        return ProcessingUpdate(
            phase: .diarizing,
            component: .diarization,
            label: "Assigning speakers with \(engine)",
            detail: "Processed \(safeProcessed)/\(safeTotal) diarization chunks.",
            fraction: Double(safeProcessed) / Double(safeTotal)
        )
    }

    private static func sampleProgressUpdate(
        engine: String,
        processedSamples: Int,
        totalSamples: Int,
        chunksProcessed: Int
    ) -> ProcessingUpdate {
        let safeTotal = max(totalSamples, 1)
        let safeProcessed = min(max(processedSamples, 0), safeTotal)
        let processedTime = formatDuration(seconds: Double(safeProcessed) / diarizationInputSampleRate)
        let totalTime = formatDuration(seconds: Double(safeTotal) / diarizationInputSampleRate)
        return ProcessingUpdate(
            phase: .diarizing,
            component: .diarization,
            label: "Assigning speakers with \(engine)",
            detail: "Processed \(processedTime) / \(totalTime) across \(max(chunksProcessed, 0)) chunks.",
            fraction: Double(safeProcessed) / Double(safeTotal)
        )
    }

    private static func formatDuration(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func normalizedClusterLabel(from rawSpeakerID: String) -> String {
        let trimmed = rawSpeakerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "UNK" }
        if trimmed.uppercased().hasPrefix("S") { return trimmed.uppercased() }
        if let numeric = Int(trimmed) {
            return "S\(max(1, numeric + 1))"
        }
        return "S\(trimmed)"
    }

    private func diarizerSpans(from segments: [DiarizerSegment]) -> [DiarizationSpan] {
        segments
            .sorted { lhs, rhs in
                if lhs.startFrame == rhs.startFrame {
                    if lhs.endFrame == rhs.endFrame {
                        return lhs.speakerIndex < rhs.speakerIndex
                    }
                    return lhs.endFrame < rhs.endFrame
                }
                return lhs.startFrame < rhs.startFrame
            }
            .compactMap { segment -> DiarizationSpan? in
                let startMs = max(0, Int((Double(segment.startTime) * 1000.0).rounded()))
                let endMs = max(startMs + 1, Int((Double(segment.endTime) * 1000.0).rounded()))
                guard endMs > startMs else { return nil }
                let sourceSpeakerID = "S\(segment.speakerIndex + 1)"
                return DiarizationSpan(
                    startMs: startMs,
                    endMs: endMs,
                    speakerId: sourceSpeakerID,
                    sourceSpeakerId: sourceSpeakerID
                )
            }
    }

    private func relabelKnownSpeakers(
        in spans: [DiarizationSpan],
        audioData: [Float]
    ) async throws -> (spans: [DiarizationSpan], profiles: [SpeakerProfile]) {
        guard !knownSpeakers.isEmpty else { return (spans, []) }

        let grouped = Dictionary(grouping: spans) { $0.sourceSpeakerId ?? $0.speakerId }
        var candidates: [(clusterID: String, speaker: KnownSpeaker, distance: Float)] = []

        for (clusterID, clusterSpans) in grouped {
            guard let embedding = try await representativeEmbedding(
                for: clusterSpans,
                audioData: audioData
            ) else {
                continue
            }

            for knownSpeaker in knownSpeakers {
                let distance = KnownSpeakerSimilarity.cosineDistance(
                    embedding,
                    knownSpeaker.embedding
                )
                if distance <= knownSpeakerMatchThreshold {
                    candidates.append((clusterID: clusterID, speaker: knownSpeaker, distance: distance))
                }
            }
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.distance == rhs.distance {
                return (lhs.clusterID, lhs.speaker.id) < (rhs.clusterID, rhs.speaker.id)
            }
            return lhs.distance < rhs.distance
        }

        var usedClusters = Set<String>()
        var usedSpeakerIDs = Set<String>()
        var assignments: [String: KnownSpeaker] = [:]
        for candidate in sortedCandidates {
            guard !usedClusters.contains(candidate.clusterID) else { continue }
            guard !usedSpeakerIDs.contains(candidate.speaker.id) else { continue }
            assignments[candidate.clusterID] = candidate.speaker
            usedClusters.insert(candidate.clusterID)
            usedSpeakerIDs.insert(candidate.speaker.id)
        }

        let relabeledSpans = spans.map { span -> DiarizationSpan in
            let sourceID = span.sourceSpeakerId ?? span.speakerId
            guard let knownSpeaker = assignments[sourceID] else { return span }
            return DiarizationSpan(
                startMs: span.startMs,
                endMs: span.endMs,
                speakerId: knownSpeaker.id,
                sourceSpeakerId: sourceID
            )
        }

        let profiles = assignments.values
            .sorted { $0.safeDisplayName.localizedCaseInsensitiveCompare($1.safeDisplayName) == .orderedAscending }
            .map(\.speakerProfile)
        return (relabeledSpans, profiles)
    }

    private func representativeEmbedding(
        for spans: [DiarizationSpan],
        audioData: [Float]
    ) async throws -> [Float]? {
        let sorted = spans.sorted {
            let lhsDuration = $0.endMs - $0.startMs
            let rhsDuration = $1.endMs - $1.startMs
            if lhsDuration == rhsDuration {
                return $0.startMs < $1.startMs
            }
            return lhsDuration > rhsDuration
        }

        var selectedSamples: [Float] = []
        let sampleLimit = Int(representativeAudioLimitSeconds * 16_000.0)

        for span in sorted {
            let startIndex = max(0, Int((Double(span.startMs) / 1000.0) * 16_000.0))
            let endIndex = min(audioData.count, Int((Double(span.endMs) / 1000.0) * 16_000.0))
            guard endIndex > startIndex else { continue }
            let slice = Array(audioData[startIndex..<endIndex])
            guard slice.count >= 4_800 else { continue }
            selectedSamples.append(contentsOf: slice)
            if selectedSamples.count >= sampleLimit {
                selectedSamples = Array(selectedSamples.prefix(sampleLimit))
                break
            }
        }

        guard selectedSamples.count >= 16_000 else { return nil }
        return try await enrollmentService.extractEmbedding(from: selectedSamples)
    }
}
#endif
