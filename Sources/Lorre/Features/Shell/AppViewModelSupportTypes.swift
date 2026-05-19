import Foundation

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all
    case processing
    case ready
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Sessions"
        case .processing: "Processing"
        case .ready: "Ready"
        case .errors: "Errors"
        }
    }

    var iconName: String {
        switch self {
        case .all: "tray.full"
        case .processing: "gearshape.2"
        case .ready: "doc.text"
        case .errors: "exclamationmark.triangle"
        }
    }
}

struct AppBanner: Identifiable {
    enum Kind {
        case info
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

enum ModelPreparationState: Equatable {
    case unknown
    case idle
    case preparing
    case ready
    case error(String)
}

enum WorkStageRoute: Equatable {
    case recorder
    case processing(UUID)
    case transcript(UUID)
}

struct CuePlaybackPresentation: Equatable {
    let statusLabel: String
    let description: String
    let iconName: String
}

enum SessionAction: String, CaseIterable, Identifiable, Sendable {
    case moveToFolder
    case revealFiles
    case rename
    case retryProcessing
    case exportTranscript
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToFolder:
            return "Move to Folder"
        case .revealFiles:
            return "Reveal Files"
        case .rename:
            return "Rename"
        case .retryProcessing:
            return "Retry Processing"
        case .exportTranscript:
            return "Export"
        case .delete:
            return "Delete"
        }
    }
}

enum SessionActionSurface: Sendable {
    case shelfContextMenu
    case transcriptHeader
    case processingStage
    case errorState
}

struct SessionActionState: Identifiable, Equatable, Sendable {
    var action: SessionAction
    var isEnabled: Bool
    var disabledReason: String?

    var id: String { action.id }
}

actor TranscriptPersistenceQueue {
    private struct QueuedSave {
        var id: UUID
        var task: Task<Void, Error>
    }

    private var tails: [UUID: QueuedSave] = [:]

    func save(_ transcript: TranscriptDocument, using store: any SessionStore) async throws {
        let sessionID = transcript.sessionId
        let previous = tails[sessionID]?.task
        let token = UUID()
        let task = Task {
            _ = try? await previous?.value
            try await store.saveTranscript(transcript)
        }
        tails[sessionID] = QueuedSave(id: token, task: task)

        do {
            try await task.value
            if tails[sessionID]?.id == token {
                tails[sessionID] = nil
            }
        } catch {
            if tails[sessionID]?.id == token {
                tails[sessionID] = nil
            }
            throw error
        }
    }
}
