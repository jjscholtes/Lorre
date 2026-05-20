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
    let supportsCohereQualityPass: Bool

    init(
        pipeline: RuntimeProcessingPipeline,
        supportsSpeechToText: Bool,
        supportsVoiceActivityDetection: Bool,
        supportsSpeakerDiarization: Bool,
        supportsSpeakerEnrollment: Bool,
        supportsLivePreview: Bool,
        supportsTextNormalization: Bool,
        supportsVocabularyBoosting: Bool,
        supportsCohereQualityPass: Bool = false
    ) {
        self.pipeline = pipeline
        self.supportsSpeechToText = supportsSpeechToText
        self.supportsVoiceActivityDetection = supportsVoiceActivityDetection
        self.supportsSpeakerDiarization = supportsSpeakerDiarization
        self.supportsSpeakerEnrollment = supportsSpeakerEnrollment
        self.supportsLivePreview = supportsLivePreview
        self.supportsTextNormalization = supportsTextNormalization
        self.supportsVocabularyBoosting = supportsVocabularyBoosting
        self.supportsCohereQualityPass = supportsCohereQualityPass
    }

    static let mock = RuntimeCapabilities(
        pipeline: .mock,
        supportsSpeechToText: false,
        supportsVoiceActivityDetection: false,
        supportsSpeakerDiarization: false,
        supportsSpeakerEnrollment: false,
        supportsLivePreview: false,
        supportsTextNormalization: false,
        supportsVocabularyBoosting: false,
        supportsCohereQualityPass: false
    )

    var usesMockPipeline: Bool {
        pipeline == .mock
    }

    var usesFluidAudio: Bool {
        pipeline == .fluidAudio
    }

    var pipelineLabel: String {
        switch pipeline {
        case .fluidAudio:
            return "FluidAudio"
        case .mock:
            return "Mock"
        }
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
        if supportsVocabularyBoosting {
            labels.append("Vocabulary boosting")
        }
        if supportsCohereQualityPass {
            labels.append("Cohere quality pass")
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
