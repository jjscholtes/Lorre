import Foundation

enum GlobalDictationShortcutChoice: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case controlOptionD
    case controlOptionSpace
    case controlOptionCommandD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionD:
            return "Control-Option-D"
        case .controlOptionSpace:
            return "Control-Option-Space"
        case .controlOptionCommandD:
            return "Control-Option-Command-D"
        }
    }

    var detail: String {
        switch self {
        case .controlOptionD:
            return "Default global dictation shortcut."
        case .controlOptionSpace:
            return "Compact shortcut, but more likely to conflict with launchers."
        case .controlOptionCommandD:
            return "More explicit shortcut with fewer accidental triggers."
        }
    }
}

struct GlobalDictationConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var shortcut: GlobalDictationShortcutChoice
    var retainsSnippets: Bool

    init(
        isEnabled: Bool = false,
        shortcut: GlobalDictationShortcutChoice = .controlOptionD,
        retainsSnippets: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.retainsSnippets = retainsSnippets
    }
}

enum GlobalDictationPhase: String, Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case inserting
    case inserted
    case failed

    var isBusy: Bool {
        switch self {
        case .listening, .transcribing, .inserting:
            return true
        case .idle, .inserted, .failed:
            return false
        }
    }
}

struct GlobalTextInsertionTarget: Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var processIdentifier: Int32
    var capturedAt: Date

    var displayName: String {
        appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Focused app" : appName
    }
}

enum GlobalTextInsertionPreparation: Equatable, Sendable {
    case ready(GlobalTextInsertionTarget)
    case missingAccessibilityPermission
    case noEditableTarget(appName: String?)
    case secureTarget(appName: String?)
    case unsupportedPlatform

    var failureCode: String? {
        switch self {
        case .ready:
            return nil
        case .missingAccessibilityPermission:
            return "missing_accessibility_permission"
        case .noEditableTarget:
            return "no_editable_target"
        case .secureTarget:
            return "secure_target"
        case .unsupportedPlatform:
            return "unsupported_platform"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .ready:
            return "Ready"
        case .missingAccessibilityPermission:
            return "Accessibility permission is required so Lorre can verify the focused text field and insert dictated text."
        case let .noEditableTarget(appName):
            let target = appName ?? "the focused app"
            return "No editable text field was detected in \(target). Focus a normal text field and try again."
        case let .secureTarget(appName):
            let target = appName ?? "the focused app"
            return "\(target) is focused on a secure text field. Lorre will not insert dictated text into password or secure-input fields."
        case .unsupportedPlatform:
            return "Global dictation insertion is only available in the macOS app."
        }
    }
}

enum GlobalTextInsertionResult: Equatable, Sendable {
    case inserted
    case failed(code: String, message: String)
}

enum GlobalDictationTextFormatter {
    static func insertionText(from result: TranscriptionResult) -> String {
        let text = result.utterances
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalizeWhitespace(text)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
