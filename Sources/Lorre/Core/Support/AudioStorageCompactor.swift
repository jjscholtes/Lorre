import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Re-encodes a session's uncompressed recordings as Apple Lossless once
/// processing has finished.
///
/// Lorre records Float32 CAF: an hour of microphone plus system audio is about
/// 2.3 GB (system stem 1.38 GB, microphone stem 0.69 GB, 16 kHz mix 0.23 GB).
/// After processing those files are only needed for playback and re-transcription,
/// so storing them as 24-bit ALAC keeps every audible detail at a fraction of the
/// size.
///
/// The work happens in two steps so a crash never leaves a manifest pointing at a
/// missing file: `encode` writes and verifies the `.m4a` next to the original,
/// the caller updates the manifest, and only then `removeOriginals` deletes the
/// `.caf` files.
enum AudioStorageCompactor {
    struct Outcome: Equatable, Sendable {
        /// Original file name → new file name, for files that were re-encoded.
        var renamedFiles: [String: String] = [:]
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0

        var isEmpty: Bool { renamedFiles.isEmpty }
    }

    static let compactedExtension = "m4a"
    /// Recordings are CAF; imported audio may be WAV or AIFF. The PCM check in
    /// `encodeLossless` still skips any of these that turn out to be compressed.
    private static let uncompressedExtensions: Set<String> = ["caf", "wav", "aif", "aiff"]

    /// The name a file gets once compacted, or nil when it is not a PCM container.
    static func compactedFileName(for fileName: String) -> String? {
        let name = fileName as NSString
        guard uncompressedExtensions.contains(name.pathExtension.lowercased()) else { return nil }
        let base = name.deletingPathExtension
        guard !base.isEmpty else { return nil }
        return "\(base).\(compactedExtension)"
    }

    /// Encodes every uncompressed recording among `fileNames` to ALAC. A file that cannot
    /// be read or encoded is left untouched, so the result may be partial; this
    /// never throws because a failed compaction must not fail a finished transcript.
    static func encode(fileNames: [String], in directory: URL) -> Outcome {
        var outcome = Outcome()
        var seen: Set<String> = []
        for fileName in fileNames where seen.insert(fileName).inserted {
            guard let targetName = compactedFileName(for: fileName),
                  let sourceURL = try? SafeSessionFileResolver.fileURL(named: fileName, in: directory),
                  let targetURL = try? SafeSessionFileResolver.fileURL(named: targetName, in: directory),
                  FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
                continue
            }
            do {
                try encodeLossless(from: sourceURL, to: targetURL)
                outcome.renamedFiles[fileName] = targetName
                outcome.bytesBefore += fileSize(at: sourceURL)
                outcome.bytesAfter += fileSize(at: targetURL)
            } catch {
                try? FileManager.default.removeItem(at: targetURL)
            }
        }
        return outcome
    }

    /// Deletes the originals once the manifest points at the compacted files.
    static func removeOriginals(of outcome: Outcome, in directory: URL) {
        for originalName in outcome.renamedFiles.keys {
            guard let url = try? SafeSessionFileResolver.fileURL(named: originalName, in: directory) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    private static func encodeLossless(from sourceURL: URL, to targetURL: URL) throws {
        #if canImport(AVFoundation)
        let directory = targetURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".compact-\(UUID().uuidString).\(compactedExtension)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let sourceLength: AVAudioFramePosition
        do {
            let source = try AVAudioFile(forReading: sourceURL)
            guard isUncompressedPCM(source.fileFormat), source.length > 0 else {
                throw LorreError.persistenceFailed("Audio is already compressed or empty.")
            }
            sourceLength = source.length
            let format = source.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: 24
            ]
            // Scoped so the encoder is closed and the file finalised before verifying.
            do {
                let output = try AVAudioFile(
                    forWriting: temporaryURL,
                    settings: settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                    throw LorreError.persistenceFailed("Could not allocate an audio buffer.")
                }
                while source.framePosition < source.length {
                    try source.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    try output.write(from: buffer)
                }
            }
        }

        // Verify before anything else depends on the new file.
        let check = try AVAudioFile(forReading: temporaryURL)
        let tolerance = max(AVAudioFramePosition(4_096), sourceLength / 1_000)
        guard abs(check.length - sourceLength) <= tolerance else {
            throw LorreError.persistenceFailed("Compacted audio has a different length.")
        }

        if FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
        #else
        throw LorreError.persistenceFailed("Audio compaction is unavailable in this build.")
        #endif
    }

    #if canImport(AVFoundation)
    private static func isUncompressedPCM(_ format: AVAudioFormat) -> Bool {
        (format.settings[AVFormatIDKey] as? NSNumber)?.uint32Value == kAudioFormatLinearPCM
    }
    #endif
}
