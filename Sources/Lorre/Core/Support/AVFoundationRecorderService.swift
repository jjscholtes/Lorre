#if canImport(AVFoundation)
import AVFoundation
import Foundation

actor AVFoundationRecorderService: RecorderService {
    private final class LiveCaptureFileWriterBox: @unchecked Sendable {
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

    private final class LiveCaptureTapBridgeBox: @unchecked Sendable {
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
        private let maxBufferedRecognitionBuffers = 8
        private var recognitionWorkerTask: Task<Void, Never>?
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

        func currentRecognizer() -> FluidAudioLiveStreamingRecognizer? {
            lock.lock()
            defer { lock.unlock() }
            return recognizer
        }

        func enqueueForRecognition(_ buffer: LiveTranscriptionPCMBufferBox) {
            lock.lock()
            guard recognizer != nil else {
                lock.unlock()
                return
            }
            if pendingRecognitionBuffers.count >= maxBufferedRecognitionBuffers {
                pendingRecognitionBuffers.removeFirst(pendingRecognitionBuffers.count - maxBufferedRecognitionBuffers + 1)
            }
            pendingRecognitionBuffers.append(buffer)
            let shouldStartWorker = recognitionWorkerTask == nil
            lock.unlock()
            if shouldStartWorker {
                startRecognitionWorkerIfNeeded()
            }
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
            let stream = AsyncStream<RecorderLiveMonitorEvent>(bufferingPolicy: .bufferingNewest(64)) { continuation in
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
            return (recognizer, next)
        }

        private func runRecognitionWorkerLoop() async {
            while !Task.isCancelled {
                if let (recognizer, buffer) = popRecognitionWork() {
                    await recognizer.ingest(buffer)
                    continue
                }
                try? await Task.sleep(for: .milliseconds(12))
                if currentRecognizer() == nil {
                    break
                }
            }
            clearRecognitionWorkerTaskReference()
        }

        private func clearRecognitionWorkerTaskReference() {
            lock.lock()
            recognitionWorkerTask = nil
            lock.unlock()
        }
        #endif
    }

    private var recorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var liveCaptureFileWriter: LiveCaptureFileWriterBox?
    private var liveCaptureTapBridge: LiveCaptureTapBridgeBox?
    private var temporaryURL: URL?
    private var startedAt: Date?
    private var liveStartupTask: Task<Void, Never>?
    private var activeRecordingToken: UUID?
    private var isLiveTranscriptionEnabled = false
    private var livePreviewFallback: LiveTranscriptPreview?
    #if canImport(FluidAudio)
    private var liveRecognizer: FluidAudioLiveStreamingRecognizer?
    #endif

    func requestMicrophonePermission() async -> Bool {
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

    func supportsLiveTranscription() async -> Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    func prepareLiveTranscriptionEngine() async throws {
        #if canImport(FluidAudio)
        guard await supportsLiveTranscription() else { return }
        let recognizer = liveRecognizer ?? FluidAudioLiveStreamingRecognizer()
        try await recognizer.prepareModels()
        self.liveRecognizer = recognizer
        #endif
    }

    func setLiveTranscriptionEnabled(_ isEnabled: Bool) async {
        let supported = await supportsLiveTranscription()
        isLiveTranscriptionEnabled = isEnabled && supported

        if !isLiveTranscriptionEnabled {
            liveStartupTask?.cancel()
            liveStartupTask = nil
            livePreviewFallback = nil
            #if canImport(FluidAudio)
            if recorder == nil {
                await liveRecognizer?.cancel()
                liveRecognizer = nil
            }
            #endif
        }
    }

    func currentLiveTranscriptPreview() async -> LiveTranscriptPreview? {
        guard isLiveTranscriptionEnabled else { return nil }
        if let bridgePreview = liveCaptureTapBridge?.currentPreview(),
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
        guard audioEngine != nil else { return nil }
        return liveCaptureTapBridge?.makeMonitorStream()
    }

    func startRecording() async throws {
        guard recorder == nil, audioEngine == nil else {
            throw LorreError.recordingStartFailed("Another recording is already in progress.")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lorre", isDirectory: true)
            .appendingPathComponent("recording-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            livePreviewFallback = nil
            try startEngineBackedRecording(in: tempDir)

            let recordingToken = UUID()
            self.activeRecordingToken = recordingToken
            if isLiveTranscriptionEnabled {
                livePreviewFallback = LiveTranscriptPreview(
                    confirmedText: "",
                    partialText: "Preparing live transcript… recording has already started.",
                    isFinalizing: false,
                    errorMessage: nil,
                    updatedAt: Date()
                )
                liveCaptureTapBridge?.setPreview(livePreviewFallback)
                startLiveStreamingStartupTask(for: recordingToken)
            }
        } catch let error as LorreError {
            throw error
        } catch {
            throw LorreError.recordingStartFailed(error.localizedDescription)
        }
    }

    func stopRecording(to url: URL) async throws -> RecordingCapture {
        guard let temporaryURL, let startedAt else {
            throw LorreError.recordingNotStarted
        }

        let endedAt = Date()
        let durationSeconds: Double

        if let recorder {
            durationSeconds = max(recorder.currentTime, endedAt.timeIntervalSince(startedAt))
            recorder.stop()
        } else if audioEngine != nil {
            durationSeconds = max(endedAt.timeIntervalSince(startedAt), 0)
        } else {
            throw LorreError.recordingNotStarted
        }

        activeRecordingToken = nil
        liveStartupTask?.cancel()
        liveStartupTask = nil
        await stopLiveStreamingCaptureIfNeeded()
        let liveWriteFailure = liveCaptureFileWriter?.failureMessage()

        self.recorder = nil
        self.liveCaptureFileWriter = nil
        self.liveCaptureTapBridge = nil
        self.startedAt = nil
        self.temporaryURL = nil

        if let writeFailure = liveWriteFailure {
            throw LorreError.recordingStopFailed("Could not write live recording audio. \(writeFailure)")
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        } catch {
            throw LorreError.recordingStopFailed(error.localizedDescription)
        }

        return RecordingCapture(
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds
        )
    }

    func cancelRecording() async throws {
        guard recorder != nil || audioEngine != nil || temporaryURL != nil || startedAt != nil else {
            throw LorreError.recordingNotStarted
        }

        if let recorder {
            recorder.stop()
        }

        let discardURL = temporaryURL
        activeRecordingToken = nil
        liveStartupTask?.cancel()
        liveStartupTask = nil
        await stopLiveStreamingCaptureIfNeeded()

        self.recorder = nil
        self.liveCaptureFileWriter = nil
        self.liveCaptureTapBridge = nil
        self.startedAt = nil
        self.temporaryURL = nil
        self.livePreviewFallback = nil

        guard let discardURL else { return }
        let path = discardURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(at: discardURL)
        } catch {
            throw LorreError.recordingStopFailed("Could not discard temporary recording. \(error.localizedDescription)")
        }
    }

    func currentMeterLevel() async -> Double {
        if let recorder {
            recorder.updateMeters()
            let dB = Double(recorder.averagePower(forChannel: 0))
            guard dB.isFinite else { return 0.05 }
            let normalized = max(0, min(1, (dB + 60) / 60))
            return pow(normalized, 1.7)
        }
        if audioEngine != nil {
            return liveCaptureTapBridge?.currentMeterLevel() ?? 0.05
        }
        return 0.05
    }

    func preferredRecordingFileExtension() async -> String {
        "caf"
    }

    #if canImport(FluidAudio)
    private func startEngineBackedRecording(in tempDir: URL) throws {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).caf")
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let fileWriter = try LiveCaptureFileWriterBox(file: AVAudioFile(forWriting: url, settings: inputFormat.settings))
        let tapBridge = LiveCaptureTapBridgeBox()
        let targetFrames = Int((inputFormat.sampleRate * 0.45).rounded())
        let bufferSize = AVAudioFrameCount(max(4096, min(32_768, targetFrames)))

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            fileWriter.write(buffer)

            let meterLevel = buffer.lorre_meterLevel()
            tapBridge.setMeterLevel(meterLevel)

            guard tapBridge.currentRecognizer() != nil else { return }
            guard let copiedBuffer = buffer.lorre_deepCopy().map(LiveTranscriptionPCMBufferBox.init) else { return }
            tapBridge.enqueueForRecognition(copiedBuffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw LorreError.recordingStartFailed("AVAudioEngine failed to start. \(error.localizedDescription)")
        }

        self.audioEngine = engine
        self.liveCaptureFileWriter = fileWriter
        self.liveCaptureTapBridge = tapBridge
        self.temporaryURL = url
        self.startedAt = Date()
    }

    private func startLiveStreamingStartupTask(for recordingToken: UUID) {
        liveStartupTask?.cancel()
        liveStartupTask = Task { [weak self] in
            await self?.completeLiveStreamingStartup(for: recordingToken)
        }
    }

    private func completeLiveStreamingStartup(for recordingToken: UUID) async {
        guard !Task.isCancelled else { return }
        guard (recorder != nil || audioEngine != nil), activeRecordingToken == recordingToken else { return }
        do {
            try await startLiveRecognizerIfNeeded()
            guard (recorder != nil || audioEngine != nil), activeRecordingToken == recordingToken else { return }
            livePreviewFallback = LiveTranscriptPreview(
                confirmedText: "",
                partialText: "Listening for speech…",
                isFinalizing: false,
                errorMessage: nil,
                updatedAt: Date()
            )
            liveCaptureTapBridge?.setPreview(livePreviewFallback)
        } catch is CancellationError {
            return
        } catch {
            // Keep recording usable even if live transcription startup fails.
            guard (recorder != nil || audioEngine != nil), activeRecordingToken == recordingToken else { return }
            livePreviewFallback = LiveTranscriptPreview(
                confirmedText: "",
                partialText: "",
                isFinalizing: false,
                errorMessage: "Live transcript unavailable: \(error.localizedDescription)",
                updatedAt: Date()
            )
            liveCaptureTapBridge?.setPreview(livePreviewFallback)
        }
    }

    private func startLiveRecognizerIfNeeded() async throws {
        guard isLiveTranscriptionEnabled else { return }
        try Task.checkCancellation()

        let recognizer = liveRecognizer ?? FluidAudioLiveStreamingRecognizer()
        let tapBridge = self.liveCaptureTapBridge
        try await recognizer.start { [weak tapBridge] preview in
            tapBridge?.setPreview(preview)
        }
        self.liveRecognizer = recognizer
        tapBridge?.setRecognizer(recognizer)
        try Task.checkCancellation()
    }

    private func stopLiveStreamingCaptureIfNeeded() async {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        liveCaptureTapBridge?.setMeterLevel(0.05)
        liveCaptureTapBridge?.setRecognizer(nil)
        liveCaptureTapBridge?.finishMonitoring()

        guard let liveRecognizer else { return }

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
            liveCaptureTapBridge?.setPreview(livePreviewFallback)
        }
        self.liveRecognizer = nil
    }
    #else
    private func startEngineBackedRecording(in tempDir: URL) throws {
        _ = tempDir
        throw LorreError.recordingStartFailed("Live transcription is unavailable in this build.")
    }
    private func startLiveStreamingStartupTask(for recordingToken: UUID) {
        _ = recordingToken
    }
    private func stopLiveStreamingCaptureIfNeeded() async {}
    #endif
}

private extension AVAudioPCMBuffer {
    func lorre_deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength

        let frameCount = Int(frameLength)
        let channelCount = Int(format.channelCount)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = floatChannelData, let destination = copy.floatChannelData else { return nil }
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
            return copy
        case .pcmFormatInt16:
            guard let source = int16ChannelData, let destination = copy.int16ChannelData else { return nil }
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
            return copy
        case .pcmFormatInt32:
            guard let source = int32ChannelData, let destination = copy.int32ChannelData else { return nil }
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
            return copy
        default:
            return nil
        }
    }

    func lorre_meterLevel() -> Double {
        let frameCount = Int(frameLength)
        guard frameCount > 0 else { return 0.05 }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return 0.05 }

        var peak: Double = 0
        var sumSquares: Double = 0
        var sampleCount = 0

        switch format.commonFormat {
        case .pcmFormatFloat32:
            if let channels = floatChannelData {
                for channel in 0..<channelCount {
                    let values = UnsafeBufferPointer(start: channels[channel], count: frameCount)
                    for sample in values {
                        let value = Double(abs(sample))
                        peak = max(peak, value)
                        sumSquares += value * value
                        sampleCount += 1
                    }
                }
            } else {
                let audioBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
                guard let first = audioBuffers.first, let data = first.mData else { return 0.05 }
                let samples = data.assumingMemoryBound(to: Float.self)
                let total = frameCount * channelCount
                for index in 0..<total {
                    let value = Double(abs(samples[index]))
                    peak = max(peak, value)
                    sumSquares += value * value
                }
                sampleCount = total
            }
        case .pcmFormatInt16:
            if let channels = int16ChannelData {
                for channel in 0..<channelCount {
                    let values = UnsafeBufferPointer(start: channels[channel], count: frameCount)
                    for sample in values {
                        let normalized = Double(Swift.abs(Int32(sample))) / Double(Int16.max)
                        peak = max(peak, normalized)
                        sumSquares += normalized * normalized
                        sampleCount += 1
                    }
                }
            } else {
                let audioBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
                guard let first = audioBuffers.first, let data = first.mData else { return 0.05 }
                let samples = data.assumingMemoryBound(to: Int16.self)
                let total = frameCount * channelCount
                for index in 0..<total {
                    let normalized = Double(Swift.abs(Int32(samples[index]))) / Double(Int16.max)
                    peak = max(peak, normalized)
                    sumSquares += normalized * normalized
                }
                sampleCount = total
            }
        case .pcmFormatInt32:
            if let channels = int32ChannelData {
                for channel in 0..<channelCount {
                    let values = UnsafeBufferPointer(start: channels[channel], count: frameCount)
                    for sample in values {
                        let normalized = Double(Swift.abs(Int64(sample))) / Double(Int32.max)
                        peak = max(peak, normalized)
                        sumSquares += normalized * normalized
                        sampleCount += 1
                    }
                }
            } else {
                let audioBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
                guard let first = audioBuffers.first, let data = first.mData else { return 0.05 }
                let samples = data.assumingMemoryBound(to: Int32.self)
                let total = frameCount * channelCount
                for index in 0..<total {
                    let normalized = Double(Swift.abs(Int64(samples[index]))) / Double(Int32.max)
                    peak = max(peak, normalized)
                    sumSquares += normalized * normalized
                }
                sampleCount = total
            }
        default:
            return 0.05
        }

        guard sampleCount > 0 else { return 0.05 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        let rmsDb = 20.0 * log10(max(rms, 0.000_1))
        let peakDb = 20.0 * log10(max(peak, 0.000_1))

        // Calibrate for spoken voice on laptop/desktop mics:
        // - RMS gives stable motion
        // - Peak gives fast response
        // Use a tighter dB window than before so normal speech reads higher.
        let rmsNormalized = max(0.0, min(1.0, (rmsDb + 58.0) / 38.0))
        let peakNormalized = max(0.0, min(1.0, (peakDb + 46.0) / 34.0))

        // Blend RMS (body) with peak (attack), then apply a soft gate + gain.
        let blended = max(rmsNormalized * 0.92, peakNormalized * 0.88)
        let gated = max(0.0, blended - 0.02) / 0.98
        let gained = min(1.0, gated * 1.45)

        // Slightly lighter curve to improve visible movement in the live rail.
        return max(0.02, pow(gained, 0.68))
    }
}
#endif
