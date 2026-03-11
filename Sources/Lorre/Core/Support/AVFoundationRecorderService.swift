#if canImport(AVFoundation)
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ScreenCaptureKit)
import CoreGraphics
@preconcurrency import ScreenCaptureKit
#endif
import Foundation

actor AVFoundationRecorderService: RecorderService {
    private enum PermissionSettingsPane {
        case microphone
        case screenCapture
    }

    private final class CaptureFileWriterBox: @unchecked Sendable {
        private let file: AVAudioFile
        private let lock = NSLock()
        private var writeFailureMessage: String?

        init(file: AVAudioFile) {
            self.file = file
        }

        func write(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard writeFailureMessage == nil else { return }
            do {
                try file.write(from: buffer)
            } catch {
                writeFailureMessage = error.localizedDescription
            }
        }

        func failureMessage() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return writeFailureMessage
        }
    }

    private final class LiveMonitorBridgeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var meterLevel: Double = 0.05
        private var preview: LiveTranscriptPreview?
        private var monitorStream: AsyncStream<RecorderLiveMonitorEvent>?
        private var monitorContinuation: AsyncStream<RecorderLiveMonitorEvent>.Continuation?
        private var lastMeterEmitUptime: TimeInterval = 0
        private let meterEmitIntervalSeconds: TimeInterval = 0.05
        #if canImport(FluidAudio)
        private var recognizer: FluidAudioLiveStreamingRecognizer?
        private var pendingRecognitionBuffers: [LiveTranscriptionPCMBufferBox] = []
        private let maxBufferedRecognitionBuffers = 16
        private var recognitionWorkerTask: Task<Void, Never>?
        private var recognitionWorkerBusy = false
        #endif

        func setMeterLevel(_ level: Double) {
            lock.lock()
            meterLevel = level
            let shouldEmit = (ProcessInfo.processInfo.systemUptime - lastMeterEmitUptime) >= meterEmitIntervalSeconds
            if shouldEmit {
                lastMeterEmitUptime = ProcessInfo.processInfo.systemUptime
            }
            let continuation = shouldEmit ? monitorContinuation : nil
            lock.unlock()
            if shouldEmit {
                continuation?.yield(RecorderLiveMonitorEvent(meterLevel: level, preview: nil))
            }
        }

        func currentMeterLevel() -> Double {
            lock.lock()
            defer { lock.unlock() }
            return meterLevel
        }

        func setPreview(_ preview: LiveTranscriptPreview?) {
            lock.lock()
            self.preview = preview
            let continuation = monitorContinuation
            lock.unlock()
            continuation?.yield(RecorderLiveMonitorEvent(meterLevel: nil, preview: preview))
        }

        func currentPreview() -> LiveTranscriptPreview? {
            lock.lock()
            defer { lock.unlock() }
            return preview
        }

        func makeMonitorStream() -> AsyncStream<RecorderLiveMonitorEvent> {
            lock.lock()
            if let monitorStream {
                lock.unlock()
                return monitorStream
            }

            let currentMeter = meterLevel
            let currentPreview = preview
            var continuationRef: AsyncStream<RecorderLiveMonitorEvent>.Continuation?
            let stream = AsyncStream<RecorderLiveMonitorEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation in
                continuationRef = continuation
            }
            monitorStream = stream
            monitorContinuation = continuationRef
            let continuation = monitorContinuation
            lock.unlock()

            continuation?.yield(RecorderLiveMonitorEvent(meterLevel: currentMeter, preview: currentPreview))
            return stream
        }

        func finishMonitoring() {
            lock.lock()
            preview = nil
            let continuation = monitorContinuation
            monitorContinuation = nil
            monitorStream = nil
            lock.unlock()
            continuation?.finish()
        }

        #if canImport(FluidAudio)
        func setRecognizer(_ recognizer: FluidAudioLiveStreamingRecognizer?) {
            lock.lock()
            self.recognizer = recognizer
            if recognizer == nil {
                pendingRecognitionBuffers.removeAll(keepingCapacity: false)
            }
            let shouldStartWorker = recognizer != nil && recognitionWorkerTask == nil
            lock.unlock()
            if shouldStartWorker {
                startRecognitionWorkerIfNeeded()
            }
            if recognizer == nil {
                recognitionWorkerTask?.cancel()
                recognitionWorkerTask = nil
            }
        }

        func enqueueRecognitionBuffer(_ buffer: AVAudioPCMBuffer) {
            guard let copiedBuffer = buffer.lorre_deepCopy().map(LiveTranscriptionPCMBufferBox.init) else { return }

            lock.lock()
            guard recognizer != nil else {
                lock.unlock()
                return
            }
            if pendingRecognitionBuffers.count >= maxBufferedRecognitionBuffers {
                pendingRecognitionBuffers.removeFirst(pendingRecognitionBuffers.count - maxBufferedRecognitionBuffers + 1)
            }
            pendingRecognitionBuffers.append(copiedBuffer)
            let shouldStartWorker = recognitionWorkerTask == nil
            lock.unlock()
            if shouldStartWorker {
                startRecognitionWorkerIfNeeded()
            }
        }

        func drainRecognitionWork() async {
            while hasRecognitionWork() {
                try? await Task.sleep(for: .milliseconds(12))
            }
        }

        private func startRecognitionWorkerIfNeeded() {
            lock.lock()
            guard recognitionWorkerTask == nil else {
                lock.unlock()
                return
            }
            recognitionWorkerTask = Task { [weak self] in
                await self?.runRecognitionWorkerLoop()
            }
            lock.unlock()
        }

        private func popRecognitionWork() -> (FluidAudioLiveStreamingRecognizer, LiveTranscriptionPCMBufferBox)? {
            lock.lock()
            defer { lock.unlock() }
            guard let recognizer, !pendingRecognitionBuffers.isEmpty else { return nil }
            let next = pendingRecognitionBuffers.removeFirst()
            recognitionWorkerBusy = true
            return (recognizer, next)
        }

        private func hasRecognitionWork() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !pendingRecognitionBuffers.isEmpty || recognitionWorkerBusy
        }

        private func runRecognitionWorkerLoop() async {
            while !Task.isCancelled {
                if let (recognizer, buffer) = popRecognitionWork() {
                    await recognizer.ingest(buffer)
                    markRecognitionWorkerIdle()
                    continue
                }
                try? await Task.sleep(for: .milliseconds(12))
                if shouldBreakRecognitionLoop() {
                    break
                }
            }
            clearRecognitionWorkerTaskReference()
        }

        private func clearRecognitionWorkerTaskReference() {
            lock.lock()
            recognitionWorkerTask = nil
            recognitionWorkerBusy = false
            lock.unlock()
        }

        private func markRecognitionWorkerIdle() {
            lock.lock()
            recognitionWorkerBusy = false
            lock.unlock()
        }

        private func shouldBreakRecognitionLoop() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return recognizer == nil
        }
        #else
        func setRecognizer(_ recognizer: Any?) {
            _ = recognizer
        }

        func enqueueRecognitionBuffer(_ buffer: AVAudioPCMBuffer) {
            _ = buffer
        }

        func drainRecognitionWork() async {}
        #endif
    }

    private final class CombinedMeterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var microphoneLevel: Double = 0.05
        private var systemLevel: Double = 0.05

        enum Source {
            case microphone
            case systemAudio
        }

        func update(_ level: Double, for source: Source) -> Double {
            lock.lock()
            switch source {
            case .microphone:
                microphoneLevel = level
            case .systemAudio:
                systemLevel = level
            }
            let combined = max(microphoneLevel, systemLevel)
            lock.unlock()
            return combined
        }

        func reset() {
            lock.lock()
            microphoneLevel = 0.05
            systemLevel = 0.05
            lock.unlock()
        }
    }

    private final class MixedPreviewMixerBox: @unchecked Sendable {
        enum Source {
            case microphone
            case systemAudio
        }

        private let lock = NSLock()
        private var microphoneSamples: [Float] = []
        private var systemSamples: [Float] = []
        private let chunkSize = 1600
        private let maxBufferedSamples = 1600 * 24
        private let outputFormat = RecorderAudioUtilities.previewFormat
        private let outputHandler: @Sendable (AVAudioPCMBuffer) -> Void

        init(outputHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
            self.outputHandler = outputHandler
        }

        func enqueue(_ buffer: AVAudioPCMBuffer, source: Source) {
            guard let converted = try? RecorderAudioUtilities.convert(buffer, to: outputFormat),
                  let channelData = converted.floatChannelData else {
                return
            }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))

            let chunks: [[Float]]
            lock.lock()
            switch source {
            case .microphone:
                microphoneSamples.append(contentsOf: samples)
                if microphoneSamples.count > maxBufferedSamples {
                    microphoneSamples.removeFirst(microphoneSamples.count - maxBufferedSamples)
                }
            case .systemAudio:
                systemSamples.append(contentsOf: samples)
                if systemSamples.count > maxBufferedSamples {
                    systemSamples.removeFirst(systemSamples.count - maxBufferedSamples)
                }
            }
            chunks = drainLocked(flushAll: false)
            lock.unlock()
            emit(chunks)
        }

        func flushRemaining() {
            let chunks: [[Float]]
            lock.lock()
            chunks = drainLocked(flushAll: true)
            lock.unlock()
            emit(chunks)
        }

        private func drainLocked(flushAll: Bool) -> [[Float]] {
            var chunks: [[Float]] = []

            while max(microphoneSamples.count, systemSamples.count) >= chunkSize || (
                flushAll && max(microphoneSamples.count, systemSamples.count) > 0
            ) {
                let frameCount = flushAll ? min(chunkSize, max(microphoneSamples.count, systemSamples.count)) : chunkSize
                var mixed = Array(repeating: Float(0), count: frameCount)

                for index in 0..<frameCount {
                    let microphone = index < microphoneSamples.count ? microphoneSamples[index] : 0
                    let system = index < systemSamples.count ? systemSamples[index] : 0
                    let value = ((microphone * 0.70710677) + (system * 0.70710677)) * 0.8
                    mixed[index] = max(-0.98, min(0.98, value))
                }

                if microphoneSamples.count >= frameCount {
                    microphoneSamples.removeFirst(frameCount)
                } else {
                    microphoneSamples.removeAll(keepingCapacity: true)
                }
                if systemSamples.count >= frameCount {
                    systemSamples.removeFirst(frameCount)
                } else {
                    systemSamples.removeAll(keepingCapacity: true)
                }

                chunks.append(mixed)
            }

            return chunks
        }

        private func emit(_ chunks: [[Float]]) {
            for chunk in chunks {
                guard let buffer = try? RecorderAudioUtilities.makePCMBuffer(from: chunk, format: outputFormat) else {
                    continue
                }
                outputHandler(buffer)
            }
        }
    }

    #if canImport(ScreenCaptureKit)
    private final class SystemAudioCaptureBox: NSObject, SCStreamOutput, @unchecked Sendable {
        private let filter: SCContentFilter
        private let outputURL: URL
        private let writer: CaptureFileWriterBox
        private let outputQueue = DispatchQueue(label: "Lorre.SystemAudioCapture")
        private let onPCMBuffer: @Sendable (AVAudioPCMBuffer) -> Void
        private let onMeterLevel: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var failureMessage: String?
        private var stream: SCStream?

        init(
            filter: SCContentFilter,
            outputURL: URL,
            onPCMBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            onMeterLevel: @escaping @Sendable (Double) -> Void
        ) throws {
            self.filter = filter
            self.outputURL = outputURL
            let fileFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )!
            self.writer = try CaptureFileWriterBox(file: AVAudioFile(forWriting: outputURL, settings: fileFormat.settings))
            self.onPCMBuffer = onPCMBuffer
            self.onMeterLevel = onMeterLevel
        }

        func start() async throws {
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            do {
                try await stream.startCapture()
                self.stream = stream
            } catch {
                try? stream.removeStreamOutput(self, type: .audio)
                throw error
            }
        }

        func stop() async throws {
            guard let stream else { return }
            try await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .audio)
            self.stream = nil
        }

        func cancel() async {
            try? await stop()
        }

        func failure() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return failureMessage ?? writer.failureMessage()
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            guard CMSampleBufferIsValid(sampleBuffer) else { return }
            do {
                let buffer = try RecorderAudioUtilities.extractPCMBuffer(from: sampleBuffer)
                let converted = try RecorderAudioUtilities.convert(
                    buffer,
                    to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
                )
                writer.write(converted)
                onMeterLevel(converted.lorre_meterLevel())
                onPCMBuffer(converted)
            } catch {
                lock.lock()
                if failureMessage == nil {
                    failureMessage = error.localizedDescription
                }
                lock.unlock()
            }
        }
    }

    @MainActor
    private final class ScreenCapturePickerObserverBox: NSObject, SCContentSharingPickerObserver {
        private var continuation: CheckedContinuation<SCContentFilter, Error>?
        private let picker = SCContentSharingPicker.shared

        func present() async throws -> SCContentFilter {
            var configuration = picker.defaultConfiguration
            configuration.allowedPickerModes = [
                .singleWindow,
                .multipleWindows,
                .singleApplication,
                .multipleApplications,
                .singleDisplay,
            ]
            configuration.allowsChangingSelectedContent = false
            configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
            picker.defaultConfiguration = configuration
            picker.maximumStreamCount = 1
            picker.isActive = true
            picker.add(self)

            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                picker.present()
            }
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
            _ = picker
            _ = stream
            Task { @MainActor in
                self.finish(with: .failure(LorreError.recordingSourceSelectionCancelled))
            }
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
            _ = picker
            _ = stream
            Task { @MainActor in
                self.finish(with: .success(filter))
            }
        }

        nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
            Task { @MainActor in
                self.finish(with: .failure(error))
            }
        }

        private func finish(with result: Result<SCContentFilter, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            picker.remove(self)
            picker.isActive = false
            switch result {
            case let .success(filter):
                continuation.resume(returning: filter)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }
    #endif

    private struct MicrophoneCaptureStartResult {
        var engine: AVAudioEngine
        var writer: CaptureFileWriterBox
        var tempURL: URL
    }

    #if canImport(ScreenCaptureKit)
    private struct SystemCaptureStartResult {
        var capture: SystemAudioCaptureBox
        var tempURL: URL
    }
    #endif

    private var microphoneEngine: AVAudioEngine?
    private var microphoneWriter: CaptureFileWriterBox?
    #if canImport(ScreenCaptureKit)
    private var systemCapture: SystemAudioCaptureBox?
    #endif
    private var liveMonitorBridge: LiveMonitorBridgeBox?
    private var combinedMeterBox: CombinedMeterBox?
    private var previewMixer: MixedPreviewMixerBox?
    private var temporaryCanonicalURL: URL?
    private var temporaryMicrophoneURL: URL?
    private var temporarySystemAudioURL: URL?
    private var startedAt: Date?
    private var liveStartupTask: Task<Void, Never>?
    private var activeRecordingToken: UUID?
    private var activeRecordingSource: RecordingSource?
    private var isLiveTranscriptionEnabled = false
    private var livePreviewFallback: LiveTranscriptPreview?
    private let speakerEnrollmentService: any SpeakerEnrollmentService
    private let knownSpeakerReferenceAudioProvider: (@Sendable (KnownSpeaker) async -> URL?)?
    private var knownSpeakers: [KnownSpeaker] = []
    #if canImport(FluidAudio)
    private var liveRecognizer: FluidAudioLiveStreamingRecognizer?
    #endif

    init(
        speakerEnrollmentService: any SpeakerEnrollmentService,
        knownSpeakerReferenceAudioProvider: (@Sendable (KnownSpeaker) async -> URL?)? = nil
    ) {
        self.speakerEnrollmentService = speakerEnrollmentService
        self.knownSpeakerReferenceAudioProvider = knownSpeakerReferenceAudioProvider
    }

    func startRecording(_ request: RecordingRequest) async throws {
        guard activeRecordingSource == nil else {
            throw LorreError.recordingStartFailed("Another recording is already in progress.")
        }

        try await ensurePermissions(for: request.source)
        #if canImport(ScreenCaptureKit)
        let selectedFilter: SCContentFilter? = request.source.includesSystemAudio ? try await pickSystemAudioFilter() : nil
        #else
        if request.source.includesSystemAudio {
            throw LorreError.recordingStartFailed("System audio capture is unavailable in this build.")
        }
        #endif

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lorre", isDirectory: true)
            .appendingPathComponent("recording-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let monitorBridge = LiveMonitorBridgeBox()
        let combinedMeter = request.source == .microphoneAndSystemAudio ? CombinedMeterBox() : nil
        let previewMixer = request.source == .microphoneAndSystemAudio
            ? MixedPreviewMixerBox { monitorBridge.enqueueRecognitionBuffer($0) }
            : nil

        do {
            let micStart: MicrophoneCaptureStartResult?
            if request.source.includesMicrophone {
                micStart = try startMicrophoneCapture(
                    in: tempDir,
                    combinedMeter: combinedMeter,
                    previewBridge: monitorBridge,
                    previewMixer: previewMixer,
                    source: request.source
                )
            } else {
                micStart = nil
            }

            #if canImport(ScreenCaptureKit)
            let systemStart: SystemCaptureStartResult?
            if request.source.includesSystemAudio, let filter = selectedFilter {
                systemStart = try await startSystemAudioCapture(
                    filter: filter,
                    in: tempDir,
                    combinedMeter: combinedMeter,
                    previewBridge: monitorBridge,
                    previewMixer: previewMixer,
                    source: request.source
                )
            } else {
                systemStart = nil
            }
            #endif

            let startedAt = Date()
            self.liveMonitorBridge = monitorBridge
            self.combinedMeterBox = combinedMeter
            self.previewMixer = previewMixer
            self.microphoneEngine = micStart?.engine
            self.microphoneWriter = micStart?.writer
            #if canImport(ScreenCaptureKit)
            self.systemCapture = systemStart?.capture
            #endif
            self.startedAt = startedAt
            self.activeRecordingSource = request.source
            self.activeRecordingToken = UUID()

            switch request.source {
            case .microphone:
                self.temporaryCanonicalURL = micStart?.tempURL
            case .systemAudio:
                #if canImport(ScreenCaptureKit)
                self.temporaryCanonicalURL = systemStart?.tempURL
                #endif
            case .microphoneAndSystemAudio:
                self.temporaryCanonicalURL = nil
                self.temporaryMicrophoneURL = micStart?.tempURL
                #if canImport(ScreenCaptureKit)
                self.temporarySystemAudioURL = systemStart?.tempURL
                #endif
            }

            if isLiveTranscriptionEnabled, await supportsLiveTranscription(for: request.source) {
                livePreviewFallback = LiveTranscriptPreview(
                    confirmedText: "",
                    partialText: "Preparing live transcript… recording has already started.",
                    isFinalizing: false,
                    errorMessage: nil,
                    updatedAt: Date()
                )
                monitorBridge.setPreview(livePreviewFallback)
                if let recordingToken = activeRecordingToken {
                    startLiveStreamingStartupTask(for: recordingToken)
                }
            } else {
                livePreviewFallback = nil
            }
        } catch {
            try? await cleanupPartialRecordingState()
            throw error
        }
    }

    func cancelRecording() async throws {
        guard activeRecordingSource != nil else {
            throw LorreError.recordingNotStarted
        }
        try await cleanupPartialRecordingState(removeTemporaryFiles: true)
    }

    func stopRecording(in directoryURL: URL, fileLayout: RecordingFileLayout) async throws -> RecordingCapture {
        guard let startedAt, let source = activeRecordingSource else {
            throw LorreError.recordingNotStarted
        }

        let endedAt = Date()
        let durationSeconds = max(endedAt.timeIntervalSince(startedAt), 0)
        let canonicalTempURL = temporaryCanonicalURL
        let microphoneTempURL = temporaryMicrophoneURL
        let systemAudioTempURL = temporarySystemAudioURL

        activeRecordingToken = nil
        liveStartupTask?.cancel()
        liveStartupTask = nil

        try await stopCapturePipelines()
        await stopLiveStreamingCaptureIfNeeded()

        let microphoneWriteFailure = microphoneWriter?.failureMessage()
        #if canImport(ScreenCaptureKit)
        let systemWriteFailure = systemCapture?.failure()
        #else
        let systemWriteFailure: String? = nil
        #endif

        self.microphoneEngine = nil
        self.microphoneWriter = nil
        #if canImport(ScreenCaptureKit)
        self.systemCapture = nil
        #endif
        self.liveMonitorBridge = nil
        self.combinedMeterBox = nil
        self.previewMixer = nil
        self.startedAt = nil
        self.activeRecordingSource = nil
        self.temporaryCanonicalURL = nil
        self.temporaryMicrophoneURL = nil
        self.temporarySystemAudioURL = nil

        if let microphoneWriteFailure {
            throw LorreError.recordingStopFailed("Could not write microphone audio. \(microphoneWriteFailure)")
        }
        if let systemWriteFailure {
            throw LorreError.recordingStopFailed("Could not write system audio. \(systemWriteFailure)")
        }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let canonicalDestinationURL = directoryURL.appendingPathComponent(fileLayout.audioFileName)

            switch source {
            case .microphone, .systemAudio:
                guard let canonicalTempURL else {
                    throw LorreError.recordingStopFailed("Recorded audio was not captured.")
                }
                try moveRecordingFile(from: canonicalTempURL, to: canonicalDestinationURL)
            case .microphoneAndSystemAudio:
                guard let microphoneTempURL, let systemAudioTempURL else {
                    throw LorreError.recordingStopFailed("Recorded stems are incomplete.")
                }
                guard let microphoneStemFileName = fileLayout.microphoneStemFileName,
                      let systemAudioStemFileName = fileLayout.systemAudioStemFileName else {
                    throw LorreError.recordingStopFailed("Recording file layout is missing stem destinations.")
                }

                try RecorderAudioUtilities.mixToCanonicalFile(
                    microphoneURL: microphoneTempURL,
                    systemAudioURL: systemAudioTempURL,
                    destinationURL: canonicalDestinationURL
                )
                try moveRecordingFile(
                    from: microphoneTempURL,
                    to: directoryURL.appendingPathComponent(microphoneStemFileName)
                )
                try moveRecordingFile(
                    from: systemAudioTempURL,
                    to: directoryURL.appendingPathComponent(systemAudioStemFileName)
                )
            }
        } catch let error as LorreError {
            throw error
        } catch {
            throw LorreError.recordingStopFailed(error.localizedDescription)
        }

        return RecordingCapture(startedAt: startedAt, endedAt: endedAt, durationSeconds: durationSeconds)
    }

    func currentMeterLevel() async -> Double {
        liveMonitorBridge?.currentMeterLevel() ?? 0.05
    }

    func recordingFileLayout(for source: RecordingSource) async -> RecordingFileLayout {
        switch source {
        case .microphone, .systemAudio:
            return RecordingFileLayout(audioFileName: "audio.caf", microphoneStemFileName: nil, systemAudioStemFileName: nil)
        case .microphoneAndSystemAudio:
            return RecordingFileLayout(
                audioFileName: "audio.caf",
                microphoneStemFileName: "microphone.caf",
                systemAudioStemFileName: "system-audio.caf"
            )
        }
    }

    func supportsLiveTranscription(for source: RecordingSource) async -> Bool {
        #if canImport(FluidAudio)
        #if canImport(ScreenCaptureKit)
        return source == .microphone || source == .systemAudio || source == .microphoneAndSystemAudio
        #else
        return source == .microphone
        #endif
        #else
        _ = source
        return false
        #endif
    }

    func prepareLiveTranscriptionEngine(
        onProgress: (@Sendable (ProcessingUpdate) async -> Void)?
    ) async throws {
        #if canImport(FluidAudio)
        let recognizer = liveRecognizer ?? FluidAudioLiveStreamingRecognizer(
            speakerEnrollmentService: speakerEnrollmentService,
            knownSpeakerReferenceAudioProvider: knownSpeakerReferenceAudioProvider
        )
        await recognizer.setKnownSpeakers(knownSpeakers)
        try await recognizer.prepareModels(onProgress: onProgress)
        self.liveRecognizer = recognizer
        #else
        if let onProgress {
            await onProgress(
                ProcessingUpdate(
                    phase: .preparing,
                    component: .livePreview,
                    label: "Live preview unavailable",
                    detail: "This build does not include the live preview engine.",
                    fraction: 1.0
                )
            )
        }
        #endif
    }

    func setKnownSpeakers(_ speakers: [KnownSpeaker]) async {
        knownSpeakers = speakers.sorted {
            $0.safeDisplayName.localizedCaseInsensitiveCompare($1.safeDisplayName) == .orderedAscending
        }
        #if canImport(FluidAudio)
        await liveRecognizer?.setKnownSpeakers(knownSpeakers)
        #endif
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async {
        isLiveTranscriptionEnabled = isEnabled
        if !isEnabled {
            liveStartupTask?.cancel()
            liveStartupTask = nil
            livePreviewFallback = nil
            #if canImport(FluidAudio)
            if activeRecordingSource == nil {
                await liveRecognizer?.cancel()
                liveRecognizer = nil
            }
            #endif
        }
    }

    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview? {
        guard isLiveTranscriptionEnabled else { return nil }
        if let bridgePreview = liveMonitorBridge?.currentPreview(),
           bridgePreview.hasContent || bridgePreview.errorMessage != nil || bridgePreview.isFinalizing {
            return bridgePreview
        }
        #if canImport(FluidAudio)
        if let liveRecognizer {
            let preview = await liveRecognizer.latestPreview()
            if preview.hasContent || preview.errorMessage != nil || preview.isFinalizing {
                return preview
            }
            return livePreviewFallback ?? preview
        }
        #endif
        return livePreviewFallback
    }

    func makeLiveMonitorStream() async -> AsyncStream<RecorderLiveMonitorEvent>? {
        liveMonitorBridge?.makeMonitorStream()
    }

    private func ensurePermissions(for source: RecordingSource) async throws {
        if source.includesMicrophone, !(await requestMicrophonePermission()) {
            await MainActor.run {
                Self.openSystemSettings(for: .microphone)
            }
            throw LorreError.microphonePermissionDenied
        }
        if source.includesSystemAudio, !screenCapturePermissionGranted() {
            await MainActor.run {
                Self.openSystemSettings(for: .screenCapture)
            }
            throw LorreError.screenCapturePermissionDenied
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func screenCapturePermissionGranted() -> Bool {
        #if canImport(ScreenCaptureKit)
        return CGPreflightScreenCaptureAccess()
        #else
        return false
        #endif
    }

    @MainActor
    private static func openSystemSettings(for pane: PermissionSettingsPane) {
        #if canImport(AppKit)
        let candidateURLs: [URL]
        switch pane {
        case .microphone:
            candidateURLs = [
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            ].compactMap { $0 }
        case .screenCapture:
            candidateURLs = [
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"),
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            ].compactMap { $0 }
        }

        for url in candidateURLs where NSWorkspace.shared.open(url) {
            return
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        #endif
    }

    #if canImport(ScreenCaptureKit)
    private func pickSystemAudioFilter() async throws -> SCContentFilter {
        let pickerObserver = await MainActor.run { ScreenCapturePickerObserverBox() }
        return try await pickerObserver.present()
    }
    #endif

    private func startMicrophoneCapture(
        in tempDir: URL,
        combinedMeter: CombinedMeterBox?,
        previewBridge: LiveMonitorBridgeBox,
        previewMixer: MixedPreviewMixerBox?,
        source: RecordingSource
    ) throws -> MicrophoneCaptureStartResult {
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let writer = try CaptureFileWriterBox(file: AVAudioFile(forWriting: tempURL, settings: inputFormat.settings))
        let targetFrames = Int((inputFormat.sampleRate * 0.45).rounded())
        let bufferSize = AVAudioFrameCount(max(4096, min(32_768, targetFrames)))

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            writer.write(buffer)
            let meterLevel = buffer.lorre_meterLevel()
            if let combinedMeter {
                previewBridge.setMeterLevel(combinedMeter.update(meterLevel, for: .microphone))
            } else {
                previewBridge.setMeterLevel(meterLevel)
            }

            if source == .microphoneAndSystemAudio {
                previewMixer?.enqueue(buffer, source: .microphone)
            } else {
                previewBridge.enqueueRecognitionBuffer(buffer)
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw LorreError.recordingStartFailed("AVAudioEngine failed to start. \(error.localizedDescription)")
        }

        return MicrophoneCaptureStartResult(engine: engine, writer: writer, tempURL: tempURL)
    }

    #if canImport(ScreenCaptureKit)
    private func startSystemAudioCapture(
        filter: SCContentFilter,
        in tempDir: URL,
        combinedMeter: CombinedMeterBox?,
        previewBridge: LiveMonitorBridgeBox,
        previewMixer: MixedPreviewMixerBox?,
        source: RecordingSource
    ) async throws -> SystemCaptureStartResult {
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let capture = try SystemAudioCaptureBox(
            filter: filter,
            outputURL: tempURL,
            onPCMBuffer: { buffer in
                if source == .microphoneAndSystemAudio {
                    previewMixer?.enqueue(buffer, source: .systemAudio)
                } else {
                    previewBridge.enqueueRecognitionBuffer(buffer)
                }
            },
            onMeterLevel: { level in
                if let combinedMeter {
                    previewBridge.setMeterLevel(combinedMeter.update(level, for: .systemAudio))
                } else {
                    previewBridge.setMeterLevel(level)
                }
            }
        )
        do {
            try await capture.start()
        } catch {
            await capture.cancel()
            throw LorreError.recordingStartFailed("System audio capture failed to start. \(error.localizedDescription)")
        }
        return SystemCaptureStartResult(capture: capture, tempURL: tempURL)
    }
    #endif

    private func startLiveStreamingStartupTask(for recordingToken: UUID) {
        liveStartupTask?.cancel()
        liveStartupTask = Task { [weak self] in
            await self?.completeLiveStreamingStartup(for: recordingToken)
        }
    }

    private func completeLiveStreamingStartup(for recordingToken: UUID) async {
        guard !Task.isCancelled else { return }
        guard activeRecordingSource != nil, activeRecordingToken == recordingToken else { return }
        do {
            try await startLiveRecognizerIfNeeded()
            guard activeRecordingSource != nil, activeRecordingToken == recordingToken else { return }
            livePreviewFallback = LiveTranscriptPreview(
                confirmedText: "",
                partialText: "Listening for speech…",
                isFinalizing: false,
                errorMessage: nil,
                updatedAt: Date()
            )
            liveMonitorBridge?.setPreview(livePreviewFallback)
        } catch is CancellationError {
            return
        } catch {
            guard activeRecordingSource != nil, activeRecordingToken == recordingToken else { return }
            livePreviewFallback = LiveTranscriptPreview(
                confirmedText: "",
                partialText: "",
                isFinalizing: false,
                errorMessage: "Live transcript unavailable: \(error.localizedDescription)",
                updatedAt: Date()
            )
            liveMonitorBridge?.setPreview(livePreviewFallback)
        }
    }

    private func startLiveRecognizerIfNeeded() async throws {
        #if canImport(FluidAudio)
        guard isLiveTranscriptionEnabled else { return }
        try Task.checkCancellation()

        let recognizer = liveRecognizer ?? FluidAudioLiveStreamingRecognizer(
            speakerEnrollmentService: speakerEnrollmentService,
            knownSpeakerReferenceAudioProvider: knownSpeakerReferenceAudioProvider
        )
        await recognizer.setKnownSpeakers(knownSpeakers)
        let previewBridge = self.liveMonitorBridge
        try await recognizer.start { [weak previewBridge] preview in
            previewBridge?.setPreview(preview)
        }
        self.liveRecognizer = recognizer
        previewBridge?.setRecognizer(recognizer)
        try Task.checkCancellation()
        #endif
    }

    private func stopLiveStreamingCaptureIfNeeded() async {
        previewMixer?.flushRemaining()
        await liveMonitorBridge?.drainRecognitionWork()
        liveMonitorBridge?.setMeterLevel(0.05)

        #if canImport(FluidAudio)
        guard let liveRecognizer else {
            liveMonitorBridge?.finishMonitoring()
            return
        }

        do {
            _ = try await liveRecognizer.finish()
            livePreviewFallback = nil
        } catch {
            livePreviewFallback = LiveTranscriptPreview(
                confirmedText: "",
                partialText: "",
                isFinalizing: false,
                errorMessage: "Live transcript ended with an error: \(error.localizedDescription)",
                updatedAt: Date()
            )
            liveMonitorBridge?.setPreview(livePreviewFallback)
        }
        liveMonitorBridge?.setRecognizer(nil)
        self.liveRecognizer = nil
        #endif

        liveMonitorBridge?.finishMonitoring()
    }

    private func stopCapturePipelines() async throws {
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        #if canImport(ScreenCaptureKit)
        if let systemCapture {
            try await systemCapture.stop()
        }
        #endif
    }

    private func cleanupPartialRecordingState(removeTemporaryFiles: Bool = true) async throws {
        activeRecordingToken = nil
        liveStartupTask?.cancel()
        liveStartupTask = nil

        try? await stopCapturePipelines()
        await stopLiveStreamingCaptureIfNeeded()

        let tempURLs = [temporaryCanonicalURL, temporaryMicrophoneURL, temporarySystemAudioURL]

        self.microphoneEngine = nil
        self.microphoneWriter = nil
        #if canImport(ScreenCaptureKit)
        self.systemCapture = nil
        #endif
        self.liveMonitorBridge = nil
        self.combinedMeterBox = nil
        self.previewMixer = nil
        self.startedAt = nil
        self.activeRecordingSource = nil
        self.temporaryCanonicalURL = nil
        self.temporaryMicrophoneURL = nil
        self.temporarySystemAudioURL = nil
        self.livePreviewFallback = nil

        guard removeTemporaryFiles else { return }
        for tempURL in tempURLs {
            guard let tempURL else { continue }
            let path = tempURL.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    private func moveRecordingFile(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
}
#endif
