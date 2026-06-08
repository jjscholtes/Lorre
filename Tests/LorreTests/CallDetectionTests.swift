import Foundation
import Testing
@testable import Lorre

@Suite("CallDetectionTests")
struct CallDetectionTests {
    private let enabledConfiguration = CallWatcherConfiguration(isEnabled: true)

    @Test
    func testKnownCommunicationAppWithCaptureDeviceUseEmitsAfterDebounce() async {
        let engine = CallDetectionEngine(debounceSeconds: 5)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = await engine.ingest(
            CallSignalSample(
                observedAt: start,
                frontmostBundleID: "us.zoom.xos",
                runningBundleIDs: ["us.zoom.xos"],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isCameraInUseByAnotherApplication: true,
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )
        XCTAssertNil(first)

        let second = await engine.ingest(
            CallSignalSample(
                observedAt: start.addingTimeInterval(6),
                frontmostBundleID: "us.zoom.xos",
                runningBundleIDs: ["us.zoom.xos"],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isCameraInUseByAnotherApplication: true,
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = second else {
            XCTFail("Expected a detected call candidate")
            return
        }
        XCTAssertEqual(candidate.appDisplayName, "Zoom")
        XCTAssertEqual(candidate.confidenceBand, .high)
        XCTAssertEqual(candidate.recommendedRecordingSource, .microphoneAndSystemAudio)
        XCTAssertTrue(candidate.reasons.contains(.knownCommunicationAppForeground))
        XCTAssertTrue(candidate.reasons.contains(.captureDeviceInUse))
    }

    @Test
    func testBrowserWithoutCallTitleDoesNotPrompt() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: "com.google.Chrome",
                runningBundleIDs: ["com.google.Chrome"]
            ),
            configuration: enabledConfiguration
        )

        XCTAssertNil(event)
    }

    @Test
    func testForegroundBrowserWithCaptureDeviceUseCanEmitWithoutCallTitle() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: "com.microsoft.edgemac",
                runningBundleIDs: ["com.microsoft.edgemac"],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = event else {
            XCTFail("Expected foreground browser capture device use to create a candidate")
            return
        }
        XCTAssertEqual(candidate.appDisplayName, "Microsoft Edge")
        XCTAssertEqual(candidate.confidenceBand, .high)
        XCTAssertTrue(candidate.reasons.contains(.captureDeviceInUse))
        XCTAssertFalse(candidate.reasons.contains(.browserCallWindowTitle))
    }

    @Test
    func testBackgroundBrowserWithCaptureDeviceUseDoesNotPromptWithoutCallTitle() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: "com.apple.finder",
                runningBundleIDs: ["com.microsoft.edgemac"],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        XCTAssertNil(event)
    }

    @Test
    func testBrowserCallTitleCanEmitCandidate() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: "com.google.Chrome",
                runningBundleIDs: ["com.google.Chrome"],
                windowTitleHints: [
                    WindowTitleHint(appBundleID: "com.google.Chrome", title: "Weekly sync - meet.google.com/abc-defg-hij")
                ]
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = event else {
            XCTFail("Expected browser call title to create a candidate")
            return
        }
        XCTAssertEqual(candidate.appDisplayName, "Google Chrome")
        XCTAssertTrue(candidate.reasons.contains(.browserCallWindowTitle))
    }

    @Test
    func testTeamsPWACallTitleCanEmitCandidate() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let teamsPWABundleID = "com.microsoft.edgemac.app.cifhbcnohmdccbgoicgdjpfamggdegmo"
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: teamsPWABundleID,
                frontmostAppName: "Microsoft Teams",
                runningBundleIDs: [teamsPWABundleID],
                windowTitleHints: [
                    WindowTitleHint(
                        appBundleID: teamsPWABundleID,
                        appDisplayName: "Microsoft Teams",
                        title: "Weekly sync | Microsoft Teams"
                    )
                ]
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = event else {
            XCTFail("Expected Teams PWA call title to create a candidate")
            return
        }
        XCTAssertEqual(candidate.appBundleID, teamsPWABundleID)
        XCTAssertEqual(candidate.appDisplayName, "Microsoft Teams")
        XCTAssertTrue(candidate.reasons.contains(.browserCallWindowTitle))
    }

    @Test
    func testForegroundTeamsPWAWithCaptureDeviceUseCanEmitWithoutCallTitle() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let teamsPWABundleID = "com.microsoft.edgemac.app.cifhbcnohmdccbgoicgdjpfamggdegmo"
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: teamsPWABundleID,
                frontmostAppName: "Microsoft Teams",
                runningBundleIDs: [teamsPWABundleID],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = event else {
            XCTFail("Expected foreground Teams PWA capture device use to create a candidate")
            return
        }
        XCTAssertEqual(candidate.appBundleID, teamsPWABundleID)
        XCTAssertEqual(candidate.appDisplayName, "Microsoft Teams")
        XCTAssertTrue(candidate.reasons.contains(.captureDeviceInUse))
    }

    @Test
    func testMediaAppWithDeviceUseDoesNotPrompt() async {
        let engine = CallDetectionEngine(debounceSeconds: 0)
        let event = await engine.ingest(
            CallSignalSample(
                observedAt: Date(timeIntervalSince1970: 1_000),
                frontmostBundleID: "com.spotify.client",
                runningBundleIDs: ["com.spotify.client"],
                microphoneActivity: AudioActivitySummary(isSustained: true),
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isCameraInUseByAnotherApplication: true,
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        XCTAssertNil(event)
    }

    @Test
    func testCandidateEndsAfterGracePeriodWithoutSignal() async {
        let engine = CallDetectionEngine(debounceSeconds: 0, endGraceSeconds: 20)
        let start = Date(timeIntervalSince1970: 1_000)

        let detected = await engine.ingest(
            CallSignalSample(
                observedAt: start,
                frontmostBundleID: "us.zoom.xos",
                runningBundleIDs: ["us.zoom.xos"],
                captureDeviceUsage: CaptureDeviceUsageSummary(
                    isCameraInUseByAnotherApplication: true,
                    isMicrophoneInUseByAnotherApplication: true
                )
            ),
            configuration: enabledConfiguration
        )

        guard case let .candidateDetected(candidate) = detected else {
            XCTFail("Expected a detected candidate")
            return
        }

        let ended = await engine.ingest(
            CallSignalSample(observedAt: start.addingTimeInterval(25)),
            configuration: enabledConfiguration
        )

        XCTAssertEqual(ended, .candidateEnded(fingerprint: candidate.fingerprint))
    }

    @Test
    func testPromptCoordinatorSuppressesRecordingRepeatAndDismissedCandidates() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "us.zoom.xos:3",
            appBundleID: "us.zoom.xos",
            appDisplayName: "Zoom",
            confidenceScore: 95,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now,
            lastSeenAt: now,
            reasons: [.knownCommunicationAppForeground, .captureDeviceInUse]
        )
        let coordinator = CallPromptCoordinator(candidateFreshnessSeconds: 30)

        let whileRecording = await coordinator.shouldPrompt(for: candidate, now: now, isRecording: true)
        XCTAssertFalse(whileRecording)

        let firstPrompt = await coordinator.shouldPrompt(for: candidate, now: now, isRecording: false)
        XCTAssertTrue(firstPrompt)

        let repeatedPrompt = await coordinator.shouldPrompt(for: candidate, now: now.addingTimeInterval(1), isRecording: false)
        XCTAssertFalse(repeatedPrompt)

        await coordinator.dismiss(candidate: candidate, now: now.addingTimeInterval(2), cooldownSeconds: 600)
        let dismissedPrompt = await coordinator.shouldPrompt(for: candidate, now: now.addingTimeInterval(30), isRecording: false)
        XCTAssertFalse(dismissedPrompt)

        await coordinator.resetWhenSignalEnded(fingerprint: candidate.fingerprint)
        let nextCallStartedAt = now.addingTimeInterval(31)
        let nextCandidate = CallDetectionCandidate(
            fingerprint: candidate.fingerprint,
            appBundleID: candidate.appBundleID,
            appDisplayName: candidate.appDisplayName,
            confidenceScore: candidate.confidenceScore,
            recommendedRecordingSource: candidate.recommendedRecordingSource,
            firstDetectedAt: nextCallStartedAt,
            lastSeenAt: nextCallStartedAt,
            reasons: candidate.reasons
        )
        let nextCallPromptDuringCooldown = await coordinator.shouldPrompt(
            for: nextCandidate,
            now: nextCallStartedAt,
            isRecording: false
        )
        XCTAssertFalse(nextCallPromptDuringCooldown)

        let postCooldownCallStartedAt = now.addingTimeInterval(603)
        let postCooldownCandidate = CallDetectionCandidate(
            fingerprint: candidate.fingerprint,
            appBundleID: candidate.appBundleID,
            appDisplayName: candidate.appDisplayName,
            confidenceScore: candidate.confidenceScore,
            recommendedRecordingSource: candidate.recommendedRecordingSource,
            firstDetectedAt: postCooldownCallStartedAt,
            lastSeenAt: postCooldownCallStartedAt,
            reasons: candidate.reasons
        )
        let nextCallPromptAfterCooldown = await coordinator.shouldPrompt(
            for: postCooldownCandidate,
            now: postCooldownCallStartedAt,
            isRecording: false
        )
        XCTAssertTrue(nextCallPromptAfterCooldown)
    }

    @Test
    func testPromptCoordinatorRejectsStaleCandidate() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = CallDetectionCandidate(
            fingerprint: "us.zoom.xos:3",
            appBundleID: "us.zoom.xos",
            appDisplayName: "Zoom",
            confidenceScore: 95,
            recommendedRecordingSource: .microphoneAndSystemAudio,
            firstDetectedAt: now.addingTimeInterval(-60),
            lastSeenAt: now.addingTimeInterval(-60),
            reasons: [.knownCommunicationAppForeground, .captureDeviceInUse]
        )
        let coordinator = CallPromptCoordinator(candidateFreshnessSeconds: 30)

        let shouldPrompt = await coordinator.shouldPrompt(for: candidate, now: now, isRecording: false)
        XCTAssertFalse(shouldPrompt)
    }
}
