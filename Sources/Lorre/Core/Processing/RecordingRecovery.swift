import Foundation

enum RecordingRecovery {
    private static func existingFile(_ name: String?, in directory: URL) -> URL? {
        guard let name, let url = try? SafeSessionFileResolver.fileURL(named: name, in: directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return url
    }

    static func hasSource(for session: SessionManifest, in directory: URL) -> Bool {
        guard session.hasRetainedAudio else { return false }
        if existingFile(session.audioFileName, in: directory) != nil { return true }
        return session.recordingSource == .microphoneAndSystemAudio
            && (existingFile(session.microphoneStemFileName, in: directory) != nil
                || existingFile(session.systemAudioStemFileName, in: directory) != nil)
    }

    static func restoreAudioIfNeeded(for session: SessionManifest, in directory: URL) throws {
        #if canImport(AVFoundation)
        guard session.hasRetainedAudio, session.recordingSource == .microphoneAndSystemAudio,
              existingFile(session.audioFileName, in: directory) == nil else { return }
        let mic = existingFile(session.microphoneStemFileName, in: directory)
        let system = existingFile(session.systemAudioStemFileName, in: directory)
        let destination = try SafeSessionFileResolver.fileURL(named: session.audioFileName, in: directory)
        if let mic, let system {
            try RecorderAudioUtilities.publishMix(microphone: mic, system: system, destination: destination)
        } else if let survivingTrack = mic ?? system {
            // Both files are in the same session directory. A hard link publishes
            // the surviving track atomically without duplicating a large recording.
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize == 0 else {
                    throw LorreError.persistenceFailed("Could not restore the session audio file.")
                }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.linkItem(at: survivingTrack, to: destination)
        }
        #endif
    }
}
