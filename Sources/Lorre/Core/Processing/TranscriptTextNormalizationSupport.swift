import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

enum TranscriptTextNormalizationSupport {
    static func normalize(_ transcript: TranscriptDocument) -> TranscriptDocument {
        #if canImport(FluidAudio)
        let normalizer = TextNormalizationRuntimeSupport.prepare()
        guard normalizer.isNativeAvailable else { return transcript }
        return normalize(transcript, using: normalizer.normalizeSentence)
        #else
        return transcript
        #endif
    }

    static func normalize(
        _ transcript: TranscriptDocument,
        using sentenceNormalizer: (String) -> String
    ) -> TranscriptDocument {
        var normalizedTranscript = transcript
        normalizedTranscript.segments = transcript.segments.map { segment in
            var normalizedSegment = segment
            let normalizedText = sentenceNormalizer(segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { return normalizedSegment }
            normalizedSegment.text = normalizedText
            return normalizedSegment
        }
        return normalizedTranscript
    }
}
