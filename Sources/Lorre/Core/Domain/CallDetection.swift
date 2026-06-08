import Foundation

struct CallWatcherConfiguration: Codable, Equatable, Sendable {
    static let minimumCooldownSeconds = 60
    static let maximumCooldownSeconds = 3_600

    var isEnabled: Bool
    var defaultRecordingSource: RecordingSource
    var cooldownSeconds: Int

    init(
        isEnabled: Bool = false,
        defaultRecordingSource: RecordingSource = .microphoneAndSystemAudio,
        cooldownSeconds: Int = 600
    ) {
        self.isEnabled = isEnabled
        self.defaultRecordingSource = defaultRecordingSource
        self.cooldownSeconds = Self.normalizedCooldownSeconds(cooldownSeconds)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.defaultRecordingSource = try container.decodeIfPresent(
            RecordingSource.self,
            forKey: .defaultRecordingSource
        ) ?? .microphoneAndSystemAudio
        self.cooldownSeconds = Self.normalizedCooldownSeconds(
            try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 600
        )
    }

    private static func normalizedCooldownSeconds(_ value: Int) -> Int {
        min(max(value, minimumCooldownSeconds), maximumCooldownSeconds)
    }
}

enum CallDetectionConfidenceBand: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high

    static func band(for score: Int) -> CallDetectionConfidenceBand {
        if score >= 70 { return .high }
        if score >= 45 { return .medium }
        return .low
    }
}

enum CallDetectionReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case knownCommunicationAppForeground
    case knownCommunicationAppRunning
    case callLikeWindowTitle
    case browserCallWindowTitle
    case captureDeviceInUse
    case sustainedMicrophoneActivity
}

struct WindowTitleHint: Equatable, Sendable {
    var appBundleID: String?
    var appDisplayName: String?
    var title: String

    init(appBundleID: String? = nil, appDisplayName: String? = nil, title: String) {
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.title = title
    }
}

struct AudioActivitySummary: Equatable, Sendable {
    var isSustained: Bool

    init(isSustained: Bool) {
        self.isSustained = isSustained
    }
}

struct CaptureDeviceUsageSummary: Equatable, Sendable {
    var isCameraInUseByAnotherApplication: Bool
    var isMicrophoneInUseByAnotherApplication: Bool

    init(
        isCameraInUseByAnotherApplication: Bool = false,
        isMicrophoneInUseByAnotherApplication: Bool = false
    ) {
        self.isCameraInUseByAnotherApplication = isCameraInUseByAnotherApplication
        self.isMicrophoneInUseByAnotherApplication = isMicrophoneInUseByAnotherApplication
    }

    var isAnyDeviceInUse: Bool {
        isCameraInUseByAnotherApplication || isMicrophoneInUseByAnotherApplication
    }

    var isCameraAndMicrophoneInUse: Bool {
        isCameraInUseByAnotherApplication && isMicrophoneInUseByAnotherApplication
    }
}

struct CallSignalSample: Equatable, Sendable {
    var observedAt: Date
    var frontmostBundleID: String?
    var frontmostAppName: String?
    var runningBundleIDs: [String]
    var windowTitleHints: [WindowTitleHint]
    var microphoneActivity: AudioActivitySummary?
    var captureDeviceUsage: CaptureDeviceUsageSummary?

    init(
        observedAt: Date = Date(),
        frontmostBundleID: String? = nil,
        frontmostAppName: String? = nil,
        runningBundleIDs: [String] = [],
        windowTitleHints: [WindowTitleHint] = [],
        microphoneActivity: AudioActivitySummary? = nil,
        captureDeviceUsage: CaptureDeviceUsageSummary? = nil
    ) {
        self.observedAt = observedAt
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppName = frontmostAppName
        self.runningBundleIDs = runningBundleIDs
        self.windowTitleHints = windowTitleHints
        self.microphoneActivity = microphoneActivity
        self.captureDeviceUsage = captureDeviceUsage
    }
}

struct CallDetectionCandidate: Identifiable, Equatable, Sendable {
    var id: UUID
    var fingerprint: String
    var appBundleID: String?
    var appDisplayName: String
    var confidenceScore: Int
    var confidenceBand: CallDetectionConfidenceBand
    var recommendedRecordingSource: RecordingSource
    var firstDetectedAt: Date
    var lastSeenAt: Date
    var reasons: [CallDetectionReason]

    init(
        id: UUID = UUID(),
        fingerprint: String,
        appBundleID: String?,
        appDisplayName: String,
        confidenceScore: Int,
        recommendedRecordingSource: RecordingSource,
        firstDetectedAt: Date,
        lastSeenAt: Date,
        reasons: [CallDetectionReason]
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.confidenceScore = confidenceScore
        self.confidenceBand = CallDetectionConfidenceBand.band(for: confidenceScore)
        self.recommendedRecordingSource = recommendedRecordingSource
        self.firstDetectedAt = firstDetectedAt
        self.lastSeenAt = lastSeenAt
        self.reasons = reasons
    }
}

enum CallDetectionEvent: Equatable, Sendable {
    case candidateDetected(CallDetectionCandidate)
    case candidateEnded(fingerprint: String)
}

actor CallDetectionEngine {
    private struct AppRule: Sendable {
        enum Category: Sendable {
            case communication
            case browser
            case media
        }

        var bundleID: String
        var displayName: String
        var category: Category
    }

    private struct ScoredSignal: Sendable {
        var key: String
        var bundleID: String?
        var displayName: String
        var score: Int
        var reasons: [CallDetectionReason]
    }

    private struct TrackedCandidate: Sendable {
        var id: UUID
        var fingerprint: String
        var key: String
        var appBundleID: String?
        var appDisplayName: String
        var firstDetectedAt: Date
        var lastSeenAt: Date
        var bestScore: Int
        var reasons: Set<CallDetectionReason>
        var hasEmittedStart: Bool
    }

    private let promptThreshold: Int
    private let endThreshold: Int
    private let debounceSeconds: TimeInterval
    private let endGraceSeconds: TimeInterval
    private let appRulesByBundleID: [String: AppRule]
    private var trackedCandidates: [String: TrackedCandidate] = [:]

    init(
        promptThreshold: Int = 70,
        endThreshold: Int = 45,
        debounceSeconds: TimeInterval = 5,
        endGraceSeconds: TimeInterval = 20
    ) {
        self.promptThreshold = promptThreshold
        self.endThreshold = endThreshold
        self.debounceSeconds = debounceSeconds
        self.endGraceSeconds = endGraceSeconds
        self.appRulesByBundleID = Dictionary(
            uniqueKeysWithValues: Self.defaultAppRules.map { ($0.bundleID.lowercased(), $0) }
        )
    }

    func ingest(
        _ sample: CallSignalSample,
        configuration: CallWatcherConfiguration
    ) -> CallDetectionEvent? {
        guard configuration.isEnabled else {
            trackedCandidates.removeAll()
            return nil
        }

        let scoredSignal = score(sample)
        if let event = updateTrackedCandidate(
            with: scoredSignal,
            sample: sample,
            configuration: configuration
        ) {
            return event
        }

        return expireStaleCandidate(at: sample.observedAt)
    }

    private func updateTrackedCandidate(
        with scoredSignal: ScoredSignal?,
        sample: CallSignalSample,
        configuration: CallWatcherConfiguration
    ) -> CallDetectionEvent? {
        guard let scoredSignal else { return nil }
        guard scoredSignal.score >= endThreshold else { return nil }

        let now = sample.observedAt
        var tracked = trackedCandidates[scoredSignal.key] ?? TrackedCandidate(
            id: UUID(),
            fingerprint: Self.makeFingerprint(key: scoredSignal.key, firstDetectedAt: now),
            key: scoredSignal.key,
            appBundleID: scoredSignal.bundleID,
            appDisplayName: scoredSignal.displayName,
            firstDetectedAt: now,
            lastSeenAt: now,
            bestScore: scoredSignal.score,
            reasons: Set(scoredSignal.reasons),
            hasEmittedStart: false
        )

        tracked.lastSeenAt = now
        tracked.bestScore = max(tracked.bestScore, scoredSignal.score)
        tracked.reasons.formUnion(scoredSignal.reasons)
        trackedCandidates[scoredSignal.key] = tracked

        let persistedLongEnough = now.timeIntervalSince(tracked.firstDetectedAt) >= debounceSeconds
        guard !tracked.hasEmittedStart, tracked.bestScore >= promptThreshold, persistedLongEnough else {
            return nil
        }

        tracked.hasEmittedStart = true
        trackedCandidates[scoredSignal.key] = tracked
        return .candidateDetected(
            CallDetectionCandidate(
                id: tracked.id,
                fingerprint: tracked.fingerprint,
                appBundleID: tracked.appBundleID,
                appDisplayName: tracked.appDisplayName,
                confidenceScore: tracked.bestScore,
                recommendedRecordingSource: configuration.defaultRecordingSource,
                firstDetectedAt: tracked.firstDetectedAt,
                lastSeenAt: tracked.lastSeenAt,
                reasons: Self.sortedReasons(tracked.reasons)
            )
        )
    }

    private func expireStaleCandidate(at now: Date) -> CallDetectionEvent? {
        guard let stale = trackedCandidates.values
            .sorted(by: { $0.firstDetectedAt < $1.firstDetectedAt })
            .first(where: { now.timeIntervalSince($0.lastSeenAt) >= endGraceSeconds })
        else {
            return nil
        }

        trackedCandidates[stale.key] = nil
        return .candidateEnded(fingerprint: stale.fingerprint)
    }

    private func score(_ sample: CallSignalSample) -> ScoredSignal? {
        let frontmostRule = rule(for: sample.frontmostBundleID, appDisplayName: sample.frontmostAppName)
        let runningRule = sample.runningBundleIDs.compactMap(rule(for:)).first
        let titleMatch = bestTitleMatch(in: sample.windowTitleHints, frontmostRule: frontmostRule, runningRule: runningRule)

        let selectedRule = frontmostRule ?? titleMatch?.rule ?? runningRule
        guard let selectedRule else { return nil }
        guard selectedRule.category != .media else { return nil }

        var score = 0
        var reasons: [CallDetectionReason] = []

        switch selectedRule.category {
        case .communication:
            if Self.isSameRule(frontmostRule, selectedRule) {
                score += 50
                reasons.append(.knownCommunicationAppForeground)
            } else {
                score += 25
                reasons.append(.knownCommunicationAppRunning)
            }
        case .browser:
            score += 5
        case .media:
            return nil
        }

        if let titleMatch {
            score += titleMatch.reason == .browserCallWindowTitle ? 75 : 40
            reasons.append(titleMatch.reason)
        }

        if let captureDeviceUsage = sample.captureDeviceUsage, captureDeviceUsage.isAnyDeviceInUse {
            let isForegroundBrowser = selectedRule.category == .browser
                && Self.isSameRule(frontmostRule, selectedRule)
            if isForegroundBrowser {
                // Browser tabs often hide call details from CGWindow unless Screen Recording is allowed.
                score += captureDeviceUsage.isCameraAndMicrophoneInUse ? 85 : 70
            } else {
                score += captureDeviceUsage.isCameraAndMicrophoneInUse ? 45 : 25
            }
            reasons.append(.captureDeviceInUse)
        }

        if sample.microphoneActivity?.isSustained == true {
            score += 10
            reasons.append(.sustainedMicrophoneActivity)
        }

        let key = selectedRule.bundleID.lowercased()
        return ScoredSignal(
            key: key,
            bundleID: selectedRule.bundleID,
            displayName: selectedRule.displayName,
            score: min(score, 100),
            reasons: Self.uniqueReasons(reasons)
        )
    }

    private func bestTitleMatch(
        in hints: [WindowTitleHint],
        frontmostRule: AppRule?,
        runningRule: AppRule?
    ) -> (rule: AppRule, reason: CallDetectionReason)? {
        for hint in hints where Self.isCallLikeTitle(hint.title) {
            if let rule = rule(for: hint.appBundleID, appDisplayName: hint.appDisplayName) {
                let reason: CallDetectionReason = rule.category == .browser ? .browserCallWindowTitle : .callLikeWindowTitle
                return (rule, reason)
            }
            if let frontmostRule, frontmostRule.category == .browser {
                return (frontmostRule, .browserCallWindowTitle)
            }
            if let runningRule, runningRule.category == .browser {
                return (runningRule, .browserCallWindowTitle)
            }
        }
        return nil
    }

    private func rule(for bundleID: String?) -> AppRule? {
        rule(for: bundleID, appDisplayName: nil)
    }

    private func rule(for bundleID: String?, appDisplayName: String?) -> AppRule? {
        guard let bundleID else { return nil }
        if let rule = appRulesByBundleID[bundleID.lowercased()] {
            return rule
        }
        guard Self.isBrowserWebAppBundleID(bundleID) else { return nil }
        return AppRule(
            bundleID: bundleID,
            displayName: Self.browserWebAppDisplayName(appDisplayName: appDisplayName),
            category: .browser
        )
    }

    private static func isSameRule(_ lhs: AppRule?, _ rhs: AppRule) -> Bool {
        lhs?.bundleID.lowercased() == rhs.bundleID.lowercased()
    }

    private static func isBrowserWebAppBundleID(_ bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return [
            "com.microsoft.edgemac.app.",
            "com.google.chrome.app.",
            "org.chromium.chromium.app.",
            "com.brave.browser.app.",
            "com.apple.safari.webapp."
        ].contains { normalized.hasPrefix($0) }
    }

    private static func browserWebAppDisplayName(appDisplayName: String?) -> String {
        let trimmed = appDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Browser Web App" : trimmed
    }

    private static func isCallLikeTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return [
            "meet.google.com",
            "google meet",
            "zoom meeting",
            "microsoft teams",
            "teams.microsoft.com",
            "teams meeting",
            "webex",
            "whereby",
            "slack huddle",
            "discord call"
        ].contains { normalized.contains($0) }
    }

    private static func makeFingerprint(key: String, firstDetectedAt: Date) -> String {
        let bucket = Int(firstDetectedAt.timeIntervalSince1970 / 300)
        return "\(key):\(bucket)"
    }

    private static func uniqueReasons(_ reasons: [CallDetectionReason]) -> [CallDetectionReason] {
        sortedReasons(Set(reasons))
    }

    private static func sortedReasons(_ reasons: Set<CallDetectionReason>) -> [CallDetectionReason] {
        CallDetectionReason.allCases.filter { reasons.contains($0) }
    }

    private static let defaultAppRules: [AppRule] = [
        AppRule(bundleID: "com.apple.FaceTime", displayName: "FaceTime", category: .communication),
        AppRule(bundleID: "us.zoom.xos", displayName: "Zoom", category: .communication),
        AppRule(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams", category: .communication),
        AppRule(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", category: .communication),
        AppRule(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", category: .communication),
        AppRule(bundleID: "com.hnc.Discord", displayName: "Discord", category: .communication),
        AppRule(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex", category: .communication),
        AppRule(bundleID: "com.google.Chrome", displayName: "Google Chrome", category: .browser),
        AppRule(bundleID: "com.apple.Safari", displayName: "Safari", category: .browser),
        AppRule(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", category: .browser),
        AppRule(bundleID: "org.mozilla.firefox", displayName: "Firefox", category: .browser),
        AppRule(bundleID: "com.spotify.client", displayName: "Spotify", category: .media),
        AppRule(bundleID: "com.apple.Music", displayName: "Music", category: .media),
        AppRule(bundleID: "com.apple.TV", displayName: "TV", category: .media)
    ]
}

actor CallPromptCoordinator {
    private let candidateFreshnessSeconds: TimeInterval
    private var promptedFingerprints: Set<String> = []
    private var dismissedUntil: [String: Date] = [:]

    init(candidateFreshnessSeconds: TimeInterval = 30) {
        self.candidateFreshnessSeconds = candidateFreshnessSeconds
    }

    func shouldPrompt(for candidate: CallDetectionCandidate, now: Date, isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        guard now.timeIntervalSince(candidate.lastSeenAt) <= candidateFreshnessSeconds else { return false }

        if let dismissedUntilDate = dismissedUntil[candidate.fingerprint] {
            if dismissedUntilDate > now {
                return false
            }
            dismissedUntil[candidate.fingerprint] = nil
        }

        guard !promptedFingerprints.contains(candidate.fingerprint) else { return false }
        promptedFingerprints.insert(candidate.fingerprint)
        return true
    }

    func dismiss(candidate: CallDetectionCandidate, now: Date, cooldownSeconds: Int) {
        let normalizedCooldown = CallWatcherConfiguration(
            isEnabled: true,
            cooldownSeconds: cooldownSeconds
        ).cooldownSeconds
        dismissedUntil[candidate.fingerprint] = now.addingTimeInterval(TimeInterval(normalizedCooldown))
    }

    func resetWhenSignalEnded(fingerprint: String) {
        promptedFingerprints.remove(fingerprint)
    }
}
