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
    private struct RememberedTextTarget {
        var element: AXUIElement
        var capturedAt: Date
    }

    private var lastNonLorreApplication: NSRunningApplication?
    private var rememberedTextTargets: [UUID: RememberedTextTarget] = [:]
    private var activationObserver: NSObjectProtocol?
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private let rememberedTextTargetMaxAge: TimeInterval = 300

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
        guard let focusedElement = focusedElement(for: targetApplication) else {
            return .noEditableTarget(appName: appName)
        }

        let targetValidation = validateTextTarget(focusedElement)
        switch targetValidation {
        case .editable:
            break
        case .secure:
            return .secureTarget(appName: appName)
        case .missing, .notEditable:
            guard Self.supportsPasteFallback(bundleIdentifier: targetApplication.bundleIdentifier) else {
                return .noEditableTarget(appName: appName)
            }
        }

        let accessibilityElementID: UUID?
        if case .editable = targetValidation {
            accessibilityElementID = rememberTextTarget(focusedElement)
        } else {
            accessibilityElementID = nil
        }
        return .ready(
            GlobalTextInsertionTarget(
                appName: appName,
                bundleIdentifier: targetApplication.bundleIdentifier,
                processIdentifier: targetApplication.processIdentifier,
                capturedAt: Date(),
                accessibilityElementID: accessibilityElementID
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
        let rememberedTextTarget = rememberedTextTarget(for: target)
        defer {
            forgetTextTarget(for: target)
        }

        raiseApplication(processIdentifier: target.processIdentifier)
        _ = application.activate(options: [.activateAllWindows])

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
            return .failed(code: "target_app_activation_failed", message: "Lorre could not return focus to \(target.displayName).")
        }

        let validation: FocusedTextTargetValidation
        if let rememberedTextTarget, isReachableAXElement(rememberedTextTarget) {
            if isSecureTextTarget(rememberedTextTarget) {
                validation = .secure
            } else {
                _ = restoreFocus(to: rememberedTextTarget, in: application)
                validation = .editable
            }
        } else {
            validation = validateFocusedTextTarget(for: application)
        }

        switch validation {
        case .editable:
            break
        case .secure:
            return .failed(
                code: "secure_target",
                message: GlobalTextInsertionPreparation.secureTarget(appName: target.displayName).userFacingMessage
            )
        case .missing, .notEditable:
            guard Self.supportsPasteFallback(bundleIdentifier: target.bundleIdentifier) else {
                return .failed(
                    code: "no_editable_target",
                    message: GlobalTextInsertionPreparation.noEditableTarget(appName: target.displayName).userFacingMessage
                )
            }
        }

        if let rememberedTextTarget,
           insertTextUsingAccessibility(text, into: rememberedTextTarget) {
            rememberTargetApplicationIfUsable(application)
            return .inserted
        }

        guard targetApplicationOwnsInputFocus(target) else {
            return .failed(code: "target_app_activation_failed", message: "Lorre could not return keyboard focus to \(target.displayName).")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard sendPasteCommand(to: target.processIdentifier) else {
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

    private func targetApplicationOwnsInputFocus(_ target: GlobalTextInsertionTarget) -> Bool {
        let processIdentifier = target.processIdentifier
        guard isApplicationFrontmost(processIdentifier: processIdentifier) else {
            return false
        }

        if let focusedApplicationProcessIdentifier,
           focusedApplicationProcessIdentifier != processIdentifier {
            return false
        }

        if let focusedBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let targetBundleIdentifier = target.bundleIdentifier,
           focusedBundleIdentifier != targetBundleIdentifier {
            return false
        }

        return true
    }

    private var focusedApplicationProcessIdentifier: pid_t? {
        let systemElement = AXUIElementCreateSystemWide()
        guard let focusedApplication = copyAXElement(
            from: systemElement,
            attribute: kAXFocusedApplicationAttribute
        ) else {
            return nil
        }
        return processIdentifier(of: focusedApplication)
    }

    private var focusedElementProcessIdentifier: pid_t? {
        let systemElement = AXUIElementCreateSystemWide()
        guard let focusedElement = copyAXElement(
            from: systemElement,
            attribute: kAXFocusedUIElementAttribute
        ) else {
            return nil
        }
        return processIdentifier(of: focusedElement)
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

    private static func supportsPasteFallback(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.tinyspeck.slackmacgap"
        ].contains(bundleIdentifier)
    }

    private func raiseApplication(processIdentifier: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementPerformAction(applicationElement, kAXRaiseAction as CFString)
    }

    private func rememberTextTarget(_ element: AXUIElement) -> UUID {
        cleanupRememberedTextTargets(now: Date())
        let id = UUID()
        rememberedTextTargets[id] = RememberedTextTarget(element: element, capturedAt: Date())
        return id
    }

    private func rememberedTextTarget(for target: GlobalTextInsertionTarget) -> AXUIElement? {
        guard let id = target.accessibilityElementID,
              let remembered = rememberedTextTargets[id]
        else {
            return nil
        }

        guard Date().timeIntervalSince(remembered.capturedAt) <= rememberedTextTargetMaxAge else {
            rememberedTextTargets[id] = nil
            return nil
        }

        return remembered.element
    }

    private func forgetTextTarget(for target: GlobalTextInsertionTarget) {
        guard let id = target.accessibilityElementID else { return }
        rememberedTextTargets[id] = nil
    }

    private func cleanupRememberedTextTargets(now: Date) {
        rememberedTextTargets = rememberedTextTargets.filter { _, remembered in
            now.timeIntervalSince(remembered.capturedAt) <= rememberedTextTargetMaxAge
        }
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
        return validateTextTarget(focusedElement)
    }

    private func validateTextTarget(_ element: AXUIElement) -> FocusedTextTargetValidation {
        let role = copyAXString(from: element, attribute: kAXRoleAttribute)
        let subrole = copyAXString(from: element, attribute: kAXSubroleAttribute)
        if isSecureTextTarget(role: role, subrole: subrole) {
            return .secure
        }
        if isEditableTextTarget(element, role: role, subrole: subrole) {
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

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private func isSecureTextTarget(role: String?, subrole: String?) -> Bool {
        let normalizedRole = role ?? ""
        let normalizedSubrole = subrole ?? ""
        return normalizedRole == "AXSecureTextField" || normalizedSubrole == "AXSecureTextField"
    }

    private func isSecureTextTarget(_ element: AXUIElement) -> Bool {
        isSecureTextTarget(
            role: copyAXString(from: element, attribute: kAXRoleAttribute),
            subrole: copyAXString(from: element, attribute: kAXSubroleAttribute)
        )
    }

    private func isReachableAXElement(_ element: AXUIElement) -> Bool {
        var attributeNames: CFArray?
        return AXUIElementCopyAttributeNames(element, &attributeNames) == .success
    }

    private func restoreFocus(to element: AXUIElement, in application: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var didRestore = false

        if AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        ) == .success {
            didRestore = true
        }

        if AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success {
            didRestore = true
        }

        return didRestore
    }

    private func insertTextUsingAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard !isSecureTextTarget(element) else {
            return false
        }

        if isAXAttributeSettable(element, attribute: kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
           ) == .success {
            return true
        }

        return replaceTextValueUsingAccessibility(text, in: element)
    }

    private func replaceTextValueUsingAccessibility(_ text: String, in element: AXUIElement) -> Bool {
        guard isAXAttributeSettable(element, attribute: kAXValueAttribute),
              let currentValue = copyAXString(from: element, attribute: kAXValueAttribute),
              let selectedRange = selectedTextRange(from: element)
        else {
            return false
        }

        let currentNSString = currentValue as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= currentNSString.length,
              selectedRange.location + selectedRange.length <= currentNSString.length
        else {
            return false
        }

        let updatedValue = NSMutableString(string: currentValue)
        updatedValue.replaceCharacters(
            in: NSRange(location: selectedRange.location, length: selectedRange.length),
            with: text
        )

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue.copy() as! CFString
        ) == .success else {
            return false
        }

        let insertedLength = (text as NSString).length
        _ = setSelectedTextRange(
            CFRange(location: selectedRange.location + insertedLength, length: 0),
            on: element
        )
        return true
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        guard isAXAttributeSettable(element, attribute: kAXSelectedTextRangeAttribute) else {
            return false
        }

        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
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
            || isAXAttributeSettable(element, attribute: kAXValueAttribute)
    }

    private func isAXAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func sendPasteCommand(to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
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
