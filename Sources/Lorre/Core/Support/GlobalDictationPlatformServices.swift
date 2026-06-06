import Foundation

#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

#if canImport(Carbon)
import Carbon
#endif

#if canImport(AppKit) && canImport(Carbon)
final class CarbonGlobalDictationHotKeyService: GlobalDictationHotKeyService, @unchecked Sendable {
    private static let signature: OSType = 0x4C724744 // LrGD

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (@MainActor @Sendable () -> Void)?

    func register(
        shortcut: GlobalDictationShortcutChoice,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            unregister()
            throw LorreError.persistenceFailed("Could not install the global dictation shortcut handler.")
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.carbonKeyCode,
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw LorreError.persistenceFailed("The global dictation shortcut \(shortcut.label) could not be registered. Choose another shortcut or close the app using it.")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }

    private static let eventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let service = Unmanaged<CarbonGlobalDictationHotKeyService>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            service.handler?()
        }
        return noErr
    }
}

private extension GlobalDictationShortcutChoice {
    var carbonKeyCode: UInt32 {
        switch self {
        case .optionShiftD, .commandOptionShiftD, .controlOptionD, .controlOptionCommandD:
            return 2
        case .optionShiftSpace, .controlOptionSpace:
            return 49
        }
    }

    var carbonModifierFlags: UInt32 {
        switch self {
        case .optionShiftD, .optionShiftSpace:
            return UInt32(optionKey | shiftKey)
        case .commandOptionShiftD:
            return UInt32(cmdKey | optionKey | shiftKey)
        case .controlOptionD, .controlOptionSpace:
            return UInt32(controlKey | optionKey)
        case .controlOptionCommandD:
            return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}
#endif

#if canImport(AppKit)
final class MacGlobalTextInsertionService: GlobalTextInsertionService, @unchecked Sendable {
    private var lastNonLorreApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    init() {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if let frontmostApplication,
           Self.isUsableTargetApplication(
            frontmostApplication,
            ownBundleIdentifier: ownBundleIdentifier,
            ownProcessIdentifier: ownProcessIdentifier
           ) {
            lastNonLorreApplication = frontmostApplication
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.rememberTargetApplicationIfUsable(application)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    @MainActor
    func prepareTarget(promptForPermission: Bool) -> GlobalTextInsertionPreparation {
        guard isAccessibilityTrusted(promptForPermission: promptForPermission) else {
            return .missingAccessibilityPermission
        }

        guard let targetApplication = currentTargetApplication() else {
            return .noEditableTarget(appName: nil)
        }

        let appName = targetApplication.localizedName ?? "Focused app"
        switch validateFocusedTextTarget(for: targetApplication) {
        case .editable:
            break
        case .secure:
            return .secureTarget(appName: appName)
        case .missing, .notEditable:
            return .noEditableTarget(appName: appName)
        }

        return .ready(
            GlobalTextInsertionTarget(
                appName: appName,
                bundleIdentifier: targetApplication.bundleIdentifier,
                processIdentifier: targetApplication.processIdentifier,
                capturedAt: Date()
            )
        )
    }

    @MainActor
    func insert(_ text: String, into target: GlobalTextInsertionTarget) async -> GlobalTextInsertionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(code: "empty_text", message: "There is no dictated text to insert.")
        }
        guard isAccessibilityTrusted(promptForPermission: false) else {
            return .failed(
                code: "missing_accessibility_permission",
                message: GlobalTextInsertionPreparation.missingAccessibilityPermission.userFacingMessage
            )
        }

        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return .failed(code: "target_app_unavailable", message: "\(target.displayName) is no longer available.")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        raiseApplication(processIdentifier: target.processIdentifier)
        _ = application.activate(options: [])

        let startActivate = Date()
        var isFrontmost = false
        while Date().timeIntervalSince(startActivate) < 1.0 {
            if isApplicationFrontmost(processIdentifier: target.processIdentifier) {
                isFrontmost = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Give the target app a brief moment to focus its text field
        try? await Task.sleep(for: .milliseconds(150))

        guard isFrontmost || isApplicationFrontmost(processIdentifier: target.processIdentifier) else {
            snapshot.restore(to: pasteboard)
            return .failed(code: "target_app_activation_failed", message: "Lorre could not return focus to \(target.displayName).")
        }

        switch validateFocusedTextTarget(for: application) {
        case .editable:
            break
        case .secure:
            snapshot.restore(to: pasteboard)
            return .failed(
                code: "secure_target",
                message: GlobalTextInsertionPreparation.secureTarget(appName: target.displayName).userFacingMessage
            )
        case .missing, .notEditable:
            snapshot.restore(to: pasteboard)
            return .failed(
                code: "no_editable_target",
                message: GlobalTextInsertionPreparation.noEditableTarget(appName: target.displayName).userFacingMessage
            )
        }

        guard sendPasteCommand() else {
            snapshot.restore(to: pasteboard)
            return .failed(code: "paste_event_failed", message: "Lorre could not send the paste command to \(target.displayName).")
        }

        rememberTargetApplicationIfUsable(application)
        try? await Task.sleep(for: .milliseconds(900))
        snapshot.restore(to: pasteboard)
        return .inserted
    }

    @MainActor
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func isAccessibilityTrusted(promptForPermission: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": promptForPermission] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func currentTargetApplication() -> NSRunningApplication? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           Self.isUsableTargetApplication(
            frontmostApplication,
            ownBundleIdentifier: ownBundleIdentifier,
            ownProcessIdentifier: ownProcessIdentifier
           ) {
            rememberTargetApplicationIfUsable(frontmostApplication)
            return frontmostApplication
        }

        if let lastNonLorreApplication,
           Self.isUsableTargetApplication(
            lastNonLorreApplication,
            ownBundleIdentifier: ownBundleIdentifier,
            ownProcessIdentifier: ownProcessIdentifier
           ) {
            return lastNonLorreApplication
        }

        return nil
    }

    private func rememberTargetApplicationIfUsable(_ application: NSRunningApplication) {
        guard Self.isUsableTargetApplication(
            application,
            ownBundleIdentifier: ownBundleIdentifier,
            ownProcessIdentifier: ownProcessIdentifier
        ) else {
            return
        }
        lastNonLorreApplication = application
    }

    private func isFrontmostApplication(_ application: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func isApplicationFrontmost(processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    private static func isUsableTargetApplication(
        _ application: NSRunningApplication,
        ownBundleIdentifier: String?,
        ownProcessIdentifier: Int32
    ) -> Bool {
        if application.isTerminated {
            return false
        }
        if application.processIdentifier == ownProcessIdentifier {
            return false
        }
        if let ownBundleIdentifier,
           application.bundleIdentifier == ownBundleIdentifier {
            return false
        }
        return application.activationPolicy != .prohibited
    }

    private func raiseApplication(processIdentifier: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementPerformAction(applicationElement, kAXRaiseAction as CFString)
    }

    private enum FocusedTextTargetValidation {
        case editable
        case secure
        case missing
        case notEditable
    }

    private func validateFocusedTextTarget(for application: NSRunningApplication) -> FocusedTextTargetValidation {
        guard let focusedElement = focusedElement(for: application) else {
            return .missing
        }

        let role = copyAXString(from: focusedElement, attribute: kAXRoleAttribute)
        let subrole = copyAXString(from: focusedElement, attribute: kAXSubroleAttribute)
        if isSecureTextTarget(role: role, subrole: subrole) {
            return .secure
        }
        if isEditableTextTarget(focusedElement, role: role, subrole: subrole) {
            return .editable
        }
        return .notEditable
    }

    private func focusedElement(for application: NSRunningApplication) -> AXUIElement? {
        if isFrontmostApplication(application) {
            let systemElement = AXUIElementCreateSystemWide()
            if let focusedElement = copyAXElement(
                from: systemElement,
                attribute: kAXFocusedUIElementAttribute
            ) {
                return focusedElement
            }
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return copyAXElement(from: applicationElement, attribute: kAXFocusedUIElementAttribute)
    }

    private func copyAXElement(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyAXString(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func isSecureTextTarget(role: String?, subrole: String?) -> Bool {
        let normalizedRole = role ?? ""
        let normalizedSubrole = subrole ?? ""
        return normalizedRole == "AXSecureTextField" || normalizedSubrole == "AXSecureTextField"
    }

    private func isEditableTextTarget(_ element: AXUIElement, role: String?, subrole: String?) -> Bool {
        let normalizedRole = role ?? ""
        let normalizedSubrole = subrole ?? ""
        let editableRoles: Set<String> = [
            "AXTextArea",
            "AXTextField",
            "AXComboBox",
            "AXSearchField"
        ]

        if editableRoles.contains(normalizedRole) || editableRoles.contains(normalizedSubrole) {
            return true
        }

        return isAXAttributeSettable(element, attribute: kAXSelectedTextAttribute)
            || isAXAttributeSettable(element, attribute: kAXSelectedTextRangeAttribute)
    }

    private func isAXAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func sendPasteCommand() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

}

private struct PasteboardSnapshot {
    struct Representation {
        var type: NSPasteboard.PasteboardType
        var data: Data
    }

    struct Item {
        var representations: [Representation]
    }

    var items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.compactMap { item -> Item? in
            let representations = item.types.compactMap { type -> Representation? in
                guard let data = item.data(forType: type) else { return nil }
                return Representation(type: type, data: data)
            }
            return representations.isEmpty ? nil : Item(representations: representations)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                pasteboardItem.setData(representation.data, forType: representation.type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
#endif

final class DisabledGlobalDictationHotKeyService: GlobalDictationHotKeyService, @unchecked Sendable {
    func register(
        shortcut: GlobalDictationShortcutChoice,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {
        _ = shortcut
        _ = handler
        throw LorreError.persistenceFailed("Global shortcuts are unavailable in this build.")
    }

    func unregister() {}
}

struct DisabledGlobalTextInsertionService: GlobalTextInsertionService {
    func prepareTarget(promptForPermission: Bool) -> GlobalTextInsertionPreparation {
        _ = promptForPermission
        return .unsupportedPlatform
    }

    func insert(_ text: String, into target: GlobalTextInsertionTarget) async -> GlobalTextInsertionResult {
        _ = text
        _ = target
        return .failed(code: "unsupported_platform", message: "Global dictation insertion is unavailable in this build.")
    }

    func copyToClipboard(_ text: String) {
        _ = text
    }
}
