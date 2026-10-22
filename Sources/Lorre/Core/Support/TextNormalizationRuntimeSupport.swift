import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

enum TextNormalizationRuntimeSupport {
    /// The bundled NeMo inverse text normalizer only knows English spoken forms.
    static let supportedLanguageCodes: Set<String> = ["en"]

    static func supportsLanguage(_ languageHint: String?) -> Bool {
        guard let languageHint else { return false }
        return supportedLanguageCodes.contains(BatchTranscriptionConfiguration.normalizedLanguageCode(languageHint))
    }

    struct RuntimeState: Equatable, Sendable {
        let isNativeAvailable: Bool

        var summary: String {
            #if canImport(FluidAudio)
            isNativeAvailable ? "ITN enabled (English)" : "ITN library unavailable"
            #else
            "ITN unavailable"
            #endif
        }
    }

    #if canImport(FluidAudio)
    /// FluidAudio links the NeMo engine directly since 0.15.7; no runtime library discovery is needed.
    static func prepare() -> TextNormalizer {
        TextNormalizer.shared
    }

    static var runtimeState: RuntimeState {
        RuntimeState(isNativeAvailable: TextNormalizer.shared.isNativeAvailable)
    }
    #else
    static var runtimeState: RuntimeState {
        RuntimeState(isNativeAvailable: false)
    }
    #endif

    static var runtimeSummary: String {
        runtimeState.summary
    }
}
