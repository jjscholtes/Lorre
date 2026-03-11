import Foundation

struct UserFacingErrorMessage: Sendable {
    var title: String
    var message: String
}

enum UserFacingErrorMapper {
    static func map(_ error: Error, defaultTitle: String) -> UserFacingErrorMessage {
        if let lorreError = error as? LorreError {
            switch lorreError {
            case .microphonePermissionDenied:
                return UserFacingErrorMessage(
                    title: "Microphone access required",
                    message: lorreError.localizedDescription
                )
            case .screenCapturePermissionDenied:
                return UserFacingErrorMessage(
                    title: "Screen recording access required",
                    message: lorreError.localizedDescription
                )
            case .recordingSourceSelectionCancelled:
                return UserFacingErrorMessage(
                    title: "Recording not started",
                    message: lorreError.localizedDescription
                )
            case .recordingStartFailed:
                return UserFacingErrorMessage(
                    title: "Could not start recording",
                    message: lorreError.localizedDescription
                )
            case .recordingStopFailed, .recordingNotStarted:
                return UserFacingErrorMessage(
                    title: "Could not stop recording",
                    message: lorreError.localizedDescription
                )
            case .importFailed:
                return UserFacingErrorMessage(
                    title: "Import failed",
                    message: lorreError.localizedDescription
                )
            case .playbackFailed:
                return UserFacingErrorMessage(
                    title: "Playback unavailable",
                    message: lorreError.localizedDescription
                )
            case .processingFailed:
                return UserFacingErrorMessage(
                    title: "Processing failed",
                    message: lorreError.localizedDescription
                )
            case .exportFailed:
                return UserFacingErrorMessage(
                    title: "Export failed",
                    message: lorreError.localizedDescription
                )
            case .revealFilesFailed:
                return UserFacingErrorMessage(
                    title: "Could not open Finder",
                    message: lorreError.localizedDescription
                )
            case .deleteSessionFailed:
                return UserFacingErrorMessage(
                    title: "Delete failed",
                    message: lorreError.localizedDescription
                )
            case .persistenceFailed:
                return UserFacingErrorMessage(
                    title: "Local save failed",
                    message: lorreError.localizedDescription
                )
            case .sessionNotFound:
                return UserFacingErrorMessage(
                    title: "Session not found",
                    message: lorreError.localizedDescription
                )
            case .transcriptNotFound:
                return UserFacingErrorMessage(
                    title: "Transcript unavailable",
                    message: lorreError.localizedDescription
                )
            }
        }

        return UserFacingErrorMessage(
            title: defaultTitle,
            message: error.localizedDescription
        )
    }
}
