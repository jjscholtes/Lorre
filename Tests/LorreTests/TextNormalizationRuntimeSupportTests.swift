import XCTest
@testable import Lorre

final class TextNormalizationRuntimeSupportTests: XCTestCase {
    func testRuntimeStateSummaryForUnavailableLibrary() {
        let state = TextNormalizationRuntimeSupport.RuntimeState(
            isNativeAvailable: false,
            loadedLibraryPath: nil
        )
        #if canImport(FluidAudio)
        XCTAssertEqual(state.summary, "ITN library unavailable")
        #else
        XCTAssertEqual(state.summary, "ITN unavailable")
        #endif
    }

    func testRuntimeStateSummaryForLoadedLibrary() {
        let state = TextNormalizationRuntimeSupport.RuntimeState(
            isNativeAvailable: true,
            loadedLibraryPath: "/tmp/libnemo_text_processing.dylib"
        )
        #if canImport(FluidAudio)
        XCTAssertEqual(state.summary, "ITN enabled (libnemo_text_processing.dylib loaded at runtime)")
        #else
        XCTAssertEqual(state.summary, "ITN unavailable")
        #endif
    }
}
