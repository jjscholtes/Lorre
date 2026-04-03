import XCTest
@testable import Lorre

final class RuntimeCapabilitiesTests: XCTestCase {
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

    func testMockCapabilitiesDescribeDemoPipeline() {
        XCTAssertEqual(RuntimeCapabilities.mock.featureLabels, [])
        XCTAssertTrue(RuntimeCapabilities.mock.usesMockPipeline)
        XCTAssertFalse(RuntimeCapabilities.mock.usesFluidAudio)
        XCTAssertTrue(RuntimeCapabilities.mock.processingModeDescription.contains("Test/demo"))
    }
}
