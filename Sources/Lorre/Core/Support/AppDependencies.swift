import Foundation

struct AppDependencies {
    let store: any SessionStore
    let knownSpeakerStore: KnownSpeakerStore
    let settings: AppSettingsStore
    let recorder: any RecorderService
    let transcription: any TranscriptionService
    let diarization: any SpeakerDiarizationService
    let speakerEnrollment: any SpeakerEnrollmentService
    let playback: any AudioPlaybackService
    let exporter: any ExportService
    let processingCoordinator: ProcessingCoordinator
    let metrics: LocalMetricsLogger
    let fluidAudioStatus: String
    let runtimeCapabilities: RuntimeCapabilities
    let modelPreparationComponentsSummary: String

    static func live() -> AppDependencies {
        let store = FileSessionStore()
        let knownSpeakerStore = KnownSpeakerStore()
        let settings = AppSettingsStore()

        let transcriptionService: any TranscriptionService
        let diarizationService: any SpeakerDiarizationService
        let speakerEnrollmentService: any SpeakerEnrollmentService
        let fluidAudioStatus: String
        let runtimeCapabilities: RuntimeCapabilities
        let modelPreparationComponentsSummary: String

        #if canImport(FluidAudio)
        _ = TextNormalizationRuntimeSupport.prepare()
        let enrollmentService = FluidAudioSpeakerEnrollmentService()
        speakerEnrollmentService = enrollmentService
        transcriptionService = FluidAudioTranscriptionService()
        diarizationService = FluidAudioDiarizationService(enrollmentService: enrollmentService)
        fluidAudioStatus = FluidAudioIntegrationProbe.statusSummary
        runtimeCapabilities = FluidAudioIntegrationProbe.runtimeCapabilities
        modelPreparationComponentsSummary = "ASR v3 • Silero VAD • Speaker enrollment • VBx / Sortformer / LS-EEND diarizers • Live diarizer"
        #else
        speakerEnrollmentService = FluidAudioSpeakerEnrollmentService()
        transcriptionService = MockTranscriptionService()
        diarizationService = MockSpeakerDiarizationService()
        fluidAudioStatus = "FluidAudio unavailable in this build; using mock ASR + diarization"
        runtimeCapabilities = .mock
        modelPreparationComponentsSummary = "Mock ASR • Mock diarizer"
        #endif

        #if canImport(AVFoundation)
        let recorder: any RecorderService = AVFoundationRecorderService(
            speakerEnrollmentService: speakerEnrollmentService,
            knownSpeakerReferenceAudioProvider: { speaker in
                await knownSpeakerStore.referenceAudioURL(for: speaker)
            }
        )
        let playback: any AudioPlaybackService = AVFoundationAudioPlaybackService()
        #else
        let recorder: any RecorderService = MockRecorderService()
        let playback: any AudioPlaybackService = UnsupportedAudioPlaybackService()
        #endif

        let coordinator = ProcessingCoordinator(
            store: store,
            transcriptionService: transcriptionService,
            diarizationService: diarizationService
        )
        return AppDependencies(
            store: store,
            knownSpeakerStore: knownSpeakerStore,
            settings: settings,
            recorder: recorder,
            transcription: transcriptionService,
            diarization: diarizationService,
            speakerEnrollment: speakerEnrollmentService,
            playback: playback,
            exporter: MarkdownExportService(),
            processingCoordinator: coordinator,
            metrics: LocalMetricsLogger(),
            fluidAudioStatus: fluidAudioStatus,
            runtimeCapabilities: runtimeCapabilities,
            modelPreparationComponentsSummary: modelPreparationComponentsSummary
        )
    }
}
