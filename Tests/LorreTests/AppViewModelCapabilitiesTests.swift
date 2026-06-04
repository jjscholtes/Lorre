import Testing
@testable import Lorre

@Suite("AppViewModelCapabilitiesTests")
struct AppViewModelCapabilitiesTests {

    @Test
    func testPrepareModelsUsesRuntimeCapabilitiesInsteadOfStatusStringParsing() async throws {
        let root = makeTemporaryRoot(named: "AppViewModelCapabilities")
        let recorder = ControlledRecorderService()
        let speakerEnrollment = TestSpeakerEnrollmentService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            speakerEnrollment: speakerEnrollment,
            runtimeCapabilities: RuntimeCapabilities(
                pipeline: .fluidAudio,
                supportsSpeechToText: true,
                supportsVoiceActivityDetection: true,
                supportsSpeakerDiarization: true,
                supportsSpeakerEnrollment: true,
                supportsLivePreview: false,
                supportsTextNormalization: false,
                supportsVocabularyBoosting: false
            ),
            fluidAudioStatus: "FluidAudio available (ASR + VAD + diarization enabled; ITN library unavailable)"
        )

        let viewModel = await MainActor.run { AppViewModel(dependencies: dependencies) }
        await viewModel.start()
        await MainActor.run {
            viewModel.prepareModelsTapped()
        }

        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run {
                if case .ready = viewModel.modelPreparationState {
                    return true
                }
                return false
            }
        }

        let ensureModelsReadyCallCount = await speakerEnrollment.snapshotEnsureModelsReadyCallCount()
        XCTAssertEqual(ensureModelsReadyCallCount, 1)
    }


    @Test
    func testPrepareModelsSkipsSpeakerEnrollmentWhenCapabilityDisabled() async throws {
        let root = makeTemporaryRoot(named: "AppViewModelCapabilities")
        let recorder = ControlledRecorderService()
        let speakerEnrollment = TestSpeakerEnrollmentService()
        let dependencies = makeTestDependencies(
            root: root,
            recorder: recorder,
            speakerEnrollment: speakerEnrollment,
            runtimeCapabilities: RuntimeCapabilities(
                pipeline: .fluidAudio,
                supportsSpeechToText: true,
                supportsVoiceActivityDetection: true,
                supportsSpeakerDiarization: true,
                supportsSpeakerEnrollment: false,
                supportsLivePreview: false,
                supportsTextNormalization: false,
                supportsVocabularyBoosting: false
            ),
            fluidAudioStatus: "FluidAudio available (ASR + VAD + diarization enabled; ITN library unavailable)"
        )

        let viewModel = await MainActor.run { AppViewModel(dependencies: dependencies) }
        await viewModel.start()
        await MainActor.run {
            viewModel.prepareModelsTapped()
        }

        try await waitUntil(timeout: .seconds(4)) {
            await MainActor.run {
                if case .ready = viewModel.modelPreparationState {
                    return true
                }
                return false
            }
        }

        let ensureModelsReadyCallCount = await speakerEnrollment.snapshotEnsureModelsReadyCallCount()
        XCTAssertEqual(ensureModelsReadyCallCount, 0)
    }


    @Test
    func testSetVocabularyBoostingEnabledShowsUnavailableBannerWhenUnsupported() async throws {
        let root = makeTemporaryRoot(named: "AppViewModelCapabilities")
        let dependencies = makeTestDependencies(
            root: root,
            recorder: ControlledRecorderService(),
            runtimeCapabilities: RuntimeCapabilities(
                pipeline: .fluidAudio,
                supportsSpeechToText: true,
                supportsVoiceActivityDetection: true,
                supportsSpeakerDiarization: true,
                supportsSpeakerEnrollment: true,
                supportsLivePreview: true,
                supportsTextNormalization: false,
                supportsVocabularyBoosting: false
            )
        )

        let viewModel = await MainActor.run { AppViewModel(dependencies: dependencies) }
        await viewModel.start()

        await MainActor.run {
            viewModel.setVocabularyBoostingEnabled(true)
        }

        await MainActor.run {
            XCTAssertFalse(viewModel.isVocabularyBoostingAvailable)
            XCTAssertFalse(viewModel.isVocabularyBoostingEffectivelyEnabled)
            XCTAssertEqual(viewModel.banner?.title, "Vocabulary boosting unavailable")
        }
    }


    @Test
    func testBatchLanguageChangeFallsBackFromParakeetV2ToV3() async throws {
        let root = makeTemporaryRoot(named: "AppViewModelBatchFallback")
        let dependencies = makeTestDependencies(
            root: root,
            recorder: ControlledRecorderService()
        )
        let viewModel = await MainActor.run { AppViewModel(dependencies: dependencies) }

        await viewModel.start()
        await MainActor.run {
            viewModel.setBatchTranscriptionLanguageCode("en")
            viewModel.setBatchTranscriptionMode(.parakeetV2English)
        }

        try await waitUntil {
            await MainActor.run {
                viewModel.batchTranscriptionConfiguration.mode == .parakeetV2English
            }
        }

        await MainActor.run {
            viewModel.setBatchTranscriptionLanguageCode("nl")
        }

        try await waitUntil {
            await MainActor.run {
                viewModel.batchTranscriptionConfiguration.mode == .parakeetV3
                    && viewModel.batchTranscriptionConfiguration.languageCode == "nl"
                    && viewModel.banner?.title == "Switched to Parakeet v3"
            }
        }

        await MainActor.run {
            XCTAssertEqual(
                viewModel.banner?.message,
                "Parakeet v2 is English-only, so NL uses the multilingual v3 model."
            )
        }
    }


    @Test
    func testLiveEngineChangeIsBlockedDuringRecording() async throws {
        let root = makeTemporaryRoot(named: "AppViewModelLiveEngineLock")
        let recorder = ControlledRecorderService(
            supportBySource: [
                .microphone: true
            ]
        )
        let dependencies = makeTestDependencies(root: root, recorder: recorder)
        let viewModel = await MainActor.run { AppViewModel(dependencies: dependencies) }

        await viewModel.start()
        try await waitUntil {
            await MainActor.run { viewModel.isLiveTranscriptionSupported }
        }

        await MainActor.run {
            viewModel.startRecordingTapped()
        }
        try await waitUntil {
            await MainActor.run { viewModel.isRecording }
        }

        await MainActor.run {
            XCTAssertEqual(viewModel.liveTranscriptionPreset, .balanced)
            viewModel.setLiveTranscriptionPreset(.nemotronBalanced)
            XCTAssertEqual(viewModel.liveTranscriptionPreset, .balanced)
            XCTAssertEqual(viewModel.banner?.title, "Live engine locked")
        }
    }
}
