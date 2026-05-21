import Testing
@testable import Lorre

@Suite("RuntimeCapabilitiesTests")
struct RuntimeCapabilitiesTests {

    @Test
    func testFeatureLabelsReflectSupportedCapabilities() {
        let capabilities = RuntimeCapabilities(
            pipeline: .fluidAudio,
            supportsSpeechToText: true,
            supportsVoiceActivityDetection: true,
            supportsSpeakerDiarization: true,
            supportsSpeakerEnrollment: false,
            supportsLivePreview: true,
            supportsTextNormalization: true,
            supportsVocabularyBoosting: false
        )

        XCTAssertEqual(
            capabilities.featureLabels,
            [
                "Speech-to-text",
                "Pause / silence detection",
                "Speaker recognition",
                "Live preview support",
                "Text normalization"
            ]
        )
        XCTAssertTrue(capabilities.usesFluidAudio)
        XCTAssertFalse(capabilities.usesMockPipeline)
    }


    @Test
    func testMockCapabilitiesDescribeDemoPipeline() {
        XCTAssertEqual(RuntimeCapabilities.mock.featureLabels, [])
        XCTAssertTrue(RuntimeCapabilities.mock.usesMockPipeline)
        XCTAssertFalse(RuntimeCapabilities.mock.usesFluidAudio)
        XCTAssertTrue(RuntimeCapabilities.mock.processingModeDescription.contains("Test/demo"))
    }


    @Test
    func testFeatureLabelsIncludeFluidAudioSpeechPassesWhenSupported() {
        let capabilities = RuntimeCapabilities(
            pipeline: .fluidAudio,
            supportsSpeechToText: true,
            supportsVoiceActivityDetection: true,
            supportsSpeakerDiarization: true,
            supportsSpeakerEnrollment: true,
            supportsLivePreview: true,
            supportsTextNormalization: true,
            supportsVocabularyBoosting: true,
            supportsCohereQualityPass: true
        )

        XCTAssertTrue(capabilities.featureLabels.contains("Vocabulary boosting"))
        XCTAssertTrue(capabilities.featureLabels.contains("Cohere quality pass"))
    }
}
