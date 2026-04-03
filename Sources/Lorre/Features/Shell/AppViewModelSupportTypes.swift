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
