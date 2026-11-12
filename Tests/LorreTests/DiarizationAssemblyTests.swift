import Foundation
import Testing
@testable import Lorre

@Suite("DiarizationAssemblyTests")
struct DiarizationAssemblyTests {
    /// Builds token timings for whitespace-separated words laid out back to back.
    private func tokens(_ words: [(String, Int, Int)]) -> [TranscriptionTokenTiming] {
        words.enumerated().map { offset, word in
            TranscriptionTokenTiming(
                startMs: word.1,
                endMs: word.2,
                text: offset == 0 ? word.0 : " " + word.0,
                confidence: 0.9
            )
        }
    }

    private func assemble(
        _ utterances: [TranscriptionUtterance],
        spans: [DiarizationSpan]
    ) -> TranscriptDocument {
        TranscriptAssembler.assemble(
            sessionId: UUID(),
            transcription: TranscriptionResult(engineName: "Test", utterances: utterances),
            diarization: DiarizationResult(spans: spans)
        )
    }

    @Test
    func splitsShortUtteranceAtQuickTurnChange() {
        // 1.9 s and no pause: the old assembler never split utterances shorter than 2.2 s.
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 1_900,
            text: "Klopt dat? Ja zeker weten",
            confidence: 0.9,
            tokenTimings: tokens([
                ("Klopt", 0, 350), ("dat?", 350, 800),
                ("Ja", 800, 1_050), ("zeker", 1_050, 1_450), ("weten", 1_450, 1_900)
            ])
        )

        let transcript = assemble([utterance], spans: [
            DiarizationSpan(startMs: 0, endMs: 820, speakerId: "S1"),
            DiarizationSpan(startMs: 820, endMs: 1_900, speakerId: "S2")
        ])

        #expect(transcript.segments.map(\.text) == ["Klopt dat?", "Ja zeker weten"])
        #expect(transcript.segments.map(\.speakerId) == ["S1", "S2"])
    }

    @Test
    func movesLateSpeakerChangeToSentenceEnd() {
        // The diarizer switches to S2 one word too late ("dat" instead of "Prima").
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 3_000,
            text: "We beginnen morgen. Prima dat lijkt me goed",
            confidence: 0.9,
            tokenTimings: tokens([
                ("We", 0, 250), ("beginnen", 250, 800), ("morgen.", 800, 1_300),
                ("Prima", 1_300, 1_700), ("dat", 1_700, 1_950), ("lijkt", 1_950, 2_300),
                ("me", 2_300, 2_500), ("goed", 2_500, 3_000)
            ])
        )

        let transcript = assemble([utterance], spans: [
            DiarizationSpan(startMs: 0, endMs: 1_720, speakerId: "S1"),
            DiarizationSpan(startMs: 1_720, endMs: 3_000, speakerId: "S2")
        ])

        #expect(transcript.segments.map(\.text) == ["We beginnen morgen.", "Prima dat lijkt me goed"])
        #expect(transcript.segments.map(\.speakerId) == ["S1", "S2"])
    }

    @Test
    func neverSplitsInsideAWord() {
        // "vergadering" arrives as three subword tokens; the speaker change falls inside it.
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 3_200,
            text: "De vergadering begint nu echt",
            confidence: 0.9,
            tokenTimings: [
                TranscriptionTokenTiming(startMs: 0, endMs: 300, text: "De", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 300, endMs: 600, text: " ver", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 600, endMs: 900, text: "gade", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 900, endMs: 1_300, text: "ring", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 1_300, endMs: 2_000, text: " begint", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 2_000, endMs: 2_500, text: " nu", confidence: 0.9),
                TranscriptionTokenTiming(startMs: 2_500, endMs: 3_200, text: " echt", confidence: 0.9)
            ]
        )

        let transcript = assemble([utterance], spans: [
            DiarizationSpan(startMs: 0, endMs: 800, speakerId: "S1"),
            DiarizationSpan(startMs: 800, endMs: 3_200, speakerId: "S2")
        ])

        #expect(!transcript.segments.contains { $0.text.hasSuffix("ver") || $0.text.hasPrefix("gade") })
        #expect(transcript.segments.contains { $0.text.contains("vergadering") })
    }

    @Test
    func wordsInDiarizationGapKeepThePreviousSpeaker() {
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 2_400,
            text: "Ik denk dat het werkt",
            confidence: 0.9,
            tokenTimings: tokens([
                ("Ik", 0, 300), ("denk", 300, 700), ("dat", 700, 1_100), ("het", 1_100, 1_600), ("werkt", 1_600, 2_400)
            ])
        )

        // Nothing covers 700–1600 ms; the old assembler still decided on overall overlap,
        // the new one must not invent a change there either.
        let transcript = assemble([utterance], spans: [
            DiarizationSpan(startMs: 0, endMs: 700, speakerId: "S1"),
            DiarizationSpan(startMs: 1_600, endMs: 2_400, speakerId: "S1")
        ])

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments.first?.speakerId == "S1")
        #expect(transcript.segments.first?.text == "Ik denk dat het werkt")
    }

    @Test
    func keepsPunctuationThatIsNotInTheTokens() {
        let utterance = TranscriptionUtterance(
            startMs: 0,
            endMs: 2_000,
            text: "Klopt dat? Ja zeker weten.",
            confidence: 0.9,
            tokenTimings: tokens([
                ("Klopt", 0, 350), ("dat?", 350, 800),
                ("Ja", 800, 1_100), ("zeker", 1_100, 1_500), ("weten", 1_500, 2_000)
            ])
        )

        let transcript = assemble([utterance], spans: [
            DiarizationSpan(startMs: 0, endMs: 800, speakerId: "S1"),
            DiarizationSpan(startMs: 800, endMs: 2_000, speakerId: "S2")
        ])

        #expect(transcript.segments.map(\.text) == ["Klopt dat?", "Ja zeker weten."])
    }

    @Test
    func foldsMinorSpeakerIntoSurroundingSpeakerInAutoMode() {
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 30_000, speakerId: "S1"),
            DiarizationSpan(startMs: 30_000, endMs: 30_600, speakerId: "S3"),
            DiarizationSpan(startMs: 30_600, endMs: 60_000, speakerId: "S2")
        ])

        let folded = diarization.applyingSpeakerCountHint(.auto)

        #expect(Set(folded.spans.map(\.speakerId)) == ["S1", "S2"])
        #expect(folded.spans[1].sourceSpeakerId == "S3")
    }

    @Test
    func keepsShortButRealSpeakerInShortRecording() {
        // 1.5 s out of 20 s is 7.5 % of the speech: a real participant, not an artifact.
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 10_000, speakerId: "S1"),
            DiarizationSpan(startMs: 10_000, endMs: 11_500, speakerId: "S2"),
            DiarizationSpan(startMs: 11_500, endMs: 20_000, speakerId: "S1")
        ])

        let folded = diarization.applyingSpeakerCountHint(.auto)

        #expect(folded == diarization)
    }

    @Test
    func neverFoldsRecognizedKnownSpeaker() {
        let diarization = DiarizationResult(
            spans: [
                DiarizationSpan(startMs: 0, endMs: 60_000, speakerId: "S1", sourceSpeakerId: "S1"),
                DiarizationSpan(startMs: 60_000, endMs: 60_800, speakerId: "K1", sourceSpeakerId: "S2")
            ],
            speakerProfiles: [SpeakerProfile.defaultProfile(id: "K1")]
        )

        let folded = diarization.applyingSpeakerCountHint(.auto)

        #expect(folded == diarization)
    }

    @Test
    func enforcesMaximumSpeakerCountFromRangeHint() {
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 20_000, speakerId: "S1"),
            DiarizationSpan(startMs: 20_000, endMs: 30_000, speakerId: "S2"),
            DiarizationSpan(startMs: 30_000, endMs: 35_000, speakerId: "S3"),
            DiarizationSpan(startMs: 35_000, endMs: 60_000, speakerId: "S1")
        ])

        let folded = diarization.applyingSpeakerCountHint(.range(min: 1, max: 2))

        #expect(Set(folded.spans.map(\.speakerId)) == ["S1", "S2"])
    }

    @Test
    func exactHintDoesNotFoldBelowRequestedCount() {
        let diarization = DiarizationResult(spans: [
            DiarizationSpan(startMs: 0, endMs: 60_000, speakerId: "S1"),
            DiarizationSpan(startMs: 60_000, endMs: 60_500, speakerId: "S2")
        ])

        let folded = diarization.applyingSpeakerCountHint(.exact(2))

        #expect(folded == diarization)
    }

    @Test
    func spanIndexFindsOverlapsBehindLongEarlierSpan() {
        let index = DiarizationSpanIndex([
            DiarizationSpan(startMs: 0, endMs: 10_000, speakerId: "S1"),
            DiarizationSpan(startMs: 2_000, endMs: 2_500, speakerId: "S2"),
            DiarizationSpan(startMs: 3_000, endMs: 3_200, speakerId: "S3")
        ])

        let overlaps = index.overlaps(startMs: 4_000, endMs: 5_000)

        #expect(overlaps.keys.sorted() == ["S1"])
        #expect(overlaps["S1"]?.overlapMs == 1_000)
        #expect(index.nearestSpan(toMs: 12_000)?.span.speakerId == "S1")
        #expect(index.nearestSpan(toMs: 12_000)?.distanceMs == 2_000)
    }
}
