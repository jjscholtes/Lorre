#if canImport(AppKit)
import AppKit

/// Asks before quitting while a recording or transcription is running.
@MainActor
final class LorreAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, let warning = viewModel.terminationWarning else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: warning.confirmButtonTitle)
        alert.addButton(withTitle: warning.cancelButtonTitle)
        // Return keeps working; quitting has to be chosen on purpose.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        guard warning == .recording else {
            return .terminateNow
        }

        Task { @MainActor in
            await viewModel.stopRecordingForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
