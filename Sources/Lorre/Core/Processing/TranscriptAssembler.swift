import Foundation

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
            languageHint: transcription.languageCode ?? "en",
            sourceEngine: transcription.engineName,
            segments: segments,
            speakers: speakers.sorted { $0.id < $1.id },
            alternatives: transcription.alternatives
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
