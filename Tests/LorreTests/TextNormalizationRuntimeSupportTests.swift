import Foundation
import Testing
@testable import Lorre

@Suite("TextNormalizationRuntimeSupportTests")
struct TextNormalizationRuntimeSupportTests {

    @Test
    func testRuntimeStateSummaryForUnavailableLibrary() {
        let state = TextNormalizationRuntimeSupport.RuntimeState(isNativeAvailable: false)
        #if canImport(FluidAudio)
        XCTAssertEqual(state.summary, "ITN library unavailable")
        #else
        XCTAssertEqual(state.summary, "ITN unavailable")
        #endif
    }

    @Test
    func testRuntimeStateSummaryForLinkedLibrary() {
        let state = TextNormalizationRuntimeSupport.RuntimeState(isNativeAvailable: true)
        #if canImport(FluidAudio)
        XCTAssertEqual(state.summary, "ITN enabled (English)")
        #else
        XCTAssertEqual(state.summary, "ITN unavailable")
        #endif
    }

    #if canImport(FluidAudio)
    @Test
    func testBundledNormalizerIsLinked() {
        XCTAssertTrue(TextNormalizationRuntimeSupport.runtimeState.isNativeAvailable)
    }
    #endif

    @Test
    func testOnlyEnglishTranscriptsAreNormalized() {
        XCTAssertTrue(TextNormalizationRuntimeSupport.supportsLanguage("en"))
        XCTAssertTrue(TextNormalizationRuntimeSupport.supportsLanguage(" EN "))
        XCTAssertFalse(TextNormalizationRuntimeSupport.supportsLanguage("nl"))
        XCTAssertFalse(TextNormalizationRuntimeSupport.supportsLanguage("de"))
        XCTAssertFalse(TextNormalizationRuntimeSupport.supportsLanguage(nil))
    }

    @Test
    func testDutchTranscriptIsLeftUntouched() {
        let transcript = TranscriptDocument(
            sessionId: UUID(),
            languageHint: "nl",
            sourceEngine: "Test",
            segments: [
                TranscriptSegment(startMs: 0, endMs: 1000, text: "twee honderd period", speakerId: "S1")
            ],
            speakers: []
        )
        let normalized = TranscriptTextNormalizationSupport.normalize(transcript)
        XCTAssertEqual(normalized.segments.first?.text, "twee honderd period")
    }
}
