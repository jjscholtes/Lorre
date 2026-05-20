#if canImport(AVFoundation)
@preconcurrency import AVFoundation
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

        func markFailure(_ message: String) {
            lock.lock()
            if writeFailureMessage == nil {
                writeFailureMessage = message
            }
            lock.unlock()
        }
    }

    private final class PCMBufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private final class AudioEngineBox: @unchecked Sendable {
        private let engine: AVAudioEngine

        init(_ engine: AVAudioEngine) {
            self.engine = engine
        }

        func stop() {
            engine.stop()
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
        private actor RecognitionBufferQueue {
            private let maxBufferedBuffers: Int
            private var pendingBuffers: [LiveTranscriptionPCMBufferBox] = []
            private var suspendedConsumer: CheckedContinuation<LiveTranscriptionPCMBufferBox?, Never>?
            private var drainContinuations: [CheckedContinuation<Void, Never>] = []
            private var inFlightBufferCount = 0
            private var isClosed = false

            init(maxBufferedBuffers: Int) {
                self.maxBufferedBuffers = maxBufferedBuffers
            }

            func enqueue(_ buffer: LiveTranscriptionPCMBufferBox) {
                guard !isClosed else { return }

                if let suspendedConsumer {
                    self.suspendedConsumer = nil
                    inFlightBufferCount += 1
                    suspendedConsumer.resume(returning: buffer)
                    return
                }

                pendingBuffers.append(buffer)
                if pendingBuffers.count > maxBufferedBuffers {
                    pendingBuffers.removeFirst(pendingBuffers.count - maxBufferedBuffers)
                }
            }

            func next() async -> LiveTranscriptionPCMBufferBox? {
                if !pendingBuffers.isEmpty {
                    inFlightBufferCount += 1
                    return pendingBuffers.removeFirst()
                }
                if isClosed {
                    return nil
                }
                return await withCheckedContinuation { continuation in
                    suspendedConsumer = continuation
                }
            }

            func finishProcessingCurrentBuffer() {
                if inFlightBufferCount > 0 {
                    inFlightBufferCount -= 1
                }
                resumeDrainContinuationsIfNeeded()
            }

            func drain() async {
                guard !pendingBuffers.isEmpty || inFlightBufferCount > 0 else { return }
                await withCheckedContinuation { continuation in
                    drainContinuations.append(continuation)
                }
            }

            func finish() {
                isClosed = true
                pendingBuffers.removeAll(keepingCapacity: false)
                if let suspendedConsumer {
                    self.suspendedConsumer = nil
                    suspendedConsumer.resume(returning: nil)
                }
                resumeDrainContinuationsIfNeeded()
            }

            private func resumeDrainContinuationsIfNeeded() {
                guard pendingBuffers.isEmpty, inFlightBufferCount == 0 else { return }
                let continuations = drainContinuations
                drainContinuations.removeAll(keepingCapacity: false)
                continuations.forEach { $0.resume() }
            }
        }

        private var recognizer: FluidAudioLiveStreamingRecognizer?
        private let maxBufferedRecognitionBuffers = 16
        private var recognitionQueue: RecognitionBufferQueue?
        private var recognitionWorkerTask: Task<Void, Never>?
        private var recognitionWorkerGeneration = 0
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
        func prepareRecognitionBuffering() {
            lock.lock()
            if recognitionQueue == nil {
                recognitionQueue = RecognitionBufferQueue(maxBufferedBuffers: maxBufferedRecognitionBuffers)
            }
            lock.unlock()
        }

        func setRecognizer(_ recognizer: FluidAudioLiveStreamingRecognizer?) {
            let queueToFinish: RecognitionBufferQueue?
            let workerToCancel: Task<Void, Never>?
            let shouldStartWorker: Bool

            lock.lock()
            self.recognizer = recognizer
            if recognizer == nil {
                queueToFinish = recognitionQueue
                recognitionQueue = nil
                workerToCancel = recognitionWorkerTask
                recognitionWorkerTask = nil
                recognitionWorkerGeneration += 1
                shouldStartWorker = false
            } else {
                queueToFinish = nil
                workerToCancel = nil
                if recognitionQueue == nil {
                    recognitionQueue = RecognitionBufferQueue(maxBufferedBuffers: maxBufferedRecognitionBuffers)
                }
                shouldStartWorker = recognitionWorkerTask == nil
            }
            lock.unlock()

            if shouldStartWorker {
                startRecognitionWorkerIfNeeded()
            }

            if let workerToCancel {
                workerToCancel.cancel()
            }
            if let queueToFinish {
                Task {
                    await queueToFinish.finish()
                }
            }
        }

        func enqueueRecognitionBuffer(_ buffer: AVAudioPCMBuffer) {
            guard let copiedBuffer = buffer.lorre_deepCopy().map(LiveTranscriptionPCMBufferBox.init) else { return }

            let queue: RecognitionBufferQueue?
            lock.lock()
            queue = recognitionQueue
            lock.unlock()

            if let queue {
                Task {
                    await queue.enqueue(copiedBuffer)
                }
            }
        }

        func drainRecognitionWork() async {
            let queue = currentRecognitionQueue()
            if let queue {
                await queue.drain()
            }
        }

        func discardRecognitionWork() async {
            let queueToFinish: RecognitionBufferQueue?
            let workerToCancel: Task<Void, Never>?

            lock.lock()
            queueToFinish = recognitionQueue
            recognitionQueue = nil
            recognizer = nil
            workerToCancel = recognitionWorkerTask
            recognitionWorkerTask = nil
            recognitionWorkerGeneration += 1
            lock.unlock()

            workerToCancel?.cancel()
            await queueToFinish?.finish()
        }

        private func startRecognitionWorkerIfNeeded() {
            let queue: RecognitionBufferQueue?
            let generation: Int

            lock.lock()
            guard recognitionWorkerTask == nil else {
                lock.unlock()
                return
            }
            guard let recognitionQueue else {
                lock.unlock()
                return
            }
            recognitionWorkerGeneration += 1
            generation = recognitionWorkerGeneration
            queue = recognitionQueue
            recognitionWorkerTask = Task { [weak self] in
                guard let self, let queue else { return }
                await self.runRecognitionWorkerLoop(using: queue, generation: generation)
            }
            lock.unlock()
        }

        private func currentRecognizer() -> FluidAudioLiveStreamingRecognizer? {
            lock.lock()
            defer { lock.unlock() }
            return recognizer
        }

        private func currentRecognitionQueue() -> RecognitionBufferQueue? {
            lock.lock()
            defer { lock.unlock() }
            return recognitionQueue
        }

        private func runRecognitionWorkerLoop(using queue: RecognitionBufferQueue, generation: Int) async {
            while !Task.isCancelled {
                guard let buffer = await queue.next() else {
                    break
                }

                guard let recognizer = currentRecognizer() else {
                    await queue.finishProcessingCurrentBuffer()
                    break
                }

                await recognizer.ingest(buffer)
                await queue.finishProcessingCurrentBuffer()
            }
            clearRecognitionWorkerTaskReference(ifGenerationMatches: generation)
        }

        private func clearRecognitionWorkerTaskReference(ifGenerationMatches generation: Int) {
            lock.lock()
            if recognitionWorkerGeneration == generation {
                recognitionWorkerTask = nil
            }
            lock.unlock()
        }
        #else
        func prepareRecognitionBuffering() {}

        func setRecognizer(_ recognizer: Any?) {
            _ = recognizer
        }

        func enqueueRecognitionBuffer(_ buffer: AVAudioPCMBuffer) {
            _ = buffer
        }

        func drainRecognitionWork() async {}

        func discardRecognitionWork() async {}
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

        private struct SampleQueue {
            private var storage: [Float] = []
            private var startIndex = 0

            var count: Int { storage.count - startIndex }

            mutating func append(_ samples: [Float], maxBufferedSamples: Int) {
                storage.append(contentsOf: samples)
                if count > maxBufferedSamples {
                    startIndex += count - maxBufferedSamples
                }
                compactIfNeeded()
            }

            func sample(at index: Int) -> Float {
                guard index >= 0, index < count else { return 0 }
                return storage[startIndex + index]
            }

            mutating func removeFirst(_ amount: Int) {
                startIndex += min(max(amount, 0), count)
                compactIfNeeded()
            }

            mutating func removeAll(keepingCapacity: Bool = false) {
                storage.removeAll(keepingCapacity: keepingCapacity)
                startIndex = 0
            }

            private mutating func compactIfNeeded() {
                guard startIndex > 0, startIndex > max(4096, storage.count / 2) else { return }
                storage.removeFirst(startIndex)
                startIndex = 0
            }
        }

        private let workQueue = DispatchQueue(label: "Lorre.MixedPreviewMixer")
        private var microphoneSamples = SampleQueue()
        private var systemSamples = SampleQueue()
        private let chunkSize = 1600
        private let maxBufferedSamples = 1600 * 24
        private let outputFormat = RecorderAudioUtilities.previewFormat
        private let converter: RecorderAudioUtilities.ReusableConverterBox
        private let outputHandler: @Sendable (AVAudioPCMBuffer) -> Void

        init(outputHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
            self.outputHandler = outputHandler
            self.converter = RecorderAudioUtilities.ReusableConverterBox(outputFormat: outputFormat)
        }

        func enqueue(_ buffer: AVAudioPCMBuffer, source: Source) {
            guard let copiedBuffer = buffer.lorre_deepCopy() else { return }
            let bufferBox = PCMBufferBox(copiedBuffer)
            workQueue.async { [weak self, bufferBox] in
                self?.process(bufferBox.buffer, source: source, flushAll: false)
            }
        }

        func flushRemaining() {
            workQueue.sync {
                let chunks = drain(flushAll: true)
                emit(chunks)
            }
        }

        private func process(_ buffer: AVAudioPCMBuffer, source: Source, flushAll: Bool) {
            guard let converted = try? converter.convert(buffer),
                  let channelData = converted.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))

            switch source {
            case .microphone:
                microphoneSamples.append(samples, maxBufferedSamples: maxBufferedSamples)
            case .systemAudio:
                systemSamples.append(samples, maxBufferedSamples: maxBufferedSamples)
            }
            let chunks = drain(flushAll: flushAll)
            emit(chunks)
        }

        private func drain(flushAll: Bool) -> [[Float]] {
            var chunks: [[Float]] = []

            while max(microphoneSamples.count, systemSamples.count) >= chunkSize || (
                flushAll && max(microphoneSamples.count, systemSamples.count) > 0
            ) {
                let frameCount = flushAll ? min(chunkSize, max(microphoneSamples.count, systemSamples.count)) : chunkSize
                var mixed = Array(repeating: Float(0), count: frameCount)

                for index in 0..<frameCount {
                    let microphone = microphoneSamples.sample(at: index)
                    let system = systemSamples.sample(at: index)
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
        private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        private let converter: RecorderAudioUtilities.ReusableConverterBox
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
            self.converter = RecorderAudioUtilities.ReusableConverterBox(outputFormat: outputFormat)
            self.writer = try CaptureFileWriterBox(file: AVAudioFile(forWriting: outputURL, settings: outputFormat.settings))
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
                let converted = try converter.convert(buffer)
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
        var configurationObserver: NSObjectProtocol?
    }

    #if canImport(ScreenCaptureKit)
    private struct SystemCaptureStartResult {
        var capture: SystemAudioCaptureBox
        var tempURL: URL
    }
    #endif

    private var microphoneEngine: AVAudioEngine?
    private var microphoneWriter: CaptureFileWriterBox?
    private var microphoneConfigurationObserver: NSObjectProtocol?
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
    private var liveTranscriptionPreset: LiveTranscriptionPreset = .balanced
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
        let shouldRunLiveTranscription: Bool
        if isLiveTranscriptionEnabled {
            shouldRunLiveTranscription = await supportsLiveTranscription(for: request.source)
        } else {
            shouldRunLiveTranscription = false
        }
        if shouldRunLiveTranscription {
            monitorBridge.prepareRecognitionBuffering()
        }
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
            self.microphoneConfigurationObserver = micStart?.configurationObserver
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

            if shouldRunLiveTranscription {
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

        do {
            try await stopCapturePipelines()
            await stopLiveStreamingCaptureIfNeeded()

            let microphoneWriteFailure = microphoneWriter?.failureMessage()
            #if canImport(ScreenCaptureKit)
            let systemWriteFailure = systemCapture?.failure()
            #else
            let systemWriteFailure: String? = nil
            #endif

            clearActiveRecordingState()

            if let microphoneWriteFailure {
                throw LorreError.recordingStopFailed("Could not write microphone audio. \(microphoneWriteFailure)")
            }
            if let systemWriteFailure {
                throw LorreError.recordingStopFailed("Could not write system audio. \(systemWriteFailure)")
            }

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
        } catch {
            await stopLiveStreamingCaptureIfNeeded()
            clearActiveRecordingState()
            removeTemporaryRecordingFiles([canonicalTempURL, microphoneTempURL, systemAudioTempURL])
            if let error = error as? LorreError {
                throw error
            }
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
            knownSpeakerReferenceAudioProvider: knownSpeakerReferenceAudioProvider,
            preset: liveTranscriptionPreset
        )
        await recognizer.setPreset(liveTranscriptionPreset)
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

    func setLiveTranscriptionPreset(_ preset: LiveTranscriptionPreset) async {
        guard liveTranscriptionPreset != preset else { return }
        liveTranscriptionPreset = preset
        #if canImport(FluidAudio)
        await liveRecognizer?.setPreset(preset)
        if activeRecordingSource == nil {
            await liveRecognizer?.cancel()
            liveRecognizer = nil
        }
        #endif
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
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LorreError.recordingStartFailed("No usable microphone input device is available.")
        }
        let writer = try CaptureFileWriterBox(file: AVAudioFile(forWriting: tempURL, settings: inputFormat.settings))
        let engineBox = AudioEngineBox(engine)
        let configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [engineBox, writer] _ in
            writer.markFailure("The audio input device changed during recording.")
            engineBox.stop()
        }
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
            NotificationCenter.default.removeObserver(configurationObserver)
            inputNode.removeTap(onBus: 0)
            throw LorreError.recordingStartFailed("AVAudioEngine failed to start. \(error.localizedDescription)")
        }

        return MicrophoneCaptureStartResult(engine: engine, writer: writer, tempURL: tempURL, configurationObserver: configurationObserver)
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
            if Self.isScreenCapturePermissionError(error) {
                await MainActor.run {
                    Self.openSystemSettings(for: .screenCapture)
                }
                throw LorreError.screenCapturePermissionDenied
            }
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
            try await startLiveRecognizerIfNeeded(for: recordingToken)
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

    private func startLiveRecognizerIfNeeded(for recordingToken: UUID) async throws {
        #if canImport(FluidAudio)
        guard isLiveTranscriptionEnabled else { return }
        try Task.checkCancellation()
        guard activeRecordingSource != nil, activeRecordingToken == recordingToken else {
            throw CancellationError()
        }

        let recognizer = liveRecognizer ?? FluidAudioLiveStreamingRecognizer(
            speakerEnrollmentService: speakerEnrollmentService,
            knownSpeakerReferenceAudioProvider: knownSpeakerReferenceAudioProvider,
            preset: liveTranscriptionPreset
        )
        await recognizer.setPreset(liveTranscriptionPreset)
        await recognizer.setKnownSpeakers(knownSpeakers)
        let previewBridge = self.liveMonitorBridge
        try await recognizer.start { [weak previewBridge] preview in
            previewBridge?.setPreview(preview)
        }
        guard !Task.isCancelled,
              activeRecordingSource != nil,
              activeRecordingToken == recordingToken else {
            _ = try? await recognizer.finish()
            throw CancellationError()
        }
        self.liveRecognizer = recognizer
        previewBridge?.setRecognizer(recognizer)
        try Task.checkCancellation()
        #endif
    }

    private func stopLiveStreamingCaptureIfNeeded() async {
        previewMixer?.flushRemaining()
        liveMonitorBridge?.setMeterLevel(0.05)

        #if canImport(FluidAudio)
        guard let liveRecognizer else {
            await liveMonitorBridge?.discardRecognitionWork()
            liveMonitorBridge?.finishMonitoring()
            return
        }

        await liveMonitorBridge?.drainRecognitionWork()

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
        await liveMonitorBridge?.discardRecognitionWork()
        self.liveRecognizer = nil
        #else
        await liveMonitorBridge?.discardRecognitionWork()
        #endif

        liveMonitorBridge?.finishMonitoring()
    }

    private func stopCapturePipelines() async throws {
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let microphoneConfigurationObserver {
            NotificationCenter.default.removeObserver(microphoneConfigurationObserver)
            self.microphoneConfigurationObserver = nil
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
        if let microphoneConfigurationObserver {
            NotificationCenter.default.removeObserver(microphoneConfigurationObserver)
            self.microphoneConfigurationObserver = nil
        }
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

    private func clearActiveRecordingState() {
        self.microphoneEngine = nil
        self.microphoneWriter = nil
        if let microphoneConfigurationObserver {
            NotificationCenter.default.removeObserver(microphoneConfigurationObserver)
            self.microphoneConfigurationObserver = nil
        }
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
    }

    private func removeTemporaryRecordingFiles(_ tempURLs: [URL?]) {
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

    private static func isScreenCapturePermissionError(_ error: Error) -> Bool {
        #if canImport(ScreenCaptureKit)
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            return false
        }

        return nsError.code == -3801 || nsError.code == -3802 || nsError.code == -3818
        #else
        _ = error
        return false
        #endif
    }
}
#endif
