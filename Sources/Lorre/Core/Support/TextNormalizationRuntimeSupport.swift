import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
import Darwin
#endif

enum TextNormalizationRuntimeSupport {
    #if canImport(FluidAudio)
    struct RuntimeState: Equatable, Sendable {
        let isNativeAvailable: Bool
        let loadedLibraryPath: String?

        var summary: String {
            guard isNativeAvailable else {
                return "ITN library unavailable"
            }
            if let loadedLibraryPath {
                return "ITN enabled (\(URL(fileURLWithPath: loadedLibraryPath).lastPathComponent) loaded at runtime)"
            }
            return "ITN enabled"
        }
    }

    private static let lock = NSLock()
    private static let libraryName = "libnemo_text_processing.dylib"
    nonisolated(unsafe) private static var didAttemptLibraryLoad = false
    nonisolated(unsafe) private static var loadedLibraryPath: String?

    @discardableResult
    static func prepare() -> TextNormalizer {
        lock.lock()
        defer { lock.unlock() }

        if !didAttemptLibraryLoad {
            loadBundledLibraryIfPresent()
            didAttemptLibraryLoad = true
        }

        return TextNormalizer()
    }

    static var runtimeSummary: String {
        runtimeState.summary
    }

    static var runtimeState: RuntimeState {
        let normalizer = prepare()
        return RuntimeState(
            isNativeAvailable: normalizer.isNativeAvailable,
            loadedLibraryPath: loadedLibraryPath
        )
    }

    private static func loadBundledLibraryIfPresent() {
        for candidate in candidateLibraryURLs() {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if dlopen(candidate.path, RTLD_NOW | RTLD_GLOBAL) != nil {
                loadedLibraryPath = candidate.path
                return
            }
        }
    }

    private static func candidateLibraryURLs() -> [URL] {
        var urls: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if let overridePath = environment["LORRE_NEMO_TEXT_PROCESSING_LIBRARY"], !overridePath.isEmpty {
            urls.append(URL(fileURLWithPath: overridePath))
        }

        if let frameworksURL = Bundle.main.privateFrameworksURL {
            urls.append(frameworksURL.appendingPathComponent(libraryName))
        }

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(libraryName))
        }

        if let executableURL = Bundle.main.executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            urls.append(executableDirectory.appendingPathComponent(libraryName))
            urls.append(executableDirectory.deletingLastPathComponent().appendingPathComponent("Frameworks/\(libraryName)"))
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        urls.append(currentDirectory.appendingPathComponent("ThirdParty/NemoTextProcessing/macos/\(libraryName)"))
        urls.append(currentDirectory.appendingPathComponent("ThirdParty/NemoTextProcessing/\(libraryName)"))
        urls.append(currentDirectory.appendingPathComponent("Vendor/NemoTextProcessing/macos/\(libraryName)"))
        urls.append(currentDirectory.appendingPathComponent("Vendor/NemoTextProcessing/\(libraryName)"))

        return urls
    }
    #else
    struct RuntimeState: Equatable, Sendable {
        let isNativeAvailable: Bool
        let loadedLibraryPath: String?

        var summary: String {
            "ITN unavailable"
        }
    }

    static var runtimeSummary: String {
        runtimeState.summary
    }

    static var runtimeState: RuntimeState {
        RuntimeState(isNativeAvailable: false, loadedLibraryPath: nil)
    }
    #endif
}
