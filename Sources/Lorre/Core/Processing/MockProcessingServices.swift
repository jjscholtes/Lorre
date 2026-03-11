import Foundation

struct MockTranscriptionService: TranscriptionService {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .asr,
                    label: "Mock ASR ready",
                    detail: "Using the mock transcription pipeline.",
                    fraction: 1.0
                )
            )
        }
        try await Task.sleep(for: .milliseconds(180))
    }

    func setVocabularyBoostingConfiguration(_ configuration: VocabularyBoostingConfiguration) async {
        _ = configuration
    }

    func transcribe(url: URL, sessionTitle: String, source: RecordingSource) async throws -> TranscriptionResult {
        _ = url
        _ = source
        try await Task.sleep(for: .milliseconds(500))

        let base = [
            "Thanks for joining. Let's capture the action items while they're fresh.",
            "We need a clean transcript with speaker labels and a quick export.",
            "I'll review the first pass and correct names before sending.",
            "Let's keep the workflow local and straightforward."
        ]
        let titleSeed = max(1, sessionTitle.count % base.count)
        let rotated = Array(base[titleSeed...] + base[..<titleSeed])

        var utterances: [TranscriptionUtterance] = []
        var cursor = 0
        for (index, line) in rotated.enumerated() {
            let duration = 2200 + (index * 450)
            utterances.append(
                TranscriptionUtterance(
                    startMs: cursor,
                    endMs: cursor + duration,
                    text: line,
                    confidence: 0.89 - (Double(index) * 0.04)
                )
            )
            cursor += duration + 500
        }

        return TranscriptionResult(engineName: "MockAsrService", utterances: utterances)
    }
}

struct MockSpeakerDiarizationService: SpeakerDiarizationService {
    func ensureModelsReady(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .diarization,
                    label: "Mock diarization ready",
                    detail: "Using the mock speaker diarization pipeline.",
                    fraction: 1.0
                )
            )
        }
        try await Task.sleep(for: .milliseconds(140))
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        _ = speakers
    }

    func diarize(
        url: URL,
        expectedDurationSeconds: Double?,
        expectedSpeakers: DiarizationSpeakerCountHint
    ) async throws -> DiarizationResult? {
        _ = url
        try await Task.sleep(for: .milliseconds(350))
        let totalMs = Int(max(12, expectedDurationSeconds ?? 14) * 1000)
        let span = max(2000, totalMs / 4)
        let speakerPool = speakerSequence(for: expectedSpeakers)
        var spans: [DiarizationSpan] = []
        var cursor = 0
        var i = 0
        while cursor < totalMs {
            let next = min(totalMs, cursor + span)
            spans.append(DiarizationSpan(startMs: cursor, endMs: next, speakerId: speakerPool[i % speakerPool.count]))
            cursor = next
            i += 1
        }
        return DiarizationResult(spans: spans)
    }

    private func speakerSequence(for hint: DiarizationSpeakerCountHint) -> [String] {
        let normalized = hint.normalized()
        let desiredCount: Int
        switch normalized.mode {
        case .auto:
            desiredCount = 3
        case .exact:
            desiredCount = normalized.exactCount ?? 3
        case .range:
            let lower = normalized.minCount ?? 2
            let upper = normalized.maxCount ?? lower
            desiredCount = max(lower, min(upper, 3))
        }

        let count = max(1, min(8, desiredCount))
        let speakers = (1...count).map { "S\($0)" }
        if speakers.count == 1 { return [speakers[0], speakers[0], speakers[0], speakers[0]] }
        if speakers.count == 2 { return [speakers[0], speakers[1], speakers[0], speakers[1]] }
        if speakers.count == 3 { return [speakers[0], speakers[1], speakers[0], speakers[2]] }
        return speakers
    }
}

extension DiarizationResult {
    func applyingSpeakerCountHint(_ hint: DiarizationSpeakerCountHint) -> DiarizationResult {
        let normalizedHint = hint.normalized()
        guard normalizedHint.mode == .exact, normalizedHint.exactCount == 1 else { return self }
        guard !spans.isEmpty else { return self }

        struct SpeakerStats {
            var totalDurationMs: Int = 0
            var firstStartMs: Int = .max
        }

        var statsBySpeaker: [String: SpeakerStats] = [:]
        for span in spans {
            let durationMs = max(1, span.endMs - span.startMs)
            var stats = statsBySpeaker[span.speakerId, default: SpeakerStats()]
            stats.totalDurationMs += durationMs
            stats.firstStartMs = min(stats.firstStartMs, span.startMs)
            statsBySpeaker[span.speakerId] = stats
        }

        guard let dominantSpeakerID = statsBySpeaker.max(by: { lhs, rhs in
            if lhs.value.totalDurationMs == rhs.value.totalDurationMs {
                if lhs.value.firstStartMs == rhs.value.firstStartMs {
                    return lhs.key > rhs.key
                }
                return lhs.value.firstStartMs > rhs.value.firstStartMs
            }
            return lhs.value.totalDurationMs < rhs.value.totalDurationMs
        })?.key else {
            return self
        }

        let collapsedSpans = spans.map { span in
            DiarizationSpan(
                startMs: span.startMs,
                endMs: span.endMs,
                speakerId: dominantSpeakerID,
                sourceSpeakerId: span.sourceSpeakerId ?? span.speakerId
            )
        }
        let collapsedProfiles = [
            speakerProfiles.first(where: { $0.id == dominantSpeakerID }) ?? SpeakerProfile.defaultProfile(id: dominantSpeakerID)
        ]

        return DiarizationResult(spans: collapsedSpans, speakerProfiles: collapsedProfiles)
    }
}

enum TranscriptAssembler {
    private struct SpeakerAssignment {
        let speakerId: String
        let sourceSpeakerId: String?
        let overlapMs: Int
        let utteranceDurationMs: Int

        var overlapRatio: Double {
            guard utteranceDurationMs > 0 else { return 0 }
            return Double(overlapMs) / Double(utteranceDurationMs)
        }
    }

    static func assemble(
        sessionId: UUID,
        transcription: TranscriptionResult,
        diarization: DiarizationResult?
    ) -> TranscriptDocument {
        let diarizationSpans = refinedDiarizationSpans(diarization?.spans ?? [])
        let diarizationProfiles = Dictionary(
            uniqueKeysWithValues: (diarization?.speakerProfiles ?? []).map { ($0.id, $0) }
        )
        let speakerAwareUtterances = splitUtterancesAcrossSpeakerTransitions(
            transcription.utterances,
            diarizationSpans: diarizationSpans
        )
        let assignments = speakerAwareUtterances.map { utterance in
            primarySpeakerAssignment(for: utterance, spans: diarizationSpans)
        }

        var segments = zip(speakerAwareUtterances, assignments).map { utterance, assignment -> TranscriptSegment in
            let speakerId = assignment.speakerId
            return TranscriptSegment(
                startMs: utterance.startMs,
                endMs: utterance.endMs,
                text: utterance.text,
                speakerId: speakerId,
                sourceSpeakerId: assignment.sourceSpeakerId ?? speakerId,
                confidence: utterance.confidence
            )
        }

        smoothLikelySpeakerFlips(in: &segments, assignments: assignments)
        mergeLikelyFragmentContinuations(in: &segments)

        var uniqueSpeakerIds = Array(Set(segments.compactMap(\.speakerId))).sorted()
        if uniqueSpeakerIds.isEmpty { uniqueSpeakerIds = ["UNK"] }

        var speakers = uniqueSpeakerIds.map { diarizationProfiles[$0] ?? SpeakerProfile.defaultProfile(id: $0) }
        if !speakers.contains(where: { $0.id == "UNK" }) {
            speakers.append(.defaultProfile(id: "UNK"))
        }

        return TranscriptDocument(
            sessionId: sessionId,
            sourceEngine: transcription.engineName,
            segments: segments,
            speakers: speakers.sorted { $0.id < $1.id }
        )
    }

    private static func refinedDiarizationSpans(_ spans: [DiarizationSpan]) -> [DiarizationSpan] {
        guard !spans.isEmpty else { return [] }

        let sorted = spans.sorted {
            ($0.startMs, $0.endMs, $0.speakerId) < ($1.startMs, $1.endMs, $1.speakerId)
        }

        var merged: [DiarizationSpan] = []
        let mergeGapMs = 45

        for span in sorted {
            guard span.endMs > span.startMs else { continue }
            if var last = merged.last,
               last.speakerId == span.speakerId,
               span.startMs - last.endMs <= mergeGapMs {
                merged.removeLast()
                last = DiarizationSpan(
                    startMs: min(last.startMs, span.startMs),
                    endMs: max(last.endMs, span.endMs),
                    speakerId: last.speakerId,
                    sourceSpeakerId: last.sourceSpeakerId ?? span.sourceSpeakerId
                )
                merged.append(last)
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    private static func primarySpeakerAssignment(
        for utterance: TranscriptionUtterance,
        spans: [DiarizationSpan]
    ) -> SpeakerAssignment {
        guard !spans.isEmpty else {
            let duration = max(1, utterance.endMs - utterance.startMs)
            return SpeakerAssignment(
                speakerId: "UNK",
                sourceSpeakerId: "UNK",
                overlapMs: 0,
                utteranceDurationMs: duration
            )
        }

        let utteranceDuration = max(1, utterance.endMs - utterance.startMs)
        var overlapBySpeaker: [String: Int] = [:]
        var sourceBySpeaker: [String: String] = [:]

        for span in spans {
            let start = max(utterance.startMs, span.startMs)
            let end = min(utterance.endMs, span.endMs)
            guard end > start else { continue }
            let overlap = end - start
            overlapBySpeaker[span.speakerId, default: 0] += overlap
            if sourceBySpeaker[span.speakerId] == nil {
                sourceBySpeaker[span.speakerId] = span.sourceSpeakerId ?? span.speakerId
            }
        }

        if let winner = overlapBySpeaker.max(by: { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }) {
            return SpeakerAssignment(
                speakerId: winner.key,
                sourceSpeakerId: sourceBySpeaker[winner.key] ?? winner.key,
                overlapMs: winner.value,
                utteranceDurationMs: utteranceDuration
            )
        }

        // No overlap: choose nearest span to the utterance midpoint (helps with diarization/asr boundary drift).
        let midpoint = (utterance.startMs + utterance.endMs) / 2
        let nearest = spans.min { lhs, rhs in
            distanceFrom(midpoint: midpoint, to: lhs) < distanceFrom(midpoint: midpoint, to: rhs)
        }
        if let nearest {
            let distance = distanceFrom(midpoint: midpoint, to: nearest)
            if distance <= 250 {
                return SpeakerAssignment(
                    speakerId: nearest.speakerId,
                    sourceSpeakerId: nearest.sourceSpeakerId ?? nearest.speakerId,
                    overlapMs: 0,
                    utteranceDurationMs: utteranceDuration
                )
            }
        }

        return SpeakerAssignment(
            speakerId: "UNK",
            sourceSpeakerId: "UNK",
            overlapMs: 0,
            utteranceDurationMs: utteranceDuration
        )
    }

    private static func distanceFrom(midpoint: Int, to span: DiarizationSpan) -> Int {
        if midpoint < span.startMs { return span.startMs - midpoint }
        if midpoint > span.endMs { return midpoint - span.endMs }
        return 0
    }

    private static func splitUtterancesAcrossSpeakerTransitions(
        _ utterances: [TranscriptionUtterance],
        diarizationSpans: [DiarizationSpan]
    ) -> [TranscriptionUtterance] {
        guard !utterances.isEmpty, !diarizationSpans.isEmpty else { return utterances }

        var output: [TranscriptionUtterance] = []
        output.reserveCapacity(utterances.count)

        for utterance in utterances {
            let durationMs = utterance.endMs - utterance.startMs
            if durationMs < 2_200 || utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 {
                output.append(utterance)
                continue
            }
            if let tokenSplit = splitUtteranceUsingTokenSpeakerTransitions(utterance, diarizationSpans: diarizationSpans) {
                output.append(contentsOf: tokenSplit)
                continue
            }
            output.append(contentsOf: splitUtteranceAcrossSpeakerTransition(utterance, diarizationSpans: diarizationSpans))
        }

        return output
    }

    private static func splitUtteranceUsingTokenSpeakerTransitions(
        _ utterance: TranscriptionUtterance,
        diarizationSpans: [DiarizationSpan]
    ) -> [TranscriptionUtterance]? {
        let utteranceDuration = utterance.endMs - utterance.startMs
        guard utteranceDuration >= 2_400 else { return nil }
        guard let tokenTimings = utterance.tokenTimings, tokenTimings.count >= 2 else { return nil }

        let clampedTokens = tokenTimings.compactMap { token -> TranscriptionTokenTiming? in
            let startMs = max(utterance.startMs, token.startMs)
            let endMs = min(utterance.endMs, token.endMs)
            guard endMs > startMs else { return nil }
            return TranscriptionTokenTiming(
                startMs: startMs,
                endMs: endMs,
                text: token.text,
                confidence: token.confidence
            )
        }
        guard clampedTokens.count >= 2 else { return nil }

        let tokenAssignments = clampedTokens.map { token in
            primarySpeakerAssignment(
                for: TranscriptionUtterance(
                    startMs: token.startMs,
                    endMs: token.endMs,
                    text: token.text,
                    confidence: token.confidence
                ),
                spans: diarizationSpans
            )
        }
        let tokenSpeakerHints = zip(clampedTokens, tokenAssignments).map { token, assignment in
            strongTokenSpeakerHint(token: token, assignment: assignment)
        }
        guard Set(tokenSpeakerHints.compactMap(\.self)).count >= 2 else { return nil }

        var groupedTokens: [[TranscriptionTokenTiming]] = []
        groupedTokens.reserveCapacity(4)
        var currentGroup: [TranscriptionTokenTiming] = []
        currentGroup.reserveCapacity(clampedTokens.count)
        var currentStrongSpeaker: String?

        for (token, speakerHint) in zip(clampedTokens, tokenSpeakerHints) {
            if let currentGroupSpeaker = currentStrongSpeaker,
               let speakerHint,
               speakerHint != currentGroupSpeaker,
               !currentGroup.isEmpty {
                groupedTokens.append(currentGroup)
                currentGroup.removeAll(keepingCapacity: true)
                currentStrongSpeaker = nil
            }

            currentGroup.append(token)
            if currentStrongSpeaker == nil, let speakerHint {
                currentStrongSpeaker = speakerHint
            }
        }
        if !currentGroup.isEmpty {
            groupedTokens.append(currentGroup)
        }
        guard groupedTokens.count >= 2 else { return nil }

        let groupedUtterances = groupedTokens.compactMap(utteranceFromTokenGroup)
        guard groupedUtterances.count >= 2 else { return nil }
        guard groupedUtterances.allSatisfy({ groupedUtterance in
            let durationMs = groupedUtterance.endMs - groupedUtterance.startMs
            let wordCount = groupedUtterance.text.split(whereSeparator: \.isWhitespace).count
            return durationMs >= 650 || wordCount >= 3
        }) else {
            return nil
        }

        let groupedAssignments = groupedUtterances.map { primarySpeakerAssignment(for: $0, spans: diarizationSpans) }
        let strongGroupedSpeakers: Set<String> = Set(
            groupedAssignments.compactMap { assignment in
                guard assignment.speakerId != "UNK" else { return nil }
                return assignment.overlapRatio >= 0.34 || assignment.overlapMs >= 160 ? assignment.speakerId : nil
            }
        )
        guard strongGroupedSpeakers.count >= 2 else { return nil }

        var hasStrongBoundary = false
        for index in 0..<(groupedAssignments.count - 1) {
            let left = groupedAssignments[index]
            let right = groupedAssignments[index + 1]
            guard left.speakerId != "UNK", right.speakerId != "UNK", left.speakerId != right.speakerId else { continue }

            let leftStrong = left.overlapRatio >= 0.34 || left.overlapMs >= 160
            let rightStrong = right.overlapRatio >= 0.34 || right.overlapMs >= 160
            if leftStrong && rightStrong {
                hasStrongBoundary = true
                break
            }
        }

        return hasStrongBoundary ? groupedUtterances : nil
    }

    private static func strongTokenSpeakerHint(
        token: TranscriptionTokenTiming,
        assignment: SpeakerAssignment
    ) -> String? {
        guard assignment.speakerId != "UNK" else { return nil }

        let tokenDurationMs = max(1, token.endMs - token.startMs)
        let minOverlapMs = min(120, max(40, tokenDurationMs / 2))
        let isStrong = assignment.overlapRatio >= 0.45 || assignment.overlapMs >= minOverlapMs
        return isStrong ? assignment.speakerId : nil
    }

    private static func utteranceFromTokenGroup(_ tokens: [TranscriptionTokenTiming]) -> TranscriptionUtterance? {
        guard let first = tokens.first, let last = tokens.last else { return nil }
        let text = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let confidenceValues = tokens.compactMap(\.confidence)
        let meanConfidence: Double?
        if confidenceValues.isEmpty {
            meanConfidence = nil
        } else {
            meanConfidence = confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        }

        return TranscriptionUtterance(
            startMs: first.startMs,
            endMs: max(first.startMs + 1, last.endMs),
            text: text,
            confidence: meanConfidence,
            tokenTimings: tokens
        )
    }

    private static func splitUtteranceAcrossSpeakerTransition(
        _ utterance: TranscriptionUtterance,
        diarizationSpans: [DiarizationSpan]
    ) -> [TranscriptionUtterance] {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs = max(1, utterance.endMs - utterance.startMs)

        guard durationMs >= 2_200 else { return [utterance] }
        guard text.count >= 24 else { return [utterance] }

        let overlappingSpans = diarizationSpans.filter { span in
            min(span.endMs, utterance.endMs) > max(span.startMs, utterance.startMs)
        }
        guard Set(overlappingSpans.map(\.speakerId)).count >= 2 else { return [utterance] }

        let sentenceChunks = sentenceLikeChunks(from: text)
        guard sentenceChunks.count >= 2 else { return [utterance] }

        let chunked = utteranceChunksByProportion(utterance, chunks: sentenceChunks)
        guard chunked.count >= 2 else { return [utterance] }
        guard chunked.allSatisfy({ chunk in
            let durationMs = chunk.endMs - chunk.startMs
            let wordCount = chunk.text.split(whereSeparator: \.isWhitespace).count
            return durationMs >= 750 || wordCount >= 4
        }) else {
            return [utterance]
        }

        let assignments = chunked.map { primarySpeakerAssignment(for: $0, spans: diarizationSpans) }
        let strongAssignedSpeakers = Set(
            zip(chunked, assignments).compactMap { chunk, assignment -> String? in
                guard assignment.speakerId != "UNK" else { return nil }
                if assignment.overlapMs >= 220 || assignment.overlapRatio >= 0.30 {
                    return assignment.speakerId
                }
                // Allow slightly weaker support for shorter chunks.
                let chunkDuration = max(1, chunk.endMs - chunk.startMs)
                let chunkSupportRatio = Double(assignment.overlapMs) / Double(chunkDuration)
                return chunkSupportRatio >= 0.24 ? assignment.speakerId : nil
            }
        )
        guard strongAssignedSpeakers.count >= 2 else { return [utterance] }

        var foundTransition = false
        for index in 0..<(chunked.count - 1) {
            let left = assignments[index]
            let right = assignments[index + 1]
            guard left.speakerId != "UNK", right.speakerId != "UNK", left.speakerId != right.speakerId else { continue }

            let leftStrong = left.overlapMs >= 220 || left.overlapRatio >= 0.28
            let rightStrong = right.overlapMs >= 220 || right.overlapRatio >= 0.28
            if leftStrong && rightStrong {
                foundTransition = true
                break
            }
        }

        return foundTransition ? chunked : [utterance]
    }

    private static func sentenceLikeChunks(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var buffer = ""
        let terminators: Set<Character> = [".", "!", "?"]

        for character in trimmed {
            buffer.append(character)
            if terminators.contains(character) {
                let candidate = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    chunks.append(candidate)
                }
                buffer = ""
            }
        }

        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            chunks.append(tail)
        }

        return chunks
    }

    private static func utteranceChunksByProportion(
        _ utterance: TranscriptionUtterance,
        chunks: [String]
    ) -> [TranscriptionUtterance] {
        guard chunks.count >= 2 else { return [utterance] }

        let totalDuration = max(1, utterance.endMs - utterance.startMs)
        let weights = chunks.map { max(1, $0.filter { !$0.isWhitespace }.count) }
        let totalWeight = max(1, weights.reduce(0, +))

        var results: [TranscriptionUtterance] = []
        results.reserveCapacity(chunks.count)
        var currentStart = utterance.startMs
        var cumulativeWeight = 0

        for index in chunks.indices {
            cumulativeWeight += weights[index]
            let remainingChunkCount = chunks.count - index - 1
            let suggestedEnd: Int
            if index == chunks.count - 1 {
                suggestedEnd = utterance.endMs
            } else {
                let fraction = Double(cumulativeWeight) / Double(totalWeight)
                suggestedEnd = utterance.startMs + Int((Double(totalDuration) * fraction).rounded())
            }

            let maxEndForChunk = utterance.endMs - remainingChunkCount
            let end = min(maxEndForChunk, max(currentStart + 1, suggestedEnd))

            results.append(
                TranscriptionUtterance(
                    startMs: currentStart,
                    endMs: end,
                    text: chunks[index],
                    confidence: utterance.confidence
                )
            )

            currentStart = end
        }

        if let lastIndex = results.indices.last {
            results[lastIndex].endMs = max(results[lastIndex].startMs + 1, utterance.endMs)
        }

        return results
    }

    private static func smoothLikelySpeakerFlips(
        in segments: inout [TranscriptSegment],
        assignments: [SpeakerAssignment]
    ) {
        guard segments.count >= 3, segments.count == assignments.count else { return }

        for index in 1..<(segments.count - 1) {
            let current = segments[index]
            let previous = segments[index - 1]
            let next = segments[index + 1]

            guard let previousSpeaker = previous.speakerId,
                  let nextSpeaker = next.speakerId,
                  let currentSpeaker = current.speakerId else { continue }
            guard previousSpeaker == nextSpeaker else { continue }
            guard currentSpeaker != previousSpeaker else { continue }
            guard currentSpeaker != "UNK" else { continue }

            let durationMs = max(1, current.endMs - current.startMs)
            let supportRatio = assignments[index].overlapRatio

        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let endsSentence = text.last.map { ".!?".contains($0) } ?? false

        // Typical diarization jitter pattern: a very short row flips to another speaker
        // between two rows owned by the same surrounding speaker.
        if durationMs <= 1_100 && supportRatio < 0.42 && !endsSentence {
            segments[index].speakerId = previousSpeaker
            continue
        }

        if durationMs <= 1_600 && wordCount <= 3 && supportRatio < 0.30 {
            segments[index].speakerId = previousSpeaker
        }
    }
    }

    private static func mergeLikelyFragmentContinuations(in segments: inout [TranscriptSegment]) {
        guard segments.count >= 2 else { return }

        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(segments.count)

        var index = 0
        while index < segments.count {
            let current = segments[index]

            if index + 1 < segments.count {
                var next = segments[index + 1]
                if shouldMergeFragment(current, into: next) {
                    next.text = smartJoin(current.text, next.text)
                    next.startMs = min(current.startMs, next.startMs)
                    next.confidence = mergeConfidence(current.confidence, next.confidence)
                    merged.append(next)
                    index += 2
                    continue
                }
            }

            merged.append(current)
            index += 1
        }

        segments = merged
    }

    private static func shouldMergeFragment(_ current: TranscriptSegment, into next: TranscriptSegment) -> Bool {
        guard current.speakerId == next.speakerId else { return false }

        let gapMs = next.startMs - current.endMs
        guard gapMs >= 0, gapMs <= 320 else { return false }

        let currentText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty, !nextText.isEmpty else { return false }

        let durationMs = max(1, current.endMs - current.startMs)
        let currentWords = currentText.split(whereSeparator: \.isWhitespace)
        let nextStartsLowercase = nextText.first?.isLowercase == true
        let currentEndsSentence = currentText.last.map { ".!?".contains($0) } ?? false

        // Merge tiny fragments like "Do" + "ordat ..." that are split by ASR/VAD boundaries.
        if currentWords.count == 1,
           durationMs <= 900,
           currentText.count <= 4,
           nextStartsLowercase,
           !currentEndsSentence {
            return true
        }

        if currentWords.count <= 3,
           durationMs <= 1_400,
           !currentEndsSentence,
           nextStartsLowercase {
            return true
        }

        return false
    }

    private static func smartJoin(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let noSpaceJoin: Bool = {
            guard let leftLast = left.last, let rightFirst = right.first else { return false }
            let leftIsWord = leftLast.isLetter || leftLast.isNumber
            let rightIsWord = rightFirst.isLetter || rightFirst.isNumber
            return leftIsWord && rightIsWord && rightFirst.isLowercase
        }()

        if noSpaceJoin {
            return left + right
        }
        return "\(left) \(right)"
    }

    private static func mergeConfidence(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return (l + r) / 2.0
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }
}

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

                let draftTranscript = TranscriptAssembler.assemble(
                    sessionId: sessionId,
                    transcription: transcription,
                    diarization: nil
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
                    expectedSpeakers: diarizationExpectedSpeakers
                )
            } else {
                try await updateSession(&session, status: .processing, phase: .diarizing, label: "Skipping speaker diarization", fraction: 0.6)
                await onProgress(ProcessingUpdate(phase: .diarizing, label: "Skipping speaker diarization", fraction: 0.6))
                diarization = nil
            }
            let adjustedDiarization = diarization?.applyingSpeakerCountHint(diarizationExpectedSpeakers)

            try await updateSession(&session, status: .processing, phase: .assembling, label: "Assembling transcript", fraction: 0.82)
            await onProgress(ProcessingUpdate(phase: .assembling, label: "Assembling transcript", fraction: 0.82))
            let transcript = TranscriptAssembler.assemble(
                sessionId: sessionId,
                transcription: transcription,
                diarization: adjustedDiarization
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
