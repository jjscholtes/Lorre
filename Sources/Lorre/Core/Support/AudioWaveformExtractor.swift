import Foundation

#if canImport(AVFoundation)
import AVFoundation

enum AudioWaveformExtractor {
    static func makeBins(from url: URL, binCount: Int = 96) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }

        let count = max(12, binCount)
        var bins = Array(repeating: Float(0), count: count)
        let chunkSize: AVAudioFrameCount = 4096
        var frameOffset = 0

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
                break
            }
            try file.read(into: buffer)
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }

            for frame in 0..<framesRead {
                let amplitude = maxFrameAmplitude(buffer, frame: frame)
                let globalFrame = frameOffset + frame
                let binIndex = min(count - 1, (globalFrame * count) / max(totalFrames, 1))
                bins[binIndex] = max(bins[binIndex], amplitude)
            }

            frameOffset += framesRead
        }

        let maxValue = bins.max() ?? 0
        guard maxValue > 0 else {
            return Array(repeating: 0.08, count: count)
        }

        return bins.map { sample in
            let normalized = Double(sample / maxValue)
            // Gentle compression gives a more readable strip for speech.
            return min(1.0, max(0.05, sqrt(normalized)))
        }
    }

    private static func maxFrameAmplitude(_ buffer: AVAudioPCMBuffer, frame: Int) -> Float {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if let channels = buffer.floatChannelData {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channels[channel][frame]))
                }
                return peak
            }
            return maxFrameAmplitudeInterleavedFloat32(buffer, frame: frame, channelCount: channelCount)

        case .pcmFormatInt16:
            if let channels = buffer.int16ChannelData {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    let raw = Int32(channels[channel][frame])
                    let normalized = Float(Swift.abs(raw)) / Float(Int16.max)
                    peak = max(peak, normalized)
                }
                return peak
            }
            return maxFrameAmplitudeInterleavedInt16(buffer, frame: frame, channelCount: channelCount)

        case .pcmFormatInt32:
            if let channels = buffer.int32ChannelData {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    let raw = Int64(channels[channel][frame])
                    let normalized = Float(Swift.abs(raw)) / Float(Int32.max)
                    peak = max(peak, normalized)
                }
                return peak
            }
            return maxFrameAmplitudeInterleavedInt32(buffer, frame: frame, channelCount: channelCount)

        default:
            return 0
        }
    }

    private static func maxFrameAmplitudeInterleavedFloat32(
        _ buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int
    ) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = audioBuffers.first, let data = first.mData else { return 0 }
        let samples = data.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        let start = frame * channelCount
        for channel in 0..<channelCount {
            peak = max(peak, abs(samples[start + channel]))
        }
        return peak
    }

    private static func maxFrameAmplitudeInterleavedInt16(
        _ buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int
    ) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = audioBuffers.first, let data = first.mData else { return 0 }
        let samples = data.assumingMemoryBound(to: Int16.self)
        var peak: Float = 0
        let start = frame * channelCount
        for channel in 0..<channelCount {
            let raw = Int32(samples[start + channel])
            let normalized = Float(Swift.abs(raw)) / Float(Int16.max)
            peak = max(peak, normalized)
        }
        return peak
    }

    private static func maxFrameAmplitudeInterleavedInt32(
        _ buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int
    ) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = audioBuffers.first, let data = first.mData else { return 0 }
        let samples = data.assumingMemoryBound(to: Int32.self)
        var peak: Float = 0
        let start = frame * channelCount
        for channel in 0..<channelCount {
            let raw = Int64(samples[start + channel])
            let normalized = Float(Swift.abs(raw)) / Float(Int32.max)
            peak = max(peak, normalized)
        }
        return peak
    }
}
#else
enum AudioWaveformExtractor {
    static func makeBins(from url: URL, binCount: Int = 96) throws -> [Double] {
        _ = url
        _ = binCount
        return []
    }
}
#endif
