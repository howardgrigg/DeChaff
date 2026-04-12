import SwiftUI
import AVFoundation

// MARK: - Helpers

func formatPlaybackTime(_ seconds: Double) -> String {
    let t = max(0, seconds)
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - PlaybackState

/// Isolated `@Observable` for playback so that the 20 Hz timer only invalidates
/// views that read `isPlaying` or `playheadSeconds`, not the entire hierarchy.
@MainActor @Observable
final class PlaybackState {
    var isPlaying = false
    var playheadSeconds: Double = 0

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    func toggle(url: URL?) {
        isPlaying ? pause() : playFrom(playheadSeconds, url: url)
    }

    func playFrom(_ t: Double, url: URL?) {
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer = player
        player.currentTime = t
        player.play()
        isPlaying = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.audioPlayer else { return }
            self.playheadSeconds = p.currentTime
            if !p.isPlaying { self.isPlaying = false; self.playbackTimer?.invalidate() }
        }
    }

    func pause() {
        audioPlayer?.pause(); isPlaying = false; playbackTimer?.invalidate()
    }

    func stop() {
        audioPlayer?.stop(); audioPlayer = nil
        isPlaying = false; playbackTimer?.invalidate(); playheadSeconds = 0
    }

    func seek(to time: Double) {
        playheadSeconds = time
        audioPlayer?.currentTime = time
    }
}
