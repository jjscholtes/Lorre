import AVFoundation
import Foundation
import Testing
@testable import Lorre

struct AudioStorageCompactorTests {
    @Test
    func compactedNamesOnlyApplyToPCMContainers() {
        #expect(AudioStorageCompactor.compactedFileName(for: "audio.caf") == "audio.m4a")
        #expect(AudioStorageCompactor.compactedFileName(for: "system-audio.CAF") == "system-audio.m4a")
        #expect(AudioStorageCompactor.compactedFileName(for: "import.wav") == "import.m4a")
        #expect(AudioStorageCompactor.compactedFileName(for: "audio.m4a") == nil)
        #expect(AudioStorageCompactor.compactedFileName(for: "audio.mp3") == nil)
        #expect(AudioStorageCompactor.compactedFileName(for: ".caf") == nil)
    }

    @Test
    func encodesFloatCAFLosslesslyAndRemovesTheOriginalOnRequest() throws {
        let directory = makeTemporaryRoot(named: "Compactor")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let samples = (0..<32_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.4) }
        let sourceURL = directory.appendingPathComponent("audio.caf")
        do {
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try file.write(from: RecorderAudioUtilities.makePCMBuffer(from: samples, format: format))
        }

        let outcome = AudioStorageCompactor.encode(fileNames: ["audio.caf", "audio.caf"], in: directory)
        #expect(outcome.renamedFiles == ["audio.caf": "audio.m4a"])
        #expect(outcome.bytesAfter > 0)
        #expect(outcome.bytesAfter < outcome.bytesBefore)

        // The original stays until the caller has updated the manifest.
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        let compacted = try AVAudioFile(forReading: directory.appendingPathComponent("audio.m4a"))
        #expect(compacted.length == AVAudioFramePosition(samples.count))
        #expect(compacted.fileFormat.sampleRate == 16_000)

        AudioStorageCompactor.removeOriginals(of: outcome, in: directory)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func unreadableOrMissingFilesAreLeftAlone() throws {
        let directory = makeTemporaryRoot(named: "CompactorSkip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let junkURL = directory.appendingPathComponent("microphone.caf")
        try Data("not audio".utf8).write(to: junkURL)

        let outcome = AudioStorageCompactor.encode(
            fileNames: ["microphone.caf", "missing.caf", "../escape.caf"],
            in: directory
        )
        #expect(outcome.isEmpty)
        #expect(FileManager.default.fileExists(atPath: junkURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone.m4a").path))
    }
}
