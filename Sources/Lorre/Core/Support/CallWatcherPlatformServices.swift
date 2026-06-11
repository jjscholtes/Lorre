import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

struct DisabledCallWatcherService: CallWatcherService {
    func makeDetectionStream(configuration: CallWatcherConfiguration) async -> AsyncStream<CallDetectionEvent> {
        _ = configuration
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func suppressPrompt(for candidate: CallDetectionCandidate, cooldownSeconds: Int) async {
        _ = candidate
        _ = cooldownSeconds
    }
}

#if canImport(AppKit)
struct MacCallWatcherService: CallWatcherService {
    private let pollIntervalNanoseconds: UInt64 = 1_000_000_000
    private let engine = CallDetectionEngine()
    private let coordinator = CallPromptCoordinator()

    func makeDetectionStream(configuration: CallWatcherConfiguration) async -> AsyncStream<CallDetectionEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let sample = await MainActor.run {
                        Self.makeSignalSample()
                    }
                    if let detectionEvent = await engine.ingest(sample, configuration: configuration) {
                        switch detectionEvent {
                        case let .candidateDetected(candidate):
                            if await coordinator.shouldPrompt(for: candidate, now: sample.observedAt, isRecording: false) {
                                continuation.yield(detectionEvent)
                            }
                        case let .candidateEnded(fingerprint):
                            await coordinator.resetWhenSignalEnded(fingerprint: fingerprint)
                            continuation.yield(detectionEvent)
                        }
                    }
                    try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func suppressPrompt(for candidate: CallDetectionCandidate, cooldownSeconds: Int) async {
        await coordinator.dismiss(candidate: candidate, now: Date(), cooldownSeconds: cooldownSeconds)
    }

    @MainActor
    private static func makeSignalSample() -> CallSignalSample {
        let workspace = NSWorkspace.shared
        let frontmost = workspace.frontmostApplication
        let runningBundleIDs = workspace.runningApplications
            .compactMap(\.bundleIdentifier)

        return CallSignalSample(
            observedAt: Date(),
            frontmostBundleID: frontmost?.bundleIdentifier,
            frontmostAppName: frontmost?.localizedName,
            runningBundleIDs: runningBundleIDs,
            windowTitleHints: makeWindowTitleHints(),
            captureDeviceUsage: makeCaptureDeviceUsageSummary()
        )
    }

    @MainActor
    private static func makeWindowTitleHints() -> [WindowTitleHint] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let runningAppsByProcessID = makeRunningApplicationsByProcessID(
            NSWorkspace.shared.runningApplications
        )

        return windowInfo.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let title = info[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let app = runningAppsByProcessID[ownerPID]
            return WindowTitleHint(
                appBundleID: app?.bundleIdentifier,
                appDisplayName: app?.localizedName,
                title: title
            )
        }
    }

    @MainActor
    static func makeRunningApplicationsByProcessID(
        _ runningApplications: [NSRunningApplication]
    ) -> [pid_t: NSRunningApplication] {
        runningApplications.reduce(into: [:]) { applicationsByProcessID, app in
            applicationsByProcessID[app.processIdentifier] = app
        }
    }

    @MainActor
    private static func makeCaptureDeviceUsageSummary() -> CaptureDeviceUsageSummary? {
        #if canImport(AVFoundation)
        let cameraInUse = AVCaptureDevice.default(for: .video)?.isInUseByAnotherApplication ?? false
        let microphoneInUse = AVCaptureDevice.default(for: .audio)?.isInUseByAnotherApplication ?? false
        guard cameraInUse || microphoneInUse else { return nil }
        return CaptureDeviceUsageSummary(
            isCameraInUseByAnotherApplication: cameraInUse,
            isMicrophoneInUseByAnotherApplication: microphoneInUse
        )
        #else
        return nil
        #endif
    }
}
#endif
