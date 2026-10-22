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

    /// FluidAudio's debug lines can contain recognised transcript text; keep them out of the console and system log.
    static func applyPrivateLogging() {
        #if canImport(FluidAudio)
        AppLogger.minimumLevel = .info
        AppLogger.mirrorsToConsole = false
        #endif
    }
}
