import Foundation
#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

struct DisabledCallPromptNotificationService: CallPromptNotificationService {
    func requestAuthorizationIfNeeded() async -> Bool {
        false
    }

    func showCallPrompt(for candidate: CallDetectionCandidate) async -> Bool {
        _ = candidate
        return false
    }

    func removeCallPrompt(fingerprint: String) async {
        _ = fingerprint
    }

    func makeActionStream() async -> AsyncStream<CallPromptNotificationAction> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

#if canImport(UserNotifications)
final class MacCallPromptNotificationService: NSObject, CallPromptNotificationService, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let categoryIdentifier = "lorre.call-prompt"
    private static let acceptActionIdentifier = "lorre.call-prompt.accept"
    private static let dismissActionIdentifier = "lorre.call-prompt.dismiss"
    private static let disableActionIdentifier = "lorre.call-prompt.disable"
    private static let fingerprintUserInfoKey = "fingerprint"

    private let center: UNUserNotificationCenter
    private let stateQueue = DispatchQueue(label: "app.lorre.call-prompt-notifications")
    private var actionContinuation: AsyncStream<CallPromptNotificationAction>.Continuation?
    private var queuedActions: [CallPromptNotificationAction] = []

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        configureCategories()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func showCallPrompt(for candidate: CallDetectionCandidate) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let identifier = Self.notificationIdentifier(for: candidate.fingerprint)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Wil je opnemen?"
        content.body = "Lorre ziet waarschijnlijk een gesprek in \(candidate.appDisplayName)."
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "lorre.call-watcher"
        content.userInfo = [Self.fingerprintUserInfoKey: candidate.fingerprint]
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        return await add(request)
    }

    func removeCallPrompt(fingerprint: String) async {
        let identifier = Self.notificationIdentifier(for: fingerprint)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func makeActionStream() async -> AsyncStream<CallPromptNotificationAction> {
        AsyncStream { continuation in
            stateQueue.async {
                self.actionContinuation = continuation
                self.queuedActions.forEach { continuation.yield($0) }
                self.queuedActions.removeAll()
            }
            continuation.onTermination = { [weak self] _ in
                self?.clearActionContinuation()
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.notification.request.content.categoryIdentifier == Self.categoryIdentifier,
              let fingerprint = response.notification.request.content.userInfo[Self.fingerprintUserInfoKey] as? String
        else {
            return
        }

        switch response.actionIdentifier {
        case Self.acceptActionIdentifier:
            enqueue(.accept(fingerprint: fingerprint))
        case Self.dismissActionIdentifier, UNNotificationDismissActionIdentifier:
            enqueue(.dismiss(fingerprint: fingerprint))
        case Self.disableActionIdentifier:
            enqueue(.disable(fingerprint: fingerprint))
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.categoryIdentifier == Self.categoryIdentifier else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    private func configureCategories() {
        let accept = UNNotificationAction(
            identifier: Self.acceptActionIdentifier,
            title: "Opnemen",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionIdentifier,
            title: "Niet nu",
            options: []
        )
        let disable = UNNotificationAction(
            identifier: Self.disableActionIdentifier,
            title: "Uitschakelen",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [accept, dismiss, disable],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    private func enqueue(_ action: CallPromptNotificationAction) {
        stateQueue.async {
            if let actionContinuation = self.actionContinuation {
                actionContinuation.yield(action)
            } else {
                self.queuedActions.append(action)
            }
        }
    }

    private func clearActionContinuation() {
        stateQueue.async {
            self.actionContinuation = nil
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func notificationIdentifier(for fingerprint: String) -> String {
        "lorre.call-prompt.\(fingerprint)"
    }
}
#endif
