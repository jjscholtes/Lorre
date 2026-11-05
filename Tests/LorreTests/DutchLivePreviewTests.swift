import AVFoundation
import Foundation
import Testing
@testable import Lorre

struct DutchLivePreviewTests {
    // Opt in to the model download and the macOS Dutch voice used by this integration test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LORRE_TEST_DUTCH_LIVE"] == "1"))
    func dutchSpeechAppearsDuringCaptureAndTheLastWordSurvivesStop() async throws {
        let directory = makeTemporaryRoot(named: "DutchLiveSpeech")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("meeting.aiff")
        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-v", "Xander", "-o", clip.path,
            "Maandag bespreken we de planning voor het nieuwe station in Delft. [[slnc 1000]] De vergadering begint om tien uur. Daarna belt Marieke de leverancier om de afspraak te bevestigen."]
        try speech.run()
        speech.waitUntilExit()
        try #require(speech.terminationStatus == 0)

        let recognizer = FluidAudioLiveStreamingRecognizer(preset: .dutchUnified)
        try await recognizer.prepareModels()
        for (rate, channels) in [(16_000.0, 1), (48_000.0, 2)] {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)))
            let samples = try RecorderAudioUtilities.loadSamples(from: clip, targetFormat: format)
            try #require(!samples.isEmpty)
            try await recognizer.start { _ in }
            #expect(await !recognizer.latestPreview().hasContent)
            var sawPartialBeforeEnd = false
            let chunk = Int(rate / 20)
            for start in stride(from: 0, to: samples.count, by: chunk) {
                let end = min(start + chunk, samples.count)
                let buffer = try RecorderAudioUtilities.makePCMBuffer(from: Array(samples[start..<end]), format: format)
                await recognizer.ingest(LiveTranscriptionPCMBufferBox(buffer))
                if end < samples.count, await recognizer.latestPreview().partialText.localizedCaseInsensitiveContains("Delft") {
                    sawPartialBeforeEnd = true
                }
            }
            let final = try await recognizer.finish()
            #expect(sawPartialBeforeEnd)
            #expect(final.errorMessage == nil)
            #expect(final.partialText.isEmpty)
            let words = final.confirmedText.lowercased().split { !$0.isLetter }
            #expect(words.filter { $0 == "delft" }.count == 1)
            #expect(words.last == "bevestigen")
        }
    }
}
