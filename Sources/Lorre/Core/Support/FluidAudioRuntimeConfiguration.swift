import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

enum FluidAudioRuntimeConfiguration {
    static func apply(modelRegistry configuration: ModelRegistryConfiguration) {
        #if canImport(FluidAudio)
        ModelRegistry.baseURL = configuration.summaryLabel
        #else
        _ = configuration
        #endif
    }
}
