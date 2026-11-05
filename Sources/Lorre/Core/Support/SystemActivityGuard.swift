import Foundation

/// Keeps the Mac awake and out of App Nap while Lorre records or transcribes.
///
/// Without an activity assertion a MacBook can idle-sleep during an in-person
/// meeting where nobody touches the keyboard, and App Nap can throttle an hour-long
/// transcription when Lorre's window is in the background. The display may still
/// turn off; only system sleep and throttling are prevented.
@MainActor
final class SystemActivityGuard {
    private var token: NSObjectProtocol?
    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    var isActive: Bool { token != nil }

    func update(isRecording: Bool, isProcessing: Bool) {
        let isNeeded = isRecording || isProcessing
        if isNeeded, token == nil {
            token = processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: isRecording ? "Recording audio" : "Transcribing a recording"
            )
        } else if !isNeeded, let token {
            processInfo.endActivity(token)
            self.token = nil
        }
    }
}
