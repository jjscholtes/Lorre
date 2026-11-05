import Testing
@testable import Lorre

#if canImport(FluidAudio)
import FluidAudio

@Suite("BatchLanguageMappingTests")
struct BatchLanguageMappingTests {

    @Test
    func testEverySupportedLanguageHasParakeetHint() {
        for code in BatchTranscriptionConfiguration.supportedLanguageCodes {
            let language = FluidAudioTranscriptionService.parakeetLanguage(for: code)
            XCTAssertEqual(language?.rawValue, code)
        }
    }

    @Test
    func testEverySupportedLanguageHasCohereLanguage() {
        for code in BatchTranscriptionConfiguration.supportedLanguageCodes {
            let language = FluidAudioTranscriptionService.cohereLanguage(for: code)
            XCTAssertEqual(language?.rawValue, code)
        }
    }

    @Test
    func testDutchMapsToDutchHint() {
        XCTAssertEqual(FluidAudioTranscriptionService.parakeetLanguage(for: " NL "), .dutch)
        XCTAssertEqual(FluidAudioTranscriptionService.cohereLanguage(for: "nl"), .dutch)
    }

    @Test
    func testBatchModesMapToExpectedParakeetModels() {
        XCTAssertEqual(FluidAudioTranscriptionService.asrModelVersion(for: .parakeetV2English), .v2)
        XCTAssertEqual(FluidAudioTranscriptionService.asrModelVersion(for: .parakeetV3), .v3)
        XCTAssertEqual(FluidAudioTranscriptionService.asrModelVersion(for: .parakeetV3WithCohereQualityPass), .v3)
        XCTAssertEqual(FluidAudioTranscriptionService.asrModelVersion(for: .parakeetUltra), .ultra)
    }
}
#endif
