import Foundation

#if canImport(AVFoundation)
import AVFoundation

final class AVFoundationAudioPlaybackService: NSObject, AudioPlaybackService {
    private var player: AVAudioPlayer?
    private(set) var preparedURL: URL?
    private var configuredRate: Double = 1.0

    var currentTimeSeconds: Double { player?.currentTime ?? 0 }
    var durationSeconds: Double {
        let duration = player?.duration ?? 0
        return duration.isFinite ? duration : 0
    }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var playbackRate: Double { configuredRate }

    func prepare(url: URL) throws {
        if preparedURL == url, player != nil { return }
        do {
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.enableRate = true
            nextPlayer.rate = Float(configuredRate)
            nextPlayer.prepareToPlay()
            player = nextPlayer
            preparedURL = url
        } catch {
            throw LorreError.playbackFailed(error.localizedDescription)
        }
    }

    func play() throws {
        guard let player else {
            throw LorreError.playbackFailed("Audio file is not loaded.")
        }
        if !player.play() {
            throw LorreError.playbackFailed("Playback could not be started.")
        }
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let bounded = min(max(0, seconds), max(0, player.duration))
        player.currentTime = bounded
    }

    func setPlaybackRate(_ rate: Double) {
        let bounded = min(max(rate, 0.5), 2.0)
        configuredRate = bounded
        player?.enableRate = true
        player?.rate = Float(bounded)
    }
}
#else

final class UnsupportedAudioPlaybackService: AudioPlaybackService {
    let preparedURL: URL? = nil
    let currentTimeSeconds: Double = 0
    let durationSeconds: Double = 0
    let isPlaying: Bool = false
    let playbackRate: Double = 1.0

    func prepare(url: URL) throws {
        _ = url
        throw LorreError.playbackFailed("Audio playback is unavailable in this build.")
    }

    func play() throws {
        throw LorreError.playbackFailed("Audio playback is unavailable in this build.")
    }

    func pause() {}
    func stop() {}
    func seek(to seconds: Double) {
        _ = seconds
    }
    func setPlaybackRate(_ rate: Double) {
        _ = rate
    }
}
#endif
