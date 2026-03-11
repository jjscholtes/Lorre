#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum RecorderAudioUtilities {
    private final class ConversionInputState: @unchecked Sendable {
        private let lock = NSLock()
        private var hasSuppliedInput = false

        func nextBuffer(
            from buffer: AVAudioPCMBuffer,
            outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }

            guard hasSuppliedInput == false else {
                outStatus.pointee = .endOfStream
                return nil
            }

            hasSuppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    static let previewFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }()

    static func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw LorreError.recordingStartFailed("System audio stream format is unavailable.")
        }

        var sourceStreamDescription = streamDescription.pointee
        guard let sourceFormat = AVAudioFormat(streamDescription: &sourceStreamDescription) else {
            throw LorreError.recordingStartFailed("System audio format is unsupported.")
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw LorreError.recordingStartFailed("Could not allocate system audio buffer.")
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw LorreError.recordingStartFailed("Could not copy system audio samples (status: \(status)).")
        }
        return buffer
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == outputFormat {
            guard let copy = buffer.lorre_deepCopy() else {
                throw LorreError.recordingStartFailed("Could not copy audio buffer.")
            }
            return copy
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            throw LorreError.recordingStartFailed("Could not prepare audio format converter.")
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let estimatedCapacity = max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedCapacity)
        ) else {
            throw LorreError.recordingStartFailed("Could not allocate converted audio buffer.")
        }

        let inputState = ConversionInputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputState.nextBuffer(from: buffer, outStatus: outStatus)
        }

        if let conversionError {
            throw LorreError.recordingStartFailed(conversionError.localizedDescription)
        }

        guard status == .haveData || status == .inputRanDry || status == .endOfStream else {
            throw LorreError.recordingStartFailed("Audio conversion failed.")
        }
        return outputBuffer
    }

    static func makePCMBuffer(from samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            throw LorreError.recordingStartFailed("Could not allocate mixed audio buffer.")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else {
            throw LorreError.recordingStartFailed("Mixed audio buffer has no channel data.")
        }

        let channelCount = Int(format.channelCount)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            for channel in 0..<channelCount {
                channelData[channel].update(from: baseAddress, count: samples.count)
            }
        }
        return buffer
    }

    static func loadSamples(from url: URL, targetFormat: AVAudioFormat) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw LorreError.recordingStopFailed("Could not load recorded audio for mixing.")
        }
        try file.read(into: inputBuffer)
        let converted = try convert(inputBuffer, to: targetFormat)
        guard let channelData = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))
    }

    static func write(samples: [Float], to url: URL, format: AVAudioFormat) throws {
        let buffer = try makePCMBuffer(from: samples, format: format)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func mixToCanonicalFile(
        microphoneURL: URL,
        systemAudioURL: URL,
        destinationURL: URL,
        targetFormat: AVAudioFormat = RecorderAudioUtilities.previewFormat
    ) throws {
        let microphoneSamples = try loadSamples(from: microphoneURL, targetFormat: targetFormat)
        let systemSamples = try loadSamples(from: systemAudioURL, targetFormat: targetFormat)
        let count = max(microphoneSamples.count, systemSamples.count)
        guard count > 0 else {
            try write(samples: [], to: destinationURL, format: targetFormat)
            return
        }

        let voiceGain: Float = 0.70710677
        let systemGain: Float = 0.70710677
        let headroom: Float = 0.8
        var mixed = Array(repeating: Float(0), count: count)
        var peak: Float = 0

        for index in 0..<count {
            let microphone = index < microphoneSamples.count ? microphoneSamples[index] : 0
            let system = index < systemSamples.count ? systemSamples[index] : 0
            let value = ((microphone * voiceGain) + (system * systemGain)) * headroom
            mixed[index] = value
            peak = max(peak, abs(value))
        }

        if peak > 0.98 {
            let gain = 0.98 / peak
            for index in mixed.indices {
                mixed[index] *= gain
            }
        }

        try write(samples: mixed, to: destinationURL, format: targetFormat)
    }
}

extension AVAudioPCMBuffer {
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
        let rmsNormalized = max(0.0, min(1.0, (rmsDb + 58.0) / 38.0))
        let peakNormalized = max(0.0, min(1.0, (peakDb + 46.0) / 34.0))
        let blended = max(rmsNormalized * 0.92, peakNormalized * 0.88)
        let gated = max(0.0, blended - 0.02) / 0.98
        let gained = min(1.0, gated * 1.45)
        return max(0.02, pow(gained, 0.68))
    }
}
#endif
