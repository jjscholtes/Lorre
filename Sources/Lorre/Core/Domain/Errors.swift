import Foundation

enum LorreError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case recordingNotStarted
    case recordingStartFailed(String)
    case recordingStopFailed(String)
    case playbackFailed(String)
    case importFailed(String)
    case sessionNotFound
    case transcriptNotFound
    case processingFailed(String)
    case exportFailed(String)
    case revealFilesFailed(String)
    case deleteSessionFailed(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required to record audio."
        case .recordingNotStarted:
            return "Recording is not active."
        case let .recordingStartFailed(message):
            return "Could not start recording. \(message)"
        case let .recordingStopFailed(message):
            return "Could not stop recording. \(message)"
        case let .playbackFailed(message):
            return "Could not play audio. \(message)"
        case let .importFailed(message):
            return "Could not import audio. \(message)"
        case .sessionNotFound:
            return "The session could not be found."
        case .transcriptNotFound:
            return "No transcript is available for this session yet."
        case let .processingFailed(message):
            return "Processing failed. \(message)"
        case let .exportFailed(message):
            return "Export failed. \(message)"
        case let .revealFilesFailed(message):
            return "Could not open the session folder. \(message)"
        case let .deleteSessionFailed(message):
            return "Could not delete the session. \(message)"
        case let .persistenceFailed(message):
            return "Could not save local data. \(message)"
        }
    }
}
