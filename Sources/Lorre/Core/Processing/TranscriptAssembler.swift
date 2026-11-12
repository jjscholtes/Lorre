import Foundation

extension DiarizationResult {
    /// Speakers with less speech than this, and less than `minorSpeakerMaxShare` of all speech,
    /// are treated as diarizer artifacts (a cough, laughter, a burst of crosstalk that got its own
    /// cluster) when the speaker count is not fixed.
    static let minorSpeakerMaxSpeechMs = 2_000
    static let minorSpeakerMaxShare = 0.03

    func applyingSpeakerCountHint(_ hint: DiarizationSpeakerCountHint) -> DiarizationResult {
        let normalizedHint = hint.normalized()
        guard !spans.isEmpty else { return self }
        guard normalizedHint.mode == .exact, normalizedHint.exactCount == 1 else {
            return foldingMinorSpeakers(hint: normalizedHint)
        }

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

    /// Folds speakers that carry almost no speech into the speaker talking around them, and folds
    /// the smallest speakers away while there are more than the hint allows. Not every engine
    /// enforces the hint itself (Sortformer and LS-EEND ignore it). Saved speakers recognized by
    /// voice are never folded away.
    func foldingMinorSpeakers(hint: DiarizationSpeakerCountHint) -> DiarizationResult {
        let normalizedHint = hint.normalized()
        let minimumCount: Int
        let maximumCount: Int?
        switch normalizedHint.mode {
        case .auto:
            minimumCount = 1
            maximumCount = nil
        case .range:
            minimumCount = normalizedHint.minCount ?? 1
            maximumCount = normalizedHint.maxCount
        case .exact:
            minimumCount = normalizedHint.exactCount ?? 1
            maximumCount = normalizedHint.exactCount
        }

        var speechBySpeaker: [String: Int] = [:]
        var recognizedSpeakers = Set<String>()
        for span in spans where span.endMs > span.startMs {
            speechBySpeaker[span.speakerId, default: 0] += span.endMs - span.startMs
            if let source = span.sourceSpeakerId, source != span.speakerId {
                recognizedSpeakers.insert(span.speakerId)
            }
        }
        guard speechBySpeaker.count > 1 else { return self }
        let totalSpeechMs = max(1, speechBySpeaker.values.reduce(0, +))

        let smallestFirst = speechBySpeaker.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }
        var folded = Set<String>()
        var remainingCount = speechBySpeaker.count
        for (speakerId, speechMs) in smallestFirst {
            guard remainingCount > minimumCount else { break }
            guard !recognizedSpeakers.contains(speakerId) else { continue }
            let isOverLimit = maximumCount.map { remainingCount > $0 } ?? false
            let isMinor = normalizedHint.mode != .exact
                && speechMs < Self.minorSpeakerMaxSpeechMs
                && Double(speechMs) < Double(totalSpeechMs) * Self.minorSpeakerMaxShare
            guard isOverLimit || isMinor else { break }
            folded.insert(speakerId)
            remainingCount -= 1
        }
        guard !folded.isEmpty else { return self }

        let keptIndex = DiarizationSpanIndex(spans.filter { !folded.contains($0.speakerId) })
        guard !keptIndex.isEmpty else { return self }

        let foldedSpans = spans.map { span -> DiarizationSpan in
            guard folded.contains(span.speakerId) else { return span }
            let overlaps = keptIndex.overlaps(startMs: span.startMs, endMs: span.endMs)
            let target = overlaps.max { lhs, rhs in
                if lhs.value.overlapMs == rhs.value.overlapMs { return lhs.key > rhs.key }
                return lhs.value.overlapMs < rhs.value.overlapMs
            }?.key ?? keptIndex.nearestSpan(toMs: (span.startMs + span.endMs) / 2)?.span.speakerId
            guard let target else { return span }
            return DiarizationSpan(
                startMs: span.startMs,
                endMs: span.endMs,
                speakerId: target,
                sourceSpeakerId: span.sourceSpeakerId ?? span.speakerId
            )
        }

        return DiarizationResult(
            spans: foldedSpans,
            speakerProfiles: speakerProfiles.filter { !folded.contains($0.id) }
        )
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
        let spanIndex = DiarizationSpanIndex(refinedDiarizationSpans(diarization?.spans ?? []))
        let diarizationProfiles = Dictionary(
            (diarization?.speakerProfiles ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let assignedUtterances = speakerAwareUtterances(transcription.utterances, index: spanIndex)
        let assignments = assignedUtterances.map(\.assignment)

        var segments = assignedUtterances.map { assigned -> TranscriptSegment in
            let utterance = assigned.utterance
            let assignment = assigned.assignment
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
        index: DiarizationSpanIndex
    ) -> SpeakerAssignment {
        let utteranceDuration = max(1, utterance.endMs - utterance.startMs)
        let unknown = SpeakerAssignment(
            speakerId: "UNK",
            sourceSpeakerId: "UNK",
            overlapMs: 0,
            utteranceDurationMs: utteranceDuration
        )
        guard !index.isEmpty else { return unknown }

        let overlaps = index.overlaps(startMs: utterance.startMs, endMs: utterance.endMs)
        if let winner = strongestOverlap(in: overlaps) {
            return SpeakerAssignment(
                speakerId: winner.speakerId,
                sourceSpeakerId: overlaps[winner.speakerId]?.sourceSpeakerId ?? winner.speakerId,
                overlapMs: winner.overlapMs,
                utteranceDurationMs: utteranceDuration
            )
        }

        let midpoint = (utterance.startMs + utterance.endMs) / 2
        if let nearest = index.nearestSpan(toMs: midpoint), nearest.distanceMs <= 250 {
            return SpeakerAssignment(
                speakerId: nearest.span.speakerId,
                sourceSpeakerId: nearest.span.sourceSpeakerId ?? nearest.span.speakerId,
                overlapMs: 0,
                utteranceDurationMs: utteranceDuration
            )
        }

        return unknown
    }

    // MARK: - Speaker-aware utterance splitting

    private struct AssignedUtterance {
        let utterance: TranscriptionUtterance
        let assignment: SpeakerAssignment
    }

    /// One spoken word, built from one or more ASR subword tokens. Speaker changes are only ever
    /// placed between words, never inside one.
    private struct TimedWord {
        var startMs: Int
        var endMs: Int
        var tokens: [TranscriptionTokenTiming]

        var durationMs: Int { max(1, endMs - startMs) }

        var endsSentence: Bool {
            let text = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = text.last else { return false }
            return TranscriptAssembler.sentenceTerminators.contains(last)
        }
    }

    private struct SpeakerRun {
        var speakerId: String
        var range: Range<Int>
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    /// A word keeps the previous word's speaker unless another speaker covers it clearly more.
    /// This stops overlapping diarization spans from flip-flopping a speaker mid-sentence.
    private static let wordSpeakerStickiness = 0.8
    /// Short runs of words wedged between the same speaker are almost always diarization jitter
    /// (a backchannel, a cough, a boundary that is a few hundred milliseconds off).
    private static let interiorBlipMaxWords = 2
    private static let interiorBlipMaxDurationMs = 900
    /// A single short word at the edge of an ASR utterance, or between two different speakers,
    /// is folded into its neighbor: the ASR found no pause there, so a real turn change is unlikely.
    private static let edgeBlipMaxDurationMs = 500
    /// How many words a speaker change may move to land on a sentence end instead.
    private static let sentenceSnapMaxWords = 2

    private static func speakerAwareUtterances(
        _ utterances: [TranscriptionUtterance],
        index: DiarizationSpanIndex
    ) -> [AssignedUtterance] {
        var output: [AssignedUtterance] = []
        output.reserveCapacity(utterances.count)

        for utterance in utterances {
            if !index.isEmpty, let wordLevel = splitUtteranceByWordSpeakers(utterance, index: index) {
                output.append(contentsOf: wordLevel)
                continue
            }
            // No usable token timings: fall back to sentence-proportional splitting.
            for part in splitUtteranceAcrossSpeakerTransition(utterance, index: index) {
                output.append(
                    AssignedUtterance(utterance: part, assignment: primarySpeakerAssignment(for: part, index: index))
                )
            }
        }

        return output
    }

    /// Assigns a speaker to every word from its overlap with the diarization spans, cleans up
    /// jitter, moves speaker changes onto nearby sentence ends and splits the utterance at each
    /// remaining change. Returns nil when the utterance has no token timings to work with.
    private static func splitUtteranceByWordSpeakers(
        _ utterance: TranscriptionUtterance,
        index: DiarizationSpanIndex
    ) -> [AssignedUtterance]? {
        let words = timedWords(for: utterance)
        guard !words.isEmpty else { return nil }
        guard var runs = speakerRuns(for: words, index: index) else { return nil }

        smoothSpeakerRuns(&runs, words: words)
        snapSpeakerChangesToSentenceEnds(&runs, words: words)

        if runs.count == 1 {
            return [
                AssignedUtterance(
                    utterance: utterance,
                    assignment: assignment(of: runs[0].speakerId, to: utterance, index: index)
                )
            ]
        }

        var parts = runs.map { run in
            makeUtterance(from: Array(words[run.range]), fallbackConfidence: utterance.confidence)
        }
        reconcileText(of: &parts, with: utterance.text)

        let assigned = zip(parts, runs).compactMap { part, run -> AssignedUtterance? in
            guard !part.text.isEmpty else { return nil }
            return AssignedUtterance(utterance: part, assignment: assignment(of: run.speakerId, to: part, index: index))
        }
        return assigned.isEmpty ? nil : assigned
    }

    private static func timedWords(for utterance: TranscriptionUtterance) -> [TimedWord] {
        guard let tokenTimings = utterance.tokenTimings, !tokenTimings.isEmpty else { return [] }
        let lastStartMs = max(utterance.startMs, utterance.endMs - 1)

        var words: [TimedWord] = []
        words.reserveCapacity(tokenTimings.count)
        for token in tokenTimings {
            let startMs = min(max(utterance.startMs, token.startMs), lastStartMs)
            let endMs = max(startMs + 1, min(utterance.endMs, token.endMs))
            let clamped = TranscriptionTokenTiming(
                startMs: startMs,
                endMs: endMs,
                text: token.text,
                confidence: token.confidence
            )
            let startsWord = words.isEmpty || token.text.first?.isWhitespace == true
            if startsWord {
                words.append(TimedWord(startMs: startMs, endMs: endMs, tokens: [clamped]))
            } else {
                words[words.count - 1].tokens.append(clamped)
                words[words.count - 1].endMs = max(words[words.count - 1].endMs, endMs)
            }
        }
        return words
    }

    private static func speakerRuns(for words: [TimedWord], index: DiarizationSpanIndex) -> [SpeakerRun]? {
        var labels: [String?] = []
        labels.reserveCapacity(words.count)
        var previous: String?

        for word in words {
            let overlaps = index.overlaps(startMs: word.startMs, endMs: word.endMs)
            guard let best = strongestOverlap(in: overlaps) else {
                labels.append(nil)
                continue
            }
            var label = best.speakerId
            if let previous, previous != label, let previousOverlap = overlaps[previous]?.overlapMs,
               Double(previousOverlap) >= Double(best.overlapMs) * wordSpeakerStickiness {
                label = previous
            }
            labels.append(label)
            previous = label
        }

        // Words in a gap between spans take the speaker of the word before them (or after them at
        // the start of the utterance): the ASR heard no pause, so the same person kept talking.
        guard let firstLabel = labels.compactMap({ $0 }).first else { return nil }
        var current = firstLabel
        var runs: [SpeakerRun] = []
        for (wordIndex, label) in labels.enumerated() {
            if let label { current = label }
            if let last = runs.last, last.speakerId == current {
                runs[runs.count - 1].range = last.range.lowerBound..<(wordIndex + 1)
            } else {
                runs.append(SpeakerRun(speakerId: current, range: wordIndex..<(wordIndex + 1)))
            }
        }
        return runs
    }

    private static func smoothSpeakerRuns(_ runs: inout [SpeakerRun], words: [TimedWord]) {
        var changed = true
        while changed, runs.count > 1 {
            changed = false
            for runIndex in runs.indices {
                let run = runs[runIndex]
                let durationMs = words[run.range.upperBound - 1].endMs - words[run.range.lowerBound].startMs
                let previous = runIndex > 0 ? runs[runIndex - 1] : nil
                let next = runIndex + 1 < runs.count ? runs[runIndex + 1] : nil

                var replacement: String?
                if let previous, let next, previous.speakerId == next.speakerId {
                    if run.range.count <= interiorBlipMaxWords, durationMs < interiorBlipMaxDurationMs {
                        replacement = previous.speakerId
                    }
                } else if run.range.count == 1, durationMs < edgeBlipMaxDurationMs {
                    let neighbors = [previous, next].compactMap { $0 }
                    replacement = neighbors.max { lhs, rhs in
                        spokenDurationMs(of: lhs, words: words) < spokenDurationMs(of: rhs, words: words)
                    }?.speakerId
                }

                if let replacement {
                    runs[runIndex].speakerId = replacement
                    mergeAdjacentRuns(&runs)
                    changed = true
                    break
                }
            }
        }
    }

    private static func spokenDurationMs(of run: SpeakerRun, words: [TimedWord]) -> Int {
        words[run.range].reduce(0) { $0 + $1.durationMs }
    }

    private static func mergeAdjacentRuns(_ runs: inout [SpeakerRun]) {
        var merged: [SpeakerRun] = []
        merged.reserveCapacity(runs.count)
        for run in runs {
            if let last = merged.last, last.speakerId == run.speakerId {
                merged[merged.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                merged.append(run)
            }
        }
        runs = merged
    }

    /// Diarization turn boundaries are often a few hundred milliseconds off. When a sentence ends
    /// within a couple of words of the change, the change almost certainly belongs there.
    private static func snapSpeakerChangesToSentenceEnds(_ runs: inout [SpeakerRun], words: [TimedWord]) {
        guard runs.count > 1 else { return }

        for runIndex in 0..<(runs.count - 1) {
            let boundary = runs[runIndex + 1].range.lowerBound
            guard !words[boundary - 1].endsSentence else { continue }

            // The new boundary must leave at least one word on each side.
            let lowest = max(runs[runIndex].range.lowerBound + 1, boundary - sentenceSnapMaxWords)
            let highest = min(runs[runIndex + 1].range.upperBound - 1, boundary + sentenceSnapMaxWords)
            guard lowest <= highest else { continue }

            let candidates = (lowest...highest).filter { $0 != boundary && words[$0 - 1].endsSentence }
            guard let snapped = candidates.min(by: { lhs, rhs in
                let lhsDistance = abs(lhs - boundary)
                let rhsDistance = abs(rhs - boundary)
                if lhsDistance == rhsDistance { return lhs < rhs }
                return lhsDistance < rhsDistance
            }) else {
                continue
            }

            runs[runIndex].range = runs[runIndex].range.lowerBound..<snapped
            runs[runIndex + 1].range = snapped..<runs[runIndex + 1].range.upperBound
        }
    }

    private static func makeUtterance(from words: [TimedWord], fallbackConfidence: Double?) -> TranscriptionUtterance {
        let tokens = words.flatMap(\.tokens)
        let text = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let confidenceValues = tokens.compactMap(\.confidence)
        let confidence = confidenceValues.isEmpty
            ? fallbackConfidence
            : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        let startMs = words.first?.startMs ?? 0
        let endMs = max(startMs + 1, words.last?.endMs ?? startMs + 1)
        return TranscriptionUtterance(
            startMs: startMs,
            endMs: endMs,
            text: text,
            confidence: confidence,
            tokenTimings: tokens
        )
    }

    /// The utterance text can carry punctuation that the transcriber moved over from a neighboring
    /// row after tokenization. Keep it when splitting instead of silently dropping it.
    private static func reconcileText(of parts: inout [TranscriptionUtterance], with originalText: String) {
        guard !parts.isEmpty else { return }
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = parts.map(\.text).joined(separator: " ")
        guard collapsedWhitespace(original) != collapsedWhitespace(joined) else { return }

        let joinedTokens = parts.map { $0.tokenTimings?.map(\.text).joined() ?? $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinedTokens.isEmpty else { return }

        if original.hasPrefix(joinedTokens) {
            let suffix = original.dropFirst(joinedTokens.count)
            parts[parts.count - 1].text += suffix
        } else if original.hasSuffix(joinedTokens) {
            let prefix = original.dropLast(joinedTokens.count).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                parts[0].text = "\(prefix) \(parts[0].text)"
            }
        }
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func assignment(
        of speakerId: String,
        to utterance: TranscriptionUtterance,
        index: DiarizationSpanIndex
    ) -> SpeakerAssignment {
        let overlap = index.overlaps(startMs: utterance.startMs, endMs: utterance.endMs)[speakerId]
        return SpeakerAssignment(
            speakerId: speakerId,
            sourceSpeakerId: overlap?.sourceSpeakerId ?? index.sourceSpeakerId(for: speakerId) ?? speakerId,
            overlapMs: overlap?.overlapMs ?? 0,
            utteranceDurationMs: max(1, utterance.endMs - utterance.startMs)
        )
    }

    private static func strongestOverlap(
        in overlaps: [String: DiarizationSpanIndex.SpeakerOverlap]
    ) -> (speakerId: String, overlapMs: Int)? {
        overlaps.max { lhs, rhs in
            if lhs.value.overlapMs == rhs.value.overlapMs { return lhs.key > rhs.key }
            return lhs.value.overlapMs < rhs.value.overlapMs
        }.map { (speakerId: $0.key, overlapMs: $0.value.overlapMs) }
    }

    private static func splitUtteranceAcrossSpeakerTransition(
        _ utterance: TranscriptionUtterance,
        index: DiarizationSpanIndex
    ) -> [TranscriptionUtterance] {
        guard !index.isEmpty else { return [utterance] }
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs = max(1, utterance.endMs - utterance.startMs)

        guard durationMs >= 2_200 else { return [utterance] }
        guard text.count >= 24 else { return [utterance] }

        guard index.overlaps(startMs: utterance.startMs, endMs: utterance.endMs).count >= 2 else { return [utterance] }

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

        let assignments = chunked.map { primarySpeakerAssignment(for: $0, index: index) }
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
                    next.endMs = max(current.endMs, next.endMs)
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

/// Answers "which speakers talk between these two times" without scanning every span.
/// Spans may overlap (offline VBx, Sortformer and LS-EEND all report overlapping speech).
struct DiarizationSpanIndex {
    struct SpeakerOverlap: Equatable {
        var overlapMs: Int
        /// The source (cluster) ID of the earliest overlapping span of this speaker.
        var sourceSpeakerId: String
    }

    private let spans: [DiarizationSpan]
    /// prefixMaxEndMs[i] is the latest end time among spans[0...i].
    private let prefixMaxEndMs: [Int]
    private let firstSourceBySpeaker: [String: String]

    init(_ spans: [DiarizationSpan]) {
        let sorted = spans
            .filter { $0.endMs > $0.startMs }
            .sorted { ($0.startMs, $0.endMs, $0.speakerId) < ($1.startMs, $1.endMs, $1.speakerId) }
        self.spans = sorted

        var runningMax = Int.min
        self.prefixMaxEndMs = sorted.map { span in
            runningMax = max(runningMax, span.endMs)
            return runningMax
        }

        var sources: [String: String] = [:]
        for span in sorted where sources[span.speakerId] == nil {
            sources[span.speakerId] = span.sourceSpeakerId ?? span.speakerId
        }
        self.firstSourceBySpeaker = sources
    }

    var isEmpty: Bool { spans.isEmpty }

    func sourceSpeakerId(for speakerId: String) -> String? {
        firstSourceBySpeaker[speakerId]
    }

    /// Total overlap per speaker with `[startMs, endMs)`.
    func overlaps(startMs: Int, endMs: Int) -> [String: SpeakerOverlap] {
        guard endMs > startMs, !spans.isEmpty else { return [:] }

        var result: [String: SpeakerOverlap] = [:]
        // Walk backwards from the last span that starts before endMs; stop once no earlier span
        // can still reach startMs. Walking backwards means the last write per speaker is its
        // earliest span.
        var spanIndex = firstIndex(startingAtOrAfter: endMs) - 1
        while spanIndex >= 0, prefixMaxEndMs[spanIndex] > startMs {
            let span = spans[spanIndex]
            let overlap = min(endMs, span.endMs) - max(startMs, span.startMs)
            if overlap > 0 {
                let previous = result[span.speakerId]?.overlapMs ?? 0
                result[span.speakerId] = SpeakerOverlap(
                    overlapMs: previous + overlap,
                    sourceSpeakerId: span.sourceSpeakerId ?? span.speakerId
                )
            }
            spanIndex -= 1
        }
        return result
    }

    /// The span closest to `ms`, with its distance (0 when a span covers `ms`).
    func nearestSpan(toMs ms: Int) -> (span: DiarizationSpan, distanceMs: Int)? {
        guard !spans.isEmpty else { return nil }

        let upper = firstIndex(startingAtOrAfter: ms + 1)
        var best: (span: DiarizationSpan, distanceMs: Int)?

        if upper < spans.count {
            best = (spans[upper], spans[upper].startMs - ms)
        }
        if upper > 0 {
            // Among the spans starting at or before ms, the one ending last is the closest.
            let latestEnd = prefixMaxEndMs[upper - 1]
            let distance = max(0, ms - latestEnd)
            if best == nil || distance <= best!.distanceMs {
                var candidate = upper - 1
                while candidate > 0, spans[candidate].endMs != latestEnd {
                    candidate -= 1
                }
                best = (spans[candidate], distance)
            }
        }
        return best
    }

    private func firstIndex(startingAtOrAfter ms: Int) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].startMs < ms {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
