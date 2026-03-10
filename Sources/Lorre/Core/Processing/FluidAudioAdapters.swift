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
        return "FluidAudio available (ASR + VAD + diarization adapters enabled)"
        #else
        return "FluidAudio adapter seam ready (package not linked in this prototype build)"
        #endif
    }

    #if canImport(FluidAudio)
    static func referencedTypes() -> [Any.Type] {
        [
            AsrManager.self,
            VadManager.self,
            OfflineDiarizerManager.self
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

        func transcribe(_ url: URL, source: AudioSource) async throws -> ASRResult {
            try await manager.transcribe(url, source: source)
        }

        func configureVocabularyBoosting(
            vocabulary: CustomVocabularyContext,
            ctcModels: CtcModels
        ) async throws {
            try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctcModels)
        }

        func disableVocabularyBoosting() {
            manager.disableVocabularyBoosting()
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
    private var ctcModels: CtcModels?
    private var initialized = false
    private var configuredVocabularySignature: String?
    private var vocabularyBoostingConfiguration = VocabularyBoostingConfiguration()

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
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
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

    func transcribe(url: URL, sessionTitle: String) async throws -> TranscriptionResult {
        try await ensureModelsReady(onProgress: nil)
        guard let managerBox else {
            throw LorreError.processingFailed("ASR manager is not initialized.")
        }

        try await configureVocabularyBoostingIfNeeded(sessionTitle: sessionTitle, managerBox: managerBox)
        let result = try await managerBox.transcribe(url, source: .microphone)
        let speechWindows = await loadSpeechWindowsIfAvailable(from: url)
        let utterances = buildUtterances(from: result, speechWindows: speechWindows)

        if !utterances.isEmpty {
            return TranscriptionResult(engineName: "FluidAudio-AsrManager-v3", utterances: utterances)
        }

        let trimmed = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let fallbackText = trimmed.isEmpty ? "No speech detected." : trimmed
        return TranscriptionResult(
            engineName: "FluidAudio-AsrManager-v3",
            utterances: [
                TranscriptionUtterance(startMs: 0, endMs: 1000, text: fallbackText, confidence: nil)
            ]
        )
    }

    private func configureVocabularyBoostingIfNeeded(
        sessionTitle: String,
        managerBox: AsrManagerBox
    ) async throws {
        _ = sessionTitle
        let config = vocabularyBoostingConfiguration
        guard config.isEnabled else {
            if configuredVocabularySignature != nil {
                managerBox.disableVocabularyBoosting()
                configuredVocabularySignature = nil
            }
            return
        }

        guard let context = vocabularyContext(fromSimpleFormat: config.simpleFormatTerms) else {
            if configuredVocabularySignature != nil {
                managerBox.disableVocabularyBoosting()
                configuredVocabularySignature = nil
            }
            return
        }

        let signature = vocabularySignature(for: context)
        guard signature != configuredVocabularySignature else { return }

        if ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        }
        guard let ctcModels else { return }

        try await managerBox.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
        configuredVocabularySignature = signature
    }

    private func vocabularySignature(for context: CustomVocabularyContext) -> String {
        context.terms
            .map { term in
                let aliasPart = (term.aliases ?? []).map { $0.lowercased() }.sorted().joined(separator: ",")
                return "\(term.text.lowercased()):\(aliasPart)"
            }
            .sorted()
            .joined(separator: "|")
    }

    private func vocabularyContext(fromSimpleFormat rawText: String) -> CustomVocabularyContext? {
        let trimmedInput = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        var seen = Set<String>()
        var terms: [CustomVocabularyTerm] = []

        for line in trimmedInput.split(whereSeparator: { $0.isNewline }) {
            let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawLine.isEmpty, !rawLine.hasPrefix("#") else { continue }

            let canonicalRaw: String
            let aliasesRaw: [String]
            if let colonIndex = rawLine.firstIndex(of: ":") {
                canonicalRaw = String(rawLine[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let aliasSection = String(rawLine[rawLine.index(after: colonIndex)...])
                aliasesRaw = aliasSection
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                canonicalRaw = rawLine
                aliasesRaw = []
            }

            let canonical = sanitizeVocabularyPhrase(canonicalRaw)
            guard canonical.count >= 3 else { continue }

            let normalizedKey = canonical.lowercased()
            guard !seen.contains(normalizedKey) else { continue }
            seen.insert(normalizedKey)

            let aliases = aliasesRaw
                .map(sanitizeVocabularyPhrase)
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(canonical) != .orderedSame }

            terms.append(
                CustomVocabularyTerm(
                    text: canonical,
                    weight: nil, // Let FluidAudio defaults tune CBW unless user explicitly needs stronger biasing.
                    aliases: aliases.isEmpty ? nil : aliases
                )
            )
        }

        guard !terms.isEmpty else { return nil }
        return CustomVocabularyContext(terms: terms)
    }

    private func sanitizeVocabularyPhrase(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cleanedScalars = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(cleanedScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
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

actor FluidAudioOfflineDiarizationService: SpeakerDiarizationService {
    private final class OfflineDiarizerManagerBox: @unchecked Sendable {
        let manager: OfflineDiarizerManager

        init(manager: OfflineDiarizerManager) {
            self.manager = manager
        }

        func diarizeSpans(audio: [Float]) async throws -> [(start: Double, end: Double, speakerId: String)] {
            let result = try await manager.process(audio: audio)
            return result.segments.map { segment in
                (
                    start: Double(segment.startTimeSeconds),
                    end: Double(segment.endTimeSeconds),
                    speakerId: segment.speakerId
                )
            }
        }
    }

    private let enrollmentService: any SpeakerEnrollmentService
    private var managerBox: OfflineDiarizerManagerBox?
    private var prepared = false
    private var preparedSpeakerHint: DiarizationSpeakerCountHint = .auto
    private var knownSpeakers: [KnownSpeaker] = []
    private let representativeAudioLimitSeconds: Double = 10.0
    private let knownSpeakerMatchThreshold: Float = 0.36

    init(enrollmentService: any SpeakerEnrollmentService) {
        self.enrollmentService = enrollmentService
    }

    private func qualityTunedConfig(expectedSpeakers: DiarizationSpeakerCountHint) -> OfflineDiarizerConfig {
        // FluidAudio benchmarks note the default community-1 config trades some DER for speed.
        // For transcript review accuracy, prefer the slower / higher-quality segmentation settings.
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
        config.minSegmentDuration = 0.0
        // Bias slightly toward preserving distinct conversational speakers instead of collapsing
        // adjacent voices into one label.
        config.clusteringThreshold = 0.60

        // Keep gap stitching extra conservative so brief turn-taking is less likely to merge.
        config.minGapDuration = 0.06
        return config
    }

    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        try await ensureModelsReady(expectedSpeakers: .auto, onProgress: onProgress)
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        knownSpeakers = speakers.sorted { $0.id < $1.id }
    }

    private func ensureModelsReady(
        expectedSpeakers: DiarizationSpeakerCountHint,
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)? = nil
    ) async throws {
        let normalizedHint = expectedSpeakers.normalized()
        if prepared, normalizedHint == preparedSpeakerHint {
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
        self.managerBox = OfflineDiarizerManagerBox(manager: manager)
        self.prepared = true
        self.preparedSpeakerHint = normalizedHint
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

    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint
    ) async throws -> DiarizationResult? {
        _ = expectedDurationSeconds
        try await ensureModelsReady(expectedSpeakers: expectedSpeakers, onProgress: nil)
        guard let managerBox else {
            throw LorreError.processingFailed("Diarizer is not initialized.")
        }

        let audioData = try AudioConverter().resampleAudioFile(url)
        let diarizedSpans = try await managerBox.diarizeSpans(audio: audioData)

        let spans = diarizedSpans.compactMap { segment -> DiarizationSpan? in
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

        guard !spans.isEmpty else { return nil }
        let relabeled = try await relabelKnownSpeakers(in: spans, audioData: audioData)
        return DiarizationResult(spans: relabeled.spans, speakerProfiles: relabeled.profiles)
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
