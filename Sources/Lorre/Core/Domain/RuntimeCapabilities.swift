import Foundation

enum RuntimeProcessingPipeline: String, Codable, Equatable, Sendable {
    case fluidAudio
    case mock
}

struct RuntimeCapabilities: Equatable, Sendable {
    let pipeline: RuntimeProcessingPipeline
    let supportsSpeechToText: Bool
    let supportsVoiceActivityDetection: Bool
    let supportsSpeakerDiarization: Bool
    let supportsSpeakerEnrollment: Bool
    let supportsLivePreview: Bool
    let supportsTextNormalization: Bool
    let supportsVocabularyBoosting: Bool

    static let mock = RuntimeCapabilities(
        pipeline: .mock,
        supportsSpeechToText: false,
        supportsVoiceActivityDetection: false,
        supportsSpeakerDiarization: false,
        supportsSpeakerEnrollment: false,
        supportsLivePreview: false,
        supportsTextNormalization: false,
        supportsVocabularyBoosting: false
    )

    var usesMockPipeline: Bool {
        pipeline == .mock
    }

    var usesFluidAudio: Bool {
        pipeline == .fluidAudio
    }

    var featureLabels: [String] {
        var labels: [String] = []
        if supportsSpeechToText {
            labels.append("Speech-to-text")
        }
        if supportsVoiceActivityDetection {
            labels.append("Pause / silence detection")
        }
        if supportsSpeakerDiarization {
            labels.append("Speaker recognition")
        }
        if supportsLivePreview {
            labels.append("Live preview support")
        }
        if supportsTextNormalization {
            labels.append("Text normalization")
        }
        return labels
    }

    var processingModeDescription: String {
        switch pipeline {
        case .fluidAudio:
            return "Local processing is available on this Mac (no cloud upload required)."
        case .mock:
            return "Test/demo processing pipeline is active (not the full production models)."
        }
    }
}
