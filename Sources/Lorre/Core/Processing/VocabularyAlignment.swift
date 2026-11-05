#if canImport(FluidAudio)
import FluidAudio
import Foundation

enum VocabularyAlignment {
    /// The SDK returns corrected words but keeps the original subword timings.
    /// Keep unchanged words anchored and assign each replacement the time of its source phrase.
    static func tokens(for result: ASRResult) -> [TokenTiming] {
        let tokens = result.tokenTimings ?? []
        guard result.ctcAppliedTerms?.isEmpty == false, !tokens.isEmpty else { return tokens }
        let original = buildWordTimings(from: tokens)
        guard !original.isEmpty else { return [] }
        let corrected = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let difference = corrected.difference(from: original.map(\.word))
        let removed = Set(difference.removals.map(\.wordOffset))
        let inserted = Set(difference.insertions.map(\.wordOffset))
        let anchors = zip(original.indices.filter { !removed.contains($0) },
                          corrected.indices.filter { !inserted.contains($0) })
        var timed: [TokenTiming] = []
        var oldStart = 0
        var newStart = 0
        var tokenIndex = 0

        func append(words: Range<Int>, spanning span: Range<Int>) {
            guard !words.isEmpty, !span.isEmpty else { return }
            let start = original[span.lowerBound].startTime
            let end = original[span.upperBound - 1].endTime
            while tokenIndex < tokens.count && tokens[tokenIndex].endTime <= start { tokenIndex += 1 }
            let first = tokenIndex
            while tokenIndex < tokens.count && tokens[tokenIndex].startTime < end { tokenIndex += 1 }
            let source = tokens[first..<tokenIndex]
            let confidence = source.isEmpty ? result.confidence : source.reduce(0) { $0 + $1.confidence } / Float(source.count)
            let text = corrected[words].joined(separator: " ")
            timed.append(TokenTiming(token: " " + text, tokenId: source.first?.tokenId ?? 0,
                                     startTime: start, endTime: end, confidence: confidence))
        }

        for (old, new) in anchors {
            if old > oldStart {
                append(words: newStart..<new, spanning: oldStart..<old)
                newStart = new
            }
            // A pure insertion shares the interval of the adjoining unchanged word.
            append(words: newStart..<(new + 1), spanning: old..<(old + 1))
            oldStart = old + 1
            newStart = new + 1
        }
        if newStart < corrected.count && oldStart == original.count, let last = timed.popLast() {
            let suffix = corrected[newStart...].joined(separator: " ")
            timed.append(TokenTiming(token: last.token + " " + suffix, tokenId: last.tokenId,
                                     startTime: last.startTime, endTime: last.endTime, confidence: last.confidence))
        } else {
            append(words: newStart..<corrected.count, spanning: oldStart..<original.count)
        }
        return timed
    }
}

private extension CollectionDifference.Change {
    var wordOffset: Int {
        switch self {
        case let .insert(offset, _, _), let .remove(offset, _, _): return offset
        }
    }
}
#endif
