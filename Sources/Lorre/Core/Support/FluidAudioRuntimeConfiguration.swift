import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

enum FluidAudioRuntimeConfiguration {
    static func apply(modelRegistry configuration: ModelRegistryConfiguration) {
        let runtimeConfiguration = (try? configuration.validatedForModelDownloads()) ?? ModelRegistryConfiguration()
        #if canImport(FluidAudio)
        ModelRegistry.baseURL = runtimeConfiguration.summaryLabel
        #else
        _ = runtimeConfiguration
        #endif
    }
}
